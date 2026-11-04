using System;
using System.Windows.Forms;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.IO;
using System.Web.Script.Serialization;
using System.Drawing;
using System.Threading;
using System.Linq;

public class TrayConfig {
    public TrayConfig() {
        mode = "beep";
        soundPath = "";
        projectPath = "";
    }
    public string mode { get; set; }
    public string soundPath { get; set; }
    public string projectPath { get; set; }
}

public class TrayLauncher : ApplicationContext {
    private NotifyIcon trayIcon;
    private TrayConfig config;
    private string configPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "claude-auto", "tray_config.json");
    private Process fccProcess = null;
    private Process claudeProcess = null;
    private ToolStripMenuItem showHideLogItem;

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
    }

    private void BuildContextMenu() {
        ContextMenuStrip menu = new ContextMenuStrip();

        // 🚀 Запустить Claude [ИмяПапки] / Выбрать папку
        string startLabel = string.IsNullOrEmpty(config.projectPath)
            ? "🚀 Запустить Claude — Выбрать папку"
            : "🚀 Запустить Claude [" + new DirectoryInfo(config.projectPath).Name + "]";
        ToolStripMenuItem startClaude = new ToolStripMenuItem(startLabel);
        startClaude.Click += StartClaude;
        menu.Items.Add(startClaude);

        // 👁 Скрыть окно Claude
        ToolStripMenuItem hideClaude = new ToolStripMenuItem("👁 Скрыть окно Claude");
        hideClaude.Click += HideClaude;
        menu.Items.Add(hideClaude);

        // 📁 Выбрать папку проекта...
        ToolStripMenuItem selectFolder = new ToolStripMenuItem("📁 Выбрать папку проекта...");
        selectFolder.Click += SelectProjectFolder;
        menu.Items.Add(selectFolder);

        menu.Items.Add(new ToolStripSeparator());

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
        ToolStripMenuItem soundMenu = new ToolStripMenuItem("⚙️ Настройки звука");

        ToolStripMenuItem beepItem = new ToolStripMenuItem("🔔 Встроенный писк");
        beepItem.Click += (s, e) => { config.mode = "beep"; config.soundPath = ""; SaveConfig(); UpdateSoundMenuChecks(soundMenu); };
        soundMenu.DropDownItems.Add(beepItem);

        ToolStripMenuItem customItem = new ToolStripMenuItem("🎵 Выбрать свой звук...");
        customItem.Click += SelectCustomSound;
        soundMenu.DropDownItems.Add(customItem);

        ToolStripMenuItem noneItem = new ToolStripMenuItem("🔇 Без звука");
        noneItem.Click += (s, e) => { config.mode = "none"; SaveConfig(); UpdateSoundMenuChecks(soundMenu); };
        soundMenu.DropDownItems.Add(noneItem);

        menu.Items.Add(soundMenu);

        menu.Items.Add(new ToolStripSeparator());

        // ❌ Выход
        ToolStripMenuItem exit = new ToolStripMenuItem("❌ Выход");
        exit.Click += ExitApp;
        menu.Items.Add(exit);

        trayIcon.ContextMenuStrip = menu;
        UpdateSoundMenuChecks(soundMenu);
    }

    private void UpdateSoundMenuChecks(ToolStripMenuItem soundMenu) {
        foreach (ToolStripItem item in soundMenu.DropDownItems) {
            ToolStripMenuItem mi = item as ToolStripMenuItem;
            if (mi != null) {
                if (mi.Text.Contains("Встроенный") && config.mode == "beep") mi.Checked = true;
                else if (mi.Text.Contains("свой звук") && config.mode == "custom") mi.Checked = true;
                else if (mi.Text.Contains("Без звука") && config.mode == "none") mi.Checked = true;
                else mi.Checked = false;
            }
        }
    }

    private void StartFccServer() {
        try {
            ProcessStartInfo psi = new ProcessStartInfo("fcc-server") {
                UseShellExecute = false,
                CreateNoWindow = false,
                WindowStyle = ProcessWindowStyle.Normal
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

    private void StartClaude(object sender, EventArgs e) {
        if (string.IsNullOrEmpty(config.projectPath)) {
            SelectProjectFolder(sender, e);
            return;
        }
        LaunchClaude();
    }

    private void SelectProjectFolder(object sender, EventArgs e) {
        using (FolderBrowserDialog fbd = new FolderBrowserDialog()) {
            fbd.Description = "Выберите папку проекта для claude-auto";
            fbd.ShowNewFolderButton = true;
            if (fbd.ShowDialog() == DialogResult.OK) {
                config.projectPath = fbd.SelectedPath;
                SaveConfig();
                // Update the start menu item text
                if (trayIcon.ContextMenuStrip != null && trayIcon.ContextMenuStrip.Items.Count > 0) {
                    var startItem = trayIcon.ContextMenuStrip.Items[0] as ToolStripMenuItem;
                    if (startItem != null) {
                        startItem.Text = "🚀 Запустить Claude [" + new DirectoryInfo(config.projectPath).Name + "]";
                    }
                }
                LaunchClaude();
            }
        }
    }

    private void LaunchClaude() {
        try {
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", "/k claude-auto") {
                UseShellExecute = true,
                WorkingDirectory = config.projectPath
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
                UpdateSoundMenuChecks(trayIcon.ContextMenuStrip.Items.OfType<ToolStripMenuItem>().FirstOrDefault(m => m.Text.Contains("Настройки звука")));
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

    private void LoadConfig() {
        try {
            if (File.Exists(configPath)) {
                string json = File.ReadAllText(configPath);
                config = new JavaScriptSerializer().Deserialize<TrayConfig>(json);
                // Ensure projectPath exists for older configs
                if (config.projectPath == null) config.projectPath = "";
                if (config.soundPath == null) config.soundPath = "";
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