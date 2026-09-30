# whisperx-lecture-transcriber

Local GPU transcription for college lecture recordings using WhisperX (RTX 4050, `cuda` / `float16`).

Drop audio into `pending/`, get timestamped transcripts in `transcripts/`. Originals move to `done/` on success.

## Setup (Windows PowerShell, Python 3.11)

```powershell
# 1. per-project venv (Python 3.11)
py -3.11 -m venv .venv

# 2. GPU torch FIRST (cu128 index) — ~2-3 GB download
.\.venv\Scripts\python.exe -m pip install "torch~=2.8.0" "torchaudio~=2.8.0" "torchvision~=0.23.0" --index-url https://download.pytorch.org/whl/cu128

# 3. rest of deps
.\.venv\Scripts\python.exe -m pip install -r requirements.txt

# 4. verify
.\.venv\Scripts\python.exe -c "import torch; print(torch.__version__, torch.cuda.is_available())"
.\.venv\Scripts\whisperx.exe --help
```

## Use

```powershell
# single file (guided prompts)
.\transcribe.ps1

# single file, no prompts
.\transcribe.ps1 -Audio MyLecture.wav -Lang en

# batch: every file in pending\
.\transcribe-all.ps1 -Lang en -Model medium -BatchSize 4
```

* Langs: `en`, `hi`. Models: `tiny` / `base` / `small` / `medium` / `large-v2` / `large-v3`.
* `-NoAlign` skips word alignment (faster, sentence timings only).
* Outputs: `transcripts/<Base>[-lang][-noalign]-<dd_MMM>/`, logs in `logs/`.
