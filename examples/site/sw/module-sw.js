// A module service worker of tools\sw_e2e.ps1 ({type: "module"}): a static import, importScripts refused, answered by
// message.
import { tag } from "./module-lib.js";
let imports = "allowed";
try { importScripts("module-lib.js"); } catch (e) { imports = e.name; }
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("message", (e) => e.source.postMessage("module:" + tag + " " + imports));
