type: Fixed

**A page with a very large Web Audio graph no longer freezes.** A graph that took longer to render than it plays held the lock of the audio thread almost all the time, and each call of the page into it could wait for seconds. The page now goes first.
