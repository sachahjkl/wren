type: Fixed

**`MediaSource.isTypeSupported` and `canPlayType` no longer say no at random on Windows**: while one thread was starting Media Foundation, the others were told it had failed, so a worker that asked early was refused every codec.
