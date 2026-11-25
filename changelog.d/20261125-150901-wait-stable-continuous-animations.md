type: Fixed

**Remote wait for stable on animated pages**: `wren ctl wait stable` and `Wren.wait` now complete once layout, style, and pending page updates settle, instead of timing out on pages with continuous CSS or Web animations or playing media.
