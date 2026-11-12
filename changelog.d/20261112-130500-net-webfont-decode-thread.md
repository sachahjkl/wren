type: Changed

**Web fonts are decoded off the page's thread**: a WOFF2 font that was not decoded before is unpacked on a background thread, so scripts and painting do not wait for it. A font decoded before is still used at once.
