using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

[assembly: System.Reflection.AssemblyVersion("1.0.2.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.0.2.0")]

class InstallLauncher
{
    // Константы
    const string APP_NAME = "fcc-auto-claude";
    const string INSTALL_DIR = @"C:\Program Files (x86)\fcc-auto-claude";
    const string FCC_INSTALL_URL = "https://raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/install.ps1";
    const string GITHUB_REPO = "https://github.com/your-repo/fcc-auto"; // Заменить на реальный репозиторий
    const string VERSION = "1.0.2";

    // ================================ Main ==============================

    static int Main(string[] args)
    {
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);

        // Проверка прав администратора
        if (!IsAdministrator())
        {
            Console.WriteLine("Требуются права администратора для установки в Program Files.");
            Console.WriteLine("Запустите установщик от имени администратора.");
            Pause();
            return 1;
        }

        // Парсинг аргументов
        bool isUninstall = args.Any(a =>
            string.Equals(a, "-Uninstall", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "/uninstall", StringComparison.OrdinalIgnoreCase));

        bool silent = args.Any(a =>
            string.Equals(a, "-Silent", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "/silent", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "-Yes", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "/yes", StringComparison.OrdinalIgnoreCase));

        bool downloadOnly = args.Any(a =>
            string.Equals(a, "-DownloadOnly", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "/downloadonly", StringComparison.OrdinalIgnoreCase));

        bool skipFcc = args.Any(a =>
            string.Equals(a, "-SkipFcc", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "--skip-fcc", StringComparison.OrdinalIgnoreCase));

        if (isUninstall)
        {
            return RunUninstall(exeDir, silent, skipFcc).Result;
        }

        if (downloadOnly)
        {
            return DownloadInstallerOnly(exeDir).Result;
        }

        return RunInstall(exeDir, silent, skipFcc).Result;
    }

    // ============================ Установка =============================

    static async Task<int> RunInstall(string exeDir, bool silent, bool skipFcc)
    {
        // Проверка: уже установлена ли программа?
        bool isUpdate = false;
        string existingVersion = GetInstalledVersion();
        if (!string.IsNullOrEmpty(existingVersion))
        {
            Version existing = Version.Parse(existingVersion);
            Version current = Version.Parse(VERSION);
            if (existing >= current)
            {
                Console.WriteLine("Версия " + existingVersion + " уже установлена (текущая: " + VERSION + ").");
                Console.Write("Переустановить? (y/N): ");
                string ans = Console.ReadLine();
                if (!ans.Equals("y", StringComparison.OrdinalIgnoreCase) &&
                    !ans.Equals("yes", StringComparison.OrdinalIgnoreCase))
                {
                    Console.WriteLine("Отменено.");
                    return 0;
                }
                isUpdate = true;
                Console.WriteLine("=== Обновление " + APP_NAME + " v" + existingVersion + " -> v" + VERSION + " ===");
            }
            else
            {
                Console.WriteLine("=== Обновление " + APP_NAME + " v" + existingVersion + " -> v" + VERSION + " ===");
                isUpdate = true;
            }
        }
        else
        {
            Console.WriteLine("=== Установка " + APP_NAME + " v" + VERSION + " ===");
        }
        Console.WriteLine("Целевая папка: " + INSTALL_DIR);
        Console.WriteLine();

        try
        {
            // 1. Создаём папку установки
            Step("Создание папки установки");
            Directory.CreateDirectory(INSTALL_DIR);
            Ok("Папка создана: " + INSTALL_DIR);

            // 2. Копируем файлы программы
            Step("Копирование файлов программы");
            await CopyProgramFiles(exeDir, INSTALL_DIR);
            Ok("Файлы программы скопированы");

            // 3. Устанавливаем FCC
            if (!skipFcc)
            {
                Step("Установка FCC (Free Claude Code)");
                await InstallFCC(silent);
                Ok("FCC установлен");
            }
            else
            {
                Step("Установка FCC (пропущена --skip-fcc)");
                Ok("FCC пропущен");
            }

            // 4. Создаём uninstall.exe
            Step("Создание uninstall.exe");
            ExtractUninstaller(INSTALL_DIR);
            Ok("uninstall.exe создан");

            // 5. Создаём записи в реестре для Add/Remove Programs
            Step("Регистрация в системе");
            RegisterUninstaller();
            Ok("Записи в реестре созданы");

            // 6. Добавляем в PATH (опционально)
            Step("Настройка PATH");
            AddToPath(INSTALL_DIR);
            Ok("PATH обновлён (перезапустите терминал)");

            Console.WriteLine();
            string action = isUpdate ? "Обновление" : "Установка";
            Console.WriteLine("=== " + action + " завершен" + (isUpdate ? "о" : "а") + " успешно! ===");
            Console.WriteLine("Программа " + (isUpdate ? "обновлена" : "установлена") + " в: " + INSTALL_DIR);
            Console.WriteLine("Для удаления запустите: " + INSTALL_DIR + "\\uninstall.exe");
            Console.WriteLine("Или используйте 'Добавление/удаление программ' в Windows.");
            Console.WriteLine();
            Console.WriteLine("Запустите 'claude-auto' в новой консоли для начала работы.");

            if (!silent) Pause();
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("\nОШИБКА УСТАНОВКИ: " + ex.Message);
            Console.Error.WriteLine("Подробности: " + ex);

            // Попытка отката
            try { RollbackInstallation(); } catch { }

            if (!silent) Pause();
            return 1;
        }
    }

    static async Task CopyProgramFiles(string sourceDir, string targetDir)
    {
        // Файлы для копирования (Python скрипты и конфигурация)
        string[] filesToCopy = new[]
        {
            "claude_auto.py",
            "claude_filter.py",
            "scanner.py",
            "scanner_config.py",
            "pyproject.toml",
            "README.md"
        };

        // Если исходные файлы не в sourceDir (например, запуск из build/), ищем в родительской папке
        if (!File.Exists(Path.Combine(sourceDir, "claude_auto.py")))
        {
            string parentDir = Path.GetDirectoryName(sourceDir);
            if (Directory.Exists(parentDir) && File.Exists(Path.Combine(parentDir, "claude_auto.py")))
            {
                sourceDir = parentDir;
            }
        }

        // Копируем Python файлы
        foreach (string file in filesToCopy)
        {
            string src = Path.Combine(sourceDir, file);
            string dst = Path.Combine(targetDir, file);
            if (File.Exists(src))
            {
                File.Copy(src, dst, true);
                Console.WriteLine("  Скопирован: " + file);
            }
            else
            {
                Console.WriteLine("  ВНИМАНИЕ: не найден " + file + " в " + sourceDir);
            }
        }

        // Копируем папку model_limits если есть
        string modelLimitsSrc = Path.Combine(sourceDir, "model_limits");
        string modelLimitsDst = Path.Combine(targetDir, "model_limits");
        if (Directory.Exists(modelLimitsSrc))
        {
            CopyDirectory(modelLimitsSrc, modelLimitsDst);
            Console.WriteLine("  Скопирована папка: model_limits");
        }

        // Создаём wrapper скрипт для запуска
        CreateWrapperScript(targetDir);
    }

    static void CopyDirectory(string source, string target)
    {
        Directory.CreateDirectory(target);
        foreach (string file in Directory.GetFiles(source))
        {
            string dest = Path.Combine(target, Path.GetFileName(file));
            File.Copy(file, dest, true);
        }
        foreach (string dir in Directory.GetDirectories(source))
        {
            string dest = Path.Combine(target, Path.GetFileName(dir));
            CopyDirectory(dir, dest);
        }
    }

    static void CreateWrapperScript(string installDir)
    {
        // Создаём bat-файл для запуска claude-auto
        string wrapper = "@echo off\n" +
            "REM Wrapper для запуска claude-auto\n" +
            "set LOCALAPPDATA=%LOCALAPPDATA%\n" +
            "set USERPROFILE=%USERPROFILE%\n" +
            "python \"" + installDir + "\\claude_auto.py\" %*\n";
        File.WriteAllText(Path.Combine(installDir, "claude-auto.bat"), wrapper);

        // Также создаём Python entry point через pipx/uv если доступно
        string pythonWrapper = "#!/usr/bin/env python3\n" +
            "import sys\n" +
            "import os\n" +
            "sys.path.insert(0, r'" + installDir + "')\n" +
            "from claude_auto import main\n" +
            "if __name__ == '__main__':\n" +
            "    main()\n";
        File.WriteAllText(Path.Combine(installDir, "claude-auto"), pythonWrapper);
    }

    static async Task InstallFCC(bool silent)
    {
        // Enable TLS 1.2/1.1/1.0 для .NET Framework 4.x
        System.Net.ServicePointManager.SecurityProtocol =
            System.Net.SecurityProtocolType.Tls12
            | System.Net.SecurityProtocolType.Tls11
            | System.Net.SecurityProtocolType.Tls;

        Console.WriteLine("  Загрузка установщика FCC...");

        using (var http = new HttpClient())
        {
            http.Timeout = TimeSpan.FromMinutes(5);
            string script = await http.GetStringAsync(FCC_INSTALL_URL);

            // Сохраняем во временный файл
            string tempScript = Path.Combine(Path.GetTempPath(), "fcc_install.ps1");
            File.WriteAllText(tempScript, script, Encoding.UTF8);

            // Запускаем установщик FCC
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + tempScript + "\"",
                UseShellExecute = false,
                CreateNoWindow = silent,
                RedirectStandardOutput = !silent,
                RedirectStandardError = !silent,
                Verb = "runas" // Запрос прав админа
            };

            using (var proc = Process.Start(psi))
            {
                if (!silent)
                {
                    string output = await proc.StandardOutput.ReadToEndAsync();
                    string error = await proc.StandardError.ReadToEndAsync();
                    Console.WriteLine(output);
                    if (!string.IsNullOrEmpty(error))
                        Console.Error.WriteLine(error);
                }
                proc.WaitForExit();

                if (proc.ExitCode != 0)
                    throw new Exception("Установщик FCC завершился с кодом " + proc.ExitCode);
            }

            // Удаляем временный скрипт
            try { File.Delete(tempScript); } catch { }
        }
    }

    static void RegisterUninstaller()
    {
        string uninstallExe = Path.Combine(INSTALL_DIR, "uninstall.exe");
        string displayName = "fcc-auto-claude (Free Claude Code Auto)";

        try
        {
            using (var key = Microsoft.Win32.Registry.LocalMachine.CreateSubKey(
                String.Format(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{0}", APP_NAME)))
            {
                key.SetValue("DisplayName", displayName);
                key.SetValue("DisplayVersion", VERSION);
                key.SetValue("Publisher", "fcc-auto-claude");
                key.SetValue("UninstallString", "\"" + uninstallExe + "\" -Silent");
                key.SetValue("QuietUninstallString", "\"" + uninstallExe + "\" -Silent -Yes");
                key.SetValue("InstallLocation", INSTALL_DIR);
                key.SetValue("DisplayIcon", uninstallExe);
                key.SetValue("NoModify", 1);
                key.SetValue("NoRepair", 1);
                key.SetValue("SystemComponent", 0);
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("  ВНИМАНИЕ: не удалось зарегистрировать в системе: " + ex.Message);
        }
    }

    static string GetInstalledVersion()
    {
        try
        {
            using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                String.Format(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{0}", APP_NAME), false))
            {
                if (key != null)
                {
                    var val = key.GetValue("DisplayVersion");
                    if (val != null) return val.ToString();
                    return "";
                }
            }
        }
        catch { }
        return "";
    }

    static void AddToPath(string installDir)
    {
        try
        {
            string currentPath = Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.Machine) ?? "";
            if (!currentPath.Split(';').Any(p => string.Equals(p.Trim(), installDir, StringComparison.OrdinalIgnoreCase)))
            {
                string newPath = currentPath + ";" + installDir;
                Environment.SetEnvironmentVariable("PATH", newPath, EnvironmentVariableTarget.Machine);
            }
        }
        catch { /* Игнорируем ошибки PATH */ }
    }

    // ============================ Удаление ==============================

    static async Task<int> RunUninstall(string exeDir, bool silent, bool skipFcc)
    {
        Console.WriteLine("=== Удаление " + APP_NAME + " ===");
        Console.WriteLine();

        if (!silent)
        {
            Console.WriteLine("Будет удалено:");
            Console.WriteLine("  - Программа: " + INSTALL_DIR);
            Console.WriteLine("  - FCC (Free Claude Code)");
            Console.WriteLine("  - Записи в реестре");
            Console.WriteLine("  - PATH запись");
            Console.WriteLine();
            Console.Write("Продолжить? (y/N): ");
            string ans = Console.ReadLine();
            if (!ans.Equals("y", StringComparison.OrdinalIgnoreCase) &&
                !ans.Equals("yes", StringComparison.OrdinalIgnoreCase) &&
                !ans.Equals("д", StringComparison.OrdinalIgnoreCase) &&
                !ans.Equals("да", StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine("Отменено.");
                return 0;
            }
        }

        try
        {
            // Делегируем удаление в uninstall.exe с пробросом --skip-fcc
            string uninstallExe = Path.Combine(INSTALL_DIR, "uninstall.exe");
            if (!File.Exists(uninstallExe))
            {
                Console.WriteLine("uninstall.exe не найден: " + uninstallExe);
                return 1;
            }

            var args = new List<string> { "-Silent" };
            if (skipFcc) args.Add("--skip-fcc");

            var psi = new ProcessStartInfo
            {
                FileName = uninstallExe,
                Arguments = string.Join(" ", args),
                UseShellExecute = false,
                CreateNoWindow = silent,
                RedirectStandardOutput = !silent,
                RedirectStandardError = !silent,
                Verb = "runas"
            };

            Console.WriteLine("Запуск uninstall.exe" + (skipFcc ? " --skip-fcc" : "") + "...");
            using (var proc = Process.Start(psi))
            {
                if (!silent)
                {
                    string output = await proc.StandardOutput.ReadToEndAsync();
                    string error = await proc.StandardError.ReadToEndAsync();
                    Console.WriteLine(output);
                    if (!string.IsNullOrEmpty(error))
                        Console.Error.WriteLine(error);
                }
                proc.WaitForExit();
                return proc.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("\nОШИБКА ЗАПУСКА УДАЛЕНИЯ: " + ex.Message);
            if (!silent) Pause();
            return 1;
        }
    }

    static async Task UninstallFCC(bool silent)
    {
        // FCC uninstaller обычно находится в ~/.local/bin или где-то в PATH
        // Пробуем найти и запустить uninstall
        string fccUninstall = "fcc-uninstall"; // Или проверяем установку

        // FCC устанавливается через PowerShell скрипт, который не имеет uninstall
        // Поэтому удаляем вручную известные места
        string[] fccPaths = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin", "fcc-server"),
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

        // Также пробуем через uv tool uninstall если установлено так
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
        // Последняя попытка с игнорированием ошибок
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

    // ===================== Download Only ===============================

    static async Task<int> DownloadInstallerOnly(string exeDir)
    {
        Console.WriteLine("Режим скачивания установщика...");
        Console.WriteLine("Эта функция создаёт standalone установщик.");
        Console.WriteLine("Для полноценной работы нужно собрать проект с внедрёнными ресурсами.");

        // Здесь логика создания standalone installer
        // В данном случае просто сообщаем, что нужен build
        return 0;
    }

    // ===================== Вспомогательные ==============================

    static void ExtractUninstaller(string targetDir)
    {
        string target = Path.Combine(targetDir, "uninstall.exe");

        using (var res = Assembly.GetExecutingAssembly()
                            .GetManifestResourceStream("Uninstaller.exe"))
        {
            if (res == null)
                throw new InvalidOperationException(
                    "Встроенный ресурс Uninstaller.exe не найден. Пересоберите install.exe через build.ps1.");

            IOException lastIo = null;
            for (int attempt = 1; attempt <= 5; attempt++)
            {
                try
                {
                    res.Position = 0;
                    using (var fs = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        res.CopyTo(fs);
                    }

                    // 2. copy uninstall.ps1 alongside uninstall.exe (for RunDirectUninstall)
                    string ps1Source = Path.Combine(
                        Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location),
                        "uninstall.ps1");
                    string ps1Target = Path.Combine(targetDir, "uninstall.ps1");
                    if (File.Exists(ps1Source))
                    {
                        try { File.Copy(ps1Source, ps1Target, true); }
                        catch { /* не критично — uninstall.exe работает и без ps1 */ }
                    }

                    return;
                }
                catch (IOException io)
                {
                    lastIo = io;
                    System.Threading.Thread.Sleep(400);
                }
                catch (UnauthorizedAccessException)
                {
                    throw new IOException(
                        "uninstall.exe занят (возможно, запущен). Закройте его и запустите установщик снова.");
                }
            }
            throw lastIo ?? new IOException("Не удалось записать uninstall.exe");
        }
    }

    static void RollbackInstallation()
    {
        try
        {
            if (Directory.Exists(INSTALL_DIR))
                RemoveDirectoryWithRetry(INSTALL_DIR);
            UnregisterUninstaller();
            RemoveFromPath(INSTALL_DIR);
        }
        catch { }
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

    static void Step(string msg) { Console.WriteLine("\n==> " + msg); }
    static void Ok(string msg) { Console.WriteLine("    OK: " + msg); }

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