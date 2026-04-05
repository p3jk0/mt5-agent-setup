# MT5 Agent Setup

Automated MT5 Strategy Tester agent distributor — downloads a packaged
`metatester64.exe` from a **private GitHub Release**, kills all existing
agents, and rebuilds the maximum number of new ones (1 per logical CPU).

---

## Repository layout

```
mt5-agent-setup/
├── dist/
│   └── metatester64.exe        ← commit your binary here
├── .github/workflows/
│   ├── build-release.yml       ← packages + publishes GitHub Release
│   └── validate.yml            ← PS7 syntax check on every push
├── Setup-MT5Agents.ps1         ← main setup (run as Admin)
├── Get-AgentStatus.ps1         ← diagnostics helper
├── run.bat                     ← auto-elevate launcher
└── README.md
```

---

## Quick start (client machine)

### Option A — one-liner (token in env)

```powershell
$env:MT5_GITHUB_TOKEN = "ghp_your_pat_here"
$env:MT5_GITHUB_OWNER = "p3jk0"

irm https://raw.githubusercontent.com/p3jk0/mt5-agent-setup/main/Setup-MT5Agents.ps1 | iex
```

### Option B — clone and run

```powershell
git clone https://github.com/YOUR_USERNAME/mt5-agent-setup.git
cd mt5-agent-setup

.\Setup-MT5Agents.ps1 -GitHubToken "ghp_xxx" -GitHubOwner "your-org"
```

### Option C — double-click

`run.bat` — auto-elevates and calls pwsh (reads token from env).

> **Requires:** Windows 10/11 · PowerShell 7+ · Administrator privileges

---

## Parameters

| Parameter        | Default                                            | Description                                         |
|------------------|----------------------------------------------------|-----------------------------------------------------|
| `-GitHubToken`   | `$env:MT5_GITHUB_TOKEN`                            | PAT with `repo` scope (private) or no scope (public) |
| `-GitHubOwner`   | `$env:MT5_GITHUB_OWNER`                            | GitHub user or org                                  |
| `-GitHubRepo`    | `mt5-agent-setup` / `$env:MT5_GITHUB_REPO`        | Repository name                                     |
| `-GitHubTag`     | `latest` / `$env:MT5_GITHUB_TAG`                  | Release tag or `"latest"`                           |
| `-AssetName`     | `mt5-tester-agent.zip`                             | Release asset filename                              |
| `-TesterRoot`    | `%APPDATA%\MetaQuotes\Terminal\Common\Tester`      | Agent output folder                                 |
| `-PortStart`     | `3000`                                             | First agent TCP port                                |
| `-AgentHost`     | `127.0.0.1`                                        | Bind address                                        |
| `-SkipStart`     | `false`                                            | Create but don't launch                             |
| `-KeepDownload`  | `false`                                            | Keep downloaded zip                                 |

Default password for mt5 agent
[string]$AgentPassword = "mt5Agent"

---

## Publishing a new release

### Automated (recommended)

1. Copy an updated `metatester64.exe` into `dist/`
2. Commit and push:

```bash
# Rolling pre-release (latest-build tag, updated automatically):
git add dist/metatester64.exe
git commit -m "chore: update metatester64.exe"
git push

# Versioned stable release:
git tag v1.2.0
git push --tags
```

3. The `Build & Publish` workflow runs automatically, creates the ZIP, and
   uploads it as a release asset with SHA-256 checksum embedded.

### Manual trigger

Go to **Actions → Build & Publish MT5 Tester Package → Run workflow**
Optionally supply a custom tag and toggle pre-release.

---

## What the setup script does

| Step | Action |
|------|--------|
| 1 | Validate admin + required params |
| 2 | Call GitHub Releases API to get asset download URL |
| 3 | Stream-download with progress bar, verify ZIP integrity |
| 4 | `Stop-Process -Force` on all `metatester64.exe` instances |
| 5 | Delete all `Agent-*` folders in tester root |
| 6 | Create `N` agent folders (`N` = `[Environment]::ProcessorCount`) |
| 7 | Write `metatester64.ini` per agent with correct `Agent=host:port` |
| 8 | Add inbound+outbound TCP firewall rules for port range |
| 9 | Add per-exe Firewall program rules |
| 10 | Add Defender path + process exclusions |
| 11 | Launch agents with `/agent:host:port` (unless `-SkipStart`) |
| 12 | Clean up temp download folder |

---

## GitHub PAT scopes

| Repo type | Required scope |
|-----------|---------------|
| Private   | `repo` (classic) or `contents:read` (fine-grained) |
| Public    | No scope required, but token still needed for rate limits |

Store it as a GitHub Actions secret named `MT5_RELEASE_TOKEN` if you want
to chain setup from a CI pipeline, or in Windows Credential Manager locally.

---

## Tips

- **After MT5 update**: push the new `metatester64.exe` → workflow auto-publishes → re-run setup on agent machines.
- **Farm nodes**: use `-SkipStart` so the master terminal discovers them on the next scan.
- **Multiple MT5 instances**: use `-PortStart 3100` on the second instance to avoid port collisions.
- **Pinning a version**: pass `-GitHubTag v1.1.0` to prevent accidental upgrades.

---

## License

MIT
