# Claude Usage Bar

A lightweight macOS menu bar app that shows how much of your Claude subscription
usage limit is left — the 5-hour window and, optionally, the weekly one.

Claude Code's `/usage` command shows these numbers, but only inside a terminal
session. Claude Usage Bar keeps them visible at all times.

## Features

- Remaining 5-hour limit as a compact percentage in the menu bar, with the weekly limit as an option
- Optional menu bar icon (gauge, bars, sparkle or asterisk; or none), chosen in Settings
- Color warning when the limit runs low (orange below 25%, red below 10%)
- Track several Claude accounts at once: sign in with the browser, rename, reorder and remove them in Settings
- Choose which accounts appear in the menu bar (one or several, e.g. `42% | 88%`)
- Click for a detail panel: progress bars and reset times for every account, with email and plan
- Right-click for a quick menu (Settings, Refresh, menu bar accounts, Quit)
- Settings window: weekly limit in the bar, remaining vs. used, refresh interval, launch at login
- Starts automatically at login (on by default, can be disabled in Settings)
- Native Swift, no dependencies, no Dock icon, universal binary (Apple Silicon and Intel), macOS 13+
- English and Turkish interface, chosen from the system language

## Requirements

- macOS 13 or later
- A Claude subscription (Pro, Max, Team, …)
- [Claude Code](https://claude.com/claude-code) installed on the same Mac (accounts are signed in from the app)

The app has no login of its own. It signs accounts in through Claude Code's `claude auth login`
and never uses the default Claude Code login of this Mac.

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

Open Settings and add an account. After each sign-in, macOS asks whether the app may access that
account's Keychain item (`Claude Code-credentials-…`). Choose **Always Allow**, otherwise the prompt
returns on every refresh.

## Usage

| Action | Result |
| --- | --- |
| Click the percentage | Opens the detail panel |
| Right-click or Ctrl-click | Opens the Settings / Refresh / Menu bar accounts / Quit menu |
| Settings → Accounts | Add (browser sign-in), edit, remove and reorder accounts, choose which ones show in the menu bar |
| Settings → Menu bar | Icon, show the weekly limit, switch between remaining and used |
| Settings → General | Launch at login, refresh interval (1, 2, 5 or 10 minutes) |

## Accounts

The app tracks any number of Claude accounts, Pro, Max, Team or any other plan. Every account is
added explicitly; the default Claude Code login of this Mac is not tracked.

- **Add account…** (Settings → Accounts): enter a name and sign in with your browser. The app runs
  Claude Code's own `claude auth login` for a private folder,
  `~/Library/Application Support/ClaudeUsageBar/accounts/<name>`, so the login stays separate from
  Claude Code's default one and from your other accounts. If the browser does not open, copy the
  link from the sign-in window (and paste the code the page shows, if any).
- **Edit:** the pencil button changes the name. Without a name, the account's email is shown.
- **Sign in again:** shown next to an account whose login is missing or expired. It is also in the
  edit window at any time, for example to switch the Claude account behind an entry.
- **Remove:** the trash button, after a confirmation. The account is signed out and its private folder deleted.
- **Reorder:** drag a row by its handle (right-click a row for *Move up* / *Move down*). The order is used in the panel and the menu bar.
- **Menu bar:** tick the accounts to show. One ticked account looks like a single percentage; several appear
  side by side (`42% | 88%`) and the tooltip lists their names. Without any tick, the first account is shown.
  The panel always lists every account, and the pin icon next to a name toggles it as well. So does
  the *Menu bar accounts* submenu of the right-click menu.
- Two entries that turn out to be the same account (same email) are flagged in Settings.
- Cached values are stored per account and are never shown for a different one.
- API-key and Console sign-ins have no subscription limits, so there is nothing to display for them.

Upgrading from a version that tracked the default login: that entry is dropped; add the account again
with *Add account…*.

Reading an account's token uses the Keychain item Claude Code creates for its folder
(`Claude Code-credentials-<8 hex characters>`), or `<folder>/.credentials.json`. macOS asks for
Keychain access once per account. Choose **Always Allow**. A folder without a login shows
"Not signed in" instead of another account's numbers.

## How it works

Claude Code stores each account's OAuth login in the macOS Keychain (one item per config folder),
or in `<config folder>/.credentials.json`.
On each refresh the app reads that token with `/usr/bin/security` and requests

```
GET https://api.anthropic.com/api/oauth/usage
```

which is the same data behind Claude Code's `/usage` command. The token is sent only to
`api.anthropic.com` (and to `platform.claude.com` when it is renewed). Nothing is written to disk except your preferences and the last
usage values (in `UserDefaults`) and the private account folders that Claude Code fills when you
sign in (the app adds the renewed login there). No analytics or third-party services are involved.

### Staying signed in

Access tokens last about 8 hours. The app renews them itself, shortly before they expire (or when
the server answers 401), with the refresh token Claude Code stored at sign-in. This is the same request
Claude Code makes: `POST https://platform.claude.com/v1/oauth/token`. The refresh token rolls forward with
every renewal (about 30 days each time), so an account stays signed in for as long as the app runs
now and then. The renewed login is saved in `<account folder>/.credentials.json` (owner-only) and is used
in preference to the older Keychain copy; a new sign-in replaces it.

Only if the refresh token is revoked or has gone unused for about a month (for example after signing out
of all sessions on claude.ai, or a month without the app running) does the account show *Sign in again*.

## Rate limiting

The usage endpoint is rate-limited by the server, so requests are throttled by design:

- All refreshes (timer, opening the panel, wake from sleep, the refresh button, app launch)
  pass through a gate that allows at most one request per account per refresh interval
  (default: 2 minutes). Every account has its own gate and back-off. The gate survives app restarts,
  so relaunching never causes an extra request.
- The last values of every account are cached on disk and shown immediately at launch.
- On HTTP 429 the app backs off exponentially (2, 4, 8, 16, then 30 minutes, honoring
  `Retry-After`), keeps showing the last known values and retries automatically when the
  back-off ends.
- The manual refresh button is limited to once every 15 seconds and never overrides a back-off.

## Limitations

- The usage endpoint is undocumented and may change or stop working at any time.
  When a request fails, the bar shows a warning symbol next to the last known value.
- Signing in needs Claude Code installed (the app looks for `claude` in `~/.local/bin`, Homebrew,
  the editor extension and your login shell's PATH).
- Renewing tokens relies on the same undocumented OAuth endpoint Claude Code uses, so it may change.
  A login that can no longer be renewed needs *Sign in again*.
- The weekly figure and reset times depend on what the server returns for your plan.

## Uninstall

Remove your accounts in Settings first (this signs them out and deletes their folders), quit from
the right-click menu, turn off *Launch at login*, then delete `ClaudeUsageBar.app`. Preferences can be
removed with `defaults delete io.github.claude-usage-bar`. Anything left of the accounts is in
`~/Library/Application Support/ClaudeUsageBar`.

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
