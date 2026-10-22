package browser

import "core:fmt"
import "core:strings"
import "wb:license"

////////////////////////////////
// The licence card of about:wren, shown when a licence is registered: a dark card with the supporter's name, edition,
// date and order number, an iridescent foil that shifts with the pointer, and a certification seal. Made with the page
// engine's own CSS and a little JavaScript:
//
//  - the card tilts with the pointer (rotateX / rotateY, eased back to rest by a CSS transition) and its layers move by
//    different amounts (the foil, the glare, the text, the seal), which is what gives it depth: Wren's transforms are
//    2D (rotateX/Y are projected without perspective, style/transform.odin), so the tilt alone would only squeeze it;
//  - the script runs on pointer events only, applies at most one update per frame (requestAnimationFrame) and never
//    loops: a card at rest, or the pointer still, costs no frame;
//  - without JavaScript (javascript.enabled off) or with prefers-reduced-motion the card is the same, still, foil at
//    a fixed angle.

@(private = "file")
CARD_STYLE :: `
  .cardbox { width: 100%; max-width: 440px; margin: 16px 0 6px; padding: 12px 0; }
  .lic { position: relative; width: 100%; aspect-ratio: 1.586; box-sizing: border-box; border-radius: 14px; overflow: hidden; color: #eceff7;
    background-color: #161a26; background-image: linear-gradient(150deg, #232a40 0%, #151926 58%, #1c2132 100%);
    border: 1px solid rgba(255, 255, 255, 0.16); transition: transform 0.55s cubic-bezier(0.2, 0.7, 0.2, 1); }
  .lic.live { transition: none; }
  .lic > div { position: absolute; }
  .lic .tex { left: 0; top: 0; right: 0; bottom: 0; background-image: repeating-linear-gradient(115deg, rgba(255, 255, 255, 0.04) 0px, rgba(255, 255, 255, 0.04) 1px, rgba(255, 255, 255, 0) 1px, rgba(255, 255, 255, 0) 4px); }
  .lic .holo { left: 0; top: 0; right: 0; bottom: 0; opacity: 0.19; mix-blend-mode: color-dodge; background-size: 240% 240%; background-position: var(--bx, 35%) var(--by, 30%);
    background-image: linear-gradient(var(--ang, 115deg), rgba(255, 122, 198, 0) 8%, #ff7ac6 22%, #ffd36e 36%, #7dffb2 50%, #6ec7ff 64%, #b48cff 78%, rgba(180, 140, 255, 0) 92%); }
  .lic .glare { left: 0; top: 0; right: 0; bottom: 0; mix-blend-mode: soft-light;
    background-image: radial-gradient(circle at var(--gx, 30%) var(--gy, 24%), rgba(255, 255, 255, 0.5), rgba(255, 255, 255, 0) 55%); }
  .lic .face { left: 0; top: 0; right: 0; bottom: 0; padding: 18px 22px; box-sizing: border-box; display: flex; flex-direction: column; justify-content: space-between; }
  .lic .top { display: flex; align-items: center; }
  .lic .top img { width: 26px; height: 26px; flex: none; margin-right: 9px; }
  .lic .top b { font-size: 17px; font-weight: 600; letter-spacing: 0.02em; }
  .lic .top span { margin-left: auto; font-size: 11px; letter-spacing: 0.16em; text-transform: uppercase; color: rgba(236, 239, 247, 0.66); }
  .lic .who { font-size: 24px; line-height: 1.2; font-weight: 600; overflow-wrap: anywhere; }
  .lic .mail { font-size: 12px; color: rgba(236, 239, 247, 0.6); overflow-wrap: anywhere; }
  .lic .meta { display: flex; }
  .lic .meta div { margin-right: 26px; }
  .lic .meta small { display: block; font-size: 10px; letter-spacing: 0.14em; text-transform: uppercase; color: rgba(236, 239, 247, 0.5); }
  .lic .meta em { font-style: normal; font-size: 13px; font-variant-numeric: tabular-nums; }
  .lic .seal { right: 18px; bottom: 16px; width: 78px; height: 78px; border-radius: 50%;
    background-image: repeating-conic-gradient(from 0deg, #e9c96a 0deg, #e9c96a 4deg, #b88a28 4deg, #b88a28 8deg); }
  .lic .seal .ring { position: absolute; left: 5px; top: 5px; right: 5px; bottom: 5px; border-radius: 50%; border: 2px solid #f4df9a; box-sizing: border-box;
    background-image: repeating-radial-gradient(circle at 50% 50%, rgba(255, 255, 255, 0.10) 0px, rgba(255, 255, 255, 0.10) 1px, rgba(255, 255, 255, 0) 1px, rgba(255, 255, 255, 0) 3px), radial-gradient(circle at 34% 28%, #46c27d, #1f7a47 72%); }
  .lic .seal .gloss { position: absolute; left: 0; top: 0; right: 0; bottom: 0; border-radius: 50%; background-image: linear-gradient(140deg, rgba(255, 255, 255, 0.38), rgba(255, 255, 255, 0) 46%); }
  .lic .seal .tick { position: absolute; left: 29px; top: 13px; width: 11px; height: 21px; border: solid #fbf0c4; border-width: 0 4px 4px 0; transform: rotate(45deg); }
  .lic .seal .word { position: absolute; left: 0; right: 0; top: 46px; text-align: center; font-size: 8.5px; font-weight: 700; letter-spacing: 0.14em; color: #f7e9b0; }
`

@(private = "file")
CARD_SCRIPT :: `
(function () {
  var card = document.getElementById("lic");
  if (!card || !card.addEventListener) return;
  if (window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  var box = card.parentNode, face = card.querySelector(".face"), seal = card.querySelector(".seal");
  var px = 0, py = 0, queued = false, live = false;
  function apply() {
    queued = false;
    card.style.transform = "perspective(900px) rotateX(" + (-py * 14).toFixed(2) + "deg) rotateY(" + (px * 18).toFixed(2) + "deg)";
    card.style.setProperty("--bx", (50 + px * 50).toFixed(1) + "%");
    card.style.setProperty("--by", (50 + py * 50).toFixed(1) + "%");
    card.style.setProperty("--ang", (115 + px * 22).toFixed(1) + "deg");
    card.style.setProperty("--gx", (50 + px * 50).toFixed(1) + "%");
    card.style.setProperty("--gy", (50 + py * 50).toFixed(1) + "%");
    face.style.transform = "translate(" + (-px * 5).toFixed(2) + "px," + (-py * 4).toFixed(2) + "px)";
    seal.style.transform = "translate(" + (px * 7).toFixed(2) + "px," + (py * 6).toFixed(2) + "px)";
  }
  function move(e) {
    var r = box.getBoundingClientRect();
    px = Math.max(-1, Math.min(1, (e.clientX - r.left) / r.width * 2 - 1));
    py = Math.max(-1, Math.min(1, (e.clientY - r.top) / r.height * 2 - 1));
    if (!live) { live = true; card.className = "lic live"; }
    if (!queued) { queued = true; requestAnimationFrame(apply); }
  }
  function leave() {
    live = false; px = 0; py = 0; queued = false;
    card.className = "lic";
    card.style.transform = "perspective(900px) rotateX(0deg) rotateY(0deg)";
    face.style.transform = "translate(0px,0px)";
    seal.style.transform = "translate(0px,0px)";
  }
  box.addEventListener(window.PointerEvent ? "pointermove" : "mousemove", move);
  box.addEventListener(window.PointerEvent ? "pointerleave" : "mouseleave", leave);
})();
`

card_css :: proc() -> string { return CARD_STYLE }

// The card of `lic` and the script that moves it. Every field is escaped.
license_card_html :: proc(sb: ^strings.Builder, lic: license.License) {
	e :: proc(s: string) -> string { return escape_html(s) }
	strings.write_string(sb, "<div class=\"cardbox\"><div class=\"lic\" id=\"lic\">")
	strings.write_string(sb, "<div class=\"tex\"></div>")
	fmt.sbprintf(sb, "<div class=\"face\"><div class=\"top\"><img src=\"%s\" alt=\"\"><b>%s</b><span>%s</span></div>", app_logo_url(), APP_NAME, e(license.edition_title(lic.edition)))
	fmt.sbprintf(sb, "<div><div class=\"who\">%s</div>", e(lic.name))
	if lic.email != "" { fmt.sbprintf(sb, "<div class=\"mail\">%s</div>", e(lic.email)) }
	strings.write_string(sb, "</div><div class=\"meta\">")
	if lic.date != "" { fmt.sbprintf(sb, "<div><small>Issued</small><em>%s</em></div>", e(lic.date)) }
	if lic.order != "" { fmt.sbprintf(sb, "<div><small>Order</small><em>%s</em></div>", e(lic.order)) }
	strings.write_string(sb, "</div></div>")
	strings.write_string(sb, "<div class=\"holo\"></div><div class=\"glare\"></div>")
	strings.write_string(sb, "<div class=\"seal\"><div class=\"ring\"></div><div class=\"gloss\"></div><div class=\"tick\"></div><div class=\"word\">CERTIFIED</div></div>")
	strings.write_string(sb, "</div></div>\n<script>")
	strings.write_string(sb, CARD_SCRIPT)
	strings.write_string(sb, "</script>\n")
}
