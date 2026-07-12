# pi-antigravity-provider

A dynamic, auto-syncing Google Antigravity (Cloud Code Assist) provider plugin for `pi` (based on upstream `oh-my-pi`).

## 💡 Design Philosophy

This plugin is designed around **mechanical synchronization** and **minimal manual maintenance**.

Instead of duplicating the `google-antigravity` logic from the `oh-my-pi` core, this project uses a build script (`sync.sh`) to automatically extract, patch, and bundle the official implementation directly from the upstream repository.

- **Zero Core Modifications:** You do not need to modify your local `pi` binary. Just load this extension.
- **Upstream Tracking:** When `oh-my-pi` updates its models or provider logic, simply run `./sync.sh` to mechanically pull the latest upstream logic without rewriting code.
- **Dynamic Model Resolution:** It dynamically extracts model registries and internal wire IDs (`requestModelId`) directly from the bundled `pi-catalog`, ensuring 100% compatibility with the backend endpoints without brittle hardcoded strings.
- **Secure by Default:** The build process bundles the necessary dependencies but intentionally excludes OAuth secrets from the source control, relying on `pi`'s secure environment.

## 🚀 Usage

### 1. Build / Sync with Upstream

Before using the plugin, you must generate the bundled provider. You only need to run this once, or whenever you want to update the internal logic from the latest `oh-my-pi` repository.

```bash
# Clone the repository
git clone https://github.com/Masterisk-F/pi-antigravity-provider.git
cd pi-antigravity-provider

# Run the synchronization script (Requires git, sed, and bun)
./sync.sh
```

This script will:
1. Fetch the latest `oh-my-pi` source.
2. Patch internal dependencies to work outside the core runtime.
3. Generate `plugin-bundled.js` containing the required utilities and logic.

### 2. Run `pi` with the Extension

Start `pi` by passing the `index.ts` file as an extension:

```bash
pi -e /path/to/pi-antigravity-provider/index.ts
```

*(You can also add this flag to an alias in your `.bashrc` or `.zshrc` for convenience.)*

### 3. Authentication

Once inside `pi`, authenticate with Google Antigravity if you haven't already:

```
/login google-antigravity
```

You can now use `gemini-3.5-flash`, `claude-3-7-sonnet`, and other Antigravity models directly from `pi`!

## 📝 License

[MIT License](LICENSE)
