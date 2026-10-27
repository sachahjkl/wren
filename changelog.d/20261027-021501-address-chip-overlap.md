type: Fixed

**The address bar's chip no longer covers the address on the frame it appears** (`security_chip_measure`): its width is worked out from its icon and label while building instead of read back from the last layout, so opening about:config from a page without a chip no longer left "about:config" drawn over "Settings" until something else was redrawn.
