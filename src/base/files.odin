package base

// The whole-file and positional file operations the stores share (the HTTP cache, the blocker's compiled lists) now
// live in the toolkit's platform-neutral fsx package (toolkit:fsx); base keeps the historic names (base.file_*) as
// aliases so callers do not change. See fsx for the guarantees each one gives, on every system.

import "toolkit:fsx"

Dir_File :: fsx.Dir_File

file_read_all :: fsx.read_all
file_write_atomic :: fsx.write_atomic
file_write_parts :: fsx.write_parts
file_replace :: fsx.replace
file_delete :: fsx.delete_file
file_stat :: fsx.stat
file_read_at :: fsx.read_at
make_dirs :: fsx.make_dirs
list_files :: fsx.list_files
