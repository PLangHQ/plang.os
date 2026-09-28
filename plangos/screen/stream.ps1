<#
.SYNOPSIS
  Proof: Chromium inside PlangOS, live on the Windows screen, with mouse and keyboard.

.DESCRIPTION
  Starts headless Chromium inside PlangOS with a test page and a DevTools port bound to
  localhost, connects from Windows (WSL forwards localhost), streams the page with
  Page.startScreencast into a window at 1:1 pixels, and sends your mouse and keyboard back
  with Input.dispatchMouseEvent / dispatchKeyEvent / insertText.

  Receiving is separate from painting: a background thread receives each frame and acks it at
  once (Chromium sends the next frame only after the ack); the window paints the newest frame.
  The title bar shows frames RECEIVED per second (Chromium + the pipe) and PAINTED per second.
  The work is a small C# class compiled here by Add-Type.

  The window stays until you close it (X or Alt+F4), unless -Seconds is given.
  It runs `wsl --terminate PlangOS` before and after, which stops everything inside PlangOS.

  PROOF ONLY: a DevTools port gives full control of that browser to anything on this machine
  that connects to it. The real path is Chromium drawing into plang-screen (a compositor).

    .\stream.ps1                          until closed, JPEG frames at 1920 wide
    .\stream.ps1 -Seconds 15 -Format png -Quality 80 -Width 1280 -Port 9222

  Windows PowerShell 5.1 compatible. No install. Needs the PlangOS distro imported (..\start.ps1).
#>
[CmdletBinding()]
param(
    [int]$Seconds = 0,
    [ValidateSet('jpeg', 'png')] [string]$Format = 'jpeg',
    [int]$Quality = 80,
    [int]$Width = 1920,
    [int]$Port = 9222,
    [string]$Distro = 'PlangOS'
)
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.IO;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

namespace PlangOS
{
    // C# 5 only: Windows PowerShell 5.1 compiles with the .NET Framework compiler.
    public class StreamWindow : Form
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        public static void DpiAware() { SetProcessDPIAware(); }

        static readonly Regex DataRx = new Regex("\"data\":\"([^\"]+)\"", RegexOptions.Compiled);
        static readonly Regex SessionRx = new Regex("\"sessionId\":(\\d+)", RegexOptions.Compiled);

        readonly ClientWebSocket ws = new ClientWebSocket();
        readonly object gate = new object();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        int msgId;
        string latest;             // newest frame, base64; painting skips older ones
        Image image;
        DateTime first, end, lastMove, lastTitle;
        public int Received, Painted;
        public long Bytes;
        public string Error;
        public double Elapsed { get { return first == default(DateTime) ? 0 : (DateTime.UtcNow - first).TotalSeconds; } }

        public StreamWindow(Rectangle bounds, int seconds)
        {
            Text = "PlangOS - Chromium";
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.Manual;
            ClientSize = bounds.Size;
            Location = new Point(bounds.X, bounds.Y);
            BackColor = Color.Black;
            DoubleBuffered = true;
            KeyPreview = true;
            end = seconds > 0 ? DateTime.UtcNow.AddSeconds(seconds) : DateTime.MaxValue;
            timer.Interval = 5;
            timer.Tick += delegate { Tick(); };
        }

        public void Connect(string url, string script, string format, int quality, int w, int h)
        {
            ws.ConnectAsync(new Uri(url), CancellationToken.None).Wait();
            Send("Page.enable", "{}");
            Send("Runtime.evaluate", "{\"expression\":\"" + script + "\"}");
            Send("Page.startScreencast", "{\"format\":\"" + format + "\",\"quality\":" + quality +
                 ",\"maxWidth\":" + w + ",\"maxHeight\":" + h + ",\"everyNthFrame\":1}");
            var t = new Thread(ReceiveLoop);
            t.IsBackground = true;
            t.Start();
            timer.Start();
        }

        void Send(string method, string parameters)
        {
            var json = "{\"id\":" + Interlocked.Increment(ref msgId) + ",\"method\":\"" + method + "\",\"params\":" + parameters + "}";
            var bytes = Encoding.UTF8.GetBytes(json);
            try { lock (ws) ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None).Wait(); }
            catch (Exception e) { Error = e.GetBaseException().Message; }
        }

        void ReceiveLoop()
        {
            var buffer = new byte[1 << 20];
            var message = new MemoryStream();
            try
            {
                while (ws.State == WebSocketState.Open)
                {
                    var r = ws.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None).Result;
                    message.Write(buffer, 0, r.Count);
                    if (!r.EndOfMessage) continue;
                    var text = Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length);
                    message.SetLength(0);
                    if (!text.StartsWith("{\"method\":\"Page.screencastFrame\"")) continue;
                    var session = SessionRx.Match(text).Groups[1].Value;
                    Send("Page.screencastFrameAck", "{\"sessionId\":" + session + "}");   // ack first
                    var data = DataRx.Match(text).Groups[1].Value;
                    lock (gate)
                    {
                        if (first == default(DateTime)) first = DateTime.UtcNow;
                        latest = data;
                        Received++;
                        Bytes += data.Length * 3 / 4;
                    }
                }
            }
            catch (Exception e) { Error = e.GetBaseException().Message; }
        }

        void Tick()
        {
            if (DateTime.UtcNow >= end) { Close(); return; }
            if ((DateTime.UtcNow - lastTitle).TotalMilliseconds > 500)
            {
                lastTitle = DateTime.UtcNow;
                var s = Elapsed;
                Text = string.Format("PlangOS - Chromium   received {0:N1} fps   painted {1:N1} fps   {2:N2} MB/s",
                    s > 0 ? Received / s : 0, s > 0 ? Painted / s : 0, s > 0 ? Bytes / 1048576.0 / s : 0);
            }
            string data;
            lock (gate) { data = latest; latest = null; }
            if (data == null) return;
            var old = image;
            image = Image.FromStream(new MemoryStream(Convert.FromBase64String(data)));
            if (old != null) old.Dispose();
            Painted++;
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (image != null) e.Graphics.DrawImageUnscaled(image, 0, 0);
        }

        // ---- input: window pixels are page pixels (the frame is shown 1:1) --------------

        static int Modifiers()
        {
            var m = Control.ModifierKeys; int bits = 0;
            if ((m & Keys.Alt) != 0) bits |= 1;
            if ((m & Keys.Control) != 0) bits |= 2;
            if ((m & Keys.Shift) != 0) bits |= 8;
            return bits;
        }

        static string ButtonName(MouseButtons b)
        {
            if ((b & MouseButtons.Left) != 0) return "left";
            if ((b & MouseButtons.Right) != 0) return "right";
            if ((b & MouseButtons.Middle) != 0) return "middle";
            return "none";
        }

        void Mouse(string type, MouseEventArgs e, string button, int clicks)
        {
            Send("Input.dispatchMouseEvent", "{\"type\":\"" + type + "\",\"x\":" + e.X + ",\"y\":" + e.Y +
                 ",\"button\":\"" + button + "\",\"clickCount\":" + clicks + ",\"modifiers\":" + Modifiers() + "}");
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            // moves are many: send at most one per 8 ms, except while dragging
            if (e.Button == MouseButtons.None && (DateTime.UtcNow - lastMove).TotalMilliseconds < 8) return;
            lastMove = DateTime.UtcNow;
            Mouse("mouseMoved", e, ButtonName(e.Button), 0);
        }
        protected override void OnMouseDown(MouseEventArgs e) { Mouse("mousePressed", e, ButtonName(e.Button), e.Clicks); }
        protected override void OnMouseUp(MouseEventArgs e) { Mouse("mouseReleased", e, ButtonName(e.Button), e.Clicks); }
        protected override void OnMouseWheel(MouseEventArgs e)
        {
            Send("Input.dispatchMouseEvent", "{\"type\":\"mouseWheel\",\"x\":" + e.X + ",\"y\":" + e.Y +
                 ",\"deltaX\":0,\"deltaY\":" + (-e.Delta) + ",\"modifiers\":" + Modifiers() + "}");
        }

        // every key is ours: no dialog navigation (Tab, arrows) in this window
        protected override bool IsInputKey(Keys keyData) { return true; }
        protected override bool ProcessDialogKey(Keys keyData) { return false; }

        static string KeyName(Keys k)
        {
            switch (k)
            {
                case Keys.Enter: return "Enter";      case Keys.Back: return "Backspace";
                case Keys.Tab: return "Tab";          case Keys.Delete: return "Delete";
                case Keys.Escape: return "Escape";    case Keys.Home: return "Home";
                case Keys.End: return "End";          case Keys.PageUp: return "PageUp";
                case Keys.PageDown: return "PageDown";
                case Keys.Left: return "ArrowLeft";   case Keys.Right: return "ArrowRight";
                case Keys.Up: return "ArrowUp";       case Keys.Down: return "ArrowDown";
            }
            return null;
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            var name = KeyName(e.KeyCode);
            var ctrlLetter = e.Control && !e.Alt && e.KeyCode >= Keys.A && e.KeyCode <= Keys.Z;
            if (name == null && !ctrlLetter) return;              // ordinary characters come as KeyPress
            if (ctrlLetter) name = ((char)('a' + (e.KeyCode - Keys.A))).ToString();
            var vk = (int)e.KeyCode;
            // Enter needs its text to act (submit, new line); the rest are raw keys
            var down = e.KeyCode == Keys.Enter
                ? "{\"type\":\"keyDown\",\"key\":\"Enter\",\"code\":\"Enter\",\"text\":\"\\r\",\"windowsVirtualKeyCode\":13,\"modifiers\":" + Modifiers() + "}"
                : "{\"type\":\"rawKeyDown\",\"key\":\"" + name + "\",\"windowsVirtualKeyCode\":" + vk + ",\"modifiers\":" + Modifiers() + "}";
            Send("Input.dispatchKeyEvent", down);
            Send("Input.dispatchKeyEvent", "{\"type\":\"keyUp\",\"key\":\"" + name + "\",\"windowsVirtualKeyCode\":" + vk + ",\"modifiers\":" + Modifiers() + "}");
            e.Handled = true;
            e.SuppressKeyPress = true;
        }

        protected override void OnKeyPress(KeyPressEventArgs e)
        {
            if (e.KeyChar < ' ') return;                         // control characters went as keys
            Send("Input.insertText", "{\"text\":\"\\u" + ((int)e.KeyChar).ToString("x4") + "\"}");
            e.Handled = true;
        }

        public void Stop()
        {
            Send("Browser.close", "{}");
        }
    }
}
'@

[PlangOS.StreamWindow]::DpiAware()
$primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$w = [Math]::Min($primary.Width - 40, $Width)
$h = [int]($w * $primary.Height / $primary.Width)

# --- the page ------------------------------------------------------------------------
$page = @"
<html><body style='margin:0;background:%23102030;color:white;font-family:sans-serif;font-size:26px;overflow:hidden'>
<div style='position:absolute;left:40px;top:24px;font-size:40px'>Chromium inside PlangOS &mdash; click, type, press</div>
<div id=clock style='position:absolute;right:40px;top:30px;font-size:34px;color:%2388ccff'></div>
<div style='position:absolute;left:40px;top:110px'>
 Your name: <input id=nm style='font-size:26px;padding:8px;width:340px' placeholder='type here'>
 <button id=hello style='font-size:26px;padding:8px 22px;margin-left:12px'>Say hello</button>
 <div id=out style='margin-top:16px;font-size:34px;color:%23ffd23f'>&nbsp;</div>
 <textarea id=notes style='margin-top:18px;font-size:22px;width:640px;height:170px' placeholder='Notes: Enter, Backspace, arrows, Ctrl+A work'></textarea><br>
 <label style='display:inline-block;margin-top:16px'><input type=checkbox id=chk style='width:26px;height:26px'> Check me</label>
 <span id=chkout style='margin-left:16px;color:%2388ccff'>not checked</span>
</div>
<div id=clk style='position:absolute;right:40px;top:110px;font-size:26px;color:%2388ccff'>clicks on the page: 0</div>
<div id=box style='position:absolute;bottom:60px;width:90px;height:90px;border-radius:14px;background:linear-gradient(135deg,%23ff5a36,%23ffd23f)'></div>
<div style='position:absolute;left:0;right:0;bottom:0;height:30px;background:linear-gradient(90deg,red,orange,yellow,lime,cyan,blue,violet)'></div>
</body></html>
"@ -replace "`r?`n", ''
# Headless Chromium doesn't run a command-line data: page's own scripts, so behaviour is sent
# over DevTools once connected. Single quotes only: it goes into a JSON string.
$script = "let t0=performance.now(),clicks=0,hellos=0;" +
    "function f(t){const x=(t-t0)/4%(innerWidth-90);box.style.left=x+'px';box.style.transform='rotate('+(t/10%360)+'deg)';" +
    "clock.textContent=new Date().toLocaleTimeString()+'.'+String(Math.floor(t%1000)).padStart(3,'0')}" +
    "setInterval(()=>f(performance.now()),16);" +
    "hello.onclick=function(){hellos++;out.textContent='Hello, '+(nm.value||'nobody')+'! ('+hellos+')'};" +
    "nm.onkeydown=function(e){if(e.key==='Enter')hello.click()};" +
    "chk.onchange=function(){chkout.textContent=chk.checked?'checked':'not checked'};" +
    "document.addEventListener('mousedown',function(){clicks++;clk.textContent='clicks on the page: '+clicks});"

# --- start Chromium in PlangOS -------------------------------------------------------
# Stopping wsl.exe on Windows doesn't stop the Linux process behind it, so a Chromium from an
# earlier run can still hold the port and the profile. Start from a clean distro.
Write-Host "Stopping anything still running in $Distro (wsl --terminate)..."
wsl.exe --terminate $Distro | Out-Null
Write-Host "Starting Chromium in $Distro (${w}x${h}, DevTools on localhost:$Port)..."
$chromeArgs = "-d $Distro --exec /usr/lib/chromium/chromium --headless --disable-gpu " +
    "--user-data-dir=/home/plang/.chromium-stream --hide-scrollbars --window-size=$w,$h " +
    "--remote-debugging-address=127.0.0.1 --remote-debugging-port=$Port --remote-allow-origins=* `"data:text/html,$page`""
$chrome = Start-Process wsl.exe -ArgumentList $chromeArgs -WindowStyle Hidden -PassThru

$target = $null
for ($i = 0; $i -lt 60 -and -not $target; $i++) {
    Start-Sleep -Milliseconds 250
    try {
        # PS 5.1 passes a JSON array down the pipeline as ONE object: enumerate it explicitly
        $pages = @(Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 2)
        $target = @($pages | ForEach-Object { $_ } | Where-Object { $_.type -eq 'page' })[0]
    } catch { }
}
if (-not $target) {
    $chrome | Stop-Process -ErrorAction SilentlyContinue
    wsl.exe --terminate $Distro | Out-Null
    throw "DevTools didn't answer on http://127.0.0.1:$Port. Is WSL localhost forwarding on (.wslconfig localhostForwarding)?"
}
Write-Host "Connected to $($target.webSocketDebuggerUrl). Close the window to stop."

# --- the window: 1:1 pixels, centred on the primary monitor --------------------------
$bounds = New-Object System.Drawing.Rectangle ($primary.X + [int](($primary.Width - $w) / 2)), ($primary.Y + [int](($primary.Height - $h) / 2)), $w, $h
$stream = New-Object PlangOS.StreamWindow $bounds, $Seconds
try { $stream.Connect($target.webSocketDebuggerUrl, $script, $Format, $Quality, $w, $h) }
catch {
    wsl.exe --terminate $Distro | Out-Null
    throw "Could not connect to $($target.webSocketDebuggerUrl): $($_.Exception.GetBaseException().Message)"
}
[System.Windows.Forms.Application]::Run($stream)

$stream.Stop()
Start-Sleep -Milliseconds 500
$chrome | Stop-Process -ErrorAction SilentlyContinue
wsl.exe --terminate $Distro | Out-Null   # make sure Chromium is gone inside PlangOS too
$e = $stream.Elapsed
Write-Host ("Done: {0:N1} s, received {1} frames = {2:N1} fps, painted {3} = {4:N1} fps, {5:N1} MB = {6:N2} MB/s ({7}, {8}x{9})" -f `
    $e, $stream.Received, $(if ($e) { $stream.Received / $e } else { 0 }), $stream.Painted, $(if ($e) { $stream.Painted / $e } else { 0 }),
    ($stream.Bytes / 1MB), $(if ($e) { $stream.Bytes / 1MB / $e } else { 0 }), $Format, $w, $h)
