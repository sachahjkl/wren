// Wren licences, as src/license/license.odin reads them:
//
//     WREN1.<payload>.<signature>
//
// payload: base64url (no padding) of the JSON {"product":"wren","edition":..,"name":..,"email":..,"date":..,"order":..}
// signature: base64url (no padding) of the Ed25519 signature over SIGN_CONTEXT followed by the payload's bytes exactly
// as they are in the text.

import { b64urlDecode, b64urlEncode, concat, utf8 } from "./encoding.ts";

export const PRODUCT = "wren";
export const VERSION_TAG = "WREN1";
export const SIGN_CONTEXT = "wren-license-v1\n";
export const MAX_FIELD = 256;   // bytes, per field: Wren refuses a longer one
export const FILE_EXTENSION = ".wrenlicense";

export type Edition = "supporter" | "patron";

export interface Fields {
	edition: Edition;
	name: string;
	email: string;
	date: string;    // AAAA-MM-JJ
	order: string;
}

export function editionTitle(e: Edition): string {
	return e === "patron" ? "Patron" : "Supporter";
}

// A value as a licence can carry it: well-formed text on one line, at most MAX_FIELD bytes (cut between characters).
export function cleanField(s: string): string {
	const one = s.toWellFormed().normalize("NFC").replace(/[\p{Cc}\u2028\u2029\u200e\u200f\u061c\u202a-\u202e\u2066-\u2069]+/gu, " ").replace(/\s+/g, " ").trim();
	let out = "";
	let bytes = 0;
	for (const ch of one) {
		const n = utf8(ch).length;
		if (bytes + n > MAX_FIELD) break;
		out += ch;
		bytes += n;
	}
	return out.trimEnd();
}

// The same text Odin's json.marshal makes of its License struct (same field order).
export function payloadOf(f: Fields): string {
	return JSON.stringify({ product: PRODUCT, edition: f.edition, name: f.name, email: f.email, date: f.date, order: f.order });
}

// The key text of `key`: white space, '#' comment lines and quotes dropped, as Odin's `normalize` does.
export function normalize(text: string): string {
	return text.split(/\r?\n/).map((l) => l.trim()).filter((l) => !l.startsWith("#")).join("").replace(/[ \t"']/g, "");
}

function seedBytes(text: string): Uint8Array {
	const b = b64urlDecode(normalize(text));
	if (!b || b.length !== 32) throw new Error("LICENSE_PRIVATE_KEY is not a 32-byte base64url seed (the line of private.key without its # comments)");
	return b;
}

const PKCS8_ED25519_PREFIX = Uint8Array.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]);

export interface Signer {
	sign(f: Fields): Promise<string>;
	verify(text: string): Promise<boolean>;
}

let cached: { id: string; signer: Promise<Signer> } | undefined;

// Imports the keys once per isolate. The private key is given as the seed (what keygen writes), wrapped in PKCS#8 for
// WebCrypto, so the public key is not needed to sign; it is used to check the pair and every licence before it is used.
export function loadSigner(privateKey: string, publicKey: string): Promise<Signer> {
	const id = privateKey + "|" + publicKey;
	if (cached?.id === id) return cached.signer;
	const signer = makeSigner(privateKey, publicKey);
	cached = { id, signer };
	signer.catch(() => { if (cached?.id === id) cached = undefined; });
	return signer;
}

async function makeSigner(privateKey: string, publicKey: string): Promise<Signer> {
	const seed = seedBytes(privateKey);
	const pubBytes = b64urlDecode(normalize(publicKey));
	if (!pubBytes || pubBytes.length !== 32) throw new Error("LICENSE_PUBLIC_KEY is not a 32-byte base64url key");
	const priv = await crypto.subtle.importKey("pkcs8", concat(PKCS8_ED25519_PREFIX, seed), { name: "Ed25519" }, false, ["sign"]);
	const pub = await crypto.subtle.importKey("raw", pubBytes, { name: "Ed25519" }, false, ["verify"]);

	const verifyPayload = async (payload: Uint8Array, sig: Uint8Array) =>
		crypto.subtle.verify({ name: "Ed25519" }, pub, sig, concat(utf8(SIGN_CONTEXT), payload));

	const signer: Signer = {
		async sign(f) {
			const payload = utf8(payloadOf(f));
			const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, priv, concat(utf8(SIGN_CONTEXT), payload)));
			if (!(await verifyPayload(payload, sig))) throw new Error("the signature does not check out with LICENSE_PUBLIC_KEY");
			return `${VERSION_TAG}.${b64urlEncode(payload)}.${b64urlEncode(sig)}`;
		},
		async verify(text) {
			const parts = normalize(text).split(".");
			if (parts.length !== 3 || parts[0] !== VERSION_TAG) return false;
			const payload = b64urlDecode(parts[1]);
			const sig = b64urlDecode(parts[2]);
			return !!payload && !!sig && verifyPayload(payload, sig);
		},
	};
	// the pair must match: otherwise every licence made would be refused by Wren
	await signer.sign({ edition: "supporter", name: "check", email: "check@example.org", date: "2026-01-01", order: "CHECK" });
	return signer;
}

// The key wrapped at 76 columns under a header of comments: the .wrenlicense file tools\license.ps1 writes.
export function licenceFile(key: string, f: Fields): string {
	const lines = key.match(/.{1,76}/g) ?? [];
	return `# Wren licence (${editionTitle(f.edition)}) for ${f.name}\n# Order ${f.order}, ${f.date}. Open this file with Wren, or paste the key in about:wren.\n${lines.join("\n")}\n`;
}

export function licenceFileName(order: string): string {
	return "Wren-" + order.replace(/[^A-Za-z0-9_-]/g, "_") + FILE_EXTENSION;
}
