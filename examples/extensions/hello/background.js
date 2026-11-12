// The background service worker of the test fixture. Its listeners are added in its first run, as Chrome requires.
"use strict";

chrome.runtime.onInstalled.addListener((details) => {
  chrome.storage.local.set({ installed: details.reason });
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  switch (message && message.type) {
    case "echo":
      sendResponse({ echo: message.value, from: sender.url, id: sender.id });
      return false;
    case "later":
      // an answer after the listener returned: it says so by returning true
      setTimeout(() => sendResponse({ later: message.value }), 10);
      return true;
    case "promise":
      return Promise.resolve({ promised: message.value });
    case "storage":
      chrome.storage.local.get(message.key).then((items) => sendResponse(items));
      return true;
    case "alarm":
      chrome.alarms.create(message.name, { delayInMinutes: message.minutes });
      sendResponse({ created: message.name });
      return false;
    case "ignored":
      return false;
  }
  return false;
});

chrome.runtime.onConnect.addListener((port) => {
  port.onMessage.addListener((m) => {
    if (m === "close") { port.disconnect(); return; }
    port.postMessage({ echo: m, name: port.name });
  });
});

chrome.alarms.onAlarm.addListener((alarm) => {
  chrome.storage.local.set({ lastAlarm: alarm.name });
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.ping) {
    chrome.storage.session.set({ pong: changes.ping.newValue });
  }
});
