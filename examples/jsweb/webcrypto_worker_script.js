// The worker of webcrypto.js: crypto.subtle in a worker, with a key sent by the page, and a key sent back.
onmessage = async e => {
  try {
    const { key, iv } = e.data;
    const tag = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new Uint8Array(0));
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new Uint8Array(1));
    const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, sig, new Uint8Array(1));
    const password = await crypto.subtle.importKey("raw", new Uint8Array(4), "PBKDF2", false, ["deriveBits"]);
    const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(4), iterations: 1000 }, password, 256);
    postMessage({ ok: valid && key instanceof CryptoKey && bits.byteLength === 32, detail: "crypto.subtle", tag, key });
  } catch (err) {
    postMessage({ ok: false, detail: `${err.name}: ${err.message}` });
  }
};
