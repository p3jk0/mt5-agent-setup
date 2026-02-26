#Requires -Version 7.0
<#
.SYNOPSIS
    Diagnostics: running agents, ports, firewall rules, Defender exclusions.
#>
param([int]$PortStart = 3000)

Write-Host "`n── MT5 Agent Status ───────────────────────────────" -ForegroundColor Cyan

$procs = Get-Process -Name "metatester64" -ErrorAction SilentlyContinue
Write-Host "  Running : $($procs.Count)" -ForegroundColor $(if ($procs.Count -gt 0) {"Green"} else {"Red"})

foreach ($p in $procs) {
    $conn = Get-NetTCPConnection -OwningProcess $p.Id -ErrorAction SilentlyContinue |
            Where-Object { $_.State -eq "Listen" } | Select-Object -First 1
    $port = if ($conn) { $conn.LocalPort } else { "?" }
    Write-Host "    PID $($p.Id.ToString().PadLeft(6))  CPU $($p.CPU.ToString("F1").PadLeft(8))s  Port $port" -ForegroundColor White
}

Write-Host ""
Write-Host "── Firewall Rules ─────────────────────────────────" -ForegroundColor Cyan
$rules = Get-NetFirewallRule -DisplayName "MT5*" -ErrorAction SilentlyContinue
Write-Host "  Count: $($rules.Count)"
$rules | ForEach-Object {
    $enabled = if ($_.Enabled -eq "True") { "ON " } else { "OFF" }
    Write-Host "    [$($_.Direction.ToString().PadRight(8))] [$enabled] $($_.DisplayName)" -ForegroundColor $(if ($enabled -eq "ON ") {"Gray"} else {"DarkRed"})
}

Write-Host ""
Write-Host "── Defender Exclusions ────────────────────────────" -ForegroundColor Cyan
$pref = Get-MpPreference -ErrorAction SilentlyContinue
if ($pref) {
    $pref.ExclusionPath    | Where-Object { $_ -match "MetaQuotes|Tester" } |
        ForEach-Object { Write-Host "    PATH    $_" -ForegroundColor Gray }
    $pref.ExclusionProcess | Where-Object { $_ -match "metatester|terminal" } |
        ForEach-Object { Write-Host "    PROCESS $_" -ForegroundColor Gray }
} else {
    Write-Host "  Defender not active" -ForegroundColor DarkYellow
}
Write-Host ""
