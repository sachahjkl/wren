// A script registered with scripting.registerContentScripts (run_at document_end).
"use strict";
document.documentElement.setAttribute("data-ext-late", document.readyState);
