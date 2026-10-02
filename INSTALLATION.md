# Installing VibeRouter

**Requirements:** macOS 13+ · Apple Silicon *or* Intel builds on Releases.

## Option 1: Download Pre-built (Recommended)

1. Open **[Geekyshubham/VibeRouter Releases](https://github.com/Geekyshubham/VibeRouter/releases)**
2. Download for your Mac:
   - Apple Silicon: `VibeRouter-arm64.dmg` or `VibeRouter-arm64.zip`
   - Intel: `VibeRouter-x86_64.dmg` or `VibeRouter-x86_64.zip`
3. Optional: `shasum -a 256 -c VibeRouter-arm64.zip.sha256`

### Install

**ZIP:** extract → drag `VibeRouter.app` to `/Applications` → launch

**DMG:** open → drag to Applications → eject → launch

### Gatekeeper

Releases are **ad-hoc signed**:

```bash
xattr -cr /Applications/VibeRouter.app
# or
xattr -cr "/Applications/VibeRouter.app"
```

Or **Right-click → Open → Open**.

---

## Option 2: Build from Source

- macOS 13.0+ · Swift 5.9+ · Xcode Command Line Tools · Git

```bash
git clone https://github.com/Geekyshubham/VibeRouter.git
cd VibeRouter
make app
# or
make install
```

Multi-arch packages:

```bash
APP_VERSION=1.1.0 ./scripts/build-release-artifacts.sh
```

---

## After install

1. Menu bar icon → **Settings**
2. Connect providers (Claude Code, Codex, Gemini, Kiro, Copilot, …)
3. Use **usage limits**, **analytics**, and **status** in the popover

### Optional CLI and terminal dashboard

```bash
/Applications/VibeRouter.app/Contents/MacOS/CLIProxyMenuBar cli install-cli
export PATH="$HOME/.local/bin:$PATH"  # add once to ~/.zshrc if needed
viberouter doctor
```

Source completions from your shell profile:

```bash
# zsh
source <(viberouter completion zsh)

# bash: source <(viberouter completion bash)
# fish: viberouter completion fish | source
```

Source builds can use `make install-cli`. Override the destination with
`CLI_INSTALL_DIR=/some/bin make install-cli`. See [docs/CLI.md](docs/CLI.md) for the
full command and JSON automation contract.

---

## Support

- Issues: [github.com/Geekyshubham/VibeRouter/issues](https://github.com/Geekyshubham/VibeRouter/issues)
- Releases: [github.com/Geekyshubham/VibeRouter/releases](https://github.com/Geekyshubham/VibeRouter/releases)

© 2026 Geekyshubham · VibeRouter · MIT
