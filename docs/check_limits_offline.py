#!/usr/bin/env python3
"""Offline unit checks for LimitsRegistry daily limits parsing."""
import tempfile
import time
from pathlib import Path
from model_limits.registry import LimitsRegistry

def test_case(name: str, func):
    try:
        result = func()
        status = "PASS" if result else "FAIL"
        print(f"  [{status}] {name}")
        return result
    except Exception as e:
        print(f"  [FAIL] {name} - Exception: {e}")
        return False

def main():
    print("=== Offline LimitsRegistry checks ===\n")
    results = []

    # Test 1: Parse headers with Limit=50, Remaining=0, Reset in future (ms)
    # Expect describe to show "осталось 0/50" and "сброс HH:MM UTC"
    def test1():
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            tmp_path = Path(f.name)
        try:
            reg = LimitsRegistry(tmp_path)
            reset_ms = int((time.time() + 3600) * 1000)  # 1 hour from now in ms
            headers = {
                "x-ratelimit-limit": "50",
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": str(reset_ms),
            }
            reg.observe("test/model1", headers)
            lim, rem, rst = reg.get_daily_remaining("test/model1")
            ok = (lim == 50 and rem == 0 and rst is not None and abs(rst - reset_ms/1000) < 2)
            desc = reg.describe("test/model1")
            # New behavior: remaining=0, reset future -> "осталось 0/50 в день, сброс HH:MM UTC"
            ok = ok and ("осталось 0/50" in desc) and ("сброс" in desc) and ("UTC" in desc)
            return ok
        finally:
            tmp_path.unlink(missing_ok=True)
    results.append(test_case("Limit=50 Remaining=0 Reset future (ms)", test1))

    # Test 2: Headers without Remaining -> model NOT excluded (daily_remaining=None)
    def test2():
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            tmp_path = Path(f.name)
        try:
            reg = LimitsRegistry(tmp_path)
            headers = {
                "x-ratelimit-limit": "100",
                # no remaining
                "x-ratelimit-reset": str(int((time.time() + 3600) * 1000)),
            }
            reg.observe("test/model2", headers)
            lim, rem, rst = reg.get_daily_remaining("test/model2")
            # daily_remaining should be None, not 0
            return lim == 100 and rem is None
        finally:
            tmp_path.unlink(missing_ok=True)
    results.append(test_case("No Remaining header -> daily_remaining=None", test2))

    # Test 3: Remaining=0 with Reset in past -> model available (limit reset)
    def test3():
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            tmp_path = Path(f.name)
        try:
            reg = LimitsRegistry(tmp_path)
            reset_ms = int((time.time() - 3600) * 1000)  # 1 hour ago in ms
            headers = {
                "x-ratelimit-limit": "50",
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": str(reset_ms),
            }
            reg.observe("test/model3", headers)
            lim, rem, rst = reg.get_daily_remaining("test/model3")
            # reset in past -> should be treated as available (no block)
            return lim == 50 and rem == 0 and rst is not None and rst < time.time()
        finally:
            tmp_path.unlink(missing_ok=True)
    results.append(test_case("Remaining=0 Reset in past -> available", test3))

    # Test 4: Headers in different case (HTTP headers case-insensitive)
    def test4():
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            tmp_path = Path(f.name)
        try:
            reg = LimitsRegistry(tmp_path)
            reset_ms = int((time.time() + 3600) * 1000)
            headers = {
                "X-RateLimit-Limit": "75",
                "X-RateLimit-Remaining": "25",
                "X-RateLimit-Reset": str(reset_ms),
            }
            reg.observe("test/model4", headers)
            lim, rem, rst = reg.get_daily_remaining("test/model4")
            return lim == 75 and rem == 25
        finally:
            tmp_path.unlink(missing_ok=True)
    results.append(test_case("Case-insensitive headers (X-RateLimit-*)", test4))

    # Test 5: Reset in seconds (value < 1e11) not milliseconds
    def test5():
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            tmp_path = Path(f.name)
        try:
            reg = LimitsRegistry(tmp_path)
            reset_sec = int(time.time() + 3600)  # 1 hour from now in seconds
            headers = {
                "x-ratelimit-limit": "30",
                "x-ratelimit-remaining": "10",
                "x-ratelimit-reset": str(reset_sec),  # seconds, not ms
            }
            reg.observe("test/model5", headers)
            lim, rem, rst = reg.get_daily_remaining("test/model5")
            # Parser should detect seconds (value < 1e11) and not treat as ms
            ok = lim == 30 and rem == 10 and rst is not None
            # Should be roughly reset_sec, not reset_sec/1000
            ok = ok and abs(rst - reset_sec) < 5
            return ok
        finally:
            tmp_path.unlink(missing_ok=True)
    results.append(test_case("Reset in seconds (< 1e11) not ms", test5))

    # Test 6: Retry-After as fallback for reset
    def test6():
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            tmp_path = Path(f.name)
        try:
            reg = LimitsRegistry(tmp_path)
            headers = {
                "x-ratelimit-limit": "20",
                "x-ratelimit-remaining": "0",
                "retry-after": "120",  # 2 minutes
            }
            reg.cooldown("test/model6", headers)  # cooldown also parses daily
            lim, rem, rst = reg.get_daily_remaining("test/model6")
            ok = lim == 20 and rem == 0 and rst is not None
            # reset should be ~now + 120
            ok = ok and abs(rst - (time.time() + 120)) < 5
            return ok
        finally:
            tmp_path.unlink(missing_ok=True)
    results.append(test_case("Retry-After fallback for reset", test6))

    # Test 7: describe() format with daily remaining
    def test7():
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            tmp_path = Path(f.name)
        try:
            reg = LimitsRegistry(tmp_path)
            reset_ms = int((time.time() + 3600) * 1000)
            headers = {
                "x-ratelimit-limit-tokens": "50000",
                "x-ratelimit-limit": "40",
                "x-ratelimit-remaining": "5",
                "x-ratelimit-reset": str(reset_ms),
            }
            reg.observe("test/model7", headers)
            desc = reg.describe("test/model7")
            # Should contain tpm (50k/мин) and daily remaining
            return ("50k/мин" in desc or "50/мин" in desc) and "осталось 5/40" in desc
        finally:
            tmp_path.unlink(missing_ok=True)
    results.append(test_case("describe() format with tpm and daily", test7))

    # Test 8: is_daily_available False for remaining=0 and reset in future
    # Also check filter_available excludes exhausted model
    def test8():
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            tmp_path = Path(f.name)
        try:
            reg = LimitsRegistry(tmp_path)
            reset_ms = int((time.time() + 3600) * 1000)  # 1 hour future
            headers = {
                "x-ratelimit-limit": "50",
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": str(reset_ms),
            }
            reg.observe("test/model8a", headers)
            # Model without daily data
            reg.observe("test/model8b", {"x-ratelimit-limit": "100"})
            # is_daily_available should return False for exhausted model
            available_a = reg.is_daily_available("test/model8a")
            available_b = reg.is_daily_available("test/model8b")
            # filter_available should only return model8b
            filtered = reg.filter_available(["test/model8a", "test/model8b"])
            return (available_a is False) and (available_b is True) and (filtered == ["test/model8b"])
        finally:
            tmp_path.unlink(missing_ok=True)
    results.append(test_case("is_daily_available False + filter_available", test8))

    # Test 9: is_daily_available True for remaining=0 and reset in past; describe contains "сброс суток прошёл"
    def test9():
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            tmp_path = Path(f.name)
        try:
            reg = LimitsRegistry(tmp_path)
            reset_ms = int((time.time() - 3600) * 1000)  # 1 hour ago
            headers = {
                "x-ratelimit-limit": "50",
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": str(reset_ms),
            }
            reg.observe("test/model9", headers)
            # is_daily_available should return True (reset passed)
            available = reg.is_daily_available("test/model9")
            # describe should contain "сброс суток прошёл"
            desc = reg.describe("test/model9")
            has_reset_passed = "сброс суток прошёл" in desc
            return available is True and has_reset_passed
        finally:
            tmp_path.unlink(missing_ok=True)
    results.append(test_case("is_daily_available True: remaining=0 reset past; describe=сброс суток прошёл", test9))

    # Test 10: remaining=0, reset in future: describe contains "сброс", "UTC", "осталось 0/50"
    def test10():
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            tmp_path = Path(f.name)
        try:
            reg = LimitsRegistry(tmp_path)
            reset_ms = int((time.time() + 3600) * 1000)  # 1 hour future
            headers = {
                "x-ratelimit-limit": "50",
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": str(reset_ms),
            }
            reg.observe("test/model10", headers)
            desc = reg.describe("test/model10")
            # Should contain "осталось 0/50", "сброс", "UTC"
            return ("осталось 0/50" in desc) and ("сброс" in desc) and ("UTC" in desc)
        finally:
            tmp_path.unlink(missing_ok=True)
    results.append(test_case("describe: remaining=0 reset future -> 0/50 + сброс UTC", test10))

    # Test 11: filter_available with exhausted (reset future) and no-data models
    def test11():
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            tmp_path = Path(f.name)
        try:
            reg = LimitsRegistry(tmp_path)
            reset_ms = int((time.time() + 3600) * 1000)  # 1 hour future
            # Model A: exhausted, reset future
            reg.observe("test/model11a", {
                "x-ratelimit-limit": "50",
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": str(reset_ms),
            })
            # Model B: no daily data
            reg.observe("test/model11b", {"x-ratelimit-limit": "100"})
            # Model C: has remaining > 0
            reg.observe("test/model11c", {
                "x-ratelimit-limit": "30",
                "x-ratelimit-remaining": "15",
                "x-ratelimit-reset": str(reset_ms),
            })
            # filter_available should return only B and C (not A)
            filtered = reg.filter_available(["test/model11a", "test/model11b", "test/model11c"])
            return filtered == ["test/model11b", "test/model11c"]
        finally:
            tmp_path.unlink(missing_ok=True)
    results.append(test_case("filter_available: excludes exhausted, keeps no-data and available", test11))

    # Summary
    passed = sum(results)
    total = len(results)
    print(f"\n=== Summary: {passed}/{total} passed ===")
    if passed == total:
        print("ALL TESTS PASSED")
        return 0
    else:
        print("SOME TESTS FAILED")
        return 1

if __name__ == "__main__":
    exit(main())