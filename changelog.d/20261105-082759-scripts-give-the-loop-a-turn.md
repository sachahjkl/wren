type: Changed

**A page paints while its scripts load**: ready scripts ran one after the other until none was left, with no frame and no network between them. Past `javascript.load.pump_slice_ms` (50) the loop gets a turn. Twelve scripts of 100 ms behind a stylesheet: first paint 1 222 -> 322 ms. DOMContentLoaded comes later on some pages (frames run between the scripts).
