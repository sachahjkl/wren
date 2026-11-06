type: Changed

**Script functions that never run cost almost nothing to load**: a script's bytecode is read and checked one function at a time, when the function first runs, so reading scripts on the page's thread takes about half the time on heavy pages (cnn.com 207 to 75 ms, npr.org 108 to 44 ms) and they take less memory.
