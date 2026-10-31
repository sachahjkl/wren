// crypto.subtle (native/js/odin/web_crypto.js, src/page/bindings_crypto_subtle.odin): known answers of the RFCs and NIST,
// the rules of the specification (errors, usages, extractable), and keys that travel.
"use strict";

const subtle = crypto.subtle;
const hex = s => new Uint8Array(s.match(/../g).map(x => parseInt(x, 16)));
const toHex = b => [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, "0")).join("");
const utf8 = s => new TextEncoder().encode(s);
const b64url = b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const fill = (n, x) => new Uint8Array(n).fill(x);
const counting = n => new Uint8Array(n).map((_, i) => i);

test("CryptoKey", async () => {
  eq(typeof CryptoKey, "function", "CryptoKey exists");
  throws(() => new CryptoKey(), "TypeError", "CryptoKey has no constructor");
  const key = await subtle.generateKey({ name: "aes-gcm", length: 128 }, true, ["encrypt", "encrypt", "decrypt"]);
  ok(key instanceof CryptoKey, "generateKey makes a CryptoKey");
  eq(String(key), "[object CryptoKey]", "its class string");
  eq(key.type, "secret", "type");
  eq(key.extractable, true, "extractable");
  eq(key.algorithm.name, "AES-GCM", "the algorithm has its registered name");
  eq(key.algorithm.length, 128, "the algorithm has its length");
  eq(key.algorithm, key.algorithm, "algorithm is one object");
  eq(key.usages, key.usages, "usages is one object");
  eq(key.usages.join(), "encrypt,decrypt", "usages have no repetition");
  // what a script does to these objects does not change the key
  key.algorithm.name = "HMAC";
  key.usages.length = 0;
  const data = await subtle.encrypt({ name: "AES-GCM", iv: new Uint8Array(12) }, key, new Uint8Array(1));
  eq(data.byteLength, 17, "the key is as it was");
  const getter = Object.getOwnPropertyDescriptor(CryptoKey.prototype, "type").get;
  throws(() => getter.call({}), "TypeError", "the getters check their object");
});

test("HMAC (RFC 4231)", async () => {
  const key = await subtle.importKey("raw", fill(20, 0x0b), { name: "HMAC", hash: "SHA-256" }, true, ["sign", "verify"]);
  eq(key.algorithm.hash.name, "SHA-256", "the key's hash");
  eq(key.algorithm.length, 160, "the key's length");
  const mac = await subtle.sign("HMAC", key, utf8("Hi There"));
  eq(toHex(mac), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "sign");
  eq(await subtle.verify("HMAC", key, mac, utf8("Hi There")), true, "verify");
  eq(await subtle.verify("HMAC", key, mac, utf8("Hi there")), false, "verify of something else");
  eq(await subtle.verify("HMAC", key, mac.slice(1), utf8("Hi There")), false, "verify of a short tag");
  const generated = await subtle.generateKey({ name: "HMAC", hash: "SHA-384" }, true, ["sign"]);
  eq(generated.algorithm.length, 1024, "a generated key is one block long");
  eq((await subtle.exportKey("raw", generated)).byteLength, 128, "with that many bytes");
  eq((await subtle.exportKey("jwk", key)).k, "CwsLCwsLCwsLCwsLCwsLCwsLCws", "its jwk");
  eq((await subtle.exportKey("jwk", key)).alg, "HS256", "its jwk's alg");
});

test("AES-CBC, AES-CTR (SP 800-38A)", async () => {
  const raw = hex("2b7e151628aed2a6abf7158809cf4f3c");
  const plain = hex("6bc1bee22e409f96e93d7e117393172a");
  const cbc = await subtle.importKey("raw", raw, "AES-CBC", true, ["encrypt", "decrypt"]);
  const iv = counting(16);
  const c1 = await subtle.encrypt({ name: "AES-CBC", iv }, cbc, plain);
  eq(c1.byteLength, 32, "CBC adds a block of padding");
  eq(toHex(c1).slice(0, 32), "7649abac8119b246cee98e9b12e9197d", "CBC encrypt");
  eq(toHex(await subtle.decrypt({ name: "AES-CBC", iv }, cbc, c1)), toHex(plain), "CBC decrypt");
  await rejects(subtle.decrypt({ name: "AES-CBC", iv }, cbc, c1.slice(1)), "OperationError", "CBC: not whole blocks");
  await rejects(subtle.decrypt({ name: "AES-CBC", iv }, cbc, c1.slice(0, 16)), "OperationError", "CBC: wrong padding");
  await rejects(subtle.encrypt({ name: "AES-CBC", iv: iv.slice(1) }, cbc, plain), "OperationError", "CBC: the iv's size");
  const ctr = await subtle.importKey("raw", raw, "AES-CTR", true, ["encrypt", "decrypt"]);
  const counter = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");
  const c2 = await subtle.encrypt({ name: "AES-CTR", counter, length: 64 }, ctr, plain);
  eq(toHex(c2), "874d6191b620e3261bef6864990db6ce", "CTR encrypt");
  eq(toHex(await subtle.decrypt({ name: "AES-CTR", counter, length: 64 }, ctr, c2)), toHex(plain), "CTR decrypt");
  // only the `length` low bits of the counter count: the keystream goes from ...ff to ...00 in its last byte alone
  const near = hex("000102030405060708090a0b0c0d0eff");
  const two = await subtle.encrypt({ name: "AES-CTR", counter: near, length: 8 }, ctr, new Uint8Array(32));
  const after = await subtle.encrypt({ name: "AES-CTR", counter: hex("000102030405060708090a0b0c0d0e00"), length: 8 }, ctr, new Uint8Array(16));
  eq(toHex(two).slice(32), toHex(after), "CTR: the counter wraps within its length");
  await rejects(subtle.encrypt({ name: "AES-CTR", counter, length: 1 }, ctr, new Uint8Array(33)), "OperationError", "CTR: more blocks than the counter has");
  await rejects(subtle.encrypt({ name: "AES-CTR", counter, length: 0 }, ctr, plain), "OperationError", "CTR: length 0");
});

test("AES-GCM (the original paper's test cases)", async () => {
  const key = await subtle.importKey("raw", new Uint8Array(16), "AES-GCM", true, ["encrypt", "decrypt"]);
  const iv = new Uint8Array(12);
  eq(toHex(await subtle.encrypt({ name: "AES-GCM", iv }, key, new Uint8Array(0))), "58e2fccefa7e3061367f1d57a4e7455a", "case 1: the tag");
  const c = await subtle.encrypt({ name: "AES-GCM", iv }, key, new Uint8Array(16));
  eq(toHex(c).slice(0, 32), "0388dace60b6a392f328c2b971b2fe78", "case 2: the ciphertext");
  eq(toHex(await subtle.decrypt({ name: "AES-GCM", iv }, key, c)), "00".repeat(16), "decrypt");
  for (const tagLength of [32, 64, 96, 104, 112, 120]) {
    const short = await subtle.encrypt({ name: "AES-GCM", iv, tagLength }, key, new Uint8Array(16));
    eq(toHex(short), toHex(c).slice(0, 32 + tagLength / 4), `a tag of ${tagLength} bits is the beginning of the tag`);
    eq(toHex(await subtle.decrypt({ name: "AES-GCM", iv, tagLength }, key, short)), "00".repeat(16), `decrypt with a tag of ${tagLength} bits`);
    const bad = new Uint8Array(short);
    bad[bad.length - 1] ^= 1;
    await rejects(subtle.decrypt({ name: "AES-GCM", iv, tagLength }, key, bad), "OperationError", `a wrong tag of ${tagLength} bits`);
  }
  const bad = new Uint8Array(c);
  bad[0] ^= 1;
  await rejects(subtle.decrypt({ name: "AES-GCM", iv }, key, bad), "OperationError", "a wrong ciphertext");
  await rejects(subtle.decrypt({ name: "AES-GCM", iv }, key, new Uint8Array(4)), "OperationError", "shorter than the tag");
  await rejects(subtle.encrypt({ name: "AES-GCM", iv, tagLength: 33 }, key, c), "OperationError", "a tag length that does not exist");
  const aad = await subtle.encrypt({ name: "AES-GCM", iv, additionalData: utf8("x") }, key, new Uint8Array(16));
  await rejects(subtle.decrypt({ name: "AES-GCM", iv }, key, aad), "OperationError", "the additional data is authenticated");
  eq(toHex(await subtle.decrypt({ name: "AES-GCM", iv, additionalData: utf8("x") }, key, aad)), "00".repeat(16), "with it");
  // an IV of any size, a copy of the bytes at the call
  const iv16 = counting(16);
  const pending = subtle.encrypt({ name: "AES-GCM", iv: iv16 }, key, utf8("data"));
  iv16[0] = 99;
  const sealed = await pending;
  eq(toHex(await subtle.decrypt({ name: "AES-GCM", iv: counting(16) }, key, sealed)), toHex(utf8("data")), "an iv of 16 bytes, read at the call");
  // past crypto.digest_offload_bytes it goes to a thread
  const large = await subtle.encrypt({ name: "AES-GCM", iv }, key, new Uint8Array(1 << 20));
  eq((await subtle.decrypt({ name: "AES-GCM", iv }, key, large)).byteLength, 1 << 20, "a large input");
});

test("AES-KW (RFC 3394), wrapKey, unwrapKey", async () => {
  const kek = await subtle.importKey("raw", counting(16), "AES-KW", true, ["wrapKey", "unwrapKey"]);
  const key = await subtle.importKey("raw", hex("00112233445566778899aabbccddeeff"), "AES-GCM", true, ["encrypt"]);
  const wrapped = await subtle.wrapKey("raw", key, kek, "AES-KW");
  eq(toHex(wrapped), "1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5", "wrap");
  const back = await subtle.unwrapKey("raw", wrapped, kek, "AES-KW", "AES-GCM", true, ["encrypt"]);
  eq(toHex(await subtle.exportKey("raw", back)), "00112233445566778899aabbccddeeff", "unwrap");
  eq(back.algorithm.name, "AES-GCM", "unwrap makes a key of the algorithm");
  const bad = new Uint8Array(wrapped);
  bad[0] ^= 1;
  await rejects(subtle.unwrapKey("raw", bad, kek, "AES-KW", "AES-GCM", true, ["encrypt"]), "OperationError", "unwrap of something changed");
  // a jwk through AES-GCM
  const wrapper = await subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["wrapKey", "unwrapKey"]);
  const iv = new Uint8Array(12);
  const sealed = await subtle.wrapKey("jwk", key, wrapper, { name: "AES-GCM", iv });
  const round = await subtle.unwrapKey("jwk", sealed, wrapper, { name: "AES-GCM", iv }, "AES-GCM", true, ["encrypt"]);
  eq(toHex(await subtle.exportKey("raw", round)), "00112233445566778899aabbccddeeff", "a jwk wrapped with AES-GCM");
  const secret = await subtle.importKey("raw", new Uint8Array(16), "AES-GCM", false, ["encrypt"]);
  await rejects(subtle.wrapKey("raw", secret, kek, "AES-KW"), "InvalidAccessError", "a key that is not extractable is not wrapped");
  await rejects(subtle.wrapKey("raw", key, secret, "AES-KW"), "InvalidAccessError", "a wrapping key without the usage");
});

test("PBKDF2 (RFC 6070), HKDF (RFC 5869)", async () => {
  const password = await subtle.importKey("raw", utf8("password"), "PBKDF2", false, ["deriveBits", "deriveKey"]);
  eq(password.extractable, false, "a PBKDF2 key is not extractable");
  const alg = { name: "PBKDF2", hash: "SHA-1", salt: utf8("salt"), iterations: 2 };
  eq(toHex(await subtle.deriveBits({ ...alg, iterations: 1 }, password, 160)), "0c60c80f961f0e71f3a9b524af6012062fe037a6", "PBKDF2, one iteration");
  eq(toHex(await subtle.deriveBits(alg, password, 160)), "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957", "PBKDF2, two iterations");
  await rejects(subtle.deriveBits({ ...alg, iterations: 0 }, password, 160), "OperationError", "no iterations");
  await rejects(subtle.deriveBits(alg, password, 12), "OperationError", "a length that is no multiple of 8");
  await rejects(subtle.deriveBits(alg, password), "OperationError", "no length");
  await rejects(subtle.importKey("raw", utf8("x"), "PBKDF2", true, ["deriveBits"]), "SyntaxError", "an extractable PBKDF2 key");
  await rejects(subtle.exportKey("raw", password), "NotSupportedError", "a PBKDF2 key is not exported");
  const derived = await subtle.deriveKey(alg, password, { name: "AES-GCM", length: 256 }, true, ["encrypt"]);
  eq((await subtle.exportKey("raw", derived)).byteLength, 32, "deriveKey");
  eq(derived.algorithm.length, 256, "the derived key's length");
  const ikm = await subtle.importKey("raw", fill(22, 0x0b), "HKDF", false, ["deriveBits", "deriveKey"]);
  const hkdf = { name: "HKDF", hash: "SHA-256", salt: counting(13), info: hex("f0f1f2f3f4f5f6f7f8f9") };
  eq(toHex(await subtle.deriveBits(hkdf, ikm, 336)), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", "HKDF");
  await rejects(subtle.deriveBits(hkdf, ikm, 256 * 8 * 32), "OperationError", "more than HKDF can give");
  eq((await subtle.deriveBits(hkdf, ikm, 0)).byteLength, 0, "zero bits");
  const hmac = await subtle.deriveKey(hkdf, ikm, { name: "HMAC", hash: "SHA-256" }, true, ["sign"]);
  eq(hmac.algorithm.length, 512, "an HMAC key derived, of a block");
});

test("ECDSA", async () => {
  for (const [curve, size, hash] of [["P-256", 32, "SHA-256"], ["P-384", 48, "SHA-384"]]) {
    const pair = await subtle.generateKey({ name: "ECDSA", namedCurve: curve }, true, ["sign", "verify"]);
    eq(pair.publicKey.type, "public", `${curve}: the public key`);
    eq(pair.publicKey.extractable, true, `${curve}: a public key is extractable`);
    eq(pair.publicKey.usages.join(), "verify", `${curve}: its usages`);
    eq(pair.privateKey.type, "private", `${curve}: the private key`);
    eq(pair.privateKey.usages.join(), "sign", `${curve}: its usages`);
    const sig = await subtle.sign({ name: "ECDSA", hash }, pair.privateKey, utf8("message"));
    eq(sig.byteLength, size * 2, `${curve}: r and s`);
    eq(await subtle.verify({ name: "ECDSA", hash }, pair.publicKey, sig, utf8("message")), true, `${curve}: verify`);
    eq(await subtle.verify({ name: "ECDSA", hash }, pair.publicKey, sig, utf8("massage")), false, `${curve}: verify of something else`);
    await rejects(subtle.sign({ name: "ECDSA", hash }, pair.publicKey, utf8("m")), "InvalidAccessError", `${curve}: signing with a public key`);
    for (const format of ["raw", "spki"]) {
      const out = await subtle.exportKey(format, pair.publicKey);
      const back = await subtle.importKey(format, out, { name: "ECDSA", namedCurve: curve }, true, ["verify"]);
      eq(await subtle.verify({ name: "ECDSA", hash }, back, sig, utf8("message")), true, `${curve}: public key through ${format}`);
      eq(toHex(await subtle.exportKey(format, back)), toHex(out), `${curve}: ${format} round trip`);
    }
    const pkcs8 = await subtle.exportKey("pkcs8", pair.privateKey);
    const back = await subtle.importKey("pkcs8", pkcs8, { name: "ECDSA", namedCurve: curve }, true, ["sign"]);
    eq(toHex(await subtle.exportKey("pkcs8", back)), toHex(pkcs8), `${curve}: pkcs8 round trip`);
    const jwk = await subtle.exportKey("jwk", pair.privateKey);
    eq(jwk.kty, "EC", `${curve}: jwk kty`);
    eq(jwk.crv, curve, `${curve}: jwk crv`);
    eq(jwk.ext, true, `${curve}: jwk ext`);
    const fromJwk = await subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: curve }, true, ["sign"]);
    eq(toHex(await subtle.exportKey("pkcs8", fromJwk)), toHex(pkcs8), `${curve}: jwk round trip`);
    const bad = await subtle.exportKey("raw", pair.publicKey);
    new Uint8Array(bad)[size] ^= 1;
    await rejects(subtle.importKey("raw", bad, { name: "ECDSA", namedCurve: curve }, true, ["verify"]), "DataError", `${curve}: a point not on the curve`);
    await rejects(subtle.exportKey("raw", pair.privateKey), "InvalidAccessError", `${curve}: raw is for public keys`);
    await rejects(subtle.exportKey("spki", pair.privateKey), "InvalidAccessError", `${curve}: spki is for public keys`);
    await rejects(subtle.exportKey("pkcs8", pair.publicKey), "InvalidAccessError", `${curve}: pkcs8 is for private keys`);
  }
  await rejects(subtle.generateKey({ name: "ECDSA", namedCurve: "P-521" }, true, ["sign"]), "NotSupportedError", "P-521 is not there");
  await rejects(subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["encrypt"]), "SyntaxError", "a usage of no ECDSA key");
  await rejects(subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]), "SyntaxError", "no usage left for the private key");
});

test("ECDH", async () => {
  const alg = { name: "ECDH", namedCurve: "P-256" };
  const a = await subtle.generateKey(alg, true, ["deriveBits", "deriveKey"]);
  const b = await subtle.generateKey(alg, true, ["deriveBits"]);
  eq(a.publicKey.usages.length, 0, "an ECDH public key has no usages");
  const s1 = await subtle.deriveBits({ name: "ECDH", public: b.publicKey }, a.privateKey, 256);
  const s2 = await subtle.deriveBits({ name: "ECDH", public: a.publicKey }, b.privateKey, 256);
  eq(s1.byteLength, 32, "the secret");
  eq(toHex(s1), toHex(s2), "both sides have it");
  eq((await subtle.deriveBits({ name: "ECDH", public: b.publicKey }, a.privateKey)).byteLength, 32, "without a length: all of it");
  const short = await subtle.deriveBits({ name: "ECDH", public: b.publicKey }, a.privateKey, 12);
  eq(short.byteLength, 2, "12 bits in 2 bytes");
  eq(new Uint8Array(short)[1] & 15, 0, "the rest of the last byte is zero");
  await rejects(subtle.deriveBits({ name: "ECDH", public: b.publicKey }, a.privateKey, 264), "OperationError", "more bits than the secret");
  await rejects(subtle.deriveBits({ name: "ECDH", public: a.privateKey }, b.privateKey, 256), "InvalidAccessError", "a private key as the public one");
  await rejects(subtle.deriveBits({ name: "ECDH" }, a.privateKey, 256), "TypeError", "no public key");
  const c = await subtle.generateKey({ name: "ECDH", namedCurve: "P-384" }, true, ["deriveBits"]);
  await rejects(subtle.deriveBits({ name: "ECDH", public: c.publicKey }, a.privateKey, 256), "InvalidAccessError", "a key of another curve");
  const key = await subtle.deriveKey({ name: "ECDH", public: b.publicKey }, a.privateKey, { name: "AES-GCM", length: 256 }, true, ["encrypt"]);
  eq(toHex(await subtle.exportKey("raw", key)), toHex(s1), "deriveKey");
});

test("RSA", async () => {
  const hash = "SHA-256";
  const exponent = new Uint8Array([1, 0, 1]);
  const pss = await subtle.generateKey({ name: "RSA-PSS", modulusLength: 2048, publicExponent: exponent, hash }, true, ["sign", "verify"]);
  eq(pss.publicKey.algorithm.modulusLength, 2048, "modulusLength");
  eq(toHex(pss.publicKey.algorithm.publicExponent), "010001", "publicExponent");
  eq(pss.publicKey.algorithm.hash.name, hash, "hash");
  const sig = await subtle.sign({ name: "RSA-PSS", saltLength: 32 }, pss.privateKey, utf8("message"));
  eq(sig.byteLength, 256, "a signature of PSS");
  eq(await subtle.verify({ name: "RSA-PSS", saltLength: 32 }, pss.publicKey, sig, utf8("message")), true, "PSS verify");
  eq(await subtle.verify({ name: "RSA-PSS", saltLength: 32 }, pss.publicKey, sig, utf8("massage")), false, "PSS verify of something else");
  eq(await subtle.verify({ name: "RSA-PSS", saltLength: 20 }, pss.publicKey, sig, utf8("message")), false, "PSS verify with another salt size");
  await rejects(subtle.sign({ name: "RSA-PSS", saltLength: 512 }, pss.privateKey, utf8("m")), "OperationError", "a salt too large");
  // the same material under other algorithms, by each format
  const spki = await subtle.exportKey("spki", pss.publicKey);
  const pkcs8 = await subtle.exportKey("pkcs8", pss.privateKey);
  const jwkPrivate = await subtle.exportKey("jwk", pss.privateKey);
  const jwkPublic = await subtle.exportKey("jwk", pss.publicKey);
  eq(jwkPrivate.kty, "RSA", "jwk kty");
  eq(jwkPrivate.alg, "PS256", "jwk alg");
  eq(jwkPublic.e, "AQAB", "jwk e");
  eq(jwkPublic.d, undefined, "a public jwk has no d");
  const pkcs1 = { name: "RSASSA-PKCS1-v1_5", hash };
  const signer = await subtle.importKey("pkcs8", pkcs8, pkcs1, true, ["sign"]);
  const verifier = await subtle.importKey("spki", spki, pkcs1, true, ["verify"]);
  eq(verifier.algorithm.modulusLength, 2048, "an imported key's modulusLength");
  eq(toHex(await subtle.exportKey("pkcs8", signer)), toHex(pkcs8), "pkcs8 round trip");
  eq(toHex(await subtle.exportKey("spki", verifier)), toHex(spki), "spki round trip");
  const s = await subtle.sign("RSASSA-PKCS1-v1_5", signer, utf8("message"));
  eq(toHex(s), toHex(await subtle.sign("RSASSA-PKCS1-v1_5", signer, utf8("message"))), "PKCS#1 v1.5 is deterministic");
  eq(await subtle.verify("RSASSA-PKCS1-v1_5", verifier, s, utf8("message")), true, "PKCS#1 v1.5 verify");
  eq(await subtle.verify("RSASSA-PKCS1-v1_5", verifier, s.slice(1), utf8("message")), false, "PKCS#1 v1.5 verify of a short signature");
  const oaep = { name: "RSA-OAEP", hash };
  const decrypter = await subtle.importKey("jwk", { ...jwkPrivate, alg: "RSA-OAEP-256", key_ops: ["decrypt", "unwrapKey"] }, oaep, true, ["decrypt", "unwrapKey"]);
  const encrypter = await subtle.importKey("jwk", { ...jwkPublic, alg: "RSA-OAEP-256", key_ops: ["encrypt", "wrapKey"] }, oaep, true, ["encrypt", "wrapKey"]);
  const label = utf8("label");
  const c = await subtle.encrypt({ name: "RSA-OAEP", label }, encrypter, utf8("secret"));
  eq(c.byteLength, 256, "a ciphertext of OAEP");
  eq(toHex(await subtle.decrypt({ name: "RSA-OAEP", label }, decrypter, c)), toHex(utf8("secret")), "OAEP decrypt");
  await rejects(subtle.decrypt({ name: "RSA-OAEP" }, decrypter, c), "OperationError", "OAEP with another label");
  await rejects(subtle.encrypt("RSA-OAEP", encrypter, new Uint8Array(256 - 64)), "OperationError", "OAEP: too much for the key");
  await rejects(subtle.encrypt("RSA-OAEP", decrypter, utf8("x")), "InvalidAccessError", "OAEP encrypts with a public key");
  const aes = await subtle.generateKey({ name: "AES-GCM", length: 128 }, true, ["encrypt"]);
  const wrapped = await subtle.wrapKey("raw", aes, encrypter, "RSA-OAEP");
  const back = await subtle.unwrapKey("raw", wrapped, decrypter, "RSA-OAEP", "AES-GCM", true, ["encrypt"]);
  eq(toHex(await subtle.exportKey("raw", back)), toHex(await subtle.exportKey("raw", aes)), "a key wrapped with OAEP");
  await rejects(subtle.generateKey({ name: "RSA-PSS", modulusLength: 2048, publicExponent: new Uint8Array([3]), hash }, true, ["sign"]), "OperationError", "another exponent");
  await rejects(subtle.generateKey({ name: "RSA-PSS", modulusLength: 2048, publicExponent: [1, 0, 1], hash }, true, ["sign"]), "TypeError", "an exponent that is not a Uint8Array");
  await rejects(subtle.importKey("spki", new Uint8Array(40), pkcs1, true, ["verify"]), "DataError", "spki that is not DER");
  await rejects(subtle.importKey("pkcs8", pkcs8.slice(1), pkcs1, true, ["sign"]), "DataError", "pkcs8 cut short");
});

test("Ed25519 (RFC 8032), X25519 (RFC 7748)", async () => {
  const seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
  const pub = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
  const jwk = { kty: "OKP", crv: "Ed25519", d: b64url(seed), x: b64url(pub) };
  const key = await subtle.importKey("jwk", jwk, "Ed25519", true, ["sign"]);
  const signature = await subtle.sign("Ed25519", key, new Uint8Array(0));
  eq(toHex(signature), "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b", "the signature");
  const verifier = await subtle.importKey("raw", pub, "Ed25519", true, ["verify"]);
  eq(await subtle.verify("Ed25519", verifier, signature, new Uint8Array(0)), true, "verify");
  eq(await subtle.verify("Ed25519", verifier, signature, new Uint8Array(1)), false, "verify of something else");
  eq(toHex(await subtle.exportKey("raw", verifier)), toHex(pub), "raw");
  const pkcs8 = await subtle.exportKey("pkcs8", key);
  eq(toHex(pkcs8), "302e020100300506032b657004220420" + toHex(seed), "pkcs8");
  const pair = await subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  const s2 = await subtle.sign("Ed25519", pair.privateKey, utf8("m"));
  eq(await subtle.verify("Ed25519", pair.publicKey, s2, utf8("m")), true, "a key generated");
  await rejects(subtle.importKey("jwk", { ...jwk, x: b64url(new Uint8Array(32)) }, "Ed25519", true, ["sign"]), "DataError", "x that is not of d");
  const alice = await subtle.importKey("jwk", {
    kty: "OKP", crv: "X25519",
    d: b64url(hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")),
    x: b64url(hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")),
  }, "X25519", true, ["deriveBits"]);
  const bob = await subtle.importKey("raw", hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"), "X25519", true, []);
  eq(toHex(await subtle.deriveBits({ name: "X25519", public: bob }, alice, 256)), "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742", "the shared secret");
  const zero = await subtle.importKey("raw", new Uint8Array(32), "X25519", true, []);
  await rejects(subtle.deriveBits({ name: "X25519", public: zero }, alice, 256), "OperationError", "a public value of small order");
});

test("the rules", async () => {
  const key = await subtle.generateKey({ name: "AES-CBC", length: 128 }, false, ["encrypt"]);
  const iv = new Uint8Array(16);
  await rejects(subtle.exportKey("raw", key), "InvalidAccessError", "a key that is not extractable is not exported");
  await rejects(subtle.exportKey("jwk", key), "InvalidAccessError", "nor as a jwk");
  await rejects(subtle.decrypt({ name: "AES-CBC", iv }, key, new Uint8Array(16)), "InvalidAccessError", "a usage the key does not have");
  await rejects(subtle.encrypt({ name: "AES-CTR", counter: iv, length: 64 }, key, new Uint8Array(1)), "InvalidAccessError", "another algorithm than the key's");
  await rejects(subtle.encrypt("nope", key, new Uint8Array(1)), "NotSupportedError", "an unknown algorithm");
  await rejects(subtle.encrypt({}, key, new Uint8Array(1)), "TypeError", "an algorithm without a name");
  await rejects(subtle.encrypt({ name: "AES-CBC" }, key, new Uint8Array(1)), "TypeError", "without its iv");
  await rejects(subtle.encrypt({ name: "AES-CBC", iv: [] }, key, new Uint8Array(1)), "TypeError", "an iv that is no buffer");
  await rejects(subtle.encrypt({ name: "AES-CBC", iv }, {}, new Uint8Array(1)), "TypeError", "a key that is no CryptoKey");
  await rejects(subtle.encrypt({ name: "AES-CBC", iv }, key), "TypeError", "a missing argument");
  await rejects(subtle.encrypt({ name: "AES-CBC", iv }, key, "text"), "TypeError", "data that is no buffer");
  await rejects(subtle.importKey("nope", new Uint8Array(16), "AES-CBC", true, ["encrypt"]), "TypeError", "an unknown format");
  await rejects(subtle.importKey("raw", new Uint8Array(16), "AES-CBC", true, ["nope"]), "TypeError", "an unknown usage");
  await rejects(subtle.importKey("raw", new Uint8Array(16), "AES-CBC", true, ["sign"]), "SyntaxError", "a usage of no AES key");
  await rejects(subtle.importKey("raw", new Uint8Array(16), "AES-CBC", true, []), "SyntaxError", "a secret key without usages");
  await rejects(subtle.importKey("raw", new Uint8Array(15), "AES-CBC", true, ["encrypt"]), "DataError", "a key of the wrong size");
  await rejects(subtle.importKey("raw", {}, "AES-CBC", true, ["encrypt"]), "TypeError", "raw with no buffer");
  await rejects(subtle.importKey("jwk", new Uint8Array(16), "AES-CBC", true, ["encrypt"]), "TypeError", "jwk with a buffer");
  await rejects(subtle.importKey("spki", new Uint8Array(16), "AES-CBC", true, ["encrypt"]), "NotSupportedError", "a format AES does not have");
  await rejects(subtle.generateKey({ name: "AES-CBC", length: 100 }, true, ["encrypt"]), "OperationError", "an AES length that does not exist");
  const k = b64url(new Uint8Array(16));
  const jwk = { kty: "oct", k, alg: "A128CBC" };
  ok(await subtle.importKey("jwk", jwk, "AES-CBC", true, ["encrypt"]), "a jwk");
  await rejects(subtle.importKey("jwk", { ...jwk, kty: "EC" }, "AES-CBC", true, ["encrypt"]), "DataError", "a jwk of another kty");
  await rejects(subtle.importKey("jwk", { ...jwk, alg: "A256CBC" }, "AES-CBC", true, ["encrypt"]), "DataError", "a jwk of another alg");
  await rejects(subtle.importKey("jwk", { ...jwk, use: "sig" }, "AES-CBC", true, ["encrypt"]), "DataError", "a jwk of another use");
  await rejects(subtle.importKey("jwk", { ...jwk, ext: false }, "AES-CBC", true, ["encrypt"]), "DataError", "a jwk that says it is not extractable");
  await rejects(subtle.importKey("jwk", { ...jwk, key_ops: ["decrypt"] }, "AES-CBC", true, ["encrypt"]), "DataError", "a jwk without the usage");
  await rejects(subtle.importKey("jwk", { ...jwk, k: "!!!" }, "AES-CBC", true, ["encrypt"]), "DataError", "a jwk that is not base64url");
  await rejects(subtle.importKey("jwk", { kty: "oct" }, "AES-CBC", true, ["encrypt"]), "DataError", "a jwk without its key");
  ok(subtle.encrypt({ name: "AES-CBC", iv }, key, new Uint8Array(1)) instanceof Promise, "an operation gives a promise");
  const f = subtle.encrypt;
  await rejects(f.call({}, { name: "AES-CBC", iv }, key, new Uint8Array(1)), "TypeError", "on something that is no SubtleCrypto");
});

test("keys that travel", async () => {
  const digest = await subtle.digest("SHA-256", new Uint8Array(1));
  eq(digest.resizable, false, "a buffer from the browser is not resizable");
  eq(structuredClone(digest).byteLength, 32, "and is cloned");
  const key =await subtle.generateKey({ name: "HMAC", hash: "SHA-512", length: 512 }, false, ["sign", "verify"]);
  const copy = structuredClone(key);
  ok(copy !== key && copy instanceof CryptoKey, "structuredClone makes another key");
  eq(copy.extractable, false, "as extractable as it was");
  eq(copy.algorithm.hash.name, "SHA-512", "of the same algorithm");
  eq(copy.usages.join(), "sign,verify", "with the same usages");
  await rejects(subtle.exportKey("raw", copy), "InvalidAccessError", "a clone does not become extractable");
  const mac = await subtle.sign("HMAC", copy, utf8("m"));
  eq(await subtle.verify("HMAC", key, mac, utf8("m")), true, "and the same material");
  const shared = { a: key, b: key };
  const both = structuredClone(shared);
  eq(both.a, both.b, "one key twice stays one key");
  const pair = await subtle.generateKey({ name: "RSA-OAEP", modulusLength: 1024, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-1" }, false, ["encrypt", "decrypt"]);
  const clones = structuredClone(pair);
  const c = await subtle.encrypt("RSA-OAEP", clones.publicKey, utf8("hi"));
  eq(toHex(await subtle.decrypt("RSA-OAEP", clones.privateKey, c)), toHex(utf8("hi")), "an RSA pair");
  eq(toHex(clones.publicKey.algorithm.publicExponent), "010001", "with its exponent");
  // a worker has all of it, and takes keys in messages
  const worker = new Worker("/jsweb/js/webcrypto_worker_script.js");
  const answer = new Promise(resolve => { worker.onmessage = e => resolve(e.data); worker.onerror = e => resolve("error: " + e.message); });
  const aes = await subtle.importKey("raw", new Uint8Array(16), "AES-GCM", false, ["encrypt", "decrypt"]);
  worker.postMessage({ key: aes, iv: new Uint8Array(12) });
  const r = await answer;
  eq(typeof r === "object" && r.ok, true, "a worker: " + (typeof r === "string" ? r : r.detail));
  eq(toHex(r.tag), "58e2fccefa7e3061367f1d57a4e7455a", "a worker encrypts with the key it was sent");
  eq(toHex(await subtle.decrypt({ name: "AES-GCM", iv: new Uint8Array(12) }, r.key, r.tag)), "", "a key a worker sends back");
  worker.terminate();
  // in IndexedDB
  const db = await new Promise((resolve, reject) => {
    const open = indexedDB.open("webcrypto_keys", 1);
    open.onupgradeneeded = () => open.result.createObjectStore("keys");
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => reject(open.error);
  });
  await new Promise((resolve, reject) => {
    const tx = db.transaction("keys", "readwrite");
    tx.objectStore("keys").put(key, "hmac");
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
  const stored = await new Promise((resolve, reject) => {
    const get = db.transaction("keys").objectStore("keys").get("hmac");
    get.onsuccess = () => resolve(get.result);
    get.onerror = () => reject(get.error);
  });
  ok(stored instanceof CryptoKey, "a key comes back from IndexedDB");
  eq(await subtle.verify("HMAC", stored, mac, utf8("m")), true, "with its material");
  db.close();
});

test("heavy work does not stop the page", async () => {
  // PBKDF2 and a key of RSA on another thread: the page's tasks run meanwhile
  const password = await subtle.importKey("raw", utf8("p"), "PBKDF2", false, ["deriveBits"]);
  let ticks = 0, running = true;
  const tick = () => new Promise(resolve => { AbortSignal.timeout(1).onabort = resolve; });
  const ticking = (async () => { while (running) { await tick(); ticks++; } })();
  await subtle.deriveBits({ name: "PBKDF2", hash: "SHA-512", salt: utf8("s"), iterations: 1000000 }, password, 256);
  running = false;
  await ticking;
  ok(ticks > 0, "tasks ran during PBKDF2 of a million iterations");
});

__run();
