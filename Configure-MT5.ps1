#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = "Set")]
param(
	[Parameter(ParameterSetName = "Set")]   [switch]$Set,
	[Parameter(ParameterSetName = "Show")]  [switch]$Show,
	[Parameter(ParameterSetName = "Clear")] [switch]$Clear
)

$VARS = [ordered]@{
	MT5_GITHUB_TOKEN   = $true    # $true = sensitive (masked)
	MT5_GITHUB_OWNER   = $false
	MT5_GITHUB_REPO    = $false
	MT5_GITHUB_TAG     = $false
	MT5_AGENT_PASSWORD = $true
}

function Assert-Admin {
	$p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
	if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
		Write-Host "Requires Administrator." -ForegroundColor Red; exit 1
	}
}

function Mask { param([string]$v) if ($v) { "$($v.Substring(0,[Math]::Min(6,$v.Length)))****" } else { "(not set)" } }

switch ($PSCmdlet.ParameterSetName) {
	"Set" {
		Assert-Admin
		Write-Host ""
		foreach ($key in $VARS.Keys) {
			$sensitive = $VARS[$key]
			$current = [Environment]::GetEnvironmentVariable($key, "Machine")
			$hint = if ($current) { " [$(if ($sensitive) { Mask $current } else { $current })]" } else { "" }
			$val = if ($sensitive) {
				$s = Read-Host "$key$hint" -AsSecureString
				[Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
			}
			else {
				Read-Host "$key$hint"
			}
			if ($val) { [Environment]::SetEnvironmentVariable($key, $val, "Machine"); Write-Host "  ✔ $key" -ForegroundColor Green }
			else { Write-Host "  · $key unchanged" -ForegroundColor DarkGray }
		}
		Write-Host ""
	}
	"Show" {
		Write-Host ""
		foreach ($key in $VARS.Keys) {
			$val = [Environment]::GetEnvironmentVariable($key, "Machine")
			$display = if ($VARS[$key]) { Mask $val } else { if ($val) { $val } else { "(not set)" } }
			Write-Host "  $($key.PadRight(24)) $display" -ForegroundColor $(if ($val) { "White" } else { "DarkGray" })
		}
		Write-Host ""
	}
	"Clear" {
		Assert-Admin
		foreach ($key in $VARS.Keys) {
			[Environment]::SetEnvironmentVariable($key, $null, "Machine")
			Write-Host "  ✔ Cleared $key" -ForegroundColor Green
		}
		Write-Host ""
	}
}
