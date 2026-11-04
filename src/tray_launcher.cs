using System;
using System.Windows.Forms;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.IO;
using System.Web.Script.Serialization;
using System.Drawing;
using System.Threading;

public class TrayConfig {
    public TrayConfig() {
        mode = "beep";
        path = "";
    }
    public string mode { get; set; }
    public string path { get; set; }
}

public class TrayLauncher : ApplicationContext {
    private NotifyIcon trayIcon;
    private TrayConfig config;
    private string configPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "claude-auto", "tray_config.json");
    private Process fccServerProcess = null;
    private Process claudeProcess = null;

    [DllImport("winmm.dll")]
    private static extern long mciSendString(string strCommand, System.Text.StringBuilder strReturn, int iReturnLength, IntPtr hwndCallback);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);

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

        ContextMenuStrip menu = new ContextMenuStrip();

        ToolStripMenuItem startShowClaude = new ToolStripMenuItem("🚀 Запустить/Показать Claude");
        startShowClaude.Click += StartOrShowClaude;
        menu.Items.Add(startShowClaude);

        ToolStripMenuItem hideClaude = new ToolStripMenuItem("🙈 Скрыть окно Claude");
        hideClaude.Click += HideClaude;
        menu.Items.Add(hideClaude);

        ToolStripMenuItem openFcc = new ToolStripMenuItem("🌐 Открыть панель FCC");
        openFcc.Click += OpenFcc;
        menu.Items.Add(openFcc);

        ToolStripMenuItem settings = new ToolStripMenuItem("⚙️ Настройки оповещений");
        settings.Click += ShowSettings;
        menu.Items.Add(settings);

        menu.Items.Add(new ToolStripSeparator());

        ToolStripMenuItem exit = new ToolStripMenuItem("❌ Выход");
        exit.Click += ExitApp;
        menu.Items.Add(exit);

        trayIcon.ContextMenuStrip = menu;
        trayIcon.DoubleClick += OpenFcc;

        AddToStartup();
        StartFccServer();
        StartClaudeConsole();
    }

    private void StartFccServer() {
        try {
            ProcessStartInfo psi = new ProcessStartInfo("fcc-server") {
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            fccServerProcess = Process.Start(psi);
        } catch {
            // fcc-server might not be in PATH, ignore silently
        }
    }

    private void StartClaudeConsole() {
        try {
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", "/k claude-auto") {
                UseShellExecute = true
            };
            claudeProcess = Process.Start(psi);
            if (claudeProcess != null) {
                claudeProcess.EnableRaisingEvents = true;
                claudeProcess.Exited += (s, ev) => {
                    claudeProcess = null;
                    PlayNotification();
                };
            }
        } catch {
            // Ignore startup errors
        }
    }

    private void StartOrShowClaude(object sender, EventArgs e) {
        if (claudeProcess != null && !claudeProcess.HasExited) {
            // Process exists, try to restore its window
            IntPtr hWnd = claudeProcess.MainWindowHandle;
            if (hWnd != IntPtr.Zero) {
                if (IsIconic(hWnd)) {
                    ShowWindow(hWnd, SW_RESTORE);
                } else {
                    ShowWindow(hWnd, SW_RESTORE);
                }
                SetForegroundWindow(hWnd);
            }
            return;
        }

        // Process not running, start new one
        try {
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", "/k claude-auto") {
                UseShellExecute = true
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
        } else if (config.mode == "custom" && File.Exists(config.path)) {
            mciSendString("close myaudio", null, 0, IntPtr.Zero);
            mciSendString("open \"" + config.path + "\" type mpegvideo alias myaudio", null, 0, IntPtr.Zero);
            mciSendString("play myaudio", null, 0, IntPtr.Zero);
        }
    }

    private void ShowSettings(object sender, EventArgs e) {
        using (Form f = new Form()) {
            f.Text = "Настройки оповещений";
            f.Size = new Size(400, 250);
            f.FormBorderStyle = FormBorderStyle.FixedDialog;
            f.MaximizeBox = false;
            f.MinimizeBox = false;
            f.StartPosition = FormStartPosition.CenterScreen;

            RadioButton rbNone = new RadioButton() { Text = "Без звука", Location = new Point(20, 20), Width = 300, Checked = (config.mode == "none") };
            RadioButton rbBeep = new RadioButton() { Text = "Встроенный писк (2 раза)", Location = new Point(20, 50), Width = 300, Checked = (config.mode == "beep") };
            RadioButton rbCustom = new RadioButton() { Text = "Свой файл (MP3/WAV):", Location = new Point(20, 80), Width = 150, Checked = (config.mode == "custom") };

            TextBox txtPath = new TextBox() { Location = new Point(175, 80), Width = 120, Text = config.path };
            Button btnBrowse = new Button() { Text = "...", Location = new Point(300, 78), Width = 60 };
            btnBrowse.Click += (s, ev) => {
                OpenFileDialog ofd = new OpenFileDialog() { Filter = "Audio files|*.mp3;*.wav|All files|*.*" };
                if (ofd.ShowDialog() == DialogResult.OK) { txtPath.Text = ofd.FileName; rbCustom.Checked = true; }
            };

            Button btnSave = new Button() { Text = "Сохранить", Location = new Point(150, 150), Width = 100 };
            btnSave.Click += (s, ev) => {
                if (rbNone.Checked) config.mode = "none";
                else if (rbBeep.Checked) config.mode = "beep";
                else config.mode = "custom";
                config.path = txtPath.Text;
                SaveConfig();
                f.Close();
            };

            f.Controls.Add(rbNone);
            f.Controls.Add(rbBeep);
            f.Controls.Add(rbCustom);
            f.Controls.Add(txtPath);
            f.Controls.Add(btnBrowse);
            f.Controls.Add(btnSave);
            f.ShowDialog();
        }
    }

    private void LoadConfig() {
        try {
            if (File.Exists(configPath)) {
                string json = File.ReadAllText(configPath);
                config = new JavaScriptSerializer().Deserialize<TrayConfig>(json);
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