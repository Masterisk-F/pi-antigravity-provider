---
name: sync-omp
description: Sync with upstream oh-my-pi (omp) repository, update sync.sh when upstream structures change, bundle plugin-bundled.js, verify models and extension registration, and commit/push the changes. Use whenever updating or syncing oh-my-pi dependencies.
---

# Sync with Upstream oh-my-pi (omp)

This skill updates the plugin by fetching the latest `oh-my-pi` codebase, bundling the provider dependencies, and verifying the runtime compatibility.

## Workflow

### 1. Run sync script

Execute `./sync.sh` in the project root:

```bash
./sync.sh
```

### 2. Handle upstream drift (if sync fails)

If `./sync.sh` fails:
1. Clone or inspect the latest oh-my-pi repository to `/tmp` to inspect structural changes.
2. Check for changes in:
   - `packages/catalog/src/identity/` or `compat/` (model classification, taxonomy, auth rules)
   - `packages/catalog/src/compat/rules/auth/google-antigravity.kdl` (OAuth configs/endpoints)
   - `packages/ai/src/providers/google-gemini-cli.ts` (request handling / credentials parsing)
   - `packages/ai/src/registry/` (provider definitions, login/refresh hooks)
   - `packages/utils/src/` (new utility functions needed by catalog/ai)
3. Adjust `sync.sh` (polyfills, stubs, aliases, esbuild entry point) accordingly.
4. Re-run `./sync.sh` until it succeeds.

### 3. Verification

Run the verification script to ensure exports and runtime compatibility:

```bash
node -e '
import("./plugin-bundled.js").then(async bundle => {
  console.log("Checking exports:", Object.keys(bundle));
  const models = bundle.getBundledModels("google-antigravity");
  console.log("Found models:", models.length);
  if (models.length === 0) throw new Error("No models found for google-antigravity");
  
  if (typeof bundle.streamGoogleGeminiCli !== "function") throw new Error("streamGoogleGeminiCli missing");
  if (typeof bundle.loginAntigravity !== "function") throw new Error("loginAntigravity missing");
  if (typeof bundle.refreshAntigravityToken !== "function") throw new Error("refreshAntigravityToken missing");

  const { default: initExtension } = await import("./index.ts");
  let registered = null;
  const mockPi = {
    registerProvider: (id, provider) => { registered = { id, provider }; }
  };
  initExtension(mockPi);
  if (!registered || registered.id !== "google-antigravity") {
    throw new Error("Extension registration failed");
  }
  console.log("Smoke test passed!");
});
'
```

### 4. Git Commit & Push

Review changes with `git status` and `git diff`, then create a commit and push to remote:

```bash
git add sync.sh
git commit -m "fix(sync): sync upstream oh-my-pi"
git push origin master
```
