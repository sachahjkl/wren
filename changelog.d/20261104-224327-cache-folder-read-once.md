type: Fixed

**Closing a window no longer waits for the disk caches to read their folder.** The compiled-code and bytecode caches read their whole folder at each write (1.5 s with 13 000 files, while a page loads, and again at the close): once a run now, and when the limit may be reached.
