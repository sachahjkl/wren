type: Changed

**A page paints while its scripts load**: ready scripts ran one after the other until none was left, with no frame and no network between them. Past `javascript.load.pump_slice_ms` (50) the loop gets a turn. bbc.com's first paint 3.4 s -> 0.9 s, cnn.com's 7.7 s -> 1.4 s.
