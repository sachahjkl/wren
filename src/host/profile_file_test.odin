package host

import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"

@(test)
file_retry_grows_to_its_last :: proc(t: ^testing.T) {
	testing.expect_value(t, file_retry_ms(1), FILE_RETRY_FIRST_MS)
	testing.expect_value(t, file_retry_ms(2), 2 * FILE_RETRY_FIRST_MS)
	testing.expect_value(t, file_retry_ms(100), FILE_RETRY_LAST_MS)
}

@(private = "file")
test_dir :: proc() -> string {
	dir := strings.concatenate({base.temp_dir(context.temp_allocator), "/wren-profile-file-", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	return dir
}

@(private = "file")
read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : "(absent)"
}

// The texts given while a write runs: only the newest reaches the disk, after the pool's write, and a removal after it.
@(test)
profile_write_keeps_the_newest_text :: proc(t: ^testing.T) {
	dir := test_dir()
	defer base.remove_tree(dir)
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	p: Blocking_Pool
	blocking_init(&p, &l, 1)
	w: File_Writer
	file_writer_init(&w, &l, &p)
	path := strings.concatenate({dir, "/a.txt"}, context.temp_allocator)
	profile_write(&w, path, "one")
	profile_write(&w, path, "two")
	profile_write(&w, path, "three")
	blocking_settle(&p)
	testing.expect_value(t, read_text(path), "three")
	profile_remove(&w, path)
	file_writer_flush(&w)
	testing.expect_value(t, read_text(path), "(absent)")
	profile_write(&w, path, "late")   // closing: written at once
	testing.expect_value(t, read_text(path), "late")
	blocking_destroy(&p)
	file_writer_destroy(&w)
}

// A writer that is not set up writes on the calling thread (unit tests, tools).
@(test)
profile_write_without_a_writer :: proc(t: ^testing.T) {
	dir := test_dir()
	defer base.remove_tree(dir)
	path := strings.concatenate({dir, "/b.txt"}, context.temp_allocator)
	profile_write(nil, path, "now")
	testing.expect_value(t, read_text(path), "now")
	w: File_Writer
	profile_remove(&w, path)
	testing.expect_value(t, read_text(path), "(absent)")
}
