"""Настройки сканера моделей. Меняйте значения здесь, не в коде."""

# Порт прокси FCC.
PORT = 8082

# Сколько ждать ответа одной модели по умолчанию, мс (флаг --ping).
DEFAULT_TIMEOUT_MS = 15000

# Общий предел сканирования, сек (флаг --max-wait).
DEFAULT_MAX_WAIT_S = 120

# Сколько проверок идёт одновременно всего (флаг --workers).
DEFAULT_WORKERS = 24

# Размер контекста проверки в символах (около 25k токенов, как у Claude Code).
PADDING_CHARS = 100000

# Минимальный лимит токенов в минуту, при котором модель пригодна для Claude Code.
MIN_TPM = 25000

# Сколько часов рабочая модель не перепроверяется.
OK_TTL_HOURS = 6

# Сколько минут нерабочая модель не перепроверяется.
FAIL_TTL_MINUTES = 30

# Версия формата кэша. При смене логики увеличьте число: старый кэш сбросится.
CACHE_VERSION = 2

# Провайдеры, которые сканер проверяет. Ключ берётся из переменной окружения или .env FCC.
PROVIDERS = {
    "open_router": {
        "key_env": "OPENROUTER_API_KEY",
        "models_url": "https://openrouter.ai/api/v1/models",
        "chat_url": "https://openrouter.ai/api/v1/chat/completions",
        "fcc_prefix": "open_router",
        "free_only": True,     # брать только бесплатные модели
        "parallel": 6,         # одновременных запросов к этому провайдеру
    },
    "groq": {
        "key_env": "GROQ_API_KEY",
        "models_url": "https://api.groq.com/openai/v1/models",
        "chat_url": "https://api.groq.com/openai/v1/chat/completions",
        "fcc_prefix": "groq",
        "free_only": False,
        "parallel": 4,
    },
    "nvidia_nim": {
        "key_env": "NVIDIA_NIM_API_KEY",
        "models_url": "https://integrate.api.nvidia.com/v1/models",
        "chat_url": "https://integrate.api.nvidia.com/v1/chat/completions",
        "fcc_prefix": "nvidia_nim",
        "free_only": False,
        "parallel": 10,
    },
}

# Модели с этими словами в названии не проверяются: озвучка, картинки, эмбеддинги и т. п.
EXCLUDE = [
    "lyria", "inkling", "embed", "guard", "safety", "tts", "whisper", "orpheus",
    "diffusion", "deplot", "codegemma", "starcoder", "granite", "gemma-2b",
    "recurrentgemma", "fuyu", "dbrx", "jamba", "yi-large", "sea-lion", "deepseek-coder",
    "vision", "vl", "kosmos", "phi-3-vision", "codellama", "llama2",
]