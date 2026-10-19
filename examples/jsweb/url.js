// URL and URLSearchParams.

test("URL", () => {
  const u = new URL("https://user:pw@example.com:8080/a/b?x=1#frag");
  eq(u.href, "https://user:pw@example.com:8080/a/b?x=1#frag", "href");
  eq(u.protocol, "https:", "protocol");
  eq(u.username, "user", "username");
  eq(u.password, "pw", "password");
  eq(u.host, "example.com:8080", "host");
  eq(u.hostname, "example.com", "hostname");
  eq(u.port, "8080", "port");
  eq(u.pathname, "/a/b", "pathname");
  eq(u.search, "?x=1", "search");
  eq(u.hash, "#frag", "hash");
  eq(u.origin, "https://example.com:8080", "origin");
  eq(String(u), u.href, "stringifier");
  eq(JSON.stringify({ u }), '{"u":"' + u.href + '"}', "toJSON");
  eq(new URL("../c?y", "http://h/a/b/").href, "http://h/a/c?y", "relative to a base");
  eq(new URL("HTTP://EXAMPLE.com/%7Efoo").href, "http://example.com/%7Efoo", "parsing normalizes");
  throws(() => new URL("not a url"), "TypeError", "invalid URL");
  throws(() => new URL("/x", "nope"), "TypeError", "invalid base");
  eq(URL.canParse("https://a"), true, "canParse");
  eq(URL.canParse("x", "bad"), false, "canParse with a bad base");
  eq(URL.parse("nope"), null, "URL.parse invalid is null");
  eq(URL.parse("/p", "http://h").href, "http://h/p", "URL.parse");
  ok(webkitURL === URL, "webkitURL alias");
});

test("URL setters", () => {
  const u = new URL("http://example.com/path");
  u.pathname = "/other path";
  eq(u.pathname, "/other%20path", "pathname setter encodes");
  u.search = "q=1";
  eq(u.href, "http://example.com/other%20path?q=1", "search setter");
  u.hash = "h";
  eq(u.hash, "#h", "hash setter");
  u.port = "99";
  eq(u.host, "example.com:99", "port setter");
  u.port = "80";
  eq(u.port, "", "default port is dropped");
  u.protocol = "https";
  eq(u.protocol, "https:", "protocol setter");
  u.hostname = "other.org";
  eq(u.hostname, "other.org", "hostname setter");
  throws(() => { u.href = "::bad"; }, "TypeError", "href setter with an invalid URL");
  u.href = "http://x.y/z";
  eq(u.pathname, "/z", "href setter");
});

test("searchParams is linked both ways", () => {
  const u = new URL("http://h/?a=1&b=2");
  const p = u.searchParams;
  ok(p === u.searchParams, "[SameObject]");
  eq(p.get("a"), "1", "params from the URL");
  p.append("c", "3 4");
  eq(u.search, "?a=1&b=2&c=3+4", "the URL follows the params");
  u.search = "?z=9";
  eq(p.get("z"), "9", "the params follow the URL");
  eq(p.has("a"), false, "old params gone");
  p.delete("z");
  eq(u.href, "http://h/", "an empty list empties the query");
});

test("URLSearchParams", () => {
  const p = new URLSearchParams("?a=1&b=x+y&a=%C3%A9");
  eq(p.size, 3, "size");
  eq(p.get("a"), "1", "get the first");
  eq(p.get("nope"), null, "get absent is null");
  eq(show(p.getAll("a")), '["1","\u00e9"]', "getAll");
  eq(p.get("b"), "x y", "plus is a space");
  eq(p.has("b"), true, "has");
  eq(p.has("a", "\u00e9"), true, "has with a value");
  p.set("a", "z");
  eq(show(p.getAll("a")), '["z"]', "set replaces all");
  p.sort();
  eq(p.toString(), "a=z&b=x+y", "sort and toString");
  eq(String(p), "a=z&b=x+y", "stringifier");
  const keys = [];
  for (const [k, v] of p) keys.push(k + "=" + v);
  eq(keys.join("|"), "a=z|b=x y", "iteration");
  eq([...p.keys()].join(), "a,b", "keys()");
  eq([...p.values()].join(), "z,x y", "values()");
  const seen = [];
  p.forEach((v, k, o) => seen.push(k + v + (o === p)));
  eq(seen.join(), "aztrue,bx ytrue", "forEach");
  eq(Object.prototype.toString.call(p.entries()), "[object URLSearchParams Iterator]", "iterator toStringTag");
  eq(new URLSearchParams([["x", "1"], ["y", "2"]]).toString(), "x=1&y=2", "from a sequence");
  eq(new URLSearchParams({ k: "v", n: 1 }).toString(), "k=v&n=1", "from a record");
  eq(new URLSearchParams(new URLSearchParams("q=1")).toString(), "q=1", "from another URLSearchParams");
  throws(() => new URLSearchParams([["x"]]), "TypeError", "a pair of one");
  eq(new URLSearchParams("a=\ud800").toString(), "a=%EF%BF%BD", "USVString: lone surrogate replaced");
  const live = new URLSearchParams("a=1&b=2&c=3");
  const out = [];
  for (const [k] of live) { out.push(k); if (k === "a") live.delete("b"); }
  eq(out.join(), "a,c", "iteration sees changes");
});

__run();
