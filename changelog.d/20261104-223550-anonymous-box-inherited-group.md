type: Fixed

**A crash on restyled pages with anonymous boxes** (getbootstrap.com, after following a link): a paint-only restyle wrote the new values of a parent into an inherited group of an earlier pass (`layout.refresh`): an access violation in `copy_prop` where that memory was gone, a silent write into another element's style where it was recycled.
