// Wren's testharnessreport.js: served by tools/testserver (wpt.go) in place of WPT's own at
// /resources/testharnessreport.js. testharness.js loads it right after itself, in the page (worker tests report through
// their page: fetch_tests_from_worker).
//
// The harness runs without its own timeout (explicit_timeout: the runner, src/tools/wpt, calls timeout() when the
// test's time is up, as wptrunner does) and without its HTML output. When it completes, the results go to the runner
// as one console message: "WPTRESULT " + JSON {status, message, tests: [{name, status, message}]} with testharness.js's
// numeric statuses (harness: 0 OK, 1 ERROR, 2 TIMEOUT, 3 PRECONDITION_FAILED; tests: 0 PASS, 1 FAIL, 2 TIMEOUT,
// 3 NOTRUN, 4 PRECONDITION_FAILED). Messages are cut to keep the line reasonable.
(function () {
  "use strict";
  var MAX_MESSAGE = 2000;
  function cut(s) {
    if (s === null || s === undefined) { return null; }
    s = String(s);
    return s.length > MAX_MESSAGE ? s.slice(0, MAX_MESSAGE) + "..." : s;
  }
  // the console the page started with: a test replacing console.log must not swallow the report
  var log = console.log.bind(console);
  setup({ output: false, explicit_timeout: true });
  add_completion_callback(function (tests, status) {
    var out = { status: status.status, message: cut(status.message), tests: [] };
    for (var i = 0; i < tests.length; i++) {
      out.tests.push({ name: String(tests[i].name), status: tests[i].status, message: cut(tests[i].message) });
    }
    log("WPTRESULT " + JSON.stringify(out));
  });
})();
