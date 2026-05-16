<#
Build a public-safe, binary-only app folder.

Output:
  publish/public-binary-only

Goals:
- Keep firmware/license payloads encoded (via build-public-github-copy.ps1)
- Hide main app logic by embedding PS script payload into launcher EXE
- Remove readable logic scripts from publish folder
#>

param(
    [string]$AppVersion   = $env:SMT_APP_VERSION,
    [string]$GitHubToken = $env:GITHUB_TOKEN,
    [switch]$SkipRelease
)

$ErrorActionPreference = 'Stop'

$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$publishRoot = Join-Path $baseDir 'publish'
$publicSourceDir = Join-Path $publishRoot 'public-github'
$publicBinaryDir = Join-Path $publishRoot 'public-binary-only'

function Log([string]$msg) {
    Write-Host "[public-binary] $msg"
}

function Ensure-Directory([string]$path) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }
}

function Compress-ToBase64([string]$text) {
    $utf8 = [System.Text.Encoding]::UTF8.GetBytes($text)
    $ms = New-Object System.IO.MemoryStream
    try {
        $gzip = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
        try {
            $gzip.Write($utf8, 0, $utf8.Length)
        } finally {
            $gzip.Dispose()
        }
        return [Convert]::ToBase64String($ms.ToArray())
    } finally {
        $ms.Dispose()
    }
}

function Bundle-AllPayloads([string]$srcDir) {
    # Bundles EVERYTHING needed in the install dir into one compressed manifest:
    #   - Firmware/code folders (Arduino, STM32, PoKeys, tools)
    #   - Root code files (MachMacroInstaller.ps1)
    #   - App runtime (launcher EXE, config, license, icon, vbs, bat)
    # Result: the installer EXE is fully self-contained. No other files needed.
    $sb = New-Object System.Text.StringBuilder

    # 1. Code/firmware folders
    $spec = @(
        @{ Folder = 'Arduino'; Exts = @('.ino','.cpp','.h','.c') },
        @{ Folder = 'STM32';   Exts = $null },
        @{ Folder = 'PoKeys';  Exts = $null },
        @{ Folder = 'tools';   Exts = @('.ps1','.bat','.cmd','.exe','.dll') }
    )
    foreach ($s in $spec) {
        $dir = Join-Path $srcDir $s.Folder
        if (-not (Test-Path $dir)) { continue }
        $items = if ($s.Exts) {
            Get-ChildItem -Recurse -File $dir | Where-Object { $s.Exts -contains $_.Extension.ToLower() }
        } else {
            Get-ChildItem -Recurse -File $dir | Where-Object { $_.Extension.ToLower() -ne '.md' }
        }
        foreach ($item in $items) {
            # Skip large EXE files (>4MB) — they exceed C# 16MB string literal limit when base64-encoded
            # arduino-cli.exe (35MB) is downloaded at install time instead
            if ($item.Extension.ToLower() -eq '.exe' -and $item.Length -gt 4194304) { continue }
            $rel = $item.FullName.Substring($srcDir.Length).TrimStart('\','/').Replace('\','/')
            $bytes = [System.IO.File]::ReadAllBytes($item.FullName)
            $sb.AppendLine($rel) | Out-Null
            $sb.AppendLine([Convert]::ToBase64String($bytes)) | Out-Null
        }
    }

    # 2. Root code files
    foreach ($rf in @('MachMacroInstaller.ps1')) {
        $fp = Join-Path $srcDir $rf
        if (-not (Test-Path $fp)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($fp)
        $sb.AppendLine($rf.Replace('\','/')) | Out-Null
        $sb.AppendLine([Convert]::ToBase64String($bytes)) | Out-Null
    }

    # 3. App runtime — launcher EXE and support files placed in install root
    foreach ($af in @(
        'STEELMETTLE-THC-Systems-Integrator.exe',
        'STEELMETTLE-THC-Systems-Integrator-Launcher.vbs',
        'STEELMETTLE-THC-Systems-Integrator.bat',
        'config.json'
    )) {
        $fp = Join-Path $srcDir $af
        if (-not (Test-Path $fp)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($fp)
        $sb.AppendLine($af.Replace('\','/')) | Out-Null
        $sb.AppendLine([Convert]::ToBase64String($bytes)) | Out-Null
    }

    # 4. Sub-folder runtime files
    foreach ($sf in @('licenses\user.license.json', 'assets\SteelMettle.ico')) {
        $fp = Join-Path $srcDir $sf
        if (-not (Test-Path $fp)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($fp)
        $sb.AppendLine($sf.Replace('\','/')) | Out-Null
        $sb.AppendLine([Convert]::ToBase64String($bytes)) | Out-Null
    }

    return Compress-ToBase64 -text $sb.ToString()
}

function New-EmbeddedLauncherSource([string]$payloadB64) {
@"
using System;
using System.IO;
using System.IO.Compression;
using System.Management.Automation;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

static class SteelMettleLauncher
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern void SetCurrentProcessExplicitAppUserModelID(string appID);

    static string DecodeScript()
    {
        string b64 = @"$payloadB64";
        byte[] gz = Convert.FromBase64String(b64);
        using (var input = new MemoryStream(gz))
        using (var gzs = new GZipStream(input, CompressionMode.Decompress))
        using (var output = new MemoryStream())
        {
            gzs.CopyTo(output);
            return Encoding.UTF8.GetString(output.ToArray());
        }
    }

    static string GetHostLogPath()
    {
        string baseDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "STEELMETTLE THC Systems Integrator",
            "logs");
        Directory.CreateDirectory(baseDir);
        return Path.Combine(baseDir, "launcher-host.log");
    }

    static void HostLog(string message)
    {
        try
        {
            File.AppendAllText(
                GetHostLogPath(),
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [launcher] " + message + Environment.NewLine,
                Encoding.UTF8);
        }
        catch { }
    }

    [STAThread]
    static void Main()
    {
        try
        {
            HostLog("Launcher start");
            SetCurrentProcessExplicitAppUserModelID("SteelMettle.THCSystemsIntegrator");

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string exeDir = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
            if (string.IsNullOrWhiteSpace(exeDir)) exeDir = AppDomain.CurrentDomain.BaseDirectory;
            Directory.SetCurrentDirectory(exeDir);
            HostLog("ExeDir=" + exeDir);

            string scriptText = DecodeScript();
            HostLog("Decoded script length=" + scriptText.Length);

            using (PowerShell ps = PowerShell.Create())
            {
                // Keep script text intact so its top-level param(...) block remains valid.
                // Inject base directory through runspace state instead of prepending script source.
                ps.Runspace.SessionStateProxy.SetVariable("__SMTExeBaseDir", exeDir);
                ps.AddScript(scriptText).AddParameter("Gui", true);
                HostLog("Invoking embedded PowerShell script");
                ps.Invoke();

                if (ps.HadErrors)
                {
                    string err = "";
                    foreach (var e in ps.Streams.Error)
                    {
                        if (e == null) continue;
                        err += e.ToString() + Environment.NewLine;
                    }
                    if (string.IsNullOrWhiteSpace(err)) err = "Unknown PowerShell host error.";
                    HostLog("PowerShell had errors: " + err.Replace(Environment.NewLine, " | "));
                    MessageBox.Show(
                        "Startup error:\n\n" + err + "\nHost log: " + GetHostLogPath(),
                        "STEELMETTLE THC Systems Integrator",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                }
                else
                {
                    HostLog("Embedded script completed without host-reported errors");
                }
            }
        }
        catch (Exception ex)
        {
            HostLog("Fatal launcher exception: " + ex.ToString().Replace(Environment.NewLine, " | "));
            MessageBox.Show(
                "Launcher startup failed:\n\n" + ex + "\n\nHost log: " + GetHostLogPath(),
                "STEELMETTLE THC Systems Integrator",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}
"@
}

function New-InstallerSource([string]$firmwareBundleB64) {
@"
using System;
using System.IO;
using System.IO.Compression;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

static class SteelMettleInstaller
{
    static Form       _form;
    static Panel      _content;
    static Panel      _pageWelcome;
    static Panel      _pageProgress;
    static Panel      _pageDone;
    static readonly string _fwBundle = @"$firmwareBundleB64";
    static ProgressBar _pb;
    static Label      _statusLbl;
    static string     _sourceDir;
    static string     _installDir;
    static bool       _isUpdateInstall;
    static int        _waitForPid;

    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        _sourceDir = AppDomain.CurrentDomain.BaseDirectory;
        _installDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "STEELMETTLE THC Systems Integrator");

        string[] args = Environment.GetCommandLineArgs();
        _isUpdateInstall = false;
        _waitForPid = -1;

        for (int i = 1; i < args.Length; i++)
        {
            string a = args[i];
            if (string.Equals(a, "--update", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(a, "/update", StringComparison.OrdinalIgnoreCase))
            {
                _isUpdateInstall = true;
                continue;
            }

            if (a.StartsWith("--wait-pid=", StringComparison.OrdinalIgnoreCase))
            {
                int parsed;
                if (int.TryParse(a.Substring("--wait-pid=".Length), out parsed) && parsed > 0)
                {
                    _waitForPid = parsed;
                }
                continue;
            }

            if (string.Equals(a, "--wait-pid", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(a, "/wait-pid", StringComparison.OrdinalIgnoreCase))
            {
                if (i + 1 < args.Length)
                {
                    int parsed;
                    if (int.TryParse(args[i + 1], out parsed) && parsed > 0)
                    {
                        _waitForPid = parsed;
                        i++;
                    }
                }
                continue;
            }
        }

        // Fallback: if app is already installed, treat this run as an update install.
        if (!_isUpdateInstall)
        {
            string installedExe = Path.Combine(_installDir, "STEELMETTLE-THC-Systems-Integrator.exe");
            if (File.Exists(installedExe)) _isUpdateInstall = true;
        }

        if (_waitForPid > 0)
        {
            WaitForProcessExit(_waitForPid, 30000);
        }

        Build();
        if (_isUpdateInstall)
        {
            _form.Shown += delegate
            {
                RunInstall(true);
            };
            Go(_pageProgress);
        }
        else
        {
            Go(_pageWelcome);
        }
        Application.Run(_form);
    }

    static void WaitForProcessExit(int pid, int timeoutMs)
    {
        try
        {
            Process p = Process.GetProcessById(pid);
            if (p != null && !p.HasExited)
            {
                p.WaitForExit(timeoutMs);
            }
        }
        catch
        {
            // Process already exited or cannot be queried.
        }
    }

    static Color C(int r, int g, int b) { return Color.FromArgb(r, g, b); }

    static void Build()
    {
        Color bg0       = C(14, 18, 22);
        Color bg1       = C(22, 32, 40);
        Color bg2       = C(28, 36, 22);
        Color accent    = C(195, 148, 18);
        Color accentHi  = C(240, 200, 55);
        Color textF     = C(245, 244, 240);
        Color textS     = C(190, 204, 212);
        Color textM     = C(120, 140, 150);
        Color subtle    = C(52, 66, 74);

        _form = new Form();
        _form.Text             = "STEELMETTLE LLC Systems Integrator - Setup";
        _form.Width            = 620;
        _form.Height           = 460;
        _form.StartPosition    = FormStartPosition.CenterScreen;
        _form.FormBorderStyle  = FormBorderStyle.None;
        _form.MaximizeBox      = false;
        _form.MinimizeBox      = false;
        _form.BackColor        = bg0;
        string icoFile = Path.Combine(_sourceDir, "assets", "SteelMettle.ico");
        if (File.Exists(icoFile)) try { _form.Icon = new Icon(icoFile); } catch {}

        // Border and gradient background
        _form.Paint += delegate(object sender, PaintEventArgs e)
        {
            using (var brush = new System.Drawing.Drawing2D.LinearGradientBrush(
                _form.ClientRectangle,
                bg0,
                bg1,
                90f))
            {
                e.Graphics.FillRectangle(brush, _form.ClientRectangle);
            }
            using (var pen = new Pen(accent, 1))
            {
                e.Graphics.DrawRectangle(pen, 0, 0, _form.Width - 1, _form.Height - 1);
            }
        };

        // Header
        Panel hdr = new Panel { Dock = DockStyle.Top, Height = 78, BackColor = bg1 };
        Point dragStart = Point.Empty;
        hdr.MouseDown += delegate(object sender, MouseEventArgs e) {
            if (e.Button == MouseButtons.Left) dragStart = e.Location;
        };
        hdr.MouseMove += delegate(object sender, MouseEventArgs e) {
            if (e.Button == MouseButtons.Left) {
                _form.Left += e.X - dragStart.X;
                _form.Top  += e.Y - dragStart.Y;
            }
        };
        hdr.Controls.Add(new Label {
            Text = "SYSTEMS INTEGRATOR",
            Dock = DockStyle.Bottom,
            Height = 24,
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Segoe UI", 10, FontStyle.Bold),
            ForeColor = accent, BackColor = Color.Transparent
        });
        hdr.Controls.Add(new Label {
            Text = "STEELMETTLE LLC",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Segoe UI Semibold", 20, FontStyle.Bold),
            ForeColor = textF, BackColor = Color.Transparent
        });

        Label xBtn = new Label {
            Text = "x",
            AutoSize = false,
            Size = new Size(34, 28),
            Location = new Point(582, 8),
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Segoe UI", 14, FontStyle.Regular),
            ForeColor = C(85, 102, 112),
            BackColor = Color.Transparent,
            Cursor = Cursors.Hand,
            Anchor = AnchorStyles.Top | AnchorStyles.Right
        };
        xBtn.MouseEnter += delegate { xBtn.ForeColor = C(230, 70, 50); };
        xBtn.MouseLeave += delegate { xBtn.ForeColor = C(85, 102, 112); };
        xBtn.Click += delegate { Application.Exit(); };
        hdr.Controls.Add(xBtn);
        _form.Controls.Add(hdr);

        Panel accentTop = new Panel { Dock = DockStyle.Top, Height = 5, BackColor = accent };
        _form.Controls.Add(accentTop);

        Panel accentLeft = new Panel { Dock = DockStyle.Left, Width = 5, BackColor = accent };
        _form.Controls.Add(accentLeft);

        // Content container
        _content = new Panel { Dock = DockStyle.Fill, BackColor = bg0 };
        _form.Controls.Add(_content);

        // === Welcome Page ===
        _pageWelcome = new Panel { Dock = DockStyle.Fill, BackColor = bg0, Visible = false };
        _pageWelcome.Controls.Add(new Label {
            Text = "Welcome to\nSTEELMETTLE LLC Systems Integrator",
            Font = new Font("Segoe UI", 16, FontStyle.Bold),
            ForeColor = textF, BackColor = Color.Transparent,
            TextAlign = ContentAlignment.MiddleCenter,
            Location = new Point(20, 14), Size = new Size(560, 86)
        });
        Panel wDiv = new Panel { BackColor = accent, Location = new Point(90, 106), Size = new Size(430, 2) };
        _pageWelcome.Controls.Add(wDiv);
        _pageWelcome.Controls.Add(new Label {
            Text = "This wizard installs STEELMETTLE THC Systems Integrator, creates\nDesktop and Start Menu shortcuts, and can launch the app after setup.\n\nInstall location: " + _installDir,
            Font = new Font("Segoe UI", 9), ForeColor = textS, BackColor = Color.Transparent,
            TextAlign = ContentAlignment.TopCenter,
            Location = new Point(20, 116), Size = new Size(560, 102)
        });
        _pageWelcome.Controls.Add(new Label {
            Text = "Sync   |   Detect   |   Flash   |   Deploy",
            Font = new Font("Segoe UI", 9, FontStyle.Bold), ForeColor = accent,
            BackColor = bg2, TextAlign = ContentAlignment.MiddleCenter,
            BorderStyle = BorderStyle.FixedSingle,
            Location = new Point(135, 234), Size = new Size(330, 30)
        });
        Button wInstall = MkBtn("GET STARTED", accent, accent, C(16, 18, 22));
        wInstall.Size = new Size(165, 40);
        wInstall.Location = new Point(315, 302);
        wInstall.Click += delegate { RunInstall(false); };
        _pageWelcome.Controls.Add(wInstall);
        Button wCancel = MkBtn("Cancel", bg1, bg1, textS);
        wCancel.Size = new Size(95, 40);
        wCancel.Location = new Point(490, 302);
        wCancel.Click += delegate { Application.Exit(); };
        _pageWelcome.Controls.Add(wCancel);
        _pageWelcome.Controls.Add(new Label {
            Text = "Precision Controls | Industrial Grade | Built for the Shop Floor",
            Font = new Font("Segoe UI", 8), ForeColor = subtle, BackColor = Color.Transparent,
            TextAlign = ContentAlignment.MiddleCenter,
            Location = new Point(20, 382), Size = new Size(560, 20)
        });
        _content.Controls.Add(_pageWelcome);

        // === Progress Page ===
        _pageProgress = new Panel { Dock = DockStyle.Fill, BackColor = bg0, Visible = false };
        _pageProgress.Controls.Add(new Label {
            Text = "Installing - Please wait",
            Font = new Font("Segoe UI Semibold", 13, FontStyle.Bold),
            ForeColor = textF, BackColor = Color.Transparent,
            TextAlign = ContentAlignment.MiddleCenter,
            Location = new Point(20, 34), Size = new Size(560, 38)
        });
        _pageProgress.Controls.Add(new Label {
            Text = "Please wait while the application files are being installed.",
            Font = new Font("Segoe UI", 9), ForeColor = textS, BackColor = Color.Transparent,
            TextAlign = ContentAlignment.MiddleCenter,
            Location = new Point(20, 76), Size = new Size(560, 24)
        });
        _pb = new ProgressBar { Location = new Point(20, 116), Size = new Size(560, 26), Maximum = 100 };
        _pageProgress.Controls.Add(_pb);
        _statusLbl = new Label {
            Text = "Preparing...", Font = new Font("Segoe UI", 9),
            ForeColor = textM, BackColor = Color.Transparent,
            Location = new Point(20, 152), Size = new Size(560, 22)
        };
        _pageProgress.Controls.Add(_statusLbl);
        _content.Controls.Add(_pageProgress);

        // === Done Page ===
        _pageDone = new Panel { Dock = DockStyle.Fill, BackColor = bg0, Visible = false };
        _pageDone.Controls.Add(new Label {
            Text = "Installation Complete!",
            Font = new Font("Segoe UI Semibold", 16, FontStyle.Bold),
            ForeColor = textF, BackColor = Color.Transparent,
            TextAlign = ContentAlignment.MiddleCenter,
            Location = new Point(20, 24), Size = new Size(560, 44)
        });
        Panel dDiv = new Panel { BackColor = accent, Location = new Point(95, 76), Size = new Size(430, 2) };
        _pageDone.Controls.Add(dDiv);
        _pageDone.Controls.Add(new Label {
            Text = "STEELMETTLE THC Systems Integrator has been installed.\n\n" +
                   "  - Desktop shortcut created\n" +
                   "  - Start Menu shortcut created\n\n" +
                   "Click Launch App to open the application now,\nor click Finish to close this installer.",
            Font = new Font("Segoe UI", 10), ForeColor = textS, BackColor = Color.Transparent,
            TextAlign = ContentAlignment.TopLeft,
            Location = new Point(95, 88), Size = new Size(430, 150)
        });
        Button dLaunch = MkBtn("LAUNCH APP", accent, accent, C(16, 18, 22));
        dLaunch.Size = new Size(150, 40);
        dLaunch.Location = new Point(340, 302);
        dLaunch.Click += delegate { LaunchApp(); Application.Exit(); };
        _pageDone.Controls.Add(dLaunch);
        Button dFinish = MkBtn("Finish", bg1, bg1, textS);
        dFinish.Size = new Size(95, 40);
        dFinish.Location = new Point(495, 302);
        dFinish.Click += delegate { Application.Exit(); };
        _pageDone.Controls.Add(dFinish);
        _content.Controls.Add(_pageDone);
    }

    static Button MkBtn(string text, Color border, Color back, Color fore)
    {
        Button b = new Button {
            Text = text, Size = new Size(100, 34),
            FlatStyle = FlatStyle.Flat, BackColor = back, ForeColor = fore,
            Font = new Font("Segoe UI Semibold", 10, FontStyle.Bold), Cursor = Cursors.Hand
        };
        b.FlatAppearance.BorderSize = 1;
        b.FlatAppearance.BorderColor = border;
        b.MouseEnter += delegate {
            b.BackColor = Color.FromArgb(
                Math.Min(255, b.BackColor.R + 25),
                Math.Min(255, b.BackColor.G + 25),
                Math.Min(255, b.BackColor.B + 25));
        };
        b.MouseLeave += delegate { b.BackColor = back; };
        return b;
    }

    static void Go(Panel page)
    {
        _pageWelcome.Visible  = false;
        _pageProgress.Visible = false;
        _pageDone.Visible     = false;
        page.Visible = true;
        page.BringToFront();
    }

    static void SetProgress(int value, string status)
    {
        if (value >= 0) _pb.Value = Math.Min(value, 100);
        _statusLbl.Text = status;
        Application.DoEvents();
    }

    static void RunInstall(bool autoLaunchAfterInstall)
    {
        Go(_pageProgress);
        try
        {
            SetProgress(5,  "Creating installation directory...");
            if (!Directory.Exists(_installDir))
                Directory.CreateDirectory(_installDir);

            SetProgress(10, "Copying application files...");
            DirectoryCopy(_sourceDir, _installDir, true);

            SetProgress(72, "Extracting firmware payloads...");
            ExtractFirmwareBundle(_installDir);

            SetProgress(78, "Downloading arduino-cli...");
            DownloadArduinoCli(_installDir);

            SetProgress(85, "Creating shortcuts...");
            string launcherExe = Path.Combine(_installDir, "STEELMETTLE-THC-Systems-Integrator.exe");
            string icoPath     = Path.Combine(_installDir, "assets", "SteelMettle.ico");
            if (!File.Exists(icoPath)) icoPath = launcherExe;

            if (!File.Exists(launcherExe))
                throw new FileNotFoundException("Launcher EXE missing after install: " + launcherExe);

            CreateShortcut(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                    "STEELMETTLE THC Systems Integrator.lnk"),
                launcherExe, _installDir, icoPath);

            CreateShortcut(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
                    "Programs", "STEELMETTLE THC Systems Integrator.lnk"),
                launcherExe, _installDir, icoPath);

            SetProgress(100, "Installation complete.");
            if (autoLaunchAfterInstall)
            {
                LaunchApp();
                Application.Exit();
                return;
            }

            Go(_pageDone);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Installation failed:\n\n" + ex.Message,
                "STEELMETTLE Installer",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            Application.Exit();
        }
    }

    static void LaunchApp()
    {
        string exe = Path.Combine(_installDir, "STEELMETTLE-THC-Systems-Integrator.exe");
        if (File.Exists(exe)) System.Diagnostics.Process.Start(exe);
    }

    static void DownloadArduinoCli(string baseDir)
    {
        string toolsDir = Path.Combine(baseDir, "tools");
        string dest = Path.Combine(toolsDir, "arduino-cli.exe");
        if (File.Exists(dest)) return;  // Already present (reinstall/update)
        if (!Directory.Exists(toolsDir)) Directory.CreateDirectory(toolsDir);
        try
        {
            string url = "https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Windows_64bit.zip";
            string zip = Path.Combine(Path.GetTempPath(), "arduino-cli.zip");
            using (var wc = new System.Net.WebClient())
                wc.DownloadFile(url, zip);
            // Extract arduino-cli.exe from zip
            using (var fs = File.OpenRead(zip))
            using (var archive = new System.IO.Compression.ZipArchive(fs, System.IO.Compression.ZipArchiveMode.Read))
            {
                foreach (var entry in archive.Entries)
                {
                    if (entry.Name.Equals("arduino-cli.exe", StringComparison.OrdinalIgnoreCase))
                    {
                        entry.ExtractToFile(dest, true);
                        break;
                    }
                }
            }
            File.Delete(zip);
        }
        catch { /* Non-fatal: user can place arduino-cli.exe manually */ }
    }

    static void ExtractFirmwareBundle(string baseDir)
    {
        if (string.IsNullOrEmpty(_fwBundle)) return;
        byte[] gz = Convert.FromBase64String(_fwBundle);
        string text;
        using (var input = new MemoryStream(gz))
        using (var gzs = new GZipStream(input, CompressionMode.Decompress))
        using (var output = new MemoryStream())
        {
            gzs.CopyTo(output);
            text = System.Text.Encoding.UTF8.GetString(output.ToArray());
        }
        string[] lines = text.Split('\n');
        for (int i = 0; i + 1 < lines.Length; i += 2)
        {
            string relPath = lines[i].Trim();
            string b64data = lines[i + 1].Trim();
            if (string.IsNullOrEmpty(relPath) || string.IsNullOrEmpty(b64data)) continue;
            string fullPath = Path.Combine(baseDir, relPath.Replace('/', Path.DirectorySeparatorChar));
            string dir = Path.GetDirectoryName(fullPath);
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            File.WriteAllBytes(fullPath, Convert.FromBase64String(b64data));
        }
    }

    static void DirectoryCopy(string src, string dst, bool recurse)
    {
        DirectoryInfo dir = new DirectoryInfo(src);
        if (!dir.Exists) throw new DirectoryNotFoundException("Source not found: " + src);
        if (!Directory.Exists(dst)) Directory.CreateDirectory(dst);
        FileInfo[] files = dir.GetFiles();
        for (int i = 0; i < files.Length; i++)
        {
            string dstFile = Path.Combine(dst, files[i].Name);
            // Skip if source and destination are the same file (reinstall from install dir)
            if (string.Equals(Path.GetFullPath(files[i].FullName),
                              Path.GetFullPath(dstFile),
                              StringComparison.OrdinalIgnoreCase)) continue;
            try { files[i].CopyTo(dstFile, true); }
            catch (IOException) { /* file in use – skip, already present */ }
            catch (UnauthorizedAccessException) { /* locked – skip */ }
            SetProgress(10 + (int)(72.0 * i / Math.Max(1, files.Length)), "Copying: " + files[i].Name);
        }
        if (recurse)
        {
            foreach (DirectoryInfo sub in dir.GetDirectories())
            {
                if (sub.Name.Equals(".git", StringComparison.OrdinalIgnoreCase)) continue;
                DirectoryCopy(sub.FullName, Path.Combine(dst, sub.Name), true);
            }
        }
    }

    static void CreateShortcut(string shortcutPath, string targetPath, string workingDir, string iconPath)
    {
        Type t = Type.GetTypeFromProgID("WScript.Shell");
        dynamic shell = Activator.CreateInstance(t);
        dynamic sc = shell.CreateShortcut(shortcutPath);
        sc.TargetPath    = targetPath;
        sc.Arguments     = "";
        sc.WorkingDirectory = workingDir;
        sc.IconLocation  = iconPath + ",0";
        sc.Description   = "STEELMETTLE THC Systems Integrator";
        sc.Save();
    }
}
"@
}

# 1) Always refresh encoded public source to avoid stale embedded scripts
Log 'Refreshing public-github source...'
& (Join-Path $baseDir 'build-public-github-copy.ps1')

if (-not (Test-Path $publicSourceDir)) {
    throw "Missing source publish folder: $publicSourceDir"
}

# 2) Copy source folder to binary-only target
if (Test-Path $publicBinaryDir) {
    Log "Removing previous output: $publicBinaryDir"
    Remove-Item -Recurse -Force $publicBinaryDir
}
Ensure-Directory $publicBinaryDir

Log 'Copying public-github -> public-binary-only...'
$rc = & robocopy $publicSourceDir $publicBinaryDir /MIR /R:1 /W:1 /XD .git .vs .vscode 2>&1
if ($LASTEXITCODE -gt 7) {
    throw "Copy failed with robocopy code $LASTEXITCODE"
}

# 2b) Inject vendor binaries stripped by public-github-copy (required at runtime)
$toolsDst = Join-Path $publicBinaryDir 'tools'
Ensure-Directory $toolsDst
$injectFiles = @(
    'PoKeysDevice_DLL.dll',
    'arduino-cli.exe'
)
foreach ($injectFile in $injectFiles) {
    $src = Join-Path $baseDir "tools\$injectFile"
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $toolsDst $injectFile) -Force
        Log "Injected tools\$injectFile into binary-only output."
    } else {
        Log "WARNING: tools\$injectFile not found in source - skipping injection."
    }
}

# 2c) Retarget updater config for the public download repository
$configPath = Join-Path $publicBinaryDir 'config.json'
if (Test-Path $configPath) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        if (-not $cfg.update) {
            $cfg | Add-Member -NotePropertyName update -NotePropertyValue ([pscustomobject]@{})
        }

        $cfg.update.enabled = $true
        if (-not $cfg.update.repo -or [string]::IsNullOrWhiteSpace([string]$cfg.update.repo)) {
            throw 'config.json update.repo is empty. Set it to owner/repo for your GitHub release feed.'
        }
        if ($AppVersion -and -not [string]::IsNullOrWhiteSpace($AppVersion)) {
            $cfg.update.currentVersion = $AppVersion.Trim()
        }
        if (-not $cfg.update.currentVersion -or [string]::IsNullOrWhiteSpace([string]$cfg.update.currentVersion)) {
            $cfg.update.currentVersion = '0.0.0'
        }
        $cfg.update.assetNamePattern = 'STEELMETTLE-THC-Systems-Integrator-Installer.exe'
        $cfg.update.autoCheckOnLaunch = $true

        $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $configPath -Encoding UTF8
        Log ("Updated config.json app update target for public download distribution. currentVersion={0}" -f $cfg.update.currentVersion)
    } catch {
        throw "Could not update config.json for binary-only distribution: $_"
    }
}

# 3) Build embedded launcher EXE from the sanitized public script text
$scriptPath = Join-Path $publicBinaryDir 'STEELMETTLE-THC-Systems-Integrator.ps1'
if (-not (Test-Path $scriptPath)) {
    throw "Missing public app script: $scriptPath"
}
$appScriptText = Get-Content -Path $scriptPath -Raw
$payloadB64 = Compress-ToBase64 -text $appScriptText

$generatedCsPath = Join-Path $publicBinaryDir 'launcher_embedded_generated.cs'
$launcherSource = New-EmbeddedLauncherSource -payloadB64 $payloadB64
Set-Content -Path $generatedCsPath -Value $launcherSource -Encoding UTF8

$cscPath = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $cscPath)) {
    throw "C# compiler not found: $cscPath"
}

$smaPath = [psobject].Assembly.Location
$wfPath = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Windows.Forms.dll'
$drawingPath = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Drawing.dll'
$ioCompPath = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.IO.Compression.FileSystem.dll'
$iconPath = Join-Path $publicBinaryDir 'assets\SteelMettle.ico'
$outExe = Join-Path $publicBinaryDir 'STEELMETTLE-THC-Systems-Integrator.exe'

Log 'Compiling embedded launcher EXE...'
$args = @(
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    "/reference:$smaPath",
    "/reference:$wfPath",
    "/reference:$ioCompPath",
    "/out:$outExe",
    $generatedCsPath
)
if (Test-Path $iconPath) {
    $args = @('/win32icon:' + $iconPath) + $args
}

& $cscPath @args | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outExe)) {
    throw 'Failed to compile embedded launcher EXE.'
}

# 4) Build a native installer EXE — embeds ALL payloads (firmware + app runtime)
Log 'Bundling all payloads into installer (firmware, code, launcher EXE, support files)...'
$firmwareBundleB64 = Bundle-AllPayloads -srcDir $publicBinaryDir
$installerCsPath = Join-Path $publicBinaryDir 'installer_generated.cs'
Set-Content -Path $installerCsPath -Value (New-InstallerSource -firmwareBundleB64 $firmwareBundleB64) -Encoding UTF8

$installerExe = Join-Path $publicBinaryDir 'STEELMETTLE-THC-Systems-Integrator-Installer.exe'
$installerArgs = @(
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    "/reference:$wfPath",
    "/reference:$drawingPath",
    "/out:$installerExe",
    $installerCsPath
)
if (Test-Path $iconPath) {
    $installerArgs = @('/win32icon:' + $iconPath) + $installerArgs
}

Log 'Compiling native installer EXE...'
& $cscPath @installerArgs | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $installerExe)) {
    throw 'Failed to compile installer EXE.'
}

# 5) Final cleanup — keep ONLY the installer EXE, README, and .gitignore.
#    Everything else is now embedded inside the installer EXE.
Log 'Cleaning output folder — keeping only installer EXE, README, and .gitignore...'
$keepFiles = @(
    'STEELMETTLE-THC-Systems-Integrator-Installer.exe',
    'README.md',
    '.gitignore'
)
Get-ChildItem -Path $publicBinaryDir | ForEach-Object {
    if ($keepFiles -notcontains $_.Name) {
        try {
            Remove-Item -Recurse -Force $_.FullName -ErrorAction Stop
            Log "Stripped from public output: $($_.Name)"
        } catch {
            Log "WARNING: Could not strip from public output: $($_.Name) - $($_.Exception.Message)"
        }
    }
}

# 6) Write end-user README
$readmePath = Join-Path $publicBinaryDir 'README.md'
@"
# STEELMETTLE THC Systems Integrator

## Install

1. Download **STEELMETTLE-THC-Systems-Integrator-Installer.exe**
2. Run it — the installer sets up everything automatically
3. Click **Launch App** when done, or use the Desktop / Start Menu shortcut

## Updates
The app checks for updates automatically on launch.
When a new release is published here, you will be prompted to install it.

---
*© STEELMETTLE LLC — All rights reserved.*
"@ | Set-Content -Path $readmePath -Encoding UTF8

Log "Single-file public output complete: $publicBinaryDir"

# 7) Push to GitHub and create a GitHub Release automatically
if (-not $SkipRelease) {
    # Read repo slug from source config
    $srcCfgPath = Join-Path $baseDir 'config.json'
    $repoSlug   = ''
    if (Test-Path $srcCfgPath) {
        try { $repoSlug = [string](Get-Content $srcCfgPath -Raw | ConvertFrom-Json).update.repo } catch {}
    }
    $releaseName = if (-not [string]::IsNullOrWhiteSpace($AppVersion)) { "v$($AppVersion.Trim())" } else { 'v0.0.0' }

    if ([string]::IsNullOrWhiteSpace($repoSlug)) {
        Log 'WARNING: update.repo not set in config.json - skipping GitHub publish.'
    } else {
        # --- git push ---
        Log "Pushing build to GitHub ($repoSlug) main branch..."
        $tokenPrefix = if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) { "${GitHubToken}@" } else { '' }
        $remoteUrl   = "https://${tokenPrefix}github.com/${repoSlug}.git"
        Push-Location $publicBinaryDir
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            & git init -b main            2>&1 | Out-Null
            & git config user.name  'STEELMETAL'          2>&1 | Out-Null
            & git config user.email 'Jashuahill13@gmail.com' 2>&1 | Out-Null
            & git remote add origin $remoteUrl            2>&1 | Out-Null
            & git remote set-url origin $remoteUrl        2>&1 | Out-Null
            & git add -A                                  2>&1 | Out-Null
            & git commit -m "Release $releaseName"        2>&1 | Out-Null
            & git push --force -u origin main             2>&1 | Out-Null
            $pushExit = $LASTEXITCODE
            $ErrorActionPreference = $prevEAP
            if ($pushExit -eq 0) { Log 'Git push complete.' } else { Log "WARNING: Git push returned exit code $pushExit." }
        Pop-Location

        # --- GitHub Release API ---
        if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
            Log "No GitHub token provided. Set -GitHubToken or the GITHUB_TOKEN environment variable."
            Log "Manually create the release at: https://github.com/$repoSlug/releases/new"
        } else {
            $apiHeaders = @{
                Authorization = "token $GitHubToken"
                Accept        = 'application/vnd.github.v3+json'
                'User-Agent'  = 'STEELMETTLE-Build-Script'
            }
            $assetFileName = 'STEELMETTLE-THC-Systems-Integrator-Installer.exe'
            $installerPath = Join-Path $publicBinaryDir $assetFileName

            # Get or create the release for this tag
            Log "Looking up GitHub Release $releaseName..."
            $release = $null
            try {
                $release = Invoke-RestMethod `
                    -Uri     "https://api.github.com/repos/$repoSlug/releases/tags/$releaseName" `
                    -Method  Get `
                    -Headers $apiHeaders
                Log "Release already exists - updating asset."
            } catch {
                # Release doesn't exist yet — create it
                try {
                    Log "Creating GitHub Release $releaseName..."
                    $releasePayload = [ordered]@{
                        tag_name         = $releaseName
                        target_commitish = 'main'
                        name             = $releaseName
                        body             = "Automated release $releaseName"
                        draft            = $false
                        prerelease       = $false
                    } | ConvertTo-Json -Depth 5 -Compress
                    $release = Invoke-RestMethod `
                        -Uri         "https://api.github.com/repos/$repoSlug/releases" `
                        -Method      Post `
                        -Headers     $apiHeaders `
                        -Body        $releasePayload `
                        -ContentType 'application/json'
                    Log "GitHub Release created: $($release.html_url)"
                } catch {
                    Log "WARNING: Could not create GitHub Release: $_"
                    Log "Manually create the release at: https://github.com/$repoSlug/releases/new"
                }
            }

            # Upload (or replace) the installer EXE asset
            if ($release -and (Test-Path $installerPath)) {
                try {
                    # Delete any existing asset with the same name so we can re-upload cleanly
                    $existing = $release.assets | Where-Object { $_.name -eq $assetFileName }
                    foreach ($old in $existing) {
                        Invoke-RestMethod `
                            -Uri     "https://api.github.com/repos/$repoSlug/releases/assets/$($old.id)" `
                            -Method  Delete `
                            -Headers $apiHeaders | Out-Null
                        Log "Deleted old asset: $($old.name)"
                    }
                    # Re-fetch release to get fresh upload_url after asset deletion
                    $release = Invoke-RestMethod `
                        -Uri     "https://api.github.com/repos/$repoSlug/releases/tags/$releaseName" `
                        -Method  Get `
                        -Headers $apiHeaders
                    $uploadUri  = ($release.upload_url -replace '\{.*\}', '') + "?name=$assetFileName"
                    $assetBytes = [System.IO.File]::ReadAllBytes($installerPath)
                    $assetResp  = Invoke-RestMethod `
                        -Uri         $uploadUri `
                        -Method      Post `
                        -Headers     $apiHeaders `
                        -Body        $assetBytes `
                        -ContentType 'application/octet-stream'
                    Log "Asset uploaded: $($assetResp.browser_download_url)"
                } catch {
                    Log "WARNING: Asset upload failed: $_"
                }
            } elseif (-not (Test-Path $installerPath)) {
                Log "WARNING: Installer EXE not found - asset not uploaded."
            }
        }
    }
}
