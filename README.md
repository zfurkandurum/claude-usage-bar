# Claude Usage Bar

A tiny macOS menu bar app that shows how much of your **Claude subscription
limit** (Pro / Max) you have left — the **5-hour** window, and optionally the
**weekly** one — right next to Wi-Fi and the clock.

```
 76%            ← 5-hour limit remaining
 76% · 19%      ← 5-hour · weekly (optional)
```

- Text only, no icon — takes very little menu bar space
- Turns orange under 25% and red under 10% remaining
- **Click** the number for a small panel: progress bars for the 5-hour and weekly limits, time until reset, refresh, **Settings…** and **Quit**
- **Right-click** (or Ctrl-click) for a quick Settings / Refresh / Quit menu
- Settings window: show weekly limit in the bar, show *used* instead of *remaining*, launch at login, refresh interval
- **Launch at login** (enabled on first run, can be switched off in Settings)
- Refreshes every 2 min (configurable) and after wake from sleep
- Native Swift, no dependencies, no Dock icon, universal (Apple Silicon + Intel), macOS 13+
- English and Turkish UI (follows system language)

## Requirements

You must be signed in to [Claude Code](https://claude.com/claude-code) on the
Mac (`claude` → log in with your Claude account). The app reuses that login to
read your usage; it has no login of its own.

## Install

### Build from source (recommended)

Needs Xcode or the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/zfurkandurum/claude-usage-bar.git
cd claude-usage-bar
./build.sh            # installs to ~/Applications/ClaudeUsageBar.app
open ~/Applications/ClaudeUsageBar.app
```

### Prebuilt release

Download `ClaudeUsageBar.zip` from the Releases page, unzip, move the app to
`~/Applications` (or `/Applications`). The app is ad-hoc signed, not notarized,
so macOS will block the first launch:

```sh
xattr -dr com.apple.quarantine /Applications/ClaudeUsageBar.app
```

(or right-click → Open).

### First run

macOS will ask whether `ClaudeUsageBar` may access the *Claude Code-credentials*
Keychain item. Choose **Always Allow**.

## How it works

Claude Code stores its OAuth token in the macOS Keychain (item
`Claude Code-credentials`, or `$CLAUDE_CONFIG_DIR/.credentials.json`). The app
reads it with `/usr/bin/security` on every refresh and calls

```
GET https://api.anthropic.com/api/oauth/usage
```

— the same data Claude Code's `/usage` command shows. The token is only ever
sent to `api.anthropic.com`; nothing is stored, logged, or sent anywhere else.
Preferences (weekly toggle, used/remaining) live in `UserDefaults`.

## Accounts

The app has no login of its own. It shows the limits of **the account Claude Code
is currently signed into on this Mac**, and displays that account (email · plan)
at the top of the panel and in Settings, so you always know which one you are looking at.

- **Switching accounts** (`claude /login`, or any account-switcher that swaps the
  Keychain login): the bar follows on the next refresh. Cached numbers belong to
  one account and are never shown for another.
- **Separate config folders** (`CLAUDE_CONFIG_DIR`): pick the folder in
  *Settings → Account* (it reads `<folder>/.credentials.json` and `.claude.json`).
- **One account at a time.** Showing several accounts side by side is not supported yet.
- API-key / Console logins have no subscription limits, so there is nothing to show for them.

## Rate limiting

The usage endpoint is rate-limited by the server, so the app is deliberately gentle:

- every request goes through one gate: at most one per refresh interval (default 2 min),
  **also across app restarts** — relaunching never triggers an extra request
- the last values are cached on disk and shown instantly at launch
- on HTTP 429 it backs off exponentially (2 → 4 → 8 → 16 → 30 min, honoring `Retry-After`),
  keeps showing the last value, and retries automatically when the back-off ends
- the manual refresh button is limited to once per 15 s and never overrides a back-off

## Caveats

- This endpoint is **undocumented/unofficial** and may change or break at any
  time. If it does, the bar shows `⚠︎`.
- The app never refreshes the token itself (to avoid clashing with Claude Code).
  If the token has expired, open Claude Code once and it will refresh.
- Only subscription (Pro/Max) logins expose these limits; API-key-only setups
  have nothing to show.
- Not affiliated with or endorsed by Anthropic.

## Uninstall

Quit from the menu, turn off *Launch at login*, delete the app.

## Contributing

Single file ([main.swift](main.swift), SwiftUI + AppKit). `--open-popover` / `--open-settings` launch flags open the UI directly, handy for screenshots. PRs welcome — translations, Opus/Sonnet
per-model limits, notifications at thresholds, etc.

## License

MIT
