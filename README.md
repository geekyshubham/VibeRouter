# VibeRouter

<p align="center">
  <img src="icon.png" width="128" height="128" alt="VibeRouter">
</p>

<p align="center">
  <strong>macOS menu bar app</strong> for AI coding tools — live <em>usage limits</em>, quotas, analytics, multi-account switch, and a local proxy.
</p>

<p align="center">
<a href="https://github.com/Geekyshubham/VibeRouter/releases"><img alt="Download VibeRouter" src="https://img.shields.io/github/v/release/Geekyshubham/VibeRouter?label=Download&color=6c5ce7"></a>
<a href="https://github.com/Geekyshubham/VibeRouter/blob/main/LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/License-MIT-28a745"></a>
<a href="https://github.com/Geekyshubham/VibeRouter/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/Geekyshubham/VibeRouter?style=social"></a>
<a href="https://github.com/Geekyshubham/VibeRouter/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/Geekyshubham/VibeRouter/total?label=downloads"></a>
</p>

**VibeRouter** by **Geekyshubham** — use Claude Code, ChatGPT/Codex, Gemini, Antigravity, Kiro, Grok, Z.AI, OpenCode, and more with local tools. **No separate API keys** for OAuth providers. GitHub Copilot is tracked for usage only — the bundled proxy cannot route requests to it.

> Live usage limits · reset countdowns · token/credit analytics · account import & switch · session keep-alive · provider status

---

## Features

| Area | What you get |
|------|----------------|
| **Usage limits** | Live per-account cards, streaming updates, reset countdowns |
| **Codex / ChatGPT** | Plan limits, multi-subscription ranking |
| **Claude Code** | Local proxy + log analytics (tokens, models, est. $) |
| **Gemini / Antigravity** | Quota groups (Gemini vs Claude/Opus) |
| **Kiro** | Serves `kiro/*` models to Claude Code, plus `kiro-cli /usage` credits and local session metering (Kiro reports credits, never token counts) |
| **OpenCode Go** | 5-hour, weekly, and monthly subscription limits with reset countdowns |
| **Analytics** | Volume + estimated API-equivalent $ by provider/model |
| **Accounts** | Import configured apps; one-click native account switch |
| **Sessions** | Proactive token refresh · auto “wake 5h window” |
| **Status** | Provider status pages + incidents |
| **Menu bar** | Overview · Status · Analytics · optional peak-quota badge |
| **CLI + TUI** | Stable JSON automation contract, terminal dashboard, account actions, server control, and shell completions |

Also: one-click server start/stop, multi-account round-robin, provider enable/disable, Vercel AI Gateway option, self-contained `.app` bundle.

---

## Download

| Architecture | DMG | ZIP |
|--------------|-----|-----|
| **Apple Silicon** (M1–M4) | [arm64.dmg](https://github.com/Geekyshubham/VibeRouter/releases/latest) | [arm64.zip](https://github.com/Geekyshubham/VibeRouter/releases/latest) |
| **Intel** (x86_64) | [x86_64.dmg](https://github.com/Geekyshubham/VibeRouter/releases/latest) | [x86_64.zip](https://github.com/Geekyshubham/VibeRouter/releases/latest) |

**Releases:** [github.com/Geekyshubham/VibeRouter/releases](https://github.com/Geekyshubham/VibeRouter/releases)

Ad-hoc signed. First open: **Right-click → Open**, or `xattr -cr /Applications/VibeRouter.app`.

---

## Requirements

- macOS 13.0 (Ventura) or later
- Build from source: Xcode CLT / Swift 5.9+

## Installation

### Pre-built

1. Open **[Releases](https://github.com/Geekyshubham/VibeRouter/releases)**
2. Download arm64 or x86_64 DMG/ZIP
3. Drag `VibeRouter.app` to **Applications** → launch

### From source

```bash
git clone https://github.com/Geekyshubham/VibeRouter.git
cd VibeRouter
make app
make run
# or
make install
```

Multi-arch packages:

```bash
APP_VERSION=1.1.0 ./scripts/build-release-artifacts.sh
```

See [INSTALLATION.md](INSTALLATION.md).

## Usage

1. Launch — menu bar icon appears
2. Click for **Overview / Status / Analytics**
3. **Settings** → connect providers, import accounts, start proxy
4. Point coding tools (Factory, Amp, etc.) at the local proxy

Guides: [Factory CLI](FACTORY_SETUP.md) · [Amp CLI](AMPCODE_SETUP.md)

### Claude Code auto mode

`claude-viberouter --permission-mode auto` defaults to Claude Code's local safety
classifier because translated routes such as Kiro and GPT cannot return Anthropic's
server-side safety verdicts. Auto mode remains active without the gateway billing
notice; local classifier requests still use the provider's tokens or credits.

For a compatible native Claude upstream, opt into server review with
`CLAUDE_CODE_AUTO_MODE_SERVER=1 claude-viberouter --permission-mode auto`.
VibeRouter forwards Claude's safeguards and results; no-charge checks depend on
the upstream's rollout and credential eligibility. See Anthropic's
[classifier billing guide](https://code.claude.com/docs/en/auto-mode-classifier-billing).
Restart Claude Code after updating the launcher; an existing session retains its
classifier fallback.

### Command line

Install the optional shell command from an installed app:

```bash
/Applications/VibeRouter.app/Contents/MacOS/CLIProxyMenuBar cli install-cli
export PATH="$HOME/.local/bin:$PATH"
viberouter status
```

Running `viberouter` with no arguments opens the terminal dashboard. Automation should
use `--json`; start with `viberouter capabilities --json` for the versioned command
contract. See the [CLI and TUI guide](docs/CLI.md) for account switching, OAuth/import,
server control, exit behavior, and completions.

---

## License

**MIT** · © 2026 Geekyshubham / VibeRouter — see [LICENSE](LICENSE).

Not affiliated with OpenAI, Anthropic, Google, xAI, GitHub, or other AI providers.
Proxying subscriptions may violate provider ToS — use at your own risk.

## Support

- **Issues:** [Geekyshubham/VibeRouter/issues](https://github.com/Geekyshubham/VibeRouter/issues)
- **Releases:** [Geekyshubham/VibeRouter/releases](https://github.com/Geekyshubham/VibeRouter/releases)

---

© 2026 Geekyshubham · **VibeRouter**
