"""Сканер моделей: асинхронные проверки текста, вызова инструментов и лимита токенов."""

import asyncio
import json
import os
import re
import time
from datetime import datetime, timedelta
from pathlib import Path

import aiohttp

from model_limits.registry import LimitsRegistry, _parse_reset_unix
import scanner_config as cfg

HOME = Path(os.environ["USERPROFILE"])

# Shared registry instance for daily limit checks in usable()
_limits_registry = None


def _get_limits_registry() -> LimitsRegistry:
    global _limits_registry
    if _limits_registry is None:
        _limits_registry = LimitsRegistry(get_cache_dir() / "limits.json")
    return _limits_registry


def _is_test_mode() -> bool:
    return os.environ.get("CLAUDE_AUTO_TEST_MODE", "") == "1"


def _get_data_dir() -> Path:
    if _is_test_mode():
        return Path(os.environ.get("CLAUDE_AUTO_DATA_DIR", os.environ.get("LOCALAPPDATA", str(HOME))))
    return Path(os.environ.get("LOCALAPPDATA", str(HOME))) / "claude-auto"


def get_env_file() -> Path:
    if _is_test_mode():
        return _get_data_dir() / ".env"
    return HOME / ".fcc" / ".env"


def get_cache_dir() -> Path:
    return _get_data_dir()


def get_cache_file() -> Path:
    return get_cache_dir() / "cache.json"


# Backward compatibility for existing imports
ENV_FILE = get_env_file()
CACHE_DIR = get_cache_dir()
CACHE_FILE = get_cache_file()


# Test mode port accessor (deviation from reference: needed for CLAUDE_AUTO_PORT in tests)
def get_port() -> int:
    """Возвращает порт FCC. Читает CLAUDE_AUTO_PORT при каждом вызове (lazy)."""
    return int(os.environ.get("CLAUDE_AUTO_PORT", str(cfg.PORT)))


TOOL = {
    "type": "function",
    "function": {
        "name": "get_time",
        "description": "Возвращает текущее время",
        "parameters": {"type": "object", "properties": {}, "required": []},
    },
}


def now() -> datetime:
    return datetime.now()


def clean_value(raw: str) -> str:
    """Снимает JSON-обёртку из .env вида ["ключ"]."""
    value = raw.strip()
    for _ in range(3):
        try:
            decoded = json.loads(value)
        except (json.JSONDecodeError, TypeError):
            break
        if isinstance(decoded, list):
            decoded = decoded[0] if decoded else ""
        value = str(decoded).strip()
    return value.strip('[]"\' ')


def read_env() -> dict[str, str]:
    """Читает .env FCC. Значения никуда не выводятся."""
    values: dict[str, str] = {}
    env_file = get_env_file()
    if not env_file.exists():
        return values
    for line in env_file.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, raw = line.split("=", 1)
        values[name.strip()] = clean_value(raw)
    return values


def get_key(name: str, env: dict[str, str]) -> str | None:
    """Переменная окружения важнее .env."""
    return os.environ.get(name) or env.get(name) or None


def fcc_provider_status() -> tuple[dict[str, int], list[str]]:
    """Что FCC видит прямо сейчас: сколько моделей у каждого провайдера и у каких ошибка.
    Источник - Admin API самого FCC, поэтому подключения через Admin UI учитываются без .env."""
    url = f"http://127.0.0.1:{get_port()}/admin/api/models"
    with urllib.request.urlopen(url, timeout=10) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    counts: dict[str, int] = {}
    for ref in data.get("models", []):
        provider = str(ref).split("/", 1)[0]
        counts[provider] = counts.get(provider, 0) + 1
    return counts, list(data.get("failed_providers", []))


def provider_keys(counts: dict[str, int]) -> dict[str, str]:
    """Провайдеры, которые сканер проверит: FCC видит их модели и есть ключ для прямого запроса."""
    env = read_env()
    found: dict[str, str] = {}
    for name, p in cfg.PROVIDERS.items():
        if counts.get(name):
            key = get_key(p["key_env"], env)
            if key:
                found[name] = key
    return found


def _headers(key: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {key}", "User-Agent": "claude-auto/2.0"}


def _is_free(model: dict) -> bool:
    pricing = model.get("pricing") or {}
    return model.get("id", "").endswith(":free") or (
        pricing.get("prompt") == "0" and pricing.get("completion") == "0")


def _parse_daily_limit(headers: dict) -> dict | None:
    """Парсит заголовки дневного лимита: X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset, retry-after."""
    h = {k.lower(): v for k, v in headers.items()}
    daily_limit = None
    daily_remaining = None
    daily_reset_unix = None

    # X-RateLimit-Limit (дневной лимит запросов)
    if "x-ratelimit-limit" in h:
        try:
            daily_limit = int(h["x-ratelimit-limit"])
        except ValueError:
            pass

    # X-RateLimit-Remaining (оставшиеся запросы на сегодня)
    if "x-ratelimit-remaining" in h:
        try:
            daily_remaining = int(h["x-ratelimit-remaining"])
        except ValueError:
            pass

    # X-RateLimit-Reset: используем общую функцию (секунды < 1e11, мс >= 1e11)
    if "x-ratelimit-reset" in h:
        daily_reset_unix = _parse_reset_unix(h["x-ratelimit-reset"])

    # retry-after в секундах
    if daily_reset_unix is None and "retry-after" in h:
        try:
            daily_reset_unix = time.time() + float(h["retry-after"])
        except ValueError:
            pass

    if daily_limit is not None or daily_remaining is not None or daily_reset_unix is not None:
        return {
            "daily_limit": daily_limit,
            "daily_remaining": daily_remaining,
            "daily_reset_unix": daily_reset_unix,
            "observed_at": time.time(),
        }
    return None


def _classify(status: int, text: str, headers: dict) -> tuple[str, str, dict | None]:
    """Превращает HTTP-ошибку в статус, пояснение и extra (reset time, limits)."""
    extra = None
    if status == 429:
        # OpenRouter: x-ratelimit-reset in unix milliseconds (or seconds)
        reset_ms = headers.get("x-ratelimit-reset")
        # Standard: retry-after in seconds
        retry_after = headers.get("retry-after")
        if reset_ms:
            reset_unix = _parse_reset_unix(reset_ms)
            if reset_unix is not None:
                extra = {"reset_unix": reset_unix}
        elif retry_after:
            try:
                extra = {"reset_unix": time.time() + float(retry_after)}
            except ValueError:
                pass
        # Parse daily limit headers for 429
        daily = _parse_daily_limit(headers)
        if daily:
            if extra:
                extra.update(daily)
            else:
                extra = daily
        return "busy", f"HTTP 429", extra
    if status == 413:
        # Parse daily limit headers for 413 as well
        daily = _parse_daily_limit(headers)
        if daily:
            extra = daily
        return "too_big", f"лимит контекста/токенов", extra
    if status in (404, 403):
        kind = "not_deployed" if status == 404 else "forbidden"
        return kind, f"HTTP {status}", extra
    if status >= 500:
        return "temporary", f"HTTP {status}", extra
    # Check for daily limit exceeded in response text (e.g., "free-models-per-day")
    if "free-models-per-day" in text.lower():
        daily = _parse_daily_limit(headers)
        if daily:
            extra = daily
        return "busy", "дневной лимит исчерпан", extra
    return "fail", f"HTTP {status}: {text[:100]}", extra


class ModelCache:
    """Кэш результатов на диске. Сбрасывается при смене CACHE_VERSION."""

    def __init__(self, path: Path | None = None):
        self.path = path or get_cache_file()

    def load(self) -> dict:
        if not self.path.exists():
            return {}
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}
        if raw.get("_version") != cfg.CACHE_VERSION:
            return {}
        return raw.get("models", {})

    def save(self, models: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        data = {"_version": cfg.CACHE_VERSION, "models": models}
        self.path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


class ProviderLimiter:
    """Per-provider rate limiter: min_interval_s between requests, max parallel."""

    def __init__(self, parallel: int, min_interval_s: float):
        self.sem = asyncio.Semaphore(parallel)
        self.min_interval_s = min_interval_s
        self.last_request = 0.0
        self.lock = asyncio.Lock()

    async def acquire(self):
        async with self.lock:
            now = time.monotonic()
            wait = self.min_interval_s - (now - self.last_request)
            if wait > 0:
                await asyncio.sleep(wait)
            self.last_request = time.monotonic()
        await self.sem.acquire()

    def release(self):
        self.sem.release()


class ModelScanner:
    """Асинхронно проверяет модели подключённых провайдеров."""

    def __init__(self, cache: ModelCache | None = None):
        self.cache = cache or ModelCache()
        self.entries: dict = self.cache.load()

    def mark(self, fid: str, status: str, note: str, **kwargs) -> None:
        self.entries[fid] = {
            "status": status,
            "tools": kwargs.get("tools", False),
            "note": note,
            "latency": kwargs.get("latency", 0.0),
            "context_window": kwargs.get("context_window"),
            "tpm_limit": kwargs.get("tpm_limit"),
            "rpd_limit": kwargs.get("rpd_limit"),
            "daily_limit": kwargs.get("daily_limit"),
            "daily_remaining": kwargs.get("daily_remaining"),
            "daily_reset_unix": kwargs.get("daily_reset_unix"),
            "headers_seen": kwargs.get("headers_seen", {}),
            "checked": now().isoformat(),
        }
        self.cache.save(self.entries)

    def usable(self, skip: set[str] | None = None) -> list[str]:
        """Модели, которые ответили и поддерживают инструменты, окно >= MIN_CONTEXT_TOKENS.
        Учитывает дневной лимит: пропускает модели с daily_remaining=0 до времени сброса."""
        skip = skip or set()
        items = []
        registry = _get_limits_registry()
        for fid, e in self.entries.items():
            if fid in skip:
                continue
            if e.get("status") != "ok":
                continue
            if not e.get("tools"):
                continue
            ctx = e.get("context_window")
            if ctx is None:
                if not cfg.ALLOW_UNKNOWN_WINDOW:
                    continue
            elif ctx < cfg.MIN_CONTEXT_TOKENS:
                continue
            # Check daily limit via registry (single rule for scanner and filter)
            if not registry.is_daily_available(fid):
                continue
            items.append((fid, e))
        items.sort(key=lambda x: x[1]["latency"])
        return [fid for fid, _ in items]

    def get_context_window(self, ref: str) -> int | None:
        """Возвращает context_window из кэша для модели, или None если нет данных."""
        entry = self.entries.get(ref)
        if entry:
            return entry.get("context_window")
        return None

    def scan(self, force: bool, timeout_s: float, max_wait_s: float, workers: int,
             providers: dict[str, str]) -> None:
        asyncio.run(self._scan(force, timeout_s, max_wait_s, workers, providers))

    def _fresh(self, entry: dict) -> bool:
        age = now() - datetime.fromisoformat(entry["checked"])
        status = entry.get("status", "fail")
        # ok — OK_TTL_HOURS; not_deployed, forbidden, fail — 24h; busy, temporary — FAIL_TTL_MINUTES
        if status == "ok":
            ttl = timedelta(hours=cfg.OK_TTL_HOURS)
        elif status in ("not_deployed", "forbidden", "fail"):
            ttl = timedelta(hours=24)
        else:  # busy, temporary, too_big
            ttl = timedelta(minutes=cfg.FAIL_TTL_MINUTES)
        return age < ttl

    async def _collect(self, session: aiohttp.ClientSession, force: bool,
                       providers: dict[str, str]) -> list[tuple]:
        """Модели, которые нужно проверить сейчас. Список берётся живым, с каждого провайдера."""
        tasks = []
        for name, key in providers.items():
            p = cfg.PROVIDERS[name]
            try:
                async with session.get(p["models_url"], headers=_headers(key),
                                       timeout=aiohttp.ClientTimeout(total=15)) as r:
                    r.raise_for_status()
                    models = (await r.json()).get("data", [])
            except Exception as err:
                print(f"[{name}] список моделей не получен: {type(err).__name__}")
                continue
            for m in models:
                mid = m["id"]
                if p["free_only"] and not _is_free(m):
                    continue
                if any(word in mid.lower() for word in cfg.EXCLUDE):
                    continue
                fid = f"{p['fcc_prefix']}/{mid}"
                entry = self.entries.get(fid)
                if not force and entry and self._fresh(entry):
                    continue
                # Save context_window from /models if available
                context_window = m.get("context_length")
                tasks.append((name, p, key, mid, fid, context_window))
        return tasks

    async def _text_probe(self, session: aiohttp.ClientSession, p: dict, key: str,
                          model_id: str, timeout_s: float, limiter: ProviderLimiter) -> dict:
        """Проба текста: POST chat_url, max_tokens=1, сообщение 'hi'."""
        started = time.monotonic()
        await limiter.acquire()
        headers_seen = {}
        res = {"status": "fail", "tools": False, "note": "", "latency": 0.0,
               "context_window": None, "tpm_limit": None, "rpd_limit": None,
               "daily_limit": None, "daily_remaining": None, "daily_reset_unix": None,
               "headers_seen": {}}
        body = {
            "model": model_id,
            "max_tokens": 1,
            "messages": [{"role": "user", "content": "hi"}],
        }
        try:
            async with session.post(p["chat_url"], json=body, headers=_headers(key),
                                    timeout=aiohttp.ClientTimeout(total=timeout_s)) as r:
                text = await r.text()
                # Save rate limit headers
                for h, v in r.headers.items():
                    hl = h.lower()
                    if any(x in hl for x in ("limit", "remaining", "reset", "retry")):
                        headers_seen[h] = v
                # Parse daily limits from all responses
                daily = _parse_daily_limit(dict(r.headers))
                if daily:
                    res.update(daily)
                if r.status == 200:
                    res["status"] = "ok"
                    res["note"] = "text ok"
                else:
                    res["status"], res["note"], extra = _classify(r.status, text[:500], dict(r.headers))
                    if extra:
                        res.update(extra)
                    # For OpenRouter 429, save X-RateLimit-Limit as rpd_limit
                    if r.status == 429 and "x-ratelimit-limit" in r.headers:
                        try:
                            res["rpd_limit"] = int(r.headers["x-ratelimit-limit"])
                        except ValueError:
                            pass
        except asyncio.TimeoutError:
            res["status"], res["note"] = "temporary", "нет ответа вовремя"
        except Exception as err:
            res["note"] = type(err).__name__
        res["latency"] = round(time.monotonic() - started, 2)
        res["headers_seen"] = headers_seen
        limiter.release()
        return res

    async def _tool_probe(self, session: aiohttp.ClientSession, p: dict, key: str,
                          model_id: str, timeout_s: float, limiter: ProviderLimiter) -> dict:
        """Проба инструмента: tools=[get_time], tool_choice=auto, max_tokens=16."""
        started = time.monotonic()
        await limiter.acquire()
        headers_seen = {}
        res = {"status": "fail", "tools": False, "note": "", "latency": 0.0,
               "context_window": None, "tpm_limit": None, "rpd_limit": None,
               "daily_limit": None, "daily_remaining": None, "daily_reset_unix": None,
               "headers_seen": {}}
        body = {
            "model": model_id,
            "max_tokens": 16,
            "messages": [{"role": "user", "content": "Вызови инструмент get_time."}],
            "tools": [TOOL],
            "tool_choice": "auto",
        }
        try:
            async with session.post(p["chat_url"], json=body, headers=_headers(key),
                                    timeout=aiohttp.ClientTimeout(total=timeout_s)) as r:
                text = await r.text()
                for h, v in r.headers.items():
                    hl = h.lower()
                    if any(x in hl for x in ("limit", "remaining", "reset", "retry")):
                        headers_seen[h] = v
                # Parse daily limits from all responses
                daily = _parse_daily_limit(dict(r.headers))
                if daily:
                    res.update(daily)
                if r.status == 200:
                    data = json.loads(text)
                    message = (data.get("choices") or [{}])[0].get("message") or {}
                    if message:
                        res["status"] = "ok"
                        res["tools"] = bool(message.get("tool_calls"))
                        if not res["tools"]:
                            res["note"] = "нет вызова инструмента"
                        else:
                            res["note"] = "tools ok"
                    else:
                        res["note"] = "пустой ответ"
                else:
                    res["status"], res["note"], extra = _classify(r.status, text[:500], dict(r.headers))
                    if extra:
                        res.update(extra)
                    if r.status == 429 and "x-ratelimit-limit" in r.headers:
                        try:
                            res["rpd_limit"] = int(r.headers["x-ratelimit-limit"])
                        except ValueError:
                            pass
        except asyncio.TimeoutError:
            res["status"], res["note"] = "temporary", "нет ответа вовремя"
        except Exception as err:
            res["note"] = type(err).__name__
        res["latency"] = round(time.monotonic() - started, 2)
        res["headers_seen"] = headers_seen
        limiter.release()
        return res

    async def _scan(self, force: bool, timeout_s: float, max_wait_s: float, workers: int,
                    providers: dict[str, str]) -> None:
        # Build limiters per provider
        limiters = {}
        for name, p in cfg.PROVIDERS.items():
            if name in providers:
                limiters[name] = ProviderLimiter(p["parallel"], p["min_interval_s"])

        connector = aiohttp.TCPConnector(limit=workers)
        async with aiohttp.ClientSession(connector=connector) as session:
            tasks = await self._collect(session, force, providers)
            if not tasks:
                print("Все модели уже проверены недавно.")
                return
            print(f"Проверяю моделей: {len(tasks)} (ответ {timeout_s:.1f}с, общий предел {max_wait_s:.0f}с)")

            stats = {"total": len(tasks), "ok": 0, "busy": 0, "too_big": 0,
                     "not_deployed": 0, "forbidden": 0, "temporary": 0, "fail": 0,
                     "no_tools": 0, "window_small": 0, "window_unknown": 0}

            async def work(task):
                name, p, key, mid, fid, ctx_from_models = task
                limiter = limiters[name]

                # Text probe
                res = await self._text_probe(session, p, key, mid, timeout_s, limiter)
                res["context_window"] = ctx_from_models

                # If text ok, do tool probe
                if res["status"] == "ok":
                    tool_res = await self._tool_probe(session, p, key, mid, timeout_s, limiter)
                    # Merge: keep text latency, tool status, tool headers
                    res["tools"] = tool_res["tools"]
                    if tool_res["tools"]:
                        res["status"] = "ok"
                        res["note"] = tool_res["note"]
                    else:
                        res["status"] = "fail"
                        res["note"] = tool_res["note"]
                    # Merge headers_seen
                    res["headers_seen"].update(tool_res["headers_seen"])
                    # tpm_limit from headers_seen if present
                    for h, v in res["headers_seen"].items():
                        if "x-ratelimit-limit-tokens" in h.lower():
                            try:
                                res["tpm_limit"] = int(v)
                            except ValueError:
                                pass
                    # Merge daily limits from tool probe (prefer tool probe values if present)
                    for field in ("daily_limit", "daily_remaining", "daily_reset_unix"):
                        if tool_res.get(field) is not None:
                            res[field] = tool_res[field]

                # Classify usable
                if res["status"] == "ok":
                    ctx = res.get("context_window")
                    if ctx is None:
                        if not cfg.ALLOW_UNKNOWN_WINDOW:
                            res["status"] = "fail"
                            res["note"] = "окно неизвестно"
                            stats["window_unknown"] += 1
                    elif ctx < cfg.MIN_CONTEXT_TOKENS:
                        res["status"] = "fail"
                        res["note"] = f"окно {ctx} < {cfg.MIN_CONTEXT_TOKENS}"
                        stats["window_small"] += 1

                if res["status"] == "ok":
                    if not res["tools"]:
                        stats["no_tools"] += 1
                    else:
                        stats["ok"] += 1
                elif res["status"] in stats:
                    stats[res["status"]] += 1
                else:
                    stats["fail"] += 1

                return fid, res

            jobs = [asyncio.create_task(work(t)) for t in tasks]
            done, pending = await asyncio.wait(jobs, timeout=max_wait_s)
            for job in pending:
                job.cancel()
            for job in done:
                fid, res = job.result()
                self.entries[fid] = res
                mark = "ok" if res["status"] == "ok" and res["tools"] else res["status"]
                ctx = res.get("context_window")
                tpm = res.get("tpm_limit")
                daily_rem = res.get("daily_remaining")
                daily_lim = res.get("daily_limit")
                extra_parts = []
                if ctx is not None:
                    extra_parts.append(f"ctx={ctx}")
                if tpm is not None:
                    extra_parts.append(f"tpm={tpm}")
                if daily_lim is not None and daily_rem is not None:
                    extra_parts.append(f"daily={daily_rem}/{daily_lim}")
                extra_parts.append(f"{res['latency']}s")
                if res["note"]:
                    extra_parts.append(res["note"])
                extra = " ".join(extra_parts)
                print(f"  {mark:<12} {fid}  {extra}")
            if pending:
                print(f"Общий предел исчерпан, не успели проверить: {len(pending)}")

            # Print summary
            print(f"\nИтого: всего {stats['total']}, ок {stats['ok']}, "
                  f"busy {stats['busy']}, too_big {stats['too_big']}, "
                  f"not_deployed {stats['not_deployed']}, forbidden {stats['forbidden']}, "
                  f"temporary {stats['temporary']}, fail {stats['fail']}, "
                  f"no_tools {stats['no_tools']}, window_small {stats['window_small']}, "
                  f"window_unknown {stats['window_unknown']}")

            self.cache.save(self.entries)


# Need urllib for fcc_provider_status
import urllib.request