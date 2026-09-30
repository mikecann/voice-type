# deps.ps1 - installs Python dependencies for voice-type.
# Idempotent: checks before installing.

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'Python 3.10+ must be installed and on PATH.'
}
# Failed import probes are expected. Explicit throws below still stop installs.
$ErrorActionPreference = 'Continue'
Write-Host "  [voice-type] Checking dependencies..." -ForegroundColor Cyan

$packages = @(
    @{ import = "faster_whisper";  pip = "faster-whisper" },
    @{ import = "sounddevice";     pip = "sounddevice" },
    @{ import = "numpy";           pip = "numpy" },
    @{ import = "PIL";             pip = "Pillow" },
    @{ import = "pystray";         pip = "pystray" },
    @{ import = "sherpa_onnx";     pip = "sherpa-onnx" },
    @{ import = "huggingface_hub"; pip = "huggingface_hub" },
    # llama-cpp-python has no prebuilt wheel on PyPI (source-only), so it needs
    # a C/C++ compiler to build. It only backs the optional, off-by-default
    # transcript formatter (see text_formatter.py), so a failed install here
    # must not block the rest of setup or core dictation.
    @{ import = "llama_cpp";       pip = "llama-cpp-python"; optional = $true }
)

if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $packages += @(
        @{ import = "nvidia.cublas";       pip = "nvidia-cublas-cu12" },
        @{ import = "nvidia.cudnn";        pip = "nvidia-cudnn-cu12" },
        @{ import = "nvidia.cuda_runtime"; pip = "nvidia-cuda-runtime-cu12" },
        @{ import = "nvidia.cuda_nvrtc";   pip = "nvidia-cuda-nvrtc-cu12" }
    )
}

foreach ($pkg in $packages) {
    $check = python -c "import $($pkg.import)" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    OK  $($pkg.pip)" -ForegroundColor Green
    } else {
        Write-Host "    Installing $($pkg.pip)..." -ForegroundColor Yellow
        python -m pip install $pkg.pip --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    OK  $($pkg.pip) (installed)" -ForegroundColor Green
        } elseif ($pkg.optional) {
            Write-Host "    WARNING  $($pkg.pip) failed to install. Skipping it; it only backs the optional formatter." -ForegroundColor Yellow
            Write-Host "    Install it yourself later with: python -m pip install $($pkg.pip)" -ForegroundColor Yellow
        } else {
            throw "Failed to install $($pkg.pip). Resolve the pip error and rerun deps.ps1."
        }
    }
}

Write-Host ""
Write-Host "    NOTE: Whisper and formatter models download automatically on first use." -ForegroundColor DarkGray
Write-Host "    They are cached under %USERPROFILE%\.cache\huggingface and %LOCALAPPDATA%\voice-type\llm-models." -ForegroundColor DarkGray
