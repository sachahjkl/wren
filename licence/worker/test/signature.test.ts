import assert from "node:assert/strict";
import { test } from "node:test";
import { editionOf, orderNumber, parseSignatureHeader, verifySignature } from "../src/paddle.ts";
import { NOW, WEBHOOK_SECRET, fixture, paddleSignature } from "./helpers.ts";

const body = fixture("transaction.completed.json");
const check = (b: string, header: string | null, opts: { secret?: string; now?: number; tolerance?: number } = {}) =>
	verifySignature(new TextEncoder().encode(b), header, opts.secret ?? WEBHOOK_SECRET, opts.now ?? NOW, opts.tolerance ?? 300);

test("a valid Paddle-Signature is accepted", async () => {
	assert.equal(await check(body, paddleSignature(body)), "ok");
});

test("a body altered by one byte is rejected", async () => {
	assert.equal(await check(body.replace("2900", "0290"), paddleSignature(body)), "mismatch");
});

test("a signature made with another secret is rejected", async () => {
	assert.equal(await check(body, paddleSignature(body, "pdl_ntfset_other")), "mismatch");
});

test("a signature whose timestamp was changed is rejected", async () => {
	const sig = paddleSignature(body);
	assert.equal(await check(body, sig.replace(/ts=\d+/, `ts=${Math.floor(NOW / 1000) + 1}`)), "mismatch");
});

test("a signature that is too old (or from the future) is rejected, whatever its validity", async () => {
	const old = paddleSignature(body, WEBHOOK_SECRET, Math.floor(NOW / 1000) - 301);
	assert.equal(await check(body, old), "stale");
	assert.equal(await check(body, paddleSignature(body, WEBHOOK_SECRET, Math.floor(NOW / 1000) - 299)), "ok");
	assert.equal(await check(body, paddleSignature(body, WEBHOOK_SECRET, Math.floor(NOW / 1000) + 400)), "stale");
	assert.equal(await check(body, old, { tolerance: 600 }), "ok");
});

test("a missing or malformed header is rejected", async () => {
	assert.equal(await check(body, null), "missing");
	for (const bad of ["", "garbage", "ts=abc;h1=00", "h1=" + "0".repeat(64), `ts=${Math.floor(NOW / 1000)}`, "ts=1;h1="]) {
		assert.notEqual(await check(body, bad), "ok", bad);
	}
	assert.equal(await check(body, `ts=${Math.floor(NOW / 1000)};h1=nothex`), "mismatch");
	assert.equal(await check(body, `ts=${Math.floor(NOW / 1000)};h1=abcd`), "mismatch");
});

test("an empty secret never validates anything", async () => {
	assert.equal(await check(body, paddleSignature(body, ""), { secret: "" }), "malformed");
});

test("during a secret rotation, any of the h1 values may match", async () => {
	const good = paddleSignature(body);
	const header = `ts=${good.match(/ts=(\d+)/)![1]};h1=${"0".repeat(64)};${good.split(";")[1]}`;
	assert.equal(await check(body, header), "ok");
});

test("the header is parsed leniently around its separators", () => {
	assert.deepEqual(parseSignatureHeader(" ts=12 ; h1=ab "), { ts: "12", h1: ["ab"] });
	assert.equal(parseSignatureHeader("h1=ab"), null);
});

test("editions come from the price ids, the patron one first", () => {
	const env = { PRICE_SUPPORTER: "pri_a, pri_b", PRICE_PATRON: "pri_p" };
	assert.equal(editionOf([{ price_id: "pri_a" }], env), "supporter");
	assert.equal(editionOf([{ price: { id: "pri_b" } }], env), "supporter");
	assert.equal(editionOf([{ price_id: "pri_a" }, { price_id: "pri_p" }], env), "patron");
	assert.equal(editionOf([{ price_id: "pri_x" }], env), null);
	assert.equal(editionOf([], env), null);
	assert.equal(editionOf([{ price_id: "" }], { PRICE_SUPPORTER: "", PRICE_PATRON: "" }), null);
});

test("the order number is readable and follows the transaction", () => {
	assert.equal(orderNumber("txn_01hv8wptq8987qeep44cyrewp9"), "WREN-EEP4-4CYR-EWP9");
});
