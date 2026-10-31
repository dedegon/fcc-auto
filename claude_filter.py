"""Фильтр между Claude Code и FCC.

Claude Code показывает в /model только модели с ID, начинающимся на claude или anthropic.
Проверенные модели FCC выставляются под такими ID (claude-fcc-...), а при отправке
запроса подменяются обратно на настоящий ID FCC.
"""

import json
import os
import re
import threading
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from model_limits.registry import LimitsRegistry
import scanner_config as cfg

SKIP_HEADERS = {"connection", "keep-alive", "transfer-encoding", "content-length", "host", "upgrade"}
LOG_FILE = Path(os.environ.get("LOCALAPPDATA", ".")) / "claude-auto" / "filter.log"
INFERENCE_PATHS = {"/v1/messages", "/v1/messages/count_tokens"}
ALIAS_PREFIX = "claude-fcc-"


def alias_for(ref: str) -> str:
    """Claude-совместимый ID для модели FCC, например claude-fcc-nvidia-nim-openai-gpt-oss-20b."""
    slug = re.sub(r"[^a-z0-9]+", "-", ref.lower()).strip("-")
    return ALIAS_PREFIX + slug


def log(message: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(f"{datetime.now().isoformat(timespec='seconds')} {message}\n")


def _estimate_tokens(data: dict) -> int:
    """Приблизительная оценка токенов в запросе: байты UTF-8 / 4."""
    return len(json.dumps(data, ensure_ascii=False).encode("utf-8")) // 4


def _truncate_messages(data: dict, ref: str, window: int) -> tuple[dict, bool]:
    """
    Обрезает messages до окна контекста модели.
    Оставляет system + последние N сообщений, пока токены <= window * 0.8.
    Добавляет маркер обрезки в system или первое user сообщение.
    Возвращает (новые_данные, был_ли_обрезан).
    """
    messages = data.get("messages")
    if not isinstance(messages, list) or not messages:
        return data, False

    # Находим system сообщения (обычно первое)
    system_msgs = [m for m in messages if m.get("role") == "system"]
    other_msgs = [m for m in messages if m.get("role") != "system"]

    # Оценка текущих токенов
    est = _estimate_tokens(data)
    limit = int(window * 0.8)
    if est <= limit:
        return data, False

    # Удаляем старые сообщения с головы, оставляя system + хвост
    truncated = False
    while other_msgs and est > limit:
        other_msgs.pop(0)
        new_messages = system_msgs + other_msgs
        data["messages"] = new_messages
        est = _estimate_tokens(data)
        truncated = True

    if truncated:
        # Добавляем маркер в system (если есть) или в первое user
        marker = f"[контекст обрезан фильтром до {window}t для {ref}]"
        if system_msgs:
            system_msgs[0]["content"] = (system_msgs[0].get("content", "") + "\n\n" + marker).strip()
        elif other_msgs and other_msgs[0].get("role") == "user":
            other_msgs[0]["content"] = (other_msgs[0].get("content", "") + "\n\n" + marker).strip()

    return data, truncated


def _truncate_if_needed(data: dict, ref: str, window: int) -> tuple[dict, bool]:
    """TODO: реализовать обрезку истории при превышении окна контекста."""
    return _truncate_messages(data, ref, window)


class _Handler(BaseHTTPRequestHandler):
    upstream: str = ""
    verified: Callable[[], set[str]] = staticmethod(lambda: set())
    get_window: Callable[[str], int | None] = staticmethod(lambda _: None)

    def log_message(self, *args) -> None:
        pass

    def _open_upstream(self, body: bytes | None):
        headers = {k: v for k, v in self.headers.items() if k.lower() not in SKIP_HEADERS}
        req = urllib.request.Request(self.upstream + self.path, data=body,
                                     headers=headers, method=self.command)
        try:
            return urllib.request.urlopen(req, timeout=900)
        except urllib.error.HTTPError as err:
            return err

    def _send_upstream(self, body: bytes | None) -> None:
        try:
            resp = self._open_upstream(body)
        except Exception as err:
            log(f"{self.command} {self.path} -> FCC недоступен: {type(err).__name__}")
            msg = f"FCC недоступен: {type(err).__name__}".encode()
            self.send_response(502)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            return

        status = resp.status if hasattr(resp, "status") else resp.code
        log(f"{self.command} {self.path} -> {status}")
        self.send_response(status)
        for k, v in resp.headers.items():
            if k.lower() not in SKIP_HEADERS:
                self.send_header(k, v)
        self.end_headers()
        read = getattr(resp, "read1", resp.read)
        while chunk := read(8192):
            self.wfile.write(chunk)
            self.wfile.flush()

        # model_limits tracking — после отправки ответа клиенту, не блокируем
        ref = getattr(self, "_current_ref", None)
        if ref:
            try:
                hdrs = dict(resp.headers)
                if 200 <= status < 300:
                    self.limits.observe(ref, hdrs)
                elif status == 429:
                    wait = self.limits.cooldown(ref, hdrs)
                    log(f"429 {ref}, cooldown {wait:.1f}s")
            except Exception as err:
                log(f"limits error {ref}: {type(err).__name__}: {err}")

    def _send_json(self, payload: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _rewrite_body(self, body: bytes) -> bytes:
        """Подменяет claude-fcc-... на настоящий ID FCC в запросе к модели.
        Обрезает контекст под окно модели, если запрос слишком большой."""
        try:
            data = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._current_ref = None
            return body
        if not isinstance(data, dict):
            self._current_ref = None
            return body
        mapping = {alias_for(ref): ref for ref in self.verified()}
        model = data.get("model")
        if model in mapping:
            ref = mapping[model]
            data["model"] = ref
            log(f"запрос: {model} -> {ref}")
            self._current_ref = ref

            # Обрезка контекста под окно модели (заглушка — окно из кэша сканера)
            window = self.get_window(ref) or cfg.MIN_CONTEXT_TOKENS
            est = _estimate_tokens(data)
            if est > int(window * 0.9):
                data, tr = _truncate_messages(data, ref, window)
                if tr:
                    new_est = _estimate_tokens(data)
                    log(f"truncated {ref}: {est}t -> {new_est}t")
            return json.dumps(data, ensure_ascii=False).encode("utf-8")
        self._current_ref = None
        return body

    def do_GET(self) -> None:
        if urlsplit(self.path).path == "/v1/models":
            allowed = sorted(self.verified())
            items = []
            for ref in allowed:
                limit_desc = self.limits.describe(ref) if hasattr(self, 'limits') else ref
                # Format: [Nk/мин] if tpm_limit known, else [лимит неизвестен]
                display_name = limit_desc
            payload = json.dumps({
                "data": items,
                "has_more": False,
                "first_id": items[0]["id"] if items else None,
            }, ensure_ascii=False).encode("utf-8")
            log(f"GET /v1/models -> {len(items)} моделей")
            self._send_json(payload)
        else:
            log(f"GET {self.path}")
            self._send_upstream(None)

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        if body and urlsplit(self.path).path in INFERENCE_PATHS:
            # Check if we need to switch model due to rate limit
            switched = False
            for attempt in range(3):  # max 3 attempts: original + up to 2 switches
                if switched:
                    # Re-read body for switched model
                    length = int(self.headers.get("Content-Length") or 0)
                    body = self.rfile.read(length) if length else None
                body = self._rewrite_body(body)
                # Check if _rewrite_body set _current_ref
                ref = getattr(self, "_current_ref", None)
                if not ref:
                    self._send_upstream(body)
                    return

                # Send request
                try:
                    headers = {k: v for k, v in self.headers.items() if k.lower() not in SKIP_HEADERS}
                    req = urllib.request.Request(self.upstream + self.path, data=body,
                                                 headers=headers, method=self.command)
                    resp = urllib.request.urlopen(req, timeout=900)
                    status = resp.status
                    resp_headers = dict(resp.headers)
                    self.send_response(status)
                    for k, v in resp_headers.items():
                        if k.lower() not in SKIP_HEADERS:
                            self.send_header(k, v)
                    self.end_headers()
                    read = getattr(resp, "read1", resp.read)
                    while chunk := read(8192):
                        self.wfile.write(chunk)
                        self.wfile.flush()

                    # Track limits
                    try:
                        if 200 <= status < 300:
                            self.limits.observe(ref, resp_headers)
                        elif status == 429:
                            wait = self.limits.cooldown(ref, resp_headers)
                            log(f"429 {ref}, cooldown {wait:.1f}s")
                    except Exception as err:
                        log(f"limits error {ref}: {type(err).__name__}: {err}")

                    # Handle 429/413 - switch model
                    if status in (429, 413) and not switched:
                        # Check if we should wait or switch
                        wait_needed = 0.0
                        if status == 429:
                            h = {k.lower(): v for k, v in resp_headers.items()}
                            if "x-ratelimit-reset" in h:
                                try:
                                    reset_unix = int(h["x-ratelimit-reset"]) / 1000
                                    wait_needed = max(1.0, reset_unix - time.time())
                                except (ValueError, KeyError):
                                    pass
                            elif "retry-after" in h:
                                try:
                                    wait_needed = float(h["retry-after"])
                                except ValueError:
                                    pass
                        # If reset known and < 20s, wait; else switch
                        if wait_needed > 0 and wait_needed < 20:
                            time.sleep(wait_needed)
                            switched = True
                            continue
                        # Switch to next usable model with daily_remaining > 0 preferred
                        verified_set = set(self.verified())
                        usable_models = [m for m in verified_set if m != ref]
                        # Filter by window >= MIN_CONTEXT_TOKENS (using get_window from cache)
                        filtered = []
                        for m in usable_models:
                            window = self.get_window(m)
                            if window is not None and window >= cfg.MIN_CONTEXT_TOKENS:
                                filtered.append(m)
                        # Filter by daily limit availability using filter_available
                        daily_available = self.limits.filter_available(filtered)
                        if daily_available:
                            # Prefer models with daily_remaining > 0
                            preferred = []
                            fallback = []
                            for m in daily_available:
                                dlim, drem, _ = self.limits.get_daily_remaining(m)
                                if drem is not None and drem > 0:
                                    preferred.append(m)
                                else:
                                    fallback.append(m)
                            next_models = preferred + fallback
                            if next_models:
                                next_model = next_models[0]
                                # Rewrite body with new model
                                try:
                                    data = json.loads(body)
                                    data["model"] = next_model
                                    body = json.dumps(data, ensure_ascii=False).encode("utf-8")
                                    log(f"переключение {ref} -> {next_model}: {status} ({'rate limit' if status == 429 else 'context limit'})")
                                    switched = True
                                    continue
                                except Exception:
                                    pass
                        # No models available to switch
                        if not switched:
                            # Find nearest reset time for error message
                            nearest_reset = None
                            for m in verified_set:
                                _, _, dreset = self.limits.get_daily_remaining(m)
                                if dreset and dreset > time.time():
                                    if nearest_reset is None or dreset < nearest_reset:
                                        nearest_reset = dreset
                            if nearest_reset:
                                reset_str = time.strftime("%H:%M:%S", time.gmtime(nearest_reset))
                                log(f"все модели исчерпаны, ближайший сброс {reset_str} UTC")
                            self._send_upstream(body)
                            return
                    # If we get here, either success, or no switch possible, or already switched
                    return

                except urllib.error.HTTPError as err:
                    status = err.code
                    resp_headers = dict(err.headers)
                    self.send_response(status)
                    for k, v in resp_headers.items():
                        if k.lower() not in SKIP_HEADERS:
                            self.send_header(k, v)
                    self.end_headers()
                    while chunk := err.read(8192):
                        self.wfile.write(chunk)
                        self.wfile.flush()

                    # Track limits
                    try:
                        if status == 429:
                            wait = self.limits.cooldown(ref, resp_headers)
                            log(f"429 {ref}, cooldown {wait:.1f}s")
                    except Exception as e:
                        log(f"limits error {ref}: {type(e).__name__}: {e}")

                    # Handle 429/413 - switch model
                    if status in (429, 413) and not switched:
                        wait_needed = 0.0
                        if status == 429:
                            h = {k.lower(): v for k, v in resp_headers.items()}
                            if "x-ratelimit-reset" in h:
                                try:
                                    reset_unix = int(h["x-ratelimit-reset"]) / 1000
                                    wait_needed = max(1.0, reset_unix - time.time())
                                except (ValueError, KeyError):
                                    pass
                            elif "retry-after" in h:
                                try:
                                    wait_needed = float(h["retry-after"])
                                except ValueError:
                                    pass
                        if wait_needed > 0 and wait_needed < 20:
                            time.sleep(wait_needed)
                            switched = True
                            continue
                        verified_set = set(self.verified())
                        usable_models = [m for m in verified_set if m != ref]
                        filtered = []
                        for m in usable_models:
                            window = self.get_window(m)
                            if window is not None and window >= cfg.MIN_CONTEXT_TOKENS:
                                filtered.append(m)
                        # Filter by daily limit availability using filter_available
                        daily_available = self.limits.filter_available(filtered)
                        if daily_available:
                            # Prefer models with daily_remaining > 0
                            preferred = []
                            fallback = []
                            for m in daily_available:
                                dlim, drem, _ = self.limits.get_daily_remaining(m)
                                if drem is not None and drem > 0:
                                    preferred.append(m)
                                else:
                                    fallback.append(m)
                            next_models = preferred + fallback
                            if next_models:
                                next_model = next_models[0]
                                try:
                                    data = json.loads(body)
                                    data["model"] = next_model
                                    body = json.dumps(data, ensure_ascii=False).encode("utf-8")
                                    log(f"переключение {ref} -> {next_model}: {status} ({'rate limit' if status == 429 else 'context limit'})")
                                    switched = True
                                    continue
                                except Exception:
                                    pass
                        # No models available to switch
                        if not switched:
                            nearest_reset = None
                            for m in verified_set:
                                _, _, dreset = self.limits.get_daily_remaining(m)
                                if dreset and dreset > time.time():
                                    if nearest_reset is None or dreset < nearest_reset:
                                        nearest_reset = dreset
                            if nearest_reset:
                                reset_str = time.strftime("%H:%M:%S", time.gmtime(nearest_reset))
                                log(f"все модели исчерпаны, ближайший сброс {reset_str} UTC")
                            self._send_upstream(body)
                            return
                    return
                except Exception as err:
                    log(f"{self.command} {self.path} -> FCC недоступен: {type(err).__name__}")
                    msg = f"FCC недоступен: {type(err).__name__}".encode()
                    self.send_response(502)
                    self.send_header("Content-Type", "text/plain; charset=utf-8")
                    self.send_header("Content-Length", str(len(msg)))
                    self.end_headers()
                    self.wfile.write(msg)
                    return


def start_filter(upstream: str, verified: Callable[[], set[str]], limits=None,
                 get_window: Callable[[str], int | None] | None = None) -> ThreadingHTTPServer:
    """Фильтр на свободном порту 127.0.0.1 в фоновом потоке."""
    log(f"фильтр запущен, FCC: {upstream}")
    handler = type("FilterHandler", (_Handler,), {
        "upstream": upstream,
        "verified": staticmethod(verified),
        "limits": limits or LimitsRegistry(),
        "get_window": staticmethod(get_window or (lambda _: None)),
    })
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server