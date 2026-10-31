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
        entry = self.data.get(ref, {})
        daily_remaining = entry.get("daily_remaining")
        daily_reset_unix = entry.get("daily_reset_unix")

        if daily_remaining is None:
            return True
        if daily_remaining > 0:
            return True
        # daily_remaining <= 0
        if daily_reset_unix is not None and daily_reset_unix > now:
            return False
        # reset в прошлом или неизвестен — пробуем
        return True

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
        Если известен дневной остаток и is_daily_available=True, добавляет: [Nk/мин, осталось D/день].
        Если reset уже прошёл или remaining <= 0, показывает «сброс суток прошёл» вместо «осталось 0/L»."""
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

        # Daily limit display: show "осталось D/L" only if remaining > 0.
        # If remaining <= 0 (whether reset passed or future), show "сброс суток прошёл".
        if daily_limit is not None and daily_remaining is not None:
            if daily_remaining > 0:
                parts.append(f"осталось {daily_remaining}/{daily_limit} в день")
            else:
                parts.append("сброс суток прошёл")
        elif daily_limit is not None:
            parts.append(f"дневной лимит {daily_limit}")
        elif daily_remaining is not None:
            parts.append(f"осталось {daily_remaining} в день")

        if daily_reset and daily_reset > now:
            reset_str = time.strftime("%H:%M", time.gmtime(daily_reset))
            parts.append(f"сброс {reset_str} UTC")

        return f"{ref}  [{', '.join(parts)}]"