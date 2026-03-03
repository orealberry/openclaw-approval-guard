$ErrorActionPreference = 'Stop'

$RepoUrl = 'https://github.com/orealberry/openclaw-approval-guard.git'
$WorkDir = Join-Path $env:TEMP ("openclaw-approval-guard-install-" + [System.Guid]::NewGuid().ToString("N"))

function Need-Cmd($name) {
  return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

Write-Host "[1/5] Checking dependencies..."
if (-not (Need-Cmd git)) { throw "git is required" }

Write-Host "[2/5] Checking Rust..."
if (-not (Need-Cmd cargo)) {
  Write-Host "Rust not found. Install from https://rustup.rs first, then rerun."
  throw "cargo not found"
}

Write-Host "[3/5] Cloning repository..."
if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
git clone --depth 1 $RepoUrl $WorkDir | Out-Null

Write-Host "[4/5] Building release binary..."
Push-Location $WorkDir
cargo build --release

Write-Host "[5/5] Installing binary and running installer..."
$BinDir = Join-Path $HOME ".local\bin"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
Copy-Item ".\target\release\openclaw-approval-guard.exe" (Join-Path $BinDir "openclaw-approval-guard.exe") -Force

if (-not $env:APPROVAL_BOT_TOKEN) {
  $secure = Read-Host "Enter APPROVAL_BOT_TOKEN"
  $env:APPROVAL_BOT_TOKEN = $secure
}

& (Join-Path $BinDir "openclaw-approval-guard.exe") install
Pop-Location

Write-Host "Done."
Write-Host "Run: openclaw-approval-guard run \"sudo id\""
