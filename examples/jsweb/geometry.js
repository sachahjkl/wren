// Geometry Interfaces (native/js/runtime/web_geometry.c): DOMPoint, DOMMatrix and DOMQuad, in the engine.

const near = (a, b) => Math.abs(a - b) < 1e-12;
const names = ["m11", "m12", "m13", "m14", "m21", "m22", "m23", "m24", "m31", "m32", "m33", "m34", "m41", "m42", "m43", "m44"];
const all = m => names.map(n => m[n]);

test("points", () => {
  const p = new DOMPoint(1, 2);
  eq([p.x, p.y, p.z, p.w].join(), "1,2,0,1", "defaults");
  eq(JSON.stringify(p), '{"x":1,"y":2,"z":0,"w":1}', "toJSON");
  p.x = 5; p.w = "3";
  eq([p.x, p.w].join(), "5,3", "the attributes are writable and converted");
  eq(new DOMPoint(undefined, 7).x, 0, "undefined takes the default");
  ok(Number.isNaN(new DOMPoint(NaN).x), "unrestricted double: NaN is kept");
  eq(DOMPoint.fromPoint({ y: 4 }).y, 4, "fromPoint");
  ok(DOMPoint.fromPoint({}) instanceof DOMPoint && !(DOMPointReadOnly.fromPoint({}) instanceof DOMPoint), "fromPoint makes the interface's own");
  const ro = new DOMPointReadOnly(1);
  ro.x = 9;
  eq(ro.x, 1, "a read-only point stays");
  class P extends DOMPoint { twice() { return this.x * 2; } }
  eq(new P(4).twice(), 8, "subclass");
  throws(() => DOMPoint(), "TypeError", "constructor needs new");
  throws(() => Object.getOwnPropertyDescriptor(DOMPoint.prototype, "x").get.call({}), "TypeError", "illegal invocation");
  eq(Object.prototype.toString.call(p), "[object DOMPoint]", "toStringTag");
  ok(SVGPoint === DOMPoint, "SVGPoint is DOMPoint");
  ok(DOMPoint.prototype instanceof DOMPointReadOnly, "DOMPoint extends DOMPointReadOnly");
});

test("matrices: construction", () => {
  const m = new DOMMatrix();
  ok(m.isIdentity && m.is2D, "identity");
  eq(String(m), "matrix(1, 0, 0, 1, 0, 0)", "toString");
  ok(new DOMMatrix([1, 2, 3, 4, 5, 6]).is2D, "six numbers: 2D");
  const six = new DOMMatrix([1, 2, 3, 4, 5, 6]);
  eq([six.a, six.b, six.c, six.d, six.e, six.f].join(), "1,2,3,4,5,6", "six numbers: a b c d e f");
  eq([six.m11, six.m12, six.m21, six.m22, six.m41, six.m42].join(), "1,2,3,4,5,6", "six numbers: the m members");
  const sixteen = new DOMMatrix(Array.from({ length: 16 }, (_, i) => i + 1));
  ok(!sixteen.is2D, "sixteen numbers: 3D");
  eq(all(sixteen).join(), "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16", "sixteen numbers: column-major");
  throws(() => new DOMMatrix([1, 2, 3]), "TypeError", "three numbers");
  throws(() => new DOMMatrix(new Float32Array(5)), "TypeError", "a typed array of five");
  eq(new DOMMatrix(new Float64Array([1, 0, 0, 1, 7, 8])).e, 7, "any iterable of numbers");
  eq(String(new DOMMatrix(undefined)), "matrix(1, 0, 0, 1, 0, 0)", "undefined: identity");
  eq(String(new DOMMatrix("")), "matrix(1, 0, 0, 1, 0, 0)", "an empty string: identity");
  eq(String(new DOMMatrix("none")), "matrix(1, 0, 0, 1, 0, 0)", "none: identity");
  throws(() => DOMMatrix(), "TypeError", "constructor needs new");
  ok(SVGMatrix === DOMMatrix, "SVGMatrix is DOMMatrix");
  ok(DOMMatrix.prototype instanceof DOMMatrixReadOnly, "DOMMatrix extends DOMMatrixReadOnly");
  eq(Object.prototype.toString.call(m), "[object DOMMatrix]", "toStringTag");
  class M extends DOMMatrix { three() { return this.a * 3; } }
  eq(new M([2, 0, 0, 1, 0, 0]).three(), 6, "subclass");
  throws(() => DOMMatrix.prototype.translate.call({}), "TypeError", "illegal invocation");
});

test("matrices: transform lists", () => {
  eq(String(new DOMMatrix("translate(10px, 20px) scale(2)")), "matrix(2, 0, 0, 2, 10, 20)", "translate then scale");
  eq(String(new DOMMatrix("  Translate( 3px )Scale( 2 , 3 ) ")), "matrix(2, 0, 0, 3, 3, 0)", "case, spaces, no space between functions");
  eq(String(new DOMMatrix("matrix(1, 2, 3, 4, 5, 6)")), "matrix(1, 2, 3, 4, 5, 6)", "matrix()");
  eq(String(new DOMMatrix("translateX(2px) translateY(3px)")), "matrix(1, 0, 0, 1, 2, 3)", "translateX, translateY");
  eq(String(new DOMMatrix("scaleX(2) scaleY(3)")), "matrix(2, 0, 0, 3, 0, 0)", "scaleX, scaleY");
  const r = new DOMMatrix("rotate(90deg)");
  ok(near(r.a, 0) && near(r.b, 1) && near(r.c, -1) && near(r.d, 0), "rotate(90deg)");
  const turn = new DOMMatrix("rotate(0.25turn)"), rad = new DOMMatrix(`rotate(${Math.PI / 2}rad)`), grad = new DOMMatrix("rotate(100grad)");
  ok(near(turn.b, 1) && near(rad.b, 1) && near(grad.b, 1), "turn, rad and grad");
  const s = new DOMMatrix("skew(45deg, 0)");
  ok(near(s.c, 1) && s.b === 0, "skew");
  ok(near(new DOMMatrix("skewX(45deg)").c, 1) && near(new DOMMatrix("skewY(45deg)").b, 1), "skewX, skewY");
  eq(String(new DOMMatrix("translate(1in, 6pt)")), "matrix(1, 0, 0, 1, 96, 8)", "absolute units");
  const m3 = new DOMMatrix("translate3d(1px, 2px, 3px)");
  ok(!m3.is2D && m3.m43 === 3, "translate3d makes it 3D");
  ok(!new DOMMatrix("scale3d(1, 2, 3)").is2D && !new DOMMatrix("rotateX(10deg)").is2D && !new DOMMatrix("rotateZ(10deg)").is2D, "3D functions");
  ok(new DOMMatrix("rotate(10deg) translate(1px)").is2D, "2D functions stay 2D");
  const p = new DOMMatrix("perspective(100px)");
  ok(p.m34 === -0.01 && !p.is2D, "perspective(d)");
  ok(new DOMMatrix("perspective(none)").isIdentity, "perspective(none)");
  const axis = new DOMMatrix("rotate3d(0, 0, 1, 90deg)");
  ok(near(axis.b, 1) && !axis.is2D, "rotate3d around z");
  ok(near(new DOMMatrix("rotate3d(1, 0, 0, 90deg)").m23, 1), "rotate3d around x");
  for (const bad of ["bogus(1)", "translate(10)", "translate(1em)", "translate(5%)", "rotate(45)", "scale(1px)", "scale()", "scale(1, 2, 3)", "matrix(1, 2, 3)",
    "translate(1px,)", "perspective(-1px)", "translate(1px", "1px", "rotate(1deg) bogus"]) {
    throws(() => new DOMMatrix(bad), "SyntaxError", "a bad list: " + bad);
  }
  eq(String(new DOMMatrix().setMatrixValue("scale(3)")), "matrix(3, 0, 0, 3, 0, 0)", "setMatrixValue");
  const mm = new DOMMatrix([1, 0, 0, 1, 5, 5]);
  eq(mm.setMatrixValue("translate(1px)"), mm, "setMatrixValue returns this");
  eq(mm.e, 1, "setMatrixValue replaces the matrix");
  throws(() => mm.setMatrixValue("nope"), "SyntaxError", "setMatrixValue fails like the constructor");
});

test("matrices: operations", () => {
  const m = new DOMMatrix();
  const t = m.translate(10, 5).scale(2);
  eq(String(t), "matrix(2, 0, 0, 2, 10, 5)", "translate then scale");
  ok(m.isIdentity, "the original is not changed");
  ok(t instanceof DOMMatrix && t.constructor === DOMMatrix, "the result is a DOMMatrix");
  ok(!m.translate(0, 0, 1).is2D && m.translate(1, 2, 0).is2D, "translate: 3D only for a z");
  eq(String(m.scale(2, undefined)), "matrix(2, 0, 0, 2, 0, 0)", "scale(x) is uniform");
  eq(String(m.scale(2, 3)), "matrix(2, 0, 0, 3, 0, 0)", "scale(x, y)");
  eq(String(m.scale(2, 2, 1, 5, 5, 0)), "matrix(2, 0, 0, 2, -5, -5)", "scale around an origin");
  ok(!m.scale(1, 1, 2).is2D && !m.scale(1, 1, 1, 0, 0, 3).is2D, "scale: 3D for a z factor or origin");
  eq(String(m.scaleNonUniform(2, 3)), "matrix(2, 0, 0, 3, 0, 0)", "scaleNonUniform");
  const s3 = m.scale3d(2, 1, 1, 1);
  ok(!s3.is2D && s3.m11 === 2 && s3.m33 === 2 && s3.m41 === -1, "scale3d");
  eq(String(m.flipX()), "matrix(-1, 0, 0, 1, 0, 0)", "flipX");
  eq(String(m.flipY()), "matrix(1, 0, 0, -1, 0, 0)", "flipY");
  const rot = m.rotate(90);
  ok(near(rot.a, 0) && near(rot.b, 1) && rot.is2D, "rotate(angle) turns around z");
  ok(!m.rotate(10, 20, 30).is2D && !m.rotate(10, 0, 0).is2D && m.rotate(0, 0, 30).is2D, "rotate(x, y, z): 3D for x or y");
  const rzyx = m.rotate(10, 20, 30);
  const expected = m.rotate(0, 0, 30).rotate(0, 20, 0).rotate(10, 0, 0);
  ok(all(rzyx).every((v, i) => near(v, all(expected)[i])), "rotate applies z, then y, then x");
  ok(near(m.rotateFromVector(0, 1).b, 1) && m.rotateFromVector(0, 0).isIdentity, "rotateFromVector");
  ok(m.rotateAxisAngle(0, 0, 1, 90).is2D && !m.rotateAxisAngle(1, 0, 0, 90).is2D, "rotateAxisAngle: 3D for x or y");
  ok(m.rotateAxisAngle(0, 0, 0, 90).isIdentity, "a zero axis is no rotation");
  ok(near(m.skewX(45).c, 1) && near(m.skewY(45).b, 1), "skewX, skewY");
  const prod = new DOMMatrix([1, 2, 3, 4, 5, 6]).multiply(new DOMMatrix([7, 8, 9, 10, 11, 12]));
  eq([prod.a, prod.b, prod.c, prod.d, prod.e, prod.f].join(), "31,46,39,58,52,76", "multiply (this * other)");
  eq(String(m.multiply({ a: 2, d: 3 })), "matrix(2, 0, 0, 3, 0, 0)", "multiply takes a DOMMatrixInit");
  eq(String(m.multiply()), "matrix(1, 0, 0, 1, 0, 0)", "multiply() is the identity");
  ok(!new DOMMatrix().multiply(new DOMMatrix("translateZ(1px)")).is2D, "multiply: 3D when either is");
  throws(() => m.multiply(5), "TypeError", "multiply(5)");
  throws(() => m.multiply({ a: 1, m11: 2 }), "TypeError", "a and m11 must agree");
  const i = t.inverse();
  ok(near(i.a, 0.5) && near(i.e, -5) && near(i.f, -2.5) && i.is2D, "inverse");
  ok(all(t.multiply(i)).every((v, k) => near(v, all(new DOMMatrix())[k])), "m * inverse is the identity");
  const d3 = new DOMMatrix("translate3d(1px, 2px, 3px) rotateX(30deg) scale3d(2, 3, 4)");
  ok(all(d3.multiply(d3.inverse())).every((v, k) => near(v, all(new DOMMatrix())[k])), "inverse of a 3D matrix");
  const single = new DOMMatrix([0, 0, 0, 0, 0, 0]).inverse();
  ok(all(single).every(Number.isNaN) && !single.is2D && !single.isIdentity, "a matrix that cannot be inverted: NaN everywhere, 3D");
  throws(() => String(single), "InvalidStateError", "NaN cannot be serialized");
  throws(() => String(new DOMMatrix([Infinity, 0, 0, 1, 0, 0])), "InvalidStateError", "Infinity cannot be serialized");
  ok(all(new DOMMatrix([NaN, 0, 0, 1, 0, 0]).inverse()).every(Number.isNaN), "inverse of a NaN matrix");
});

test("matrices: DOMMatrix mutates, DOMMatrixReadOnly does not", () => {
  const mm = new DOMMatrix([1, 0, 0, 1, 0, 0]);
  mm.a = 3; mm.m41 = 9;
  eq(mm.a + "," + mm.e, "3,9", "attributes are writable");
  ok(mm.is2D, "2D values keep it 2D");
  mm.m33 = 1; mm.m13 = -0;
  ok(mm.is2D, "the identity values of the 3D members keep it 2D");
  mm.m34 = 0.5;
  ok(!mm.is2D, "another value makes it 3D");
  mm.m34 = 0;
  ok(!mm.is2D, "and it stays 3D");
  const ro = new DOMMatrixReadOnly([1, 2, 3, 4, 5, 6]);
  ro.a = 99;
  eq(ro.a, 1, "read-only");
  eq(typeof Object.getOwnPropertyDescriptor(DOMMatrix.prototype, "a").set, "function", "DOMMatrix.prototype.a has a setter");
  eq(Object.getOwnPropertyDescriptor(DOMMatrixReadOnly.prototype, "a").set, undefined, "DOMMatrixReadOnly.prototype.a has none");
  eq(Object.getOwnPropertyDescriptor(DOMMatrix.prototype, "is2D"), undefined, "is2D is read-only");
  const x = new DOMMatrix([1, 0, 0, 1, 0, 0]);
  eq(x.multiplySelf(new DOMMatrix([2, 0, 0, 2, 0, 0])), x, "multiplySelf returns this");
  eq(x.a, 2, "multiplySelf");
  x.preMultiplySelf(new DOMMatrix([1, 0, 0, 1, 5, 0]));
  eq(x.e, 5, "preMultiplySelf");
  eq(String(new DOMMatrix([1, 0, 0, 1, 5, 0]).preMultiplySelf(new DOMMatrix([2, 0, 0, 2, 0, 0]))), "matrix(2, 0, 0, 2, 10, 0)", "preMultiplySelf is other * this");
  const y = new DOMMatrix();
  eq(y.translateSelf(3, 4), y, "translateSelf returns this");
  eq(y.e + "," + y.f, "3,4", "translateSelf");
  y.scaleSelf(2); y.rotateSelf(90); y.skewXSelf(10); y.skewYSelf(10); y.scale3dSelf(1); y.rotateFromVectorSelf(1, 1); y.rotateAxisAngleSelf(0, 0, 1, 5);
  ok(!y.is2D, "scale3dSelf makes it 3D");
  const z = new DOMMatrix([2, 0, 0, 2, 0, 0]);
  eq(z.invertSelf(), z, "invertSelf returns this");
  eq(z.a, 0.5, "invertSelf");
  const w = new DOMMatrix([0, 0, 0, 0, 0, 0]).invertSelf();
  ok(Number.isNaN(w.a) && !w.is2D, "invertSelf of a singular matrix");
  throws(() => DOMMatrix.prototype.multiplySelf.call(ro), "TypeError", "multiplySelf needs a DOMMatrix");
  eq(Object.keys(DOMMatrixReadOnly.prototype).length, 22 + 2 + 15 + 3 , "enumerable members of DOMMatrixReadOnly.prototype");
});

test("matrices: fromMatrix, typed arrays, JSON", () => {
  eq(String(DOMMatrix.fromMatrix({ a: 2, d: 3 })), "matrix(2, 0, 0, 3, 0, 0)", "fromMatrix with a b c d e f");
  eq(String(DOMMatrix.fromMatrix({ m11: 2, m42: 7 })), "matrix(2, 0, 0, 1, 0, 7)", "fromMatrix with m members");
  eq(DOMMatrix.fromMatrix({ a: 5, m11: 5 }).a, 5, "equal aliases");
  throws(() => DOMMatrix.fromMatrix({ a: 1, m11: 2 }), "TypeError", "aliases that differ");
  throws(() => DOMMatrix.fromMatrix({ is2D: true, m13: 1 }), "TypeError", "is2D with a 3D value");
  throws(() => DOMMatrix.fromMatrix({ is2D: true, m33: 2 }), "TypeError", "is2D with m33 not 1");
  ok(!DOMMatrix.fromMatrix({ m13: 1 }).is2D, "a 3D value without is2D: 3D");
  ok(DOMMatrix.fromMatrix({ m13: 0, m33: 1 }).is2D, "identity 3D values without is2D: 2D");
  ok(!DOMMatrix.fromMatrix({ is2D: false }).is2D, "is2D: false");
  ok(DOMMatrix.fromMatrix().isIdentity, "fromMatrix()");
  const src = new DOMMatrix("translate3d(1px, 2px, 3px)");
  const copy = DOMMatrix.fromMatrix(src);
  ok(copy !== src && !copy.is2D && copy.m43 === 3, "fromMatrix(matrix) copies");
  ok(DOMMatrix.fromMatrix(src) instanceof DOMMatrix && DOMMatrixReadOnly.fromMatrix(src) instanceof DOMMatrixReadOnly && !(DOMMatrixReadOnly.fromMatrix(src) instanceof DOMMatrix), "the interface's own");
  const f32 = new DOMMatrix([1, 2, 3, 4, 5, 6]).toFloat32Array();
  ok(f32 instanceof Float32Array && f32.length === 16, "toFloat32Array");
  eq(Array.from(f32).join(), "1,2,0,0,3,4,0,0,0,0,1,0,5,6,0,1", "toFloat32Array: column-major");
  const f64 = new DOMMatrix([0.1, 0, 0, 1, 0, 0]).toFloat64Array();
  ok(f64 instanceof Float64Array && f64[0] === 0.1, "toFloat64Array keeps the doubles");
  eq(new DOMMatrix([0.1, 0, 0, 1, 0, 0]).toFloat32Array()[0], Math.fround(0.1), "toFloat32Array rounds");
  eq(String(DOMMatrix.fromFloat32Array(new Float32Array([1, 0, 0, 1, 7, 8]))), "matrix(1, 0, 0, 1, 7, 8)", "fromFloat32Array (6)");
  ok(!DOMMatrix.fromFloat64Array(new Float64Array(16).fill(1)).is2D, "fromFloat64Array (16)");
  throws(() => DOMMatrix.fromFloat32Array(new Float32Array(5)), "TypeError", "fromFloat32Array of five");
  throws(() => DOMMatrix.fromFloat32Array([1, 0, 0, 1, 0, 0]), "TypeError", "fromFloat32Array of an array");
  throws(() => DOMMatrix.fromFloat32Array(new Float64Array(6)), "TypeError", "fromFloat32Array of a Float64Array");
  throws(() => DOMMatrix.fromFloat64Array(), "TypeError", "fromFloat64Array()");
  const json = JSON.parse(JSON.stringify(new DOMMatrix([1, 2, 3, 4, 5, 6])));
  eq(Object.keys(json).join(), "a,b,c,d,e,f," + names.join() + ",is2D,isIdentity", "toJSON: the members in order");
  ok(json.a === 1 && json.m21 === 3 && json.is2D === true && json.isIdentity === false, "toJSON: values");
  const cloned = structuredClone(new DOMMatrix([1, 2, 3, 4, 5, 6]));
  ok(cloned instanceof DOMMatrix && String(cloned) === "matrix(1, 2, 3, 4, 5, 6)" && cloned.is2D, "structuredClone of a 2D matrix");
  const cloned3 = structuredClone(src);
  ok(!cloned3.is2D && cloned3.m43 === 3, "structuredClone of a 3D matrix");
});

test("matrices and points", () => {
  const t = new DOMMatrix().translate(10, 5).scale(2);
  const pt = t.transformPoint(new DOMPoint(1, 1));
  ok(pt instanceof DOMPoint, "transformPoint gives a DOMPoint");
  eq(pt.x + "," + pt.y + "," + pt.z + "," + pt.w, "12,7,0,1", "transformPoint");
  eq(JSON.stringify(t.transformPoint({ x: 1 })), '{"x":12,"y":5,"z":0,"w":1}', "transformPoint takes a DOMPointInit");
  eq(JSON.stringify(t.transformPoint()), '{"x":10,"y":5,"z":0,"w":1}', "transformPoint()");
  const persp = new DOMMatrix("perspective(10px)").transformPoint(new DOMPoint(1, 2, -10, 1));
  ok(near(persp.w, 2) && persp.z === -10, "w comes from the matrix");
  eq(JSON.stringify(new DOMPoint(1, 1).matrixTransform(t)), '{"x":12,"y":7,"z":0,"w":1}', "point.matrixTransform(matrix)");
  eq(JSON.stringify(new DOMPoint(1, 1).matrixTransform({ e: 1 })), '{"x":2,"y":1,"z":0,"w":1}', "point.matrixTransform(DOMMatrixInit)");
  ok(new DOMPointReadOnly(1, 1).matrixTransform(t) instanceof DOMPoint, "a read-only point's result is a DOMPoint");
});

test("quads", () => {
  const q = new DOMQuad({ x: 1, y: 2 }, { x: 5, y: 2 }, { x: 5, y: 7 }, { x: 1, y: 7 });
  ok(q.p1 instanceof DOMPoint && q.p1.x === 1 && q.p3.y === 7, "points");
  eq(q.p2, q.p2, "[SameObject]");
  q.p1.x = 0;
  eq(q.p1.x, 0, "the points are the quad's own");
  const b = q.getBounds();
  ok(b instanceof DOMRect, "getBounds gives a DOMRect");
  eq([b.x, b.y, b.width, b.height].join(), "0,2,5,5", "getBounds");
  q.p3.x = NaN;
  ok(Number.isNaN(q.getBounds().width), "getBounds: NaN-safe");
  const r = DOMQuad.fromRect({ x: 1, y: 2, width: 3, height: 4 });
  eq(r.p1.x + "," + r.p1.y + " " + r.p2.x + "," + r.p2.y + " " + r.p3.x + "," + r.p3.y + " " + r.p4.x + "," + r.p4.y, "1,2 4,2 4,6 1,6", "fromRect");
  const fq = DOMQuad.fromQuad({ p1: { x: 9 }, p3: { y: 3, w: 2 } });
  eq([fq.p1.x, fq.p2.x, fq.p3.y, fq.p3.w, fq.p4.w].join(), "9,0,3,2,1", "fromQuad (absent points are the default point)");
  eq(JSON.stringify(new DOMQuad()), JSON.stringify({ p1: { x: 0, y: 0, z: 0, w: 1 }, p2: { x: 0, y: 0, z: 0, w: 1 }, p3: { x: 0, y: 0, z: 0, w: 1 }, p4: { x: 0, y: 0, z: 0, w: 1 } }), "toJSON");
  throws(() => DOMQuad(), "TypeError", "constructor needs new");
  throws(() => new DOMQuad(5), "TypeError", "a point must be an object");
  eq(Object.prototype.toString.call(q), "[object DOMQuad]", "toStringTag");
});

test("the canvas hands out matrices", () => {
  const g = document.createElement("canvas").getContext("2d");
  g.translate(3, 4);
  const m = g.getTransform();
  ok(m instanceof DOMMatrix && m.is2D, "getTransform gives a 2D DOMMatrix");
  eq(m.e + "," + m.f, "3,4", "its values");
  g.setTransform(new DOMMatrix([2, 0, 0, 2, 1, 1]).translate(1, 1));
  eq(g.getTransform().e, 3, "setTransform takes a DOMMatrix");
});

test("in a worker", async () => {
  const w = new Worker("/jsweb/js/geometry_worker_script.js");
  const answer = await new Promise(resolve => { w.onmessage = e => resolve(e.data); w.postMessage(0); });
  eq(answer, "function,3,2,1,TypeError", "matrices, points and quads exist; a string is refused");
  w.terminate();
});

__run();