type: Fixed

**A wait for load (`wren ctl wait load`, `nav`, captures) waits for a page whose script engine is not there yet**: the tab's document is loaded when its readyState is complete, read from the page itself; a page whose first parser-blocking script was still on its way was taken for one without scripts, so a capture of odin-lang.org was blank. `wrentool shots` takes a page that never rests (its videos play) as it is, not as missing.
