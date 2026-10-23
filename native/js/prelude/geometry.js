// Geometry Interfaces (Geometry Module Level 1): DOMPointReadOnly, DOMPoint, DOMMatrixReadOnly and DOMMatrix. The 2D
// canvas takes and gives them (getTransform, setTransform, addPath); pages use them for transform math. A matrix is its
// sixteen numbers in column-major order (m11 m12 m13 m14 m21 ... m44, the order of the attributes) and the "2D" flag
// that says whether it was made from 2D values (a b c d e f) and has stayed 2D. The CSS transform-list parser knows
// matrix(), matrix3d(), translate*, scale*, rotate*, skew*, and perspective().
(function () {
  "use strict";
  const PRIVATE = {};
  const NAMES = ["m11", "m12", "m13", "m14", "m21", "m22", "m23", "m24", "m31", "m32", "m33", "m34", "m41", "m42", "m43", "m44"];
  const ALIAS = { a: "m11", b: "m12", c: "m21", d: "m22", e: "m41", f: "m42" };
  const num = (v) => Number(v);
  const IDENTITY = () => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  const states = new WeakMap();   // matrix -> { m: number[16], is2D }
  const pstates = new WeakMap();  // point -> { x, y, z, w }

  // a * b for column-major 4x4 matrices (the result applies b first, then a)
  function mul(a, b) {
    const r = new Array(16);
    for (let c = 0; c < 4; c++) {
      for (let row = 0; row < 4; row++) {
        let s = 0;
        for (let k = 0; k < 4; k++) s += a[k * 4 + row] * b[c * 4 + k];
        r[c * 4 + row] = s;
      }
    }
    return r;
  }

  function invert(m) {
    const inv = new Array(16);
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
    const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (det === 0 || !Number.isFinite(det)) return null;
    return inv.map((v) => v / det);
  }

  const T = (x, y, z) => { const m = IDENTITY(); m[12] = x; m[13] = y; m[14] = z; return m; };
  const S = (x, y, z) => { const m = IDENTITY(); m[0] = x; m[5] = y; m[10] = z; return m; };
  function rotAxis(x, y, z, deg) {
    const len = Math.hypot(x, y, z);
    if (len === 0) return IDENTITY();
    x /= len; y /= len; z /= len;
    const a = (deg * Math.PI) / 360;   // half angle
    const sc = Math.sin(a) * Math.cos(a), sq = Math.sin(a) * Math.sin(a);
    const m = IDENTITY();
    m[0] = 1 - 2 * (y * y + z * z) * sq; m[1] = 2 * (x * y * sq + z * sc); m[2] = 2 * (x * z * sq - y * sc);
    m[4] = 2 * (x * y * sq - z * sc); m[5] = 1 - 2 * (x * x + z * z) * sq; m[6] = 2 * (y * z * sq + x * sc);
    m[8] = 2 * (x * z * sq + y * sc); m[9] = 2 * (y * z * sq - x * sc); m[10] = 1 - 2 * (x * x + y * y) * sq;
    return m;
  }
  const SKEW = (ax, ay) => { const m = IDENTITY(); m[4] = Math.tan((ax * Math.PI) / 180); m[1] = Math.tan((ay * Math.PI) / 180); return m; };

  function angle(tok) {
    const m = /^([+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)(deg|rad|grad|turn)?$/i.exec(tok.trim());
    if (!m) return NaN;
    const v = parseFloat(m[1]);
    switch ((m[2] || "deg").toLowerCase()) {
      case "rad": return (v * 180) / Math.PI;
      case "grad": return v * 0.9;
      case "turn": return v * 360;
    }
    return v;
  }
  function length(tok) {
    const m = /^([+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)(px)?$/i.exec(tok.trim());
    return m ? parseFloat(m[1]) : NaN;
  }

  // "translate(10px, 5px) rotate(45deg)" -> { m, is2D }
  function parseTransform(text) {
    let m = IDENTITY(), is2D = true;
    const s = String(text).trim();
    if (s === "" || s.toLowerCase() === "none") return { m, is2D };
    const re = /\s*([a-zA-Z0-9]+)\(([^)]*)\)\s*/y;
    let pos = 0;
    while (pos < s.length) {
      re.lastIndex = pos;
      const mt = re.exec(s);
      if (!mt) throw new DOMException("Failed to parse transform list.", "SyntaxError");
      pos = re.lastIndex;
      const name = mt[1].toLowerCase();
      const args = mt[2].split(",").map((x) => x.trim());
      const n = (i, f = num) => f(args[i]);
      let t = null;
      const bad = () => { throw new DOMException("Failed to parse transform list.", "SyntaxError"); };
      switch (name) {
        case "matrix": {
          if (args.length !== 6) bad();
          const v = args.map(Number);
          t = IDENTITY(); t[0] = v[0]; t[1] = v[1]; t[4] = v[2]; t[5] = v[3]; t[12] = v[4]; t[13] = v[5];
          break;
        }
        case "matrix3d": if (args.length !== 16) bad(); t = args.map(Number); is2D = false; break;
        case "translate": t = T(n(0, length), args.length > 1 ? n(1, length) : 0, 0); break;
        case "translatex": t = T(n(0, length), 0, 0); break;
        case "translatey": t = T(0, n(0, length), 0); break;
        case "translatez": t = T(0, 0, n(0, length)); is2D = false; break;
        case "translate3d": t = T(n(0, length), n(1, length), n(2, length)); is2D = false; break;
        case "scale": { const x = n(0); t = S(x, args.length > 1 ? n(1) : x, 1); break; }
        case "scalex": t = S(n(0), 1, 1); break;
        case "scaley": t = S(1, n(0), 1); break;
        case "scalez": t = S(1, 1, n(0)); is2D = false; break;
        case "scale3d": t = S(n(0), n(1), n(2)); is2D = false; break;
        case "rotate": case "rotatez": t = rotAxis(0, 0, 1, n(0, angle)); break;
        case "rotatex": t = rotAxis(1, 0, 0, n(0, angle)); is2D = false; break;
        case "rotatey": t = rotAxis(0, 1, 0, n(0, angle)); is2D = false; break;
        case "rotate3d": t = rotAxis(n(0), n(1), n(2), n(3, angle)); is2D = false; break;
        case "skew": t = SKEW(n(0, angle), args.length > 1 ? n(1, angle) : 0); break;
        case "skewx": t = SKEW(n(0, angle), 0); break;
        case "skewy": t = SKEW(0, n(0, angle)); break;
        case "perspective": { t = IDENTITY(); const d = n(0, length); t[11] = d === 0 ? 0 : -1 / d; is2D = false; break; }
        default: bad();
      }
      if (t.some((v) => Number.isNaN(v))) bad();
      m = mul(m, t);
    }
    return { m, is2D };
  }

  function fromInit(init) {
    if (init === undefined) return { m: IDENTITY(), is2D: true };
    if (typeof init === "string") return parseTransform(init);
    if (init !== null && typeof init === "object" && typeof init[Symbol.iterator] === "function") {
      const v = Array.from(init, Number);
      if (v.length === 6) { const m = IDENTITY(); m[0] = v[0]; m[1] = v[1]; m[4] = v[2]; m[5] = v[3]; m[12] = v[4]; m[13] = v[5]; return { m, is2D: true }; }
      if (v.length === 16) return { m: v, is2D: false };
    }
    throw new TypeError("Failed to construct 'DOMMatrix': The sequence must contain 6 elements for a 2D matrix or 16 elements for a 3D matrix.");
  }

  const st = (o, what) => {
    const s = states.get(o);
    if (s === undefined) throw new TypeError(`Failed to execute '${what}' on 'DOMMatrixReadOnly': Illegal invocation`);
    return s;
  };

  class DOMPointReadOnly {
    constructor(x = 0, y = 0, z = 0, w = 1) { pstates.set(this, { x: num(x), y: num(y), z: num(z), w: num(w) }); }
    get x() { return pst(this).x; }
    get y() { return pst(this).y; }
    get z() { return pst(this).z; }
    get w() { return pst(this).w; }
    static fromPoint(p = {}) { return new this(p.x, p.y, p.z, p.w); }
    matrixTransform(m = {}) { return transformPoint(m instanceof DOMMatrixReadOnly ? m : DOMMatrix.fromMatrix(m), this, DOMPoint); }
    toJSON() { const s = pst(this); return { x: s.x, y: s.y, z: s.z, w: s.w }; }
  }
  const pst = (o) => {
    const s = pstates.get(o);
    if (s === undefined) throw new TypeError("Illegal invocation");
    return s;
  };
  class DOMPoint extends DOMPointReadOnly {
    get x() { return pst(this).x; } set x(v) { pst(this).x = num(v); }
    get y() { return pst(this).y; } set y(v) { pst(this).y = num(v); }
    get z() { return pst(this).z; } set z(v) { pst(this).z = num(v); }
    get w() { return pst(this).w; } set w(v) { pst(this).w = num(v); }
  }
  function transformPoint(matrix, p, Ctor) {
    const m = st(matrix, "transformPoint").m, s = pst(p);
    const x = m[0] * s.x + m[4] * s.y + m[8] * s.z + m[12] * s.w;
    const y = m[1] * s.x + m[5] * s.y + m[9] * s.z + m[13] * s.w;
    const z = m[2] * s.x + m[6] * s.y + m[10] * s.z + m[14] * s.w;
    const w = m[3] * s.x + m[7] * s.y + m[11] * s.z + m[15] * s.w;
    return new Ctor(x, y, z, w);
  }

  class DOMMatrixReadOnly {
    constructor(init) {
      const s = fromInit(init);
      states.set(this, s);
    }
    get is2D() { return st(this, "is2D").is2D; }
    get isIdentity() { const m = st(this, "isIdentity").m, id = IDENTITY(); return m.every((v, i) => v === id[i]); }
    static fromMatrix(other = {}) {
      if (other instanceof DOMMatrixReadOnly) { const s = st(other, "fromMatrix"); const r = new this(); states.set(r, { m: s.m.slice(), is2D: s.is2D }); return r; }
      const m = IDENTITY();
      let is2D = true;
      const has3d = NAMES.some((n) => other[n] !== undefined && !["m11", "m12", "m21", "m22", "m41", "m42"].includes(n));
      for (const [al, nm] of Object.entries(ALIAS)) {
        const idx = NAMES.indexOf(nm);
        if (other[al] !== undefined && other[nm] !== undefined && Object.is(Number(other[al]), Number(other[nm])) === false && !(Number(other[al]) === Number(other[nm]))) {
          throw new TypeError(`Failed to execute 'fromMatrix' on 'DOMMatrix': The ${al} and ${nm} members must have the same value.`);
        }
        const v = other[al] !== undefined ? other[al] : other[nm];
        if (v !== undefined) m[idx] = num(v);
      }
      if (has3d) { for (const nm of NAMES) if (other[nm] !== undefined) m[NAMES.indexOf(nm)] = num(other[nm]); is2D = other.is2D === true ? true : false; }
      else if (other.is2D === false) is2D = false;
      const r = new this();
      states.set(r, { m, is2D });
      return r;
    }
    static fromFloat32Array(a) { return this.fromFloat64Array(a); }
    static fromFloat64Array(a) {
      if (a.length !== 6 && a.length !== 16) throw new TypeError("The sequence must contain 6 elements for a 2D matrix or 16 elements for a 3D matrix.");
      return new this(Array.from(a));
    }
    translate(tx = 0, ty = 0, tz = 0) { return derive(this, "translate", T(num(tx), num(ty), num(tz)), num(tz) !== 0); }
    scale(sx = 1, sy, sz = 1, ox = 0, oy = 0, oz = 0) {
      sx = num(sx); sy = sy === undefined ? sx : num(sy); sz = num(sz); ox = num(ox); oy = num(oy); oz = num(oz);
      const t = mul(mul(T(ox, oy, oz), S(sx, sy, sz)), T(-ox, -oy, -oz));
      return derive(this, "scale", t, sz !== 1 || oz !== 0);
    }
    scaleNonUniform(sx = 1, sy = 1) { return derive(this, "scaleNonUniform", S(num(sx), num(sy), 1), false); }
    scale3d(scale = 1, ox = 0, oy = 0, oz = 0) { scale = num(scale); return derive(this, "scale3d", mul(mul(T(num(ox), num(oy), num(oz)), S(scale, scale, scale)), T(-num(ox), -num(oy), -num(oz))), true); }
    rotate(rx = 0, ry, rz) {
      rx = num(rx);
      if (ry === undefined && rz === undefined) { rz = rx; rx = 0; ry = 0; } else { ry = ry === undefined ? 0 : num(ry); rz = rz === undefined ? 0 : num(rz); }
      let t = IDENTITY();
      if (rz) t = mul(t, rotAxis(0, 0, 1, rz));
      if (ry) t = mul(t, rotAxis(0, 1, 0, ry));
      if (rx) t = mul(t, rotAxis(1, 0, 0, rx));
      return derive(this, "rotate", t, rx !== 0 || ry !== 0);
    }
    rotateFromVector(x = 0, y = 0) { x = num(x); y = num(y); return derive(this, "rotateFromVector", x === 0 && y === 0 ? IDENTITY() : rotAxis(0, 0, 1, (Math.atan2(y, x) * 180) / Math.PI), false); }
    rotateAxisAngle(x = 0, y = 0, z = 0, angle = 0) { return derive(this, "rotateAxisAngle", rotAxis(num(x), num(y), num(z), num(angle)), true); }
    skewX(sx = 0) { return derive(this, "skewX", SKEW(num(sx), 0), false); }
    skewY(sy = 0) { return derive(this, "skewY", SKEW(0, num(sy)), false); }
    multiply(other = {}) {
      const o = other instanceof DOMMatrixReadOnly ? st(other, "multiply") : st(DOMMatrix.fromMatrix(other), "multiply");
      const s = st(this, "multiply");
      const r = new DOMMatrix();
      states.set(r, { m: mul(s.m, o.m), is2D: s.is2D && o.is2D });
      return r;
    }
    flipX() { return derive(this, "flipX", S(-1, 1, 1), false); }
    flipY() { return derive(this, "flipY", S(1, -1, 1), false); }
    inverse() {
      const s = st(this, "inverse"), inv = invert(s.m), r = new DOMMatrix();
      states.set(r, inv ? { m: inv, is2D: s.is2D } : { m: new Array(16).fill(NaN), is2D: s.is2D });
      return r;
    }
    transformPoint(p = {}) { return transformPoint(this, p instanceof DOMPointReadOnly ? p : DOMPoint.fromPoint(p), DOMPoint); }
    toFloat32Array() { return new Float32Array(st(this, "toFloat32Array").m); }
    toFloat64Array() { return new Float64Array(st(this, "toFloat64Array").m); }
    toString() {
      const s = st(this, "toString");
      if (!s.m.every(Number.isFinite)) throw new DOMException("Failed to execute 'toString' on 'DOMMatrixReadOnly': Cannot be serialized with NaN or Infinity values.", "InvalidStateError");
      return s.is2D ? `matrix(${[0, 1, 4, 5, 12, 13].map((i) => s.m[i]).join(", ")})` : `matrix3d(${s.m.join(", ")})`;
    }
    toJSON() {
      const s = st(this, "toJSON"), o = {};
      for (const [al, nm] of Object.entries(ALIAS)) o[al] = s.m[NAMES.indexOf(nm)];
      for (const nm of NAMES) o[nm] = s.m[NAMES.indexOf(nm)];
      o.is2D = s.is2D;
      o.isIdentity = this.isIdentity;
      return o;
    }
  }
  function derive(self, what, t, makes3d) {
    const s = st(self, what), r = new DOMMatrix();
    states.set(r, { m: mul(s.m, t), is2D: s.is2D && !makes3d });
    return r;
  }
  for (const [al, nm] of Object.entries(ALIAS)) {
    const idx = NAMES.indexOf(nm);
    Object.defineProperty(DOMMatrixReadOnly.prototype, al, { get() { return st(this, al).m[idx]; }, enumerable: true, configurable: true });
  }
  for (const nm of NAMES) {
    const idx = NAMES.indexOf(nm);
    Object.defineProperty(DOMMatrixReadOnly.prototype, nm, { get() { return st(this, nm).m[idx]; }, enumerable: true, configurable: true });
  }

  class DOMMatrix extends DOMMatrixReadOnly {
    constructor(init) { super(init); }
    static fromMatrix(other) { return super.fromMatrix(other); }
    multiplySelf(other = {}) { const r = this.multiply(other); states.set(this, states.get(r)); return this; }
    preMultiplySelf(other = {}) {
      const o = other instanceof DOMMatrixReadOnly ? st(other, "preMultiplySelf") : st(DOMMatrix.fromMatrix(other), "preMultiplySelf");
      const s = st(this, "preMultiplySelf");
      states.set(this, { m: mul(o.m, s.m), is2D: s.is2D && o.is2D });
      return this;
    }
    translateSelf(...a) { states.set(this, states.get(this.translate(...a))); return this; }
    scaleSelf(...a) { states.set(this, states.get(this.scale(...a))); return this; }
    scale3dSelf(...a) { states.set(this, states.get(this.scale3d(...a))); return this; }
    rotateSelf(...a) { states.set(this, states.get(this.rotate(...a))); return this; }
    rotateFromVectorSelf(...a) { states.set(this, states.get(this.rotateFromVector(...a))); return this; }
    rotateAxisAngleSelf(...a) { states.set(this, states.get(this.rotateAxisAngle(...a))); return this; }
    skewXSelf(...a) { states.set(this, states.get(this.skewX(...a))); return this; }
    skewYSelf(...a) { states.set(this, states.get(this.skewY(...a))); return this; }
    invertSelf() { states.set(this, states.get(this.inverse())); return this; }
    setMatrixValue(text) { states.set(this, parseTransform(text)); return this; }
  }
  for (const [al, nm] of [...Object.entries(ALIAS), ...NAMES.map((n) => [n, n])]) {
    const idx = NAMES.indexOf(nm);
    const flat3d = idx !== 0 && idx !== 1 && idx !== 4 && idx !== 5 && idx !== 12 && idx !== 13;
    Object.defineProperty(DOMMatrix.prototype, al, {
      get() { return st(this, al).m[idx]; },
      set(v) {
        const s = st(this, al);
        v = num(v);
        // a 3D attribute set to anything but its identity value makes the matrix 3D
        if (flat3d && v !== IDENTITY()[idx]) s.is2D = false;
        s.m[idx] = v;
      },
      enumerable: true, configurable: true,
    });
  }
  Object.defineProperty(DOMMatrix.prototype, "is2D", { get() { return st(this, "is2D").is2D; }, set(v) { const s = st(this, "is2D"); if (!v && s.is2D) s.is2D = false; }, enumerable: true, configurable: true });

  for (const c of [DOMPointReadOnly, DOMPoint, DOMMatrixReadOnly, DOMMatrix]) {
    Object.defineProperty(c.prototype, Symbol.toStringTag, { value: c.name, configurable: true });
    Object.defineProperty(globalThis, c.name, { value: c, writable: true, configurable: true, enumerable: false });
  }
})();
