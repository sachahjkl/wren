type: Fixed

**Downloads end cleanly in every case**: a download stopped when the browser closes is marked cancelled with its end time and saved to the list, its temporary file is removed exactly once, and a download being moved to its place can no longer be cancelled halfway. The Save dialog and the folder picker run on a thread of their own, so a dialog left open does not hold back other downloads' writes or the profile's saves. Without a chosen place, the free file name is found off the interface thread.
