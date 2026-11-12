type: Changed

**Extension popups open under their button**: a click on an extension's toolbar button shows its popup in a panel under the button, sized to its content (25 x 25 to 800 x 600 CSS pixels), instead of in a new tab. The panel takes the keyboard and the pointer over it; it closes on Escape, on a click outside it, on a second click on the button, when the popup calls `window.close()`, and when another tab is shown.
