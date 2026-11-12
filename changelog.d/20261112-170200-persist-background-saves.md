type: Changed

**Saving the profile no longer pauses the window**: the session, the pinned tabs, the closed tabs, the cookies, the HSTS hosts, the downloads list and the palette's usage are written by background threads. The session is made again only after a tab changed, and the check that a downloaded file is still there no longer runs on the interface thread.
