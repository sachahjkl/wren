type: Fixed

**A read of freed memory when an image left the cache**: the last request of an entry already out of the index freed it, then looked at it again to see whether the cache was over its limit, which it then only sometimes enforced.
