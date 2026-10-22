import assert from "node:assert/strict";
import { test } from "node:test";
import { handle } from "../src/handler.ts";
import { b64urlDecode } from "../src/encoding.ts";
import { loadSigner } from "../src/licence.ts";
import { DEV_SEED, NOW, PRICE_PATRON, TXN, WEBHOOK_SECRET, emailError, fakeNetwork, fixture, jsonResponse, makeEnv, paddleSignature, waiter, webhookRequest } from "./helpers.ts";
import type { Call } from "./helpers.ts";
import { b64urlEncode } from "../src/encoding.ts";

const body = fixture("transaction.completed.json");
const customer = fixture("customer.json");
const URL_BASE = "https://licences.example.workers.dev";

// The mail does not go through the network any more (it is the `EMAIL` binding of the env): only Paddle does.
function network(opts: { customers?: (c: Call) => Response } = {}) {
	return fakeNetwork({ "https://sandbox-api.paddle.com/customers/": opts.customers ?? (() => jsonResponse(customer)) });
}

const stateOf = (env: ReturnType<typeof makeEnv>) => JSON.parse(env.LICENSES.data.get(`txn:${TXN}`)!) as { mail: string; mail_detail?: string };

const post = (env: ReturnType<typeof makeEnv>, net: ReturnType<typeof network>, b = body) => handle(webhookRequest(b), env, waiter, net.deps);
const get = (env: ReturnType<typeof makeEnv>, path: string, net = network(), init: RequestInit = {}) => handle(new Request(URL_BASE + path, init), env, waiter, net.deps);

test("transaction.completed issues a licence, keeps it and mails it", async () => {
	const env = makeEnv();
	const net = network();
	const res = await post(env, net);
	assert.equal(res.status, 200);
	const answer = await res.json() as { status: string; order: string; mail: string };
	assert.deepEqual(answer, { status: "issued", order: "WREN-EEP4-4CYR-EWP9", mail: "sent" });

	// the customer was read with the API key, in the environment of the webhook
	const c = net.calls[0];
	assert.equal(c.url, "https://sandbox-api.paddle.com/customers/ctm_01hv6y1jedq4p1n0yqn5ba3ky4");
	assert.equal(c.headers.authorization, "Bearer pdl_sdbx_apikey_test");

	// kept in KV under the transaction, with the order and e-mail indexes
	const stored = JSON.parse(env.LICENSES.data.get(`txn:${TXN}`)!);
	assert.equal(stored.name, "Jeanne Dupont");
	assert.equal(stored.email, "jeanne@example.org");
	assert.equal(stored.edition, "supporter");
	assert.equal(stored.date, "2026-10-22");
	assert.equal(env.LICENSES.data.get("order:WREN-EEP4-4CYR-EWP9"), TXN);
	assert.ok([...env.LICENSES.data.keys()].some((k) => k.startsWith("email:")));

	// the licence: three parts, a payload with exactly the fields of src/license/license.odin, signed by our key
	const [tag, payload, sig] = stored.licence.split(".");
	assert.equal(tag, "WREN1");
	assert.deepEqual(JSON.parse(new TextDecoder().decode(b64urlDecode(payload)!)), {
		product: "wren", edition: "supporter", name: "Jeanne Dupont", email: "jeanne@example.org", date: "2026-10-22", order: "WREN-EEP4-4CYR-EWP9",
	});
	assert.equal(b64urlDecode(sig)!.length, 64);
	const signer = await loadSigner(b64urlEncode(DEV_SEED), env.LICENSE_PUBLIC_KEY);
	assert.ok(await signer.verify(stored.licence));
	assert.ok(await signer.verify(stored.file), "the .wrenlicense file (with its comments) verifies too");
	const forged = stored.licence.replace(/(\.[^.]+\.)(.)/, (_m: string, head: string, c: string) => head + (c === "A" ? "B" : "A"));
	assert.notEqual(forged, stored.licence);
	assert.ok(!(await signer.verify(forged)));

	// the mail: to the buyer, from the configured sender, the key in the text and the file attached
	assert.equal(env.EMAIL.sent.length, 1);
	const sent = env.EMAIL.sent[0];
	assert.equal(sent.to, "jeanne@example.org");
	assert.deepEqual(sent.from, { email: "licences@example.org", name: "Wren" });
	assert.equal(sent.subject, "Your Wren licence (order WREN-EEP4-4CYR-EWP9)");
	assert.equal(sent.replyTo, undefined, "no MAIL_REPLY_TO, no reply-to");
	assert.ok(sent.text.includes("about:wren"));
	assert.ok(sent.text.replace(/\s/g, "").includes(stored.licence));
	assert.equal(sent.attachments?.length, 1);
	const file = sent.attachments![0];
	assert.equal(file.filename, "Wren-WREN-EEP4-4CYR-EWP9.wrenlicense");
	assert.equal(file.type, "application/octet-stream");
	assert.equal(file.disposition, "attachment");
	assert.equal(Buffer.from(file.content, "base64").toString("utf8"), stored.file, "the attachment is the base64 of the .wrenlicense text");
	assert.equal(stored.mail, "sent");
});

test("the sender is given to Email Service as an address and a name; the reply-to when there is one", async () => {
	const named = makeEnv({ MAIL_FROM: '"Wren, by Froment" <licences@example.org>', MAIL_REPLY_TO: "contact@example.org" });
	await post(named, network());
	assert.deepEqual(named.EMAIL.sent[0].from, { email: "licences@example.org", name: "Wren, by Froment" });
	assert.equal(named.EMAIL.sent[0].replyTo, "contact@example.org");

	const bare = makeEnv({ MAIL_FROM: "licences@example.org" });
	await post(bare, network());
	assert.equal(bare.EMAIL.sent[0].from, "licences@example.org");
});

test("a webhook delivered again gives the same licence, writes nothing and mails nothing twice", async () => {
	const env = makeEnv();
	const net = network();
	await post(env, net);
	const first = env.LICENSES.data.get(`txn:${TXN}`);
	const writes = env.LICENSES.writes;
	const calls = net.calls.length;

	const again = await post(env, net);
	assert.equal(again.status, 200);
	assert.equal((await again.json() as { status: string }).status, "replayed");
	assert.equal(env.LICENSES.data.get(`txn:${TXN}`), first);
	assert.equal(env.LICENSES.writes, writes);
	assert.equal(net.calls.length, calls, "no new request to Paddle");
	assert.equal(env.EMAIL.attempts, 1, "and no second mail");
});

test("webhooks delivered again after every kind of mail outcome never send a second mail", async () => {
	for (const failure of [null, emailError("E_SENDER_NOT_VERIFIED"), emailError("E_DELIVERY_FAILED"), new Error("boom")]) {
		const env = makeEnv();
		if (failure) env.EMAIL.fail = () => { throw failure; };
		assert.equal((await post(env, network())).status, 200);
		const before = env.EMAIL.attempts;
		for (let i = 0; i < 3; i++) assert.equal((await post(env, network())).status, 200);
		assert.equal(env.EMAIL.attempts, before, String(failure));
		assert.equal(before, 1);
	}
});

test("a send whose outcome is lost is not repeated: the record says 'sending' and a new delivery leaves it alone", async () => {
	// the last write of the first delivery fails (KV down): the mail is out, the record still says "sending"
	const env = makeEnv();
	const put = env.LICENSES.put.bind(env.LICENSES);
	let failFinalWrite = true;
	env.LICENSES.put = async (key: string, value: string) => {
		if (failFinalWrite && key.startsWith("txn:") && value.includes('"mail":"sent"')) throw new Error("KV unavailable");
		await put(key, value);
	};
	assert.equal((await post(env, network())).status, 500);
	assert.equal(env.EMAIL.attempts, 1);
	assert.equal(stateOf(env).mail, "sending");

	failFinalWrite = false;
	const again = await post(env, network());
	assert.equal(again.status, 200, "acknowledged: Paddle stops redelivering");
	assert.deepEqual(await again.json(), { status: "replayed", order: "WREN-EEP4-4CYR-EWP9", mail: "sending" });
	assert.equal(env.EMAIL.attempts, 1, "no second mail");
	assert.equal(stateOf(env).mail, "sending", "nothing written either");

	// the buyer can still ask for it again
	const resend = makeEnv({ RESEND_ENABLED: "true" });
	resend.LICENSES.data = new Map(env.LICENSES.data);
	const res = await handle(new Request(URL_BASE + "/resend", { method: "POST", body: JSON.stringify({ email: "jeanne@example.org" }) }), resend, waiter, network().deps);
	assert.equal(res.status, 202);
	assert.equal(resend.EMAIL.sent.length, 1);
});

test("an issued licence costs four KV writes, mail included", async () => {
	const env = makeEnv();
	await post(env, network());
	assert.equal(env.LICENSES.writes, 4, "txn (sending), order, email, txn (sent)");
});

test("the licence is a function of the transaction: a second Worker with empty storage signs the same text", async () => {
	const a = makeEnv();
	const b = makeEnv();
	await post(a, network());
	await post(b, network());
	assert.equal(JSON.parse(a.LICENSES.data.get(`txn:${TXN}`)!).licence, JSON.parse(b.LICENSES.data.get(`txn:${TXN}`)!).licence);
});

test("a patron price gives the patron edition", async () => {
	const env = makeEnv();
	await post(env, network(), body.replace("pri_01hsxyh9a1fnwv3xbg2zykm4sj", PRICE_PATRON));
	assert.equal(JSON.parse(env.LICENSES.data.get(`txn:${TXN}`)!).edition, "patron");
});

test("a failed signature check stores nothing and calls nobody", async () => {
	const env = makeEnv();
	const net = network();
	for (const sig of [null, "ts=1;h1=00", paddleSignature(body, "wrong secret"), paddleSignature(body, undefined, Math.floor(NOW / 1000) - 3600)]) {
		const res = await handle(webhookRequest(body, sig), env, waiter, net.deps);
		assert.equal(res.status, 401, String(sig));
	}
	assert.equal((await handle(webhookRequest(body.replace("2900", "1"), paddleSignature(body)), env, waiter, net.deps)).status, 401);
	assert.equal(env.LICENSES.writes, 0);
	assert.equal(net.calls.length, 0);
});

test("other events and unpaid or foreign transactions are acknowledged and ignored", async () => {
	const env = makeEnv();
	const net = network();
	const other = body.replace('"transaction.completed"', '"transaction.created"');
	assert.equal((await post(env, net, other)).status, 200);
	const unpaid = body.replace('"status": "completed"', '"status": "ready"');
	assert.equal((await (await post(env, net, unpaid)).json() as { status: string }).status, "ignored");
	const foreign = body.replace("pri_01hsxyh9a1fnwv3xbg2zykm4sj", "pri_someone_elses_product");
	assert.equal((await (await post(env, net, foreign)).json() as { status: string }).status, "ignored");
	assert.equal(env.LICENSES.writes, 0);
	assert.equal(net.calls.length, 0);
});

test("a body that is not JSON (but correctly signed) is a 400", async () => {
	assert.equal((await post(makeEnv(), network(), "not json")).status, 400);
});

test("the webhook only answers POST, and a huge body is refused before anything is read", async () => {
	const env = makeEnv();
	assert.equal((await get(env, "/paddle/webhook")).status, 405);
	const big = "x".repeat(600 * 1024);
	assert.equal((await handle(webhookRequest(big), env, waiter, network().deps)).status, 413);
});

test("when the Paddle API is down the webhook says 500 (Paddle retries) and nothing is kept; then it works", async () => {
	const env = makeEnv();
	const down = network({ customers: () => new Response("", { status: 503 }) });
	assert.equal((await post(env, down)).status, 500);
	assert.equal(env.LICENSES.writes, 0);
	const refused = network({ customers: () => new Response("{}", { status: 403 }) });
	assert.equal((await post(env, refused)).status, 500);
	assert.equal((await post(env, network())).status, 200);
});

test("a customer without an e-mail address is a 422 (nothing to retry), without a name the e-mail is used", async () => {
	const env = makeEnv();
	const none = network({ customers: () => jsonResponse('{"data":{"id":"ctm_01hv6y1jedq4p1n0yqn5ba3ky4","name":null,"email":null}}') });
	assert.equal((await post(env, none)).status, 422);
	const noName = network({ customers: () => jsonResponse('{"data":{"name":null,"email":"anon@example.org"}}') });
	assert.equal((await post(env, noName)).status, 200);
	assert.equal(JSON.parse(env.LICENSES.data.get(`txn:${TXN}`)!).name, "anon@example.org");
});

test("a customer inside the notification needs no call to the Paddle API", async () => {
	const env = makeEnv();
	const net = network();
	const withCustomer = body.replace('"customer_id":', '"customer": {"name": "Zoé Müller", "email": "zoe@example.org"}, "customer_id":');
	assert.equal((await post(env, net, withCustomer)).status, 200);
	assert.ok(net.calls.every((c) => !c.url.includes("/customers/")));
	assert.equal(JSON.parse(env.LICENSES.data.get(`txn:${TXN}`)!).name, "Zoé Müller");
});

test("names are made safe to sign: control characters, bidi overrides, length", async () => {
	const env = makeEnv();
	const evil = body.replace('"customer_id":', '"customer": {"name": "A\\u0000B\\nC\\u202eD' + "é".repeat(200) + '", "email": "a@example.org"}, "customer_id":');
	assert.equal((await post(env, network(), evil)).status, 200);
	const s = JSON.parse(env.LICENSES.data.get(`txn:${TXN}`)!);
	assert.ok(s.name.startsWith("A B C D"));
	assert.ok(new TextEncoder().encode(s.name).length <= 256);
	assert.ok(!/[\u0000-\u001f\u202e]/.test(s.name));
	assert.equal(s.file.split("\n")[0], `# Wren licence (Supporter) for ${s.name}`);
});

test("a mail that cannot be sent now makes the webhook fail; the next delivery sends it and only it", async () => {
	for (const code of ["E_RATE_LIMIT_EXCEEDED", "E_DAILY_LIMIT_EXCEEDED", "E_INTERNAL_SERVER_ERROR"]) {
		const env = makeEnv();
		env.EMAIL.fail = (n) => { if (n === 1) throw emailError(code); };
		const net = network();
		assert.equal((await post(env, net)).status, 500, code);
		assert.deepEqual({ mail: stateOf(env).mail, detail: stateOf(env).mail_detail }, { mail: "pending", detail: code }, "the licence exists, the mail is owed");
		assert.equal(env.EMAIL.sent.length, 0);

		const retry = await post(env, net);
		assert.equal(retry.status, 200, code);
		assert.equal(stateOf(env).mail, "sent");
		assert.equal(env.EMAIL.sent.length, 1, "one mail in the end");
		assert.equal(net.calls.filter((c) => c.url.startsWith("https://sandbox-api.paddle.com")).length, 1, "the customer is read once");
		assert.equal((await post(env, net)).status, 200);
		assert.equal(env.EMAIL.attempts, 2, "refused once, sent once, nothing more");
	}
});

test("a mail refused for good is recorded and the webhook still succeeds (no retry: Paddle would only get the same answer)", async () => {
	const codes = ["E_VALIDATION_ERROR", "E_SENDER_NOT_VERIFIED", "E_SENDER_DOMAIN_NOT_AVAILABLE", "E_RECIPIENT_NOT_ALLOWED", "E_RECIPIENT_SUPPRESSED", "E_ACCOUNT_SUSPENDED", "E_DELIVERY_FAILED", "E_CONTENT_TOO_LARGE", "E_SOMETHING_NEW"];
	for (const code of codes) {
		const env = makeEnv();
		env.EMAIL.fail = () => { throw emailError(code); };
		assert.equal((await post(env, network())).status, 200, code);
		assert.deepEqual({ mail: stateOf(env).mail, detail: stateOf(env).mail_detail }, { mail: "failed", detail: code });
		assert.equal(env.EMAIL.attempts, 1);
	}
	// an error with no code (the binding itself broke) is named by its class, and is not retried either
	const broken = makeEnv();
	broken.EMAIL.fail = () => { throw new TypeError("cannot reach jeanne@example.org"); };
	assert.equal((await post(broken, network())).status, 200);
	assert.deepEqual({ mail: stateOf(broken).mail, detail: stateOf(broken).mail_detail }, { mail: "failed", detail: "TypeError" });
});

test("without the mail binding or without MAIL_FROM the mail is 'skipped'; once configured, a replay sends it", async () => {
	const none = makeEnv({ EMAIL: undefined });
	assert.equal((await post(none, network())).status, 200);
	assert.equal(stateOf(none).mail, "skipped");
	const writes = none.LICENSES.writes;
	assert.equal((await post(none, network())).status, 200);
	assert.equal(none.LICENSES.writes, writes, "a replay of a skipped mail writes nothing while nothing is configured");

	const noSender = makeEnv({ MAIL_FROM: "" });
	assert.equal((await post(noSender, network())).status, 200);
	assert.equal(stateOf(noSender).mail, "skipped");
	assert.equal(noSender.EMAIL.attempts, 0);

	// the same record, the binding now there
	const configured = makeEnv();
	configured.LICENSES.data = new Map(noSender.LICENSES.data);
	assert.equal((await post(configured, network())).status, 200);
	assert.equal(stateOf(configured).mail, "sent");
	assert.equal(configured.EMAIL.sent.length, 1);
	assert.equal((await post(configured, network())).status, 200);
	assert.equal(configured.EMAIL.attempts, 1);
});

test("a buyer address that cannot be an address is 'failed' without calling Email Service", async () => {
	const env = makeEnv();
	const odd = body.replace('"customer_id":', '"customer": {"name": "Odd", "email": "not an address"}, "customer_id":');
	assert.equal((await post(env, network(), odd)).status, 200);
	assert.deepEqual({ mail: stateOf(env).mail, detail: stateOf(env).mail_detail }, { mail: "failed", detail: "invalid_address" });
	assert.equal(env.EMAIL.attempts, 0);
});

test("a name cannot turn the mail into something else: it only ever appears in the text, and as one line", async () => {
	const env = makeEnv();
	const evil = body.replace('"customer_id":', '"customer": {"name": "<script>alert(1)</script>\\r\\nBcc: spy@example.org", "email": "a@example.org"}, "customer_id":');
	assert.equal((await post(env, network(), evil)).status, 200);
	const m = env.EMAIL.sent[0];
	assert.ok(!("html" in m), "a plain-text mail: no markup to escape");
	assert.ok(!m.subject.includes("script") && !/[\r\n]/.test(m.subject));
	assert.ok(m.text.split("\n")[0].startsWith("Hello <script>alert(1)</script> Bcc: spy@example.org,"), "control characters became spaces");
	assert.equal(m.to, "a@example.org");
});

test("GET /licence: 202 while the licence does not exist, then the licence", async () => {
	const env = makeEnv();
	const early = await get(env, `/licence?txn=${TXN}`);
	assert.equal(early.status, 202);
	assert.equal(early.headers.get("retry-after"), "3");

	await post(env, network());
	const res = await get(env, `/licence?txn=${TXN}`, network(), { headers: { Origin: "https://sachahjkl.github.io" } });
	assert.equal(res.status, 200);
	assert.equal(res.headers.get("access-control-allow-origin"), "https://sachahjkl.github.io");
	assert.equal(res.headers.get("cache-control"), "no-store");
	const j = await res.json() as Record<string, string>;
	assert.equal(j.status, "ready");
	assert.equal(j.name, "Jeanne Dupont");
	assert.ok(j.licence.startsWith("WREN1."));
	assert.equal(j.filename, "Wren-WREN-EEP4-4CYR-EWP9.wrenlicense");
	assert.ok(!("email" in j), "the address is not given back");
});

test("GET /licence refuses what is not a transaction id, and other origins get no CORS header", async () => {
	const env = makeEnv();
	for (const bad of ["", "txn_short", "../../etc", "txn_01hv8wptq8987qeep44cyrewp9'", "ord_01hv8wptq8987qeep44cyrewp9"]) {
		assert.equal((await get(env, `/licence?txn=${encodeURIComponent(bad)}`)).status, 400, bad);
	}
	const res = await get(env, `/licence?txn=${TXN}`, network(), { headers: { Origin: "https://evil.example" } });
	assert.equal(res.headers.get("access-control-allow-origin"), null);
	const wild = await get(makeEnv({ ALLOWED_ORIGIN: "*" }), `/licence?txn=${TXN}`);
	assert.equal(wild.headers.get("access-control-allow-origin"), "*");
});

test("GET /licence/<id>.wrenlicense downloads the file", async () => {
	const env = makeEnv();
	assert.equal((await get(env, `/licence/${TXN}.wrenlicense`)).status, 404);
	await post(env, network());
	const res = await get(env, `/licence/${TXN}.wrenlicense`);
	assert.equal(res.status, 200);
	assert.equal(res.headers.get("content-disposition"), 'attachment; filename="Wren-WREN-EEP4-4CYR-EWP9.wrenlicense"');
	const text = await res.text();
	assert.ok(text.startsWith("# Wren licence (Supporter) for Jeanne Dupont\n# Order WREN-EEP4-4CYR-EWP9, 2026-10-22."));
	assert.equal((await get(env, "/licence/txn_nope.wrenlicense")).status, 400);
});

test("preflight, unknown paths, health", async () => {
	const env = makeEnv();
	const pre = await get(env, "/resend", network(), { method: "OPTIONS", headers: { Origin: "https://sachahjkl.github.io" } });
	assert.equal(pre.status, 204);
	assert.equal((await get(env, "/nothing")).status, 404);
	assert.equal((await get(env, "/health")).status, 200);
	const bare = makeEnv({ PADDLE_API_KEY: "" });
	const health = await get(bare, "/health");
	assert.equal(health.status, 503);
	assert.deepEqual((await health.json() as { missing: string[] }).missing, ["PADDLE_API_KEY"]);
});

test("a private key that does not match the public key issues nothing", async () => {
	const env = makeEnv({ LICENSE_PRIVATE_KEY: b64urlEncode(new Uint8Array(32).fill(7)) });
	const res = await post(env, network());
	assert.equal(res.status, 500);
	assert.equal(env.LICENSES.writes, 0);
});

test("logs carry no name, e-mail address or key", async () => {
	const lines: string[] = [];
	const original = console.log;
	console.log = (...a: unknown[]) => { lines.push(a.join(" ")); };
	try {
		const env = makeEnv();
		await post(env, network());
		await post(env, network());
		await handle(webhookRequest(body, "ts=1;h1=00"), env, waiter, network().deps);
		// the errors of Email Service may quote the address: only the code is logged
		for (const code of ["E_DELIVERY_FAILED", "E_RATE_LIMIT_EXCEEDED"]) {
			const bad = makeEnv();
			bad.EMAIL.fail = () => { throw emailError(code, "could not deliver to jeanne@example.org (Jeanne Dupont) WREN1.abc"); };
			await post(bad, network()).catch(() => {});
		}
		const broken = makeEnv();
		broken.EMAIL.fail = () => { throw new Error("jeanne@example.org"); };
		await post(broken, network());
	} finally {
		console.log = original;
	}
	assert.ok(lines.length >= 3);
	const all = lines.join("\n");
	assert.ok(all.includes("E_DELIVERY_FAILED") && all.includes("WREN-EEP4-4CYR-EWP9"), "the code and the order are logged");
	for (const secret of ["Jeanne", "jeanne@", "WREN1.", WEBHOOK_SECRET, "example.org"]) assert.ok(!all.includes(secret), secret);
});

test("POST /resend: off by default, the same answer for known and unknown addresses, limited per address", async () => {
	const off = makeEnv();
	await post(off, network());
	const ask = (env: ReturnType<typeof makeEnv>, net: ReturnType<typeof network>, email: string) =>
		handle(new Request(URL_BASE + "/resend", { method: "POST", body: JSON.stringify({ email }) }), env, waiter, net.deps);
	assert.equal((await ask(off, network(), "jeanne@example.org")).status, 404);

	const env = makeEnv({ RESEND_ENABLED: "true", RESEND_MAX_PER_HOUR: "2" });
	await post(env, network());
	const first = env.EMAIL.sent.length;   // the mail of the purchase
	const net = network();
	const known = await ask(env, net, " Jeanne@Example.org ");
	const unknown = await ask(env, net, "nobody@example.org");
	assert.equal(known.status, 202);
	assert.equal(unknown.status, 202);
	assert.deepEqual(await known.json(), await unknown.json());
	assert.equal(env.EMAIL.sent.length, first + 1, "one mail, to the buyer only");
	assert.equal(env.EMAIL.sent[first].to, "jeanne@example.org");
	assert.equal(net.calls.length, 0);

	const writes = env.LICENSES.writes;
	await ask(env, net, "nobody-else@example.org");
	assert.equal(env.LICENSES.writes, writes, "an address without a purchase writes nothing");

	await ask(env, net, "jeanne@example.org");
	await ask(env, net, "jeanne@example.org");   // over the limit of 2 an hour
	assert.equal(env.EMAIL.sent.length, first + 2);

	assert.equal((await ask(env, net, "not an address")).status, 400);
	const bad = await handle(new Request(URL_BASE + "/resend", { method: "POST", body: "{" }), env, waiter, net.deps);
	assert.equal(bad.status, 400);
});
