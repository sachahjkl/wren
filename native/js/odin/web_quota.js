// navigator.webkitTemporaryStorage and webkitPersistentStorage (Chromium's DeprecatedStorageQuota, in no specification): what navigator.storage.estimate()
// says, with callbacks. Sites that read a Chromium User-Agent call them without looking first. Evaluated by web_quota.odin the first time a script reads one.
(function (global) {
  "use strict";
  const estimate = () => global.navigator.storage.estimate();
  const ok = (f, ...values) => { if (typeof f === "function") f(...values); };
  class DeprecatedStorageQuota {
    queryUsageAndQuota(success, failure) {
      estimate().then(e => ok(success, e.usage, e.quota), e => ok(failure, e));
    }
    requestQuota(bytes, success, failure) {
      estimate().then(e => ok(success, Math.min(+bytes, e.quota)), e => ok(failure, e));
    }
  }
  return new DeprecatedStorageQuota();
})
