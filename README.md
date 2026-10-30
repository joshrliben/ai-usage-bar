# AIUsageBar

A macOS menu bar app that shows how much of your Claude and Codex (ChatGPT) plan limits you've used.

The menu bar shows one number per service, the higher of its 5-hour and weekly usage, plus how long until that limit resets:

```
C 33% 1h18m · X 100% 1h29m
```

Percentages turn orange at 70% and red at 90%. Click the item to open a panel that shows, for each service:

- 5-hour and weekly usage bars with reset countdowns
- a burn rate (% per hour, or % per day for weekly limits) and whether you're on pace to hit 100% before the limit resets

The app refreshes every 2 minutes and whenever you open the panel.

## Requirements

- macOS 14 or later, with Swift (Xcode or the Command Line Tools)
- [Claude Code](https://claude.com/claude-code), signed in. The app reads its token from the Keychain item `Claude Code-credentials`.
- [Codex](https://openai.com/codex), signed in with ChatGPT. The app reads its token from `~/.codex/auth.json`.

## Install

```bash
./install.sh
```

This builds `~/Applications/AIUsageBar.app`, adds a LaunchAgent so it starts at login, and launches it. Run it again after changing the code.

To print the current numbers without the UI:

```bash
~/Applications/AIUsageBar.app/Contents/MacOS/AIUsageBar --print
```

## Uninstall

```bash
pkill -x AIUsageBar
rm -rf ~/Applications/AIUsageBar.app ~/Library/LaunchAgents/com.local.aiusagebar.plist
```

## How it works

Both numbers come from undocumented endpoints, so they may change without notice:

| Service | Endpoint | Token |
|---|---|---|
| Claude | `GET https://api.anthropic.com/api/oauth/usage` (what Claude Code's `/usage` uses) | Keychain, `Claude Code-credentials` |
| Codex | `GET https://chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` |

The app only reads tokens. It never refreshes or writes them, so Claude Code and Codex stay in charge of their own sign-ins. If a token expires, the panel says so until you open that tool again.

Usage is per account, so the numbers include use from other computers, Codex cloud tasks and claude.ai.

The "last 30m" burn rate comes from readings the app keeps in memory, so it appears about 5 minutes after launch. Until then the panel shows the average since the window started.
