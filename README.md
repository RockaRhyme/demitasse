# Demitasse ☕

A tiny macOS menu bar app that does two things:

1. **Keeps your Mac awake** for a set time: 1 hour, 4 hours, 8 hours, 16 hours, 1 day, 1 week, or until you turn it off.
2. **Shows how much of your AI subscription limits you've used**, for the coding CLIs signed in on your Mac: Claude Code, Codex and Antigravity.

It is about 700 lines of Swift in two files, with no third-party packages.

```
Caffeinate: On until 3:45 PM
Keep awake  1h  4h  8h  16h  1d  1w  ∞  Off
────────────────────────────────────────────────
Claude Max · you@example.com
5h             ██░░░░░░░░  16%  resets in 1h 47m
Wk             ██░░░░░░░░  21%  resets Sat 12:00 AM
ChatGPT Pro · you@example.com
Wk             ░░░░░░░░░░   0%  resets Sat 2:24 PM
2 banked resets · next expires Oct 22 — Use One…
Google AI Pro · you@example.com
Gemini 5h      ░░░░░░░░░░   0%  resets in 3h 16m
Gemini Wk      ░░░░░░░░░░   0%  resets Sun 10:19 AM
────────────────────────────────────────────────
Launch at Login
Quit
```

## Install

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/RockaRhyme/demitasse.git
cd demitasse
./build.sh
```

`build.sh` compiles the app, signs it ad hoc, installs it to `~/Applications/Demitasse.app` and launches it. On first launch it registers itself to launch at login; turn that off with the **Launch at Login** menu item.

## What it does

### Keep awake

Click a duration in the **Keep awake** row. The cup icon fills while the Mac is being kept awake, and the top line shows when the session ends. **∞** keeps it awake until you click **Off** or quit.

### AI usage

Each time you open the menu, Demitasse shows the usage windows for every account it finds, with the time each one resets. Results are reused for a minute, because the usage endpoints rate-limit.

| Account | Where the sign-in is read from |
| --- | --- |
| Claude (Pro / Max / Team) | The `Claude Code-credentials*` keychain entries written by Claude Code |
| ChatGPT (Plus / Pro) | `~/.codex/auth.json`, written by the Codex CLI |
| Google AI (Antigravity) | `~/.gemini/jetski-standalone-oauth-token`, written by the Antigravity CLI (`agy`) |

An account only appears if its CLI is installed and signed in. For ChatGPT, banked limit resets are listed, and **Use One…** spends one after a confirmation.

### Google / Antigravity setup

Reading Google usage needs Antigravity's OAuth client ID and secret. They belong to Google, so they are not included in this repo. To turn the Google section on, create `~/.config/demitasse/google-oauth.json`:

```json
[
  { "client_id": "….apps.googleusercontent.com", "client_secret": "GOCSPX-…" }
]
```

The values are embedded in your own copy of the `agy` binary. You can list more than one client; they are tried in order. Without this file the Google row shows "needs Google client config".

## Things to know before you run it

- **Unofficial.** Demitasse is not affiliated with or endorsed by Apple, Anthropic, OpenAI or Google.
- **Undocumented endpoints.** The usage numbers come from the same private endpoints the CLIs themselves call. They can change or stop working without notice.
- **It reads your CLI sign-ins, and sometimes rewrites them.** A live token is used as is. An expired Claude or ChatGPT token is renewed, and because those refresh tokens rotate, the new tokens are written back to the keychain entry or `auth.json` in the CLI's own format so the CLI stays signed in. Tokens are sent only to the vendor that issued them.
- **Not sandboxed**, which is why it isn't on the Mac App Store.

## Command-line flags

Run `~/Applications/Demitasse.app/Contents/MacOS/Demitasse` with:

| Flag | Effect |
| --- | --- |
| `--usage` | Print the usage rows and exit |
| `--usage --debug` | Also print the raw HTTP responses |
| `--usage --renew` | Treat the Claude and ChatGPT tokens as expired, to exercise renewal |
| `--login-status` | Print whether launch at login is enabled |

## Credits

Demitasse has no third-party code dependencies, but it stands entirely on other people's work:

- **Apple** — [`caffeinate`](https://ss64.com/mac/caffeinate.html) does the actual keeping-awake; Demitasse only starts and stops it. `security` reads and writes the keychain. AppKit, ServiceManagement (launch at login) and the SF Symbols `cup.and.saucer` icons provide the rest.
- **Anthropic** — [Claude Code](https://claude.com/claude-code), whose sign-in and usage endpoints provide the Claude numbers. Most of this app was also written with Claude Code.
- **OpenAI** — the [Codex CLI](https://github.com/openai/codex), whose sign-in and usage endpoints provide the ChatGPT numbers and banked resets.
- **Google** — the Antigravity CLI, whose sign-in and quota endpoints provide the Google AI numbers.

If you want something more complete, these projects do the usage half far more thoroughly, across many more providers: [CodexBar](https://codexbar.app/) and [ClaudeBar](https://github.com/tddworks/ClaudeBar). For keeping a Mac awake, [Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704) and [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) are the standards.

## License

[MIT](LICENSE)
