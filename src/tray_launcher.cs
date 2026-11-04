using System;
using System.Windows.Forms;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.IO;
using System.Runtime.Serialization.Json;
using System.Runtime.Serialization;
using System.Drawing;
using System.Threading;
using System.Linq;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Globalization;
using System.Text;

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

// Localization helper - C# 5 compatible
public static class Loc {
    private static readonly bool IsRu = CultureInfo.CurrentCulture.TwoLetterISOLanguageName == "ru";

    public class StringPair {
        public string Ru;
        public string En;
        public StringPair(string ru, string en) { Ru = ru; En = en; }
    }

    private static readonly Dictionary<string, StringPair> Strings = new Dictionary<string, StringPair>();

    static Loc() {
        // Menu items
        Strings["menu_start_claude"] = new StringPair("🚀 Запустить Claude", "🚀 Start Claude");
        Strings["menu_select_folder"] = new StringPair("📁 Выбрать новую папку...", "📁 Select new folder...");
        Strings["menu_hide_claude"] = new StringPair("👁 Скрыть окно Claude", "👁 Hide Claude window");
        Strings["menu_open_fcc"] = new StringPair("🌐 Открыть панель FCC", "🌐 Open FCC panel");
        Strings["menu_show_log"] = new StringPair("📜 Показать лог FCC", "📜 Show FCC log");
        Strings["menu_hide_log"] = new StringPair("📜 Скрыть лог FCC", "📜 Hide FCC log");
        Strings["menu_sound_settings"] = new StringPair("⚙️ Настройки звука", "⚙️ Sound settings");
        Strings["menu_sound_beep"] = new StringPair("🔔 Писк", "🔔 Beep");
        Strings["menu_sound_custom"] = new StringPair("🎵 Свой звук...", "🎵 Custom sound...");
        Strings["menu_sound_none"] = new StringPair("🔇 Без звука", "🔇 No sound");
        Strings["menu_exit"] = new StringPair("❌ Выход", "❌ Exit");
        Strings["menu_no_paths"] = new StringPair("(путей нет — выберите папку)", "(no paths — select folder)");
        Strings["menu_project_paths"] = new StringPair("📁 Пути к проектам", "📁 Project paths");
        Strings["menu_add_new"] = new StringPair("➕ Выбрать новую папку", "➕ Select new folder");

        // Dialogs
        Strings["welcome_title"] = new StringPair("claude-auto", "claude-auto");
        Strings["welcome_msg"] = new StringPair("Добро пожаловать! Управление программой находится в трее (возле часов).\nТам же настройки звука и выбор папок.", "Welcome! Controls are in the System Tray (near the clock).\nSound settings and folder selection are also there.");
        Strings["settings_title"] = new StringPair("Настройка", "Settings");
        Strings["settings_msg"] = new StringPair("Хотите настроить модели в панели FCC?", "Configure models in FCC panel?");
        Strings["error_title"] = new StringPair("Ошибка", "Error");
        Strings["error_launch"] = new StringPair("Ошибка запуска: ", "Launch error: ");
        Strings["info_title"] = new StringPair("Информация", "Information");
        Strings["info_fcc_not_running"] = new StringPair("Процесс fcc-server не запущен", "fcc-server process is not running");
        Strings["folder_select_title"] = new StringPair("Выберите папку проекта для claude-auto", "Select project folder for claude-auto");
        Strings["folder_select_first_title"] = new StringPair("Выберите папку проекта для claude-auto (первый запуск)", "Select project folder for claude-auto (first launch)");

        // Tray tooltip
        Strings["tray_text"] = new StringPair("claude-auto 2.1.0", "claude-auto 2.1.0");

        // Console form
        Strings["console_title"] = new StringPair("Claude Auto — Консоль", "Claude Auto — Console");
        Strings["console_done_marker"] = new StringPair("✻ (Churned|Baked|Sautéed) for .* done", "✻ (Churned|Baked|Sautéed) for .* done");
    }

    public static string T(string key) {
        StringPair pair;
        if (Strings.TryGetValue(key, out pair)) {
            return IsRu ? pair.Ru : pair.En;
        }
        return key;
    }
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
    private SynchronizationContext uiContext;

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

    // Regex to detect completion markers in Claude output
    private static readonly Regex DoneRegex = new Regex(@"✻\s+(Churned|Baked|Sautéed)\s+for\s+.*\s+done", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    public TrayLauncher() {
        uiContext = SynchronizationContext.Current;
        LoadConfig();

        trayIcon = new NotifyIcon() {
            Icon = SystemIcons.Application,
            Visible = true,
            Text = Loc.T("tray_text")
        };

        BuildContextMenu();

        trayIcon.DoubleClick += (s, e) => { if (fccProcess != null && !fccProcess.HasExited) ToggleFccLog(s, e); };

        AddToStartup();
        StartFccServer();
        StartClaudeProcedure();
    }

    private void BuildContextMenu() {
        ContextMenuStrip menu = new ContextMenuStrip();

        startClaudeMenuItem = new ToolStripMenuItem(Loc.T("menu_start_claude"));
        startClaudeMenuItem.Click += StartClaudeMain;
        UpdateStartClaudeMenuItem();
        menu.Items.Add(startClaudeMenuItem);

        ToolStripMenuItem selectFolder = new ToolStripMenuItem(Loc.T("menu_select_folder"));
        selectFolder.Click += SelectProjectFolder;
        menu.Items.Add(selectFolder);

        menu.Items.Add(new ToolStripSeparator());

        ToolStripMenuItem hideClaude = new ToolStripMenuItem(Loc.T("menu_hide_claude"));
        hideClaude.Click += HideClaude;
        menu.Items.Add(hideClaude);

        ToolStripMenuItem openFcc = new ToolStripMenuItem(Loc.T("menu_open_fcc"));
        openFcc.Click += OpenFcc;
        menu.Items.Add(openFcc);

        showHideLogItem = new ToolStripMenuItem(Loc.T("menu_show_log"));
        showHideLogItem.Click += ToggleFccLog;
        menu.Items.Add(showHideLogItem);

        menu.Items.Add(new ToolStripSeparator());

        soundMenu = new ToolStripMenuItem(Loc.T("menu_sound_settings"));

        ToolStripMenuItem beepItem = new ToolStripMenuItem(Loc.T("menu_sound_beep"));
        beepItem.Click += delegate(object s, EventArgs e) { config.mode = "beep"; config.soundPath = ""; SaveConfig(); UpdateSoundMenuChecks(); };
        soundMenu.DropDownItems.Add(beepItem);

        ToolStripMenuItem customItem = new ToolStripMenuItem(Loc.T("menu_sound_custom"));
        customItem.Click += SelectCustomSound;
        soundMenu.DropDownItems.Add(customItem);

        ToolStripMenuItem noneItem = new ToolStripMenuItem(Loc.T("menu_sound_none"));
        noneItem.Click += delegate(object s, EventArgs e) { config.mode = "none"; SaveConfig(); UpdateSoundMenuChecks(); };
        soundMenu.DropDownItems.Add(noneItem);

        menu.Items.Add(soundMenu);

        menu.Items.Add(new ToolStripSeparator());

        ToolStripMenuItem exit = new ToolStripMenuItem(Loc.T("menu_exit"));
        exit.Click += ExitApp;
        menu.Items.Add(exit);

        trayIcon.ContextMenuStrip = menu;
        UpdateSoundMenuChecks();
    }

    private void UpdateStartClaudeMenuItem() {
        startClaudeMenuItem.DropDownItems.Clear();

        if (config.projectPaths.Count == 0) {
            ToolStripMenuItem noPaths = new ToolStripMenuItem(Loc.T("menu_no_paths"));
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
            ToolStripMenuItem pathsSubmenu = new ToolStripMenuItem(Loc.T("menu_project_paths"));
            foreach (string path in config.projectPaths) {
                string name = new DirectoryInfo(path).Name;
                ToolStripMenuItem pathItem = new ToolStripMenuItem("📁 " + name);
                pathItem.Tag = path;
                pathItem.Click += StartClaudeFromPath;
                pathsSubmenu.DropDownItems.Add(pathItem);
            }
            ToolStripMenuItem addNew = new ToolStripMenuItem(Loc.T("menu_add_new"));
            addNew.Click += SelectProjectFolder;
            pathsSubmenu.DropDownItems.Add(new ToolStripSeparator());
            pathsSubmenu.DropDownItems.Add(addNew);
            startClaudeMenuItem.DropDownItems.Add(pathsSubmenu);
        }
    }

    private void StartClaudeMain(object sender, EventArgs e) {
        if (config.projectPaths.Count == 0) {
            SelectProjectFolder(sender, e);
        }
        else if (config.projectPaths.Count == 1) {
            LaunchClaude(config.projectPaths[0]);
        }
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
            string descKey = (config.launchCount == 0) ? "folder_select_first_title" : "folder_select_title";
            fbd.Description = Loc.T(descKey);
            fbd.ShowNewFolderButton = true;
            if (fbd.ShowDialog() == DialogResult.OK) {
                string selectedPath = fbd.SelectedPath;
                if (!config.projectPaths.Contains(selectedPath)) {
                    config.projectPaths.Add(selectedPath);
                    SaveConfig();
                }
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
            var consoleForm = new ConsoleForm(workingDir, OnClaudeOutputLine, OnClaudeProcessExited);
            consoleForm.Show();
        } catch (Exception ex) {
            MessageBox.Show(Loc.T("error_launch") + ex.Message, Loc.T("error_title"), MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void OnClaudeOutputLine(string line) {
        if (DoneRegex.IsMatch(line)) {
            PostToUI(delegate { PlayNotification(); });
        }
    }

    private void OnClaudeProcessExited() {
        claudeProcess = null;
    }

    private void StartClaudeProcedure() {
        config.launchCount++;
        SaveConfig();

        if (config.projectPaths.Count == 0) {
            using (FolderBrowserDialog fbd = new FolderBrowserDialog()) {
                fbd.Description = Loc.T("folder_select_first_title");
                fbd.ShowNewFolderButton = true;
                if (fbd.ShowDialog() == DialogResult.OK) {
                    config.projectPaths.Add(fbd.SelectedPath);
                    SaveConfig();
                    UpdateStartClaudeMenuItem();
                    LaunchClaude(fbd.SelectedPath);
                }
            }
        }
        else {
            LaunchClaude(config.projectPaths[0]);
        }

        if (config.launchCount == 1) {
            try { Process.Start("http://127.0.0.1:8082/admin"); } catch { }
            MessageBox.Show(
                Loc.T("welcome_msg"),
                Loc.T("welcome_title"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Information
            );
        }
        else if (config.launchCount == 2) {
            DialogResult res = MessageBox.Show(
                Loc.T("settings_msg"),
                Loc.T("settings_title"),
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question
            );
            if (res == DialogResult.Yes) {
                try { Process.Start("http://127.0.0.1:8082/admin"); } catch { }
            }
        }
    }

    private void HideClaude(object sender, EventArgs e) {
    }

    private void OpenFcc(object sender, EventArgs e) {
        try { Process.Start("http://127.0.0.1:8082/admin"); } catch { }
    }

    private void ToggleFccLog(object sender, EventArgs e) {
        if (fccProcess == null || fccProcess.HasExited) {
            MessageBox.Show(Loc.T("info_fcc_not_running"), Loc.T("info_title"), MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        IntPtr hWnd = fccProcess.MainWindowHandle;
        if (hWnd == IntPtr.Zero) return;

        RECT rect;
        GetWindowRect(hWnd, out rect);
        bool isVisible = (rect.Right - rect.Left > 0) && (rect.Bottom - rect.Top > 0);

        if (isVisible) {
            ShowWindow(hWnd, SW_HIDE);
            showHideLogItem.Text = Loc.T("menu_show_log");
        } else {
            ShowWindow(hWnd, SW_RESTORE);
            SetForegroundWindow(hWnd);
            showHideLogItem.Text = Loc.T("menu_hide_log");
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
                string beepText = Loc.T("menu_sound_beep").Replace("🔔 ", "");
                string customText = Loc.T("menu_sound_custom").Replace("🎵 ", "");
                string noneText = Loc.T("menu_sound_none").Replace("🔇 ", "");
                if (mi.Text.Contains(beepText) && config.mode == "beep") mi.Checked = true;
                else if (mi.Text.Contains(customText) && config.mode == "custom") mi.Checked = true;
                else if (mi.Text.Contains(noneText) && config.mode == "none") mi.Checked = true;
                else mi.Checked = false;
            }
        }
    }

    private void PlayNotification() {
        if (config.mode == "none") return;

        if (config.mode == "beep") {
            new Thread(new ThreadStart(delegate {
                try {
                    Console.Beep(3830, 150);
                    Thread.Sleep(100);
                    Console.Beep(1783, 150);
                } catch { System.Media.SystemSounds.Exclamation.Play(); }
            })).Start();
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
        }
    }

    private void LoadConfig() {
        try {
            if (File.Exists(configPath)) {
                string json = File.ReadAllText(configPath);
                config = JsonDeserialize(json);
                if (config.projectPaths == null) config.projectPaths = new List<string>();
                if (config.soundPath == null) config.soundPath = "";
                if (config.mode == null) config.mode = "beep";
            } else { config = new TrayConfig(); }
        } catch { config = new TrayConfig(); }
    }

    private void SaveConfig() {
        try {
            Directory.CreateDirectory(Path.GetDirectoryName(configPath));
            string json = JsonSerialize(config);
            File.WriteAllText(configPath, json);
        } catch { }
    }

    private string JsonSerialize(TrayConfig obj) {
        using (MemoryStream ms = new MemoryStream()) {
            DataContractJsonSerializer ser = new DataContractJsonSerializer(typeof(TrayConfig));
            ser.WriteObject(ms, obj);
            return Encoding.UTF8.GetString(ms.ToArray());
        }
    }

    private TrayConfig JsonDeserialize(string json) {
        using (MemoryStream ms = new MemoryStream(Encoding.UTF8.GetBytes(json))) {
            DataContractJsonSerializer ser = new DataContractJsonSerializer(typeof(TrayConfig));
            return (TrayConfig)ser.ReadObject(ms);
        }
    }

    private void AddToStartup() {
        try {
            Microsoft.Win32.RegistryKey key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", true);
            key.SetValue("claude-auto-tray", Application.ExecutablePath);
        } catch { }
    }

    private void ExitApp(object sender, EventArgs e) {
        if (fccProcess != null && !fccProcess.HasExited) {
            try { fccProcess.Kill(); } catch { }
        }
        if (claudeProcess != null && !claudeProcess.HasExited) {
            try { claudeProcess.Kill(); } catch { }
        }
        trayIcon.Visible = false;
        Application.Exit();
    }

    private void PostToUI(Action action) {
        if (uiContext != null) {
            uiContext.Post(delegate { action(); }, null);
        } else {
            action();
        }
    }
}

public class ConsoleForm : Form {
    private RichTextBox outputBox;
    private Process process;
    private Action<string> onOutputLine;
    private Action onExited;
    private string workingDir;

    public ConsoleForm(string workingDir, Action<string> onOutputLine, Action onExited) {
        this.workingDir = workingDir;
        this.onOutputLine = onOutputLine;
        this.onExited = onExited;

        this.Text = Loc.T("console_title");
        this.Size = new Size(900, 600);
        this.StartPosition = FormStartPosition.CenterScreen;
        this.FormBorderStyle = FormBorderStyle.Sizable;
        this.ShowInTaskbar = true;

        outputBox = new RichTextBox {
            Dock = DockStyle.Fill,
            ReadOnly = true,
            BackColor = Color.Black,
            ForeColor = Color.LimeGreen,
            Font = new Font("Consolas", 10),
            WordWrap = true,
            ScrollBars = RichTextBoxScrollBars.Vertical,
            HideSelection = false
        };
        this.Controls.Add(outputBox);

        this.FormClosing += delegate(object s, FormClosingEventArgs e) {
            if (process != null && !process.HasExited) {
                try { process.Kill(); } catch { }
            }
        };

        StartProcess();
    }

    private void StartProcess() {
        ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", "/k claude-auto") {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = workingDir,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) {
            if (e.Data != null) {
                AppendOutput(e.Data);
                if (onOutputLine != null) onOutputLine(e.Data);
            }
        };
        process.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) {
            if (e.Data != null) {
                AppendOutput("[ERR] " + e.Data);
            }
        };
        process.Exited += delegate(object s, EventArgs e) {
            InvokeIfRequired(delegate {
                AppendOutput("\n[Process exited with code: " + process.ExitCode + "]");
                if (onExited != null) onExited();
            });
        };

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }

    private void AppendOutput(string text) {
        if (this.InvokeRequired) {
            this.BeginInvoke(new Action<string>(AppendOutput), text);
            return;
        }
        outputBox.AppendText(text + "\n");
        outputBox.ScrollToCaret();
    }

    private void InvokeIfRequired(Action action) {
        if (this.InvokeRequired) {
            this.BeginInvoke(action);
        } else {
            action();
        }
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