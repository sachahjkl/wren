type: Fixed

**The sampling profiler works on real pages**: `WREN_SAMPLE_STACK=1` and `WREN_SAMPLE_THREADS=1` no longer end the browser (cnn.com), and `WREN_SAMPLE_THREADS=1` sees short bursts of work (repeated loads of p10k: 123 of 145 samples running, 0 of 44 807 before).
