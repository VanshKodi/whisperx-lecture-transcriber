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
  .\transcribe.ps1 -Audio DS.wav -Compress -Codec opus -CompressKbps 24
  .\transcribe.ps1 -Audio DS.wav -DetailTranscribe
  .\transcribe.ps1 -Audio DS.wav -Diarize -HfToken hf_xxx
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
  [int]$MaxSpeakers = 0,

  # internal: set by transcribe-all.ps1 so batch runs don't pause per file
  [switch]$NoPause
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
  if (-not $NoPause) {
    Write-Host ""
    Write-Host "Log saved: $($script:LogFile)"
    Read-Host "Press Enter to close" | Out-Null
  }
}

$Whisperx = Join-Path $Root ".venv\Scripts\whisperx.exe"
if (-not (Test-Path -LiteralPath $Whisperx)) {
  Write-Error "whisperx not found at $Whisperx. Run the install block first."
  Stop-Log; exit 1
}

$asked = $false

# --- Step 1/8: audio file (from pending\) ---
if ([string]::IsNullOrWhiteSpace($Audio)) {
  $asked = $true
  $cands = @(Get-ChildItem -LiteralPath $PendingDir -File |
    Where-Object { $_.Extension -match '^\.(wav|mp3|m4a|flac|ogg|opus)$' } |
    Sort-Object Name)
  if ($cands.Count -eq 0) {
    Write-Error "No audio files in pending\ (drop files into $PendingDir)"
    Stop-Log; exit 1
  }
  Write-Host "Step 1/8 - Pick audio (from pending\):"
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
  Stop-Log; exit 1
}
$Base = [System.IO.Path]::GetFileNameWithoutExtension($AudioPath)
# date stamp from the audio file's modified date, falls back to today
$FileDate = $null
try {
  $FileDate = (Get-Item -LiteralPath $AudioPath).LastWriteTime
} catch { }
if (-not $FileDate) { $FileDate = Get-Date }
# short name for outputs: first 15 chars (date goes first in final names)
$ShortBase = $Base
if ($ShortBase.Length -gt 15) { $ShortBase = $ShortBase.Substring(0, 15).TrimEnd() }

# --- Step 2/8: language ---
if (-not $PSBoundParameters.ContainsKey("Lang")) {
  $asked = $true
  $validLangs = @("en", "hi")
  while ($true) {
    $l = Read-Host "Step 2/8 - Language [en/hi] (default en)"
    if ([string]::IsNullOrWhiteSpace($l)) { $l = "en" }
    $l = $l.Trim().ToLower()
    if ($validLangs -contains $l) { $Lang = $l; break }
    Write-Host "Please type 'en' or 'hi'."
  }
}

# --- Step 3/8: model ---
if (-not $PSBoundParameters.ContainsKey("Model")) {
  $asked = $true
  $validModels = @("tiny", "base", "small", "medium", "large-v2", "large-v3")
  while ($true) {
    $m = Read-Host "Step 3/8 - Model [tiny/base/small/medium/large-v2/large-v3] (default medium)"
    if ([string]::IsNullOrWhiteSpace($m)) { $m = "medium" }
    $m = $m.Trim().ToLower()
    if ($validModels -contains $m) { $Model = $m; break }
    Write-Host "Please pick one of: $($validModels -join '/')."
  }
}

# --- Step 4/8: batch size ---
if (-not $PSBoundParameters.ContainsKey("BatchSize")) {
  $asked = $true
  while ($true) {
    $b = Read-Host "Step 4/8 - Batch size (default 4, use 2 if GPU runs out of memory)"
    if ([string]::IsNullOrWhiteSpace($b)) { $b = "4" }
    $n = 0
    if ([int]::TryParse($b.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 32) {
      $BatchSize = $n
      break
    }
    Write-Host "Please type a number 1-32."
  }
}

# --- Step 5/8: alignment ---
if (-not $PSBoundParameters.ContainsKey("NoAlign")) {
  $asked = $true
  $a = Read-Host "Step 5/8 - Skip word alignment? (faster, sentence timings only) [Y/n]"
  if ($a -notmatch '^(n|no)$') { $NoAlign = $true }
}

# --- Step 6/8: compress ---
if (-not $PSBoundParameters.ContainsKey("Compress")) {
  $asked = $true
  $c = Read-Host "Step 6/8 - Compress audio with ffmpeg first? (smaller temp copy for whisperx) [y/N]"
  if ($c -match '^(y|yes)$') { $Compress = $true }
}
if ($Compress -and -not $PSBoundParameters.ContainsKey("Codec")) {
  $asked = $true
  $validCodecs = @("opus", "mp3", "aac", "flac")
  while ($true) {
    $cc = Read-Host "Step 6/8 - Codec [opus/mp3/aac/flac] (default opus)"
    if ([string]::IsNullOrWhiteSpace($cc)) { $cc = "opus" }
    $cc = $cc.Trim().ToLower()
    if ($validCodecs -contains $cc) { $Codec = $cc; break }
    Write-Host "Please pick one of: $($validCodecs -join '/')."
  }
}
if ($Compress -and $Codec -ne "flac" -and -not $PSBoundParameters.ContainsKey("CompressKbps")) {
  $asked = $true
  while ($true) {
    $k = Read-Host "Step 6/8 - Bitrate kbps, higher = bigger/better (8-320, default 24)"
    if ([string]::IsNullOrWhiteSpace($k)) { $k = "24" }
    $n = 0
    if ([int]::TryParse($k.Trim(), [ref]$n) -and $n -ge 8 -and $n -le 320) {
      $CompressKbps = $n
      break
    }
    Write-Host "Please type a number 8-320."
  }
}

# --- Step 8/8: detail output ---
if (-not $PSBoundParameters.ContainsKey("DetailTranscribe")) {
  $asked = $true
  $d = Read-Host "Step 8/8 - Detail transcription? (SRT/VTT/TSV/JSON in folder, default is TXT only) [y/N]"
  if ($d -match '^(y|yes)$') { $DetailTranscribe = $true }
}

# --- Step 8/8: diarization ---
if (-not $PSBoundParameters.ContainsKey("Diarize")) {
  $asked = $true
  $dz = Read-Host "Step 8/8 - Speaker diarization? (who spoke when, needs HuggingFace token) [y/N]"
  if ($dz -match '^(y|yes)$') { $Diarize = $true }
}
if ($Diarize -and [string]::IsNullOrWhiteSpace($HfToken)) {
  $asked = $true
  $HfToken = Read-Host "Step 8/8 - HuggingFace token (read access, pyannote licenses accepted)"
}
if ($Diarize -and -not $PSBoundParameters.ContainsKey("MinSpeakers")) {
  $asked = $true
  while ($true) {
    $sp = Read-Host "Step 8/8 - Min speakers (0 = auto)"
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
    $sp = Read-Host "Step 8/8 - Max speakers (0 = auto)"
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

$Suffix = ""
if ($Lang -ne "en") { $Suffix += "-$Lang" }
if ($NoAlign) { $Suffix += "-noalign" }
if ($Compress) { $Suffix += "-compressed" }
if ($Diarize) { $Suffix += "-diarized" }
$Stamp = $FileDate.ToString("dd_MMM")
$TranscriptsDir = Join-Path $Root "transcripts"
New-Item -ItemType Directory -Path $TranscriptsDir -Force | Out-Null
$OutDir = $TranscriptsDir
if ($DetailTranscribe) {
  $OutDir = Join-Path $TranscriptsDir ($Stamp + "-" + $ShortBase + $Suffix)
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

if ($asked) {
  Write-Host ""
  Write-Host "Summary:"
  Write-Host "  Audio:  $AudioPath"
  Write-Host "  Date:   $Stamp (from file modified $($FileDate.ToString('yyyy-MM-dd')))"
  Write-Host "  Lang:   $Lang"
  Write-Host "  Model:  $Model"
  Write-Host "  Batch:  $BatchSize"
  Write-Host "  Align:  $(if ($NoAlign) { 'skipped' } else { 'word-level' })"
  $compressInfo = "no"
  if ($Compress) {
    $compressInfo = $Codec
    if ($Codec -ne "flac") { $compressInfo += " $CompressKbps kbps" }
  }
  Write-Host "  Compress: $compressInfo"
  Write-Host "  Output: $(if ($DetailTranscribe) { 'detail (srt/vtt/txt/tsv/json in folder)' } else { 'txt only' })"
  $diarizeInfo = "no"
  if ($Diarize) {
    $diarizeInfo = "yes"
    if ($MinSpeakers -gt 0 -or $MaxSpeakers -gt 0) { $diarizeInfo += " (speakers $MinSpeakers-$MaxSpeakers, 0=auto)" }
  }
  Write-Host "  Diarize: $diarizeInfo"
  Write-Host "  Out:    $OutDir"
  Write-Host "  After:  file moves pending\ -> done\ (renamed with file date)"
  $go = Read-Host "Start transcription? [Y/n]"
  if ($go -match '^(n|no)$') {
    Write-Host "Cancelled."
    Stop-Log
    exit 0
  }
}

# --- optional ffmpeg compression (temp copy, original still moves to done\) ---
$TranscribePath = $AudioPath
$CompressedTmp = ""
if ($Compress) {
  $ff = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if (-not $ff) {
    Write-Error "ffmpeg not found on PATH. Install it: winget install Gyan.FFmpeg (then restart PowerShell)"
    Stop-Log; exit 1
  }
  $ffExt = @{ opus = "opus"; mp3 = "mp3"; aac = "m4a"; flac = "flac" }[$Codec]
  if ($Codec -eq "flac") {
    $CompressedTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-compressed.{1}" -f $Base, $ffExt)
  } else {
    $CompressedTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-compressed-{1}kbps.{2}" -f $Base, $CompressKbps, $ffExt)
  }
  $ffArgs = @("-y", "-i", $AudioPath, "-ac", "1", "-ar", "16000")
  switch ($Codec) {
    "opus" { $ffArgs += @("-c:a", "libopus", "-b:a", ("{0}k" -f $CompressKbps)) }
    "mp3"  { $ffArgs += @("-c:a", "libmp3lame", "-b:a", ("{0}k" -f $CompressKbps)) }
    "aac"  { $ffArgs += @("-c:a", "aac", "-b:a", ("{0}k" -f $CompressKbps)) }
    "flac" { $ffArgs += @("-c:a", "flac", "-compression_level", "5") }
  }
  $ffArgs += $CompressedTmp
  Write-Host ("Compressing: {0} -> {1} ({2})" -f $AudioPath, $CompressedTmp, $Codec)
  & ffmpeg @ffArgs
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $CompressedTmp)) {
    Write-Error "ffmpeg compression failed (original untouched in pending\)"
    Stop-Log; exit 1
  }
  $TranscribePath = $CompressedTmp
}

$wxArgs = @(
  $TranscribePath,
  "--model", $Model,
  "--language", $Lang,
  "--device", $Device,
  "--compute_type", $ComputeType,
  "--batch_size", "$BatchSize",
  "--output_dir", $OutDir,
  "--output_format", $(if ($DetailTranscribe) { "all" } else { "txt" }),
  "--verbose", "False",
  "--print_progress", "True",
  "--log-level", "warning"
)
if ($NoAlign) { $wxArgs += "--no_align" }
if ($Diarize) {
  if ([string]::IsNullOrWhiteSpace($HfToken)) {
    Write-Error "Diarization needs -HfToken (HuggingFace read token with pyannote licenses accepted)"
    Stop-Log; exit 1
  }
  $wxArgs += @("--diarize", "--hf_token", $HfToken)
  if ($MinSpeakers -gt 0) { $wxArgs += @("--min_speakers", "$MinSpeakers") }
  if ($MaxSpeakers -gt 0) { $wxArgs += @("--max_speakers", "$MaxSpeakers") }
}

$displayArgs = $wxArgs.Clone()
$tokIdx = [Array]::IndexOf($displayArgs, "--hf_token")
if ($tokIdx -ge 0 -and ($tokIdx + 1) -lt $displayArgs.Count) { $displayArgs[$tokIdx + 1] = "***" }
Write-Host ("CMD: whisperx {0}" -f ($displayArgs -join ' '))
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
  Stop-Log; exit $code
}

# --- date-stamp transcript output(s) ---
if ($DetailTranscribe) {
  Get-ChildItem -LiteralPath $OutDir -File | ForEach-Object {
    $newName = "{0}-{1}{2}{3}" -f $Stamp, $ShortBase, $Suffix, $_.Extension
    if ($_.Name -ne $newName) { Rename-Item -LiteralPath $_.FullName -NewName $newName }
  }
  Write-Host "DONE. Outputs:"
  Get-ChildItem -LiteralPath $OutDir | Format-Table Name, Length
} else {
  $produced = "{0}.txt" -f [System.IO.Path]::GetFileNameWithoutExtension($TranscribePath)
  $producedPath = Join-Path $OutDir $produced
  if (-not (Test-Path -LiteralPath $producedPath)) {
    Write-Error ("whisperx finished but expected output missing: {0}" -f $producedPath)
    Stop-Log; exit 1
  }
  $finalName = "{0}-{1}{2}.txt" -f $Stamp, $ShortBase, $Suffix
  $finalPath = Join-Path $OutDir $finalName
  if ($producedPath -ne $finalPath) {
    Move-Item -LiteralPath $producedPath -Destination $finalPath -Force -ErrorAction Stop
  }
  Write-Host "DONE. Output:"
  Get-Item -LiteralPath $finalPath | Format-Table Name, Length
}

# --- pending\ -> done\ (only on success, date-stamped) ---
try {
  $dest = Join-Path $DoneDir ("{0}-{1}{2}" -f $Stamp, $ShortBase, [System.IO.Path]::GetExtension($AudioPath))
  if ($AudioPath -ne $dest) {
    Move-Item -LiteralPath $AudioPath -Destination $dest -Force -ErrorAction Stop
    Write-Host "Moved to done: $dest"
  }
} catch {
  Write-Warning "Transcription succeeded but move to done\ failed: $($_.Exception.Message)"
}
if ($CompressedTmp -ne "" -and (Test-Path -LiteralPath $CompressedTmp)) {
  Remove-Item -LiteralPath $CompressedTmp -Force
  Write-Host "Removed temp compressed copy."
}
Stop-Log
