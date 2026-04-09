#Requires -Version 7.0
<#
.SYNOPSIS
    MT5 Strategy Tester — Complete Uninstaller

.DESCRIPTION
    Reverses everything done by Setup-MT5Agents.ps1:
      1. Stops and uninstalls all MetaTester agent services
      2. Kills any orphan metatester64 processes
      3. Removes Windows Firewall rules created by the setup
      4. Removes Windows Defender exclusions
      5. Deletes the TesterRoot directory (metatester64.exe)
      6. Removes cached download packages from %TEMP%

.PARAMETER TesterRoot
    Folder where metatester64.exe was deployed.
    Default: %APPDATA%\MetaQuotes\Terminal\Common\Tester

.PARAMETER KeepExecutable
    Do not delete metatester64.exe or the TesterRoot directory.

.PARAMETER KeepCache
    Do not delete cached download packages from %TEMP%.

.PARAMETER Force
    Skip the confirmation prompt.

.EXAMPLE
    .\Remove-MT5Agents.ps1
    .\Remove-MT5Agents.ps1 -KeepExecutable -Force
#>
[CmdletBinding()]
param(
    [string]$TesterRoot = "",
    [switch]$KeepExecutable,
    [switch]$KeepCache,
    [switch]$Force
)

$TesterRoot = $TesterRoot ? $TesterRoot : (Join-Path $env:APPDATA "MetaQuotes\Terminal\Common\Tester")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Helpers ────────────────────────────────────────────────────────────────────
function Write-Banner {
    Write-Host ""
    Write-Host " ╔════════════════════════════════════════════════════════╗" -ForegroundColor DarkRed
    Write-Host " ║  MT5 Strategy Tester — Complete Uninstaller           ║" -ForegroundColor Red
    Write-Host " ╚════════════════════════════════════════════════════════╝" -ForegroundColor DarkRed
    Write-Host ""
}

function Write-Step { param([string]$m) Write-Host "`n▶ $m" -ForegroundColor Yellow }
function Write-OK { param([string]$m) Write-Host "  ✔ $m" -ForegroundColor Green  }
function Write-WARN { param([string]$m) Write-Host "  ⚠ $m" -ForegroundColor DarkYellow }
function Write-ERR { param([string]$m) Write-Host "  ✖ $m" -ForegroundColor Red    }
function Write-INFO { param([string]$m) Write-Host "  · $m" -ForegroundColor Gray   }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [Security.Principal.WindowsPrincipal]$id
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-ERR "Administrator privileges required. Re-launch with:"
        Write-Host "  Start-Process pwsh -Verb RunAs -ArgumentList '-File `"$PSCommandPath`"'" -ForegroundColor White
        exit 1
    }
}

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

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $output = @($stdout, $stderr) | Where-Object { $_ } | ForEach-Object { $_.Trim() }
    return @{ ExitCode = $proc.ExitCode; Output = ($output -join "`n") }
}

# ─── Step 1: Stop and uninstall all MetaTester services ─────────────────────────
function Remove-AllAgentServices {
    Write-Step "Stopping and uninstalling MetaTester agent services..."

    $testerExe = Join-Path $TesterRoot "metatester64.exe"
    $hasTesterExe = Test-Path $testerExe

    $services = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'MetaTester%'" -ErrorAction SilentlyContinue

    if (-not $services) {
        Write-OK "No MetaTester services found."
        return
    }

    Write-INFO "Found $($services.Count) MetaTester service(s)."

    foreach ($svc in $services) {
        $svcName = $svc.Name

        # Try clean uninstall via metatester64 /uninstall
        $addressArg = $null
        if ($svc.PathName -match '/address[`:]"?([^\s"]+)"?') {
            $addressArg = $Matches[1]
        }

        if ($addressArg -and $hasTesterExe) {
            Write-INFO "Uninstalling '$svcName' via metatester64 /uninstall /address`:$addressArg"
            $result = Invoke-Metatester -ExePath $testerExe -Arguments @("/uninstall", "/address`:$addressArg")
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

    Start-Sleep -Seconds 1
    Write-OK "All MetaTester services removed."
}

# ─── Step 2: Kill orphan processes ──────────────────────────────────────────────
function Stop-OrphanProcesses {
    Write-Step "Killing orphan metatester processes..."

    $procs = Get-Process -Name "metatester64", "metatester" -ErrorAction SilentlyContinue
    if (-not $procs) {
        Write-OK "No orphan metatester processes found."
        return
    }

    foreach ($p in $procs) {
        try {
            $p | Stop-Process -Force
            Write-OK "Killed PID $($p.Id) ($($p.ProcessName))"
        }
        catch {
            Write-WARN "Could not kill PID $($p.Id): $_"
        }
    }
}

# ─── Step 3: Remove firewall rules ─────────────────────────────────────────────
function Remove-FirewallRules {
    Write-Step "Removing MT5 firewall rules..."

    $ruleNames = @(
        "MT5 Tester Agents in",
        "MT5 Tester Agents out",
        "MT5 Agent metatester64"
    )

    foreach ($name in $ruleNames) {
        $delOut = & netsh advfirewall firewall delete rule name="$name" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Removed firewall rule: $name"
        }
        else {
            $outText = $delOut -join ' '
            if ($outText -match "No rules match") {
                Write-INFO "Rule not found (already removed): $name"
            }
            else {
                Write-WARN "Failed to remove rule '$name': $outText"
            }
        }
    }
}

# ─── Step 4: Remove Defender exclusions ─────────────────────────────────────────
# function Remove-DefenderExclusions {
#     Write-Step "Removing Windows Defender exclusions..."

#     $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
#     if (-not $mpStatus) {
#         Write-WARN "Defender not active — skipping."
#         return
#     }

#     $pathExclusions = @(
#         $TesterRoot,
#         (Join-Path $env:APPDATA "MetaQuotes")
#     )

#     foreach ($p in $pathExclusions) {
#         try {
#             Remove-MpPreference -ExclusionPath $p -Force
#             Write-OK "Removed path exclusion: $p"
#         } catch {
#             Write-WARN "Could not remove path exclusion '$p': $_"
#         }
#     }

#     $testerExe = Join-Path $TesterRoot "metatester64.exe"
#     try {
#         Remove-MpPreference -ExclusionProcess $testerExe -Force
#         Write-OK "Removed process exclusion: $testerExe"
#     } catch {
#         Write-WARN "Could not remove process exclusion: $_"
#     }
# }

# ─── Step 5: Delete TesterRoot directory ────────────────────────────────────────
function Remove-TesterFiles {
    Write-Step "Removing TesterRoot directory..."

    if (-not (Test-Path $TesterRoot)) {
        Write-OK "TesterRoot not found (already removed): $TesterRoot"
        return
    }

    try {
        Remove-Item -Path $TesterRoot -Recurse -Force
        Write-OK "Deleted: $TesterRoot"
    }
    catch {
        Write-ERR "Failed to delete TesterRoot: $_"
    }
}

# ─── Step 6: Remove cached downloads ───────────────────────────────────────────
function Remove-CachedPackages {
    Write-Step "Removing cached download packages from TEMP..."

    $cacheDirs = Get-ChildItem -Path $env:TEMP -Directory -Filter "mt5agents_cache_*" -ErrorAction SilentlyContinue

    if (-not $cacheDirs) {
        Write-OK "No cached packages found."
        return
    }

    foreach ($dir in $cacheDirs) {
        try {
            Remove-Item -Path $dir.FullName -Recurse -Force
            Write-OK "Deleted cache: $($dir.Name)"
        }
        catch {
            Write-WARN "Could not delete '$($dir.FullName)': $_"
        }
    }
}

# ─── Main ───────────────────────────────────────────────────────────────────────
function Main {
    Write-Banner
    Assert-Admin

    if (-not $Force) {
        Write-Host "  This will completely remove all MT5 tester agents and related configuration." -ForegroundColor Yellow
        Write-Host "  TesterRoot: $TesterRoot" -ForegroundColor Gray
        Write-Host ""
        $confirm = Read-Host "  Type 'yes' to continue"
        if ($confirm -ne "yes") {
            Write-Host "`n  Aborted." -ForegroundColor DarkGray
            exit 0
        }
    }

    Remove-AllAgentServices
    Stop-OrphanProcesses
    Remove-FirewallRules
    # Remove-DefenderExclusions

    if (-not $KeepExecutable) {
        Remove-TesterFiles
    }
    else {
        Write-INFO "-KeepExecutable set — skipping TesterRoot deletion."
    }

    if (-not $KeepCache) {
        Remove-CachedPackages
    }
    else {
        Write-INFO "-KeepCache set — skipping cache cleanup."
    }

    Write-Host ""
    Write-Host " ┌─────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host " │              UNINSTALL COMPLETE                         │" -ForegroundColor Cyan
    Write-Host " └─────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""
}

Main
