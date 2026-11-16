type: Fixed

**A page's scripts no longer stop when an extension's content script fires an event the page listens to.** The page's JavaScript engine wrote into its own memory at an address that belonged to the content script's engine. Later, often a minute later, the page's scripts stopped with "the JavaScript engine of this page was stopped in the middle of its work".
