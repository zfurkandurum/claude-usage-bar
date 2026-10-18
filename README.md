# Claude Usage Bar

A lightweight macOS menu bar app that shows how much of your Claude subscription
usage limit is left — the 5-hour window and, optionally, the weekly one.

Claude Code's `/usage` command shows these numbers, but only inside a terminal
session. Claude Usage Bar keeps them visible at all times.

## Features

- Remaining 5-hour limit as a compact percentage in the menu bar, with the weekly limit as an option
- Color warning when the limit runs low (orange below 25%, red below 10%)
- Click for a detail panel: progress bars, time until each limit resets, signed-in account and plan
- Right-click for a quick menu (Settings, Refresh, Quit)
- Settings window: weekly limit in the bar, remaining vs. used, refresh interval, launch at login
- Starts automatically at login (on by default, can be disabled in Settings)
- Native Swift, no dependencies, no Dock icon, universal binary (Apple Silicon and Intel), macOS 13+
- English and Turkish interface, chosen from the system language

## Requirements

- macOS 13 or later
- A Claude Pro or Max subscription
- [Claude Code](https://claude.com/claude-code) installed and signed in on the same Mac

The app has no login of its own. It reuses the Claude Code sign-in.

## Installation

### Build from source

Requires Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/zfurkandurum/claude-usage-bar.git
cd claude-usage-bar
./build.sh
open ~/Applications/ClaudeUsageBar.app
```

`build.sh` installs the app to `~/Applications`. Pass a directory to install elsewhere:
`./build.sh /Applications`.

### Prebuilt release

Download `ClaudeUsageBar.zip` from the [Releases](https://github.com/zfurkandurum/claude-usage-bar/releases)
page and move the app to `/Applications`. The app is ad-hoc signed and not notarized, so
macOS blocks the first launch. Remove the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/ClaudeUsageBar.app
```

### First launch

macOS asks whether the app may access the `Claude Code-credentials` Keychain item.
Choose **Always Allow**, otherwise the prompt returns on every refresh.

## Usage

| Action | Result |
| --- | --- |
| Click the percentage | Opens the detail panel |
| Right-click or Ctrl-click | Opens the Settings / Refresh / Quit menu |
| Settings → Menu bar | Show the weekly limit, switch between remaining and used |
| Settings → General | Launch at login, refresh interval (1, 2, 5 or 10 minutes) |

## Accounts

The bar shows the limits of the account Claude Code is currently signed into on
this Mac. That account (email and plan) is displayed in the panel and in Settings.

- **Switching accounts** with `claude /login`, or with a tool that swaps the Keychain
  login, takes effect on the next refresh. Cached values are stored per account and are
  never shown for a different one.
- **Separate config folders** (`CLAUDE_CONFIG_DIR`): choose the folder under
  Settings → Account. The app then reads `<folder>/.credentials.json` and `<folder>/.claude.json`.
- Only one account is tracked at a time.
- API-key and Console sign-ins have no subscription limits, so there is nothing to display for them.

## How it works

Claude Code stores its OAuth login in the macOS Keychain (item `Claude Code-credentials`),
or in `<config folder>/.credentials.json` when a custom folder is used. On each refresh the
app reads that token with `/usr/bin/security` and requests

```
GET https://api.anthropic.com/api/oauth/usage
```

which is the same data behind Claude Code's `/usage` command. The token is sent only to
`api.anthropic.com`. Nothing is written to disk except your preferences and the last
usage values (in `UserDefaults`), and no analytics or third-party services are involved.

The token is re-read on every refresh, so a token renewed by Claude Code or a different
signed-in account is picked up automatically. The app never refreshes tokens itself, to
avoid interfering with Claude Code.

## Rate limiting

The usage endpoint is rate-limited by the server, so requests are throttled by design:

- All refreshes (timer, opening the panel, wake from sleep, the refresh button, app launch)
  pass through a single gate that allows at most one request per refresh interval
  (default: 2 minutes). The gate survives app restarts, so relaunching never causes an extra request.
- The last values are cached on disk and shown immediately at launch.
- On HTTP 429 the app backs off exponentially (2, 4, 8, 16, then 30 minutes, honoring
  `Retry-After`), keeps showing the last known values and retries automatically when the
  back-off ends.
- The manual refresh button is limited to once every 15 seconds and never overrides a back-off.

## Limitations

- The usage endpoint is undocumented and may change or stop working at any time.
  When a request fails, the bar shows a warning symbol next to the last known value.
- If the stored token has expired, open Claude Code once so it can renew the token.
- The weekly figure and reset times depend on what the server returns for your plan.

## Uninstall

Quit from the right-click menu, turn off *Launch at login* in Settings, then delete
`ClaudeUsageBar.app`. Preferences can be removed with
`defaults delete io.github.claude-usage-bar`.

## Contributing

The app is a single file, [`main.swift`](main.swift), built with SwiftUI and AppKit.
Issues and pull requests are welcome, for example translations, per-model limits or
threshold notifications.

For UI work, the app accepts two launch flags that open the panel or the settings window
directly: `--open-popover` and `--open-settings`.

## Disclaimer

This is an independent project and is not affiliated with or endorsed by Anthropic.

## License

[MIT](LICENSE)
