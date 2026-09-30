#Requires -Version 5.1
<#
.SYNOPSIS
  One-click setup: creates .venv (py 3.11) + installs GPU torch (cu128) + requirements.
.EXAMPLE
  .\setup.ps1
  .\setup.ps1 -Force
#>
[CmdletBinding()]
param(
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
$VenvDir = Join-Path $Root ".venv"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
$VenvWhisperx = Join-Path $VenvDir "Scripts\whisperx.exe"
$ReqFile = Join-Path $Root "requirements.txt"

# --- log to logs\ (ignored by git) ---
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ("setup-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
try { Start-Transcript -Path $LogFile -Append -ErrorAction Stop | Out-Null } catch { }

try {
  # --- ffmpeg preflight (whisperx needs ffmpeg.exe on PATH, not bundled) ---
  $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($ffmpeg) {
    Write-Host ("ffmpeg found: {0}" -f $ffmpeg.Source)
    & ffmpeg -version | Select-Object -First 1
  } else {
    Write-Host ""
    Write-Host "ERROR: ffmpeg not found on PATH. WhisperX requires it (not bundled with pip)."
    Write-Host ""
    Write-Host "Install via winget (recommended):"
    Write-Host "  winget install Gyan.FFmpeg"
    Write-Host ""
    Write-Host "Or manual install:"
    Write-Host "  1. Download from https://www.gyan.dev/ffmpeg/builds/ (ffmpeg-release-full.7z)"
    Write-Host "  2. Extract, add the bin\ folder to PATH:"
    Write-Host '     [Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\ffmpeg\bin", "User")'
    Write-Host "  3. Close + reopen PowerShell, verify with: where.exe ffmpeg"
    Write-Host "  4. Re-run: .\setup.ps1"
    Write-Host ""
    throw "ffmpeg missing - install it, restart PowerShell, re-run setup."
  }

  if ($Force -and (Test-Path -LiteralPath $VenvDir)) {
    Write-Host "Removing old .venv (--Force)..."
    Remove-Item -LiteralPath $VenvDir -Recurse -Force
  }

  if (-not (Test-Path -LiteralPath $VenvPython)) {
    Write-Host "Creating .venv with py -3.11..."
    & py -3.11 -m venv $VenvDir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $VenvPython)) {
      throw "venv creation failed. Is Python 3.11 installed? Try: py --list"
    }
  } else {
    Write-Host ".venv already exists, reusing."
  }

  Write-Host "Upgrading pip..."
  & $VenvPython -m pip install --upgrade pip

  Write-Host "Installing GPU torch (cu128, ~2-3 GB, takes a while)..."
  & $VenvPython -m pip install "torch~=2.8.0" "torchaudio~=2.8.0" "torchvision~=0.23.0" --index-url https://download.pytorch.org/whl/cu128
  if ($LASTEXITCODE -ne 0) { throw "torch install failed" }

  Write-Host "Installing requirements.txt..."
  & $VenvPython -m pip install -r $ReqFile
  if ($LASTEXITCODE -ne 0) { throw "requirements install failed" }

  Write-Host "Verifying..."
  & ffmpeg -version | Select-Object -First 1
  & $VenvPython -c "import torch; print(torch.__version__, torch.cuda.is_available())"
  & $VenvWhisperx --help | Select-Object -First 5

  Write-Host ""
  Write-Host "SETUP DONE. Run: .\transcribe.ps1"
  Write-Host "Log: $LogFile"
  Read-Host "Press Enter to close" | Out-Null
} catch {
  Write-Host ""
  Write-Host ("SETUP FAILED: {0}" -f $_.Exception.Message)
  Read-Host "Press Enter to close" | Out-Null
  exit 1
} finally {
  try { Stop-Transcript | Out-Null } catch { }
}
