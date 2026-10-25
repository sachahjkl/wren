package browser

import "core:fmt"
import "core:math"
import "core:strings"
import "wb:i18n"
import "wb:license"

////////////////////////////////
// The licence card of about:wren, shown when a licence is registered: a dark card with the supporter's name, edition,
// date and order number as raised silver lettering, an engraved iridescent foil that a sweeping light and the pointer play over,
// and a certification seal. Made with the page engine's own CSS and a little JavaScript, and a shader: the foil is
// `-wren-shader: card-foil` (shaders.odin, shaders/card_foil.wgsl, a normal map from about_card_relief.odin, the lettering from
// about_card_engrave.odin), lit over the CSS background of `.base`, which is also what shows where the shader cannot be had; the face of
// the seal is `card-seal` of the same module (`.relief`, a domed medal with a reeded edge, rings and raised lettering: about_card_seal.odin);
//
//  - the card tilts with the pointer (rotateX / rotateY, eased back to rest by a CSS transition) in the perspective of its box
//    (CSS Transforms 2: .cardbox has perspective, .lic preserve-3d): the base with its foil and glare lies at z = 0 and the
//    fallback text 18px above it (the logo is printed on the card, 1px over it, and moves with nothing else). The seal is a medal stuck ON the card: a stack of layers 1 to 9px above the base (its cast shadow,
//    which slides away from the light, the ridged gold edge, the domed green face, a highlight that follows the pointer, the
//    word and the tick embossed on top), so the tilt shows its relief and it never floats; the text slides a little on the
//    pointer. At rest the scales (900 / (900 - z)) cancel the enlargement the perspective gives the lifted layers;
//  - the script runs on pointer events only, applies at most one update per frame (requestAnimationFrame) and never
//    loops: a card at rest, or the pointer still, costs no frame. The sweep is a CSS animation of the registered property
//    --sweep that rests for 60 % of its 7 s: a resting animation asks for no frame either;
//  - the card turns all the way: a "Rotate" button under it (shown when the pointer is over the card or the button has the focus) switches
//    the pointer's tilt off and lets a drag turn the card freely on two axes (rotateX, rotateY, no limit), with a fling that slows down (a CSS
//    transition towards where the speed would take it: no loop, no frame at rest); Done, or Escape, brings it back to the pointer's tilt by the
//    short way. Past a quarter turn the card shows its back: a second face behind the walls, turned half a turn (`.back`, the shader
//    `card-back`, about_card_back.odin: the front's relief inside out, the logo raised in the middle). Both faces are `backface-visibility:
//    hidden`, so that the face turned away is not drawn at all (paint_planes.odin, open_plane). The shaders place the eye and both lights from
//    the turn (--rx, --ry in degrees, registered properties that transition with the transform), the back as an object seen from behind. The
//    page engine has pointermove but no pointerdown / pointerup, and a press carries page coordinates: the drag is made of mouse events,
//    with the position of the last move;
//  - without JavaScript (javascript.enabled off) or with prefers-reduced-motion the card is the same, still, foil at
//    a fixed angle, with no back and no button; a narrow card has neither.

@(private = "file")
CARD_STYLE :: `
  @property --sweep { syntax: '<number>'; inherits: true; initial-value: 0.42; }
  @property --live { syntax: '<number>'; inherits: true; initial-value: 0; }
  @property --bx { syntax: '<percentage>'; inherits: true; initial-value: 50%; }
  @property --by { syntax: '<percentage>'; inherits: true; initial-value: 50%; }
  @property --engrave { syntax: '<number>'; inherits: true; initial-value: 1; }
  @property --rx { syntax: '<number>'; inherits: true; initial-value: 0; }
  @property --ry { syntax: '<number>'; inherits: true; initial-value: 0; }
  .cardbox { width: 100%; max-width: 440px; margin: 16px 0 6px; padding: 12px 0; perspective: 900px; }
  .cardbox.manip { cursor: grab; touch-action: none; user-select: none; }
  .cardbox.manip.drag { cursor: grabbing; }
  /* the card turns about the middle of its thickness (the back lies 8.4px behind the front: CARD_THICKNESS and GAP below), --rx and --ry are the
     same turn in degrees for the shaders (the eye and the lights are placed from it) */
  .lic { position: relative; width: 100%; aspect-ratio: 1.586; box-sizing: border-box; color: #eceff7; transform-style: preserve-3d; transform-origin: 50% 50% -4px;
    transition: transform 0.55s cubic-bezier(0.2, 0.7, 0.2, 1), --rx 0.55s cubic-bezier(0.2, 0.7, 0.2, 1), --ry 0.55s cubic-bezier(0.2, 0.7, 0.2, 1), --bx 0.55s cubic-bezier(0.2, 0.7, 0.2, 1), --by 0.55s cubic-bezier(0.2, 0.7, 0.2, 1); }
  .lic.live { transition: none; }
  .lic > div { position: absolute; }
  .lic .wall { box-sizing: border-box; }
  .lic .base { left: 0; top: 0; right: 0; bottom: 0; box-sizing: border-box; border-radius: 14px; overflow: hidden; background-color: #161a26; backface-visibility: hidden;
    background-image: linear-gradient(150deg, #232a40 0%, #151926 58%, #1c2132 100%); border: 1px solid rgba(255, 255, 255, 0.16);
    -wren-shader: card-foil var(--sweep) var(--bx) var(--by) var(--live) 1 var(--engrave) 0 var(--rx) var(--ry); animation: sweep 7s cubic-bezier(0.45, 0, 0.35, 1) infinite; }
  .lic.live .base, .lic.live .back { --live: 1; animation-play-state: paused; }
  /* the back: the other face, laid behind the walls and turned half a turn; seen from the front it is turned away and not drawn at all (backface-visibility).
     Its foil and its relief are its own (card-back: the front's relief inside out, the logo raised in the middle, a line of lettering); the page's own
     lettering below is the fallback where the shader cannot be had */
  .lic .back { left: 0; top: 0; right: 0; bottom: 0; box-sizing: border-box; border-radius: 14px; overflow: hidden; background-color: #161a26; backface-visibility: hidden;
    transform: translateZ(-8.4px) rotateY(180deg);
    background-image: linear-gradient(210deg, #232a40 0%, #151926 58%, #1c2132 100%); border: 1px solid rgba(255, 255, 255, 0.16);
    -wren-shader: card-back var(--sweep) var(--bx) var(--by) var(--live) 1 var(--engrave) 2 var(--rx) var(--ry); animation: sweep 7s cubic-bezier(0.45, 0, 0.35, 1) infinite; }
  .lic .back .btext { position: absolute; left: 0; right: 0; bottom: 20px; text-align: center; font-size: 10px; letter-spacing: 0.28em; color: rgba(236, 239, 247, 0.55); visibility: hidden; }
  .lic[data-shader=off] .back .btext { visibility: visible; }
  /* the button that turns the card: under it, at its right, shown when the pointer is over the card (or the button has the focus); the script makes it
     ready (no script, no button), and reduced motion and a narrow card have none */
  .flipbar { display: none; justify-content: flex-end; width: 100%; max-width: 440px; height: 30px; margin: -6px 0 0; opacity: 0; transition: opacity 0.18s ease; }
  .flipbar.ready { display: flex; }
  .cardbox:hover + .flipbar.ready, .flipbar.ready:hover, .flipbar.ready:focus-within, .flipbar.ready.manip { opacity: 1; }
  @media (hover: none) { .flipbar.ready { opacity: 1; } }
  .flipbar button.flip { display: inline-flex; align-items: center; margin: 0; padding: 4px 11px 4px 9px; background-color: transparent; color: inherit; font-size: 13px;
    border: 1px solid rgba(127, 127, 127, 0.35); border-radius: 999px; }
  .flipbar button.flip:hover { border-color: rgba(127, 127, 127, 0.8); }
  .flipbar button.flip:focus-visible { outline: 2px solid currentcolor; outline-offset: 2px; }
  .flipbar .ics, .flipbar .lbs { display: inline-grid; }
  .flipbar .ics { margin-right: 7px; width: 1.15em; height: 1.15em; }
  .flipbar .ics svg { grid-area: 1 / 1; width: 1.15em; height: 1.15em; }
  .flipbar .lbs > span { grid-area: 1 / 1; text-align: center; }
  .flipbar .i-on, .flipbar .l-on { visibility: hidden; }
  .flipbar button.flip[data-state=on] .i-off, .flipbar button.flip[data-state=on] .l-off { visibility: hidden; }
  .flipbar button.flip[data-state=on] .i-on, .flipbar button.flip[data-state=on] .l-on { visibility: visible; }
  @keyframes sweep { 0% { --sweep: -0.3; } 40% { --sweep: 1.25; } 100% { --sweep: 1.25; } }
  /* the text is engraved by the shader (data-engrave): the page's own text stays in the document (reading, selecting, copying) but is not drawn;
     it is drawn where the shader is not used: a narrow card, reduced motion, a shader that cannot be had */
  .lic .face { -webkit-text-fill-color: transparent; }
  .lic[data-shader=off] .face { -webkit-text-fill-color: currentcolor; }
  @media (prefers-reduced-motion: reduce) { .lic .base { animation: none; --sweep: 0.42; } .lic { --engrave: 0; } .lic .face { -webkit-text-fill-color: currentcolor; } .lic .back, .flipbar.ready { display: none; } }
  .lic .face { left: 0; top: 0; right: 0; bottom: 0; backface-visibility: hidden; transform: translate3d(0, 0, 18px) scale(0.98); padding: 18px 22px; box-sizing: border-box; display: flex; flex-direction: column; justify-content: space-between;
    transition: transform 0.55s cubic-bezier(0.2, 0.7, 0.2, 1); }
  .lic.live .face, .lic.live .seal .shadow { transition: none; }
  .lic .seal .shadow { transition: transform 0.55s cubic-bezier(0.2, 0.7, 0.2, 1); }
  .lic .top { display: flex; align-items: center; }
  /* the logo is a print on the card, in the base's own plane (1px over it, like the seal's shadow, with no parallax: it turns, tilts and eases back
     with the card and with nothing else; the engraving's relief would break its colours up, and the lettering's layer slides on the pointer);
     the lettering's line leaves room for it */
  .lic .logo { position: absolute; left: 22px; top: 18px; width: 26px; height: 26px; backface-visibility: hidden; transform: translate3d(0, 0, 1px) scale(0.99889);
    filter: drop-shadow(0px 1px 1px rgba(0, 0, 0, 0.55)) drop-shadow(0px -1px 0px rgba(255, 255, 255, 0.18)); }
  .lic .top b { margin-left: 35px; }
  .lic .top b { font-size: 17px; font-weight: 600; letter-spacing: 0.02em; }
  .lic .top span { margin-left: auto; font-size: 11px; letter-spacing: 0.16em; text-transform: uppercase; color: rgba(236, 239, 247, 0.66); }
  .lic .who { font-size: 24px; line-height: 1.2; font-weight: 600; overflow-wrap: anywhere; }
  .lic .mail { font-size: 12px; color: rgba(236, 239, 247, 0.6); overflow-wrap: anywhere; }
  .lic .meta { display: flex; }
  .lic .meta div { margin-right: 26px; }
  .lic .meta small { display: block; font-size: 10px; letter-spacing: 0.14em; text-transform: uppercase; color: rgba(236, 239, 247, 0.5); }
  .lic .meta em { font-style: normal; font-size: 13px; font-variant-numeric: tabular-nums; }
  @media (max-width: 520px) {
    .lic { aspect-ratio: 1.2; --engrave: 0; }
    .lic .back, .flipbar.ready { display: none; }
    .lic .face { -webkit-text-fill-color: currentcolor; }
    .lic .meta { flex-direction: column; }
    .lic .meta div { margin: 0 0 5px 0; }
  }
  .lic .seal { right: 16px; bottom: 14px; width: 88px; height: 88px; transform-style: preserve-3d; }
  .lic .seal > div { position: absolute; box-sizing: border-box; }
  .lic .seal .shadow { left: 0; top: 0; width: 88px; height: 88px; border-radius: 50%; transform: translate3d(3px, 5px, 1px) scale(0.99889); filter: blur(3px);
    background-image: radial-gradient(circle at 50% 50%, rgba(0, 0, 0, 0.6) 60%, rgba(0, 0, 0, 0) 74%); }
  .lic .seal .sw { box-sizing: border-box; }
  .lic .seal .edge { left: 0; top: 0; width: 88px; height: 88px; border-radius: 50%; transform: translate3d(0, 0, 5px) scale(0.99444);
    box-shadow: inset 0 2px 1px rgba(255, 255, 255, 0.55), inset 0 -2px 2px rgba(0, 0, 0, 0.5), 0 1px 0 rgba(0, 0, 0, 0.4);
    background-image: repeating-conic-gradient(from 0deg, #f6e29a 0deg, #f6e29a 1.5deg, #d3a93d 1.5deg, #d3a93d 5deg, #8f6a1c 5deg, #8f6a1c 8deg); }
  .lic .seal .ring { left: 6px; top: 6px; width: 76px; height: 76px; border-radius: 50%; transform: translate3d(0, 0, 6px) scale(0.99333); border: 2px solid #f4df9a;
    box-shadow: inset 0 3px 4px rgba(255, 255, 255, 0.28), inset 0 -5px 7px rgba(0, 0, 0, 0.45), 0 1px 2px rgba(0, 0, 0, 0.55);
    background-image: repeating-radial-gradient(circle at 50% 50%, rgba(255, 255, 255, 0.09) 0px, rgba(255, 255, 255, 0.09) 1px, rgba(255, 255, 255, 0) 1px, rgba(255, 255, 255, 0) 3px), radial-gradient(circle at 34% 28%, #5ad98e, #1f8a52 55%, #0f5a36 100%); }
  .lic .seal .rim { position: absolute; left: 4px; top: 4px; right: 4px; bottom: 4px; border-radius: 50%; border: 1px solid rgba(244, 223, 154, 0.6); }
  .lic .seal .gloss { left: 6px; top: 6px; width: 76px; height: 76px; border-radius: 50%; transform: translate3d(0, 0, 7px) scale(0.99222);
    background-image: radial-gradient(circle at var(--sgx, 32%) var(--sgy, 26%), rgba(255, 255, 255, 0.55), rgba(255, 255, 255, 0) 45%), linear-gradient(140deg, rgba(255, 255, 255, 0.22), rgba(255, 255, 255, 0) 46%); }
  .lic .seal .word { left: 0; top: 48px; width: 88px; height: 10px; transform: translate3d(0, 0, 8px) scale(0.99111); text-align: center; font-size: 8px; line-height: 10px; font-weight: 700; letter-spacing: 0.08em; color: #f7e9b0;
    text-shadow: 0px 1px 0px rgba(0, 0, 0, 0.5), 0px -1px 0px rgba(255, 255, 255, 0.3); }
  .lic .seal .tickwrap { left: 0; top: 0; width: 88px; height: 88px; transform: translate3d(0, 0, 10px) scale(0.98889);
    filter: drop-shadow(0px 2px 1px rgba(0, 0, 0, 0.5)) drop-shadow(0px -1px 0px rgba(255, 255, 255, 0.35)); }
  .lic .seal .tickwrap svg { display: block; }
  /* the face of the seal is drawn by the shader (.relief: a domed green face with fine rings, a reeded gold edge, the word and the tick
     raised); the layers above are its fallback and show where it cannot be had (data-shader=off on the seal), with reduced motion and on a
     narrow card. The cast shadow and the edge's walls stay: they are the seal's thickness. */
  .lic .seal .relief { left: 0; top: 0; width: 88px; height: 88px; border-radius: 50%; transform: translate3d(0, 0, 5px) scale(0.99444);
    -wren-shader: card-seal var(--sweep) var(--bx) var(--by) var(--live) 1 var(--engrave) 1 var(--rx) var(--ry); animation: sweep 7s cubic-bezier(0.45, 0, 0.35, 1) infinite; }
  .lic.live .seal .relief { --live: 1; animation-play-state: paused; }
  .lic .seal .edge, .lic .seal .ring, .lic .seal .gloss, .lic .seal .word, .lic .seal .tickwrap { visibility: hidden; }
  .lic .seal[data-shader=off] .edge, .lic .seal[data-shader=off] .ring, .lic .seal[data-shader=off] .gloss, .lic .seal[data-shader=off] .word, .lic .seal[data-shader=off] .tickwrap { visibility: visible; }
  @media (prefers-reduced-motion: reduce) { .lic .seal .relief { animation: none; --sweep: 0.42; } .lic .seal .edge, .lic .seal .ring, .lic .seal .gloss, .lic .seal .word, .lic .seal .tickwrap { visibility: visible; } }
  @media (max-width: 520px) { .lic .seal .edge, .lic .seal .ring, .lic .seal .gloss, .lic .seal .word, .lic .seal .tickwrap { visibility: visible; } }
`

@(private = "file")
CARD_SCRIPT :: `
(function () {
  var card = document.getElementById("lic");
  if (!card || !card.addEventListener) return;
  if (window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  var box = card.parentNode, bar = document.getElementById("flipbar"), flip = document.getElementById("flip");
  var face = card.querySelector(".face"), shadow = card.querySelector(".seal .shadow");
  // px, py: the pointer on the card, -1 .. 1; ax, ay: the card's turn in degrees (rotateX, rotateY); the pointer's small tilt, or in the
  // manipulation mode (turn) what the drag made of it; va, vb: how fast it turns while dragged, degrees per ms
  var px = 0, py = 0, ax = 0, ay = 0, va = 0, vb = 0, lx = 0, ly = 0, lt = 0, mx = 0, my = 0;
  var queued = false, live = false, turn = false, drag = false, home = 0;
  // the lettering and the logo stand 18px over the card for the pointer's parallax; a card turned all the way has them on it (1px), or they would float
  var lift = true;
  var EASE = "cubic-bezier(0.2, 0.7, 0.2, 1)", K = 0.45;
  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }
  function classes() {
    card.className = live ? "lic live" : "lic";
    box.className = "cardbox" + (turn ? " manip" : "") + (drag ? " drag" : "");
    if (bar) bar.className = "flipbar ready" + (turn ? " manip" : "");
  }
  // an inline transition rules over the sheet's (and over .live's none): the turn and what the shaders read of it ease together, for ms
  function ease(ms, light) {
    follow(ms);
    if (!ms) { card.style.transition = "none"; return; }
    var t = " " + ms + "ms " + EASE, s = "transform" + t + ", --rx" + t + ", --ry" + t;
    card.style.transition = light ? s + ", --bx" + t + ", --by" + t : s;
  }
  // what stands on the card (the fallback lettering, the seal's shadow) slides with its parallax and eases with the card, or it would jump
  // where the card is still on its way (ms: "" gives them back to the sheet's)
  function follow(ms) {
    var s = ms === "" ? "" : ms ? "transform " + ms + "ms " + EASE : "none";
    face.style.transition = s; shadow.style.transition = s;
  }
  function write() {
    queued = false;
    var fx = turn ? 0 : px, fy = turn ? 0 : py;
    card.style.transform = "rotateX(" + ax.toFixed(2) + "deg) rotateY(" + ay.toFixed(2) + "deg)";
    card.style.setProperty("--rx", ax.toFixed(2));
    card.style.setProperty("--ry", ay.toFixed(2));
    card.style.setProperty("--bx", (50 + px * 50).toFixed(1) + "%");
    card.style.setProperty("--by", (50 + py * 50).toFixed(1) + "%");
    face.style.transform = "translate3d(" + (-fx * 5).toFixed(2) + "px," + (-fy * 4).toFixed(2) + "px," + (lift ? "18px) scale(0.98)" : "1px) scale(0.99889)");
    shadow.style.transform = "translate3d(" + (3 - fx * 5).toFixed(2) + "px," + (5 - fy * 4).toFixed(2) + "px,1px) scale(0.99889)";
    card.style.setProperty("--sgx", (50 + px * 28).toFixed(1) + "%");
    card.style.setProperty("--sgy", (50 + py * 28).toFixed(1) + "%");
  }
  function later() { if (!queued) { queued = true; requestAnimationFrame(write); } }
  function where(e) {
    var r = box.getBoundingClientRect();
    px = clamp((e.clientX - r.left) / r.width * 2 - 1, -1, 1);
    py = clamp((e.clientY - r.top) / r.height * 2 - 1, -1, 1);
  }
  // a touch has its own events: the point of an event, whichever device made it
  function pt(e) { return (e.touches && e.touches[0]) || (e.changedTouches && e.changedTouches[0]) || e; }
  // the preference asked at the first move, not only when the script runs (the page's media state is not settled while it is parsed)
  var asked = false;
  function calm() {
    if (asked) return false;
    if (window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches) return true;
    asked = true;
    return false;
  }
  function move(e) {
    if (drag || calm()) return;
    mx = e.clientX; my = e.clientY;
    where(e);
    if (!live) { live = true; classes(); }
    if (!turn) { ax = -py * 14; ay = px * 18; }
    later();
  }
  // while a drag lasts the document follows it (the pointer may leave the card)
  function dragmove(e) {
    var p = pt(e), dt = Math.max(1, e.timeStamp - lt), da = -(p.clientY - ly) * K, db = (p.clientX - lx) * K;
    where(p);
    ax += da; ay += db;
    va = 0.6 * da / dt + 0.4 * va; vb = 0.6 * db / dt + 0.4 * vb;
    lx = p.clientX; ly = p.clientY; mx = lx; my = ly; lt = e.timeStamp;
    later();
    if (e.preventDefault) e.preventDefault();
  }
  function leave() {
    if (drag) return;
    live = false; px = 0; py = 0; queued = false;
    classes();
    if (!turn) { ax = 0; ay = 0; }
    write();
  }
  // the turn as it is on screen now, whatever transition is running
  function current() {
    var cs = getComputedStyle(card), a = parseFloat(cs.getPropertyValue("--rx")), b = parseFloat(cs.getPropertyValue("--ry"));
    if (isFinite(a)) ax = a;
    if (isFinite(b)) ay = b;
  }
  // a style that was written and is read back is the start of the transition the next write begins
  function settle() { void card.offsetWidth; getComputedStyle(card).getPropertyValue("--ry"); }
  // the events that follow a drag: the pointer's, or the mouse's, and the touch's where there is a touch screen
  // (the mouse events, which the engine sends for every device and for the synthetic input of wren ctl: it has pointermove but no pointerdown / up)
  var TOUCH = "ontouchstart" in window;
  function track(on) {
    var f = on ? "addEventListener" : "removeEventListener";
    document[f]("mousemove", dragmove);
    document[f]("mouseup", up);
    if (TOUCH) { document[f]("touchmove", dragmove); document[f]("touchend", up); document[f]("touchcancel", up); }
  }
  function down(e) {
    if (!turn || drag || e.button > 0 || (bar && bar.contains(e.target))) return;
    var p = pt(e);
    current(); ease(0); write();
    // (a press carries its position in the page, not in the window, once the page is scrolled: where the pointer last moved is where it is)
    drag = true; va = 0; vb = 0; lx = e.touches ? p.clientX : mx; ly = e.touches ? p.clientY : my; lt = e.timeStamp;
    track(true);
    classes();
    e.preventDefault();
  }
  // let go: the card keeps turning for a moment, slowing down (a transition towards where its speed would take it: no loop, no frame while it rests)
  function up(e) {
    if (!drag) return;
    drag = false;
    track(false);
    classes();
    if (e.timeStamp - lt > 90) { va = 0; vb = 0; }
    if (Math.abs(va) + Math.abs(vb) > 0.03) {
      write(); settle();
      ax += clamp(va * 380, -300, 300); ay += clamp(vb * 380, -300, 300);
      ease(1000); write();
    }
    var p = e.changedTouches ? pt(e) : { clientX: mx, clientY: my }, r = box.getBoundingClientRect();
    if (p.clientX < r.left || p.clientX > r.right || p.clientY < r.top || p.clientY > r.bottom) leave();
  }
  function enter() {
    turn = true; lift = false; ease(0); follow(300);
    clearTimeout(home);
    flip.setAttribute("data-state", "on"); flip.setAttribute("aria-pressed", "true"); flip.setAttribute("aria-label", flip.getAttribute("data-label-on"));
    classes();
  }
  // back to the pointer's tilt by the short way (the turn modulo a whole turn: the card does not unwind a spin)
  function finish() {
    if (!turn) return;
    current();
    turn = false; drag = false;
    ease(0); ax -= 360 * Math.round(ax / 360); ay -= 360 * Math.round(ay / 360); write(); settle();
    flip.setAttribute("data-state", "off"); flip.setAttribute("aria-pressed", "false"); flip.setAttribute("aria-label", flip.getAttribute("data-label-off"));
    ax = 0; ay = 0; px = 0; py = 0; live = false;
    classes();
    ease(750, true); write();
    clearTimeout(home);
    home = setTimeout(function () { card.style.transition = ""; follow(""); if (!turn) { lift = true; write(); } }, 800);
  }
  function key(e) {
    if (!turn) return;
    if (e.key === "Escape") { finish(); return; }
    var step = { ArrowLeft: [0, -30], ArrowRight: [0, 30], ArrowUp: [30, 0], ArrowDown: [-30, 0] }[e.key];
    if (!step || e.target !== flip && !box.contains(e.target)) return;
    current(); ease(0); write(); settle();
    ax += step[0]; ay += step[1];
    ease(350); write();
    e.preventDefault();
  }
  box.addEventListener(window.PointerEvent ? "pointermove" : "mousemove", move);
  box.addEventListener(window.PointerEvent ? "pointerleave" : "mouseleave", leave);
  if (flip && bar) {
    box.addEventListener("mousedown", down);
    if (TOUCH) box.addEventListener("touchstart", down);
    flip.addEventListener("click", function () { if (turn) finish(); else enter(); });
    document.addEventListener("keydown", key);
    bar.className = "flipbar ready";
  }
})();
`

// The style of the card. Its foil is a shader of the browser (`-wren-shader: card-foil`, shaders.odin, shaders/card_foil.wgsl) lit over the dark
// background below, which is also what shows where the shader cannot be had; the relief it lights is made natively (about_card_relief.odin)
// when the card is first painted, so the page carries no picture of it.
card_css :: proc() -> string { return CARD_STYLE }

// The thickness of the card: a real rim, like a bank card's (0.76mm is about 4px at this size; 8 shows from a tilt of 18 degrees), built from flat faces standing
// edge-on behind the base: the four straight sides, and the rounded corners cut into facets (a quarter circle of CARD_RADIUS in
// CARD_FACETS flat strips). Each face is shaded by its orientation against a light from the top left, so the rim reads as a solid
// when the card tilts. At rest every face is seen edge-on and lies behind the base, so the card is unchanged.
CARD_RADIUS    :: 14.0
CARD_THICKNESS :: 8.0
CARD_FACETS    :: 4
// The faces of the rim stand a hair clear of the planes they meet (the base, the seal's face), by GAP px: planes that touch exactly are
// taken to cross by the compositor (a plane's corners lie on the other's within the rounding of the projection), which splits all of
// them into pieces and loses the seal.
GAP :: 0.2

// A colour between `dark` and `light` for a face whose outward normal points at `angle` (radians, y down).
@(private = "file")
shade :: proc(angle: f64, dark, light: [3]f64) -> [3]int {
	b := 0.5 + 0.5 * (math.cos(angle) * -0.6 + math.sin(angle) * -0.8)
	return {int(dark.r + (light.r - dark.r) * b), int(dark.g + (light.g - dark.g) * b), int(dark.b + (light.b - dark.b) * b)}
}

@(private = "file")
card_walls_html :: proc(sb: ^strings.Builder) {
	r, T :: CARD_RADIUS, CARD_THICKNESS
	dark, light := [3]f64{22, 26, 42}, [3]f64{176, 186, 222}
	wall :: proc(sb: ^strings.Builder, style: string, angle: f64, dark, light: [3]f64) {
		c := shade(angle, dark, light)
		fmt.sbprintf(sb, "<div class=\"wall\" style=\"%s background-color: #%02x%02x%02x;\"></div>", style, c.r, c.g, c.b)
	}
	// the straight sides (outward normal: left 180deg, top 270deg, right 0, bottom 90deg)
	wall(sb, fmt.tprintf("left: %.2fpx; top: %.2fpx; width: %.2fpx; height: calc(100%% - %.2fpx); transform: translateZ(%.2fpx) rotateY(90deg);", -T / 2, r, T, 2 * r, -T / 2 - GAP), math.PI, dark, light)
	wall(sb, fmt.tprintf("left: calc(100%% - %.2fpx); top: %.2fpx; width: %.2fpx; height: calc(100%% - %.2fpx); transform: translateZ(%.2fpx) rotateY(90deg);", T / 2, r, T, 2 * r, -T / 2 - GAP), 0, dark, light)
	wall(sb, fmt.tprintf("left: %.2fpx; top: %.2fpx; width: calc(100%% - %.2fpx); height: %.2fpx; transform: translateZ(%.2fpx) rotateX(90deg);", r, -T / 2, 2 * r, T, -T / 2 - GAP), 1.5 * math.PI, dark, light)
	wall(sb, fmt.tprintf("left: %.2fpx; top: calc(100%% - %.2fpx); width: calc(100%% - %.2fpx); height: %.2fpx; transform: translateZ(%.2fpx) rotateX(90deg);", r, T / 2, 2 * r, T, -T / 2 - GAP), 0.5 * math.PI, dark, light)
	// the corners: 0 top left, 1 top right, 2 bottom right, 3 bottom left; a quarter circle from the angle `a0`
	chord := 2 * r * math.sin(math.PI / (4 * CARD_FACETS))
	for corner in 0 ..< 4 {
		right, bottom := corner == 1 || corner == 2, corner >= 2
		a0 := math.PI * (1 + 0.5 * f64(corner))
		for k in 0 ..< CARD_FACETS {
			a := a0 + (f64(k) + 0.5) * (0.5 * math.PI / CARD_FACETS)
			// the centre of the strip, from the corner's own centre (r from the edges)
			dx, dy := r * math.cos(a), r * math.sin(a)
			x := right ? fmt.tprintf("calc(100%% - %.2fpx)", r - dx + chord / 2) : fmt.tprintf("%.2fpx", r + dx - chord / 2)
			y := bottom ? fmt.tprintf("calc(100%% - %.2fpx)", r - dy + T / 2) : fmt.tprintf("%.2fpx", r + dy - T / 2)
			wall(sb, fmt.tprintf("left: %s; top: %s; width: %.2fpx; height: %.2fpx; transform: translateZ(%.2fpx) rotateZ(%.2fdeg) rotateX(90deg);", x, y, chord, T, -T / 2 - GAP, (a + 0.5 * math.PI) * 180 / math.PI), a, dark, light)
		}
	}
}

// The edge of the seal: a coin's milled rim, SEAL_SIDES flat strips round the circle, from the card (z = 1px) to the face (z = 5px).
// The radius is a hair under the face's, which perspective enlarges, so the rim never shows past it at rest.
SEAL_SIDES :: 32

@(private = "file")
seal_walls_html :: proc(sb: ^strings.Builder) {
	R :: 43.75
	T :: 4.0 - 2 * GAP
	chord := 2 * R * math.sin(math.PI / SEAL_SIDES)
	for i in 0 ..< SEAL_SIDES {
		a := (f64(i) + 0.5) * (2 * math.PI / SEAL_SIDES)
		x, y := 44 + R * math.cos(a) - chord / 2, 44 + R * math.sin(a) - T / 2
		c := shade(a, {96, 66, 14}, {222, 182, 78})
		fmt.sbprintf(sb, "<div class=\"sw\" style=\"left: %.2fpx; top: %.2fpx; width: %.2fpx; height: %.2fpx; transform: translateZ(3px) rotateZ(%.2fdeg) rotateX(90deg); background-color: #%02x%02x%02x;\"></div>", x, y, chord, T, (a + 0.5 * math.PI) * 180 / math.PI, c.r, c.g, c.b)
	}
}

// Lucide's "refresh-cw" (the card is turned) and "check" (done), inline so that they take the button's color and the size of its text.
@(private = "file") ROTATE_ICON :: `<svg class="i-off" xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" viewBox="0 0 24 24"><g fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2"><path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/></g></svg>`
@(private = "file") ROTATE_DONE_ICON :: `<svg class="i-on" xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" viewBox="0 0 24 24"><path fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 6L9 17l-5-5"/></svg>`

// The button under the card that switches it to the manipulation mode (the script makes it ready and drives it): "Rotate" with an icon, "Done"
// while the card is free. Both labels share a grid cell, so the button keeps one width; the accessible name says what a click does.
@(private = "file")
flip_button_html :: proc(sb: ^strings.Builder) {
	fmt.sbprintf(sb, "<div class=\"flipbar\" id=\"flipbar\"><button type=\"button\" class=\"flip\" id=\"flip\" data-state=\"off\" aria-pressed=\"false\" aria-label=\"%s\" data-label-off=\"%s\" data-label-on=\"%s\" title=\"%s\"><span class=\"ics\" aria-hidden=\"true\">%s%s</span><span class=\"lbs\"><span class=\"l-off\">%s</span><span class=\"l-on\" aria-live=\"polite\">%s</span></span></button></div>\n",
		escape_html(i18n.tr("Rotate the card")), escape_html(i18n.tr("Rotate the card")), escape_html(i18n.tr("Done: bring the card back to its tilt")), escape_html(i18n.tr("Turn the card over: drag it to rotate it (Esc to finish)")),
		ROTATE_ICON, ROTATE_DONE_ICON, escape_html(i18n.tr("Rotate")), escape_html(i18n.tr("Done")))
}

// The card of `lic` and the script that moves it. Every field is escaped.
license_card_html :: proc(sb: ^strings.Builder, lic: license.License) {
	e :: proc(s: string) -> string { return escape_html(s) }
	strings.write_string(sb, "<div class=\"cardbox\"><div class=\"lic\" id=\"lic\">")
	card_walls_html(sb)
	fmt.sbprintf(sb, "<div class=\"base\" data-engrave=\"%s\"></div>", e(card_engrave_fields(APP_NAME, license.edition_title(lic.edition), lic.name, lic.email, lic.date, lic.order)))
	fmt.sbprintf(sb, "<img class=\"logo\" src=\"%s\" alt=\"\">", app_logo_url())
	fmt.sbprintf(sb, "<div class=\"face\"><div class=\"top\"><b>%s</b><span>%s</span></div>", APP_NAME, e(license.edition_title(lic.edition)))
	fmt.sbprintf(sb, "<div><div class=\"who\">%s</div>", e(lic.name))
	if lic.email != "" { fmt.sbprintf(sb, "<div class=\"mail\">%s</div>", e(lic.email)) }
	strings.write_string(sb, "</div><div class=\"meta\">")
	if lic.date != "" { fmt.sbprintf(sb, "<div><small>Issued</small><em>%s</em></div>", e(lic.date)) }
	if lic.order != "" { fmt.sbprintf(sb, "<div><small>Order</small><em>%s</em></div>", e(lic.order)) }
	strings.write_string(sb, "</div></div>")
	strings.write_string(sb, "<div class=\"seal\"><div class=\"shadow\"></div>")
	seal_walls_html(sb)
	strings.write_string(sb, "<div class=\"relief\" data-engrave=\"CERTIFIED\"></div><div class=\"edge\"></div><div class=\"ring\"><div class=\"rim\"></div></div><div class=\"gloss\"></div><div class=\"word\">CERTIFIED</div><div class=\"tickwrap\"><svg width=\"88\" height=\"88\" viewBox=\"0 0 88 88\"><path d=\"M31.75 27.5L40.25 36L56.25 17\" fill=\"none\" stroke=\"#fbf0c4\" stroke-width=\"4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg></div></div>")
	// the back: the brand line is what the shader engraves (and what shows where it cannot be had); nothing of the person is on this side
	fmt.sbprintf(sb, "<div class=\"back\" aria-hidden=\"true\" data-engrave=\"%s\"><div class=\"btext\">%s</div></div>", e(back_text()), e(back_text()))
	strings.write_string(sb, "</div></div>\n")
	flip_button_html(sb)
	strings.write_string(sb, "<script>")
	strings.write_string(sb, CARD_SCRIPT)
	strings.write_string(sb, "</script>\n")
}
