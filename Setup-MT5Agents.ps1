#Requires -Version 7.0
<#
.SYNOPSIS
    MT5 Strategy Tester — Automated Agent Distributor v3.0

.DESCRIPTION
    Downloads metatester64.exe from a private GitHub Release, uninstalls all
    existing agents via metatester64 /uninstall and sc.exe fallback, then
    installs and starts N agents (default: 1 per logical CPU) as Windows
    services using metatester64's native CLI:

        metatester64.exe /install /address:<host>:<port> /password:<pwd>
        metatester64.exe /start   /address:<host>:<port>

    The executable is copied ONCE to $TesterRoot — no per-agent directories.
    Adds Windows Firewall rules and Defender exclusions automatically.

.PARAMETER GitHubToken
    GitHub PAT (repo scope for private repos).  Env: MT5_GITHUB_TOKEN

.PARAMETER GitHubOwner
    GitHub username or org.  Env: MT5_GITHUB_OWNER

.PARAMETER GitHubRepo
    Repo containing the release.  Default: mt5-agent-setup   Env: MT5_GITHUB_REPO

.PARAMETER GitHubTag
    Release tag. "latest" (default) for newest.  Env: MT5_GITHUB_TAG

.PARAMETER AssetName
    Release asset filename.  Default: mt5-tester-agent.zip

.PARAMETER MaxAgents
    Number of agents to install.  Default: logical CPU count.

.PARAMETER AgentPassword
    Password passed via /password on install. Must match Terminal config.
    Env: MT5_AGENT_PASSWORD

.PARAMETER TesterRoot
    Destination folder for metatester64.exe.
    Default: %APPDATA%\MetaQuotes\Terminal\Common\Tester

.PARAMETER PortStart
    First port to assign.  Default: 3000

.PARAMETER AgentHost
    Host/IP for agent binding.  Default: 127.0.0.1

.PARAMETER PortCheckTimeout
    Milliseconds to wait for an agent service to bind its port.  Default: 5000

.PARAMETER SkipStart
    Install agent services but do not start them.

.PARAMETER KeepDownload
    Do not delete the downloaded zip after extraction.

.PARAMETER ClearCache
    Force re-download even if a cached package exists from a previous run.

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
    [int]   $PortCheckTimeout = 5000,
    [switch]$SkipStart,
    [switch]$KeepDownload,
    [switch]$ClearCache
)

# Env-var fallbacks
$GitHubToken = $GitHubToken   ? $GitHubToken   : $env:MT5_GITHUB_TOKEN
$GitHubOwner = $GitHubOwner   ? $GitHubOwner   : $env:MT5_GITHUB_OWNER
$GitHubRepo = $GitHubRepo    ? $GitHubRepo    : ($env:MT5_GITHUB_REPO ?? "mt5-agent-setup")
$GitHubTag = $GitHubTag     ? $GitHubTag     : ($env:MT5_GITHUB_TAG ?? "latest")
$AgentPassword = $AgentPassword ? $AgentPassword : ($env:MT5_AGENT_PASSWORD ?? "")
$TesterRoot = $TesterRoot    ? $TesterRoot    : (Join-Path $env:APPDATA "MetaQuotes\Terminal\Common\Tester")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Helpers ────────────────────────────────────────────────────────────────────
function Write-Banner {
    Write-Host ""
    Write-Host " ╔════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host " ║  MT5 Strategy Tester — Auto Agent Distributor v3.0.0  ║" -ForegroundColor Cyan
    Write-Host " ║  github.com/$GitHubOwner/$GitHubRepo" -ForegroundColor DarkCyan
    Write-Host " ╚════════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Step { param([string]$m) Write-Host "`n▶ $m" -ForegroundColor Yellow }
function Write-OK { param([string]$m) Write-Host "  ✔ $m" -ForegroundColor Green }
function Write-WARN { param([string]$m) Write-Host "  ⚠ $m" -ForegroundColor DarkYellow }
function Write-ERR { param([string]$m) Write-Host "  ✖ $m" -ForegroundColor Red }
function Write-INFO { param([string]$m) Write-Host "  · $m" -ForegroundColor Gray }

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
    if (-not $GitHubToken) { $missing += "GitHubToken (or env MT5_GITHUB_TOKEN)" }
    if (-not $GitHubOwner) { $missing += "GitHubOwner (or env MT5_GITHUB_OWNER)" }
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

# ─── Native exe runner (avoids PS7 "StandardOutputEncoding" bug with 2>&1) ──────
function Invoke-Metatester {
    param(
        [string]   $ExePath,
        [string[]] $Arguments
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new($ExePath)
    $psi.Arguments = $Arguments -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = Split-Path $ExePath -Parent

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $null = $proc.Start()

    # Read streams before WaitForExit to avoid deadlock on large output
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $output = @($stdout, $stderr) | Where-Object { $_ } | ForEach-Object { $_.Trim() }
    return @{ ExitCode = $proc.ExitCode; Output = ($output -join "`n") }
}

# ─── Port utilities ─────────────────────────────────────────────────────────────
function Test-PortAvailable {
    param([int]$Port)
    $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    return (-not ($props.GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port }))
}

function Get-NextFreePort {
    param([int]$StartAt, [int]$MaxSearch = 200)
    $limit = $StartAt + $MaxSearch
    for ($candidate = $StartAt; $candidate -lt $limit; $candidate++) {
        if (Test-PortAvailable -Port $candidate) { return $candidate }
        Write-WARN "Port $candidate in use — skipping"
    }
    throw "No free port found in range $StartAt – $($limit - 1)"
}

function Wait-PortListening {
    param([int]$Port, [int]$TimeoutMs = 5000)
    $deadline = [datetime]::Now.AddMilliseconds($TimeoutMs)
    while ([datetime]::Now -lt $deadline) {
        $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        if ($props.GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port }) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# ─── GitHub Release download ───────────────────────────────────────────────────
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

    # Resolve CDN redirect — S3 rejects Authorization header
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
    param(
        [string]$Token,
        [string]$Owner,
        [string]$Repo,
        [string]$Tag,
        [string]$Asset,
        [switch]$ClearCache
    )

    # Deterministic cache dir — survives script re-runs during debugging
    $cacheKey = "$Owner-$Repo-$Tag" -replace '[^a-zA-Z0-9_-]', '_'
    $cacheDir = Join-Path $env:TEMP "mt5agents_cache_$cacheKey"
    $cacheExtract = Join-Path $cacheDir "extracted"
    $cachedExe = $null
    if ($ClearCache -and (Test-Path $cacheDir)) {
        Remove-Item $cacheDir -Recurse -Force
        Write-INFO "Cache cleared: $cacheDir"
    }
    else {
        $cachedExe = Get-ChildItem -Path $cacheExtract -Filter "metatester64.exe" -Recurse `
            -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($cachedExe) {
        Write-Step "Using cached MT5 package from $cacheDir"
        Write-OK "Cached executable: $($cachedExe.FullName)"
        return @{
            TmpDir     = $cacheDir
            ZipPath    = (Join-Path $cacheDir $Asset)
            ExtractDir = $cacheExtract
            TesterExe  = $cachedExe.FullName
            Cached     = $true
        }
    }

    Write-Step "Fetching MT5 tester package from GitHub Release..."
    $assetInfo = Get-ReleaseAsset -Owner $Owner -Repo $Repo -Tag $Tag -Asset $Asset -Token $Token

    # Clean stale cache (partial download / failed extract)
    if (Test-Path $cacheDir) { Remove-Item $cacheDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $cacheDir -Force

    $zipPath = Join-Path $cacheDir $Asset
    Invoke-AssetDownload -Owner $Owner -Repo $Repo -AssetId $assetInfo.Id `
        -Token $Token -OutPath $zipPath -Size $assetInfo.Size

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $entryCount = $zip.Entries.Count
        $zip.Dispose()
        Write-OK "Package verified — $entryCount file(s) (tag: $($assetInfo.Tag))"
    }
    catch { throw "Downloaded file is not a valid ZIP: $_" }

    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $cacheExtract)
    Write-OK "Extracted → $cacheExtract"

    $testerExe = Get-ChildItem -Path $cacheExtract -Filter "metatester64.exe" -Recurse |
    Select-Object -First 1
    if (-not $testerExe) { throw "metatester64.exe not found inside the package." }

    Write-OK "Executable: $($testerExe.FullName)"
    return @{
        TmpDir     = $cacheDir
        ZipPath    = $zipPath
        ExtractDir = $cacheExtract
        TesterExe  = $testerExe.FullName
        Cached     = $false
    }
}

# ─── Agent lifecycle (service-based) ───────────────────────────────────────────

function Uninstall-AllAgents {
    param([string]$TesterExe)

    Write-Step "Uninstalling existing MetaTester agent services..."

    # Discover all MetaTester services via CIM
    $services = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'MetaTester%'" `
        -ErrorAction SilentlyContinue

    if (-not $services) {
        Write-OK "No existing MetaTester services found."
        return
    }

    foreach ($svc in $services) {
        $svcName = $svc.Name

        # Try to extract address:port from service name or PathName for /uninstall
        # Service PathName typically contains /address:<host>:<port>
        $addressArg = $null
        if ($svc.PathName -match '/address[`:]"?([^\s"]+)"?') {
            $addressArg = $Matches[1]
        }

        # Attempt clean uninstall via metatester64 /uninstall first
        if (($addressArg) -and (Test-Path $TesterExe)) {
            Write-INFO "Uninstalling service '$svcName' via /uninstall /address`:$addressArg"
            $result = Invoke-Metatester -ExePath $TesterExe -Arguments @("/uninstall", "/address`:$addressArg")
            if ($result.ExitCode -eq 0) {
                Write-OK "Uninstalled: $svcName"
                continue
            }
            Write-WARN "metatester64 /uninstall returned $($result.ExitCode) — falling back to sc.exe"
        }

        # Fallback: sc stop + sc delete
        if ($svc.State -eq "Running") {
            $stopOut = & sc.exe stop $svcName 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-WARN "sc stop '$svcName' — $($stopOut -join ' ')"
            }
            else {
                Write-INFO "Stopped: $svcName"
            }
            Start-Sleep -Milliseconds 500
        }

        $delOut = & sc.exe delete $svcName 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Deleted service: $svcName"
        }
        else {
            Write-WARN "sc delete '$svcName' failed — $($delOut -join ' ')"
        }
    }

    # Also kill any orphan processes
    $procs = Get-Process -Name "metatester64", "metatester" -ErrorAction SilentlyContinue
    if ($procs) {
        foreach ($p in $procs) {
            try { $p | Stop-Process -Force; Write-OK "Killed orphan PID $($p.Id)" }
            catch { Write-WARN "Could not kill PID $($p.Id): $_" }
        }
    }

    # Brief wait for port release
    Start-Sleep -Seconds 2
    Write-OK "Cleanup complete."
}

function Install-Agents {
    param(
        [string] $TesterExe,
        [string] $AgentHost,
        [int]    $PortStart,
        [int]    $Count,
        [string] $Password
    )

    Write-Step "Installing $Count agent service(s) via metatester64 /install..."

    $installedPorts = [System.Collections.Generic.List[int]]::new()
    $nextPort = $PortStart
    $attempts = 0
    $maxAttempts = $Count * 3

    while (($installedPorts.Count -lt $Count) -and ($attempts -lt $maxAttempts)) {
        $attempts++
        try {
            $port = Get-NextFreePort -StartAt $nextPort
        }
        catch {
            Write-ERR "Port search exhausted: $_"
            break
        }
        $nextPort = $port + 1

        $address = "$AgentHost`:$port"

        # Build args: /install /address:<host>:<port> [/password:<pwd>]
        $argList = @("/install", "/address`:$address")
        if ($Password) {
            $argList += "/password`:$Password"
        }

        Write-INFO "Installing agent at $address..."
        try {
            $result = Invoke-Metatester -ExePath $TesterExe -Arguments $argList
            if ($result.ExitCode -ne 0) {
                Write-ERR "Install failed for $address (exit $($result.ExitCode)): $($result.Output)"
                continue
            }

            $pwdStatus = if ($Password) { "pwd ✔" } else { "no pwd" }
            Write-OK "Agent $($installedPorts.Count + 1)/$Count → $address [$pwdStatus]"
            $installedPorts.Add($port)
        }
        catch {
            Write-ERR "Exception installing agent at ${address}: $_"
        }
    }

    if ($installedPorts.Count -lt $Count) {
        Write-WARN "Only $($installedPorts.Count) of $Count agents installed."
    }
    else {
        Write-OK "$($installedPorts.Count)/$Count agent services installed."
    }

    return , $installedPorts.ToArray()
}

function Start-AgentServices {
    param(
        [string] $TesterExe,
        [string] $AgentHost,
        [int[]]  $Ports,
        [int]    $PortCheckTimeout
    )

    Write-Step "Starting agent services..."

    $started = [System.Collections.Generic.List[int]]::new()
    $failed = [System.Collections.Generic.List[int]]::new()

    foreach ($port in $Ports) {
        $address = "$AgentHost`:$port"

        try {
            $result = Invoke-Metatester -ExePath $TesterExe -Arguments @("/start", "/address`:$address")
            if ($result.ExitCode -ne 0) {
                Write-ERR "Start failed for $address (exit $($result.ExitCode)): $($result.Output)"
                $failed.Add($port)
                continue
            }

            Write-INFO "Service start issued for $address — verifying port binding..."
            if (Wait-PortListening -Port $port -TimeoutMs $PortCheckTimeout) {
                Write-OK "Agent $address — listening ✔"
                $started.Add($port)
            }
            else {
                Write-WARN "Agent $address — port not bound within ${PortCheckTimeout}ms"
                $failed.Add($port)
            }
        }
        catch {
            Write-ERR "Exception starting agent at ${address}: $_"
            $failed.Add($port)
        }
    }

    if ($failed.Count -gt 0) {
        Write-WARN "$($failed.Count) agent(s) did not start cleanly: $($failed -join ', ')"
    }

    return , $started.ToArray()
}

# ─── Security ───────────────────────────────────────────────────────────────────
function Add-FirewallRules {
    param([string]$TesterExe, [int[]]$Ports)

    Write-Step "Configuring Windows Firewall..."

    $portRange = "$($Ports[0])-$($Ports[-1])"

    $lines = [System.Collections.Generic.List[string]]::new()

    # Clean old rules
    $lines.Add("advfirewall firewall delete rule name=`"MT5 Tester Agents in`"")
    $lines.Add("advfirewall firewall delete rule name=`"MT5 Tester Agents out`"")
    $lines.Add("advfirewall firewall delete rule name=`"MT5 Agent metatester64`"")

    # Port-range rules
    $lines.Add("advfirewall firewall add rule name=`"MT5 Tester Agents in`" dir=in action=allow protocol=TCP localport=$portRange profile=any")
    $lines.Add("advfirewall firewall add rule name=`"MT5 Tester Agents out`" dir=out action=allow protocol=TCP localport=$portRange profile=any")

    # Per-executable rule (single exe now)
    $lines.Add("advfirewall firewall add rule name=`"MT5 Agent metatester64`" dir=in action=allow program=`"$TesterExe`" profile=any")

    $scriptFile = Join-Path $env:TEMP "mt5fw_$(Get-Random).netsh"
    $lines | Set-Content $scriptFile -Encoding UTF8

    $fwOutput = & netsh -f $scriptFile 2>&1
    Remove-Item $scriptFile -Force -ErrorAction SilentlyContinue

    $fwErrors = $fwOutput | Where-Object { $_ -match "error|failed|invalid" }
    if ($fwErrors) { Write-WARN "Firewall warnings: $($fwErrors -join '; ')" }

    Write-OK "FW in+out TCP $portRange"
    Write-OK "Per-process inbound rule added for metatester64.exe"
}

function Add-DefenderExclusions {
    param([string]$TesterRoot, [string]$TesterExe)

    Write-Step "Adding Windows Defender exclusions..."

    $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if (-not $mpStatus) { Write-WARN "Defender not active — skipping."; return }

    $pathExcl = @(
        $TesterRoot,
        (Join-Path $env:APPDATA "MetaQuotes")
    )

    foreach ($p in $pathExcl) {
        try { Add-MpPreference -ExclusionPath $p -Force; Write-OK "PATH $p" }
        catch { Write-WARN "Path exclusion failed: $p — $_" }
    }

    try { Add-MpPreference -ExclusionProcess $TesterExe -Force; Write-OK "PROCESS $TesterExe" }
    catch { Write-WARN "Process exclusion failed: $TesterExe — $_" }
}

# ─── Summary ────────────────────────────────────────────────────────────────────
function Show-Summary {
    param([int[]]$AllPorts, [int[]]$StartedPorts, [string]$Password)

    $portRange = if ($AllPorts.Count -gt 0) { "$($AllPorts[0])-$($AllPorts[-1])" } else { "—" }
    $pwdLine = if ($Password) { "set (sync with Terminal options)" } else { "NONE — local use only" }
    $pwdColor = if ($Password) { "White" } else { "DarkYellow" }

    Write-Host ""
    Write-Host " ┌─────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host " │                    SETUP COMPLETE                       │" -ForegroundColor Cyan
    Write-Host " ├─────────────────────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host " │ Agents installed : $($AllPorts.Count.ToString().PadRight(35))│" -ForegroundColor White
    Write-Host " │ Agents listening : $($StartedPorts.Count.ToString().PadRight(35))│" -ForegroundColor $(if ($StartedPorts.Count -eq $AllPorts.Count) { "Green" } else { "DarkYellow" })
    Write-Host " │ Ports assigned   : $($portRange.PadRight(35))│" -ForegroundColor White
    Write-Host " │ Agent password   : $($pwdLine.PadRight(35))│" -ForegroundColor $pwdColor
    Write-Host " └─────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  MT5 Terminal → Tools → Options → Expert Advisors:" -ForegroundColor DarkGray
    Write-Host "    ✦ Allow local agents" -ForegroundColor DarkGray
    Write-Host "    ✦ Port range : $portRange" -ForegroundColor DarkGray
    if ($Password) {
        Write-Host "    ✦ Password   : <as configured>" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ─── Main ───────────────────────────────────────────────────────────────────────
function Main {
    Write-Banner
    Assert-Admin
    Assert-Params

    Write-INFO "Logical CPUs: $([Environment]::ProcessorCount) → target agent count: $MaxAgents"

    # 1. Download package
    $pkg = Get-MT5Package -Token $GitHubToken -Owner $GitHubOwner `
        -Repo $GitHubRepo -Tag $GitHubTag -Asset $AssetName `
        -ClearCache:$ClearCache

    try {
        # 2. Copy exe to TesterRoot (single location)
        Write-Step "Deploying metatester64.exe → $TesterRoot"
        $null = New-Item -ItemType Directory -Path $TesterRoot -Force
        $destExe = Join-Path $TesterRoot "metatester64.exe"
        Copy-Item -Path $pkg.TesterExe -Destination $destExe -Force
        Write-OK "metatester64.exe deployed to $TesterRoot"

        # 3. Uninstall existing agents (uses the deployed exe for /uninstall + sc fallback)
        Uninstall-AllAgents -TesterExe $destExe

        # 4. Install agent services
        [int[]]$assignedPorts = Install-Agents `
            -TesterExe $destExe `
            -AgentHost $AgentHost `
            -PortStart $PortStart `
            -Count $MaxAgents `
            -Password $AgentPassword

        if ($assignedPorts.Count -eq 0) {
            throw "No agents were installed — check port availability and metatester64 output."
        }

        # 5. Firewall + Defender
        Add-FirewallRules -TesterExe $destExe -Ports $assignedPorts
        try { Add-DefenderExclusions -TesterRoot $TesterRoot -TesterExe $destExe }
        catch { Write-WARN "Defender exclusions failed: $_" }

        # 6. Start services
        [int[]]$startedPorts = @()
        if (-not $SkipStart) {
            $startedPorts = Start-AgentServices `
                -TesterExe $destExe `
                -AgentHost $AgentHost `
                -Ports $assignedPorts `
                -PortCheckTimeout $PortCheckTimeout
        }
        else {
            Write-WARN "-SkipStart set — agents installed but not started."
        }

        Show-Summary -AllPorts $assignedPorts -StartedPorts $startedPorts -Password $AgentPassword
    }
    finally {
        if ((-not $KeepDownload) -and (-not $pkg.Cached)) {
            Write-Step "Cleaning up temp files..."
            Remove-Item -Path $pkg.TmpDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-OK "Temp folder removed."
        }
        elseif ($pkg.Cached) {
            Write-INFO "Cache retained at: $($pkg.TmpDir)"
        }
        else {
            Write-INFO "Zip kept at: $($pkg.ZipPath)"
        }
    }
}

Main
