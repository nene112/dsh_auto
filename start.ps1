#Requires -Version 5.1
<#
.SYNOPSIS
  Detect environment, install npm deps if needed, apply LAN patches, start DeepSeek Harness.

.DESCRIPTION
  Cross-machine bootstrap for this repo:
  - Checks Node.js / npm (offers winget install if missing on Windows)
  - Runs npm ci / npm install when node_modules is missing
  - Re-applies local UI patches after install
  - Optionally exposes the UI on Tailscale :8443 (leaves :443 free)
  - Prints local + Tailscale URLs with the process token

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\start.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$Port = if ($env:DSH_PORT) { [int]$env:DSH_PORT } else { 3080 }
$TsHttpsPort = if ($env:DSH_TS_HTTPS_PORT) { [int]$env:DSH_TS_HTTPS_PORT } else { 8443 }
# Official dsh: Node ^22.19.0 || >=24
$MinNodeMajor = 22
$MinNodeMinorIf22 = 19

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "OK  $Message" -ForegroundColor Green }
function Write-WarnLine([string]$Message) { Write-Host "WARN $Message" -ForegroundColor Yellow }

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Test-Command([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-NodeVersionParts {
  $raw = (& node -v).Trim().TrimStart("v")
  $parts = $raw.Split(".")
  return [pscustomobject]@{
    Raw = $raw
    Major = [int]$parts[0]
    Minor = [int]$parts[1]
  }
}

function Assert-NodeVersion {
  $v = Get-NodeVersionParts
  $ok = ($v.Major -gt 22) -or ($v.Major -eq 22 -and $v.Minor -ge $MinNodeMinorIf22) -or ($v.Major -ge 24)
  # Also accept 23? Official says ^22.19 || >=24, so 23 is outside. Reject 23.
  if ($v.Major -eq 23) { $ok = $false }
  if (-not $ok) {
    throw "Node.js v$($v.Raw) is too old. Need ^22.19.0 or >=24.0.0 (see https://nodejs.org/)."
  }
  Write-Ok "Node.js v$($v.Raw)"
}

function Install-NodeIfMissing {
  if (Test-Command node) { return }
  Write-WarnLine "Node.js not found."
  if ($env:OS -match "Windows") {
    if (Test-Command winget) {
      Write-Step "Installing Node.js LTS via winget..."
      winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
      $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
        [System.Environment]::GetEnvironmentVariable("Path", "User")
      if (-not (Test-Command node)) {
        throw "Node.js installed but not on PATH in this shell. Open a new PowerShell and re-run start.ps1."
      }
      return
    }
  }
  throw "Install Node.js ^22.19 or >=24 from https://nodejs.org/ then re-run start.ps1."
}

function Ensure-NpmDeps {
  $dshJs = Join-Path $PSScriptRoot "node_modules\@deepseek-ai\dsh\lib\bin.js"
  $lock = Join-Path $PSScriptRoot "package-lock.json"
  $pkg = Join-Path $PSScriptRoot "package.json"
  if (-not (Test-Path $pkg)) { throw "Missing package.json in $PSScriptRoot" }

  $needInstall = -not (Test-Path $dshJs)
  if (-not $needInstall) {
    try {
      Push-Location $PSScriptRoot
      $null = & npm ls @deepseek-ai/dsh --depth=0 2>$null
      if ($LASTEXITCODE -ne 0) { $needInstall = $true }
    } finally {
      Pop-Location
    }
  }

  if (-not $needInstall) {
    Write-Ok "Dependencies present (@deepseek-ai/dsh)"
    return $dshJs
  }

  Write-Step "Installing npm dependencies..."
  Push-Location $PSScriptRoot
  try {
    if (Test-Path $lock) {
      & npm ci --no-fund --no-audit
      if ($LASTEXITCODE -ne 0) {
        Write-WarnLine "npm ci failed; falling back to npm install"
        & npm install --no-fund --no-audit
      }
    } else {
      & npm install --no-fund --no-audit
    }
    if ($LASTEXITCODE -ne 0) { throw "npm install failed (exit $LASTEXITCODE)" }
  } finally {
    Pop-Location
  }

  if (-not (Test-Path $dshJs)) { throw "Install finished but missing $dshJs" }
  Write-Ok "Dependencies installed"
  return $dshJs
}

function Patch-File([string]$Path, [string]$Old, [string]$New, [string]$AlreadyMarker, [string]$Label) {
  if (-not (Test-Path $Path)) { Write-WarnLine "$Label missing (skip)"; return }
  $s = [System.IO.File]::ReadAllText($Path)
  if ($s.Contains($AlreadyMarker)) { Write-Ok "$Label already patched"; return }
  if (-not $s.Contains($Old)) { Write-WarnLine "$Label pattern changed upstream (skip)"; return }
  Write-Utf8NoBom $Path ($s.Replace($Old, $New))
  Write-Ok "patched $Label"
}

function Apply-LanPatches {
  Write-Step "Applying LAN / Tailscale patches..."
  $root = Join-Path $PSScriptRoot "node_modules\@deepseek-ai"
  Patch-File (Join-Path $root "dsh-client-ui-workspace\lib\client.js") `
    "if (summary !== void 0 && summary.blank && summary.cwd === workspace.path && workspace.sessionIds.includes(summary.id) && !archived.includes(summary.id)) return summary.id;" `
    "if (summary !== void 0 && summary.blank && id !== sessions.current && summary.cwd === workspace.path && workspace.sessionIds.includes(summary.id) && !archived.includes(summary.id)) return summary.id; // fix blank New Session no-op" `
    "fix blank New Session no-op" "workspace-new-session"

  Patch-File (Join-Path $root "dsh-client-ui-settings\lib\client.js") `
    'const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";' `
    'const persistence = "host"; // LAN/Tailscale: enable Host-backed settings (models/credentials)' `
    "LAN/Tailscale: enable Host-backed settings" "ui-settings"

  Patch-File (Join-Path $root "dsh-client-ui-settings-general\lib\client.js") `
    'const documentController = ctx.remote.$host.isLoopback ? new SettingsDocumentStore(ctx, ctx.settingsScope.describe()) : void 0;' `
    'const documentController = new SettingsDocumentStore(ctx, ctx.settingsScope.describe()); // LAN/Tailscale: enable settings document actions' `
    "LAN/Tailscale: enable settings document" "ui-settings-general"

  Patch-File (Join-Path $root "dsh-host-directory-picker-auto\lib\index.js") `
    'if (facts.platform === "darwin" || facts.platform === "win32") return "native";' `
    'if (facts.platform === "darwin" || facts.platform === "win32") return "browse"; // Tailscale/LAN' `
    'return "browse"; // Tailscale/LAN' "directory-picker"
}

function Get-TailscaleSelf {
  if (-not (Test-Command tailscale)) { return $null }
  try {
    $j = & tailscale status --json 2>$null | ConvertFrom-Json
    if (-not $j.Self) { return $null }
    $dns = [string]$j.Self.DNSName
    if ($dns.EndsWith(".")) { $dns = $dns.TrimEnd(".") }
    $ip4 = @($j.Self.TailscaleIPs | Where-Object { $_ -notmatch ":" } | Select-Object -First 1)
    if (-not $dns -or -not $ip4) { return $null }
    return [pscustomobject]@{ DnsName = $dns; IPv4 = [string]$ip4[0] }
  } catch {
    return $null
  }
}

function Stop-PortListener([int]$ListenPort) {
  Get-NetTCPConnection -LocalPort $ListenPort -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique |
    ForEach-Object { if ($_ -and $_ -ne 0) { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }
}

# --- main ---
Write-Step "Environment check"
Install-NodeIfMissing
if (-not (Test-Command npm)) { throw "npm not found on PATH (should ship with Node.js)." }
Write-Ok "npm $((& npm -v).Trim())"
Assert-NodeVersion

$dshJs = Ensure-NpmDeps
Apply-LanPatches

$trusted = New-Object System.Collections.Generic.List[string]
$ts = Get-TailscaleSelf
if ($null -ne $ts) {
  Write-Ok "Tailscale $($ts.DnsName) ($($ts.IPv4))"
  Write-Step "Exposing port $Port on Tailscale HTTPS :$TsHttpsPort (root :443 unchanged)"
  & tailscale serve --bg --https=$TsHttpsPort --yes $Port | Out-Null
  foreach ($h in @($ts.DnsName, "$($ts.DnsName):443", "$($ts.DnsName):$TsHttpsPort", $ts.IPv4, "$($ts.IPv4):$Port", "$($ts.IPv4):$TsHttpsPort")) {
    $trusted.Add($h) | Out-Null
  }
} else {
  Write-WarnLine "Tailscale not available — local-only bind (127.0.0.1). Install Tailscale for LAN access."
}

Write-Step "Starting dsh web on 127.0.0.1:$Port"
Stop-PortListener $Port
Start-Sleep -Seconds 1

$argsList = @($dshJs, "web", "--no-open", "--port", "$Port")
foreach ($h in $trusted) {
  $argsList += @("--trusted-host", $h)
}

Write-Host "After start, open the printed token URL." -ForegroundColor DarkGray
if ($null -ne $ts) {
  Write-Host "Tailscale UI base: https://$($ts.DnsName):$TsHttpsPort/?token=..." -ForegroundColor DarkGray
}
Write-Host "Local UI base:      http://127.0.0.1:$Port/?token=..." -ForegroundColor DarkGray
Write-Host ""

& node @argsList
exit $LASTEXITCODE
