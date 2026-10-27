#+build !windows
package fetch

// A hidden file of folder_listing: a dot file.
@(private)
HIDDEN_NAME :: ".hidden.txt"

@(private)
mark_hidden :: proc(path: string) {}
