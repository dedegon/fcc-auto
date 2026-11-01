"""Настройки сканера. Значения меняются здесь, а не в коде."""

PORT = 8082
DEFAULT_TIMEOUT_MS = 15000
DEFAULT_MAX_WAIT_S = 120
DEFAULT_WORKERS = 24
OK_TTL_HOURS = 24
FAIL_TTL_MINUTES = 30
CACHE_VERSION = 4
MIN_CONTEXT_TOKENS = 32000
ALLOW_UNKNOWN_WINDOW = False

PROVIDERS = {
    "open_router": {
        "key_env": "OPENROUTER_API_KEY",
        "models_url": "https://openrouter.ai/api/v1/models",
        "chat_url": "https://openrouter.ai/api/v1/chat/completions",
        "fcc_prefix": "open_router",
        "free_only": True,
        "parallel": 2,
        "min_interval_s": 3.1,
    },
    "nvidia_nim": {
        "key_env": "NVIDIA_NIM_API_KEY",
        "models_url": "https://integrate.api.nvidia.com/v1/models",
        "chat_url": "https://integrate.api.nvidia.com/v1/chat/completions",
        "fcc_prefix": "nvidia_nim",
        "free_only": False,
        "parallel": 2,
        "min_interval_s": 1.5,
    },
}

EXCLUDE = [
    "lyria", "inkling", "embed", "guard", "safety", "tts", "whisper", "orpheus",
    "diffusion", "deplot", "codegemma", "starcoder", "granite", "gemma-2b",
    "recurrentgemma", "fuyu", "dbrx", "jamba", "yi-large", "sea-lion", "deepseek-coder",
    "vision", "vl", "kosmos", "phi-3-vision", "codellama", "llama2",
]