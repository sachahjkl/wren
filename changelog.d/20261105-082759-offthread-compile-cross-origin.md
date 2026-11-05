type: Fixed

**A large script of another origin is compiled once**: what a compile thread made of a classic script fetched without CORS (the scripts of a CDN) was never found, and the script was compiled again on the window thread.
