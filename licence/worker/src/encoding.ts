const enc = new TextEncoder();

export function utf8(s: string): Uint8Array {
	return enc.encode(s);
}

export function concat(...parts: Uint8Array[]): Uint8Array {
	const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
	let at = 0;
	for (const p of parts) { out.set(p, at); at += p.length; }
	return out;
}

function binary(bytes: Uint8Array): string {
	let s = "";
	for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
	return s;
}

// base64url without padding: what a licence is made of.
export function b64urlEncode(bytes: Uint8Array): string {
	return btoa(binary(bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function b64urlDecode(text: string): Uint8Array | null {
	if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null;
	const std = text.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - (text.length % 4)) % 4);
	const bin = atob(std);
	const out = new Uint8Array(bin.length);
	for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
	return out;
}

// standard base64 with padding: mail attachments
export function b64Encode(bytes: Uint8Array): string {
	return btoa(binary(bytes));
}

export function hexDecode(text: string): Uint8Array | null {
	if (!/^(?:[0-9a-fA-F]{2})+$/.test(text)) return null;
	const out = new Uint8Array(text.length / 2);
	for (let i = 0; i < out.length; i++) out[i] = Number.parseInt(text.slice(i * 2, i * 2 + 2), 16);
	return out;
}

export function hexEncode(bytes: Uint8Array): string {
	return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(text: string): Promise<string> {
	return hexEncode(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(text))));
}
