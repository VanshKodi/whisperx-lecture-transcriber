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
  & $VenvPython -c "import torch; print(torch.__version__, torch.cuda.is_available())"
  & $VenvWhisperx --help | Select-Object -First 5

  Write-Host ""
  Write-Host "SETUP DONE. Run: .\transcribe.ps1"
  Write-Host "Log: $LogFile"
} finally {
  try { Stop-Transcript | Out-Null } catch { }
}
