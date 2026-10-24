// WREN_JS_PRELUDE for tools\yt_boot.ps1: when the parts of a YouTube page that the user waits for are there, in ms since the navigation
// began (performance.now): masthead, logo (the SVG in the header), thumbs (the first picture of the grid or the related list),
// video (the first video with data). A MutationObserver notes them when the DOM changes, so that the page is not asked anything
// while it starts. After 30 s the marks are written to the console, with the DOM size and the page's own load times.
(function () {
  const marks = {};
  window.__ytm = marks;
  const want = {
    masthead: 'ytd-masthead',
    logo: 'ytd-topbar-logo-renderer svg, #logo-icon svg',
    thumbs: '#related img[src], ytd-watch-next-secondary-results-renderer img[src], ytd-rich-item-renderer img[src], yt-lockup-view-model img[src]',
  };
  function scan() {
    for (const k in want) {
      if (marks[k] === undefined && document.querySelector(want[k])) marks[k] = Math.round(performance.now());
    }
    if (marks.masthead !== undefined && marks.logo !== undefined && marks.thumbs !== undefined) { mo.disconnect(); }
  }
  const mo = new MutationObserver(scan);
  mo.observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ['src'] });
  for (const ev of ['loadeddata', 'playing']) {
    document.addEventListener(ev, function () { if (marks[ev] === undefined) marks[ev] = Math.round(performance.now()); }, true);
  }
  setTimeout(function () {
    mo.disconnect();
    const nav = performance.getEntriesByType('navigation')[0] || {};
    marks.dcl = Math.round(nav.domContentLoadedEventEnd || 0);
    marks.load = Math.round(nav.loadEventEnd || 0);
    marks.elements = document.getElementsByTagName('*').length;
    marks.done = 1;
  }, 30000);
})();