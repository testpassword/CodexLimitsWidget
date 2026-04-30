# CodexLimitsWidget[^vibe]

A native macOS app with a WidgetKit desktop widget that shows the remaining
Codex limits without opening an interactive Codex CLI session.

The widget uses `codex app-server` and the `account/rateLimits/read` method, so
it reads the same source of data that backs `/status` in the Codex CLI.

## Contents

- `Sources/CodexLimitsHost` - a small host app that syncs an auth snapshot.
- `Sources/CodexLimitsWidget` - the WidgetKit extension that reads and renders limits.
- `Resources` - `Info.plist`, entitlements, and the app/widget icon.
- `codex-limits` - a CLI script for printing limits without the interactive TUI.
- `build-widget.sh` - builds the `.app` bundle.
- `install-widget.sh` - builds, installs into `/Applications`, and registers the widget.

## Requirements

- macOS with WidgetKit desktop widget support.
- Apple Silicon target (`arm64-apple-macosx14.0` in `build-widget.sh`).
- Installed `swiftc` / `Xcode Command Line Tools`.
- Installed and authenticated [`Codex CLI`](https://developers.openai.com/codex/cli).

## Build

```sh
./build-widget.sh
```

The app bundle is created at:

```text
build/Codex Limits.app
```

## Install

```sh
./install-widget.sh
```

The script:

- rebuilds the app;
- installs it to `/Applications/Codex Limits.app`;
- removes the old `/Applications/CodexLimits.app` bundle if it is still present;
- registers the app through Launch Services;
- opens the host app.

After installation, open the macOS widget gallery and search for `Codex Limits`.

## Authentication

The WidgetKit extension runs in a sandbox and does not read the user's
`~/.codex/auth.json` directly. Instead, the host app copies a short auth snapshot
into the widget extension's Application Support directory on launch and when the
`Refresh Widget` button is pressed. The container location is resolved at runtime
from the bundled widget extension.

The snapshot stores only:

- access token;
- account id;
- plan type;
- update timestamp.

The refresh token is not copied.

## CLI

Print limits in the terminal:

```sh
./codex-limits
```

Print the raw JSON response:

```sh
./codex-limits --json
```

Show all buckets if the Codex CLI returns more than one:

```sh
./codex-limits --all
```

## Troubleshooting

If the widget appears but does not show limits:

1. Open `/Applications/Codex Limits.app`.
2. Press `Refresh Widget`.
3. Make sure the `codex` CLI is authenticated and available from `PATH`.
4. Rebuild and reinstall:

```sh
./install-widget.sh
```

[^vibe]: This project is fully vibe-coded, from development to publication.
