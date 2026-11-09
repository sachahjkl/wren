type: Changed

Partial redraw reaches the page (gui_toolkit 0.136.0, `draw.replay` compare): a frame that changes only the interface (a key in the address bar, a hover) no longer draws the page again; a page draws again only where its pictures changed.
