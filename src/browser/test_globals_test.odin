package browser

import "core:sync"

// Tests that use the shell's globals (page_render: its fonts and settings) run one at a time: the test runner runs
// tests on several threads.
@(private = "file")
page_render_test_mutex: sync.Mutex

page_render_test_lock :: proc() { sync.mutex_lock(&page_render_test_mutex) }
page_render_test_unlock :: proc() { sync.mutex_unlock(&page_render_test_mutex) }
