#Requires -Version 7.0
<#
.SYNOPSIS
    MT5 Strategy Tester — Automated Agent Distributor v2.0
.DESCRIPTION
    Downloads metatester64.exe from a private GitHub Release,
    stops/removes all existing agents, then creates and launches
    N agents (default: 1 per logical CPU) using metatester64's
    own /agent and /password command-line interface.
    Adds Windows Firewall rules and Defender exclusions automatically.

.PARAMETER GitHubToken
    GitHub PAT (repo scope for private repos).
    Alternatively: env MT5_GITHUB_TOKEN

.PARAMETER GitHubOwner
    GitHub username or org.
    Alternatively: env MT5_GITHUB_OWNER

.PARAMETER GitHubRepo
    Repo containing the release. Default: mt5-agent-setup
    Alternatively: env MT5_GITHUB_REPO

.PARAMETER GitHubTag
    Release tag. Use "latest" (default) for newest release.
    Alternatively: env MT5_GITHUB_TAG

.PARAMETER AssetName
    Release asset filename. Default: mt5-tester-agent.zip

.PARAMETER MaxAgents
    Number of agents to create. Default: logical CPU count.

.PARAMETER AgentPassword
    Password written into each agent's ini AND passed via /password flag.
    Must match Terminal → Tools → Options → Expert Advisors → Password.
    Alternatively: env MT5_AGENT_PASSWORD

.PARAMETER TesterRoot
    Override tester output folder.
    Default: %APPDATA%\MetaQuotes\Terminal\Common\Tester

.PARAMETER PortStart
    First port to try. Default: 3000

.PARAMETER AgentHost
    Host/IP for agent binding. Default: 127.0.0.1

.PARAMETER PortCheckTimeout
    Milliseconds to wait for an agent to bind its port after launch. Default: 3000

.PARAMETER SkipStart
    Create agent folders but do not launch processes.

.PARAMETER KeepDownload
    Do not delete the downloaded zip after extraction.

.EXAMPLE
    .\Setup-MT5Agents.ps1 -GitHubToken ghp_xxx -GitHubOwner myorg -AgentPassword "s3cr3t"
#>
[CmdletBinding()]
param(
    [string]$GitHubToken = "",
    [string]$GitHubOwner = "",
    [string]$GitHubRepo = "",
    [string]$GitHubTag = "",
    [string]$AssetName = "mt5-tester-agent.zip",
    [int]   $MaxAgents = [Environment]::ProcessorCount,
    [string]$AgentPassword = "",
    [string]$TesterRoot = "",
    [int]   $PortStart = 3000,
    [string]$AgentHost = "127.0.0.1",
    [int]   $PortCheckTimeout = 3000,
    [switch]$SkipStart,
    [switch]$KeepDownload
)

# Env-var fallbacks — ?? requires PS7+ which #Requires guarantees
$GitHubToken = $GitHubToken   ? $GitHubToken   : $env:MT5_GITHUB_TOKEN
$GitHubOwner = $GitHubOwner   ? $GitHubOwner   : $env:MT5_GITHUB_OWNER
$GitHubRepo = $GitHubRepo    ? $GitHubRepo    : ($env:MT5_GITHUB_REPO ?? "mt5-agent-setup")
$GitHubTag = $GitHubTag     ? $GitHubTag     : ($env:MT5_GITHUB_TAG ?? "latest")
$AgentPassword = $AgentPassword ? $AgentPassword : ($env:MT5_AGENT_PASSWORD ?? "")
$TesterRoot = $TesterRoot    ? $TesterRoot    : (Join-Path $env:APPDATA "MetaQuotes\Terminal\Common\Tester")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║   MT5 Strategy Tester — Auto Agent Distributor v2.0.0 ║" -ForegroundColor Cyan
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
    $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    return (-not ($props.GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port }))
}

function Get-NextFreePort {
    param([int]$StartAt, [int]$MaxSearch = 200)
    $candidate = $StartAt
    $limit = $StartAt + $MaxSearch
    while ($candidate -lt $limit) {
        if (Test-PortAvailable -Port $candidate) { return $candidate }
        Write-WARN "Port $candidate in use — skipping"
        $candidate++
    }
    throw "No free port found in range $StartAt – $($limit - 1)"
}

# Wait up to $TimeoutMs for a port to become LISTENING (agent startup verification)
function Wait-PortListening {
    param([int]$Port, [int]$TimeoutMs = 3000)
    $deadline = [datetime]::Now.AddMilliseconds($TimeoutMs)
    $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    while ([datetime]::Now -lt $deadline) {
        if ($props.GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port }) { return $true }
        Start-Sleep -Milliseconds 200
        # Re-query — listener state can change
        $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    }
    return $false
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
            404 { throw "Release '$Tag' not found in $Owner/$Repo." }
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

    $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases/assets/$AssetId"
    $sizeMB = [Math]::Round($Size / 1MB, 1)
    $authHdr = @{
        Authorization          = "Bearer $Token"
        Accept                 = "application/octet-stream"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    # Resolve CDN redirect — S3 rejects requests carrying an Authorization header
    $cdnUrl = $null
    try {
        Invoke-WebRequest -Uri $apiUrl -Headers $authHdr -MaximumRedirection 0 | Out-Null
    }
    catch {
        $cdnUrl = $_.Exception.Response.Headers.Location?.ToString()
        if (-not $cdnUrl) { throw "Could not resolve asset CDN URL: $_" }
        Write-INFO "CDN redirect → $(([Uri]$cdnUrl).Host)"
    }

    Write-INFO "Downloading ${sizeMB} MB → $OutPath"
    if ($cdnUrl) { Invoke-WebRequest -Uri $cdnUrl -OutFile $OutPath }
    else { Invoke-WebRequest -Uri $apiUrl -Headers $authHdr -OutFile $OutPath }

    Write-OK "Download complete: $([Math]::Round((Get-Item $OutPath).Length / 1MB, 1)) MB"
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

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $entryCount = $zip.Entries.Count
        $zip.Dispose()
        Write-OK "Package verified — $entryCount file(s)  (tag: $($assetInfo.Tag))"
    }
    catch {
        throw "Downloaded file is not a valid ZIP: $_"
    }

    $extractDir = Join-Path $tmpDir "extracted"
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
    Write-OK "Extracted → $extractDir"

    $testerExe = Get-ChildItem -Path $extractDir -Filter "metatester64.exe" -Recurse |
    Select-Object -First 1
    if (-not $testerExe) { throw "metatester64.exe not found inside the package." }

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
    Write-Step "Terminating existing tester agent processes and removing services..."

    # ── 1. Kill running processes ──────────────────────────────────────────────
    $procs = Get-Process -Name "metatester64", "metatester" -ErrorAction SilentlyContinue
    if ($procs) {
        foreach ($p in $procs) {
            try { $p | Stop-Process -Force; Write-OK "Killed PID $($p.Id) ($($p.Name))" }
            catch { Write-WARN "Could not kill PID $($p.Id): $_" }
        }
    }
    else {
        Write-OK "No running agent processes found."
    }

    # ── 2. Remove metatester64 Windows services via sc ─────────────────────────
    # metatester64 /install registers services named "MT5 Tester Agent <host>:<port>"
    # Query all services whose name starts with the known prefix.
    $svcPrefix = ""

    $services = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'Metatester%'" -ErrorAction SilentlyContinue

    if (-not $services) {
        Write-OK "No MT5 agent services found."
    }
    else {
        foreach ($svc in $services) {
            $svcName = $svc.Name

            # Stop first if still running — sc delete fails on a running service
            if ($svc.State -eq "Running") {
                $stopResult = & sc.exe stop $svcName 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-WARN "sc stop '$svcName' — $($stopResult -join ' ')"
                }
                else {
                    Write-INFO "Stopped service: $svcName"
                }
                Start-Sleep -Milliseconds 500   # brief pause for SCM to process the stop
            }

            $delResult = & sc.exe delete $svcName 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-OK "Deleted service: $svcName"
            }
            else {
                Write-WARN "sc delete '$svcName' failed — $($delResult -join ' ')"
            }
        }
    }

    # ── 3. Wait for ports to be released ──────────────────────────────────────
    $deadline = [datetime]::Now.AddSeconds(5)
    while ([datetime]::Now -lt $deadline) {
        if (-not (Get-Process -Name "metatester64", "metatester" -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 300
    }

    $still = Get-Process -Name "metatester64", "metatester" -ErrorAction SilentlyContinue
    if ($still) { Write-WARN "$($still.Count) process(es) still alive — port checks may be unreliable." }
    else { Write-OK "All agents terminated." }
}

function Remove-AgentFolders {
    param([string]$TesterPath)

    Write-Step "Removing existing agent folders..."

    if (-not (Test-Path $TesterPath)) { Write-INFO "Tester folder not found — nothing to clean."; return }

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

    Write-Step "Creating $Count agent folder(s)..."
    $null = New-Item -ItemType Directory -Path $TesterPath -Force

    $assignedPorts = [System.Collections.Generic.List[int]]::new()
    $nextPort = $PortStart
    # Track attempted agents separately so port search cursor advances correctly
    # even when an individual agent fails (fixes original loop-counter/skip gap)
    $attempted = 0

    while (($assignedPorts.Count -lt $Count) -and ($attempted -lt ($Count * 3))) {
        $attempted++

        try { $port = Get-NextFreePort -StartAt $nextPort }
        catch { Write-ERR "Port search exhausted: $_"; break }

        $nextPort = $port + 1   # advance cursor past this assignment

        $dir = Join-Path $TesterPath "Agent-$AgentHost-$port"
        $destExe = Join-Path $dir "metatester64.exe"
        $iniPath = Join-Path $dir "metatester64.ini"

        try {
            $null = New-Item -ItemType Directory -Path $dir -Force
            Copy-Item -Path $SourceExe -Destination $destExe -Force

            # metatester64.ini — minimal config; /agent and /password CLI args take precedence
            # but the ini provides a fallback and documents the intended port clearly.
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
            Write-OK "Agent $($assignedPorts.Count + 1)/$Count  →  $AgentHost`:$port  [$pwdStatus]"
            $assignedPorts.Add($port)
        }
        catch {
            Write-ERR "Failed to create agent on port ${port}: $_"
            # Remove partially created folder to keep state clean
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($assignedPorts.Count -lt $Count) {
        Write-WARN "Only $($assignedPorts.Count) of $Count agents created."
    }
    else {
        Write-OK "$($assignedPorts.Count) / $Count agent folders ready."
    }

    return , $assignedPorts.ToArray()
}

function Start-Agents {
    param(
        [string] $TesterPath,
        [string] $AgentHost,
        [int[]]  $Ports,
        [string] $Password,
        [int]    $PortCheckTimeout
    )

    Write-Step "Launching agents via metatester64 CLI..."

    $started = [System.Collections.Generic.List[int]]::new()
    $failed = [System.Collections.Generic.List[int]]::new()

    foreach ($port in $Ports) {
        $dir = Join-Path $TesterPath "Agent-$AgentHost-$port"
        $exe = Join-Path $dir "metatester64.exe"

        if (-not (Test-Path $exe)) {
            Write-WARN "Skipping port $port — exe missing."
            $failed.Add($port)
            continue
        }

        # Build argument list for metatester64:
        #   /agent:<host>:<port>   — tells the agent which address to bind
        #   /password:<pass>       — authentication token (optional)
        #   /log                   — enables log file in the agent directory
        #
        # Note: metatester64 reads metatester64.ini from its working directory
        # as a fallback, but CLI args always take precedence.
        $argList = @("/agent:`"$AgentHost`:$port`"")
        if ($Password) { $argList += "/password:`"$Password`"" }
        $argList += "/log"

        try {
            $proc = Start-Process `
                -FilePath $exe `
                -ArgumentList $argList `
                -WorkingDirectory $dir `
                -WindowStyle Hidden `
                -PassThru

            Write-INFO "PID $($proc.Id) launched — waiting for port $port to bind..."

            if (Wait-PortListening -Port $port -TimeoutMs $PortCheckTimeout) {
                Write-OK "Agent $AgentHost`:$port  [PID $($proc.Id)] — listening ✔"
                $started.Add($port)
            }
            else {
                Write-WARN "Agent $AgentHost`:$port  [PID $($proc.Id)] — port not bound within ${PortCheckTimeout}ms (check agent log in $dir)"
                $failed.Add($port)
            }
        }
        catch {
            Write-ERR "Could not start agent on port ${port}: $_"
            $failed.Add($port)
        }
    }

    if ($failed.Count -gt 0) {
        Write-WARN "$($failed.Count) agent(s) did not start cleanly: ports $($failed -join ', ')"
    }

    return , $started.ToArray()
}

# ─── Security ─────────────────────────────────────────────────────────────────

function Add-FirewallRules {
    param([string]$TesterPath, [int[]]$Ports)

    Write-Step "Configuring Windows Firewall..."

    $portRange = "$($Ports[0])-$($Ports[-1])"
    $exePaths = Get-ChildItem -Path $TesterPath -Filter "metatester64.exe" -Recurse `
        -ErrorAction SilentlyContinue

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("advfirewall firewall delete rule name=`"MT5 Tester Agents in`"")
    $lines.Add("advfirewall firewall delete rule name=`"MT5 Tester Agents out`"")
    foreach ($exe in $exePaths) {
        $lines.Add("advfirewall firewall delete rule name=`"MT5 Agent $($exe.Directory.Name)`"")
    }
    $lines.Add("advfirewall firewall add rule name=`"MT5 Tester Agents in`"  dir=in  action=allow protocol=TCP localport=$portRange profile=any")
    $lines.Add("advfirewall firewall add rule name=`"MT5 Tester Agents out`" dir=out action=allow protocol=TCP localport=$portRange profile=any")
    foreach ($exe in $exePaths) {
        $lines.Add("advfirewall firewall add rule name=`"MT5 Agent $($exe.Directory.Name)`" dir=in action=allow program=`"$($exe.FullName)`" profile=any")
    }

    $scriptFile = Join-Path $env:TEMP "mt5fw_$(Get-Random).netsh"
    $lines | Set-Content $scriptFile -Encoding UTF8

    # Capture output — previously swallowed completely
    $fwOutput = & netsh -f $scriptFile 2>&1
    Remove-Item $scriptFile -Force -ErrorAction SilentlyContinue

    $fwErrors = $fwOutput | Where-Object { $_ -match "error|failed|invalid" }
    if ($fwErrors) { Write-WARN "Firewall warnings: $($fwErrors -join '; ')" }

    Write-OK "FW in+out TCP $portRange"
    Write-OK "$($exePaths.Count) per-process inbound rule(s) added"
}

function Add-DefenderExclusions {
    param([string]$TesterPath)

    Write-Step "Adding Windows Defender exclusions..."

    $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if (-not $mpStatus) {
        Write-WARN "Defender not active — skipping."
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
    param([string]$TesterPath, [int[]]$AllPorts, [int[]]$StartedPorts, [string]$Password)

    $portRange = if ($AllPorts.Count -gt 0) { "$($AllPorts[0])-$($AllPorts[-1])" } else { "—" }
    $pwdLine = if ($Password) { "set (sync with Terminal options)" } else { "NONE — local use only" }
    $pwdColor = if ($Password) { "White" } else { "DarkYellow" }

    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │                     SETUP COMPLETE                      │" -ForegroundColor Cyan
    Write-Host "  ├─────────────────────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host "  │  Agents created  : $($AllPorts.Count.ToString().PadRight(36))│" -ForegroundColor White
    Write-Host "  │  Agents listening: $($StartedPorts.Count.ToString().PadRight(36))│" -ForegroundColor $(if ($StartedPorts.Count -eq $AllPorts.Count) { "Green" } else { "DarkYellow" })
    Write-Host "  │  Ports assigned  : $($portRange.PadRight(36))│" -ForegroundColor White
    Write-Host "  │  Agent password  : $($pwdLine.PadRight(36))│" -ForegroundColor $pwdColor
    Write-Host "  └─────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
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

    Write-INFO "Logical CPUs: $([Environment]::ProcessorCount)  →  target agent count: $MaxAgents"

    # 1. Download package — do this FIRST so the exe is in hand before any destructive steps
    $pkg = Get-MT5Package -Token $GitHubToken -Owner $GitHubOwner `
        -Repo $GitHubRepo -Tag $GitHubTag -Asset $AssetName

    try {
        # 2. Stop existing agents and release their ports before port scanning
        Stop-AllAgents
        Remove-AgentFolders -TesterPath $TesterRoot

        # 3. Create agent folders — all port assignments happen here
        [int[]]$assignedPorts = New-AgentFolders `
            -TesterPath $TesterRoot `
            -SourceExe $pkg.TesterExe `
            -AgentHost $AgentHost `
            -PortStart $PortStart `
            -Count $MaxAgents `
            -Password $AgentPassword

        if ($assignedPorts.Count -eq 0) {
            throw "No agents were created — check port availability and disk space."
        }

        # 4. Security rules use the actual assigned port list
        Add-FirewallRules -TesterPath $TesterRoot -Ports $assignedPorts
        try { Add-DefenderExclusions -TesterPath $TesterRoot }
        catch { Write-WARN "Defender exclusions failed: $_" }

        # 5. Launch agents — returns only ports that actually came up
        [int[]]$startedPorts = @()
        if (-not $SkipStart) {
            $startedPorts = Start-Agents `
                -TesterPath $TesterRoot `
                -AgentHost $AgentHost `
                -Ports $assignedPorts `
                -Password $AgentPassword `
                -PortCheckTimeout $PortCheckTimeout
        }
        else {
            Write-WARN "-SkipStart set — agents created but not launched."
            $startedPorts = @()
        }

        Show-Summary -TesterPath $TesterRoot `
            -AllPorts $assignedPorts `
            -StartedPorts $startedPorts `
            -Password $AgentPassword
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
