// The popup of the test fixture: its text comes from the catalogue, its answer from the background (which starts for it
// when it is stopped).
"use strict";

document.getElementById("title").textContent = chrome.i18n.getMessage("popupText");
document.getElementById("greeting").textContent = chrome.i18n.getMessage("greeting", ["popup"]);
chrome.runtime.sendMessage({ type: "echo", value: "ready" }).then(
  (answer) => { document.getElementById("answer").textContent = "background: " + answer.echo; },
  (error) => { document.getElementById("answer").textContent = "error: " + error.message; },
);
