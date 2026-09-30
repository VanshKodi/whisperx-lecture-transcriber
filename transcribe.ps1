#Requires -Version 5.1
<#
.SYNOPSIS
  Transcribe one audio file locally on GPU (RTX 4050, project .venv, py3.11).
  Run with no args for step-by-step prompts, or pass args to skip prompts.
  Picks audio from pending\ and moves it to done\ after successful transcription.
.EXAMPLE
  .\transcribe.ps1
  .\transcribe.ps1 -Audio DS.wav
  .\transcribe.ps1 -Audio DS.wav -Lang en
  .\transcribe.ps1 -Audio FM.wav -Lang hi
  .\transcribe.ps1 -Audio FM.wav -Lang en -NoAlign
#>
[CmdletBinding()]
param(
  [string]$Audio = "",

  [ValidateSet("en", "hi")]
  [string]$Lang = "en",

  [string]$Model = "medium",

  [int]$BatchSize = 4,

  [string]$ComputeType = "float16",

  [string]$Device = "cuda",

  [switch]$NoAlign
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
$PendingDir = Join-Path $Root "pending"
$DoneDir = Join-Path $Root "done"
New-Item -ItemType Directory -Path $PendingDir -Force | Out-Null
New-Item -ItemType Directory -Path $DoneDir -Force | Out-Null

# --- Crash-proof logging: console output also goes to logs\... ---
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$script:LogFile = Join-Path $LogDir ("transcribe-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
try { Start-Transcript -Path $script:LogFile -Append -ErrorAction Stop | Out-Null } catch { }

function Stop-Log {
  try { Stop-Transcript | Out-Null } catch { }
  if ($asked) {
    Write-Host ""
    Write-Host "Log saved: $($script:LogFile)"
    Read-Host "Press Enter to close" | Out-Null
  }
}

$Whisperx = Join-Path $Root ".venv\Scripts\whisperx.exe"
if (-not (Test-Path -LiteralPath $Whisperx)) {
  Write-Error "whisperx not found at $Whisperx. Run the install block first."
  exit 1
}

$asked = $false

# --- Step 1/5: audio file (from pending\) ---
if ([string]::IsNullOrWhiteSpace($Audio)) {
  $asked = $true
  $cands = @(Get-ChildItem -LiteralPath $PendingDir -File |
    Where-Object { $_.Extension -match '^\.(wav|mp3|m4a|flac|ogg)$' } |
    Sort-Object Name)
  if ($cands.Count -eq 0) {
    Write-Error "No audio files in pending\ (drop files into $PendingDir)"
    exit 1
  }
  Write-Host "Step 1/5 - Pick audio (from pending\):"
  for ($i = 0; $i -lt $cands.Count; $i++) {
    $mb = [math]::Round($cands[$i].Length / 1MB)
    Write-Host ("  [{0}] {1} ({2} MB)" -f ($i + 1), $cands[$i].Name, $mb)
  }
  $pick = Read-Host "Number or path (default 1)"
  if ([string]::IsNullOrWhiteSpace($pick)) { $pick = "1" }
  $num = 0
  if ([int]::TryParse($pick, [ref]$num) -and $num -ge 1 -and $num -le $cands.Count) {
    $Audio = $cands[$num - 1].FullName
  } else {
    $Audio = $pick
  }
}

$AudioPath = $Audio
if (-not [System.IO.Path]::IsPathRooted($AudioPath)) {
  $AudioPath = Join-Path $PendingDir $AudioPath
}
if (-not (Test-Path -LiteralPath $AudioPath)) {
  Write-Error "Audio not found: $AudioPath"
  exit 1
}
$Base = [System.IO.Path]::GetFileNameWithoutExtension($AudioPath)

# --- Step 2/5: language ---
if (-not $PSBoundParameters.ContainsKey("Lang")) {
  $asked = $true
  $validLangs = @("en", "hi")
  while ($true) {
    $l = Read-Host "Step 2/5 - Language [en/hi] (default en)"
    if ([string]::IsNullOrWhiteSpace($l)) { $l = "en" }
    $l = $l.Trim().ToLower()
    if ($validLangs -contains $l) { $Lang = $l; break }
    Write-Host "Please type 'en' or 'hi'."
  }
}

# --- Step 3/5: model ---
if (-not $PSBoundParameters.ContainsKey("Model")) {
  $asked = $true
  $validModels = @("tiny", "base", "small", "medium", "large-v2", "large-v3")
  while ($true) {
    $m = Read-Host "Step 3/5 - Model [tiny/base/small/medium/large-v2/large-v3] (default medium)"
    if ([string]::IsNullOrWhiteSpace($m)) { $m = "medium" }
    $m = $m.Trim().ToLower()
    if ($validModels -contains $m) { $Model = $m; break }
    Write-Host "Please pick one of: $($validModels -join '/')."
  }
}

# --- Step 4/5: batch size ---
if (-not $PSBoundParameters.ContainsKey("BatchSize")) {
  $asked = $true
  while ($true) {
    $b = Read-Host "Step 4/5 - Batch size (default 4, use 2 if GPU runs out of memory)"
    if ([string]::IsNullOrWhiteSpace($b)) { $b = "4" }
    $n = 0
    if ([int]::TryParse($b.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 32) {
      $BatchSize = $n
      break
    }
    Write-Host "Please type a number 1-32."
  }
}

# --- Step 5/5: alignment ---
if (-not $PSBoundParameters.ContainsKey("NoAlign")) {
  $asked = $true
  $a = Read-Host "Step 5/5 - Skip word alignment? (faster, sentence timings only) [Y/n]"
  if ($a -notmatch '^(n|no)$') { $NoAlign = $true }
}

$Suffix = ""
if ($Lang -ne "en") { $Suffix += "-$Lang" }
if ($NoAlign) { $Suffix += "-noalign" }
$Stamp = Get-Date -Format "dd_MMM"
$OutDir = Join-Path (Join-Path $Root "transcripts") ($Base + $Suffix + "-" + $Stamp)
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

if ($asked) {
  Write-Host ""
  Write-Host "Summary:"
  Write-Host "  Audio:  $AudioPath"
  Write-Host "  Lang:   $Lang"
  Write-Host "  Model:  $Model"
  Write-Host "  Batch:  $BatchSize"
  Write-Host "  Align:  $(if ($NoAlign) { 'skipped' } else { 'word-level' })"
  Write-Host "  Out:    $OutDir"
  Write-Host "  After:  file moves pending\ -> done\"
  $go = Read-Host "Start transcription? [Y/n]"
  if ($go -match '^(n|no)$') {
    Write-Host "Cancelled."
    Stop-Log
    exit 0
  }
}

$wxArgs = @(
  $AudioPath,
  "--model", $Model,
  "--language", $Lang,
  "--device", $Device,
  "--compute_type", $ComputeType,
  "--batch_size", "$BatchSize",
  "--output_dir", $OutDir,
  "--verbose", "False",
  "--print_progress", "True",
  "--log-level", "warning"
)
if ($NoAlign) { $wxArgs += "--no_align" }

Write-Host "CMD: whisperx $($wxArgs -join ' ')"
$env:PYTHONWARNINGS = "ignore"
& $Whisperx @wxArgs | ForEach-Object {
  if ($_ -match 'Progress:\s*([\d.]+)%') {
    $pct = [int][math]::Floor([double]$Matches[1])
    if ($pct -gt 100) { $pct = 100 }
    Write-Progress -Activity "Transcribing $Base" -Status ("{0}%..." -f $pct) -PercentComplete $pct
  } else {
    Write-Host $_
  }
}
$code = $LASTEXITCODE
Write-Progress -Activity "Transcribing $Base" -Completed
if ($code -ne 0) {
  Write-Error "whisperx failed with exit code $code (file stays in pending\)"
  exit $code
}

# --- date-stamp transcript filenames ---
Get-ChildItem -LiteralPath $OutDir -File | ForEach-Object {
  $newName = "{0}{1}-{2}{3}" -f $Base, $Suffix, $Stamp, $_.Extension
  if ($_.Name -ne $newName) { Rename-Item -LiteralPath $_.FullName -NewName $newName }
}
Write-Host "DONE. Outputs:"
Get-ChildItem -LiteralPath $OutDir | Format-Table Name, Length

# --- pending\ -> done\ (only on success, date-stamped) ---
try {
  $dest = Join-Path $DoneDir ("{0}-{1}{2}" -f $Base, $Stamp, [System.IO.Path]::GetExtension($AudioPath))
  if ($AudioPath -ne $dest) {
    Move-Item -LiteralPath $AudioPath -Destination $dest -Force -ErrorAction Stop
    Write-Host "Moved to done: $dest"
  }
} catch {
  Write-Warning "Transcription succeeded but move to done\ failed: $($_.Exception.Message)"
}
Stop-Log
