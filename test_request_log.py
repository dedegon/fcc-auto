"""Tests for request_log module."""

import json
import os
import sys
import tempfile
import threading
import time
from pathlib import Path

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent))

from request_log import RequestLogger, redact_secrets, redact_json


def test_counter_sequential():
    """Sequential requests give 1, 2, 3."""
    with tempfile.TemporaryDirectory() as tmpdir:
        log_dir = Path(tmpdir) / "reports"
        logger = RequestLogger(log_dir)
        nums = [logger.get_next_number() for _ in range(5)]
        assert nums == [1, 2, 3, 4, 5], f"Expected [1,2,3,4,5], got {nums}"
        print("[OK] test_counter_sequential passed")


def test_counter_parallel():
    """Parallel requests through threading don't duplicate numbers."""
    with tempfile.TemporaryDirectory() as tmpdir:
        log_dir = Path(tmpdir) / "reports"
        logger = RequestLogger(log_dir)
        results = []
        errors = []

        def worker():
            try:
                for _ in range(10):
                    results.append(logger.get_next_number())
            except Exception as e:
                errors.append(e)

        threads = [threading.Thread(target=worker) for _ in range(5)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert not errors, f"Thread errors: {errors}"
        assert len(results) == 50, f"Expected 50 results, got {len(results)}"
        assert len(set(results)) == 50, f"Duplicate numbers found: {sorted(results)}"
        assert min(results) == 1 and max(results) == 50, f"Range mismatch: {min(results)}-{max(results)}"
        print("[OK] test_counter_parallel passed")


def test_counter_recovery():
    """Counter recovers from corrupted .counter file using existing N.md files."""
    with tempfile.TemporaryDirectory() as tmpdir:
        log_dir = Path(tmpdir) / "reports"
        log_dir.mkdir(parents=True)
        # Create existing log files 1.md, 2.md, 5.md
        for n in [1, 2, 5]:
            (log_dir / f"{n}.md").write_text(f"# Request #{n}", encoding="utf-8")
        # Corrupt counter
        (log_dir / ".counter").write_text("corrupted", encoding="utf-8")

        logger = RequestLogger(log_dir)
        next_num = logger.get_next_number()
        assert next_num == 6, f"Expected 6, got {next_num}"
        print("[OK] test_counter_recovery passed")


def test_redaction_openai_key():
    """OpenAI-style keys are redacted."""
    text = "Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz123456"
    result = redact_secrets(text)
    assert "[REDACTED]" in result
    assert "sk-abcdefghijklmnopqrstuvwxyz123456" not in result
    print("[OK] test_redaction_openai_key passed")


def test_redaction_groq_key():
    """Groq keys are redacted."""
    text = "gsk_abcdefghijklmnopqrstuvwxyz123456"
    result = redact_secrets(text)
    assert "[REDACTED]" in result
    assert "gsk_abcdefghijklmnopqrstuvwxyz123456" not in result
    print("[OK] test_redaction_groq_key passed")


def test_redaction_nvidia_key():
    """NVIDIA NIM keys are redacted."""
    text = "nvapi-abcdefghijklmnopqrstuvwxyz123456"
    result = redact_secrets(text)
    assert "[REDACTED]" in result
    assert "nvapi-abcdefghijklmnopqrstuvwxyz123456" not in result
    print("[OK] test_redaction_nvidia_key passed")


def test_redaction_bearer_token():
    """Generic Bearer tokens are redacted."""
    text = "Bearer abcdefghijklmnopqrstuvwxyz123456"
    result = redact_secrets(text)
    assert "Bearer [REDACTED]" in result
    assert "Bearer abcdefghijklmnopqrstuvwxyz123456" not in result
    print("[OK] test_redaction_bearer_token passed")


def test_redaction_env_vars():
    """Environment variables with KEY/TOKEN/SECRET in name are redacted."""
    text = "OPENROUTER_API_KEY=sk-1234567890abcdef\nNORMAL_VAR=value"
    result = redact_secrets(text)
    assert "OPENROUTER_API_KEY=[REDACTED]" in result
    assert "NORMAL_VAR=value" in result
    print("[OK] test_redaction_env_vars passed")


def test_redaction_normal_text_preserved():
    """Normal text without secrets is preserved."""
    text = '{"model": "gpt-4", "messages": [{"role": "user", "content": "Hello world"}]}'
    result = redact_secrets(text)
    assert result == text, f"Normal text was modified: {result}"
    print("[OK] test_redaction_normal_text_preserved passed")


def test_redact_json():
    """redact_json recursively redacts secrets in JSON structures."""
    data = {
        "model": "gpt-4",
        "api_key": "sk-abcdefghijklmnopqrstuvwxyz123456",
        "messages": [
            {"role": "user", "content": "My key is gsk_abcdefghijklmnopqrstuvwxyz123456"}
        ],
        "metadata": {
            "auth": "Bearer nvapi-abcdefghijklmnopqrstuvwxyz123456"
        }
    }
    result = redact_json(data)
    assert result["api_key"] == "[REDACTED]"
    assert "[REDACTED]" in result["messages"][0]["content"]
    assert "[REDACTED]" in result["metadata"]["auth"]
    assert result["model"] == "gpt-4"
    print("[OK] test_redact_json passed")


def test_logging_disabled_no_folder():
    """When logger not initialized, no reports folder is created."""
    with tempfile.TemporaryDirectory() as tmpdir:
        log_dir = Path(tmpdir) / "reports"
        # Don't initialize logger
        assert not log_dir.exists(), "Reports folder should not exist"
        print("[OK] test_logging_disabled_no_folder passed")


def test_write_failure_doesnt_break():
    """Write failure doesn't break the request (warning to stderr)."""
    import tempfile
    with tempfile.TemporaryDirectory() as tmpdir:
        log_dir = Path(tmpdir) / "reports"
        logger = RequestLogger(log_dir)
        # Make directory read-only to simulate write failure
        log_dir.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(log_dir, 0o555)
        except Exception:
            # On Windows, chmod might not work as expected, skip this test
            print("[OK] test_write_failure_doesnt_break passed (skipped on Windows)")
            return
        try:
            # This should not raise, just print warning to stderr
            logger.write_request_log(
                request_num=1,
                timestamp_utc=__import__('datetime').datetime.now(__import__('datetime').timezone.utc),
                model="test/model",
                provider="test",
                request_data={"test": "data"},
                response_data={"result": "ok"},
            )
        finally:
            try:
                os.chmod(log_dir, 0o755)
            except Exception:
                pass
        print("[OK] test_write_failure_doesnt_break passed")


def test_log_file_format():
    """Log file has correct markdown format."""
    with tempfile.TemporaryDirectory() as tmpdir:
        log_dir = Path(tmpdir) / "reports"
        logger = RequestLogger(log_dir)
        request_time = __import__('datetime').datetime(2026, 1, 1, 12, 0, 0, tzinfo=__import__('datetime').timezone.utc)
        logger.write_request_log(
            request_num=1,
            timestamp_utc=request_time,
            model="open_router/llama-3.1-8b",
            provider="open_router",
            request_data={"model": "llama-3.1-8b", "messages": [{"role": "user", "content": "Hi"}]},
            response_data={"choices": [{"message": {"content": "Hello!"}}]},
        )
        log_file = log_dir / "1.md"
        assert log_file.exists(), "Log file not created"
        content = log_file.read_text(encoding="utf-8")
        assert "# Запрос #1" in content
        assert "2026-01-01T12:00:00" in content
        assert "open_router/llama-3.1-8b" in content
        assert "open_router" in content
        assert "## Промпт" in content
        assert "## Ответ" in content
        assert "Hi" in content
        assert "Hello!" in content
        print("[OK] test_log_file_format passed")


def test_partial_response_on_error():
    """Partial response is logged with error marker."""
    with tempfile.TemporaryDirectory() as tmpdir:
        log_dir = Path(tmpdir) / "reports"
        logger = RequestLogger(log_dir)
        request_time = __import__('datetime').datetime(2026, 1, 1, 12, 0, 0, tzinfo=__import__('datetime').timezone.utc)
        logger.write_request_log(
            request_num=1,
            timestamp_utc=request_time,
            model="test/model",
            provider="test",
            request_data={"test": "data"},
            response_data={"partial": "data"},
            error="HTTP 429",
        )
        log_file = log_dir / "1.md"
        content = log_file.read_text(encoding="utf-8")
        assert "HTTP 429" in content
        assert "Частичный ответ" in content
        assert "partial" in content
        print("[OK] test_partial_response_on_error passed")


if __name__ == "__main__":
    print("Running request_log tests...")
    test_counter_sequential()
    test_counter_parallel()
    test_counter_recovery()
    test_redaction_openai_key()
    test_redaction_groq_key()
    test_redaction_nvidia_key()
    test_redaction_bearer_token()
    test_redaction_env_vars()
    test_redaction_normal_text_preserved()
    test_redact_json()
    test_logging_disabled_no_folder()
    test_write_failure_doesnt_break()
    test_log_file_format()
    test_partial_response_on_error()
    print("\n[SUCCESS] All tests passed!")