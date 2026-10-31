// The small platform pieces of runtime/web_compat.c in a window (the jsdom test compat.html has the rest): the dialogs that
// are not shown, the visual viewport, permissions, document.fonts, in a worker too where it has them.

test("dialogs that are not shown", () => {
  eq(alert("a"), undefined, "alert");
  eq(confirm("c"), false, "confirm");
  eq(prompt("p", "d"), null, "prompt");
  eq(alert(), undefined, "alert()");
  throws(() => alert(Symbol()), "TypeError", "a message that cannot be converted");
});

test("the visual viewport", () => {
  const vv = visualViewport;
  ok(vv instanceof VisualViewport && vv instanceof EventTarget && vv === visualViewport, "a VisualViewport, the same each time");
  eq([vv.offsetLeft, vv.offsetTop, vv.scale].join(), "0,0,1", "no offset, no zoom");
  eq(vv.pageLeft + "," + vv.pageTop, scrollX + "," + scrollY, "page offsets are the scroll offsets");
  eq(vv.width, document.documentElement.clientWidth, "width");
  eq(vv.height, document.documentElement.clientHeight, "height");
  eq(Object.prototype.toString.call(vv), "[object VisualViewport]", "toStringTag");
  throws(() => Object.getOwnPropertyDescriptor(VisualViewport.prototype, "width").get.call({}), "TypeError", "illegal invocation");
  let heard = "";
  vv.addEventListener("resize", e => { heard += "r" + e.isTrusted; });
  vv.onscroll = () => { heard += "s"; };
  window.dispatchEvent(new Event("resize"));
  window.dispatchEvent(new Event("scroll"));
  eq(heard, "rtrues", "the window's resize and scroll reach the viewport");
  visualViewport = 5;
  eq(visualViewport, 5, "[Replaceable]");
});

test("permissions", async () => {
  const p = navigator.permissions;
  ok(p instanceof Permissions && p === navigator.permissions, "navigator.permissions");
  const states = {};
  for (const name of ["clipboard-write", "fullscreen", "clipboard-read", "persistent-storage", "storage-access", "camera", "geolocation"]) {
    states[name] = (await p.query({ name })).state;
  }
  eq(JSON.stringify(states), '{"clipboard-write":"granted","fullscreen":"granted","clipboard-read":"prompt","persistent-storage":"prompt","storage-access":"prompt","camera":"denied","geolocation":"denied"}', "the state of each power");
  const s = await p.query({ name: "camera" });
  ok(s instanceof PermissionStatus && s instanceof EventTarget && s.name === "camera" && s.onchange === null, "a PermissionStatus");
  eq(Object.prototype.toString.call(s), "[object PermissionStatus]", "toStringTag");
  await rejects(p.query(), "TypeError", "query()");
  await rejects(p.query(5), "TypeError", "query(5)");
  await rejects(p.query({}), "TypeError", "no name");
  await rejects(p.query({ name: "nope" }), "TypeError", "an unknown name");
  await rejects(Permissions.prototype.query.call({}, { name: "camera" }), "TypeError", "illegal invocation");
  throws(() => new Permissions(), "TypeError", "no constructor");
});

test("document.fonts", async () => {
  const f = document.fonts;
  ok(f instanceof FontFaceSet && f === document.fonts && f instanceof EventTarget, "a FontFaceSet, the same each time");
  eq(f.status, "loaded", "status");
  const ready = f.ready;
  ok(ready instanceof Promise && ready === f.ready && (await ready) === f, "ready: one promise of the set");
  const loaded = await f.load("12px Arial");
  ok(Array.isArray(loaded) && loaded.length === 0, "load");
  await rejects(f.load(), "TypeError", "load()");
  eq(f.check("12px Arial"), true, "check");
  let heard = 0;
  f.onloading = () => heard++;
  f.dispatchEvent(new Event("loading"));
  eq(heard, 1, "event handler attributes");
});

test("Element.scrollIntoViewIfNeeded", () => {
  const d = document.createElement("div");
  d.style.cssText = "margin-top: 5000px; height: 10px";
  document.body.append(d);
  eq(typeof d.scrollIntoViewIfNeeded, "function", "exists");
  eq(d.scrollIntoViewIfNeeded.length, 1, "length");
  eq(Object.keys(Element.prototype).includes("scrollIntoViewIfNeeded"), false, "not enumerable");
  throws(() => Element.prototype.scrollIntoViewIfNeeded.call({}), "TypeError", "illegal invocation");
  d.remove();
});

test("in a worker", async () => {
  const w = new Worker("/jsweb/js/compat_worker_script.js");
  const answer = await new Promise(resolve => { w.onmessage = e => resolve(e.data); w.postMessage(0); });
  eq(answer, "true,true,loaded,true,true,clipboard-write,granted,true,undefined,undefined,undefined,undefined", "fonts and permissions; no viewport, no dialogs");
  w.terminate();
});

test("getComputedStyle: shorthands", () => {
  const d = document.createElement("div");
  d.style.cssText = "border-radius:4px 8px;border:1px solid red;margin:1px 2px;padding:3px;gap:2px;inset:1px 2px 3px 4px;flex:2 3 10px;mask-image:url(x.svg);outline:1px solid blue;font:italic 700 12px/20px serif";
  document.body.appendChild(d);
  const c = getComputedStyle(d);
  eq(c.borderRadius, "4px 8px", "border-radius");
  eq(Number.parseInt(c.borderRadius), 4, "a number can be read from it");
  eq(getComputedStyle(document.body).borderRadius, "0px", "border-radius unset");
  eq(getComputedStyle(document.body).borderTopLeftRadius, "0px", "border-top-left-radius unset");
  eq(c.border, "1px solid rgb(255, 0, 0)", "border, all sides alike");
  eq(c.borderWidth, "1px", "border-width");
  eq(c.padding, "3px", "padding in its shortest form");
  eq(c.gap, "2px", "gap");
  eq(c.inset, "1px 2px 3px 4px", "inset");
  eq(c.flex, "2 3 10px", "flex");
  eq(c.outline, "rgb(0, 0, 255) solid 1px", "outline");
  eq(c.font, "italic 700 12px / 20px serif", "font");
  ok(c.maskImage.startsWith('url("') && c.maskImage.endsWith('x.svg")'), "mask-image");
  d.style.borderLeftWidth = "5px";
  eq(c.border, "", "border, sides that differ: no value");
  d.remove();
});

__run();
