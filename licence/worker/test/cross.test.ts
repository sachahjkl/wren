// The licences of the Worker against the real thing: the tool built from src/tools/license (the same package.license
// that Wren itself uses), with the development pair of src/license/dev_keys.odin.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { handle } from "../src/handler.ts";
import { b64urlEncode } from "../src/encoding.ts";
import { loadSigner, normalize } from "../src/licence.ts";
import type { Fields } from "../src/licence.ts";
import { DEV_PUBLIC_KEY, DEV_SEED, OTHER_DEV_SEED, PRICE_PATRON, TXN, fakeNetwork, fixture, jsonResponse, makeEnv, publicKeyOf, repoRoot, waiter, webhookRequest } from "./helpers.ts";

// build\license.exe, or the one WREN_LICENSE_EXE names (tools\test_all.ps1 builds its own), or one built now if Odin is there
function licenceTool(): string | null {
	const named = process.env.WREN_LICENSE_EXE;
	if (named) return existsSync(named) ? named : null;
	const out = join(repoRoot, "build", "license_worker_test.exe");
	mkdirSync(join(repoRoot, "build"), { recursive: true });
	const built = spawnSync("odin", ["build", "src/tools/license", "-collection:wb=src", "-vet", `-out:${out}`], { cwd: repoRoot, encoding: "utf8" });
	return built.status === 0 && existsSync(out) ? out : null;
}

const exe = licenceTool();
const skip = exe ? false : "Wren's licence tool is not available (no WREN_LICENSE_EXE, and Odin cannot build src/tools/license)";
const tmp = mkdtempSync(join(process.env.TEMP ?? process.env.TMPDIR ?? ".", "wren-worker-"));

function tool(...args: string[]) {
	const r = spawnSync(exe!, args, { encoding: "utf8" });
	return { code: r.status, out: (r.stdout ?? "") + (r.stderr ?? "") };
}

// Runs the whole webhook, as Paddle would, and returns the licence the Worker made.
async function workerLicence(body: string, customerJson: string) {
	const env = makeEnv();
	const net = fakeNetwork({ "https://sandbox-api.paddle.com/customers/": () => jsonResponse(customerJson) });
	env._deps = net.deps;   // the Paddle customer is read inside the Durable Object, which uses env._deps
	const res = await handle(webhookRequest(body), env, waiter, net.deps);
	assert.equal(res.status, 200);
	return JSON.parse(env.LICENSES.data.get(`txn:${TXN}`)!) as { licence: string; file: string; name: string; order: string };
}

test("the development pair is the one the Worker signs with (independently derived)", () => {
	assert.equal(publicKeyOf(DEV_SEED), DEV_PUBLIC_KEY);
	assert.notEqual(publicKeyOf(OTHER_DEV_SEED), DEV_PUBLIC_KEY);
});

test("a licence made by the Worker verifies with Wren's tool, as a key and as a .wrenlicense file", { skip }, async () => {
	const made = await workerLicence(fixture("transaction.completed.json"), fixture("customer.json"));

	const asKey = tool("verify", "-text", made.licence, "-dev");
	assert.equal(asKey.code, 0, asKey.out);
	assert.match(asKey.out, /VALID: Supporter licence of Jeanne Dupont <jeanne@example\.org>, order WREN-EEP4-4CYR-EWP9, 2026-10-22/);

	const file = join(tmp, "worker.wrenlicense");
	writeFileSync(file, made.file);
	const asFile = tool("verify", file, "-dev");
	assert.equal(asFile.code, 0, asFile.out);
	assert.match(asFile.out, /VALID: Supporter licence of Jeanne Dupont/);

	// the key pasted with its lines wrapped, as it arrives by e-mail
	const wrapped = made.licence.match(/.{1,60}/g)!.join("\n  ");
	assert.equal(tool("verify", "-text", wrapped, "-dev").code, 0);
});

test("patron licences and names with accents verify too", { skip }, async () => {
	const body = fixture("transaction.completed.json").replace("pri_01hsxyh9a1fnwv3xbg2zykm4sj", PRICE_PATRON);
	const customer = JSON.stringify({ data: { name: "Zoé Müller-Åkesson 山田", email: "zoe@example.org" } });
	const made = await workerLicence(body, customer);
	const r = tool("verify", "-text", made.licence, "-dev");
	assert.equal(r.code, 0, r.out);
	assert.match(r.out, /VALID: Patron licence of Zoé Müller-Åkesson 山田 <zoe@example\.org>/u);
});

test("what Wren's tool rejects is rejected: altered, other key, production key", { skip }, async () => {
	const made = await workerLicence(fixture("transaction.completed.json"), fixture("customer.json"));
	const [tag, payload, sig] = made.licence.split(".");

	const otherPayload = Buffer.from(payload, "base64url").toString().replace("supporter", "patron");
	const altered = `${tag}.${Buffer.from(otherPayload).toString("base64url")}.${sig}`;
	assert.notEqual(tool("verify", "-text", altered, "-dev").code, 0, "payload altered");

	const badSig = `${tag}.${payload}.${(sig[0] === "A" ? "B" : "A") + sig.slice(1)}`;
	assert.notEqual(tool("verify", "-text", badSig, "-dev").code, 0, "signature altered");

	assert.notEqual(tool("verify", "-text", made.licence, "-public", publicKeyOf(OTHER_DEV_SEED)).code, 0, "another public key");
	assert.equal(tool("verify", "-text", made.licence, "-public", DEV_PUBLIC_KEY).code, 0, "the dev key given by hand");
	assert.notEqual(tool("verify", "-text", made.licence).code, 0, "the production key (none yet, or not this one)");
});

// (ASCII names only: on Windows the tool reads its command line in the ANSI code page, so an accent given as an argument
// is not what was typed. The licences of accented names are checked above, from the Worker to the tool.)
test("the Worker and Wren's tool sign the same fields into the very same text", { skip }, async () => {
	const signer = await loadSigner(b64urlEncode(DEV_SEED), DEV_PUBLIC_KEY);
	const cases: Fields[] = [
		{ edition: "supporter", name: "Jeanne Dupont", email: "jeanne@example.org", date: "2026-10-22", order: "WREN-0001" },
		{ edition: "patron", name: "Zo \"Zo\" O'Brien \\ <&>", email: "zoe+wren@example.org", date: "2027-01-02", order: "WREN-ABCD-EFGH-JKLM" },
		{ edition: "supporter", name: "x".repeat(256), email: "a@b.co", date: "2026-12-31", order: "o" },
	];
	for (const f of cases) {
		const file = join(tmp, "issued.wrenlicense");
		const r = tool("issue", "-dev", "-name", f.name, "-email", f.email, "-edition", f.edition, "-order", f.order, "-date", f.date, "-out", file);
		assert.equal(r.code, 0, r.out);
		const theirs = normalize(readFileSync(file, "utf8"));
		assert.equal(await signer.sign(f), theirs, `fields: ${JSON.stringify(f)}`);
	}
});

test("the tool's public key for the dev seed is the one the Worker checks against", { skip }, () => {
	const r = tool("pubkey", "-dev");
	assert.equal(r.code, 0, r.out);
	assert.equal(r.out.split(/\r?\n/)[0].trim(), DEV_PUBLIC_KEY);
});
