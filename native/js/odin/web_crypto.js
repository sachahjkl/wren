// The operations of SubtleCrypto (https://w3c.github.io/webcrypto/) over the natives of web_crypto.odin, run the first time
// a realm asks for one: the conversions of WebIDL, the normalization of algorithms, usages and error names, JSON Web
// Keys. The computations and the material of the keys are in the browser (src/page/bindings_crypto_subtle.odin). What it
// uses of the realm is taken here, so what the page replaces later does not reach it.
(function (native) {
  "use strict";
  const { apply } = Reflect;
  const U8 = Uint8Array, TE = TypeError, N = Number, JSONparse = JSON.parse, JSONstringify = JSON.stringify;
  const ArrayIsArray = Array.isArray;
  const toUpper = String.prototype.toUpperCase, charCodeAt = String.prototype.charCodeAt;
  const u8Slice = U8.prototype.slice, u8Set = U8.prototype.set, push = Array.prototype.push;
  const isFinite_ = isFinite, trunc = Math.trunc, iterator = Symbol.iterator;
  const typedArrayTag = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(U8.prototype), Symbol.toStringTag).get;

  const isObject = v => (typeof v === "object" && v !== null) || typeof v === "function";
  const dom = (name, message) => native.dom(name, message);
  const EMPTY = new U8(0);
  const upper = s => apply(toUpper, s, []);
  const has = (list, x) => {
    for (let i = 0; i < list.length; i++) if (list[i] === x) return true;
    return false;
  };

  // ---- WebIDL ----

  const need = (given, count, what) => {
    if (given < count) throw new TE(`Failed to execute '${what}' on 'SubtleCrypto': ${count} arguments required, but only ${given} present.`);
  };
  const domString = v => {
    if (typeof v === "symbol") throw new TE("Cannot convert a Symbol to a string");
    return `${v}`;
  };
  // [EnforceRange] of an integer type
  const enforced = (v, maximum, what) => {
    const n = N(v);
    if (!isFinite_(n)) throw new TE(`${what} is not a finite number`);
    const t = trunc(n);
    if (t < 0 || t > maximum) throw new TE(`${what} is out of range`);
    return t + 0;
  };
  // A copy of a BufferSource's bytes (TypeError for anything else).
  const bytes = v => new U8(native.copy(v));
  // The conversion of an argument of type BufferSource. Its bytes are copied after the algorithm's normalization, which can run a
  // script's getters: the specification says so.
  const bufferSource = (v, what) => {
    if (!native.isBuffer(v)) throw new TE(`${what} is not of type 'BufferSource'`);
    return v;
  };
  const sequence = (v, what) => {
    if (!isObject(v)) throw new TE(`${what} is not a sequence`);
    const method = v[iterator];
    if (method === undefined || method === null) throw new TE(`${what} is not iterable`);
    const it = apply(method, v, []);
    if (!isObject(it)) throw new TE(`${what}: the iterator is not an object`);
    const next = it.next, out = [];
    for (;;) {
      const r = apply(next, it, []);
      if (!isObject(r)) throw new TE(`${what}: the iterator result is not an object`);
      if (r.done) return out;
      apply(push, out, [r.value]);
    }
  };
  // (the enum has those of the key encapsulation algorithms too: none of the keys here allows them, a SyntaxError and not a TypeError)
  const USAGE_NAMES = ["encrypt", "decrypt", "sign", "verify", "deriveKey", "deriveBits", "wrapKey", "unwrapKey", "encapsulateKey", "encapsulateBits", "decapsulateKey", "decapsulateBits"];
  // sequence<KeyUsage>, without repetitions
  const usagesOf = v => {
    const given = sequence(v, "keyUsages"), out = [];
    for (let i = 0; i < given.length; i++) {
      const u = domString(given[i]);
      if (!has(USAGE_NAMES, u)) throw new TE(`'${u}' is not a valid KeyUsage`);
      if (!has(out, u)) apply(push, out, [u]);
    }
    return out;
  };
  const FORMATS = ["raw", "spki", "pkcs8", "jwk"];
  const formatOf = v => {
    const f = domString(v);
    if (!has(FORMATS, f)) throw new TE(`'${f}' is not a valid KeyFormat`);
    return f;
  };

  // ---- algorithms ----

  const AES = ["AES-CTR", "AES-CBC", "AES-GCM", "AES-KW"];
  const RSA = ["RSASSA-PKCS1-v1_5", "RSA-PSS", "RSA-OAEP"];
  const HASH = ["hash", "hash", true];
  const CIPHERS = {
    "RSA-OAEP": [["label", "bytes"]],
    "AES-CTR": [["counter", "bytes", true], ["length", "octet", true]],
    "AES-CBC": [["iv", "bytes", true]],
    "AES-GCM": [["additionalData", "bytes"], ["iv", "bytes", true], ["tagLength", "octet"]],
  };
  const SIGNATURES = {
    "RSASSA-PKCS1-v1_5": [],
    "RSA-PSS": [["saltLength", "ulong", true]],
    "ECDSA": [HASH],
    "Ed25519": [],
    "HMAC": [],
  };
  const RSA_GENERATE = [HASH, ["modulusLength", "ulong", true], ["publicExponent", "bigInteger", true]];
  const CURVE = [["namedCurve", "string", true]];
  const AES_LENGTH = [["length", "ushort", true]];
  const HMAC_PARAMS = [HASH, ["length", "ulong"]];
  const AGREEMENT = [["public", "key", true]];
  const REGISTRY = {
    encrypt: CIPHERS,
    decrypt: CIPHERS,
    sign: SIGNATURES,
    verify: SIGNATURES,
    digest: { "SHA-1": [], "SHA-256": [], "SHA-384": [], "SHA-512": [] },
    generateKey: {
      "RSASSA-PKCS1-v1_5": RSA_GENERATE, "RSA-PSS": RSA_GENERATE, "RSA-OAEP": RSA_GENERATE,
      "ECDSA": CURVE, "ECDH": CURVE, "Ed25519": [], "X25519": [],
      "AES-CTR": AES_LENGTH, "AES-CBC": AES_LENGTH, "AES-GCM": AES_LENGTH, "AES-KW": AES_LENGTH,
      "HMAC": HMAC_PARAMS,
    },
    importKey: {
      "RSASSA-PKCS1-v1_5": [HASH], "RSA-PSS": [HASH], "RSA-OAEP": [HASH],
      "ECDSA": CURVE, "ECDH": CURVE, "Ed25519": [], "X25519": [],
      "AES-CTR": [], "AES-CBC": [], "AES-GCM": [], "AES-KW": [],
      "HMAC": HMAC_PARAMS, "HKDF": [], "PBKDF2": [],
    },
    deriveBits: {
      "ECDH": AGREEMENT, "X25519": AGREEMENT,
      "HKDF": [HASH, ["info", "bytes", true], ["salt", "bytes", true]],
      "PBKDF2": [HASH, ["iterations", "ulong", true], ["salt", "bytes", true]],
    },
    keyLength: {
      "AES-CTR": AES_LENGTH, "AES-CBC": AES_LENGTH, "AES-GCM": AES_LENGTH, "AES-KW": AES_LENGTH,
      "HMAC": HMAC_PARAMS, "HKDF": [], "PBKDF2": [],
    },
    wrapKey: { "AES-KW": [] },
    unwrapKey: { "AES-KW": [] },
  };
  // the names of a table in upper case
  const NAMES = {};
  for (const op in REGISTRY) {
    NAMES[op] = { __proto__: null };
    for (const name in REGISTRY[op]) NAMES[op][upper(name)] = name;
  }

  const member = (dict, name, type, what) => {
    const v = dict[name];
    if (v === undefined) return undefined;
    switch (type) {
      case "bytes": return bytes(v);
      case "hash": return normalize("digest", v);
      case "octet": return enforced(v, 0xFF, what);
      case "ushort": return enforced(v, 0xFFFF, what);
      case "ulong": return enforced(v, 0xFFFFFFFF, what);
      case "string": return domString(v);
      case "key":
        if (native.keyState(v) === undefined) throw new TE(`${what} is not of type 'CryptoKey'`);
        return v;
      case "bigInteger":
        // (a Uint8Array: its bytes)
        try { if (apply(typedArrayTag, v, []) !== "Uint8Array") throw 0; } catch (e) { throw new TE(`${what} is not of type 'Uint8Array'`); }
        return bytes(v);
    }
  };

  // "normalize an algorithm": a new object of the members of its dictionary, its name the registered one.
  const normalize = (op, algorithm) => {
    const dict = isObject(algorithm) ? algorithm : { name: domString(algorithm) };
    const given = dict.name;
    if (given === undefined) throw new TE("Algorithm: name is missing");
    const name = NAMES[op][upper(domString(given))];
    if (name === undefined) throw dom("NotSupportedError", `Algorithm: Unrecognized name for this operation: ${domString(given)}`);
    const out = { __proto__: null, name };
    const members = REGISTRY[op][name];
    for (let i = 0; i < members.length; i++) {
      const m = members[i], what = `Algorithm: ${m[0]}`;
      const v = member(dict, m[0], m[1], what);
      if (v === undefined && m[2]) throw new TE(`${what} is missing`);
      out[m[0]] = v;
    }
    return out;
  };

  const expect = (st, name, usage) => {
    if (st.alg.name !== name) throw dom("InvalidAccessError", `The key is not of the algorithm ${name}`);
    if (!has(st.list, usage)) throw dom("InvalidAccessError", `The key does not permit the usage ${usage}`);
  };
  const stateOf = (key, what) => {
    const st = native.keyState(key);
    if (st === undefined) throw new TE(`${what} is not of type 'CryptoKey'`);
    return st;
  };

  // ---- keys ----

  const exposedAlgorithm = alg => {
    const out = { name: alg.name };
    if (alg.length !== undefined) out.length = alg.length;
    if (alg.namedCurve !== undefined) out.namedCurve = alg.namedCurve;
    if (alg.modulusLength !== undefined) {
      out.modulusLength = alg.modulusLength;
      out.publicExponent = apply(u8Slice, alg.publicExponent, []);
    }
    if (alg.hash !== undefined) out.hash = { name: alg.hash.name };
    return out;
  };
  const stateNew = (data, type, extractable, alg, list) => {
    const usages = [];
    for (let i = 0; i < list.length; i++) usages[i] = list[i];
    return { __proto__: null, data, type, extractable, alg, list, algorithm: exposedAlgorithm(alg), usages };
  };
  const keyNew = (data, type, extractable, alg, list) => native.keyNew(stateNew(data, type, extractable, alg, list));

  const allowedOnly = (list, allowed) => {
    for (let i = 0; i < list.length; i++) {
      if (!has(allowed, list[i])) throw dom("SyntaxError", `The usage ${list[i]} is not valid for this key`);
    }
  };
  const both = (list, allowed) => {
    const out = [];
    for (let i = 0; i < list.length; i++) if (has(allowed, list[i])) apply(push, out, [list[i]]);
    return out;
  };
  const SECRET_KEY_USAGES = {
    "AES-CTR": ["encrypt", "decrypt", "wrapKey", "unwrapKey"], "AES-CBC": ["encrypt", "decrypt", "wrapKey", "unwrapKey"],
    "AES-GCM": ["encrypt", "decrypt", "wrapKey", "unwrapKey"], "AES-KW": ["wrapKey", "unwrapKey"],
    "HMAC": ["sign", "verify"], "HKDF": ["deriveKey", "deriveBits"], "PBKDF2": ["deriveKey", "deriveBits"],
  };
  // [public, private]
  const PAIR_USAGES = {
    "RSASSA-PKCS1-v1_5": [["verify"], ["sign"]], "RSA-PSS": [["verify"], ["sign"]], "ECDSA": [["verify"], ["sign"]],
    "Ed25519": [["verify"], ["sign"]], "RSA-OAEP": [["encrypt", "wrapKey"], ["decrypt", "unwrapKey"]],
    "ECDH": [[], ["deriveKey", "deriveBits"]], "X25519": [[], ["deriveKey", "deriveBits"]],
  };
  const NATIVE_CURVES = ["P-256", "P-384", "P-521"];
  const curveOf = name => {
    if (!has(NATIVE_CURVES, name)) throw dom("NotSupportedError", `The curve ${name} is not supported`);
    return name;
  };
  const curveSize = curve => (curve === "P-256" ? 32 : (curve === "P-384" ? 48 : 66));
  const HASH_BLOCK_BITS = { "SHA-1": 512, "SHA-256": 512, "SHA-384": 1024, "SHA-512": 1024 };

  const ensureUsages = (type, list) => {
    if ((type === "secret" || type === "private") && list.length === 0) throw dom("SyntaxError", "A secret or private key must have usages");
  };

  const generate = async (alg, extractable, usages) => {
    const name = alg.name;
    if (has(AES, name)) {
      allowedOnly(usages, SECRET_KEY_USAGES[name]);
      if (alg.length !== 128 && alg.length !== 192 && alg.length !== 256) throw dom("OperationError", "AES key length must be 128, 192 or 256 bits");
      ensureUsages("secret", usages);
      return keyNew(await native.generate("secret", alg.length, extractable), "secret", extractable, { __proto__: null, name, length: alg.length }, usages);
    }
    if (name === "HMAC") {
      allowedOnly(usages, SECRET_KEY_USAGES.HMAC);
      const length = alg.length === undefined ? HASH_BLOCK_BITS[alg.hash.name] : alg.length;
      if (length === 0 || length > 0x7FFFFFFF) throw dom("OperationError", "HMAC key length is not valid");
      ensureUsages("secret", usages);
      return keyNew(await native.generate("secret", length, extractable), "secret", extractable, { __proto__: null, name, length, hash: alg.hash }, usages);
    }
    const publicUsages = PAIR_USAGES[name][0], privateUsages = PAIR_USAGES[name][1];
    const allowed = [];
    for (let i = 0; i < publicUsages.length; i++) allowed[allowed.length] = publicUsages[i];
    for (let i = 0; i < privateUsages.length; i++) allowed[allowed.length] = privateUsages[i];
    allowedOnly(usages, allowed);
    let kind, keyAlg;
    if (has(RSA, name)) {
      const e = alg.publicExponent;
      let start = 0;
      while (start < e.length && e[start] === 0) start++;
      if (e.length - start !== 3 || e[start] !== 1 || e[start + 1] !== 0 || e[start + 2] !== 1) throw dom("OperationError", "The public exponent must be 65537");
      if (alg.modulusLength % 8 !== 0 || alg.modulusLength < 1024 || alg.modulusLength > 4096) throw dom("OperationError", "The modulus length must be a multiple of 8 from 1024 to 4096 bits");
      kind = "RSA";
      keyAlg = { __proto__: null, name, hash: alg.hash, modulusLength: alg.modulusLength, publicExponent: new U8([1, 0, 1]) };
    } else if (name === "ECDSA" || name === "ECDH") {
      kind = curveOf(alg.namedCurve);
      keyAlg = { __proto__: null, name, namedCurve: alg.namedCurve };
    } else {
      kind = name;
      keyAlg = { __proto__: null, name };
    }
    const privateList = both(usages, privateUsages);
    ensureUsages("private", privateList);
    const data = await native.generate(kind, kind === "RSA" ? alg.modulusLength : 0, extractable);
    return {
      publicKey: keyNew(native.publicOf(data), "public", true, keyAlg, both(usages, publicUsages)),
      privateKey: keyNew(data, "private", extractable, keyAlg, privateList),
    };
  };

  // ---- JSON Web Key ----

  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  const B64_VALUES = { __proto__: null };
  for (let i = 0; i < 64; i++) B64_VALUES[apply(charCodeAt, B64, [i])] = i;
  const base64url = data => {
    const b = new U8(data);
    let s = "";
    for (let i = 0; i < b.length; i += 3) {
      const n = b[i] << 16 | (i + 1 < b.length ? b[i + 1] << 8 : 0) | (i + 2 < b.length ? b[i + 2] : 0);
      s += B64[n >> 18] + B64[n >> 12 & 63];
      if (i + 1 < b.length) s += B64[n >> 6 & 63];
      if (i + 2 < b.length) s += B64[n & 63];
    }
    return s;
  };
  const fromBase64url = (s, what) => {
    if (s.length % 4 === 1) throw dom("DataError", `${what} is not base64url`);
    const out = new U8(trunc(s.length * 3 / 4));
    let bits = 0, count = 0, at = 0;
    for (let i = 0; i < s.length; i++) {
      const v = B64_VALUES[apply(charCodeAt, s, [i])];
      if (v === undefined) throw dom("DataError", `${what} is not base64url`);
      bits = (bits << 6 | v) & 0xFFFFFF;
      count += 6;
      if (count >= 8) {
        count -= 8;
        out[at++] = bits >> count & 0xFF;
      }
    }
    return out;
  };
  const JWK_STRINGS = ["kty", "use", "alg", "crv", "x", "y", "d", "n", "e", "p", "q", "dp", "dq", "qi", "k"];
  // A JsonWebKey dictionary: what is there, converted.
  const jwkOf = v => {
    if (v === undefined || v === null) return { __proto__: null };
    if (!isObject(v)) throw new TE("The key data is not a JsonWebKey");
    const out = { __proto__: null };
    for (let i = 0; i < JWK_STRINGS.length; i++) {
      const x = v[JWK_STRINGS[i]];
      if (x !== undefined) out[JWK_STRINGS[i]] = domString(x);
    }
    const ext = v.ext;
    if (ext !== undefined) out.ext = !!ext;
    const ops = v.key_ops;
    if (ops !== undefined) {
      const list = sequence(ops, "key_ops");
      for (let i = 0; i < list.length; i++) list[i] = domString(list[i]);
      out.key_ops = list;
    }
    const oth = v.oth;
    if (oth !== undefined) out.oth = sequence(oth, "oth");
    return out;
  };
  // What every kind of key checks: `use`, `key_ops`, `ext`.
  const jwkCommon = (jwk, use, extractable, usages) => {
    if (use !== undefined && usages.length > 0 && jwk.use !== undefined && jwk.use !== use) throw dom("DataError", `The key's use is not ${use}`);
    if (jwk.key_ops !== undefined) {
      const ops = jwk.key_ops;
      for (let i = 0; i < ops.length; i++) {
        for (let j = 0; j < i; j++) if (ops[i] === ops[j]) throw dom("DataError", "key_ops has a repeated value");
      }
      if (jwk.use !== undefined && jwk.use !== "enc" && jwk.use !== "sig") throw dom("DataError", "use and key_ops are not consistent");
      if (jwk.use !== undefined) {
        const set = jwk.use === "enc" ? ["encrypt", "decrypt", "wrapKey", "unwrapKey"] : ["sign", "verify"];
        for (let i = 0; i < ops.length; i++) if (has(USAGE_NAMES, ops[i]) && !has(set, ops[i])) throw dom("DataError", "use and key_ops are not consistent");
      }
      for (let i = 0; i < usages.length; i++) if (!has(ops, usages[i])) throw dom("DataError", `key_ops does not permit ${usages[i]}`);
    }
    if (jwk.ext === false && extractable) throw dom("DataError", "The key is not extractable (ext)");
  };
  const jwkField = (jwk, name) => {
    const v = jwk[name];
    if (v === undefined) throw dom("DataError", `The key has no ${name}`);
    return fromBase64url(v, name);
  };
  const concat = (...parts) => {
    let n = 0;
    for (let i = 0; i < parts.length; i++) n += parts[i].length;
    const out = new U8(n);
    n = 0;
    for (let i = 0; i < parts.length; i++) {
      apply(u8Set, out, [parts[i], n]);
      n += parts[i].length;
    }
    return out;
  };
  const AES_JWK_SUFFIX = { "AES-CTR": "CTR", "AES-CBC": "CBC", "AES-GCM": "GCM", "AES-KW": "KW" };
  const HMAC_JWK = { "SHA-1": "HS1", "SHA-256": "HS256", "SHA-384": "HS384", "SHA-512": "HS512" };
  const RSA_JWK = {
    "RSASSA-PKCS1-v1_5": { "SHA-1": "RS1", "SHA-256": "RS256", "SHA-384": "RS384", "SHA-512": "RS512" },
    "RSA-PSS": { "SHA-1": "PS1", "SHA-256": "PS256", "SHA-384": "PS384", "SHA-512": "PS512" },
    "RSA-OAEP": { "SHA-1": "RSA-OAEP", "SHA-256": "RSA-OAEP-256", "SHA-384": "RSA-OAEP-384", "SHA-512": "RSA-OAEP-512" },
  };
  const EC_JWK = { "P-256": "ES256", "P-384": "ES384", "P-521": "ES512" };

  // ---- importKey ----

  const importSecret = (format, keyData, alg, extractable, usages) => {
    const name = alg.name;
    allowedOnly(usages, SECRET_KEY_USAGES[name]);
    if (name === "HKDF" || name === "PBKDF2") {
      if (format !== "raw") throw dom("NotSupportedError", `${name} keys are imported as raw only`);
      if (extractable) throw dom("SyntaxError", `${name} keys cannot be extractable`);
      return keyNew(native.importRaw("secret", keyData, EMPTY, false, false), "secret", false, { __proto__: null, name }, usages);
    }
    if (format !== "raw" && format !== "jwk") throw dom("NotSupportedError", `${name} keys are imported as raw or jwk`);
    let material;
    let hash = name === "HMAC" ? alg.hash : undefined;
    if (format === "raw") {
      material = keyData;
    } else {
      const jwk = keyData;
      if (jwk.kty !== "oct") throw dom("DataError", "The key's kty is not oct");
      material = jwkField(jwk, "k");
      if (name === "HMAC") {
        if (jwk.alg !== undefined && jwk.alg !== HMAC_JWK[hash.name]) throw dom("DataError", "The key's alg is not that of its hash");
        jwkCommon(jwk, "sig", extractable, usages);
      } else {
        if (jwk.alg !== undefined && jwk.alg !== `A${material.length * 8}${AES_JWK_SUFFIX[name]}`) throw dom("DataError", "The key's alg is not that of its size");
        jwkCommon(jwk, "enc", extractable, usages);
      }
    }
    if (name === "HMAC") {
      let length = material.length * 8;
      if (length === 0) throw dom("DataError", "An HMAC key cannot be empty");
      if (alg.length !== undefined) {
        if (alg.length > length || alg.length <= length - 8) throw dom("DataError", "The key's length is not that of its bytes");
        if (alg.length % 8 !== 0) {
          material = apply(u8Slice, material, []);
          material[material.length - 1] &= 0xFF << (8 - alg.length % 8);
        }
        length = alg.length;
      }
      return keyNew(native.importRaw("secret", material, EMPTY, false, extractable), "secret", extractable, { __proto__: null, name, length, hash }, usages);
    }
    const bits = material.length * 8;
    if (bits !== 128 && bits !== 192 && bits !== 256) throw dom("DataError", "An AES key has 128, 192 or 256 bits");
    return keyNew(native.importRaw("secret", material, EMPTY, false, extractable), "secret", extractable, { __proto__: null, name, length: bits }, usages);
  };

  // A key of RSA or of a curve from what a format holds; the kinds differ only by this and by what they check of a JWK.
  const invalid = () => { throw dom("DataError", "The key data is not valid for this algorithm"); };

  const importRsa = (format, keyData, alg, extractable, usages) => {
    const name = alg.name, publicUsages = PAIR_USAGES[name][0], privateUsages = PAIR_USAGES[name][1];
    let type, data;
    switch (format) {
      case "spki":
      case "pkcs8":
        type = format === "spki" ? "public" : "private";
        allowedOnly(usages, type === "public" ? publicUsages : privateUsages);
        data = native.importDer("RSA", format === "pkcs8", keyData, extractable) || invalid();
        break;
      case "jwk": {
        const jwk = keyData;
        type = jwk.d !== undefined ? "private" : "public";
        allowedOnly(usages, type === "public" ? publicUsages : privateUsages);
        if (jwk.kty !== "RSA") throw dom("DataError", "The key's kty is not RSA");
        jwkCommon(jwk, name === "RSA-OAEP" ? "enc" : "sig", extractable, usages);
        if (jwk.alg !== undefined && jwk.alg !== RSA_JWK[name][alg.hash.name]) throw dom("DataError", "The key's alg is not that of its hash");
        if (jwk.oth !== undefined && jwk.oth.length > 0) throw dom("NotSupportedError", "Keys of more than two primes are not supported");
        const n = jwkField(jwk, "n"), e = jwkField(jwk, "e");
        if (type === "public") {
          data = native.importRsa(n, e, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, extractable) || invalid();
        } else {
          data = native.importRsa(n, e, jwkField(jwk, "d"), jwkField(jwk, "p"), jwkField(jwk, "q"), jwkField(jwk, "dp"), jwkField(jwk, "dq"), jwkField(jwk, "qi"), extractable) || invalid();
        }
        break;
      }
      default:
        throw dom("NotSupportedError", `${name} keys are not imported as ${format}`);
    }
    const modulusLength = native.modulusBits(data), publicExponent = new U8(native.exportPart(data, "e"));
    return keyNew(data, type, extractable, { __proto__: null, name, hash: alg.hash, modulusLength, publicExponent }, usages);
  };

  const importCurve = (format, keyData, alg, extractable, usages) => {
    const name = alg.name, publicUsages = PAIR_USAGES[name][0], privateUsages = PAIR_USAGES[name][1];
    const isNist = name === "ECDSA" || name === "ECDH";
    const kind = isNist ? curveOf(alg.namedCurve) : name;
    const keyAlg = isNist ? { __proto__: null, name, namedCurve: alg.namedCurve } : { __proto__: null, name };
    let type, data;
    switch (format) {
      case "spki":
      case "pkcs8":
        type = format === "spki" ? "public" : "private";
        allowedOnly(usages, type === "public" ? publicUsages : privateUsages);
        data = native.importDer(kind, format === "pkcs8", keyData, extractable) || invalid();
        break;
      case "raw":
        type = "public";
        allowedOnly(usages, publicUsages);
        data = native.importRaw(kind, keyData, EMPTY, false, true) || invalid();
        break;
      case "jwk": {
        const jwk = keyData;
        type = jwk.d !== undefined ? "private" : "public";
        allowedOnly(usages, type === "public" ? publicUsages : privateUsages);
        if (jwk.kty !== (isNist ? "EC" : "OKP")) throw dom("DataError", `The key's kty is not ${isNist ? "EC" : "OKP"}`);
        if (jwk.crv !== kind) throw dom("DataError", `The key's crv is not ${kind}`);
        jwkCommon(jwk, name === "ECDSA" || name === "Ed25519" ? "sig" : "enc", extractable, usages);
        if (name === "ECDSA" && jwk.alg !== undefined && jwk.alg !== EC_JWK[kind]) throw dom("DataError", "The key's alg is not that of its curve");
        if (name === "Ed25519" && jwk.alg !== undefined && jwk.alg !== "Ed25519" && jwk.alg !== "EdDSA") throw dom("DataError", "The key's alg is not Ed25519");
        let point;
        if (isNist) {
          const x = jwkField(jwk, "x"), y = jwkField(jwk, "y"), size = curveSize(kind);
          if (x.length !== size || y.length !== size) invalid();
          point = concat(new U8([4]), x, y);
        } else {
          point = jwkField(jwk, "x");
          if (point.length !== 32) invalid();
        }
        if (type === "public") {
          data = native.importRaw(kind, point, EMPTY, false, true) || invalid();
        } else {
          data = native.importRaw(kind, jwkField(jwk, "d"), point, true, extractable) || invalid();
        }
        break;
      }
      default:
        throw dom("NotSupportedError", `${name} keys are not imported as ${format}`);
    }
    return keyNew(data, type, extractable, keyAlg, usages);
  };

  const importInternal = (format, keyData, alg, extractable, usages) => {
    const name = alg.name;
    if (SECRET_KEY_USAGES[name] !== undefined) return importSecret(format, keyData, alg, extractable, usages);
    return has(RSA, name) ? importRsa(format, keyData, alg, extractable, usages) : importCurve(format, keyData, alg, extractable, usages);
  };

  // ---- exportKey ----

  const exportInternal = (format, st) => {
    const name = st.alg.name, data = st.data;
    if (name === "HKDF" || name === "PBKDF2") throw dom("NotSupportedError", `${name} keys cannot be exported`);
    if (!st.extractable) throw dom("InvalidAccessError", "The key is not extractable");
    const isSecret = st.type === "secret", isRsa = has(RSA, name);
    switch (format) {
      case "raw":
        if (isSecret) return native.exportPart(data, "secret");
        if (isRsa) throw dom("NotSupportedError", "RSA keys are not exported as raw");
        if (st.type !== "public") throw dom("InvalidAccessError", "Only a public key is exported as raw");
        return native.exportPart(data, "public");
      case "spki":
        if (isSecret) throw dom("NotSupportedError", "A secret key is not exported as spki");
        if (st.type !== "public") throw dom("InvalidAccessError", "Only a public key is exported as spki");
        return native.exportPart(data, "spki");
      case "pkcs8":
        if (isSecret) throw dom("NotSupportedError", "A secret key is not exported as pkcs8");
        if (st.type !== "private") throw dom("InvalidAccessError", "Only a private key is exported as pkcs8");
        return native.exportPart(data, "pkcs8");
    }
    // jwk
    const part = p => base64url(native.exportPart(data, p));
    const jwk = {};
    if (isSecret) {
      jwk.kty = "oct";
      jwk.k = part("secret");
      jwk.alg = name === "HMAC" ? HMAC_JWK[st.alg.hash.name] : `A${st.alg.length}${AES_JWK_SUFFIX[name]}`;
    } else if (isRsa) {
      jwk.kty = "RSA";
      jwk.alg = RSA_JWK[name][st.alg.hash.name];
      jwk.n = part("n");
      jwk.e = part("e");
      if (st.type === "private") {
        jwk.d = part("rsa_d");
        jwk.p = part("p");
        jwk.q = part("q");
        jwk.dp = part("dp");
        jwk.dq = part("dq");
        jwk.qi = part("qi");
      }
    } else if (name === "ECDSA" || name === "ECDH") {
      jwk.kty = "EC";
      jwk.crv = st.alg.namedCurve;
      if (name === "ECDSA") jwk.alg = EC_JWK[jwk.crv];
      jwk.x = part("x");
      jwk.y = part("y");
      if (st.type === "private") jwk.d = part("d");
    } else {
      jwk.kty = "OKP";
      jwk.crv = name;
      if (name === "Ed25519") jwk.alg = "Ed25519";
      jwk.x = part("public");
      if (st.type === "private") jwk.d = part("d");
    }
    const ops = [];
    for (let i = 0; i < st.list.length; i++) ops[i] = st.list[i];
    jwk.key_ops = ops;
    jwk.ext = st.extractable;
    return jwk;
  };

  // ---- computations ----

  const cipher = (alg, st, data, encrypt) => {
    switch (alg.name) {
      case "AES-CBC":
        if (alg.iv.length !== 16) throw dom("OperationError", "The iv of AES-CBC has 16 bytes");
        return native.aes("CBC", encrypt, st.data, alg.iv, EMPTY, 0, data);
      case "AES-CTR":
        if (alg.counter.length !== 16) throw dom("OperationError", "The counter of AES-CTR has 16 bytes");
        if (alg.length === 0 || alg.length > 128) throw dom("OperationError", "The length of AES-CTR's counter is from 1 to 128 bits");
        return native.aes("CTR", encrypt, st.data, alg.counter, EMPTY, alg.length, data);
      case "AES-GCM": {
        const tag = alg.tagLength === undefined ? 128 : alg.tagLength;
        if (tag !== 32 && tag !== 64 && tag !== 96 && tag !== 104 && tag !== 112 && tag !== 120 && tag !== 128) throw dom("OperationError", "The tag length of AES-GCM is not valid");
        return native.aes("GCM", encrypt, st.data, alg.iv, alg.additionalData || EMPTY, tag / 8, data);
      }
    }
    // RSA-OAEP
    if (st.type !== (encrypt ? "public" : "private")) throw dom("InvalidAccessError", `RSA-OAEP ${encrypt ? "encrypts with a public key" : "decrypts with a private key"}`);
    return native.oaep(encrypt, st.data, st.alg.hash.name, alg.label || EMPTY, data);
  };

  const SCHEMES = { "RSASSA-PKCS1-v1_5": "PKCS1", "RSA-PSS": "PSS", "ECDSA": "ECDSA", "Ed25519": "Ed25519", "HMAC": "HMAC" };
  const hashOfSignature = (alg, st) => {
    switch (alg.name) {
      case "ECDSA": return alg.hash.name;
      case "Ed25519": return "";
    }
    return st.alg.hash.name;
  };
  const saltOf = alg => {
    if (alg.saltLength === undefined) return 0;
    return alg.saltLength > 0x7FFFFFFF ? -1 : alg.saltLength;
  };

  // "derive bits": the bits as an ArrayBuffer. `length` null: all of an agreement's; a KDF has to be told.
  const deriveInternal = async (alg, st, length) => {
    const name = alg.name;
    if (name === "ECDH" || name === "X25519") {
      const peer = native.keyState(alg.public);
      if (st.type !== "private") throw dom("InvalidAccessError", "The base key is not a private key");
      if (peer.type !== "public") throw dom("InvalidAccessError", "The public key is not a public key");
      if (peer.alg.name !== name) throw dom("InvalidAccessError", "The public key is not of this algorithm");
      if (peer.alg.namedCurve !== st.alg.namedCurve) throw dom("InvalidAccessError", "The public key is not of this curve");
      const secret = await native.agree(st.data, peer.data);
      if (length === null) return secret;
      const b = new U8(secret);
      if (length > b.length * 8) throw dom("OperationError", "The length is more than the bits of the secret");
      const out = apply(u8Slice, b, [0, trunc((length + 7) / 8)]);
      if (length % 8 !== 0) out[out.length - 1] &= 0xFF << (8 - length % 8);
      return out.buffer;
    }
    if (length === null) throw dom("OperationError", "The length is required");
    if (length % 8 !== 0) throw dom("OperationError", "The length is not a multiple of 8");
    if (name === "PBKDF2") {
      if (alg.iterations === 0) throw dom("OperationError", "PBKDF2 needs at least one iteration");
      return native.derive(st.data, alg.hash.name, alg.salt, EMPTY, alg.iterations, length / 8);
    }
    return native.derive(st.data, alg.hash.name, alg.salt, alg.info, 0, length / 8);
  };

  // "get key length"
  const keyLength = alg => {
    const name = alg.name;
    if (has(AES, name)) {
      if (alg.length !== 128 && alg.length !== 192 && alg.length !== 256) throw dom("OperationError", "AES key length must be 128, 192 or 256 bits");
      return alg.length;
    }
    if (name === "HMAC") {
      if (alg.length === undefined) return HASH_BLOCK_BITS[alg.hash.name];
      if (alg.length === 0) throw new TE("The HMAC length is 0");
      return alg.length;
    }
    return null;
  };

  const wrapAlgorithmOf = (op, fallback, algorithm) => {
    try {
      return normalize(op, algorithm);
    } catch (e) {
      // (not a registered wrapping algorithm: then one of the ciphers)
      if (isObject(e) && e.name === "NotSupportedError") return normalize(fallback, algorithm);
      throw e;
    }
  };

  // ---- the operations ----

  const ops = {
    async encrypt(algorithm, key, data) {
      need(arguments.length, 3, "encrypt");
      const st = stateOf(key, "key"), source = bufferSource(data, "data");
      const alg = normalize("encrypt", algorithm), input = bytes(source);
      expect(st, alg.name, "encrypt");
      return cipher(alg, st, input, true);
    },
    async decrypt(algorithm, key, data) {
      need(arguments.length, 3, "decrypt");
      const st = stateOf(key, "key"), source = bufferSource(data, "data");
      const alg = normalize("decrypt", algorithm), input = bytes(source);
      expect(st, alg.name, "decrypt");
      return cipher(alg, st, input, false);
    },
    async sign(algorithm, key, data) {
      need(arguments.length, 3, "sign");
      const st = stateOf(key, "key"), source = bufferSource(data, "data");
      const alg = normalize("sign", algorithm), input = bytes(source);
      expect(st, alg.name, "sign");
      if (alg.name !== "HMAC" && st.type !== "private") throw dom("InvalidAccessError", "A signature needs a private key");
      return native.sign(SCHEMES[alg.name], st.data, hashOfSignature(alg, st), saltOf(alg), input);
    },
    async verify(algorithm, key, signature, data) {
      need(arguments.length, 4, "verify");
      const st = stateOf(key, "key"), signatureSource = bufferSource(signature, "signature"), source = bufferSource(data, "data");
      const alg = normalize("verify", algorithm), sig = bytes(signatureSource), input = bytes(source);
      expect(st, alg.name, "verify");
      if (alg.name !== "HMAC" && st.type !== "public") throw dom("InvalidAccessError", "A verification needs a public key");
      return native.verify(SCHEMES[alg.name], st.data, hashOfSignature(alg, st), saltOf(alg), sig, input);
    },
    async generateKey(algorithm, extractable, keyUsages) {
      need(arguments.length, 3, "generateKey");
      const ext = !!extractable, usages = usagesOf(keyUsages);
      return generate(normalize("generateKey", algorithm), ext, usages);
    },
    async deriveKey(algorithm, baseKey, derivedKeyType, extractable, keyUsages) {
      need(arguments.length, 5, "deriveKey");
      const st = stateOf(baseKey, "baseKey"), ext = !!extractable, usages = usagesOf(keyUsages);
      const alg = normalize("deriveBits", algorithm);
      const derived = normalize("importKey", derivedKeyType), lengthAlg = normalize("keyLength", derivedKeyType);
      expect(st, alg.name, "deriveKey");
      const length = keyLength(lengthAlg);
      const secret = await deriveInternal(alg, st, length);
      const key = importInternal("raw", new U8(secret), derived, ext, usages);
      ensureUsages(native.keyState(key).type, usages);
      return key;
    },
    async deriveBits(algorithm, baseKey, length) {
      need(arguments.length, 2, "deriveBits");
      const st = stateOf(baseKey, "baseKey");
      const size = length === undefined || length === null ? null : enforced(length, 0xFFFFFFFF, "length");
      const alg = normalize("deriveBits", algorithm);
      expect(st, alg.name, "deriveBits");
      return deriveInternal(alg, st, size);
    },
    async importKey(format, keyData, algorithm, extractable, keyUsages) {
      need(arguments.length, 5, "importKey");
      const f = formatOf(format);
      let data;
      if (f === "jwk") {
        if (native.isBuffer(keyData)) throw new TE("A JsonWebKey is expected");
        data = jwkOf(keyData);
      } else {
        data = bufferSource(keyData, "keyData");
      }
      const ext = !!extractable, usages = usagesOf(keyUsages);
      const alg = normalize("importKey", algorithm);
      if (f !== "jwk") data = bytes(data);
      const key = importInternal(f, data, alg, ext, usages);
      ensureUsages(native.keyState(key).type, usages);
      return key;
    },
    async exportKey(format, key) {
      need(arguments.length, 2, "exportKey");
      const f = formatOf(format);
      return exportInternal(f, stateOf(key, "key"));
    },
    async wrapKey(format, key, wrappingKey, wrapAlgorithm) {
      need(arguments.length, 4, "wrapKey");
      const f = formatOf(format), st = stateOf(key, "key"), wrapping = stateOf(wrappingKey, "wrappingKey");
      const alg = wrapAlgorithmOf("wrapKey", "encrypt", wrapAlgorithm);
      expect(wrapping, alg.name, "wrapKey");
      const exported = exportInternal(f, st);
      let input;
      if (f === "jwk") {
        const text = JSONstringify(exported), b = new U8(text.length);
        for (let i = 0; i < text.length; i++) b[i] = apply(charCodeAt, text, [i]);   // (ASCII: names and base64url)
        input = b;
      } else {
        input = new U8(exported);
      }
      return alg.name === "AES-KW" ? native.aesKw(true, wrapping.data, input) : cipher(alg, wrapping, input, true);
    },
    async unwrapKey(format, wrappedKey, unwrappingKey, unwrapAlgorithm, unwrappedKeyAlgorithm, extractable, keyUsages) {
      need(arguments.length, 7, "unwrapKey");
      const f = formatOf(format), source = bufferSource(wrappedKey, "wrappedKey"), unwrapping = stateOf(unwrappingKey, "unwrappingKey");
      const ext = !!extractable, usages = usagesOf(keyUsages);
      const alg = wrapAlgorithmOf("unwrapKey", "decrypt", unwrapAlgorithm);
      const keyAlg = normalize("importKey", unwrappedKeyAlgorithm);
      const input = bytes(source);
      expect(unwrapping, alg.name, "unwrapKey");
      const plain = new U8(await (alg.name === "AES-KW" ? native.aesKw(false, unwrapping.data, input) : cipher(alg, unwrapping, input, false)));
      let data = plain;
      if (f === "jwk") {
        let parsed;
        try { parsed = JSONparse(native.utf8(plain)); } catch (e) { throw dom("DataError", "The wrapped key is not JSON"); }
        if (!isObject(parsed) || ArrayIsArray(parsed)) throw dom("DataError", "The wrapped key is not a JsonWebKey");
        data = jwkOf(parsed);
      }
      const key = importInternal(f, data, keyAlg, ext, usages);
      ensureUsages(native.keyState(key).type, usages);
      return key;
    },
    // A key that came through structured serialization (clone.odin).
    keyAdopt(data, type, extractable, alg, list) {
      return keyNew(data, type, extractable, alg, list);
    },
  };
  return ops;
})
