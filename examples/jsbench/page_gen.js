// Prints a synthetic "page bundle": the shape of a framework-heavy web page's scripts (hundreds of modules with
// functions, classes, closures, option objects, string constants and a few thousand live objects), for memory work.
//   qjs examples/jsbench/page_gen.js > build/page.js        (any engine with console.log/print will do)
// Run the bundle with: jsengine mem -image build/js/wren_js.wasm build/page.js   (prints "page checksum N")
var N = 400;
var out = [];
function w(s) { out.push(s); }
w("var window = (typeof globalThis !== 'undefined') ? globalThis : this; window.mods = []; window.registry = {};");
w("class Base { constructor(el) { this.el = el; this.listeners = {}; this.id = Base.next++; } on(ev, fn) { (this.listeners[ev] || (this.listeners[ev] = [])).push(fn); return this; } emit(ev, a) { var l = this.listeners[ev]; if (l) { for (var i = 0; i < l.length; i++) l[i].call(this, a); } } } Base.next = 1;");
for (var i = 0; i < N; i++) {
  w("(function (g) { 'use strict';");
  w("  var cfg" + i + " = { name: 'module_" + i + "', version: '1." + i + ".0', opts: { a: " + i + ", b: 'option-" + i + "', c: [1, 2, 3, " + i + "] }, handlers: {}, tags: ['alpha', 'beta', 'gamma_" + (i % 17) + "'] };");
  w("  var cache" + i + " = Object.create(null), hits" + i + " = 0;");
  w("  function helperA" + i + "(a, b) { if (a > b) { return a - b + cfg" + i + ".opts.a; } for (var k = 0; k < 3; k++) { a += k * b; } return a + cfg" + i + ".opts.a; }");
  w("  function helperB" + i + "(s) { var key = s + ':' + hits" + i + "++; if (cache" + i + "[key]) return cache" + i + "[key]; var r = s.split('').reverse().join('') + '_" + i + "'; cache" + i + "[key] = r; return r; }");
  w("  function helperC" + i + "(list, fn) { var out = []; for (var j = 0; j < list.length; j++) { var v = fn(list[j], j); if (v !== undefined) out.push(v); } return out; }");
  w("  class Widget" + i + " extends Base {");
  w("    constructor(el) { super(el); this.state = { open: false, items: [], label: 'widget " + i + "' }; this.opts = Object.assign({}, cfg" + i + ".opts); }");
  w("    add(label, n) { this.state.items.push({ label: label, n: n, tag: cfg" + i + ".tags[n % 3] }); this.emit('change', this.state.items.length); return this; }");
  w("    render() { return `<div class=\"w${this.id}\" data-m=\"" + i + "\">${this.state.items.map(x => `<span class=\"${x.tag}\">${x.label}:${x.n}</span>`).join('')}</div>`; }");
  w("    toggle() { this.state.open = !this.state.open; this.emit('toggle', this.state.open); return this.state.open; }");
  w("    get size() { return this.state.items.length; }");
  w("    static create(el) { return new Widget" + i + "(el); }");
  w("  }");
  w("  var api = { id: " + i + ", Widget: Widget" + i + ", helperA: helperA" + i + ", helperB: helperB" + i + ", helperC: helperC" + i + ", cfg: cfg" + i + " };");
  w("  g.mods.push(api); g.registry['module_" + i + "'] = api;");
  w("})(window);");
}
w("var live = [], total = 0;");
w("for (var m = 0; m < window.mods.length; m++) {");
w("  var mod = window.mods[m]; var wd = mod.Widget.create({ tagName: 'DIV', id: 'el' + m });");
w("  for (var q = 0; q < 8; q++) wd.add('item ' + q + ' of ' + m, q);");
w("  wd.on('change', function (n) { total += n; }); wd.toggle(); live.push(wd);");
w("  total += mod.helperA(m, 3) + mod.helperB('abc' + m).length + mod.helperC([1, 2, 3, 4], function (x, i) { return x * i; }).length + wd.render().length + wd.size;");
w("}");
w("var data = []; for (var r = 0; r < 3000; r++) { data.push({ id: r, name: 'row ' + r, tags: ['t' + (r % 7), 'u' + (r % 11)], meta: { created: r * 1000, flags: { a: r % 2 === 0, b: r % 3 === 0 } } }); }");
w("var parsed = JSON.parse(JSON.stringify(data)); total += parsed.length + parsed[2999].meta.created;");
w("console.log('page checksum ' + total);");
console.log(out.join("\n"));
