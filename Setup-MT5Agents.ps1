#Requires -Version 7.0
<#
.SYNOPSIS
    MT5 Strategy Tester — Automated Agent Distributor
.DESCRIPTION
    Downloads the MT5 tester package from a private GitHub Release,
    terminates / removes all existing agents, then creates the maximum
    number of new agents (1 per logical CPU core).
    Adds Windows Firewall rules and Defender exclusions automatically.

.PARAMETER GitHubToken
    GitHub Personal Access Token (repo scope for private, any for public).
    Alternatively set env: MT5_GITHUB_TOKEN

.PARAMETER GitHubOwner
    GitHub username or org that owns the repo.
    Alternatively set env: MT5_GITHUB_OWNER

.PARAMETER GitHubRepo
    Repository name containing the release.
    Alternatively set env: MT5_GITHUB_REPO  (default: mt5-agent-setup)

.PARAMETER GitHubTag
    Release tag to download. Use "latest" (default) for the newest release.
    Alternatively set env: MT5_GITHUB_TAG

.PARAMETER AssetName
    Release asset filename to download. Default: mt5-tester-agent.zip

.PARAMETER AgentPassword
    Password written into each agent's metatester64.ini.
    Must match the password set in MT5 Terminal → Tools → Options → Expert Advisors → Password.
    Alternatively set env: MT5_AGENT_PASSWORD
    If omitted, agents run without a password (local-only setups only).

.PARAMETER TesterRoot
    Override the tester output folder.
    Default: %APPDATA%\MetaQuotes\Terminal\Common\Tester

.PARAMETER PortStart
    First agent port to try. Default: 3000
    If a port is already in use it is skipped and the next one is tried automatically.

.PARAMETER AgentHost
    Host/IP for agent binding. Default: 127.0.0.1

.PARAMETER SkipStart
    Create agent folders but do not launch processes.

.PARAMETER KeepDownload
    Do not delete the downloaded zip after extraction.

.EXAMPLE
    .\Setup-MT5Agents.ps1 -GitHubToken ghp_xxx -GitHubOwner myorg -AgentPassword "s3cr3t"

.EXAMPLE
    $env:MT5_GITHUB_TOKEN   = "ghp_xxx"
    $env:MT5_GITHUB_OWNER   = "myorg"
    $env:MT5_AGENT_PASSWORD = "s3cr3t"
    .\Setup-MT5Agents.ps1

.NOTES
    Must be run as Administrator.
    Private repo: token needs at minimum the `repo` scope.
    Public repo:  token needs no special scope, but is still required for
                  high-rate API calls.
#>
[CmdletBinding()]
param(
    [string]$GitHubToken = "",
    [string]$GitHubOwner = "",
    [string]$GitHubRepo = "",
    [string]$GitHubTag = "",
    [string]$AssetName = "mt5-tester-agent.zip",
    [string]$AgentPassword = "",
    [string]$TesterRoot = "",
    [int]   $PortStart = 3000,
    [string]$AgentHost = "127.0.0.1",
    [switch]$SkipStart,
    [switch]$KeepDownload
)

# Resolve env var fallbacks here — ?? is PS7+ only and iex inherits the caller's shell
if (-not $GitHubToken) { $GitHubToken = $env:MT5_GITHUB_TOKEN }
if (-not $GitHubOwner) { $GitHubOwner = $env:MT5_GITHUB_OWNER }
if (-not $GitHubRepo) { $GitHubRepo = if ($env:MT5_GITHUB_REPO) { $env:MT5_GITHUB_REPO }    else { "mt5-agent-setup" } }
if (-not $GitHubTag) { $GitHubTag = if ($env:MT5_GITHUB_TAG) { $env:MT5_GITHUB_TAG }     else { "latest" } }
if (-not $AgentPassword) { $AgentPassword = if ($env:MT5_AGENT_PASSWORD) { $env:MT5_AGENT_PASSWORD } else { "" } }
if (-not $TesterRoot) { $TesterRoot = Join-Path $env:APPDATA "MetaQuotes\Terminal\Common\Tester" }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║   MT5 Strategy Tester — Auto Agent Distributor v1.2.0 ║" -ForegroundColor Cyan
    Write-Host "  ║       github.com/$GitHubOwner/$GitHubRepo" -ForegroundColor DarkCyan
    Write-Host "  ╚════════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Step { param([string]$m) Write-Host "`n▶ $m" -ForegroundColor Yellow }
function Write-OK { param([string]$m) Write-Host "  ✔  $m" -ForegroundColor Green }
function Write-WARN { param([string]$m) Write-Host "  ⚠  $m" -ForegroundColor DarkYellow }
function Write-ERR { param([string]$m) Write-Host "  ✖  $m" -ForegroundColor Red }
function Write-INFO { param([string]$m) Write-Host "  ·  $m" -ForegroundColor Gray }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [Security.Principal.WindowsPrincipal]$id
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-ERR "Administrator privileges required. Re-launch with:"
        Write-Host "  Start-Process pwsh -Verb RunAs -ArgumentList '-File `"$PSCommandPath`"'" -ForegroundColor White
        exit 1
    }
}

function Assert-Params {
    $missing = @()
    if (-not $GitHubToken) { $missing += "GitHubToken  (or env MT5_GITHUB_TOKEN)" }
    if (-not $GitHubOwner) { $missing += "GitHubOwner  (or env MT5_GITHUB_OWNER)" }
    if ($missing) {
        Write-ERR "Missing required parameters:"
        $missing | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        Write-Host ""
        Write-Host "  Usage example:" -ForegroundColor Gray
        Write-Host "  .\Setup-MT5Agents.ps1 -GitHubToken ghp_xxx -GitHubOwner myorg -AgentPassword s3cr3t" -ForegroundColor White
        exit 1
    }
    if (-not $AgentPassword) {
        Write-WARN "No AgentPassword set — agents will run without authentication."
        Write-WARN "Pass -AgentPassword or set env MT5_AGENT_PASSWORD for secure setups."
    }
}

# ─── Port utilities ───────────────────────────────────────────────────────────

function Test-PortAvailable {
    param([int]$Port)
    $inUse = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
    Where-Object { ($_.State -eq "Listen") -or ($_.State -eq "Established") }
    return (-not $inUse)
}

function Get-NextFreePort {
    param([int]$StartAt, [int]$MaxSearch = 100)
    $candidate = $StartAt
    while ($candidate -lt ($StartAt + $MaxSearch)) {
        if (Test-PortAvailable -Port $candidate) { return $candidate }
        Write-WARN "Port $candidate in use — trying next"
        $candidate++
    }
    throw "No free port found in range $StartAt – $($StartAt + $MaxSearch - 1)"
}

# ─── GitHub Release download ──────────────────────────────────────────────────

function Get-ReleaseAsset {
    param([string]$Owner, [string]$Repo, [string]$Tag, [string]$Asset, [string]$Token)

    $apiBase = "https://api.github.com/repos/$Owner/$Repo"
    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $releaseUrl = if ($Tag -eq "latest") { "$apiBase/releases/latest" }
    else { "$apiBase/releases/tags/$Tag" }

    Write-INFO "GitHub API: $releaseUrl"

    try {
        $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers -Method Get
    }
    catch {
        $code = $_.Exception.Response?.StatusCode
        switch ($code) {
            404 { throw "Release '$Tag' not found in $Owner/$Repo. Check tag name and repo access." }
            401 { throw "GitHub token invalid or expired." }
            403 { throw "GitHub token lacks repo read access." }
            default { throw "GitHub API error ($code): $_" }
        }
    }

    Write-INFO "Release : $($release.tag_name) — $($release.name)"
    Write-INFO "Assets  : $(($release.assets.name) -join ', ')"

    $assetObj = $release.assets | Where-Object { $_.name -eq $Asset } | Select-Object -First 1
    if (-not $assetObj) {
        throw "Asset '$Asset' not found in release '$($release.tag_name)'. Available: $(($release.assets.name) -join ', ')"
    }

    return @{ Id = $assetObj.id; Size = $assetObj.size; Tag = $release.tag_name }
}

function Invoke-AssetDownload {
    param([string]$Owner, [string]$Repo, [int]$AssetId, [string]$Token, [string]$OutPath, [long]$Size)

    $url = "https://api.github.com/repos/$Owner/$Repo/releases/assets/$AssetId"
    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = "application/octet-stream"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $sizeMB = [Math]::Round($Size / 1MB, 1)
    Write-INFO "Downloading ${sizeMB} MB → $OutPath"

    Add-Type -AssemblyName System.Net.Http
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    foreach ($k in $headers.Keys) { $client.DefaultRequestHeaders.Add($k, $headers[$k]) }

    try {
        $response = $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null

        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fileStream = [System.IO.File]::Create($OutPath)

        try {
            $buffer = [byte[]]::new(81920)
            $downloaded = 0L
            $lastPct = -1

            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $read)
                $downloaded += $read
                if ($Size -gt 0) {
                    $pct = [int]($downloaded * 100 / $Size)
                    if (($pct -ne $lastPct) -and (($pct % 10) -eq 0)) {
                        Write-Host "`r  ·  Progress: $pct% ($([Math]::Round($downloaded/1MB,1)) / $sizeMB MB)   " -NoNewline
                        $lastPct = $pct
                    }
                }
            }
            Write-Host "`r  ·  Download complete: $([Math]::Round($downloaded/1MB,1)) MB                      "
        }
        finally {
            $fileStream.Dispose()
            $stream.Dispose()
        }
    }
    finally {
        $client.Dispose()
    }
}

function Get-MT5Package {
    param([string]$Token, [string]$Owner, [string]$Repo, [string]$Tag, [string]$Asset)

    Write-Step "Fetching MT5 tester package from GitHub Release..."

    $assetInfo = Get-ReleaseAsset -Owner $Owner -Repo $Repo -Tag $Tag -Asset $Asset -Token $Token
    $tmpDir = Join-Path $env:TEMP "mt5agents_$(Get-Random)"
    $zipPath = Join-Path $tmpDir $Asset
    $null = New-Item -ItemType Directory -Path $tmpDir -Force

    Invoke-AssetDownload -Owner $Owner -Repo $Repo -AssetId $assetInfo.Id `
        -Token $Token -OutPath $zipPath -Size $assetInfo.Size

    # Verify ZIP integrity
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $entryCount = $zip.Entries.Count
        $zip.Dispose()
        Write-OK "Package verified — $entryCount file(s)  (tag: $($assetInfo.Tag))"
    }
    catch {
        throw "Downloaded file is not a valid ZIP. Possibly a partial download — try again."
    }

    $extractDir = Join-Path $tmpDir "extracted"
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
    Write-OK "Extracted → $extractDir"

    $testerExe = Get-ChildItem -Path $extractDir -Filter "metatester64.exe" -Recurse |
    Select-Object -First 1
    if (-not $testerExe) {
        throw "metatester64.exe not found inside the package. Check the release asset contents."
    }
    Write-OK "Executable: $($testerExe.FullName)"

    return @{
        TmpDir     = $tmpDir
        ZipPath    = $zipPath
        ExtractDir = $extractDir
        TesterExe  = $testerExe.FullName
    }
}

# ─── Agent lifecycle ──────────────────────────────────────────────────────────

function Stop-AllAgents {
    Write-Step "Terminating existing tester agent processes..."

    $procs = Get-Process -Name "metatester64", "metatester" -ErrorAction SilentlyContinue
    if (-not $procs) { Write-OK "No running agents found."; return }

    foreach ($p in $procs) {
        try { $p | Stop-Process -Force; Write-OK "Killed PID $($p.Id) ($($p.Name))" }
        catch { Write-WARN "Could not kill PID $($p.Id): $_" }
    }

    Start-Sleep -Milliseconds 800

    $still = Get-Process -Name "metatester64", "metatester" -ErrorAction SilentlyContinue
    if ($still) { Write-WARN "$($still.Count) process(es) may still be running — they should exit shortly." }
    else { Write-OK "All agents terminated." }
}

function Remove-AgentFolders {
    param([string]$TesterPath)

    Write-Step "Removing existing agent folders..."

    if (-not (Test-Path $TesterPath)) { Write-INFO "Tester folder doesn't exist yet — nothing to clean."; return }

    $folders = Get-ChildItem -Path $TesterPath -Directory -Filter "Agent-*" -ErrorAction SilentlyContinue
    if (-not $folders) { Write-OK "No agent folders found."; return }

    foreach ($f in $folders) {
        try { Remove-Item -Path $f.FullName -Recurse -Force; Write-OK "Removed $($f.Name)" }
        catch { Write-ERR "Failed to remove $($f.Name): $_" }
    }
}

function New-AgentFolders {
    param(
        [string] $TesterPath,
        [string] $SourceExe,
        [string] $AgentHost,
        [int]    $PortStart,
        [int]    $Count,
        [string] $Password
    )

    Write-Step "Creating $Count agent(s) (1 per logical CPU)..."
    $null = New-Item -ItemType Directory -Path $TesterPath -Force

    $assignedPorts = [System.Collections.Generic.List[int]]::new()
    $nextPort = $PortStart

    for ($i = 0; $i -lt $Count; $i++) {
        # Find the next available port — skips any already bound
        try { $port = Get-NextFreePort -StartAt $nextPort }
        catch { Write-ERR "Agent $($i + 1): $_"; continue }

        $nextPort = $port + 1   # advance search cursor past current assignment

        $dir = Join-Path $TesterPath "Agent-$AgentHost-$port"
        $destExe = Join-Path $dir "metatester64.exe"
        $iniPath = Join-Path $dir "metatester64.ini"

        try {
            $null = New-Item -ItemType Directory -Path $dir -Force
            Copy-Item -Path $SourceExe -Destination $destExe -Force

            # Write ini — Password line only added when provided
            $iniLines = @(
                "[Common]",
                "Login=0",
                "Server=",
                "",
                "[Tester]",
                "Agent=$AgentHost`:$port"
            )
            if ($Password) { $iniLines += "Password=$Password" }
            $iniLines | Set-Content -Path $iniPath -Encoding UTF8

            $pwdStatus = if ($Password) { "pwd ✔" } else { "no pwd" }
            Write-OK "Agent $($i+1)/$Count  →  $AgentHost`:$port  [$pwdStatus]"
            $assignedPorts.Add($port)
        }
        catch {
            Write-ERR "Failed to create agent on port ${port}: $_"
        }
    }

    Write-OK "$($assignedPorts.Count) / $Count agents created successfully."

    # Return as array — the comma prevents PS from unwrapping a single-element collection
    return , $assignedPorts.ToArray()
}

function Start-Agents {
    param([string]$TesterPath, [string]$AgentHost, [int[]]$Ports)

    Write-Step "Launching agents..."

    foreach ($port in $Ports) {
        $dir = Join-Path $TesterPath "Agent-$AgentHost-$port"
        $exe = Join-Path $dir "metatester64.exe"

        if (-not (Test-Path $exe)) { Write-WARN "Skipping port $port — exe missing."; continue }

        try {
            Start-Process -FilePath $exe `
                -ArgumentList "/agent:$AgentHost`:$port" `
                -WorkingDirectory $dir `
                -WindowStyle Minimized
            Write-OK "Started  $AgentHost`:$port"
        }
        catch {
            Write-ERR "Could not start agent on port ${port}: $_"
        }
    }
}

# ─── Security ─────────────────────────────────────────────────────────────────

function Add-FirewallRules {
    param([string]$TesterPath, [int[]]$Ports)

    Write-Step "Configuring Windows Firewall..."

    # Remove stale rules
    @("MT5 Tester Agents Inbound", "MT5 Tester Agents Outbound") |
    ForEach-Object { Remove-NetFirewallRule -DisplayName $_ -ErrorAction SilentlyContinue }

    # Use the exact list of assigned ports — handles gaps from skipped ports correctly
    $portList = $Ports -join ","

    foreach ($dir in @("Inbound", "Outbound")) {
        New-NetFirewallRule `
            -DisplayName "MT5 Tester Agents $dir" `
            -Direction $dir `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $portList `
            -Profile Any `
            -Description "MT5 tester agent TCP ports: $portList" | Out-Null
        Write-OK "FW $dir  TCP $portList"
    }

    # Per-agent program rules (needed for loopback on some Windows configs)
    $exePaths = Get-ChildItem -Path $TesterPath -Filter "metatester64.exe" -Recurse -ErrorAction SilentlyContinue
    foreach ($exe in $exePaths) {
        $label = "MT5 Agent — $($exe.Directory.Name)"
        Remove-NetFirewallRule -DisplayName $label -ErrorAction SilentlyContinue
        New-NetFirewallRule `
            -DisplayName $label `
            -Direction Inbound `
            -Action Allow `
            -Program $exe.FullName `
            -Profile Any | Out-Null
    }
    Write-OK "$($exePaths.Count) per-process inbound rules added"
}

function Add-DefenderExclusions {
    param([string]$TesterPath)

    Write-Step "Adding Windows Defender exclusions..."

    $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if (-not $mpStatus) {
        Write-WARN "Defender not active — skipping. Add exclusions manually in your AV."
        return
    }

    $pathExcl = @(
        $TesterPath,
        (Join-Path $env:APPDATA "MetaQuotes")
    )
    $procExcl = Get-ChildItem -Path $TesterPath -Filter "metatester64.exe" -Recurse `
        -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName

    foreach ($p in $pathExcl) {
        try { Add-MpPreference -ExclusionPath $p -Force; Write-OK "PATH    $p" }
        catch { Write-WARN "Path exclusion failed: $p — $_" }
    }
    foreach ($p in $procExcl) {
        try { Add-MpPreference -ExclusionProcess $p -Force; Write-OK "PROCESS $p" }
        catch { Write-WARN "Process exclusion failed: $p — $_" }
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────────

function Show-Summary {
    param([string]$TesterPath, [int[]]$Ports, [string]$Password)

    $running = (Get-Process -Name "metatester64" -ErrorAction SilentlyContinue).Count
    $portRange = "$($Ports[0])-$($Ports[-1])"
    $pwdLine = if ($Password) { "set (sync with Terminal options)" } else { "NONE — local use only" }
    $pwdColor = if ($Password) { "White" } else { "DarkYellow" }

    Write-Host ""
    Write-Host "  ┌───────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │                    SETUP COMPLETE                      │" -ForegroundColor Cyan
    Write-Host "  ├───────────────────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host "  │  Agents created  : $($Ports.Count.ToString().PadRight(34))│" -ForegroundColor White
    Write-Host "  │  Agents running  : $($running.ToString().PadRight(34))│" -ForegroundColor White
    Write-Host "  │  Ports assigned  : $($portRange.PadRight(34))│" -ForegroundColor White
    Write-Host "  │  Agent password  : $($pwdLine.PadRight(34))│" -ForegroundColor $pwdColor
    Write-Host "  └───────────────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  MT5 Terminal → Tools → Options → Expert Advisors:" -ForegroundColor DarkGray
    Write-Host "    ✦ Allow local agents" -ForegroundColor DarkGray
    Write-Host "    ✦ Port range : $portRange" -ForegroundColor DarkGray
    if ($Password) {
        Write-Host "    ✦ Password   : <same value as MT5_AGENT_PASSWORD>" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

function Main {
    Write-Banner
    Assert-Admin
    Assert-Params

    $maxAgents = [Environment]::ProcessorCount
    Write-INFO "Logical CPUs: $maxAgents  →  target agent count: $maxAgents"

    # 1. Download package from GitHub
    $pkg = Get-MT5Package -Token $GitHubToken -Owner $GitHubOwner `
        -Repo $GitHubRepo -Tag $GitHubTag -Asset $AssetName

    try {
        # 2. Stop + clean
        Stop-AllAgents
        Remove-AgentFolders -TesterPath $TesterRoot

        # 3. Create — returns exact array of ports that were actually assigned
        [int[]]$assignedPorts = New-AgentFolders `
            -TesterPath $TesterRoot `
            -SourceExe $pkg.TesterExe `
            -AgentHost $AgentHost `
            -PortStart $PortStart `
            -Count $maxAgents `
            -Password $AgentPassword

        if ($assignedPorts.Count -eq 0) {
            throw "No agents were created — check port availability and disk space."
        }

        # 4. Security — receives the real port list, not an assumed sequential range
        Add-FirewallRules -TesterPath $TesterRoot -Ports $assignedPorts
        Add-DefenderExclusions -TesterPath $TesterRoot

        # 5. Launch
        if (-not $SkipStart) {
            Start-Agents -TesterPath $TesterRoot -AgentHost $AgentHost -Ports $assignedPorts
        }
        else {
            Write-WARN "-SkipStart set — agents created but not launched."
        }

        Show-Summary -TesterPath $TesterRoot -Ports $assignedPorts -Password $AgentPassword
    }
    finally {
        if (-not $KeepDownload) {
            Write-Step "Cleaning up temp files..."
            Remove-Item -Path $pkg.TmpDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-OK "Temp folder removed."
        }
        else {
            Write-INFO "Zip kept at: $($pkg.ZipPath)"
        }
    }
}

Main
