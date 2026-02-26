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
    GitHub Personal Access Token (read:packages / repo scope).
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

.PARAMETER TesterRoot
    Override the tester output folder.
    Default: %APPDATA%\MetaQuotes\Terminal\Common\Tester

.PARAMETER PortStart
    First agent port. Default: 3000

.PARAMETER AgentHost
    Host/IP for agent binding. Default: 127.0.0.1

.PARAMETER SkipStart
    Create agent folders but do not launch processes.

.PARAMETER KeepDownload
    Do not delete the downloaded zip after extraction.

.EXAMPLE
    .\Setup-MT5Agents.ps1 -GitHubToken ghp_xxx -GitHubOwner myorg

.EXAMPLE
    $env:MT5_GITHUB_TOKEN = "ghp_xxx"
    $env:MT5_GITHUB_OWNER = "myorg"
    .\Setup-MT5Agents.ps1

.NOTES
    Must be run as Administrator.
    Private repo: token needs at minimum the `repo` scope.
    Public repo:  token needs no special scope, but is still required for
                  high-rate API calls.
#>
[CmdletBinding()]
param(
    [string]$GitHubToken  = $env:MT5_GITHUB_TOKEN,
    [string]$GitHubOwner  = $env:MT5_GITHUB_OWNER,
    [string]$GitHubRepo   = ($env:MT5_GITHUB_REPO  ?? "mt5-agent-setup"),
    [string]$GitHubTag    = ($env:MT5_GITHUB_TAG   ?? "latest"),
    [string]$AssetName    = "mt5-tester-agent.zip",
    [string]$TesterRoot   = (Join-Path $env:APPDATA "MetaQuotes\Terminal\Common\Tester"),
    [int]   $PortStart    = 3000,
    [string]$AgentHost    = "127.0.0.1",
    [switch]$SkipStart,
    [switch]$KeepDownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║   MT5 Strategy Tester — Auto Agent Distributor v1.1.0 ║" -ForegroundColor Cyan
    Write-Host "  ║       github.com/$GitHubOwner/$GitHubRepo              " -ForegroundColor DarkCyan
    Write-Host "  ╚════════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Step { param([string]$m) Write-Host "`n▶ $m" -ForegroundColor Yellow }
function Write-OK   { param([string]$m) Write-Host "  ✔  $m" -ForegroundColor Green }
function Write-WARN { param([string]$m) Write-Host "  ⚠  $m" -ForegroundColor DarkYellow }
function Write-ERR  { param([string]$m) Write-Host "  ✖  $m" -ForegroundColor Red }
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
        Write-Host "  .\Setup-MT5Agents.ps1 -GitHubToken ghp_xxx -GitHubOwner myorg" -ForegroundColor White
        exit 1
    }
}

# ─── GitHub Release download ──────────────────────────────────────────────────

function Get-ReleaseAssetUrl {
    param([string]$Owner, [string]$Repo, [string]$Tag, [string]$Asset, [string]$Token)

    $apiBase = "https://api.github.com/repos/$Owner/$Repo"
    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $releaseUrl = if ($Tag -eq "latest") { "$apiBase/releases/latest" }
                  else                   { "$apiBase/releases/tags/$Tag" }

    Write-INFO "GitHub API: $releaseUrl"

    try {
        $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers -Method Get
    }
    catch {
        $statusCode = $_.Exception.Response?.StatusCode
        switch ($statusCode) {
            404 { throw "Release '$Tag' not found in $Owner/$Repo. Check tag name and repo access." }
            401 { throw "GitHub token invalid or expired." }
            403 { throw "GitHub token lacks repo read access." }
            default { throw "GitHub API error ($statusCode): $_" }
        }
    }

    Write-INFO "Release found: $($release.tag_name) — $($release.name)"
    Write-INFO "Assets: $(($release.assets | Select-Object -ExpandProperty name) -join ', ')"

    $assetObj = $release.assets | Where-Object { $_.name -eq $Asset } | Select-Object -First 1
    if (-not $assetObj) {
        throw "Asset '$Asset' not found in release '$($release.tag_name)'. Available: $(($release.assets.name) -join ', ')"
    }

    return @{
        Url  = $assetObj.browser_download_url
        Id   = $assetObj.id
        Size = $assetObj.size
    }
}

function Invoke-AssetDownload {
    param([string]$Owner, [string]$Repo, [int]$AssetId, [string]$Token, [string]$OutPath, [long]$Size)

    # For private repos, browser_download_url requires Accept: application/octet-stream + token
    $url     = "https://api.github.com/repos/$Owner/$Repo/releases/assets/$AssetId"
    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = "application/octet-stream"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $sizeMB = [Math]::Round($Size / 1MB, 1)
    Write-INFO "Downloading asset (${sizeMB} MB) → $OutPath"

    # Use HttpClient for streaming download with progress
    Add-Type -AssemblyName System.Net.Http

    $handler  = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $client   = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    foreach ($k in $headers.Keys) { $client.DefaultRequestHeaders.Add($k, $headers[$k]) }

    try {
        $response = $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null

        $stream   = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fileStream = [System.IO.File]::Create($OutPath)

        try {
            $buffer    = [byte[]]::new(81920)   # 80 KB chunks
            $downloaded = 0L
            $lastPct   = -1

            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $read)
                $downloaded += $read
                if ($Size -gt 0) {
                    $pct = [int]($downloaded * 100 / $Size)
                    if (($pct -ne $lastPct) -and (($pct % 10) -eq 0)) {
                        Write-Host "`r  ·  Progress: $pct% ($([Math]::Round($downloaded/1MB,1)) / $sizeMB MB)" -NoNewline
                        $lastPct = $pct
                    }
                }
            }
            Write-Host "`r  ·  Download complete: $([Math]::Round($downloaded/1MB,1)) MB      "
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

    $asset    = Get-ReleaseAssetUrl -Owner $Owner -Repo $Repo -Tag $Tag -Asset $Asset -Token $Token
    $tmpDir   = Join-Path $env:TEMP "mt5agents_$(Get-Random)"
    $zipPath  = Join-Path $tmpDir $Asset
    $null     = New-Item -ItemType Directory -Path $tmpDir -Force

    Invoke-AssetDownload -Owner $Owner -Repo $Repo -AssetId $asset.Id `
                         -Token $Token -OutPath $zipPath -Size $asset.Size

    # Verify zip is readable
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $entryCount = $zip.Entries.Count
        $zip.Dispose()
        Write-OK "Package verified — $entryCount file(s) in archive"
    }
    catch {
        throw "Downloaded file is not a valid ZIP. Possibly a failed/partial download."
    }

    # Extract
    $extractDir = Join-Path $tmpDir "extracted"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
    Write-OK "Extracted to: $extractDir"

    # Locate metatester64.exe (may be in root or subfolder)
    $testerExe = Get-ChildItem -Path $extractDir -Filter "metatester64.exe" -Recurse |
                 Select-Object -First 1

    if (-not $testerExe) {
        throw "metatester64.exe not found in package. Check the release asset contents."
    }
    Write-OK "Found: $($testerExe.FullName)"

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
        try   { $p | Stop-Process -Force; Write-OK "Killed PID $($p.Id) ($($p.Name))" }
        catch { Write-WARN "Could not kill PID $($p.Id): $_" }
    }

    Start-Sleep -Milliseconds 800

    $still = Get-Process -Name "metatester64", "metatester" -ErrorAction SilentlyContinue
    if ($still) { Write-WARN "$($still.Count) process(es) may still be running — they should exit shortly." }
    else        { Write-OK "All agents terminated." }
}

function Remove-AgentFolders {
    param([string]$TesterPath)

    Write-Step "Removing existing agent folders..."

    if (-not (Test-Path $TesterPath)) { Write-INFO "Tester folder doesn't exist yet — nothing to clean."; return }

    $folders = Get-ChildItem -Path $TesterPath -Directory -Filter "Agent-*" -ErrorAction SilentlyContinue
    if (-not $folders) { Write-OK "No agent folders found."; return }

    foreach ($f in $folders) {
        try   { Remove-Item -Path $f.FullName -Recurse -Force; Write-OK "Removed $($f.Name)" }
        catch { Write-ERR "Failed to remove $($f.Name): $_" }
    }
}

function New-AgentFolders {
    param(
        [string]$TesterPath,
        [string]$SourceExe,
        [string]$AgentHost,
        [int]   $PortStart,
        [int]   $Count
    )

    Write-Step "Creating $Count agent(s) (1 per logical CPU)..."

    $null = New-Item -ItemType Directory -Path $TesterPath -Force

    $created = 0
    for ($i = 0; $i -lt $Count; $i++) {
        $port     = $PortStart + $i
        $dir      = Join-Path $TesterPath "Agent-$AgentHost-$port"
        $destExe  = Join-Path $dir "metatester64.exe"
        $iniPath  = Join-Path $dir "metatester64.ini"

        try {
            $null = New-Item -ItemType Directory -Path $dir -Force
            Copy-Item -Path $SourceExe -Destination $destExe -Force

            @"
[Common]
Login=0
Server=

[Tester]
Agent=$AgentHost`:$port
"@ | Set-Content -Path $iniPath -Encoding UTF8

            Write-OK "Agent $($i+1)/$Count  →  $AgentHost`:$port  →  $dir"
            $created++
        }
        catch {
            Write-ERR "Failed to create agent on port ${port}: $_"
        }
    }

    Write-OK "$created / $Count agents created successfully."
    return $created
}

function Start-Agents {
    param([string]$TesterPath, [string]$AgentHost, [int]$PortStart, [int]$Count)

    Write-Step "Launching agents..."

    for ($i = 0; $i -lt $Count; $i++) {
        $port = $PortStart + $i
        $dir  = Join-Path $TesterPath "Agent-$AgentHost-$port"
        $exe  = Join-Path $dir "metatester64.exe"

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
    param([string]$TesterPath, [int]$PortStart, [int]$AgentCount)

    Write-Step "Configuring Windows Firewall..."

    $portEnd   = $PortStart + $AgentCount - 1
    $portRange = "$PortStart-$portEnd"

    # Remove stale rules
    @("MT5 Tester Agents Inbound", "MT5 Tester Agents Outbound") |
        ForEach-Object { Remove-NetFirewallRule -DisplayName $_ -ErrorAction SilentlyContinue }

    # Port range rules (covers all agents in one pair of rules)
    foreach ($dir in @("Inbound", "Outbound")) {
        New-NetFirewallRule `
            -DisplayName "MT5 Tester Agents $dir" `
            -Direction   $dir `
            -Action      Allow `
            -Protocol    TCP `
            -LocalPort   $portRange `
            -Profile     Any `
            -Description "MT5 tester agent TCP ports $portRange" | Out-Null
        Write-OK "FW $dir  TCP $portRange"
    }

    # Per-agent program rules (needed for local loopback in some Windows configs)
    $exePaths = Get-ChildItem -Path $TesterPath -Filter "metatester64.exe" -Recurse -ErrorAction SilentlyContinue
    foreach ($exe in $exePaths) {
        $label = "MT5 Agent — $($exe.Directory.Name)"
        Remove-NetFirewallRule -DisplayName $label -ErrorAction SilentlyContinue
        New-NetFirewallRule `
            -DisplayName $label `
            -Direction   Inbound `
            -Action      Allow `
            -Program     $exe.FullName `
            -Profile     Any | Out-Null
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
        try   { Add-MpPreference -ExclusionPath $p -Force; Write-OK "PATH    $p" }
        catch { Write-WARN "Path exclusion failed: $p — $_" }
    }

    foreach ($p in $procExcl) {
        try   { Add-MpPreference -ExclusionProcess $p -Force; Write-OK "PROCESS $p" }
        catch { Write-WARN "Process exclusion failed: $p — $_" }
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────────

function Show-Summary {
    param([string]$TesterPath, [int]$PortStart, [int]$Count)

    $running = (Get-Process -Name "metatester64" -ErrorAction SilentlyContinue).Count
    $portEnd = $PortStart + $Count - 1

    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │               SETUP COMPLETE                 │" -ForegroundColor Cyan
    Write-Host "  ├─────────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host "  │  Agents created : $($Count.ToString().PadRight(27))│" -ForegroundColor White
    Write-Host "  │  Agents running : $($running.ToString().PadRight(27))│" -ForegroundColor White
    Write-Host "  │  Port range     : $("$PortStart-$portEnd".PadRight(27))│" -ForegroundColor White
    Write-Host "  │  Tester path    : $(([IO.Path]::GetFileName($TesterPath)).PadRight(27))│" -ForegroundColor White
    Write-Host "  └─────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""
    if (-not $SkipStart) {
        Write-Host "  In MT5 Terminal: Tools → Options → Expert Advisors" -ForegroundColor DarkGray
        Write-Host "  Enable: 'Allow local agents'  and set Agent Ports: $PortStart-$portEnd" -ForegroundColor DarkGray
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

        # 3. Create
        $created = New-AgentFolders -TesterPath $TesterRoot `
                                    -SourceExe $pkg.TesterExe `
                                    -AgentHost $AgentHost `
                                    -PortStart $PortStart `
                                    -Count $maxAgents

        # 4. Security
        Add-FirewallRules      -TesterPath $TesterRoot -PortStart $PortStart -AgentCount $created
        Add-DefenderExclusions -TesterPath $TesterRoot

        # 5. Launch
        if (-not $SkipStart) {
            Start-Agents -TesterPath $TesterRoot -AgentHost $AgentHost -PortStart $PortStart -Count $created
        } else {
            Write-WARN "-SkipStart set — agents created but not launched."
        }

        Show-Summary -TesterPath $TesterRoot -PortStart $PortStart -Count $created
    }
    finally {
        # Cleanup temp files unless user asked to keep them
        if (-not $KeepDownload) {
            Write-Step "Cleaning up temp files..."
            Remove-Item -Path $pkg.TmpDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-OK "Temp folder removed."
        } else {
            Write-INFO "Zip kept at: $($pkg.ZipPath)"
        }
    }
}

Main
