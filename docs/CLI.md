# VibeRouter CLI and TUI

VibeRouter ships one executable for the macOS menu-bar app, a scriptable command-line
interface, and an interactive terminal dashboard. The CLI reads the same auth directory
and preferences as the app, so account discovery and deduplication stay consistent.

## Install the command

After copying `VibeRouter.app` to `/Applications`, run:

```bash
/Applications/VibeRouter.app/Contents/MacOS/CLIProxyMenuBar cli install-cli
```

This creates `~/.local/bin/viberouter`. If that directory is not already in `PATH`, add
the line printed by the installer to `~/.zshrc` and start a new shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Choose another writable directory with `--prefix DIR`. The installer replaces an
existing symlink but refuses to overwrite a regular file.

Source builds can also run `make install-cli`. A full `make install` installs both the
app in `/Applications` and the command in `~/.local/bin`.

## Start here

```bash
viberouter                 # interactive TUI
viberouter status
viberouter accounts
viberouter usage
viberouter capabilities --json
```

The TUI supports `Tab` or `1`–`4` to change pages, `j`/`k` or arrow keys to move,
`r` to refresh, `s` to switch, `w` to wake a quota window, `e` to enable or disable,
`x` to consume a reset, and `q` to quit.

## Accounts, OAuth, and imports

```bash
viberouter accounts --json
viberouter account disable ACCOUNT_ID
viberouter account enable ACCOUNT_ID
viberouter account delete ACCOUNT_ID --yes

viberouter login codex        # interactive browser OAuth
viberouter login claude
viberouter login gemini
viberouter login kimi
viberouter login antigravity
viberouter login grok
viberouter login kiro

viberouter import list
viberouter import codex
viberouter import codex --source DISCOVERED_SOURCE_ID
```

`login` is interactive and intentionally rejects `--json`. `import list` discovers
supported signed-in local apps without copying credentials. Importing a provider copies
its local session into VibeRouter's auth store. If more than one source is available,
pass the exact source ID returned by `import list --json`.

Native account switching and manual reset redemption require confirmation. In scripts,
first resolve the exact account ID and then pass `--yes`:

```bash
viberouter switch ACCOUNT_ID --yes --json
viberouter wake ACCOUNT_ID --json
viberouter reset ACCOUNT_ID --yes --json
```

`wake` starts a provider session or rolling five-hour window. `reset` consumes a limited
manual reset credit; they are deliberately separate commands.

## Server and settings

```bash
viberouter server status
viberouter server start
viberouter server stop
viberouter server restart
viberouter server logs
viberouter server open

viberouter providers list
viberouter provider status
viberouter provider disable codex
viberouter settings list
viberouter settings set usage-refresh-minutes 5
viberouter doctor --json
```

Server mutations are delivered to the running menu-bar process. `server start` launches
the app when necessary. `doctor` always returns an inspectable result; check
`data.healthy` instead of relying on the process exit status for configuration health.

## JSON contract for scripts and agents

Pass `--json` anywhere in the command. Successful output is one object on stdout:

```json
{"ok":true,"data":{},"meta":{"contract_version":"1.0","timestamp":"..."}}
```

Failures are one object on stderr and use a non-zero exit status:

```json
{"ok":false,"error":{"code":"...","message":"...","hint":"..."},"meta":{"contract_version":"1.0","timestamp":"..."}}
```

Use exit status `2` for invalid input or missing confirmation and `4` for ambiguous or
missing account/import-source selectors. The machine-readable `capabilities` command is
the source of truth for contract version, available operations, and safety rules.

The `api METHOD PATH [--body JSON]` command is an authenticated escape hatch to the local
management API. Paths are relative to `/v0/management`; it is intended for advanced use.

## Shell completions

Add the matching line to your shell profile:

```bash
# zsh
source <(viberouter completion zsh)

# bash
source <(viberouter completion bash)

# fish
viberouter completion fish | source
```
