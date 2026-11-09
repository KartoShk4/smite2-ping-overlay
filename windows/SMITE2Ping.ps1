#requires -version 5.1
<#
  SMITE 2 Ping Overlay для Windows (портативная версия).
  Отдельная программа, в игру ничего не встраивает.
  F8 - показать/скрыть плашку. Плашку можно таскать мышкой.
  Плашка видна только когда окно игры активно.
  Запуск: двойной клик по "Запуск.bat". Выход: значок в трее -> "Выход".
#>

$ErrorActionPreference = 'Stop'
$ErrLog = Join-Path $env:TEMP 'smite2_ping_error.log'

# ---------- логика без интерфейса: лог игры и пинг ----------
$CoreCs = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace Smite2Ping
{
    // Читает лог игры кусочками с места, где остановился, и помнит последний "LogNet: Browse".
    public class LogWatcher
    {
        static readonly Regex BrowseRe = new Regex(@"LogNet: Browse: (\S+)");
        static readonly Regex IpRe = new Regex(@"^(\d{1,3}(?:\.\d{1,3}){3})(?::\d+)?");

        public string[] Candidates;
        public string Path;
        public string Last;
        long pos;
        DateTime created;
        byte[] rest = new byte[0];

        public LogWatcher(string[] candidates) { Candidates = candidates; }

        string FindLog()
        {
            foreach (string c in Candidates)
                if (!string.IsNullOrEmpty(c) && File.Exists(c)) return c;
            return null;
        }

        void Reset(string p, DateTime cr)
        {
            Path = p; created = cr; pos = 0; rest = new byte[0]; Last = null;
        }

        // "ip:1.2.3.4", "err:nolog", "err:nomatch" или "err:offline"
        public string Poll()
        {
            string p = FindLog();
            if (p == null) { Reset(null, DateTime.MinValue); return "err:nolog"; }
            try
            {
                FileInfo fi = new FileInfo(p);
                DateTime cr = fi.CreationTimeUtc;
                long len = fi.Length;
                // новый файл (новый запуск игры) или файл стал короче - читаем заново
                if (p != Path || cr != created || len < pos) Reset(p, cr);
                if (len > pos)
                {
                    using (FileStream fs = new FileStream(p, FileMode.Open, FileAccess.Read,
                                                          FileShare.ReadWrite | FileShare.Delete))
                    {
                        fs.Seek(pos, SeekOrigin.Begin);
                        MemoryStream ms = new MemoryStream();
                        ms.Write(rest, 0, rest.Length);
                        byte[] buf = new byte[65536];
                        long newPos = pos;
                        int n;
                        while ((n = fs.Read(buf, 0, buf.Length)) > 0) { ms.Write(buf, 0, n); newPos += n; }
                        byte[] all = ms.ToArray();
                        pos = newPos;
                        int nl = Array.LastIndexOf(all, (byte)10);
                        if (nl < 0) { rest = all; }
                        else
                        {
                            string text = Encoding.UTF8.GetString(all, 0, nl + 1);
                            rest = new byte[all.Length - nl - 1];
                            Array.Copy(all, nl + 1, rest, 0, rest.Length);
                            foreach (Match m in BrowseRe.Matches(text)) Last = m.Groups[1].Value;
                        }
                    }
                }
            }
            catch (IOException) { if (Last == null) return "err:nolog"; }
            catch (UnauthorizedAccessException) { return "err:nolog"; }
            return Classify(Last);
        }

        public static string Classify(string last)
        {
            if (string.IsNullOrEmpty(last)) return "err:nomatch";
            Match ip = IpRe.Match(last);
            if (ip.Success) return "ip:" + ip.Groups[1].Value;
            if (last.Contains("Standalone")) return "err:offline";
            return "err:nomatch";
        }
    }

    public class PingResult
    {
        public string Hop;
        public long Ms = -1;
    }

    public static class NetProbe
    {
        // Сервера Azure не отвечают на ping, поэтому ищем последние отвечающие узлы перед сервером
        // (как traceroute, но все TTL параллельно - так быстрее).
        public static Task<string[]> TraceAsync(string ip)
        {
            return Task.Run(() => Trace(ip));
        }

        public static string[] Trace(string ip)
        {
            const int maxHops = 30;
            IPAddress target = IPAddress.Parse(ip);
            string[] byTtl = new string[maxHops + 1];
            int successTtl = maxHops + 1;
            for (int round = 0; round < 2; round++)
            {
                Ping[] pingers = new Ping[maxHops + 1];
                Task<PingReply>[] tasks = new Task<PingReply>[maxHops + 1];
                byte[] data = new byte[32];
                List<Task> started = new List<Task>();
                for (int ttl = 1; ttl <= maxHops; ttl++)
                {
                    if (byTtl[ttl] != null || ttl > successTtl) continue;
                    pingers[ttl] = new Ping();
                    tasks[ttl] = pingers[ttl].SendPingAsync(target, 1000, data, new PingOptions(ttl, true));
                    started.Add(tasks[ttl]);
                }
                try { Task.WaitAll(started.ToArray(), 5000); } catch (AggregateException) { }
                for (int ttl = 1; ttl <= maxHops; ttl++)
                {
                    Task<PingReply> t = tasks[ttl];
                    if (t != null && t.Status == TaskStatus.RanToCompletion)
                    {
                        PingReply r = t.Result;
                        if ((r.Status == IPStatus.TtlExpired || r.Status == IPStatus.Success) && r.Address != null)
                        {
                            byTtl[ttl] = r.Address.ToString();
                            if (r.Status == IPStatus.Success && ttl < successTtl) successTtl = ttl;
                        }
                    }
                    if (pingers[ttl] != null) pingers[ttl].Dispose();
                }
            }
            List<string> hops = new List<string>();
            for (int ttl = 1; ttl <= maxHops && ttl <= successTtl; ttl++)
                if (byTtl[ttl] != null && !hops.Contains(byTtl[ttl])) hops.Add(byTtl[ttl]);
            if (hops.Count == 0) return new string[] { ip };
            // несколько последних узлов, ближайший к серверу первым
            List<string> last = hops.GetRange(Math.Max(0, hops.Count - 4), Math.Min(4, hops.Count));
            last.Reverse();
            return last.ToArray();
        }

        public static Task<PingResult> PingHopsAsync(string[] hops)
        {
            return Task.Run(() => PingHops(hops));
        }

        public static PingResult PingHops(string[] hops)
        {
            PingResult res = new PingResult();
            foreach (string h in hops)
            {
                try
                {
                    using (Ping p = new Ping())
                    {
                        PingReply r = p.Send(h, 1000);
                        if (r.Status == IPStatus.Success)
                        {
                            res.Hop = h;
                            res.Ms = r.RoundtripTime;
                            return res;
                        }
                    }
                }
                catch (Exception) { }
            }
            return res;
        }
    }
}
'@

# ---------- окно-плашка, F8, проверка активного окна ----------
$UiCs = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Smite2Ping
{
    public static class Win32
    {
        public delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc fn, IntPtr hMod, uint threadId);
        [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hHook);
        [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hHook, int code, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string name);
    }

    public static class FocusCheck
    {
        static uint lastPid;
        static bool lastIsGame;
        static readonly int selfPid = Process.GetCurrentProcess().Id;

        // 1 = игра активна, 0 = нет, -1 = активна сама плашка/меню трея (оставляем как было)
        public static int GameState(IntPtr self)
        {
            IntPtr fg = Win32.GetForegroundWindow();
            if (fg == IntPtr.Zero) return 0;
            if (fg == self) return -1;
            uint pid;
            Win32.GetWindowThreadProcessId(fg, out pid);
            if (pid == (uint)selfPid) return -1;
            if (Win32.IsIconic(fg)) return 0;
            if (pid != lastPid)
            {
                lastPid = pid;
                try
                {
                    using (Process p = Process.GetProcessById((int)pid))
                        lastIsGame = p.ProcessName.IndexOf("hemingway", StringComparison.OrdinalIgnoreCase) >= 0;
                }
                catch (Exception) { lastIsGame = false; }
            }
            return lastIsGame ? 1 : 0;
        }
    }

    public class OverlayForm : Form
    {
        const int WM_HOTKEY = 0x0312, WM_MOUSEACTIVATE = 0x0021, MA_NOACTIVATE = 3;
        const int WM_TOGGLE = 0x8001, HOTKEY_ID = 0x5332, VK_F8 = 0x77;
        const int WS_EX_TOPMOST = 0x8, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;

        public event EventHandler ToggleRequested;
        public event EventHandler PositionChanged;
        public bool HotkeyRegistered;
        public bool HookInstalled;

        string text = "";
        Color color = Color.White;
        readonly Font font = new Font("Consolas", 12f, FontStyle.Bold);
        bool dragging;
        Point dragOffset;
        IntPtr hook = IntPtr.Zero;
        Win32.LowLevelKeyboardProc hookProc;
        bool f8Down;
        int lastToggle = Environment.TickCount - 10000;

        public OverlayForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.Black;
            Opacity = 0.85;
            DoubleBuffered = true;
            Cursor = Cursors.SizeAll;
            MinimumSize = new Size(1, 1);
            SetBadge("Ping: \u2026", Color.White);
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
                return cp;
            }
        }

        public void SetBadge(string t, Color c)
        {
            if (t == text && c == color) return;
            text = t; color = c;
            Size sz = TextRenderer.MeasureText(t, font, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            Size want = new Size(sz.Width + 24, sz.Height + 12);
            if (Size != want) Size = want;
            Invalidate();
        }

        protected override void OnSizeChanged(EventArgs e)
        {
            base.OnSizeChanged(e);
            int d = 16; // скругление ~8 px
            using (GraphicsPath gp = new GraphicsPath())
            {
                gp.AddArc(0, 0, d, d, 180, 90);
                gp.AddArc(Width - d, 0, d, d, 270, 90);
                gp.AddArc(Width - d, Height - d, d, d, 0, 90);
                gp.AddArc(0, Height - d, d, d, 90, 90);
                gp.CloseFigure();
                Region old = Region;
                Region = new Region(gp);
                if (old != null) old.Dispose();
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Color.Black);
            TextRenderer.DrawText(e.Graphics, text, font, new Rectangle(0, 0, Width, Height), color, Color.Black,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
        }

        public void ShowBadge()
        {
            if (!Visible) Visible = true;
            BringOnTop();
        }

        public void BringOnTop()
        {
            // HWND_TOPMOST, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
            Win32.SetWindowPos(Handle, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
        }

        // ---- перетаскивание мышкой ----
        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left)
            {
                dragging = true;
                dragOffset = new Point(Cursor.Position.X - Left, Cursor.Position.Y - Top);
            }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (dragging) Location = new Point(Cursor.Position.X - dragOffset.X, Cursor.Position.Y - dragOffset.Y);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (dragging)
            {
                dragging = false;
                if (PositionChanged != null) PositionChanged(this, EventArgs.Empty);
            }
        }

        // ---- F8: RegisterHotKey + низкоуровневый хук клавиатуры как запасной путь ----
        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            HotkeyRegistered = Win32.RegisterHotKey(Handle, HOTKEY_ID, 0x4000 /*MOD_NOREPEAT*/, VK_F8);
        }

        public void InstallHook()
        {
            hookProc = new Win32.LowLevelKeyboardProc(HookCallback);
            hook = Win32.SetWindowsHookEx(13 /*WH_KEYBOARD_LL*/, hookProc, Win32.GetModuleHandle(null), 0);
            HookInstalled = hook != IntPtr.Zero;
        }

        IntPtr HookCallback(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0)
            {
                int vk = Marshal.ReadInt32(lParam);
                int msg = wParam.ToInt32();
                if (vk == VK_F8)
                {
                    if (msg == 0x0100 || msg == 0x0104)
                    {
                        if (!f8Down) { f8Down = true; Win32.PostMessage(Handle, WM_TOGGLE, IntPtr.Zero, IntPtr.Zero); }
                    }
                    else if (msg == 0x0101 || msg == 0x0105) f8Down = false;
                }
            }
            return Win32.CallNextHookEx(hook, code, wParam, lParam);
        }

        void RequestToggle()
        {
            // хук и горячая клавиша могут сработать на одно нажатие - считаем один раз
            int now = Environment.TickCount;
            if (unchecked(now - lastToggle) < 300) return;
            lastToggle = now;
            if (ToggleRequested != null) ToggleRequested(this, EventArgs.Empty);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_MOUSEACTIVATE) { m.Result = new IntPtr(MA_NOACTIVATE); return; }
            if ((m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HOTKEY_ID) || m.Msg == WM_TOGGLE)
            {
                RequestToggle();
                return;
            }
            base.WndProc(ref m);
        }

        public void Cleanup()
        {
            if (hook != IntPtr.Zero) { Win32.UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
            if (HotkeyRegistered && IsHandleCreated) { Win32.UnregisterHotKey(Handle, HOTKEY_ID); HotkeyRegistered = false; }
        }
    }
}
'@

function Write-ErrLog([string]$msg) {
    try { Add-Content -LiteralPath $ErrLog -Value ("[{0}] {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

# ---------- запуск ----------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# только одна копия
$mutex = New-Object System.Threading.Mutex($false, 'Local\SMITE2PingOverlay')
$owned = $false
try { $owned = $mutex.WaitOne(0, $false) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    [void][System.Windows.Forms.MessageBox]::Show(
        "SMITE 2 Ping уже запущен (значок в трее у часов).`nF8 - показать/скрыть плашку в игре.",
        'SMITE 2 Ping', 'OK', 'Information')
    exit
}

try {
    Add-Type -TypeDefinition $CoreCs -Language CSharp
    Add-Type -TypeDefinition $UiCs -Language CSharp -ReferencedAssemblies System.Windows.Forms, System.Drawing
    [void][Smite2Ping.Win32]::SetProcessDPIAware()

    $ConfigPath = Join-Path $env:APPDATA 'smite2_ping.json'
    $LogCandidates = [string[]]@(
        (Join-Path $env:LOCALAPPDATA 'SMITE2Alpha\Saved\Logs\Hemingway.log'),
        (Join-Path $env:LOCALAPPDATA 'Hemingway\Saved\Logs\Hemingway.log')
    )
    $watcher = New-Object Smite2Ping.LogWatcher (,$LogCandidates)

    $Colors = @{
        White  = [System.Drawing.Color]::White
        Green  = [System.Drawing.ColorTranslator]::FromHtml('#4cff4c')
        Yellow = [System.Drawing.ColorTranslator]::FromHtml('#ffd24c')
        Red    = [System.Drawing.ColorTranslator]::FromHtml('#ff5c5c')
    }
    $ErrText = @{
        'err:nolog'   = 'нет лога игры'
        'err:nomatch' = 'нет матча'
        'err:offline' = 'оффлайн-режим'
    }

    $S = @{
        Enabled = $true; GameFg = $false
        Ip = $null; Miss = 0; Last = $null
        TraceTask = $null; TraceIp = $null
        PingTask = $null; PingIp = $null
    }
    $HopCache = @{}

    function Get-SavedPosition {
        try {
            $d = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            $pt = New-Object System.Drawing.Point ([int]$d.x), ([int]$d.y)
            foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
                if ($scr.Bounds.Contains($pt)) { return $pt }
            }
        } catch {}
        return (New-Object System.Drawing.Point 20, 20)
    }

    function Save-Position([int]$x, [int]$y) {
        try { ('{{"x": {0}, "y": {1}}}' -f $x, $y) | Set-Content -LiteralPath $ConfigPath -Encoding ASCII } catch {}
    }

    $form = New-Object Smite2Ping.OverlayForm
    $form.Location = Get-SavedPosition

    function Set-Badge([string]$text, $color = $Colors.White) { $form.SetBadge($text, $color) }

    function Update-Visibility {
        $want = $S.Enabled -and $S.GameFg
        if ($want -and -not $form.Visible) { $form.ShowBadge() }
        elseif (-not $want -and $form.Visible) { $form.Hide() }
    }

    function Switch-Badge {
        $S.Enabled = -not $S.Enabled
        Update-Visibility
    }

    function Update-Ping {
        # маршрут, найденный в фоне, кладём в кэш
        if ($S.TraceTask -and $S.TraceTask.IsCompleted) {
            $list = New-Object 'System.Collections.Generic.List[string]'
            if ($S.TraceTask.Status -eq 'RanToCompletion') { foreach ($h in $S.TraceTask.Result) { $list.Add($h) } }
            if ($list.Count -eq 0) { $list.Add($S.TraceIp) }
            $HopCache[$S.TraceIp] = $list
            $S.TraceTask = $null
        }
        if (-not $form.Visible) { return }

        $r = $watcher.Poll()
        if ($r.StartsWith('err:')) {
            $S.Ip = $null; $S.Miss = 0; $S.Last = $null
            Set-Badge ('Ping: — ({0})' -f $ErrText[$r])
            return
        }
        $ip = $r.Substring(3)
        if ($ip -ne $S.Ip) { $S.Ip = $ip; $S.Miss = 0; $S.Last = $null }

        if (-not $HopCache.ContainsKey($ip)) {
            if (-not $S.TraceTask) { $S.TraceIp = $ip; $S.TraceTask = [Smite2Ping.NetProbe]::TraceAsync($ip) }
            Set-Badge 'Ping: ищу маршрут…'
            return
        }

        if ($S.PingTask) {
            if (-not $S.PingTask.IsCompleted) { return }
            $res = $null
            if ($S.PingTask.Status -eq 'RanToCompletion') { $res = $S.PingTask.Result }
            $pip = $S.PingIp
            $S.PingTask = $null
            if ($pip -eq $ip) {
                if ($res -and $res.Ms -ge 0) {
                    $hops = $HopCache[$ip]
                    [void]$hops.Remove($res.Hop); $hops.Insert(0, $res.Hop)  # отвечающий узел - первым
                    $S.Miss = 0
                    $ms = [int]$res.Ms
                    $S.Last = $ms
                    $c = if ($ms -lt 60) { $Colors.Green } elseif ($ms -lt 120) { $Colors.Yellow } else { $Colors.Red }
                    Set-Badge ('Ping: {0} ms' -f $ms) $c
                } else {
                    $S.Miss++
                    if (-not ($S.Miss -lt 5 -and $null -ne $S.Last)) { Set-Badge 'Ping: нет ответа' }
                    # единичная потеря: оставляем прошлое значение
                }
            }
        }
        $S.PingIp = $ip
        $S.PingTask = [Smite2Ping.NetProbe]::PingHopsAsync($HopCache[$ip].ToArray())
    }

    # ---------- трей ----------
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.FillEllipse([System.Drawing.Brushes]::Black, 0, 0, 15, 15)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $Colors.Green), 4, 4, 7, 7)
    $g.Dispose()
    $trayIcon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miToggle = $menu.Items.Add('Показать/скрыть (F8)')
    $miReset = $menu.Items.Add('Вернуть плашку в угол')
    [void]$menu.Items.Add('-')
    $miExit = $menu.Items.Add('Выход')

    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = $trayIcon
    $tray.Text = 'SMITE 2 Ping (F8)'
    $tray.ContextMenuStrip = $menu
    $tray.Visible = $true

    $ctx = New-Object System.Windows.Forms.ApplicationContext

    $miToggle.add_Click({ Switch-Badge })
    $miReset.add_Click({ $form.Location = New-Object System.Drawing.Point 20, 20; Save-Position 20 20 })
    $miExit.add_Click({ $ctx.ExitThread() })
    $tray.add_DoubleClick({ Switch-Badge })

    $form.add_ToggleRequested({ Switch-Badge })
    $form.add_PositionChanged({ Save-Position $form.Left $form.Top })

    $null = $form.Handle      # создаём окно (регистрирует F8), но пока не показываем
    $form.InstallHook()
    if (-not $form.HotkeyRegistered -and -not $form.HookInstalled) {
        $tray.ShowBalloonTip(5000, 'SMITE 2 Ping', 'Не удалось занять клавишу F8. Используйте меню значка в трее.', 'Warning')
    } else {
        $tray.ShowBalloonTip(3000, 'SMITE 2 Ping', 'Работает в фоне. F8 - показать/скрыть плашку в игре.', 'Info')
    }

    $focusTimer = New-Object System.Windows.Forms.Timer
    $focusTimer.Interval = 300
    $focusTimer.add_Tick({
        try {
            $st = [Smite2Ping.FocusCheck]::GameState($form.Handle)
            if ($st -ge 0) {
                $wasGame = $S.GameFg
                $S.GameFg = ($st -eq 1)
                if ($S.GameFg -and -not $wasGame -and $form.Visible) { $form.BringOnTop() }
            }
            Update-Visibility
        } catch { Write-ErrLog $_ }
    })

    $pingTimer = New-Object System.Windows.Forms.Timer
    $pingTimer.Interval = 2000
    $pingTimer.add_Tick({
        try {
            Update-Ping
            # в игре — раз в 2 с, иначе сон ~5 с (меньше просыпаний таймера)
            $want = if ($S.Enabled -and $S.GameFg) { 2000 } else { 5000 }
            if ($pingTimer.Interval -ne $want) { $pingTimer.Interval = $want }
        } catch { Write-ErrLog $_ }
    })

    $focusTimer.Start()
    $pingTimer.Start()
    [System.Windows.Forms.Application]::Run($ctx)
}
catch {
    Write-ErrLog ($_ | Out-String)
    [void][System.Windows.Forms.MessageBox]::Show("Ошибка SMITE 2 Ping:`n$($_.Exception.Message)`n`nПодробности: $ErrLog",
        'SMITE 2 Ping', 'OK', 'Error')
}
finally {
    if ($focusTimer) { $focusTimer.Stop() }
    if ($pingTimer) { $pingTimer.Stop() }
    if ($form) { $form.Cleanup(); $form.Dispose() }
    if ($tray) { $tray.Visible = $false; $tray.Dispose() }
    if ($owned) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
}
