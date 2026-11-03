"""Фильтр между Claude Code и FCC.

Claude Code показывает в /model только модели с ID, начинающимся на claude или anthropic.
Проверенные модели FCC выставляются под такими ID (claude-fcc-...), а при отправке
запроса подменяются обратно на настоящий ID FCC.
"""

import json
import os
import re
import threading
import urllib.error
import urllib.request
from collections.abc import Callable
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

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


class _Handler(BaseHTTPRequestHandler):
    upstream: str = ""
    verified: Callable[[], set[str]] = staticmethod(lambda: set())

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

    def _send_json(self, payload: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _rewrite_body(self, body: bytes) -> bytes:
        """Подменяет claude-fcc-... на настоящий ID FCC в запросе к модели."""
        try:
            data = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return body
        if not isinstance(data, dict):
            return body
        mapping = {alias_for(ref): ref for ref in self.verified()}
        model = data.get("model")
        if model in mapping:
            data["model"] = mapping[model]
            log(f"запрос: {model} -> {mapping[model]}")
            return json.dumps(data, ensure_ascii=False).encode("utf-8")
        return body

    def do_GET(self) -> None:
        if urlsplit(self.path).path == "/v1/models":
            allowed = sorted(self.verified())
            items = [{
                "type": "model",
                "id": alias_for(ref),
                "display_name": ref,
                "created_at": "2026-01-01T00:00:00Z",
            } for ref in allowed]
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
            body = self._rewrite_body(body)
        self._send_upstream(body)


def start_filter(upstream: str, verified: Callable[[], set[str]]) -> ThreadingHTTPServer:
    """Фильтр на свободном порту 127.0.0.1 в фоновом потоке."""
    log(f"фильтр запущен, FCC: {upstream}")
    handler = type("FilterHandler", (_Handler,), {
        "upstream": upstream,
        "verified": staticmethod(verified),
    })
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server