type: Changed

**The JavaScript collection no longer walks the whole heap for finalizers**: the host objects that have one are listed, which takes about a quarter off each collection; strings without references skip the marking list.
