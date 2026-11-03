// Wren's testdriver-vendor.js: served by tools/testserver (wpt.go) in place of WPT's own at
// /resources/testdriver-vendor.js, which testdriver.js pages load right after it. The runner (src/tools/wpt) drives no
// input: test_driver's actions (click, send_keys, action_sequence, bless...) fail at once, "not implemented by
// testdriver-vendor.js", instead of waiting for a person's click or key press until the test's time is up.
window.test_driver_internal.in_automation = true;
