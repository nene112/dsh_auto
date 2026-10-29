#Requires -Version 5.1
<#
.SYNOPSIS
  Detect environment, install npm deps if needed, apply LAN patches, start DeepSeek Harness.

.DESCRIPTION
  Cross-machine bootstrap for this repo:
  - Checks Node.js / npm and downloads a private compatible Node runtime when needed
  - Prefers China-accessible Node/npm mirrors and falls back to official sources
  - Runs npm ci / npm install when node_modules is missing
  - Re-applies local UI patches after install
  - Optionally exposes the UI on Tailscale when -Tailscale is passed
  - Prints local + Tailscale URLs with the process token

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\start.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\start.ps1 -CheckOnly

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\start.ps1 -Tailscale
#>
[CmdletBinding()]
param(
  [int]$Port = $(if ($env:DSH_PORT) { [int]$env:DSH_PORT } else { 3080 }),
  [int]$TsHttpsPort = $(if ($env:DSH_TS_HTTPS_PORT) { [int]$env:DSH_TS_HTTPS_PORT } else { 8443 }),
  [ValidateSet("auto", "china", "official")]
  [string]$Mirror = $(if ($env:DSH_MIRROR) { $env:DSH_MIRROR } else { "auto" }),
  [string]$NodePrefix = $(if ($env:DSH_NODE_PREFIX) { $env:DSH_NODE_PREFIX } else { "" }),
  [switch]$CheckOnly,
  [switch]$ForceNode,
  [switch]$Tailscale
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
if (-not $NodePrefix) { $NodePrefix = Join-Path $PSScriptRoot ".runtime\node" }

# Official dsh: Node ^22.19.0 || >=24
$MinNodeMajor = 22
$MinNodeMinorIf22 = 19
$NodeMajorTarget = 24
$ChinaNodeMirror = "https://npmmirror.com/mirrors/node"
$OfficialNodeMirror = "https://nodejs.org/dist"
$ChinaNpmRegistry = "https://registry.npmmirror.com"
$OfficialNpmRegistry = "https://registry.npmjs.org"

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

function Test-HttpUrl([string]$Url, [int]$TimeoutSeconds = 8) {
  try {
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = "HEAD"
    $request.Timeout = $TimeoutSeconds * 1000
    $request.AllowAutoRedirect = $true
    $response = $request.GetResponse()
    try { return [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400 }
    finally { $response.Dispose() }
  } catch {
    return $false
  }
}

function Get-MirrorCandidates([string]$ChinaUrl, [string]$OfficialUrl) {
  switch ($Mirror) {
    "china" { return @($ChinaUrl, $OfficialUrl) }
    "official" { return @($OfficialUrl) }
    default { return @($ChinaUrl, $OfficialUrl) }
  }
}

function Invoke-DownloadWithFallback([string[]]$Urls, [string]$Destination) {
  foreach ($url in $Urls) {
    try {
      Write-Host "    download: $url" -ForegroundColor DarkGray
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $Destination -TimeoutSec 60
      return $url
    } catch {
      Write-WarnLine "download failed from $url"
      Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }
  }
  throw "All download sources failed: $($Urls -join ', ')"
}

function Add-PrivateNodeToPath {
  $bin = $NodePrefix
  if (Test-Path (Join-Path $bin "node.exe")) {
    $env:Path = "$bin;$env:Path"
  }
}

function Clear-OwnedNodePrefix {
  $full = [System.IO.Path]::GetFullPath($NodePrefix)
  $root = [System.IO.Path]::GetPathRoot($full)
  if ($full.TrimEnd('\') -eq $root.TrimEnd('\')) { throw "Refusing to use a drive root as NodePrefix: $full" }
  if (-not (Test-Path -LiteralPath $full)) { return }
  $marker = Join-Path $full ".dsh-auto-node-runtime"
  if (-not (Test-Path -LiteralPath $marker)) {
    throw "Refusing to replace non-owned directory $full. Choose an empty -NodePrefix or remove it yourself."
  }
  Remove-Item -LiteralPath $full -Recurse -Force
}

function Invoke-Native([string]$File, [string[]]$Arguments) {
  # Run a native tool without letting its stderr abort the script. npm 11 warns
  # about unknown .npmrc keys on every invocation, PowerShell 5.1 surfaces
  # native stderr as a NativeCommandError, and this script sets
  # ErrorActionPreference=Stop - so a mere warning killed the bootstrap right
  # after "Environment check" (exit 1). stdout streams through as it arrives,
  # stderr is dropped. Returns the exit code.
  $previous = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & $File @Arguments 2>&1 | ForEach-Object {
      if (-not ($_ -is [System.Management.Automation.ErrorRecord])) { Write-Host $_ }
    }
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
}

function Invoke-NativeQuiet([string]$File, [string[]]$Arguments) {
  # Same guard, for a call whose output does not matter: returns the exit code.
  $previous = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $null = & $File @Arguments 2>&1
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
}

function Get-NativeOutput([string]$File, [string[]]$Arguments) {
  # Same guard, for a call whose stdout is a value: returns its stdout lines.
  $previous = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    return @(& $File @Arguments 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
  } finally {
    $ErrorActionPreference = $previous
  }
}

function Get-NativeLine([string]$File, [string[]]$Arguments) {
  return (Get-NativeOutput $File $Arguments | Select-Object -Last 1)
}

function Get-NodeVersionParts {
  $raw = (Get-NativeLine "node" @("-v")).Trim().TrimStart("v")
  $parts = $raw.Split(".")
  return [pscustomobject]@{
    Raw = $raw
    Major = [int]$parts[0]
    Minor = [int]$parts[1]
  }
}

function Test-NodeVersion {
  if (-not (Test-Command node)) { return $false }
  $v = Get-NodeVersionParts
  $ok = ($v.Major -gt 22) -or ($v.Major -eq 22 -and $v.Minor -ge $MinNodeMinorIf22) -or ($v.Major -ge 24)
  # Also accept 23? Official says ^22.19 || >=24, so 23 is outside. Reject 23.
  if ($v.Major -eq 23) { $ok = $false }
  return $ok
}

function Install-PrivateNode {
  $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
    "X64" { "x64" }
    "Arm64" { "arm64" }
    default { throw "No supported Node.js Windows build for $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" }
  }
  $latestPath = "latest-v$NodeMajorTarget.x"
  $checksumName = "SHASUMS256.txt"
  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dsh-node-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  try {
    $checksumPath = Join-Path $tempRoot $checksumName
    $bases = Get-MirrorCandidates "$ChinaNodeMirror/$latestPath" "$OfficialNodeMirror/$latestPath"
    $checksumUrls = @($bases | ForEach-Object { "$_/$checksumName" })
    $usedChecksumUrl = Invoke-DownloadWithFallback $checksumUrls $checksumPath
    $line = Get-Content -LiteralPath $checksumPath | Where-Object { $_ -match "node-v[0-9.]+-win-$arch\.zip$" } | Select-Object -First 1
    if (-not $line) { throw "Could not find a win-$arch archive in $usedChecksumUrl" }
    $parts = $line -split '\s+', 2
    $expectedHash = $parts[0].Trim()
    $archiveName = $parts[1].Trim()
    $archivePath = Join-Path $tempRoot $archiveName
    $baseUsed = $usedChecksumUrl.Substring(0, $usedChecksumUrl.LastIndexOf('/'))
    $archiveUrls = @("$baseUsed/$archiveName")
    foreach ($base in $bases) {
      $candidate = "$base/$archiveName"
      if ($archiveUrls -notcontains $candidate) { $archiveUrls += $candidate }
    }
    $null = Invoke-DownloadWithFallback $archiveUrls $archivePath
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) { throw "Checksum mismatch for $archiveName" }
    $extractPath = Join-Path $tempRoot "extract"
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
    $sourceDir = Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1
    if (-not $sourceDir) { throw "Downloaded Node.js archive has no top-level directory" }
    Clear-OwnedNodePrefix
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $NodePrefix) | Out-Null
    Move-Item -LiteralPath $sourceDir.FullName -Destination $NodePrefix
    New-Item -ItemType File -Force -Path (Join-Path $NodePrefix ".dsh-auto-node-runtime") | Out-Null
  } finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  Add-PrivateNodeToPath
  if (-not (Test-NodeVersion)) { throw "Private Node.js install in $NodePrefix is unusable" }
  Write-Ok "Node.js $((Get-NativeLine 'node' @('-v'))) installed in $NodePrefix"
}

function Ensure-Node {
  Add-PrivateNodeToPath
  if ((Test-NodeVersion) -and -not $ForceNode) {
    Write-Ok "Node.js $((Get-NativeLine 'node' @('-v')))"
    return
  }
  if ($ForceNode -and (Test-NodeVersion)) { Write-WarnLine "private Node.js reinstall requested" }
  elseif (Test-Command node) { Write-WarnLine "Node.js $((Get-NativeLine 'node' @('-v'))) is outside ^22.19.0 or >=24.0.0" }
  else { Write-WarnLine "Node.js not found" }
  if ($CheckOnly) {
    Write-WarnLine "would install a private Node.js v$NodeMajorTarget runtime in $NodePrefix"
    return
  }
  Write-Step "Installing a private Node.js v$NodeMajorTarget runtime"
  Install-PrivateNode
}

function Configure-NpmRegistry {
  $candidates = Get-MirrorCandidates $ChinaNpmRegistry $OfficialNpmRegistry
  $selected = $null
  foreach ($candidate in $candidates) {
    if (Test-HttpUrl $candidate) { $selected = $candidate; break }
  }
  if (-not $selected) {
    $selected = $candidates[0]
    Write-WarnLine "npm registries did not answer the probe; installation will still try $selected"
  }
  $env:npm_config_registry = $selected
  Write-Ok "npm registry $selected (current run only)"
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
      $lsExit = Invoke-NativeQuiet "npm" @("ls", "@deepseek-ai/dsh", "--depth=0")
      if ($lsExit -ne 0) { $needInstall = $true }
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
      $ciExit = Invoke-Native "npm" @("ci", "--no-fund", "--no-audit")
      if ($ciExit -ne 0) {
        Write-WarnLine "npm ci failed; falling back to npm install"
        $null = Invoke-Native "npm" @("install", "--no-fund", "--no-audit")
      }
    } else {
      $null = Invoke-Native "npm" @("install", "--no-fund", "--no-audit")
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
  # Returns $true when the file carries the patch afterwards, $false when it
  # could not be applied (missing file or a pattern that moved upstream).
  if (-not (Test-Path $Path)) { Write-WarnLine "$Label missing (skip)"; return $false }
  $s = [System.IO.File]::ReadAllText($Path)
  if ($s.Contains($AlreadyMarker)) { Write-Ok "$Label already patched"; return $true }
  if (-not $s.Contains($Old)) { Write-WarnLine "$Label pattern changed upstream (skip)"; return $false }
  Write-Utf8NoBom $Path ($s.Replace($Old, $New))
  Write-Ok "patched $Label"
  return $true
}

# Re-verified against @deepseek-ai/dsh 0.2.1-rc.3 (2026-10-24). Each patch
# tries the 0.2.x spelling first and falls back to the 0.1.x one, so a version
# bump degrades to a reported SKIP instead of a silent no-op.
function Apply-LanPatches {
  Write-Step "Applying LAN / Tailscale patches..."
  $root = Join-Path $PSScriptRoot "node_modules\@deepseek-ai"
  $report = New-Object System.Collections.Generic.List[string]

  # Settings documents (the settings screen's read/write actions) are gated on
  # loopback. 0.2.x renamed the argument to ctx.configForms.describe().
  $settingsGeneral = Join-Path $root "dsh-client-ui-settings-general\lib\client.js"
  $ok = Patch-File $settingsGeneral `
    'const documentController = ctx.remote.$host.isLoopback ? new SettingsDocumentStore(ctx, ctx.configForms.describe()) : void 0;' `
    'const documentController = new SettingsDocumentStore(ctx, ctx.configForms.describe()); // LAN/Tailscale: enable settings document actions' `
    "LAN/Tailscale: enable settings document" "settings-general (0.2.x form)"
  if (-not $ok) {
    $ok = Patch-File $settingsGeneral `
      'const documentController = ctx.remote.$host.isLoopback ? new SettingsDocumentStore(ctx, ctx.settingsScope.describe()) : void 0;' `
      'const documentController = new SettingsDocumentStore(ctx, ctx.settingsScope.describe()); // LAN/Tailscale: enable settings document actions' `
      "LAN/Tailscale: enable settings document" "settings-general (0.1.x form)"
  }
  $report.Add("settings-general: " + $(if ($ok) { "applied" } else { "SKIPPED - check upstream" }))

  # Host-backed settings (models / credentials) used to fall back to memory off
  # loopback. 0.2.x has no isLoopback gate left in this file, so the patch is
  # obsolete there and this only succeeds on 0.1.x.
  $settings = Join-Path $root "dsh-client-ui-settings\lib\client.js"
  $ok2 = Patch-File $settings `
    'const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";' `
    'const persistence = "host"; // LAN/Tailscale: enable Host-backed settings (models/credentials)' `
    "LAN/Tailscale: enable Host-backed settings" "ui-settings (0.1.x form)"
  $report.Add("ui-settings: " + $(if ($ok2) { "applied" } else { "not needed on this version (upstream removed the loopback gate)" }))

  # A native file dialog cannot appear on the machine serving the page, so a
  # remote browser must get the in-page picker.
  $picker = Join-Path $root "dsh-host-directory-picker-auto\lib\index.js"
  $ok3 = Patch-File $picker `
    'if (facts.platform === "darwin" || facts.platform === "win32") return "native";' `
    'if (facts.platform === "darwin" || facts.platform === "win32") return "browse"; // Tailscale/LAN' `
    'return "browse"; // Tailscale/LAN' "directory-picker"
  $report.Add("directory-picker: " + $(if ($ok3) { "applied" } else { "SKIPPED - check upstream" }))

  # Blank "New Session" no-op: NOT applied. 0.2.x rewrote createInWorkspace -
  # `sessions` there is a list snapshot (no `.current`), and reusing a blank
  # member is deliberate upstream behaviour now. Re-deriving this needs a
  # runtime check of the New Session button while sitting in a blank session.
  $report.Add("workspace-new-session: NOT APPLIED (no equivalent in 0.2.x; verify the New Session button by hand)")

  foreach ($line in $report) { Write-Host ("     - " + $line) -ForegroundColor DarkGray }
}

function Get-TailscaleSelf {
  if (-not (Test-Command tailscale)) { return $null }
  try {
    $j = (Get-NativeOutput "tailscale" @("status", "--json") -join "`n") | ConvertFrom-Json
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

function Assert-NativeDeps {
  # npm 11 gates dependency install scripts behind approval ("allow-scripts").
  # node-pty and koffi are native, so a tree installed without those scripts
  # looks fine and then fails later inside the UI. Probe it and repair it here.
  $probe = Invoke-NativeQuiet "node" @("-e", "require('node-pty');require('koffi')")
  if ($probe -eq 0) { Write-Ok "native modules load (node-pty, koffi)"; return }
  Write-WarnLine "native modules do not load; approving install scripts and rebuilding"
  $null = Invoke-NativeQuiet "npm" @("approve-scripts", "--all")
  $rebuild = Invoke-NativeQuiet "npm" @("rebuild")
  if ($rebuild -ne 0) { Write-WarnLine "npm rebuild exited $rebuild" }
  $again = Invoke-NativeQuiet "node" @("-e", "require('node-pty');require('koffi')")
  if ($again -eq 0) { Write-Ok "native modules rebuilt" }
  else { Write-WarnLine "native modules still fail to load; terminal features may be unavailable" }
}

function Stop-PortListener([int]$ListenPort) {
  Get-NetTCPConnection -LocalPort $ListenPort -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique |
    ForEach-Object { if ($_ -and $_ -ne 0) { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }
}

# --- main ---
Write-Step "Environment check"
Write-Ok "Windows $([System.Environment]::OSVersion.Version) / PowerShell $($PSVersionTable.PSVersion) / $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
Ensure-Node
Configure-NpmRegistry
if ($CheckOnly) {
  if (Test-Command npm) { Write-Ok "npm $(Get-NativeLine 'npm' @('-v'))" } else { Write-WarnLine "npm unavailable until Node.js is installed" }
  if ($Tailscale) { Write-Host "Tailscale requested; it will be checked during a normal run." -ForegroundColor DarkGray }
  else { Write-Ok "Tailscale disabled by default" }
  Write-Step "Check-only run finished (nothing was installed, patched or started)"
  exit 0
}
if (-not (Test-Command npm)) { throw "npm not found after Node.js setup." }
Write-Ok "npm $(Get-NativeLine 'npm' @('-v'))"

$dshJs = Ensure-NpmDeps
Assert-NativeDeps
Apply-LanPatches

$trusted = New-Object System.Collections.Generic.List[string]
$ts = if ($Tailscale) { Get-TailscaleSelf } else { $null }
if ($Tailscale -and $null -ne $ts) {
  Write-Ok "Tailscale $($ts.DnsName) ($($ts.IPv4))"
  Write-Step "Exposing port $Port on Tailscale HTTPS :$TsHttpsPort (root :443 unchanged)"
  $serveExit = Invoke-Native "tailscale" @("serve", "--bg", "--https=$TsHttpsPort", "--yes", "$Port")
  if ($serveExit -ne 0) { Write-WarnLine "tailscale serve exited $serveExit; check 'tailscale serve status'" }
  foreach ($h in @($ts.DnsName, "$($ts.DnsName):443", "$($ts.DnsName):$TsHttpsPort", $ts.IPv4, "$($ts.IPv4):$Port", "$($ts.IPv4):$TsHttpsPort")) {
    $trusted.Add($h) | Out-Null
  }
} elseif ($Tailscale) {
  Write-WarnLine "Tailscale was requested but is unavailable; continuing on 127.0.0.1 only."
} else {
  Write-Ok "Tailscale disabled (pass -Tailscale to enable it)"
}

Write-Step "Starting dsh web on 127.0.0.1:$Port"
Stop-PortListener $Port
Start-Sleep -Seconds 1

$argsList = @($dshJs, "web", "--no-open", "--port", "$Port")
foreach ($h in $trusted) {
  $argsList += @("--trusted-host", $h)
}

# 0.2.x authenticates every request, loopback included: the process prints
# "dsh web: <url>?token=<launch token>", a plain visit answers 401, and the
# token URL mints a 30-day signed cookie scoped to that authority. So the
# first visit from every device must carry the token - capture it here and
# print ready-to-paste URLs instead of leaving the user to find that line.
$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logPath = Join-Path $logDir "dsh-web-$Port.out.log"
$errPath = Join-Path $logDir "dsh-web-$Port.err.log"
Remove-Item $logPath, $errPath -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath "node" -ArgumentList $argsList -NoNewWindow -PassThru `
  -RedirectStandardOutput $logPath -RedirectStandardError $errPath

$readyUrl = $null
for ($i = 0; $i -lt 90; $i++) {
  Start-Sleep -Seconds 1
  if ($proc.HasExited) { break }
  $text = Get-Content $logPath -Raw -ErrorAction SilentlyContinue
  if ($text -match 'dsh web: (\S+)') { $readyUrl = $Matches[1]; break }
}

if ($null -eq $readyUrl) {
  Write-WarnLine "no 'dsh web:' line after 90s; see $logPath and $errPath"
  if (Test-Path $errPath) { Get-Content $errPath | Select-Object -Last 15 | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor DarkGray } }
} else {
  $token = if ($readyUrl -match 'token=([^&\s]+)') { $Matches[1] } else { $null }
  $probe = & curl.exe -s -o NUL -w "%{http_code}" --max-time 10 "http://127.0.0.1:$Port/" 2>$null
  Write-Host ""
  Write-Host "dsh is up (pid $($proc.Id)); a token-less visit to / answers $probe (401 = 0.2.x auth is on, 200 = 0.1.x)." -ForegroundColor DarkGray
  if ($null -ne $token) {
    Write-Host ""
    Write-Host "FIRST visit from each device must carry the token; afterwards a 30-day cookie carries you." -ForegroundColor Yellow
    if ($null -ne $ts) {
      Write-Host ("  other machines : https://$($ts.DnsName):$TsHttpsPort/?token=$token") -ForegroundColor Yellow
    }
    Write-Host ("  this machine   : http://127.0.0.1:$Port/?token=$token") -ForegroundColor Yellow
    Write-Host ""
    Write-Host "The token is regenerated on every start (an existing cookie keeps working)." -ForegroundColor DarkGray
  } else {
    Write-Host "No token in the ready line (0.1.x style): open http://127.0.0.1:$Port/ directly." -ForegroundColor DarkGray
  }
  Write-Host "Logs: $logPath" -ForegroundColor DarkGray
  Write-Host ""
}

# Foreground wait so Ctrl+C stops the server as before.
$proc.WaitForExit()
exit $proc.ExitCode
