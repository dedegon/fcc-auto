"""Учёт лимитов провайдеров по заголовкам ответов. Лишних запросов не делает."""

import json
import re
import time
from pathlib import Path

DURATION = re.compile(r"(?:(\d+)h)?(?:(\d+)m(?!s))?(?:(\d+(?:\.\d+)?)s)?(?:(\d+)ms)?")
FALLBACK_WAIT_S = 60.0
RESET_THRESHOLD = 1e11  # < 1e11 = секунды Unix, >= 1e11 = миллисекунды


def parse_duration(text: str) -> float:
    """'1m26.4s' -> 86.4 с, '547ms' -> 0.547 с. Непонятное значение -> 0."""
    m = DURATION.fullmatch((text or "").strip())
    if not m or not any(m.groups()):
        return 0.0
    hours, minutes, seconds, millis = m.groups()
    return int(hours or 0) * 3600 + int(minutes or 0) * 60 + float(seconds or 0) + int(millis or 0) / 1000


def _lower(headers) -> dict[str, str]:
    return {k.lower(): v for k, v in headers.items()}


def _parse_reset_unix(value: str) -> float | None:
    """Парсит x-ratelimit-reset: < 1e11 — секунды Unix, >= 1e11 — миллисекунды."""
    try:
        val = int(value)
        if val < RESET_THRESHOLD:
            return float(val)  # секунды
        return val / 1000.0  # миллисекунды -> секунды
    except ValueError:
        return None


class LimitsRegistry:
    """Состояние лимитов по моделям FCC. Ключ - ref вида open_router/nvidia/nemotron-3-ultra."""

    def __init__(self, path: Path):
        self.path = path
        try:
            self.data: dict = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            self.data = {}

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self.data, ensure_ascii=False, indent=2), encoding="utf-8")

    def _remaining(self, entry: dict, now: float) -> float | None:
        limit = entry.get("tpm_limit")
        if not limit:
            return None
        if now - entry.get("observed", 0) >= entry.get("tpm_reset_s", FALLBACK_WAIT_S):
            return float(limit)
        return float(entry.get("tpm_remaining", limit))

    def _parse_daily_limit(self, h: dict) -> dict | None:
        """Парсит дневные лимиты из заголовков: X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset, retry-after."""
        daily_limit = None
        daily_remaining = None
        daily_reset_unix = None

        if "x-ratelimit-limit" in h:
            try:
                daily_limit = int(h["x-ratelimit-limit"])
            except ValueError:
                pass

        if "x-ratelimit-remaining" in h:
            try:
                daily_remaining = int(h["x-ratelimit-remaining"])
            except ValueError:
                pass

        if "x-ratelimit-reset" in h:
            daily_reset_unix = _parse_reset_unix(h["x-ratelimit-reset"])

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
            }
        return None

    def _daily_status(self, ref: str, now: float) -> tuple[str | None, float | None, int | None, int | None]:
        """
        Возвращает статус дневного лимита для describe и filter_available.
        Кортеж: (status_text, daily_reset_unix, daily_limit, daily_remaining)
        status_text: "available" | "exhausted_future" | "exhausted_past" | "unknown" | None
        """
        entry = self.data.get(ref, {})
        daily_remaining = entry.get("daily_remaining")
        daily_reset_unix = entry.get("daily_reset_unix")
        daily_limit = entry.get("daily_limit")

        if daily_remaining is None:
            return (None, daily_reset_unix, daily_limit, daily_remaining)

        if daily_remaining > 0:
            return ("available", daily_reset_unix, daily_limit, daily_remaining)

        # daily_remaining <= 0
        if daily_reset_unix is not None and daily_reset_unix > now:
            return ("exhausted_future", daily_reset_unix, daily_limit, daily_remaining)

        # reset в прошлом или неизвестен
        return ("exhausted_past", daily_reset_unix, daily_limit, daily_remaining)

    def is_daily_available(self, ref: str, now: float | None = None) -> bool:
        """Возвращает True, если модель доступна по дневному лимиту.
        Правило:
        - daily_remaining неизвестен (None): True
        - daily_remaining > 0: True
        - daily_remaining <= 0 и daily_reset_unix известен и > now: False
        - daily_remaining <= 0 и reset в прошлом или неизвестен: True (сброс мог наступить)
        """
        if now is None:
            now = time.time()
        status, _, _, _ = self._daily_status(ref, now)
        # available или exhausted_past -> доступна
        return status in ("available", "exhausted_past", None)

    def filter_available(self, refs: list[str], now: float | None = None) -> list[str]:
        """Фильтрует список рефов, оставляя только те, где is_daily_available == True.
        Используется в claude_filter для отбора моделей при переключении.
        """
        if now is None:
            now = time.time()
        return [ref for ref in refs if self.is_daily_available(ref, now)]

    def observe(self, ref: str, headers) -> None:
        """Лимиты из заголовков обычного ответа (так отдаёт OpenRouter/NVIDIA)."""
        h = _lower(headers)
        # Minute/token limits (tpm)
        if "x-ratelimit-limit-tokens" in h:
            try:
                self.data.setdefault(ref, {}).update({
                    "tpm_limit": int(h["x-ratelimit-limit-tokens"]),
                    "tpm_remaining": int(h.get("x-ratelimit-remaining-tokens", 0)),
                    "tpm_reset_s": parse_duration(h.get("x-ratelimit-reset-tokens", "")) or FALLBACK_WAIT_S,
                    "req_limit": int(h.get("x-ratelimit-limit-requests", 0) or 0),
                    "req_remaining": int(h.get("x-ratelimit-remaining-requests", 0) or 0),
                    "observed": time.time(),
                })
            except ValueError:
                pass
        # Daily limits
        daily = self._parse_daily_limit(h)
        if daily:
            self.data.setdefault(ref, {}).update(daily)
            self.data[ref]["observed"] = time.time()
        self._save()

    def cooldown(self, ref: str, headers) -> float:
        """Ответ 429: запоминаем время сброса. Возвращает секунды до сброса."""
        h = _lower(headers)
        wait = FALLBACK_WAIT_S
        try:
            if "x-ratelimit-reset" in h:  # OpenRouter: unix-время сброса в миллисекундах
                reset_unix = _parse_reset_unix(h["x-ratelimit-reset"])
                if reset_unix is not None:
                    wait = max(1.0, reset_unix - time.time())
            elif "retry-after" in h:
                wait = float(h["retry-after"])
        except ValueError:
            pass
        self.data.setdefault(ref, {})["blocked_until"] = time.time() + wait
        # Also parse daily limits from 429 response
        daily = self._parse_daily_limit(h)
        if daily:
            self.data.setdefault(ref, {}).update(daily)
        self._save()
        return wait

    def wait_needed(self, ref: str, est_tokens: int) -> float:
        """Секунды до отправки. 0 - можно сразу, inf - запрос не влезет в лимит модели никогда."""
        entry = self.data.get(ref, {})
        now = time.time()
        blocked = entry.get("blocked_until", 0) - now
        if blocked > 0:
            return blocked
        limit = entry.get("tpm_limit")
        if not limit:
            return 0.0
        if est_tokens > limit:
            return float("inf")
        remaining = self._remaining(entry, now)
        if remaining is not None and est_tokens > remaining:
            return max(0.5, entry.get("tpm_reset_s", FALLBACK_WAIT_S))
        return 0.0

    def spend(self, ref: str, tokens: int) -> None:
        """Учитываем отправленный запрос, чтобы параллельные запросы видели уменьшенный остаток."""
        entry = self.data.get(ref, {})
        limit = entry.get("tpm_limit")
        if not limit:
            return
        now = time.time()
        remaining = self._remaining(entry, now) or limit
        entry["tpm_remaining"] = max(0, int(remaining - tokens))
        entry["observed"] = now

    def get_daily_remaining(self, ref: str) -> tuple[int | None, int | None, float | None]:
        """Возвращает (daily_limit, daily_remaining, daily_reset_unix) или (None, None, None)."""
        entry = self.data.get(ref, {})
        return (
            entry.get("daily_limit"),
            entry.get("daily_remaining"),
            entry.get("daily_reset_unix"),
        )

    def describe(self, ref: str) -> str:
        """Подпись для /model: [Nk/мин] если известен tpm_limit.
        Дневная часть по правилу:
        - daily_remaining > 0: «осталось D/L в день»
        - daily_remaining <= 0, reset в будущем: «осталось 0/L в день, сброс HH:MM UTC»
        - daily_remaining <= 0, reset в прошлом или неизвестен: «сброс суток прошёл»
        - daily_remaining неизвестен: без дневной части.
        """
        entry = self.data.get(ref, {})
        now = time.time()
        if entry.get("blocked_until", 0) > now:
            reset = time.strftime("%H:%M", time.gmtime(entry["blocked_until"]))
            return f"{ref}  [лимит исчерпан, сброс {reset} UTC]"
        limit = entry.get("tpm_limit")
        daily_limit = entry.get("daily_limit")
        daily_remaining = entry.get("daily_remaining")
        daily_reset = entry.get("daily_reset_unix")

        parts = []
        if limit:
            parts.append(f"{limit // 1000}k/мин")
        else:
            parts.append("лимит неизвестен")

        # Daily part logic using _daily_status
        status, reset_unix, dlim, drem = self._daily_status(ref, now)

        if status == "available":
            # daily_remaining > 0
            if dlim is not None and drem is not None:
                parts.append(f"осталось {drem}/{dlim} в день")
            elif dlim is not None:
                parts.append(f"дневной лимит {dlim}")
            elif drem is not None:
                parts.append(f"осталось {drem} в день")

        elif status == "exhausted_future":
            # daily_remaining <= 0, reset в будущем
            if dlim is not None and drem is not None:
                parts.append(f"осталось {drem}/{dlim} в день")
            elif dlim is not None:
                parts.append(f"дневной лимит {dlim}")
            elif drem is not None:
                parts.append(f"осталось {drem} в день")
            # Добавляем время сброса
            if reset_unix is not None:
                reset_str = time.strftime("%H:%M", time.gmtime(reset_unix))
                parts.append(f"сброс {reset_str} UTC")

        elif status == "exhausted_past":
            # daily_remaining <= 0, reset в прошлом или неизвестен
            parts.append("сброс суток прошёл")

        # status == None (daily_remaining unknown) -> no daily part

        return f"{ref}  [{', '.join(parts)}]"