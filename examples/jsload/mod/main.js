import { b } from "./b.js";
import data from "./data.json" with { type: "json" };
import * as again from "./c.js";
console.log("module main", b, data.x, again.c, import.meta.url.endsWith("/jsload/files/mod/main.js"), typeof document.currentScript, document.currentScript);
