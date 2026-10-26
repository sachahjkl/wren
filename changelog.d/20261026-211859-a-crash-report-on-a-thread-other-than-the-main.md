type: Fixed

**A crash report on a thread other than the main one** no longer needs the stack to make a thread: the thread that writes it is made at start-up and the handler only wakes it (a stack overflow on a thread leaves one page; making a thread took more on some versions of Windows and the handler died of its own access violation, without a report).
