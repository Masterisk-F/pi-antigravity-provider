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

echo "Patching google-gemini-cli.ts for pi compatibility..."
apply_patch '"token?": optionalCredentialString,' '"token?": optionalCredentialString,\n\t"access?": optionalCredentialString,' packages/ai/src/providers/google-gemini-cli.ts '"access?": optionalCredentialString'
apply_patch 'if (parsed.token === undefined' 'if ((parsed.token ?? parsed.access) === undefined' packages/ai/src/providers/google-gemini-cli.ts 'parsed.access'
apply_patch 'accessToken: parsed.token,' 'accessToken: parsed.token ?? parsed.access!,' packages/ai/src/providers/google-gemini-cli.ts 'parsed.access!'
apply_patch '\[ANTIGRAVITY_DAILY_ENDPOINT, ANTIGRAVITY_SANDBOX_ENDPOINT\]' '\[ANTIGRAVITY_DAILY_ENDPOINT, ANTIGRAVITY_SANDBOX_ENDPOINT, DEFAULT_ENDPOINT\]' packages/ai/src/providers/google-gemini-cli.ts 'DEFAULT_ENDPOINT'

echo "Creating polyfills and stubs..."

cat << 'EOF' > pi-utils-polyfill.ts
export * from "./packages/utils/src/fetch-retry.ts";
export * from "./packages/utils/src/stream.ts";
export * from "./packages/utils/src/abortable.ts";
export * from "./packages/utils/src/json-parse.ts";
export * from "./packages/utils/src/json.ts";
export * from "./packages/utils/src/type-guards.ts";
export * from "./packages/utils/src/binary.ts";
export * from "./packages/utils/src/sanitize-text.ts";
export * from "./packages/utils/src/peek-file.ts";
export * from "./packages/utils/src/mime.ts";

// Environment & flags
export const $flag = (_name: string) => false;
export const $env = (name: string) => process["env"][name];
export const $envExact = (name: string) => process["env"][name];
export const $envpos = (name: string) => process["env"][name];
export const $pickenv = (...names: string[]) => {
  for (const name of names) {
    const val = process["env"][name];
    if (val !== undefined && val !== "") return val;
  }
  return undefined;
};

// Application identity
export const USER_AGENT = "oh-my-pi";
export const getAppName = () => "pi";
export const getInstallId = () => "pi-installation";
export const getAgentDbPath = () => "";
export const getModelDbPath = () => "";
export const getLogsDir = () => "";
export const getAgentDir = () => "";
export const getProviderInFlightRoot = () => "";
export const isBunTestRuntime = () => false;

// Error helpers
export const isEnoent = (err: unknown) => Boolean(err && typeof err === "object" && "code" in err && (err as any).code === "ENOENT");
export const isSqliteCorruptionError = () => false;

// Logging stub
export const logger = {
  debug: () => {},
  info: () => {},
  warn: () => {},
  error: () => {},
};

export const debug = () => {};
export const info = () => {};
export const warn = () => {};
export const error = () => {};

// CA / Fetch helpers
export const wrapFetchForExtraCa = (f: any) => f ?? fetch;
export const resolveExtraCa = () => undefined;
export const withExtraCaInit = (init: any) => init;

// String helpers
export const truncate = (str: string, maxLen: number) => str.length > maxLen ? str.slice(0, maxLen) + "..." : str;

function isPlainObject(val: object): val is Record<string, unknown> {
  return Object.getPrototypeOf(val) === Object.prototype || Array.isArray(val);
}

export function structuredCloneJSON<T>(value: T): T {
  if (!value || typeof value !== "object") return value;
  if (isPlainObject(value)) {
    try {
      return structuredClone(value);
    } catch {
    }
  }
  return JSON.parse(JSON.stringify(value)) as T;
}

// LRU Cache
export class LRUCache<K, V> extends Map<K, V> {
  private max: number;
  constructor(max = 100) {
    super();
    this.max = max;
  }
  override get(key: K): V | undefined {
    if (!super.has(key)) return undefined;
    const val = super.get(key)!;
    super.delete(key);
    super.set(key, val);
    return val;
  }
  override set(key: K, value: V): this {
    if (super.has(key)) super.delete(key);
    super.set(key, value);
    if (this.size > this.max) {
      const first = this.keys().next().value;
      if (first !== undefined) this.delete(first);
    }
    return this;
  }
}
EOF

cat << 'EOF' > pi-natives-stub.ts
export class NativeOAuthCallback {
  constructor(_opts: any) {}
  async start() { return false; }
  async dispose() {}
  cancel() {}
  async waitForCallback() { throw new Error("Native callback not supported"); }
}
export default {};
EOF

cat << 'EOF' > bun-polyfill.ts
export const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
export const $ = () => {};
export const Cookie = {};
export const CookieMap = class {};
export const YAML = { parse: () => ({}), stringify: () => "" };
export default {
  sleep,
  $,
  Cookie,
  CookieMap,
  YAML,
};
EOF

# TypeBox internal markers (~optional, ~readonly, ~kind) are non-enumerable properties
# added by typebox@1.3.7+. They must be stripped from wire schemas because some
# code paths (upgradeJsonSchemaTo202012 fast-path) preserve the original object
# with these markers, and downstream JSON serialization may expose them.
echo 'export function stripTypeBoxMarkers<T>(value: T, seen = new WeakMap()): T {
  if (value === null || typeof value !== "object") return value;
  if (seen.has(value)) return seen.get(value) as T;

  const proto = Object.getPrototypeOf(value);
  const result = Array.isArray(value) ? [] : Object.create(proto);
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
        newDescriptor.get = function(this: unknown) {
          return stripTypeBoxMarkers(originalGet.call(this), seen);
        };
      }
      if (descriptor.set) {
        const originalSet = descriptor.set;
        newDescriptor.set = function(this: unknown, _val: any) {
          originalSet.call(this, stripTypeBoxMarkers(_val, seen));
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

// 6. Getter this context — クローン状態の反映（stale reads 検出）
const original = { secret: 42 };
Object.defineProperty(original, "derived", {
  get() { return this.secret * 2; },
  enumerable: true,
});
const strippedCtx = stripTypeBoxMarkers(original);
if (strippedCtx.derived !== 84) throw new Error("Getter this context lost");
strippedCtx.secret = 100;                       // クローンのみ変更
if (strippedCtx.derived !== 200) throw new Error("Getter reads stale original state");
if (original.secret !== 42) throw new Error("Original mutated by clone getter");

// 7. Setter this context — クローンへの書き込みがオリジナルを壊さない
const withSetter: any = { _data: 1 };
Object.defineProperty(withSetter, "computed", {
  get() { return this._data; },
  set(val: any) { this._data = val; },
  enumerable: true,
});
const strippedSetter = stripTypeBoxMarkers(withSetter);
strippedSetter.computed = { "~optional": true, nested: 99 };
if (withSetter._data !== 1) throw new Error("Setter mutated original object!");
if ("~optional" in strippedSetter.computed) throw new Error("Setter value not stripped");
if (strippedSetter.computed.nested !== 99) throw new Error("Clone state not updated");

// 8. Array testing (Q3 & Q2)
const arr: any = [{ "~optional": true, val: 1 }, 2];
arr.custom = { "~kind": "test", data: 42 };
const strippedArr = stripTypeBoxMarkers(arr);
if (!Array.isArray(strippedArr)) throw new Error("Array is no longer an array");
if (strippedArr.length !== 2) throw new Error("Array length mismatch");
if ("~optional" in strippedArr[0]) throw new Error("Array element marker not stripped");
if ("~kind" in strippedArr.custom) throw new Error("Array custom property marker not stripped");
if (strippedArr.custom.data !== 42) throw new Error("Array custom property data corrupted");

// 9. Prototype chain preservation (Q1)
class CustomClass {
  method() { return 42; }
}
const inst = new CustomClass();
(inst as any).val = { "~optional": true, inner: 1 };
const strippedInst = stripTypeBoxMarkers(inst);
if (!(strippedInst instanceof CustomClass)) throw new Error("Prototype chain lost");
if (strippedInst.method() !== 42) throw new Error("Method not inherited");
if ("~optional" in (strippedInst as any).val) throw new Error("Marker not stripped in class instance");

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
import { authPolicyFor } from "./packages/catalog/src/compat/auth.ts";
import { buildProviderDefinition } from "./packages/ai/src/registry/build.ts";

const antigravityDef = buildProviderDefinition(authPolicyFor("google-antigravity")!);

export async function loginAntigravity(callbacks: any) {
  if (!antigravityDef.login) throw new Error("No login handler configured for google-antigravity");
  return antigravityDef.login(callbacks);
}

export async function refreshAntigravityToken(refreshTokenOrCred: any, projectId?: string) {
  if (!antigravityDef.refreshToken) throw new Error("No refresh handler configured for google-antigravity");
  const creds = typeof refreshTokenOrCred === "string"
    ? { access: "", refresh: refreshTokenOrCred, expires: 0, projectId }
    : refreshTokenOrCred;
  return antigravityDef.refreshToken(creds);
}

export { streamGoogleGeminiCli } from "./packages/ai/src/providers/google-gemini-cli.ts";
export { getBundledModels } from "./packages/catalog/src/models.ts";
EOF

echo "Bundling with esbuild..."
npx -y esbuild plugin-entry.ts --bundle --outfile="$EXT_DIR/plugin-bundled.js" --format=esm --platform=node \
  --alias:@oh-my-pi/pi-utils=./pi-utils-polyfill.ts \
  --alias:@oh-my-pi/pi-utils/lru=./pi-utils-polyfill.ts \
  --alias:@oh-my-pi/pi-utils/logger=./pi-utils-polyfill.ts \
  --alias:@oh-my-pi/pi-utils/type-guards=./pi-utils-polyfill.ts \
  --alias:@oh-my-pi/pi-utils/fetch-retry=./pi-utils-polyfill.ts \
  --alias:@oh-my-pi/pi-catalog=./packages/catalog/src \
  --alias:@oh-my-pi/omptype=./packages/omptype/src/index.ts \
  --alias:@oh-my-pi/pi-ai=./packages/ai/src \
  --alias:@oh-my-pi/pi-natives=./pi-natives-stub.ts \
  --alias:bun=./bun-polyfill.ts

echo "Cleaning up..."
rm -rf "$TMP_DIR"

echo "Sync complete!"
