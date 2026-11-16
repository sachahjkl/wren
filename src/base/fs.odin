package base

// The temporary directory and the recursive delete now live in the toolkit's fsx package (toolkit:fsx), with the file
// helpers of files.odin; base keeps the historic names as aliases so callers do not change. remove_tree no longer
// follows a junction or symbolic link to a directory (fsx uses path_kind, not os.is_dir): the link is removed, its
// target is left alone.

import "toolkit:fsx"

temp_dir :: fsx.temp_dir
remove_tree :: fsx.remove_tree
