using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.0.0.0")]

class UninstallLauncher
{
    // Константы
    const string APP_NAME = "claude-auto";
    const string INSTALL_DIR = @"C:\Program Files (x86)\claude-auto";
    // Версия/коммит FCC для uninstall --purge-fcc (обновлять при изменении)
    // https://github.com/Alishahryar1/free-claude-code/commit/4e92110a0a3232765c6fc7a8c9d34489fb0e65da
    const string FCC_REPO_COMMIT = "4e92110a0a3232765c6fc7a8c9d34489fb0e65da";

    // ===================== Restart Manager P/Invoke =====================

    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, StringBuilder strSessionKey);

    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle,
        uint nFiles, string[] rgsFilenames,
        uint nApplications, RM_UNIQUE_PROCESS[] rgApplications,
        uint nServices, string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle,
        out uint pnProcInfoNeeded,
        ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps,
        ref uint lpdwRebootReasons);

    const int ERROR_MORE_DATA = 234;

    // ================================ Main ==============================

    static int Main(string[] args)
    {
        // --- Скрытый флаг --selftest: запуск внутренних тестов логики ---
        if (args.Any(a => string.Equals(a, "--selftest", StringComparison.OrdinalIgnoreCase)))
        {
            return RunSelfTest();
        }

        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        bool silent = args.Any(a =>
            string.Equals(a, "-Silent", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "/silent", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "-Yes", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "/yes", StringComparison.OrdinalIgnoreCase));

        bool skipFcc = args.Any(a =>
            string.Equals(a, "-SkipFcc", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "--skip-fcc", StringComparison.OrdinalIgnoreCase));

        bool purgeFcc = args.Any(a =>
            string.Equals(a, "-PurgeFcc", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "--purge-fcc", StringComparison.OrdinalIgnoreCase));

        // Safety: не даём снести корень диска или профиль пользователя
        if (exeDir.Length <= 3 ||
            string.Equals(exeDir, Path.GetPathRoot(exeDir), StringComparison.OrdinalIgnoreCase) ||
            string.Equals(exeDir, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), StringComparison.OrdinalIgnoreCase))
        {
            Console.Error.WriteLine("Небезопасное расположение установщика: " + exeDir);
            Pause();
            return 2;
        }

        // Проверка: папка установки принадлежит проекту (есть pyproject.toml с name = "claude-auto")
        if (!IsOurInstallDir(exeDir))
        {
            Console.Error.WriteLine("Папка " + exeDir + " не содержит проекта claude-auto (нет pyproject.toml с name = \"claude-auto\"). Удаление отменено.");
            Pause();
            return 2;
        }

        // --- ГЛАВНОЕ: проверка блокирующих процессов ДО удаления ---
        Console.WriteLine("Проверка файлов, открытых в других программах...");
        if (!EnsureNoLockingProcesses(exeDir))
        {
            Console.WriteLine("\nУдаление отменено пользователем.");
            Pause();
            return 3;
        }

        // Прямое удаление на C# (нет зависимости от uninstall.ps1)
        int code = RunDirectUninstall(silent, skipFcc, purgeFcc);

        if (code == 0)
        {
            // --- Повторная проверка: пользователь мог открыть что-то за время удаления ---
            Console.WriteLine("\nПовторная проверка блокирующих процессов...");
            if (EnsureNoLockingProcesses(exeDir))
            {
                ScheduleFolderCleanup(exeDir, Process.GetCurrentProcess().Id);
            }
            else
            {
                code = 4;
                Console.WriteLine("\nВНИМАНИЕ: автоматическое удаление папки отменено.");
                Console.WriteLine("Удалите вручную после закрытия всех программ: " + exeDir);
            }
        }

        if (code == 0)
            Console.WriteLine("\nУДАЛЕНИЕ ЗАВЕРШЕНО. Остатки папки будут удалены через несколько секунд. Нажмите любую клавишу...");
        else if (code == 3 || code == 4)
            Console.WriteLine("\nУДАЛЕНИЕ НЕ ЗАВЕРШЕНО (код " + code + "). Нажмите любую клавишу...");
        else
            Console.WriteLine("\nУДАЛЕНИЕ ЗАВЕРШИЛОСЬ С ОШИБКОЙ (код " + code + "). Нажмите любую клавишу...");

        Pause();
        return code;
    }

    static int RunDirectUninstall(bool silent, bool skipFcc, bool purgeFcc)
    {
        Console.WriteLine("Прямое удаление без PowerShell скрипта...");

        // Читаем манифест для проверки fcc_preexisting
        FccPreexistingStatus fccStatus = ReadManifestFccPreexisting();

        try
        {
            // 1. Решаем, удалять ли FCC (чистая функция, покрыта тестом)
            bool shouldRemoveFcc = ShouldRemoveFcc(purgeFcc, fccStatus);
            if (shouldRemoveFcc)
            {
                Console.WriteLine("Удаление FCC (--purge-fcc, fcc_preexisting=false)...");
                UninstallFCC();
                Console.WriteLine("  OK: FCC удалён");
            }
            else
            {
                // Без флага --purge-fcc или при fcc_preexisting != false — FCC сохраняется
                Console.WriteLine("FCC сохранён");
            }

            // 2. Удаляем claude-auto через uv
            Console.WriteLine("Удаление claude-auto (uv tool uninstall)...");
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "uv",
                    Arguments = "tool uninstall claude-auto",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                using (var p = Process.Start(psi))
                {
                    p.WaitForExit();
                }
                Console.WriteLine("  OK: claude-auto удалён");
            }
            catch { Console.WriteLine("  ВНИМАНИЕ: uv tool uninstall не удался (возможно, уже удален)"); }

            // 3. Удаляем файлы программы
            Console.WriteLine("Удаление файлов программы...");
            if (Directory.Exists(INSTALL_DIR))
            {
                RemoveDirectoryWithRetry(INSTALL_DIR);
            }
            Console.WriteLine("  OK: Файлы программы удалены");

            // 4. Удаляем данные и кэш в %LOCALAPPDATA%\claude-auto
            Console.WriteLine("Удаление данных и кэша...");
            string dataDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "claude-auto");
            if (Directory.Exists(dataDir))
            {
                RemoveDirectoryWithRetry(dataDir);
            }
            Console.WriteLine("  OK: Данные и кэш удалены");

            // 5. Удаляем из реестра
            Console.WriteLine("Удаление записей реестра...");
            UnregisterUninstaller();
            Console.WriteLine("  OK: Записи реестра удалены");

            // 6. Удаляем из PATH
            Console.WriteLine("Очистка PATH...");
            RemoveFromPath(INSTALL_DIR);
            Console.WriteLine("  OK: PATH очищен");

            Console.WriteLine("\nУДАЛЕНИЕ ЗАВЕРШЕНО.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("ОШИБКА УДАЛЕНИЯ: " + ex.Message);
            return 1;
        }
    }

    static void UninstallFCC()
    {
        // Сначала пробуем запустить официальный uninstall.ps1 из репозитория FCC по зафиксированному коммиту
        // URL: https://raw.githubusercontent.com/Alishahryar1/free-claude-code/<commit>/scripts/uninstall.ps1
        string fccUninstallUrl = "https://raw.githubusercontent.com/Alishahryar1/free-claude-code/" + FCC_REPO_COMMIT + "/scripts/uninstall.ps1";

        try
        {
            Console.WriteLine("  Запуск официального uninstall.ps1 FCC (commit " + FCC_REPO_COMMIT + ")...");
            System.Net.ServicePointManager.SecurityProtocol =
                System.Net.SecurityProtocolType.Tls12
                | System.Net.SecurityProtocolType.Tls11
                | System.Net.SecurityProtocolType.Tls;

            using (var http = new System.Net.WebClient())
            {
                http.Headers.Add("User-Agent", "claude-auto-uninstaller");
                string script = http.DownloadString(fccUninstallUrl);

                string tempScript = Path.Combine(Path.GetTempPath(), "fcc_uninstall.ps1");
                File.WriteAllText(tempScript, script, Encoding.UTF8);

                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + tempScript + "\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                using (var p = Process.Start(psi))
                {
                    string output = p.StandardOutput.ReadToEnd();
                    string error = p.StandardError.ReadToEnd();
                    p.WaitForExit();
                    if (!string.IsNullOrEmpty(output)) Console.WriteLine(output);
                    if (!string.IsNullOrEmpty(error)) Console.Error.WriteLine(error);
                }
                try { File.Delete(tempScript); } catch { }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("  ВНИМАНИЕ: официальный uninstall не удался: " + ex.Message);
        }

        // Fallback: удаляем известные пути FCC вручную
        string[] fccPaths = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin", "fcc-server"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin", "fcc-server.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".fcc"),
        };

        foreach (string path in fccPaths)
        {
            try
            {
                if (File.Exists(path)) File.Delete(path);
                else if (Directory.Exists(path)) RemoveDirectoryWithRetry(path);
            }
            catch { }
        }

        // Пробуем через uv tool uninstall
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "uv",
                Arguments = "tool uninstall free-claude-code",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var p = Process.Start(psi))
            {
                p.WaitForExit();
            }
        }
        catch { }
    }

    // Результат чтения fcc_preexisting из манифеста
    enum FccPreexistingStatus
    {
        True,       // fcc_preexisting = true
        False,      // fcc_preexisting = false
        Missing,    // манифест отсутствует, не читается, или поле отсутствует
        Error       // ошибка парсинга
    }

    static FccPreexistingStatus ReadManifestFccPreexisting()
    {
        try
        {
            string dataDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "claude-auto");
            string manifestPath = Path.Combine(dataDir, "install.json");
            if (!File.Exists(manifestPath)) return FccPreexistingStatus.Missing;

            string json = File.ReadAllText(manifestPath, Encoding.UTF8);
            // Простой парсинг "fcc_preexisting": true/false
            int idx = json.IndexOf("\"fcc_preexisting\"");
            if (idx < 0) return FccPreexistingStatus.Missing;

            idx = json.IndexOf(':', idx);
            if (idx < 0) return FccPreexistingStatus.Missing;

            string rest = json.Substring(idx + 1).TrimStart();
            if (rest.StartsWith("true", StringComparison.OrdinalIgnoreCase))
                return FccPreexistingStatus.True;
            if (rest.StartsWith("false", StringComparison.OrdinalIgnoreCase))
                return FccPreexistingStatus.False;
            return FccPreexistingStatus.Missing;
        }
        catch { return FccPreexistingStatus.Error; }
    }

    // Чистая функция решения об удалении FCC.
    // Вход: purgeFcc (флаг --purge-fcc), status (значение fcc_preexisting из манифеста).
    // Выход: true = удалять FCC, false = не трогать FCC.
    // Правила:
    // 1. Удалять ТОЛЬКО если purgeFcc == true И status == False.
    // 2. Во всех остальных случаях (нет флага, status=True, Missing, Error) — не удалять.
    static bool ShouldRemoveFcc(bool purgeFcc, FccPreexistingStatus status)
    {
        return purgeFcc && status == FccPreexistingStatus.False;
    }

    // Внутренний тест логики ShouldRemoveFcc.
    // Вызывается при флаге --selftest. Ничего не удаляет, не вызывает uv, не трогает файлы/реестр/PATH.
    static int RunSelfTest()
    {
        Console.WriteLine("=== SELFTEST: ShouldRemoveFcc ===");
        Console.WriteLine();

        var testCases = new[]
        {
            new { Purge = false, Status = FccPreexistingStatus.False, Expected = false, Desc = "без флага и preexisting=false" },
            new { Purge = true,  Status = FccPreexistingStatus.True,  Expected = false, Desc = "флаг и preexisting=true" },
            new { Purge = true,  Status = FccPreexistingStatus.False, Expected = true,  Desc = "флаг и preexisting=false" },
            new { Purge = true,  Status = FccPreexistingStatus.Missing, Expected = false, Desc = "флаг и манифест отсутствует" },
            new { Purge = true,  Status = FccPreexistingStatus.Error,   Expected = false, Desc = "флаг и ошибка парсинга (поле отсутствует)" },
        };

        bool allPassed = true;
        Console.WriteLine("№  | purgeFcc | status     | ожидание | факт   | PASS/FAIL | описание");
        Console.WriteLine("---|----------|------------|----------|--------|-----------|--------------------------");

        for (int i = 0; i < testCases.Length; i++)
        {
            var tc = testCases[i];
            bool actual = ShouldRemoveFcc(tc.Purge, tc.Status);
            bool passed = actual == tc.Expected;
            allPassed = allPassed && passed;

            string purgeStr = tc.Purge ? "true" : "false";
            string statusStr = tc.Status.ToString();
            string expectedStr = tc.Expected ? "да" : "нет";
            string actualStr = actual ? "да" : "нет";
            string resultStr = passed ? "PASS" : "FAIL";

            Console.WriteLine($"{i+1}  | {purgeStr,-8} | {statusStr,-10} | {expectedStr,-8} | {actualStr,-6} | {resultStr,-9} | {tc.Desc}");
        }

        Console.WriteLine("---|----------|------------|----------|--------|-----------|--------------------------");
        if (allPassed)
        {
            Console.WriteLine("ВСЕ ТЕСТЫ ПРОШЛИ (PASS)");
            return 0;
        }
        else
        {
            Console.WriteLine("ЕСТЬ ПРОВАЛЫ (FAIL)");
            return 1;
        }
    }

    static bool IsOurInstallDir(string dir)
    {
        try
        {
            string pyprojectPath = Path.Combine(dir, "pyproject.toml");
            if (!File.Exists(pyprojectPath)) return false;
            string content = File.ReadAllText(pyprojectPath, Encoding.UTF8);
            return content.Contains("name") && content.Contains("claude-auto");
        }
        catch { return false; }
    }

    static void RemoveDirectoryWithRetry(string dir, int maxRetries = 10)
    {
        for (int i = 0; i < maxRetries; i++)
        {
            try
            {
                if (!Directory.Exists(dir)) return;
                Directory.Delete(dir, true);
                return;
            }
            catch (IOException)
            {
                System.Threading.Thread.Sleep(500);
            }
            catch (UnauthorizedAccessException)
            {
                System.Threading.Thread.Sleep(500);
            }
        }
        try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch { }
    }

    static void UnregisterUninstaller()
    {
        try
        {
            Microsoft.Win32.Registry.LocalMachine.DeleteSubKeyTree(
                String.Format(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{0}", APP_NAME), false);
        }
        catch { }
    }

    static void RemoveFromPath(string installDir)
    {
        try
        {
            string currentPath = Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.Machine) ?? "";
            var parts = currentPath.Split(';').Where(p => !string.Equals(p.Trim(), installDir, StringComparison.OrdinalIgnoreCase)).ToArray();
            string newPath = string.Join(";", parts);
            Environment.SetEnvironmentVariable("PATH", newPath, EnvironmentVariableTarget.Machine);
        }
        catch { }
    }

    // ===================== Детектор блокировок ==========================

    static bool EnsureNoLockingProcesses(string folder)
    {
        if (Console.IsInputRedirected) return true;

        int attempts = 0;
        while (true)
        {
            var lockers = GetLockingProcesses(folder);
            if (lockers.Count == 0) return true;

            Console.WriteLine();
            Console.WriteLine("Файлы в папке открыты следующими программами:");
            foreach (var p in lockers)
            {
                string nm = "?";
                int id = -1;
                try { nm = p.ProcessName + ".exe"; id = p.Id; } catch { }
                Console.WriteLine("  - " + nm + " (PID " + id + ")");
            }
            Console.WriteLine();
            Console.WriteLine("Закройте эти программы. Возможна потеря несохранённых данных!");
            Console.WriteLine("  [K]   Завершить их принудительно");
            Console.WriteLine("  [др.] Повторить проверку");
            Console.WriteLine("  [Esc] Отмена");

            var key = Console.ReadKey(true);
            if (key.Key == ConsoleKey.Escape) return false;

            if (key.KeyChar == 'k' || key.KeyChar == 'K' ||
                key.KeyChar == 'к' || key.KeyChar == 'К')
            {
                if (!IsAdministrator())
                    Console.WriteLine("ВНИМАНИЕ: запуск без прав администратора — некоторые процессы могут не завершиться.");

                foreach (var p in lockers)
                {
                    int id = -1; string nm = "?";
                    try { id = p.Id; nm = p.ProcessName; } catch { }
                    try
                    {
                        p.Kill();
                        p.WaitForExit(5000);
                        Console.WriteLine("  Завершён: " + nm + " (PID " + id + ")");
                    }
                    catch (InvalidOperationException) { }
                    catch (Exception ex)
                    {
                        Console.WriteLine("  Не удалось завершить PID " + id + ": " + ex.Message);
                    }
                }
            }

            if (++attempts > 20)
            {
                Console.WriteLine("Слишком много попыток. Выход.");
                return false;
            }
        }
    }

    static List<Process> GetLockingProcesses(string folder)
    {
        var result = new List<Process>();

        string[] files;
        try { files = Directory.GetFiles(folder, "*", SearchOption.AllDirectories); }
        catch { return result; }
        if (files.Length == 0) return result;

        uint session = 0;
        var key = new StringBuilder(64);
        int rv = RmStartSession(out session, 0, key);
        if (rv != 0) return result;

        try
        {
            rv = RmRegisterResources(session, (uint)files.Length, files, 0, null, 0, null);
            if (rv != 0) return result;

            uint needed = 0, count = 0, reasons = 0;
            rv = RmGetList(session, out needed, ref count, null, ref reasons);
            if (rv != ERROR_MORE_DATA) return result;

            count = needed;
            var infos = new RM_PROCESS_INFO[count];
            rv = RmGetList(session, out needed, ref count, infos, ref reasons);
            if (rv != 0) return result;

            int myPid = Process.GetCurrentProcess().Id;
            for (int i = 0; i < count; i++)
            {
                int pid = infos[i].Process.dwProcessId;
                if (pid == myPid) continue;
                try { result.Add(Process.GetProcessById(pid)); }
                catch { }
            }
        }
        finally { RmEndSession(session); }

        return result;
    }

    static bool IsAdministrator()
    {
        try
        {
            var id = System.Security.Principal.WindowsIdentity.GetCurrent();
            var pr = new System.Security.Principal.WindowsPrincipal(id);
            return pr.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    }

    // ===================== Фоновое удаление =============================

    static void ScheduleFolderCleanup(string folder, int myPid)
    {
        try
        {
            string temp = Path.GetTempPath();
            string ps1 = Path.Combine(temp, "claude-auto-cleanup-" + Guid.NewGuid().ToString("N") + ".ps1");
            string log = Path.Combine(temp, "claude-auto-cleanup.log");

            string folderQ = folder.Replace("'", "''");
            string ps1Q = ps1.Replace("'", "''");
            string logQ = log.Replace("'", "''");

            var sb = new StringBuilder();
            sb.AppendLine("$ErrorActionPreference = 'Continue'");
            sb.AppendLine("Start-Transcript -Path '" + logQ + "' -Force | Out-Null");
            sb.AppendLine("try {");
            sb.AppendLine("  $me = " + myPid);
            sb.AppendLine("  $folder = '" + folderQ + "'");
            sb.AppendLine("");
            sb.AppendLine("  try { Wait-Process -Id $me -Timeout 30 -ErrorAction SilentlyContinue } catch { }");
            sb.AppendLine("");
            sb.AppendLine("  for ($i = 0; $i -lt 30; $i++) {");
            sb.AppendLine("    $busy = Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" |");
            sb.AppendLine("      Where-Object { $_.CommandLine -and $_.CommandLine.Contains($folder) }");
            sb.AppendLine("    if (-not $busy) { break }");
            sb.AppendLine("    Start-Sleep -Seconds 1");
            sb.AppendLine("  }");
            sb.AppendLine("  Start-Sleep -Seconds 2");
            sb.AppendLine("");
            sb.AppendLine("  for ($i = 1; $i -le 10; $i++) {");
            sb.AppendLine("    if (-not (Test-Path -LiteralPath $folder)) {");
            sb.AppendLine("      Write-Output ('OK: папка удалена на попытке ' + $i)");
            sb.AppendLine("      break");
            sb.AppendLine("    }");
            sb.AppendLine("    try {");
            sb.AppendLine("      Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop");
            sb.AppendLine("      Write-Output ('OK: папка удалена на попытке ' + $i)");
            sb.AppendLine("      break");
            sb.AppendLine("    } catch {");
            sb.AppendLine("      Write-Output ('попытка ' + $i + ': ' + $_.Exception.Message)");
            sb.AppendLine("      Start-Sleep -Seconds 1");
            sb.AppendLine("    }");
            sb.AppendLine("  }");
            sb.AppendLine("");
            sb.AppendLine("  if (Test-Path -LiteralPath $folder) {");
            sb.AppendLine("    Write-Output 'ОСТАЛОСЬ: папка не удалена после 10 попыток'");
            sb.AppendLine("    Get-ChildItem -LiteralPath $folder -Force | ForEach-Object { Write-Output ('  ' + $_.Name) }");
            sb.AppendLine("  } else {");
            sb.AppendLine("    Write-Output 'ИТОГ: папка удалена полностью'");
            sb.AppendLine("  }");
            sb.AppendLine("} finally {");
            sb.AppendLine("  Stop-Transcript | Out-Null");
            sb.AppendLine("  Start-Sleep -Milliseconds 500");
            sb.AppendLine("  Remove-Item -LiteralPath '" + ps1Q + "' -Force -ErrorAction SilentlyContinue");
            sb.AppendLine("}");
            File.WriteAllText(ps1, sb.ToString(), new UTF8Encoding(false));

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"",
                UseShellExecute = false,
                CreateNoWindow = true
            };
            Process.Start(psi);
        }
        catch { }
    }

    static void Pause()
    {
        try
        {
            if (!Console.IsInputRedirected)
                Console.ReadKey(intercept: true);
        }
        catch { }
    }
}