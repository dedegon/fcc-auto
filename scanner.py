"""Сканер моделей: асинхронные проверки текста, вызова инструментов и лимита токенов."""

import asyncio
import json
import os
import re
import time
from datetime import datetime, timedelta
from pathlib import Path

import aiohttp

import scanner_config as cfg

HOME = Path(os.environ["USERPROFILE"])
ENV_FILE = HOME / ".fcc" / ".env"
CACHE_DIR = Path(os.environ.get("LOCALAPPDATA", str(HOME))) / "claude-auto"
CACHE_FILE = CACHE_DIR / "cache.json"

TOOL = {
    "type": "function",
    "function": {
        "name": "get_time",
        "description": "Возвращает текущее время",
        "parameters": {"type": "object", "properties": {}, "required": []},
    },
}
FILLER = "This is filler text used to check context size limits. " * (cfg.PADDING_CHARS // 60)


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
    if not ENV_FILE.exists():
        return values
    for line in ENV_FILE.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, raw = line.split("=", 1)
        values[name.strip()] = clean_value(raw)
    return values


def get_key(name: str, env: dict[str, str]) -> str | None:
    """Переменная окружения важнее .env."""
    return os.environ.get(name) or env.get(name) or None


def _headers(key: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {key}", "User-Agent": "claude-auto/2.0"}


def _is_free(model: dict) -> bool:
    pricing = model.get("pricing") or {}
    return model.get("id", "").endswith(":free") or (
        pricing.get("prompt") == "0" and pricing.get("completion") == "0")


def _classify(code: int, text: str) -> tuple[str, str]:
    """Превращает HTTP-ошибку в статус и понятное пояснение."""
    if "free-models-per-day" in text:
        return "quota", "дневной лимит"
    if code == 413:
        m = re.search(r"Limit (\d+)", text)
        return "too_big", f"лимит {m.group(1) if m else '?'} токенов/мин"
    if code in (429, 502, 503):
        return "busy", f"HTTP {code}"
    return "fail", f"HTTP {code}: {text[:100]}"


class ModelCache:
    """Кэш результатов на диске. Сбрасывается при смене CACHE_VERSION."""

    def __init__(self, path: Path = CACHE_FILE):
        self.path = path

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


class ModelScanner:
    """Асинхронно проверяет модели подключённых провайдеров FCC."""

    def __init__(self, cache: ModelCache | None = None):
        self.cache = cache or ModelCache()
        self.entries: dict = self.cache.load()

    def mark(self, fid: str, status: str, note: str) -> None:
        self.entries[fid] = {"status": status, "tools": False, "note": note,
                             "latency": 0.0, "checked": now().isoformat()}
        self.cache.save(self.entries)

    def usable(self, skip: set[str] | None = None) -> list[str]:
        """Модели, которые ответили и поддерживают инструменты, от быстрой к медленной."""
        skip = skip or set()
        items = [(fid, e) for fid, e in self.entries.items()
                 if e.get("status") == "ok" and e.get("tools") and fid not in skip]
        items.sort(key=lambda x: x[1]["latency"])
        return [fid for fid, _ in items]

    def scan(self, force: bool, timeout_s: float, max_wait_s: float, workers: int) -> None:
        asyncio.run(self._scan(force, timeout_s, max_wait_s, workers))

    async def _collect(self, session: aiohttp.ClientSession, force: bool) -> list[tuple]:
        """Модели, которые нужно проверить сейчас (по всем подключённым провайдерам)."""
        env = read_env()
        tasks = []
        for name, p in cfg.PROVIDERS.items():
            key = get_key(p["key_env"], env)
            if not key:
                print(f"[{name}] нет ключа, пропускаю")
                continue
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
                tasks.append((name, p, key, mid, fid))
        return tasks

    def _fresh(self, entry: dict) -> bool:
        age = now() - datetime.fromisoformat(entry["checked"])
        ttl = timedelta(hours=cfg.OK_TTL_HOURS) if entry["status"] == "ok" \
            else timedelta(minutes=cfg.FAIL_TTL_MINUTES)
        return age < ttl

    async def _test(self, session: aiohttp.ClientSession, p: dict, key: str,
                    model_id: str, timeout_s: float) -> dict:
        """Запрос, похожий на Claude Code: длинный контекст и вызов инструмента."""
        started = time.monotonic()
        res = {"status": "fail", "tools": False, "note": "", "latency": 0.0,
               "checked": now().isoformat()}
        body = {
            "model": model_id,
            "max_tokens": 256,
            "messages": [{"role": "user", "content": FILLER + "\nВызови инструмент get_time."}],
            "tools": [TOOL],
            "tool_choice": "auto",
        }
        try:
            async with session.post(p["chat_url"], json=body, headers=_headers(key),
                                    timeout=aiohttp.ClientTimeout(total=timeout_s)) as r:
                text = await r.text()
                if r.status == 200:
                    data = json.loads(text)
                    message = (data.get("choices") or [{}])[0].get("message") or {}
                    if message:
                        res["status"] = "ok"
                        res["tools"] = bool(message.get("tool_calls"))
                        if not res["tools"]:
                            res["note"] = "нет вызова инструмента"
                    else:
                        res["note"] = "пустой ответ"
                else:
                    res["status"], res["note"] = _classify(r.status, text[:500])
        except asyncio.TimeoutError:
            res["status"], res["note"] = "timeout", "нет ответа вовремя"
        except Exception as err:
            res["note"] = type(err).__name__
        res["latency"] = round(time.monotonic() - started, 2)
        return res

    async def _scan(self, force: bool, timeout_s: float, max_wait_s: float, workers: int) -> None:
        connector = aiohttp.TCPConnector(limit=workers)
        async with aiohttp.ClientSession(connector=connector) as session:
            tasks = await self._collect(session, force)
            if not tasks:
                print("Все модели уже проверены недавно.")
                return
            print(f"Проверяю моделей: {len(tasks)} (ответ {timeout_s:.1f}с, общий предел {max_wait_s:.0f}с)")

            sems = {name: asyncio.Semaphore(p["parallel"]) for name, p in cfg.PROVIDERS.items()}
            stopped: set[str] = set()

            async def work(task):
                name, p, key, mid, fid = task
                if name in stopped:
                    return fid, None
                async with sems[name]:
                    if name in stopped:
                        return fid, None
                    res = await self._test(session, p, key, mid, timeout_s)
                if res["status"] == "quota":
                    stopped.add(name)
                return fid, res

            jobs = [asyncio.create_task(work(t)) for t in tasks]
            done, pending = await asyncio.wait(jobs, timeout=max_wait_s)
            for job in pending:
                job.cancel()
            for job in done:
                fid, res = job.result()
                if res is None:
                    continue
                self.entries[fid] = res
                mark = "ok" if res["status"] == "ok" and res["tools"] else res["status"]
                extra = res["note"] if mark != "ok" else f"{res['latency']}s"
                print(f"  {mark:<8} {fid}  {extra}")
            if pending:
                print(f"Общий предел исчерпан, не успели проверить: {len(pending)}")
            self.cache.save(self.entries)