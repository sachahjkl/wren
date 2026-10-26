type: Fixed

Image decoding threads end after `images.decode.thread_idle_ms` of idleness and start again on demand: the stack a large decode commits (about 14 MB per thread for an AVIF) goes back to the system. A job still belongs to one owner at a time (its holders keep an identifier, not a pointer).
