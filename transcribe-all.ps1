#Requires -Version 5.1
<#
.SYNOPSIS
  Transcribe every audio file in pending\ (local GPU). Each file moves to done\ on success.
  Asks config once, applies the same to all pending files.
  Run with no args for step-by-step prompts, or pass args to skip prompts.
.EXAMPLE
  .\transcribe-all.ps1
  .\transcribe-all.ps1 -Lang en
  .\transcribe-all.ps1 -Lang hi -Model medium -BatchSize 2
  .\transcribe-all.ps1 -Lang en -Compress -Codec opus -CompressKbps 24
  .\transcribe-all.ps1 -Lang en -DetailTranscribe
  .\transcribe-all.ps1 -Lang en -Diarize -HfToken hf_xxx
#>
[CmdletBinding()]
param(
  [ValidateSet("en", "hi")]
  [string]$Lang = "en",

  [string]$Model = "medium",

  [int]$BatchSize = 4,

  [switch]$NoAlign,

  [switch]$Compress,

  [ValidateSet("opus", "mp3", "aac", "flac")]
  [string]$Codec = "opus",

  [ValidateRange(8, 320)]
  [int]$CompressKbps = 24,

  [switch]$DetailTranscribe,

  [switch]$Diarize,

  [string]$HfToken = "",

  [ValidateRange(0, 20)]
  [int]$MinSpeakers = 0,

  [ValidateRange(0, 20)]
  [int]$MaxSpeakers = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$Root = $PSScriptRoot
$Single = Join-Path $Root "transcribe.ps1"
$PendingDir = Join-Path $Root "pending"
$DoneDir = Join-Path $Root "done"
New-Item -ItemType Directory -Path $PendingDir -Force | Out-Null
New-Item -ItemType Directory -Path $DoneDir -Force | Out-Null

$asked = $false

if (-not $PSBoundParameters.ContainsKey("Lang")) {
  $asked = $true
  while ($true) {
    $l = Read-Host "Step 1/8 - Language for ALL files [en/hi] (default en)"
    if ([string]::IsNullOrWhiteSpace($l)) { $l = "en" }
    $l = $l.Trim().ToLower()
    if ($l -eq "en" -or $l -eq "hi") { $Lang = $l; break }
    Write-Host "Please type 'en' or 'hi'."
  }
}

if (-not $PSBoundParameters.ContainsKey("Model")) {
  $asked = $true
  $validModels = @("tiny", "base", "small", "medium", "large-v2", "large-v3")
  while ($true) {
    $m = Read-Host "Step 2/8 - Model for ALL files [tiny/base/small/medium/large-v2/large-v3] (default medium)"
    if ([string]::IsNullOrWhiteSpace($m)) { $m = "medium" }
    $m = $m.Trim().ToLower()
    if ($validModels -contains $m) { $Model = $m; break }
    Write-Host "Please pick one of: $($validModels -join '/')."
  }
}

if (-not $PSBoundParameters.ContainsKey("BatchSize")) {
  $asked = $true
  while ($true) {
    $b = Read-Host "Step 3/8 - Batch size for ALL files (default 4, use 2 if GPU runs out of memory)"
    if ([string]::IsNullOrWhiteSpace($b)) { $b = "4" }
    $n = 0
    if ([int]::TryParse($b.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 32) {
      $BatchSize = $n
      break
    }
    Write-Host "Please type a number 1-32."
  }
}

if (-not $PSBoundParameters.ContainsKey("NoAlign")) {
  $asked = $true
  $a = Read-Host "Step 4/8 - Skip word alignment for all? [Y/n]"
  if ($a -notmatch '^(n|no)$') { $NoAlign = $true }
}

if (-not $PSBoundParameters.ContainsKey("Compress")) {
  $asked = $true
  $c = Read-Host "Step 5/8 - Compress audio with ffmpeg first for ALL files? [y/N]"
  if ($c -match '^(y|yes)$') { $Compress = $true }
}

if ($Compress -and -not $PSBoundParameters.ContainsKey("Codec")) {
  $asked = $true
  $validCodecs = @("opus", "mp3", "aac", "flac")
  while ($true) {
    $cc = Read-Host "Step 6/8 - Codec for ALL files [opus/mp3/aac/flac] (default opus)"
    if ([string]::IsNullOrWhiteSpace($cc)) { $cc = "opus" }
    $cc = $cc.Trim().ToLower()
    if ($validCodecs -contains $cc) { $Codec = $cc; break }
    Write-Host "Please pick one of: $($validCodecs -join '/')."
  }
}

if ($Compress -and $Codec -ne "flac" -and -not $PSBoundParameters.ContainsKey("CompressKbps")) {
  $asked = $true
  while ($true) {
    $k = Read-Host "Step 6/8 - Bitrate kbps for ALL files (8-320, default 24)"
    if ([string]::IsNullOrWhiteSpace($k)) { $k = "24" }
    $n = 0
    if ([int]::TryParse($k.Trim(), [ref]$n) -and $n -ge 8 -and $n -le 320) {
      $CompressKbps = $n
      break
    }
    Write-Host "Please type a number 8-320."
  }
}

if (-not $PSBoundParameters.ContainsKey("DetailTranscribe")) {
  $asked = $true
  $d = Read-Host "Step 8/8 - Detail transcription for ALL files? (SRT/etc in folder, default TXT only) [y/N]"
  if ($d -match '^(y|yes)$') { $DetailTranscribe = $true }
}

if (-not $PSBoundParameters.ContainsKey("Diarize")) {
  $asked = $true
  $dz = Read-Host "Step 8/8 - Speaker diarization for ALL files? (needs HuggingFace token) [y/N]"
  if ($dz -match '^(y|yes)$') { $Diarize = $true }
}
if ($Diarize -and [string]::IsNullOrWhiteSpace($HfToken)) {
  $asked = $true
  $HfToken = Read-Host "Step 8/8 - HuggingFace token (one token used for all files)"
}
if ($Diarize -and -not $PSBoundParameters.ContainsKey("MinSpeakers")) {
  $asked = $true
  while ($true) {
    $sp = Read-Host "Step 8/8 - Min speakers for ALL files (0 = auto)"
    if ([string]::IsNullOrWhiteSpace($sp)) { $sp = "0" }
    $n = 0
    if ([int]::TryParse($sp.Trim(), [ref]$n) -and $n -ge 0 -and $n -le 20) {
      $MinSpeakers = $n
      break
    }
    Write-Host "Please type a number 0-20."
  }
}
if ($Diarize -and -not $PSBoundParameters.ContainsKey("MaxSpeakers")) {
  $asked = $true
  while ($true) {
    $sp = Read-Host "Step 8/8 - Max speakers for ALL files (0 = auto)"
    if ([string]::IsNullOrWhiteSpace($sp)) { $sp = "0" }
    $n = 0
    if ([int]::TryParse($sp.Trim(), [ref]$n) -and $n -ge 0 -and $n -le 20) {
      $MaxSpeakers = $n
      break
    }
    Write-Host "Please type a number 0-20."
  }
}
if ($Diarize -and $Model -match '^large') {
  Write-Warning "Diarization + $Model likely exceeds 6GB VRAM. Consider -Model medium -BatchSize 2."
}

$files = @(Get-ChildItem -LiteralPath $PendingDir -File |
    Where-Object { $_.Extension -match '^\.(wav|mp3|m4a|flac|ogg|opus)$' } |
  Sort-Object Name)

if ($files.Count -eq 0) {
  Write-Error "No audio files in pending\ (drop files into $PendingDir)"
  Read-Host "Press Enter to close" | Out-Null
  exit 1
}

Write-Host ""
Write-Host "Files ($($files.Count)): Lang=$Lang Model=$Model Batch=$BatchSize Align=$(if ($NoAlign) { 'skipped' } else { 'word-level' }) Compress=$(if ($Compress) { "$Codec $CompressKbps kbps" } else { 'off' }) Detail=$(if ($DetailTranscribe) { 'all formats' } else { 'txt-only' }) Diarize=$(if ($Diarize) { 'yes' } else { 'no' })"
foreach ($f in $files) {
  $mb = [math]::Round($f.Length / 1MB)
  Write-Host ("  - {0} ({1} MB)" -f $f.Name, $mb)
}
if ($asked) {
  $go = Read-Host "Start batch transcription? (each file moves pending\ -> done\ on success) [Y/n]"
  if ($go -match '^(n|no)$') {
    Write-Host "Cancelled."
    Read-Host "Press Enter to close" | Out-Null
    exit 0
  }
}

$ok = 0
$fail = 0
foreach ($f in $files) {
  Write-Host "===== $($f.Name) ====="
  $invokeArgs = @{
    Audio            = $f.FullName
    Lang             = $Lang
    Model            = $Model
    BatchSize        = $BatchSize
    NoAlign          = [bool]$NoAlign
    Compress         = [bool]$Compress
    Codec            = $Codec
    CompressKbps     = $CompressKbps
    DetailTranscribe = [bool]$DetailTranscribe
    Diarize          = [bool]$Diarize
    HfToken          = $HfToken
    MinSpeakers      = $MinSpeakers
    MaxSpeakers      = $MaxSpeakers
    NoPause          = $true
  }
  & $Single @invokeArgs
  if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail++ }
}

Write-Host "ALL DONE: $ok ok, $fail failed (failed files stay in pending\)."
Read-Host "Press Enter to close" | Out-Null
if ($fail -gt 0) { exit 1 }
