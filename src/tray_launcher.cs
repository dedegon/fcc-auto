using System;
using System.Windows.Forms;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.IO;
using System.Web.Script.Serialization;
using System.Drawing;

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
    private Process claudeProcess = null;

    [DllImport("winmm.dll")]
    private static extern long mciSendString(string strCommand, System.Text.StringBuilder strReturn, int iReturnLength, IntPtr hwndCallback);

    public TrayLauncher() {
        LoadConfig();
        trayIcon = new NotifyIcon() {
            Icon = SystemIcons.Application, // Замени на иконку из ресурсов, если есть
            Visible = true,
            Text = "claude-auto 2.1.0"
        };

        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add("🚀 Запустить Claude Code", null, StartClaude);
        menu.Items.Add("🌐 Открыть панель FCC", null, OpenFcc);
        menu.Items.Add("⚙️ Настройки оповещений", null, ShowSettings);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("❌ Выход", null, ExitApp);

        trayIcon.ContextMenuStrip = menu;
        trayIcon.DoubleClick += OpenFcc;
        AddToStartup();
    }

    private void StartClaude(object sender, EventArgs e) {
        if (claudeProcess != null && !claudeProcess.HasExited) {
            MessageBox.Show("Claude Code уже запущен.", "claude-auto", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", "/c claude-auto");
        psi.UseShellExecute = true;

        try {
            claudeProcess = Process.Start(psi);
            claudeProcess.EnableRaisingEvents = true;
            claudeProcess.Exited += (s, ev) => { PlayNotification(); };
        } catch (Exception ex) {
            MessageBox.Show("Ошибка запуска: " + ex.Message, "Ошибка", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void OpenFcc(object sender, EventArgs e) {
        try { Process.Start("http://127.0.0.1:8082/admin"); } catch { }
    }

    private void PlayNotification() {
        if (config.mode == "none") return;

        if (config.mode == "beep") {
            // Играем писк 2 раза
            new System.Threading.Thread(() => {
                try {
                    Console.Beep(3830, 150);
                    System.Threading.Thread.Sleep(100);
                    Console.Beep(1783, 150);
                } catch { System.Media.SystemSounds.Exclamation.Play(); }
            }).Start();
        } else if (config.mode == "custom" && File.Exists(config.path)) {
            // Играем MP3 через MCI
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

            RadioButton rbBeep = new RadioButton() { Text = "Встроенный писк (2 раза)", Location = new Point(20, 20), Width = 300, Checked = (config.mode == "beep" || config.mode == "none") };
            RadioButton rbCustom = new RadioButton() { Text = "Свой файл (MP3/WAV):", Location = new Point(20, 50), Width = 150, Checked = (config.mode == "custom") };

            TextBox txtPath = new TextBox() { Location = new Point(175, 50), Width = 120, Text = config.path };
            Button btnBrowse = new Button() { Text = "...", Location = new Point(300, 48), Width = 60 };
            btnBrowse.Click += (s, ev) => {
                OpenFileDialog ofd = new OpenFileDialog() { Filter = "Audio files|*.mp3;*.wav|All files|*.*" };
                if (ofd.ShowDialog() == DialogResult.OK) { txtPath.Text = ofd.FileName; rbCustom.Checked = true; }
            };

            Button btnSave = new Button() { Text = "Сохранить", Location = new Point(150, 150), Width = 100 };
            btnSave.Click += (s, ev) => {
                config.mode = rbBeep.Checked ? "beep" : "custom";
                config.path = txtPath.Text;
                SaveConfig();
                f.Close();
            };

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