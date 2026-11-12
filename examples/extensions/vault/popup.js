// The popup of the phase 2 fixture (also shown in its popout window: popup.html?popout).
"use strict";

document.getElementById("where").textContent = location.search === "?popout" ? "in the popout window" : "in the popup";
