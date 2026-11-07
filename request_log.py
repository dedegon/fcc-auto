"""Request logging for claude-auto: opt-in logging of AI requests/responses to markdown files."""

import json
import os
import re
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


# Patterns for secrets to redact
SECRET_PATTERNS = [
    # OpenAI-style keys
    (re.compile(r'\bsk-[a-zA-Z0-9_-]{20,}\b'), '[REDACTED]'),
    # Groq keys
    (re.compile(r'\bgsk_[a-zA-Z0-9_-]{20,}\b'), '[REDACTED]'),
    # NVIDIA NIM keys
    (re.compile(r'\bnvapi-[a-zA-Z0-9_-]{20,}\b'), '[REDACTED]'),
    # Generic Bearer tokens in Authorization header
    (re.compile(r'(?i)Bearer\s+[a-zA-Z0-9._-]{20,}'), 'Bearer [REDACTED]'),
    # Environment variables with KEY/TOKEN/SECRET in name
    (re.compile(r'(?i)\b([A-Z_]*?(?:KEY|TOKEN|SECRET)[A-Z_]*)\s*=\s*([^\s\n]+)'), r'\1=[REDACTED]'),
]


def redact_secrets(text: str) -> str:
    """Replace API keys and secrets in text with [REDACTED]."""
    result = text
    for pattern, replacement in SECRET_PATTERNS:
        result = pattern.sub(replacement, result)
    return result


def redact_json(data: Any) -> Any:
    """Recursively redact secrets in JSON-serializable data."""
    if isinstance(data, str):
        return redact_secrets(data)
    elif isinstance(data, dict):
        return {k: redact_json(v) for k, v in data.items()}
    elif isinstance(data, list):
        return [redact_json(item) for item in data]
    return data


class RequestLogger:
    """Handles request/response logging with atomic counter and redaction."""

    def __init__(self, log_dir: Path):
        self.log_dir = Path(log_dir).resolve()
        self.counter_file = self.log_dir / ".counter"
        self._lock = threading.Lock()
        self._initialized = False

    def ensure_initialized(self) -> None:
        """Create log directory and initialize counter if needed."""
        with self._lock:
            if self._initialized:
                return
            self.log_dir.mkdir(parents=True, exist_ok=True)
            self._init_counter()
            self._initialized = True

    def _init_counter(self) -> None:
        """Initialize counter from existing files or start at 1."""
        if self.counter_file.exists():
            try:
                content = self.counter_file.read_text(encoding="utf-8").strip()
                if content.isdigit():
                    return  # Counter already valid
            except Exception:
                pass
        # Counter missing or corrupted - find max existing N.md
        max_num = 0
        for f in self.log_dir.glob("*.md"):
            try:
                stem = f.stem
                if stem.isdigit():
                    max_num = max(max_num, int(stem))
            except Exception:
                pass
        self._write_counter_atomic(max_num)
        if max_num > 0:
            print(f"Предупреждение: .counter повреждён или отсутствует, восстановлено из файлов: {max_num}", file=sys.stderr)

    def _write_counter_atomic(self, value: int) -> None:
        """Write counter atomically using temp file + rename."""
        try:
            with tempfile.NamedTemporaryFile(
                mode='w', encoding='utf-8', dir=self.log_dir, delete=False, suffix='.tmp'
            ) as tmp:
                tmp.write(str(value))
                tmp_path = Path(tmp.name)
            tmp_path.replace(self.counter_file)
        except Exception as e:
            print(f"Предупреждение: не удалось записать .counter: {e}", file=sys.stderr)

    def get_next_number(self) -> int:
        """Get next request number atomically."""
        self.ensure_initialized()
        with self._lock:
            # Read current
            try:
                current = int(self.counter_file.read_text(encoding="utf-8").strip() or "0")
            except Exception:
                current = 0
            next_num = current + 1
            self._write_counter_atomic(next_num)
            return next_num

    def write_request_log(
        self,
        request_num: int,
        timestamp_utc: datetime,
        model: str,
        provider: str,
        request_data: dict,
        response_data: Optional[dict],
        error: Optional[str] = None,
    ) -> None:
        """Write a single request log file N.md."""
        self.ensure_initialized()

        # Redact secrets
        safe_request = redact_json(request_data)
        safe_response = redact_json(response_data) if response_data else None

        # Build markdown content
        lines = []
        lines.append(f"# Запрос #{request_num}")
        lines.append("")
        lines.append(f"**Время (UTC):** {timestamp_utc.isoformat(timespec='seconds')}")
        lines.append(f"**Модель:** {model}")
        lines.append(f"**Провайдер:** {provider}")
        lines.append("")

        lines.append("## Промпт")
        lines.append("")
        lines.append("```json")
        lines.append(json.dumps(safe_request, ensure_ascii=False, indent=2))
        lines.append("```")
        lines.append("")

        lines.append("## Ответ")
        lines.append("")
        if error:
            lines.append(f"*Ошибка: {error}*")
            lines.append("")
            if safe_response:
                lines.append("Частичный ответ:")
                lines.append("```json")
                lines.append(json.dumps(safe_response, ensure_ascii=False, indent=2))
                lines.append("```")
        elif safe_response is not None:
            lines.append("```json")
            lines.append(json.dumps(safe_response, ensure_ascii=False, indent=2))
            lines.append("```")
        else:
            lines.append("*Ответ не получен*")
        lines.append("")

        content = "\n".join(lines)

        # Write file
        log_file = self.log_dir / f"{request_num}.md"
        try:
            log_file.write_text(content, encoding="utf-8")
        except Exception as e:
            print(f"Предупреждение: не удалось записать лог запроса {request_num}: {e}", file=sys.stderr)


# Global logger instance (initialized on demand)
_global_logger: Optional[RequestLogger] = None


def get_logger(log_dir: Optional[Path] = None) -> Optional[RequestLogger]:
    """Get or create global request logger."""
    global _global_logger
    if _global_logger is None and log_dir is not None:
        _global_logger = RequestLogger(log_dir)
    return _global_logger


def init_logger(log_dir: Path) -> RequestLogger:
    """Initialize global request logger."""
    global _global_logger
    _global_logger = RequestLogger(log_dir)
    return _global_logger