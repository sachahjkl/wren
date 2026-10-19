// matchMedia: results, and change events from the page's style computation (the tool resizes the viewport).

test("matchMedia", async () => {
  const all = matchMedia("all");
  ok(all instanceof MediaQueryList && all instanceof EventTarget, "a MediaQueryList");
  eq(all.matches, true, "all matches");
  eq(all.media, "all", "media");
  eq(matchMedia("not all").matches, false, "not all");
  eq(matchMedia("((").media, "not all", "an invalid query is not all");
  eq(matchMedia("((").matches, false, "...and never matches");
  eq(matchMedia("  (MIN-WIDTH:  600px) ").media, "(min-width: 600px)", "media is normalized");
  await signal("wide");
  const mq = matchMedia("(min-width: 600px)");
  eq(mq.matches, true, "wide viewport matches");
  const events = [];
  const legacy = e => events.push("legacy " + e.matches);
  mq.addListener(legacy);
  const changed = new Promise(r => { mq.onchange = e => { events.push("onchange " + e.matches + " " + e.media); r(e); }; });
  await signal("narrow");
  const e = await changed;
  ok(e instanceof MediaQueryListEvent, "a MediaQueryListEvent");
  eq(mq.matches, false, "narrow viewport does not match");
  eq(events.join("|"), "legacy false|onchange false (min-width: 600px)", "addListener and onchange");
  mq.removeListener(legacy);
  const ev = new MediaQueryListEvent("change", { media: "m", matches: true });
  eq(ev.media + ev.matches, "mtrue", "MediaQueryListEvent constructor");
});

__run();
