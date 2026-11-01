// A module service worker of src\tools\e2e\sw.odin ({type: "module"}): a static import, importScripts refused, answered by
// message.
import { tag } from "./module-lib.js";
let imports = "allowed";
try { importScripts("module-lib.js"); } catch (e) { imports = e.name; }
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("message", (e) => e.source.postMessage("module:" + tag + " " + imports));
