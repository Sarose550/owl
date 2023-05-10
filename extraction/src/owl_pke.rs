use vstd::{prelude::*, vec::*};
use digest::Digest;
use rsa::{
    pkcs8::DecodePrivateKey, pkcs8::DecodePublicKey, pkcs8::EncodePrivateKey,
    pkcs8::EncodePublicKey, PaddingScheme, PublicKey, RsaPrivateKey, RsaPublicKey,
};

verus! {
/*  For PKE, we always use OAEP with SHA256 as the padding scheme,
 *  and use PKCS#8 DER to encode/decode keys as byte vectors
 */

pub const PRIVATE_KEY_BITS: usize = 2048;

#[verifier(external_body)]
pub fn gen_rand_keys() -> (_:(Vec<u8>, Vec<u8>)) {
    let mut rng = rand::thread_rng();
    let privkey = RsaPrivateKey::new(&mut rng, PRIVATE_KEY_BITS).unwrap();
    let pubkey = RsaPublicKey::from(&privkey);
    let privkey_encoded: std::vec::Vec<u8> = privkey.to_pkcs8_der().unwrap().as_bytes().to_vec();
    let pubkey_encoded = pubkey.to_public_key_der().unwrap().to_vec();
    (Vec { vec: privkey_encoded }, Vec { vec: pubkey_encoded })
}

#[verifier(external_body)]
pub fn encrypt(pubkey: &[u8], msg: &[u8]) -> Vec<u8> {
    let mut rng = rand::thread_rng();
    let padding = PaddingScheme::new_oaep::<sha2::Sha256>();
    let pubkey_decoded = RsaPublicKey::from_public_key_der(pubkey).unwrap();
    let v = pubkey_decoded.encrypt(&mut rng, padding, &msg[..]).unwrap();
    Vec { vec: v }
}

#[verifier(external_body)]
pub fn decrypt(privkey: &[u8], ctxt: &[u8]) -> Vec<u8> {
    let padding = PaddingScheme::new_oaep::<sha2::Sha256>();
    let privkey_decoded = RsaPrivateKey::from_pkcs8_der(privkey).unwrap();
    let v = privkey_decoded.decrypt(padding, &ctxt[..]).unwrap();
    Vec { vec: v }
}

#[verifier(external_body)]
pub fn sign(privkey: &[u8], msg: &[u8]) -> Vec<u8> {
    let mut rng = rand::thread_rng();
    let padding = PaddingScheme::new_pss::<sha2::Sha256>();
    let privkey_decoded = RsaPrivateKey::from_pkcs8_der(privkey).unwrap();
    let v = privkey_decoded
        .sign_with_rng(&mut rng, padding, &sha2::Sha256::digest(&msg))
        .unwrap();
    Vec { vec: v }
}

#[verifier(external_body)]
pub fn verify(pubkey: &[u8], signature: &[u8], msg: &[u8]) -> bool {
    let padding = PaddingScheme::new_pss::<sha2::Sha256>();
    let pubkey_decoded = RsaPublicKey::from_public_key_der(pubkey).unwrap();
    match pubkey_decoded.verify(padding, &sha2::Sha256::digest(&msg), &signature) {
        std::result::Result::Ok(_) => true,
        std::result::Result::Err(_) => false,
    }
}

} // verus!