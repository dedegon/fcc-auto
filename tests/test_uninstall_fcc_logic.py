#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Тест логики удаления FCC через запуск uninstaller_new.exe --selftest.
Не имитирует логику, а проверяет реальный скомпилированный код.
"""

import subprocess
import sys
import os

def run_selftest(exe_path: str) -> tuple[int, str]:
    """Запускает uninstaller_new.exe --selftest и возвращает (exit_code, stdout)."""
    try:
        result = subprocess.run(
            [exe_path, "--selftest"],
            capture_output=True,
            text=True,
            encoding='utf-8',
            timeout=30
        )
        return result.returncode, result.stdout
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"
    except Exception as e:
        return -1, f"ERROR: {e}"

def main():
    # Путь к exe: из аргумента или по умолчанию
    if len(sys.argv) > 1:
        exe_path = sys.argv[1]
    else:
        exe_path = r"C:\gags\dev\dist\uninstaller_new.exe"

    if not os.path.exists(exe_path):
        print(f"FAIL: exe not found at {exe_path}")
        return 1

    print(f"Testing: {exe_path} --selftest")
    print()

    exit_code, stdout = run_selftest(exe_path)

    print(stdout)

    # Проверяем exit code
    if exit_code != 0:
        print(f"FAIL: exit code = {exit_code} (expected 0)")
        return 1

    # Проверяем наличие строки "ВСЕ ТЕСТЫ ПРОШЛИ (PASS)"
    if "ВСЕ ТЕСТЫ ПРОШЛИ (PASS)" not in stdout:
        print("FAIL: expected 'ВСЕ ТЕСТЫ ПРОШЛИ (PASS)' not found in output")
        return 1

    print("PASS: selftest passed")
    return 0

if __name__ == "__main__":
    sys.exit(main())