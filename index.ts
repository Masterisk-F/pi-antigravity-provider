// Node/Bun の両ランタイムで動作させるための Bun shim。
// pi CLI は Node で動き (#!/usr/bin/env node)、plugin-bundled.js 内の上流 oh-my-pi コードは
// Bun ビルトイン (Bun.hash / Bun.SHA256 / Bun.sleep 等) を使う。Bun 実行時は何もしない。
if (typeof globalThis.Bun === "undefined") {
	const nodeCrypto = await import("node:crypto");
	globalThis.Bun = {
		// Bun.SHA256.hash(text) → digest / hash(data, out) → out に書き込み
		SHA256: {
			hash(text: any, out?: Uint8Array) {
				const data = typeof text === "string" ? Buffer.from(text, "utf8") : text;
				const digest = nodeCrypto.createHash("sha256").update(data).digest();
				if (out) { out.set(digest); return out; }
				return digest;
			},
		},
		// Bun.hash → 数値キャッシュキー用途 (xxHash 代替。キー用途では十分)
		hash(text: any, seed?: number) {
			const data = typeof text === "string" ? Buffer.from(text, "utf8") : text;
			let h = nodeCrypto.createHash("sha256").update(data).digest().readUInt32BE(0) >>> 0;
			if (seed !== undefined) h = (h ^ (seed >>> 0)) >>> 0;
			return h;
		},
		deepEquals(a: unknown, b: unknown) {
			if (a === b) return true;
			return JSON.stringify(a) === JSON.stringify(b);
		},
		sleep(ms: number) { return new Promise(r => setTimeout(r, ms)); },
		env: process.env,
		// google-antigravity パスで使われない API は参照エラー回避のためスタブのみ
		Image: class { metadata() { throw new Error("Bun.Image unsupported in Node"); } },
		JSONL: { parseChunk() { throw new Error("Bun.JSONL unsupported in Node"); } },
		stripANSI: (s: string) => s.replace(/\x1B\[[0-9;]*[A-Za-z]/g, ""),
	} as any;
}

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { OAuthCredentials } from "@earendil-works/pi-ai";
import { loginAntigravity, refreshAntigravityToken, streamGoogleGeminiCli, getBundledModels } from "./plugin-bundled.js";

export default function (pi: ExtensionAPI) {
	pi.registerProvider("google-antigravity", {
		id: "google-antigravity",
		name: "Google Antigravity",
		baseUrl: "https://daily-cloudcode-pa.googleapis.com",
		api: "google-gemini-cli" as const,

		models: getBundledModels("google-antigravity"),

		oauth: {
			name: "Google Antigravity",
			login: loginAntigravity as any, // Type mismatch between pi-ai and pi-coding-agent

			refreshToken: (cred: OAuthCredentials) => refreshAntigravityToken(cred.refresh, (cred as any).projectId),
			getApiKey: (cred: OAuthCredentials) => JSON.stringify(cred),
		},
		streamSimple: (model, context, options) => {
			const originalModel = getBundledModels("google-antigravity").find(m => m.id === model.id);
			return streamGoogleGeminiCli(model, context, { ...options, requestModelId: originalModel?.requestModelId });
		}
	});
}
