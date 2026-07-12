#!/bin/bash
set -e

EXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR=$(mktemp -d)

echo "Fetching latest oh-my-pi from GitHub into $TMP_DIR..."
git clone --depth 1 https://github.com/can1357/oh-my-pi.git "$TMP_DIR"

cd "$TMP_DIR"

echo "Localizing internal dependencies..."
cp packages/catalog/src/wire/gemini-headers.ts packages/ai/src/registry/oauth/gemini-headers.ts
cp packages/catalog/src/wire/gemini-headers.ts packages/ai/src/providers/gemini-headers.ts
sed -i 's|@oh-my-pi/pi-catalog/wire/gemini-headers|./gemini-headers.ts|g' packages/ai/src/registry/oauth/google-antigravity.ts packages/ai/src/providers/google-gemini-cli.ts

echo "Patching google-gemini-cli.ts for pi compatibility..."
sed -i 's|"token?": optionalCredentialString,|"token?": optionalCredentialString,\n\t"access?": optionalCredentialString,|g' packages/ai/src/providers/google-gemini-cli.ts
sed -i 's|if (parsed.token === undefined|if ((parsed.token ?? parsed.access) === undefined|g' packages/ai/src/providers/google-gemini-cli.ts
sed -i 's|accessToken: parsed.token,|accessToken: parsed.token ?? parsed.access!,|g' packages/ai/src/providers/google-gemini-cli.ts
sed -i 's|const wireModelId = options.requestModelId ?? model.requestModelId ?? model.id;|const wireModelId = options.requestModelId ?? model.requestModelId ?? model.id;|g' packages/ai/src/providers/google-gemini-cli.ts
sed -i 's|\[ANTIGRAVITY_DAILY_ENDPOINT, ANTIGRAVITY_SANDBOX_ENDPOINT\]|\[ANTIGRAVITY_DAILY_ENDPOINT, ANTIGRAVITY_SANDBOX_ENDPOINT, DEFAULT_ENDPOINT\]|g' packages/ai/src/providers/google-gemini-cli.ts
sed -i 's|const CLOUD_CODE_ENDPOINT = "https://cloudcode-pa.googleapis.com";|const CLOUD_CODE_ENDPOINT = "https://daily-cloudcode-pa.googleapis.com";|g' packages/ai/src/registry/oauth/google-antigravity.ts

echo "Creating pi-utils polyfill..."
echo 'export * from "@oh-my-pi/pi-ai";' > pi-utils-polyfill.ts
cat packages/utils/src/fetch-retry.ts >> pi-utils-polyfill.ts
cat packages/utils/src/stream.ts >> pi-utils-polyfill.ts
cat packages/utils/src/abortable.ts >> pi-utils-polyfill.ts
cat packages/utils/src/json-parse.ts >> pi-utils-polyfill.ts
cat packages/utils/src/json.ts >> pi-utils-polyfill.ts
cat packages/utils/src/type-guards.ts >> pi-utils-polyfill.ts
cat << 'EOF' >> pi-utils-polyfill.ts

export const $flag = (name: string) => false;
export const $env = (name: string) => undefined;
EOF

echo "Installing dependencies to allow bundling..."
bun install

echo "Creating entry point..."
cat << 'EOF' > plugin-entry.ts
export { loginAntigravity, refreshAntigravityToken } from "./packages/ai/src/registry/oauth/google-antigravity.ts";
export { streamGoogleGeminiCli } from "./packages/ai/src/providers/google-gemini-cli.ts";
export { getBundledModels } from "./packages/catalog/src/models.ts";
EOF

echo "Bundling with esbuild..."
npx -y esbuild plugin-entry.ts --bundle --outfile="$EXT_DIR/plugin-bundled.js" --format=esm --platform=node \
  --alias:@oh-my-pi/pi-utils=./pi-utils-polyfill.ts \
  --external:@oh-my-pi/* \
  --external:bun

echo "Patching namespaces in bundled file..."
cd "$EXT_DIR"
# All externalized @oh-my-pi/* imports (pi-catalog/models, pi-ai) actually come from @earendil-works/pi-ai in the runtime
sed -i -E 's|@oh-my-pi/[a-zA-Z0-9/-]+|@earendil-works/pi-ai|g' plugin-bundled.js

echo "Cleaning up..."
rm -rf "$TMP_DIR"

echo "Sync complete!"
