type: Fixed

**The page package's file storage no longer hands folders to the Windows shell** (src/page/fs_store.odin): removing a folder tree (an origin's OPFS, a cleared entry) goes through ase.remove_tree, one entry at a time, as os.remove_all asked SHFileOperationW, which crashed the AddressSanitizer unit tests of page after worker threads had run (CI).
