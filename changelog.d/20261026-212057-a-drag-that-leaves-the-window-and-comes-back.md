type: Added

**A drag that leaves the window and comes back gets `drop` before `dragend`**: the system's drag asks the page at once while it runs (toolkit `drop_sync_set`), and `dragend` carries the effect of the drop. The interface thread now starts OLE first (`platform.dragdrop_thread_init`): an image decoder had put it in the multithreaded apartment, and the window was no drop target at all. `wren ctl drag` takes points in between (`drag x,y x,y ... x2,y2`): a point outside the window plays the system's drag through the window's own drop target, never the real mouse.
