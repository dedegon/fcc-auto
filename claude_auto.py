"""claude-auto: определяет подключённых провайдеров по FCC, проверяет модели и открывает Claude Code."""

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.request  # <-- ДОБАВЛЕНО для проверки готовности API
from pathlib import Path

import scanner_config as cfg
from claude_filter import alias_for, start_filter
from scanner import CACHE_DIR, ModelScanner, fcc_provider_status, provider_keys

HELP = {
    "ru": {
        "usage": "Использование: claude-auto [опции] [-- аргументы для Claude Code]",
        "desc": ("Запускает FCC, проверяет бесплатные модели подключённых провайдеров параллельно "
                 "и открывает Claude Code.\nВ /model попадают только проверенные модели. "
                 "Полный список FCC: fcc-claude."),
        "opts_title": "Опции:",
        "opts": [
            ("--ping MS, --timeout MS", "таймаут ответа одной модели в мс (по умолчанию 15000)"),
            ("--max-wait SEC", "общий предел сканирования в секундах (по умолчанию 120)"),
            ("--workers N", "параллельных проверок всего (по умолчанию 24)"),
            ("--offline, --offs", "не сканировать, взять проверенные из кэша"),
            ("--list", "показать проверенные модели из кэша и выйти"),
            ("--skip MODEL", "исключить модель, можно указать несколько раз"),
            ("-h, --help", "показать эту справку"),
        ],
        "examples_title": "Примеры:",
        "examples": [
            ("claude-auto", "обычный запуск"),
            ("claude-auto --ping 3000", "ждать ответа каждой модели до 3 секунд"),
            ("claude-auto --max-wait 60 --workers 30", "сканировать не дольше минуты"),
            ("claude-auto --list", "список проверенных моделей"),
            ("cd D:\\проект", "сначала перейти в папку проекта; Claude Code откроется там"),
            ("claude-auto --offs", "без сканирования, сразу из кэша"),
            ("claude-auto --skip groq/openai/gpt-oss-20b", "исключить модель"),
            ("claude-auto -- -p \"текст\"", "передать аргументы в Claude Code"),
        ],
        "note": ("Язык определяется по языку Windows. Принудительно: "
                 "CLAUDE_AUTO_LANG=en или CLAUDE_AUTO_LANG=ru. Настройки сканера: scanner_config.py."),
    },
    "en": {
        "usage": "Usage: claude-auto [options] [-- arguments for Claude Code]",
        "desc": ("Starts FCC, checks free models of connected providers in parallel "
                 "and opens Claude Code.\nOnly verified models appear in /model. "
                 "Full FCC list: fcc-claude."),
        "opts_title": "Options:",
        "opts": [
            ("--ping MS, --timeout MS", "response timeout per model in ms (default 15000)"),
            ("--max-wait SEC", "overall scan time limit in seconds (default 120)"),
            ("--workers N", "total parallel checks (default 24)"),
            ("--offline, --offs", "skip scanning, use verified models from cache"),
            ("--list", "show verified models from the cache and exit"),
            ("--skip MODEL", "exclude a model, can be given several times"),
            ("-h, --help", "show this help"),
        ],
        "examples_title": "Examples:",
        "examples": [
            ("claude-auto", "normal start"),
            ("claude-auto --ping 3000", "wait up to 3 seconds for each model"),
            ("claude-auto --max-wait 60 --workers 30", "scan for at most one minute"),
            ("claude-auto --list", "list verified models"),
            ("cd D:\\project", "go to the project folder first; Claude Code opens there"),
            ("claude-auto --offs", "skip scanning, start from cache"),
            ("claude-auto --skip groq/openai/gpt-oss-20b", "exclude a model"),
            ("claude-auto -- -p \"text\"", "pass arguments to Claude Code"),
        ],
        "note": ("Language follows the Windows language. To force it: "
                 "CLAUDE_AUTO_LANG=en or CLAUDE_AUTO_LANG=ru. Scanner settings: scanner_config.py."),
    },
}

PROVIDER_LINKS = [
    ("open_router", "OpenRouter", "OPENROUTER_API_KEY", "https://openrouter.ai/keys"),
    ("groq", "Groq", "GROQ_API_KEY", "https://console.groq.com/keys"),
    ("nvidia_nim", "NVIDIA NIM", "NVIDIA_NIM_API_KEY", "https://build.nvidia.com/settings/api-keys"),
]


def detect_lang() -> str:
    forced = os.environ.get("CLAUDE_AUTO_LANG", "").strip().lower()
    if forced in ("ru", "en"):
        return forced
    try:
        import ctypes
        lang_id = ctypes.windll.kernel32.GetUserDefaultUILanguage()
        return "ru" if (lang_id & 0x3FF) == 0x19 else "en"
    except Exception:
        pass
    env_lang = (os.environ.get("LC_ALL") or os.environ.get("LANG") or "").lower()
    return "ru" if env_lang.startswith("ru") else "en"


def print_help(lang: str) -> None:
    t = HELP[lang]
    print(t["usage"])
    print()
    print(t["desc"])
    print()
    print(t["opts_title"])
    for flag, text in t["opts"]:
        print(f"  {flag:<38}{text}")
    print()
    print(t["examples_title"])
    for example, text in t["examples"]:
        print(f"  {example:<46}{text}")
    print()
    print(t["note"])


def print_report(lang: str, counts: dict[str, int], failed: list[str], keys: dict[str, str]) -> None:
    ru = lang == "ru"
    print("Провайдеры по данным FCC:" if ru else "Providers according to FCC:")
    known = {pid for pid, *_ in PROVIDER_LINKS}
    for pid, label, env_name, url in PROVIDER_LINKS:
        if pid in keys:
            line = f"{counts[pid]} моделей, сканируем" if ru else f"{counts[pid]} models, scanning"
            print(f"  [OK]   {label:<12} {line}")
        elif pid in counts:
            line = (f"подключён в FCC, но ключ {env_name} не найден для проверки"
                    if ru else f"connected in FCC, but key {env_name} not found for checks")
            print(f"  [KEY]  {label:<12} {line}")
        elif pid in failed:
            line = "FCC не смог получить модели, проверьте ключ" if ru else "FCC could not list models, check the key"
            print(f"  [ERR]  {label:<12} {line}")
        else:
            line = (f"не подключён: {url}" if ru else f"not connected: {url}")
            print(f"  [--]   {label:<12} {line}")
    others = sorted(p for p in counts if p not in known)
    if others:
        msg = ("подключены в FCC, но сканер их пока не проверяет: " if ru
               else "connected in FCC, but the scanner does not check them yet: ")
        print(f"  {msg}{', '.join(others)}")


def print_setup(lang: str) -> None:
    if lang == "ru":
        print()
        print("Нет ни одного готового провайдера, сканировать нечего.")
        print(f"  1. Откройте Admin UI: http://127.0.0.1:{cfg.PORT}/admin")
        print("  2. Providers -> выберите провайдера -> Configure -> вставьте ключ -> Save -> Apply")
        print("  3. Запустите claude-auto снова.")
    else:
        print()
        print("No provider is ready, nothing to scan.")
        print(f"  1. Open the Admin UI: http://127.0.0.1:{cfg.PORT}/admin")
        print("  2. Providers -> pick a provider -> Configure -> paste the key -> Save -> Apply")
        print("  3. Run claude-auto again.")


def port_open() -> bool:
    try:
        with socket.create_connection(("127.0.0.1", cfg.PORT), timeout=1):
            return True
    except OSError:
        return False


def ensure_server() -> bool:
    """Запускает fcc-server, если порт не слушается, и ждёт готовности."""
    if port_open():
        return True
    exe = shutil.which("fcc-server")
    if not exe:
        print("fcc-server не найден в PATH")
        return False
    print("Запускаю fcc-server...")
    flags = subprocess.CREATE_NEW_CONSOLE if os.name == "nt" else 0
    
    # ОЧИЩАЕМ ОКРУЖЕНИЕ ДЛЯ FCC-SERVER
    clean_env = os.environ.copy()
    for key in list(clean_env.keys()):
        if any(x in key.upper() for x in ["API_KEY", "TOKEN", "OPENAI", "GROQ", "NVIDIA", "OPENROUTER", "ANTHROPIC"]):
            del clean_env[key]
    clean_env["PORT"] = str(cfg.PORT)
    
    subprocess.Popen([exe], env=clean_env,
                     creationflags=flags, cwd=str(CACHE_DIR.parent))
    
    deadline = time.time() + 90
    while time.time() < deadline:
        if port_open():
            try:
                req = urllib.request.Request(f"http://127.0.0.1:{cfg.PORT}/admin/api/models")
                with urllib.request.urlopen(req, timeout=2) as r:
                    if r.status == 200:
                        # Ждем, пока количество моделей перестанет расти (сервер завершит фоновую загрузку)
                        last_count = -1
                        stable_checks = 0
                        while time.time() < deadline:
                            try:
                                with urllib.request.urlopen(req, timeout=2) as r2:
                                    data = json.loads(r2.read().decode("utf-8"))
                                    current_count = len(data.get("models", []))
                                    if current_count == last_count:
                                        stable_checks += 1
                                        if stable_checks >= 4: # 4 проверки подряд (2 секунды) без изменений
                                            return True
                                    else:
                                        last_count = current_count
                                        stable_checks = 0
                            except Exception:
                                pass
                            time.sleep(0.5)
            except Exception:
                pass # API еще грузится
        time.sleep(0.5)
    return False


def write_settings(models: list[str]) -> str:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = CACHE_DIR / "claude-settings.json"
    data = {"availableModels": models + ["opus", "sonnet", "haiku"]}
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return str(path)


def saved_user_model() -> str | None:
    path = Path.home() / ".claude" / "settings.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return None
    value = data.get("model") if isinstance(data, dict) else None
    return value or None


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    lang = detect_lang()
    if "-h" in sys.argv or "--help" in sys.argv:
        print_help(lang)
        return

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--offline", "--offs", dest="offline", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--skip", action="append", default=[])
    parser.add_argument("--ping", "--timeout", dest="timeout_ms", type=int,
                        default=cfg.DEFAULT_TIMEOUT_MS)
    parser.add_argument("--max-wait", type=float, default=cfg.DEFAULT_MAX_WAIT_S)
    parser.add_argument("--workers", type=int, default=cfg.DEFAULT_WORKERS)
    args, claude_args = parser.parse_known_args()
    if claude_args and claude_args[0] == "--":
        claude_args = claude_args[1:]

    scanner = ModelScanner()
    for fid in args.skip:
        scanner.mark(fid, "fail", "исключена пользователем")

    if args.list:
        for i, fid in enumerate(scanner.usable(), 1):
            print(f"{i:>3}. {fid}  ({scanner.entries[fid]['latency']}s)")
        return

    if not ensure_server():
        print("fcc-server не поднялся на порту", cfg.PORT)
        sys.exit(1)

    keys: dict[str, str] = {}
    if not args.offline:
        try:
            counts, failed = fcc_provider_status()
        except Exception as err:
            print(f"Не удалось получить данные от FCC: {type(err).__name__}")
            sys.exit(1)
        keys = provider_keys(counts)
        print_report(lang, counts, failed, keys)
        if not keys:
            print_setup(lang)
            sys.exit(2)
        print()
        scanner.scan(force=True, timeout_s=args.timeout_ms / 1000,
                     max_wait_s=args.max_wait, workers=args.workers, providers=keys)
    else:
        print("Режим --offline: сканирование пропущено, берём проверенные из кэша.")

    models = scanner.usable(skip=set(args.skip))
    if not models:
        print("Нет проверенных моделей с поддержкой инструментов.")
        sys.exit(1)

    srv = start_filter(f"http://127.0.0.1:{cfg.PORT}", lambda: set(ModelScanner().usable()))
    claude_bin = shutil.which("claude")
    if not claude_bin:
        print("Claude Code не найден в PATH.")
        srv.shutdown()
        sys.exit(1)

    # Генерируем правильные имена моделей
    valid_aliases = [alias_for(m) for m in models]
    settings_path = write_settings(valid_aliases)
    
    env = {k: v for k, v in os.environ.items() if not k.startswith("ANTHROPIC_")}
    env.pop("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", None)
    env.update({
        "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{srv.server_address[1]}",
        "ANTHROPIC_AUTH_TOKEN": "fcc",
        "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
        "CLAUDE_CODE_AUTO_MODE_SERVER": "0",
        "CLAUDE_CODE_DISABLE_ADVISOR_TOOL": "1",
        "CLAUDE_ENABLE_STREAM_WATCHDOG": "0",
        "CLAUDE_ENABLE_BYTE_WATCHDOG": "0",
        "API_FORCE_IDLE_TIMEOUT": "0",
        "API_TIMEOUT_MS": "2147483647",
        "DISABLE_AUTOUPDATER": "1",
        "DISABLE_FEEDBACK_COMMAND": "1",
        "DISABLE_ERROR_REPORTING": "1",
    })
    
    # ИСПРАВЛЕНИЕ КЛОДА: Если сохраненная модель не совпадает с новыми именами (старый формат), ставим первую доступную
    saved = saved_user_model()
    if saved in valid_aliases:
        model_args = []
    else:
        model_args = ["--model", valid_aliases[0]]

    print(f"\nПроверенных моделей: {len(models)}")
    print("Полный список FCC: fcc-claude")
    os.system("cls")
    try:
        rc = subprocess.call([claude_bin, "--settings", settings_path, *model_args, *claude_args],
                             env=env)
    finally:
        srv.shutdown()
    sys.exit(rc)


if __name__ == "__main__":
    main()
