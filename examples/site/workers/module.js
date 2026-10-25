// A module worker of tools\workers_e2e.ps1: static and dynamic imports, import.meta.url, importScripts refused.
import { twice } from "./lib/math.js";
import { label } from "/site/workers/lib/label.js";

let importScriptsError = "none";
try { importScripts("lib/classic.js"); } catch (e) { importScriptsError = e.name; }

self.onmessage = async (e) => {
  const dyn = await import("./lib/dynamic.js");
  postMessage([twice(e.data), label, dyn.value, new URL(import.meta.url).pathname, importScriptsError].join(" "));
};
