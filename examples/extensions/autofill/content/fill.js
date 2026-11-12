// run_at document_idle, the top document only: reads the login form and fills it, as a password manager does. It
// answers tabs.sendMessage({type: "fill"}) with another login.
"use strict";

function fill(user, pass) {
  const form = document.querySelector("form");
  if (!form) return false;
  const name = form.querySelector('input[type="text"], input[type="email"], input:not([type])');
  const secret = form.querySelector('input[type="password"]');
  if (!name || !secret) return false;
  for (const [input, value] of [[name, user], [secret, pass]]) {
    input.value = value;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
    input.classList.add("wren-ext-filled");
  }
  return true;
}

const filled = fill("alice", "s3cret");
chrome.runtime.sendMessage({ type: "filled", detail: String(filled) });

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.type === "fill") {
    sendResponse({ filled: fill(message.user, message.pass), from: sender.id === chrome.runtime.id });
  }
  return false;
});

// the world posts to the page: the page's listener gets it
window.postMessage({ fromContent: "hello page" }, "*");
