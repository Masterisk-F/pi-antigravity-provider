#!/bin/bash
set -e

EXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR=$(mktemp -d)

echo "Fetching latest oh-my-pi from GitHub into $TMP_DIR..."
git clone --depth 1 https://github.com/can1357/oh-my-pi.git "$TMP_DIR"

cd "$TMP_DIR"

apply_patch() {
  local pattern="$1"
  local replacement="$2"
  local file="$3"
  local expected_grep="$4"
  
  sed -i "s|$pattern|$replacement|g" "$file"
  if [ -n "$expected_grep" ] && ! grep -q "$expected_grep" "$file"; then
    echo "ERROR: Patch failed for $file. Expected to find: $expected_grep"
    exit 1
  fi
}

echo "Localizing internal dependencies..."
cp packages/catalog/src/wire/gemini-headers.ts packages/ai/src/registry/oauth/gemini-headers.ts
cp packages/catalog/src/wire/gemini-headers.ts packages/ai/src/providers/gemini-headers.ts
apply_patch '@oh-my-pi/pi-catalog/wire/gemini-headers' './gemini-headers.ts' packages/ai/src/registry/oauth/google-antigravity.ts './gemini-headers.ts'
apply_patch '@oh-my-pi/pi-catalog/wire/gemini-headers' './gemini-headers.ts' packages/ai/src/providers/google-gemini-cli.ts './gemini-headers.ts'

echo "Patching google-gemini-cli.ts for pi compatibility..."
apply_patch '"token?": optionalCredentialString,' '"token?": optionalCredentialString,\n\t"access?": optionalCredentialString,' packages/ai/src/providers/google-gemini-cli.ts '"access?": optionalCredentialString'
apply_patch 'if (parsed.token === undefined' 'if ((parsed.token ?? parsed.access) === undefined' packages/ai/src/providers/google-gemini-cli.ts 'parsed.access'
apply_patch 'accessToken: parsed.token,' 'accessToken: parsed.token ?? parsed.access!,' packages/ai/src/providers/google-gemini-cli.ts 'parsed.access!'
apply_patch '\[ANTIGRAVITY_DAILY_ENDPOINT, ANTIGRAVITY_SANDBOX_ENDPOINT\]' '\[ANTIGRAVITY_DAILY_ENDPOINT, ANTIGRAVITY_SANDBOX_ENDPOINT, DEFAULT_ENDPOINT\]' packages/ai/src/providers/google-gemini-cli.ts 'DEFAULT_ENDPOINT'
apply_patch 'const CLOUD_CODE_ENDPOINT = "https://cloudcode-pa.googleapis.com";' 'const CLOUD_CODE_ENDPOINT = "https://daily-cloudcode-pa.googleapis.com";' packages/ai/src/registry/oauth/google-antigravity.ts 'daily-cloudcode-pa.googleapis.com'

echo "Creating pi-utils polyfill..."
echo 'export * from "@oh-my-pi/pi-ai";' > pi-utils-polyfill.ts
cat packages/utils/src/fetch-retry.ts >> pi-utils-polyfill.ts
cat packages/utils/src/stream.ts >> pi-utils-polyfill.ts
cat packages/utils/src/abortable.ts >> pi-utils-polyfill.ts
cat packages/utils/src/json-parse.ts >> pi-utils-polyfill.ts
cat packages/utils/src/json.ts >> pi-utils-polyfill.ts
cat packages/utils/src/type-guards.ts >> pi-utils-polyfill.ts
cat << 'EOF' >> pi-utils-polyfill.ts

// Feature flags default to false to disable experimental upstream features gracefully
export const $flag = (name: string) => false;
// Fallback to real environment variables for upstream configuration
export const $env = (name: string) => process.env[name];
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
if grep -q '@oh-my-pi' plugin-bundled.js; then
  echo "ERROR: Failed to completely patch @oh-my-pi namespace in bundle."
  exit 1
fi
if ! grep -q '@earendil-works/pi-ai' plugin-bundled.js; then
  echo "ERROR: Namespace replacement did not result in expected @earendil-works/pi-ai imports."
  exit 1
fi

echo "Cleaning up..."
rm -rf "$TMP_DIR"

echo "Sync complete!"
