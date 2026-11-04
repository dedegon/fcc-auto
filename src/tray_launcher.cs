using System;
using System.Windows.Forms;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.IO;
using System.Web.Script.Serialization;
using System.Drawing;
using System.Threading;
using System.Linq;
using System.Collections.Generic;

public class TrayConfig {
    public TrayConfig() {
        mode = "beep";
        soundPath = "";
        projectPaths = new List<string>();
        launchCount = 0;
    }
    public string mode { get; set; }
    public string soundPath { get; set; }
    public List<string> projectPaths { get; set; }
    public int launchCount { get; set; }
}

public class TrayLauncher : ApplicationContext {
    private NotifyIcon trayIcon;
    private TrayConfig config;
    private string configPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "claude-auto", "tray_config.json");
    private Process fccProcess = null;
    private Process claudeProcess = null;
    private ToolStripMenuItem showHideLogItem;
    private ToolStripMenuItem startClaudeMenuItem;
    private ToolStripMenuItem soundMenu;

    [DllImport("winmm.dll")]
    private static extern long mciSendString(string strCommand, System.Text.StringBuilder strReturn, int iReturnLength, IntPtr hwndCallback);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    private const int SW_HIDE = 0;
    private const int SW_RESTORE = 9;
    private const int SW_SHOW = 5;

    public TrayLauncher() {
        LoadConfig();

        trayIcon = new NotifyIcon() {
            Icon = SystemIcons.Application,
            Visible = true,
            Text = "claude-auto 2.1.0"
        };

        BuildContextMenu();

        trayIcon.DoubleClick += (s, e) => { if (fccProcess != null && !fccProcess.HasExited) ToggleFccLog(s, e); };

        AddToStartup();
        StartFccServer();
        StartClaudeProcedure();
    }

    private void BuildContextMenu() {
        ContextMenuStrip menu = new ContextMenuStrip();

        // 🚀 Запустить Claude (creates submenu if multiple paths)
        startClaudeMenuItem = new ToolStripMenuItem("🚀 Запустить Claude");
        startClaudeMenuItem.Click += StartClaudeMain;
        UpdateStartClaudeMenuItem();
        menu.Items.Add(startClaudeMenuItem);

        // 📁 Выбрать новую папку...
        ToolStripMenuItem selectFolder = new ToolStripMenuItem("📁 Выбрать новую папку...");
        selectFolder.Click += SelectProjectFolder;
        menu.Items.Add(selectFolder);

        menu.Items.Add(new ToolStripSeparator());

        // 👁 Скрыть окно Claude
        ToolStripMenuItem hideClaude = new ToolStripMenuItem("👁 Скрыть окно Claude");
        hideClaude.Click += HideClaude;
        menu.Items.Add(hideClaude);

        // 🌐 Открыть панель FCC
        ToolStripMenuItem openFcc = new ToolStripMenuItem("🌐 Открыть панель FCC");
        openFcc.Click += OpenFcc;
        menu.Items.Add(openFcc);

        // 📜 Показать/Скрыть лог FCC
        showHideLogItem = new ToolStripMenuItem("📜 Показать лог FCC");
        showHideLogItem.Click += ToggleFccLog;
        menu.Items.Add(showHideLogItem);

        menu.Items.Add(new ToolStripSeparator());

        // ⚙️ Настройки звука >
        soundMenu = new ToolStripMenuItem("⚙️ Настройки звука");

        ToolStripMenuItem beepItem = new ToolStripMenuItem("🔔 Писк");
        beepItem.Click += (s, e) => { config.mode = "beep"; config.soundPath = ""; SaveConfig(); UpdateSoundMenuChecks(); };
        soundMenu.DropDownItems.Add(beepItem);

        ToolStripMenuItem customItem = new ToolStripMenuItem("🎵 Свой звук...");
        customItem.Click += SelectCustomSound;
        soundMenu.DropDownItems.Add(customItem);

        ToolStripMenuItem noneItem = new ToolStripMenuItem("🔇 Без звука");
        noneItem.Click += (s, e) => { config.mode = "none"; SaveConfig(); UpdateSoundMenuChecks(); };
        soundMenu.DropDownItems.Add(noneItem);

        menu.Items.Add(soundMenu);

        menu.Items.Add(new ToolStripSeparator());

        // ❌ Выход
        ToolStripMenuItem exit = new ToolStripMenuItem("❌ Выход");
        exit.Click += ExitApp;
        menu.Items.Add(exit);

        trayIcon.ContextMenuStrip = menu;
        UpdateSoundMenuChecks();
    }

    private void UpdateStartClaudeMenuItem() {
        startClaudeMenuItem.DropDownItems.Clear();

        if (config.projectPaths.Count == 0) {
            ToolStripMenuItem noPaths = new ToolStripMenuItem("(путей нет — выберите папку)");
            noPaths.Enabled = false;
            startClaudeMenuItem.DropDownItems.Add(noPaths);
        }
        else if (config.projectPaths.Count == 1) {
            string path = config.projectPaths[0];
            string name = new DirectoryInfo(path).Name;
            ToolStripMenuItem singleItem = new ToolStripMenuItem("📁 " + name);
            singleItem.Tag = path;
            singleItem.Click += StartClaudeFromPath;
            startClaudeMenuItem.DropDownItems.Add(singleItem);
        }
        else {
            // Multiple paths - create submenu "📁 Пути к проектам >"
            ToolStripMenuItem pathsSubmenu = new ToolStripMenuItem("📁 Пути к проектам");
            foreach (string path in config.projectPaths) {
                string name = new DirectoryInfo(path).Name;
                ToolStripMenuItem pathItem = new ToolStripMenuItem("📁 " + name);
                pathItem.Tag = path;
                pathItem.Click += StartClaudeFromPath;
                pathsSubmenu.DropDownItems.Add(pathItem);
            }
            // Add "➕ Выбрать новую папку" at the bottom
            ToolStripMenuItem addNew = new ToolStripMenuItem("➕ Выбрать новую папку");
            addNew.Click += SelectProjectFolder;
            pathsSubmenu.DropDownItems.Add(new ToolStripSeparator());
            pathsSubmenu.DropDownItems.Add(addNew);
            startClaudeMenuItem.DropDownItems.Add(pathsSubmenu);
        }
    }

    private void StartClaudeMain(object sender, EventArgs e) {
        // If no paths, trigger folder selection
        if (config.projectPaths.Count == 0) {
            SelectProjectFolder(sender, e);
        }
        else if (config.projectPaths.Count == 1) {
            // Direct launch with the single path
            LaunchClaude(config.projectPaths[0]);
        }
        // If multiple paths, the submenu handles it - this click just opens the dropdown
    }

    private void StartClaudeFromPath(object sender, EventArgs e) {
        ToolStripMenuItem item = sender as ToolStripMenuItem;
        if (item != null && item.Tag != null && item.Tag is string) {
            string path = item.Tag as string;
            LaunchClaude(path);
        }
    }

    private void SelectProjectFolder(object sender, EventArgs e) {
        using (FolderBrowserDialog fbd = new FolderBrowserDialog()) {
            fbd.Description = "Выберите папку проекта для claude-auto";
            fbd.ShowNewFolderButton = true;
            if (fbd.ShowDialog() == DialogResult.OK) {
                string selectedPath = fbd.SelectedPath;
                // Add to list if not already present
                if (!config.projectPaths.Contains(selectedPath)) {
                    config.projectPaths.Add(selectedPath);
                    SaveConfig();
                }
                // Move to front (most recently used)
                config.projectPaths.Remove(selectedPath);
                config.projectPaths.Insert(0, selectedPath);
                SaveConfig();
                UpdateStartClaudeMenuItem();
                LaunchClaude(selectedPath);
            }
        }
    }

    private void LaunchClaude(string workingDir) {
        try {
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", "/k claude-auto") {
                UseShellExecute = true,
                WorkingDirectory = workingDir
            };
            claudeProcess = Process.Start(psi);
            if (claudeProcess != null) {
                claudeProcess.EnableRaisingEvents = true;
                claudeProcess.Exited += (s, ev) => {
                    claudeProcess = null;
                    PlayNotification();
                };
            }
        } catch (Exception ex) {
            MessageBox.Show("Ошибка запуска: " + ex.Message, "Ошибка", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void StartClaudeProcedure() {
        config.launchCount++;
        SaveConfig();

        // If no project paths, show folder browser
        if (config.projectPaths.Count == 0) {
            using (FolderBrowserDialog fbd = new FolderBrowserDialog()) {
                fbd.Description = "Выберите папку проекта для claude-auto (первый запуск)";
                fbd.ShowNewFolderButton = true;
                if (fbd.ShowDialog() == DialogResult.OK) {
                    config.projectPaths.Add(fbd.SelectedPath);
                    SaveConfig();
                    UpdateStartClaudeMenuItem();
                    LaunchClaude(fbd.SelectedPath);
                }
                else {
                    // User cancelled - still continue, they can select later from menu
                }
            }
        }
        else {
            // Launch with the most recent path
            LaunchClaude(config.projectPaths[0]);
        }

        // First launch welcome
        if (config.launchCount == 1) {
            try { Process.Start("http://127.0.0.1:8082/admin"); } catch { }
            MessageBox.Show(
                "Добро пожаловать! Управление программой находится в трее (возле часов).\nТам же настройки звука и выбор папок.",
                "claude-auto",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information
            );
        }
        // Second launch - ask about FCC models
        else if (config.launchCount == 2) {
            DialogResult res = MessageBox.Show(
                "Хотите настроить модели в панели FCC?",
                "Настройка",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question
            );
            if (res == DialogResult.Yes) {
                try { Process.Start("http://127.0.0.1:8082/admin"); } catch { }
            }
        }
    }

    private void HideClaude(object sender, EventArgs e) {
        if (claudeProcess != null && !claudeProcess.HasExited) {
            IntPtr hWnd = claudeProcess.MainWindowHandle;
            if (hWnd != IntPtr.Zero) {
                ShowWindow(hWnd, SW_HIDE);
            }
        }
    }

    private void OpenFcc(object sender, EventArgs e) {
        try { Process.Start("http://127.0.0.1:8082/admin"); } catch { }
    }

    private void ToggleFccLog(object sender, EventArgs e) {
        if (fccProcess == null || fccProcess.HasExited) {
            MessageBox.Show("Процесс fcc-server не запущен", "Информация", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        IntPtr hWnd = fccProcess.MainWindowHandle;
        if (hWnd == IntPtr.Zero) return;

        RECT rect;
        GetWindowRect(hWnd, out rect);
        bool isVisible = (rect.Right - rect.Left > 0) && (rect.Bottom - rect.Top > 0);

        if (isVisible) {
            ShowWindow(hWnd, SW_HIDE);
            showHideLogItem.Text = "📜 Показать лог FCC";
        } else {
            ShowWindow(hWnd, SW_RESTORE);
            SetForegroundWindow(hWnd);
            showHideLogItem.Text = "📜 Скрыть лог FCC";
        }
    }

    private void SelectCustomSound(object sender, EventArgs e) {
        using (OpenFileDialog ofd = new OpenFileDialog()) {
            ofd.Filter = "Audio files|*.mp3;*.wav|All files|*.*";
            if (ofd.ShowDialog() == DialogResult.OK) {
                config.mode = "custom";
                config.soundPath = ofd.FileName;
                SaveConfig();
                UpdateSoundMenuChecks();
            }
        }
    }

    private void UpdateSoundMenuChecks() {
        if (soundMenu == null) return;
        foreach (ToolStripItem item in soundMenu.DropDownItems) {
            ToolStripMenuItem mi = item as ToolStripMenuItem;
            if (mi != null) {
                if (mi.Text.Contains("Писк") && config.mode == "beep") mi.Checked = true;
                else if (mi.Text.Contains("Свой звук") && config.mode == "custom") mi.Checked = true;
                else if (mi.Text.Contains("Без звука") && config.mode == "none") mi.Checked = true;
                else mi.Checked = false;
            }
        }
    }

    private void PlayNotification() {
        if (config.mode == "none") return;

        if (config.mode == "beep") {
            new Thread(() => {
                try {
                    Console.Beep(3830, 150);
                    Thread.Sleep(100);
                    Console.Beep(1783, 150);
                } catch { System.Media.SystemSounds.Exclamation.Play(); }
            }).Start();
        } else if (config.mode == "custom" && File.Exists(config.soundPath)) {
            mciSendString("close myaudio", null, 0, IntPtr.Zero);
            mciSendString("open \"" + config.soundPath + "\" type mpegvideo alias myaudio", null, 0, IntPtr.Zero);
            mciSendString("play myaudio", null, 0, IntPtr.Zero);
        }
    }

    private void StartFccServer() {
        try {
            ProcessStartInfo psi = new ProcessStartInfo("fcc-server") {
                UseShellExecute = true,
                CreateNoWindow = false,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            fccProcess = Process.Start(psi);
            if (fccProcess != null) {
                Thread.Sleep(1000);
                if (fccProcess.MainWindowHandle != IntPtr.Zero) {
                    ShowWindow(fccProcess.MainWindowHandle, SW_HIDE);
                }
            }
        } catch {
            // fcc-server might not be in PATH, ignore silently
        }
    }

    private void LoadConfig() {
        try {
            if (File.Exists(configPath)) {
                string json = File.ReadAllText(configPath);
                config = new JavaScriptSerializer().Deserialize<TrayConfig>(json);
                // Ensure fields exist for older configs
                if (config.projectPaths == null) config.projectPaths = new List<string>();
                if (config.soundPath == null) config.soundPath = "";
                if (config.mode == null) config.mode = "beep";
            } else { config = new TrayConfig(); }
        } catch { config = new TrayConfig(); }
    }

    private void SaveConfig() {
        try {
            Directory.CreateDirectory(Path.GetDirectoryName(configPath));
            string json = new JavaScriptSerializer().Serialize(config);
            File.WriteAllText(configPath, json);
        } catch { }
    }

    private void AddToStartup() {
        try {
            Microsoft.Win32.RegistryKey key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", true);
            key.SetValue("claude-auto-tray", Application.ExecutablePath);
        } catch { }
    }

    private void ExitApp(object sender, EventArgs e) {
        // Kill fcc-server process
        if (fccProcess != null && !fccProcess.HasExited) {
            try { fccProcess.Kill(); } catch { }
        }
        // Kill claude-auto process
        if (claudeProcess != null && !claudeProcess.HasExited) {
            try { claudeProcess.Kill(); } catch { }
        }
        trayIcon.Visible = false;
        Application.Exit();
    }
}

static class Program {
    [STAThread]
    static void Main() {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new TrayLauncher());
    }
}