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

echo "Localizing pi-catalog/identity for preferredDialect..."
cp packages/catalog/src/identity/classify.ts packages/catalog/src/identity/classify.fixed.ts
cp packages/catalog/src/identity/family.ts packages/catalog/src/identity/family.fixed.ts
cp packages/catalog/src/identity/dialect.ts packages/catalog/src/identity/dialect.fixed.ts

# Fix internal import paths: add .js extension and target the fixed files
apply_patch 'from "./classify"' 'from "./classify.fixed.js"' packages/catalog/src/identity/family.fixed.ts 'classify.fixed.js'
apply_patch 'from "./family"' 'from "./family.fixed.js"' packages/catalog/src/identity/dialect.fixed.ts 'family.fixed.js'

# Patch demotion.ts to import preferredDialect from local path instead of @oh-my-pi/pi-catalog/identity
# The identity files are at packages/catalog/src/identity/, relative to packages/ai/src/dialect/ is ../../../catalog/src/identity/
apply_patch 'import { preferredDialect } from "@oh-my-pi/pi-catalog/identity"' 'import { preferredDialect } from "../../../catalog/src/identity/dialect.fixed.ts"' packages/ai/src/dialect/demotion.ts '../../../catalog/src/identity/dialect.fixed'

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

# omptype is a self-contained schema library used by google-gemini-cli.ts via
# `import { type } from "@oh-my-pi/omptype"`. It must be inlined into the bundle:
# externalizing it would have the namespace patch rewrite it to
# @earendil-works/pi-ai, which does not export `type` at runtime.
echo 'export * from "./packages/omptype/src/index.ts";' > omptype-polyfill.ts

# TypeBox internal markers (~optional, ~readonly, ~kind) are non-enumerable properties
# added by typebox@1.3.7+. They must be stripped from wire schemas because some
# code paths (upgradeJsonSchemaTo202012 fast-path) preserve the original object
# with these markers, and downstream JSON serialization may expose them.
echo 'export function stripTypeBoxMarkers<T>(value: T, seen = new WeakMap()): T {
  if (value === null || typeof value !== "object") return value;
  if (seen.has(value)) return seen.get(value) as T;

  if (Array.isArray(value)) {
    const arr: any[] = [];
    seen.set(value, arr);
    for (let i = 0; i < value.length; i++) {
      arr[i] = stripTypeBoxMarkers(value[i], seen);
    }
    return arr as any;
  }

  const result: Record<string, unknown> = {};
  seen.set(value, result);

  for (const key of Reflect.ownKeys(value)) {
    if (typeof key === "string" && key.startsWith("~")) continue;
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor) continue;
    if (descriptor.get || descriptor.set) {
      const newDescriptor: PropertyDescriptor = {
        enumerable: descriptor.enumerable,
        configurable: descriptor.configurable,
      };
      if (descriptor.get) {
        const originalGet = descriptor.get;
        newDescriptor.get = function() {
          return stripTypeBoxMarkers(originalGet.call(value), seen);
        };
      }
      if (descriptor.set) {
        const originalSet = descriptor.set;
        newDescriptor.set = function(_val: any) {
          originalSet.call(value, stripTypeBoxMarkers(_val, seen));
        };
      }
      Object.defineProperty(result, key, newDescriptor);
    } else {
      Object.defineProperty(result, key, {
        ...descriptor,
        value: stripTypeBoxMarkers(descriptor.value, seen)
      });
    }
  }
  return result as T;
}' > typebox-strip.ts

echo "Running stripTypeBoxMarkers smoke tests..."
cat << 'EOF' > test-strip.ts
import { stripTypeBoxMarkers } from "./typebox-strip.ts";

// 1. Basic marker stripping
const obj = { "~optional": true, normal: 1 };
const stripped = stripTypeBoxMarkers(obj);
if ("~optional" in stripped) throw new Error("Failed to strip marker");

// 2. Cyclic reference
const cycle: any = { a: 1 };
cycle.self = cycle;
const strippedCycle = stripTypeBoxMarkers(cycle);
if (strippedCycle.self !== strippedCycle) throw new Error("Failed to handle cyclic reference");

// 3. Getter caching and memoization, setter symmetry
let cached: any = null;
const withGetter = {};
Object.defineProperty(withGetter, "lazy", {
  get() {
    if (!cached) cached = { val: 42 };
    return cached;
  },
  set(val) {
    cached = val;
  },
  enumerable: true
});
const strippedGetter = stripTypeBoxMarkers(withGetter);
if (strippedGetter.lazy !== strippedGetter.lazy) throw new Error("Getter object identity not preserved");

strippedGetter.lazy = { "~optional": true, val: 100 };
if ("~optional" in strippedGetter.lazy) throw new Error("Setter value not stripped");

// 4. Property descriptor preservation (Q5)
const nonEnum = {};
Object.defineProperty(nonEnum, "hidden", {
  value: { "~readonly": true, data: 1 },
  enumerable: false,
  configurable: false,
  writable: false,
});
const strippedNonEnum = stripTypeBoxMarkers(nonEnum);
const desc = Object.getOwnPropertyDescriptor(strippedNonEnum, "hidden")!;
if (desc.enumerable !== false) throw new Error("Non-enumerable property became enumerable");
if (desc.writable !== false) throw new Error("Non-writable property became writable");
if (desc.configurable !== false) throw new Error("Non-configurable property became configurable");

// 5. Symbol property preservation (Q2)
const sym = Symbol.for("test.symbol");
const withSymbol: any = { normal: 1 };
withSymbol[sym] = { "~kind": "test", val: 42 };
const strippedSym = stripTypeBoxMarkers(withSymbol);
if (!(sym in strippedSym)) throw new Error("Symbol property dropped");
if ("~kind" in strippedSym[sym]) throw new Error("Symbol property value not stripped");
if (strippedSym[sym].val !== 42) throw new Error("Symbol property value corrupted");

// 6. Getter this context (Q3)
const original = { secret: 42 };
Object.defineProperty(original, "derived", {
  get() { return this.secret * 2; },
  enumerable: true,
});
const strippedCtx = stripTypeBoxMarkers(original);
if (strippedCtx.derived !== 84) throw new Error("Getter this context lost");

// 7. Setter this context (Q4)
const withSetter: any = { _data: 1 };
Object.defineProperty(withSetter, "computed", {
  get() { return this._data; },
  set(val: any) { this._data = val; },
  enumerable: true,
});
const strippedSetter = stripTypeBoxMarkers(withSetter);
strippedSetter.computed = { "~optional": true, nested: 99 };
if (typeof strippedSetter.computed !== "object") throw new Error("Setter this context lost");

console.log("smoke tests passed.");
EOF
bun run test-strip.ts

# strip 関数を wire.ts と同じディレクトリにコピー（相対 import で解決）
cp typebox-strip.ts packages/ai/src/utils/schema/typebox-strip.ts

# wire.ts に stripTypeBoxMarkers を import し、toolWireSchema の両 return に適用する
apply_patch 'import { stamp } from "./stamps";' 'import { stamp } from "./stamps";\nimport { stripTypeBoxMarkers } from "./typebox-strip";' packages/ai/src/utils/schema/wire.ts 'stripTypeBoxMarkers'
apply_patch 'return arkToWireSchema(params);' 'return stripTypeBoxMarkers(arkToWireSchema(params));' packages/ai/src/utils/schema/wire.ts 'stripTypeBoxMarkers(arkToWireSchema'
apply_patch 'return postProcessJsonSchema(upgraded);' 'return stripTypeBoxMarkers(postProcessJsonSchema(upgraded));' packages/ai/src/utils/schema/wire.ts 'stripTypeBoxMarkers(postProcessJsonSchema'

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
  --alias:@oh-my-pi/omptype=./omptype-polyfill.ts \
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
