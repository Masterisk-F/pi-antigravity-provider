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
