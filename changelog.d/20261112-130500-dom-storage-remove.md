type: Changed

**Removing a Web Storage key takes constant time.** After a removal, the last key takes the place of the removed one in the `key(n)` order, as the Web Storage standard allows.
