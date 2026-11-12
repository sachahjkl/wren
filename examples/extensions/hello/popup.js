// The popup of the test fixture: its text comes from the catalogue, its answer from the background (which starts for it
// when it is stopped).
"use strict";

document.getElementById("title").textContent = chrome.i18n.getMessage("popupText");
document.getElementById("greeting").textContent = chrome.i18n.getMessage("greeting", ["popup"]);
chrome.runtime.sendMessage({ type: "echo", value: "ready" }).then(
  (answer) => { document.getElementById("answer").textContent = "background: " + answer.echo; },
  (error) => { document.getElementById("answer").textContent = "error: " + error.message; },
);

// What the e2e test of the panel watches (src/tools/e2e/extensions.odin): a click and a key reach this document, and
// "?close" closes the popup once the background answered (window.close(), as an extension's popup may).
document.addEventListener("click", () => { document.title = "clicked"; });
document.addEventListener("keydown", (event) => { if (event.key !== "Escape") document.title = "key " + event.key; });
if (location.search === "?close") {
  chrome.runtime.sendMessage({ type: "echo", value: "close" }).then(() => window.close());
}
