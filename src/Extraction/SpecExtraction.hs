{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
module SpecExtraction where
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List
import Data.Maybe
import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Except
import Control.Lens
import Prettyprinter
import Data.Type.Equality
import Unbound.Generics.LocallyNameless
import Unbound.Generics.LocallyNameless.Bind
import Unbound.Generics.LocallyNameless.Name ( Name(Bn, Fn) )
import Unbound.Generics.LocallyNameless.Unsafe (unsafeUnbind)
import Unbound.Generics.LocallyNameless.TH
import GHC.Generics (Generic)
import Data.Typeable (Typeable)
import AST
import ConcreteAST
import System.IO
import qualified Text.Parsec as P
import qualified Parse as OwlP
import qualified TypingBase as TB
import ExtractionBase 

----------------------------------------------------------------------------------
--- Datatype extraction

genParserSerializer :: String -> ExtractionMonad (Doc ann)
genParserSerializer name = do
    -- TODO nesting design---Seq or ADT args---depends on parsing lib
    let parser = pretty "#[verifier(external_body)]" <+> pretty "pub closed spec fn parse_" <> pretty name <> parens (pretty "x: Seq<u8>") <+>
                    pretty "->" <+> pretty "Option" <> angles (pretty name) <+> braces (line <>
                    (pretty "todo!()") <> line
                )
    let serializer = pretty "#[verifier(external_body)]" <+> pretty "pub closed spec fn serialize_" <> pretty name <> parens (pretty "x:" <+> pretty name) <+>
                    pretty "->" <+> pretty "Seq<u8>" <+> braces (line <>
                    (pretty "todo!()") <> line
                )
    return $ vsep [parser, serializer]

extractStruct :: String -> [(String, Ty)] -> ExtractionMonad (Doc ann)
extractStruct owlName owlFields = do
    let name = specName owlName
    fields <- mapM (\(n, t) -> (rustifySpecTy . doConcretifyTy) t >>= \t' -> return (n, t')) owlFields
    let structDef = pretty "pub struct" <+> pretty name <> braces (line <> (
                        vsep . punctuate comma . map (\(n, t) -> pretty "pub" <+> pretty (specName n) <+> pretty ":" <+> pretty t) $ fields
                    ) <> line)
    parseSerializeDefs <- genParserSerializer name
    constructor <- genConstructor owlName fields
    selectors <- mapM (genFieldSelector owlName) fields
    return $ vsep $ [structDef, parseSerializeDefs, constructor] ++ selectors 
    where
        genConstructor owlName fields = do
            let args = parens . hsep . punctuate comma . map (\(n,_) -> pretty "arg_" <> pretty n <> pretty ": Seq<u8>") $ fields
            let body = pretty "serialize_" <> pretty (specName owlName) <>
                    parens (pretty (specName owlName) <> braces (hsep . punctuate comma . map (\(n,_) -> pretty (specName n) <> pretty ": arg_" <> pretty n) $ fields))
            return $
                pretty "pub open spec fn" <+> pretty owlName <> args <+> pretty "-> Seq<u8>" <+> braces (line <>
                    body
                <> line)
        genFieldSelector owlName (fieldName, fieldTy) = do
            return $ 
                pretty "pub open spec fn" <+> pretty fieldName <> parens (pretty "arg: Seq<u8>") <+> pretty "-> Seq<u8>" <+> braces (line <>
                    pretty "match" <+> pretty "parse_" <> pretty (specName owlName) <> parens (pretty "arg") <+> braces (line <>
                        pretty "Some(parsed) => parsed." <> pretty (specName fieldName) <> comma <> line <>
                        pretty "None => seq![] // TODO"
                    <> line)
                <> line)

extractEnum :: String -> [(String, Maybe Ty)] -> ExtractionMonad (Doc ann)
extractEnum owlName owlCases = do
    let name = specName owlName
    cases <- mapM (\(n, topt) -> do
                        t' <- case topt of
                            Just t -> Just <$> (rustifySpecTy . doConcretifyTy) t
                            Nothing -> return Nothing
                        return (n, t')) owlCases
    let enumDef = pretty "#[is_variant]" <> line <> pretty "pub enum" <+> pretty name <> braces (line <> (
                        vsep . punctuate comma . map (\(n, t) -> pretty (specName n) <> parens (pretty t)) $ cases
                    ) <> line)
    parseSerializeDefs <- genParserSerializer name
    caseConstructors <- mapM (genCaseConstructor name) cases
    return $ vsep $ [enumDef, parseSerializeDefs] ++ caseConstructors
    where
        genCaseConstructor name (caseName, Just caseTy) = do
            return $
                pretty "pub open spec fn" <+> pretty caseName <> parens (pretty "x: Seq<u8>") <+> pretty "-> Seq<u8>" <+> braces (line <>
                    pretty "serialize_" <> pretty name <> parens (
                        pretty "crate::" <> pretty name <> pretty "::" <> pretty (specName caseName) <> parens (pretty "x")
                    )
                <> line)

        genCaseConstructor name (caseName, Nothing) = do
            return $
                pretty "pub open spec fn" <+> pretty caseName <> pretty "()" <+> pretty "-> Seq<u8>" <+> braces (line <>
                    pretty "serialize_" <> pretty name <> parens (
                        pretty "crate::" <> pretty name <> pretty "::" <> pretty (specName caseName) <> pretty "()"
                    )
                <> line)


----------------------------------------------------------------------------------
--- Code generation

-- Owl builtin functions that must be printed differently in Rust
specBuiltinFuncs :: M.Map String ([Doc ann] -> Doc ann)
specBuiltinFuncs = M.fromList [
        ("UNIT", \_ -> pretty "()"),
        ("TRUE", \_ -> pretty "true"),
        ("FALSE", \_ -> pretty "false"),
        ("Some", \a -> pretty "Option::Some" <> tupled a),
        ("None", \_ -> pretty "Option::None")
    ]

extractEndpoint :: Endpoint -> ExtractionMonad (Doc ann)
extractEndpoint (Endpoint evar) = return $ extractVar evar
extractEndpoint (EndpointLocality (Locality s _)) = do
    l <- flattenPath s
    return $ pretty "Endpoint::Loc_" <> pretty l

extractVar :: Name a -> Doc ann
extractVar = pretty . replacePrimes . name2String

extractAExpr :: AExpr -> ExtractionMonad (Doc ann)
extractAExpr ae = extractAExpr' (ae ^. val) where
    extractAExpr' (AEVar s n) = return $ extractVar n
    extractAExpr' (AEApp f _ as) = do 
        as' <- mapM extractAExpr as    
        ftail <- tailPath f
        case specBuiltinFuncs M.!? ftail of
            Just f' -> return $ f' as'
            Nothing  -> do
                f' <- flattenPath f
                return $ pretty f' <> tupled as'
        -- return $ pretty f' <> tupled as'
    extractAExpr' (AEString s) = return $ pretty "\"" <> pretty s <> pretty "\""
    extractAExpr' (AELenConst s) = return $ pretty s <> pretty "_len"
    extractAExpr' (AEInt i) = return $ pretty i
    extractAExpr' (AEGet ne) = do
        ne' <- flattenNameExp ne
        return $ parens (pretty "*cfg." <> pretty ne') <> pretty ".view()"
    extractAExpr' (AEGetEncPK ne) = do
        ne' <- flattenNameExp ne
        return $ parens (pretty "*cfg.pk_" <> pretty ne') <> pretty ".view()"
    extractAExpr' (AEGetVK ne) = do
        ne' <- flattenNameExp ne
        return $ parens (pretty "*cfg.pk_" <> pretty ne') <> pretty ".view()"
    extractAExpr' (AEPackIdx s a) = extractAExpr a

extractCryptOp :: CryptOp -> [AExpr] -> ExtractionMonad (Doc ann)
extractCryptOp op owlArgs = do
    args <- mapM extractAExpr owlArgs
    case (op, args) of
        (CHash p _ n, [x]) -> do 
            debugPrint "TODO CHash args"
            return $ noSamp "kdf" [x]
        -- (CPRF s, _) -> do throwError $ ErrSomethingFailed $ "TODO implement crypto op: " ++ show op
        (CAEnc, [k, x]) -> do return $ pretty "sample" <> tupled [pretty "NONCE_SIZE()", pretty "enc" <> tupled [k, x]]
        (CADec, [k, x]) -> do return $ noSamp "dec" [k, x]
        (CAEncWithNonce np _, [k, x]) -> do 
            n <- flattenPath np
            return $ noSamp "enc_with_nonce" [k, x, pretty "mut_state." <> pretty (rustifyName n)]
        (CADecWithNonce, [k, n, c]) -> do return $ noSamp "dec_with_nonce" [k, n, c]
        (CPKEnc, [k, x]) -> do return $ noSamp "pkenc" [k, x]
        (CPKDec, [k, x]) -> do return $ noSamp "pkdec" [k, x]
        (CMac, [k, x]) -> do return $ noSamp "mac" [k, x]
        (CMacVrfy, [k, x, v]) -> do return $ noSamp "mac_vrfy" [k, x, v]
        (CSign, [k, x]) -> do return $ noSamp "sign" [k, x]
        (CSigVrfy, [k, x, v]) -> do return $ noSamp "vrfy" [k, x, v]
        (_, _) -> do throwError $ TypeError $ "got bad args for spec crypto op: " ++ show op ++ "(" ++ show args ++ ")"
    where
        noSamp name args = pretty "ret" <> parens (pretty name <> tupled args)


extractExpr :: CExpr -> ExtractionMonad (Doc ann)
extractExpr CSkip = return $ pretty "skip"
extractExpr (CInput xsk) = do
    let ((x, ev), sk) = unsafeUnbind xsk
    sk' <- extractExpr sk
    return $ parens (pretty "input" <+> tupled [extractVar x, extractVar ev]) <+> pretty "in" <> line <> sk'
extractExpr (COutput a l) = do
    a' <- extractAExpr a
    l' <- case l of
      Nothing -> throwError OutputWithUnknownDestination
      Just s  -> do
        s' <- extractEndpoint s
        return $ pretty "to" <+> parens s'
    return $ parens $ pretty "output " <> parens a' <+> l'
extractExpr (CLet (COutput a l) xk) = do
    let (_, k) = unsafeUnbind xk 
    o <- extractExpr (COutput a l)
    k' <- extractExpr k
    return $ o <+> pretty "in" <> line <> k'
extractExpr (CLet CSkip xk) = 
    let (_, k) = unsafeUnbind xk in extractExpr k
extractExpr (CLet e xk) = do
    let (x, k) = unsafeUnbind xk 
    e' <- extractExpr e
    k' <- extractExpr k
    return $ pretty "let" <+> extractVar x <+> pretty "=" <+> parens e' <+> pretty "in" <> line <> k'
extractExpr (CIf a e1 e2) = do
    a' <- extractAExpr a
    e1' <- extractExpr e1
    e2' <- extractExpr e2
    return $ parens $
        pretty "if" <+> parens a' <+> pretty "then" <+> parens (pretty e1) <+> pretty "else" <+> parens (pretty e2)
extractExpr (CRet a) = do 
    a' <- extractAExpr a
    return $ parens $ pretty "ret" <+> parens a'
extractExpr (CCall f is as) = do
    as' <- mapM extractAExpr as
    ftail <- tailPath f
    let inds = case is of
                ([], []) -> mempty
                (v1, v2) -> pretty "<" <> mconcat (map pretty v1) <> pretty "@" <> mconcat (map pretty v2) <> pretty ">"
    return $ pretty "call" <> parens (pretty ftail <> pretty "_spec" <> inds <> tupled (pretty "cfg" : as'))
extractExpr (CCase a xs) = do
    a' <- extractAExpr a
    pcases <-
            mapM (\(c, o) ->
                case o of
                Left e -> do 
                    e' <- extractExpr e
                    return $ pretty c <+> pretty "=>" <+> braces e' <> comma
                Right xe -> do
                    let (x, e) = unsafeUnbind xe
                    e' <- extractExpr e
                    return $ pretty c <+> parens (extractVar x) <+> pretty "=>" <+> braces e' <> comma
                ) xs 
    return $ parens $ pretty "case" <+> parens a' <> line <> braces (vsep pcases)
extractExpr (CCrypt cop args) = do
    parens <$> extractCryptOp cop args
extractExpr (CIncCtr p ([], [])) = do
    p' <- flattenPath p
    return $ parens $ parens (pretty "inc_counter" <> tupled [pretty (rustifyName p')])
extractExpr (CGetCtr p ([], [])) = do 
    p' <- flattenPath p
    return $ parens $ pretty "ret" <> parens (pretty "mut_state." <> pretty (rustifyName p'))
extractExpr c = throwError . ErrSomethingFailed . show $ pretty "unimplemented case for Spec.extractExpr:" <+> pretty c
-- extractExpr (CTLookup n a) = return $ pretty "lookup" <> tupled [pretty n, extractAExpr a]
-- extractExpr (CTWrite n a a') = return $ pretty "write" <> tupled [pretty n, extractAExpr a, extractAExpr a']

specExtractArg :: (String, RustTy) -> Doc ann
specExtractArg (s, rt) =
    pretty s <> pretty ":" <+> pretty (specTyOf rt)


extractDef :: String -> Locality -> CExpr -> [(String, RustTy)] -> SpecTy -> ExtractionMonad (Doc ann)
extractDef owlName (Locality lpath _) concreteBody owlArgs specRt = do
    lname <- flattenPath lpath
    let argsPrettied = hsep . punctuate comma $ 
            pretty "cfg:" <+> pretty (cfgName lname) 
            : pretty "mut_state:" <+> pretty (stateName lname)
            : map specExtractArg owlArgs
    let rtPrettied = pretty "-> (res: ITree<(" <> pretty specRt <> comma <+> pretty (stateName lname) <> pretty "), Endpoint>" <> pretty ")"
    body <- extractExpr concreteBody
    return $ pretty "pub open spec fn" <+> pretty owlName <> pretty "_spec" <> parens argsPrettied <+> rtPrettied <+> lbrace <> line <>
        pretty "owl_spec!" <> parens (pretty "mut_state," <> pretty (stateName lname) <> comma <> line <>
            body
        <> line) <> line <>
        rbrace

mkSpecEndpoint :: [String] -> Doc ann
mkSpecEndpoint lnames = 
    pretty "#[is_variant]" <> line <> pretty "#[derive(Copy, Clone)]" <> line <> 
    pretty "pub enum Endpoint" <+> braces (line <> 
        (vsep . punctuate comma . map (\s -> pretty "Loc_" <> pretty s) $ lnames)
    <> line)

endpointOfAddr :: Doc ann
endpointOfAddr = pretty "#[verifier(external_body)] pub closed spec fn endpoint_of_addr(addr: Seq<char>) -> Endpoint { unimplemented!() /* axiomatized */ }"