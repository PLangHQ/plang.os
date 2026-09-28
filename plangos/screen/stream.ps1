<#
.SYNOPSIS
  Proof: a live stream of Chromium frames from PlangOS drawn on the screen.

.DESCRIPTION
  Starts headless Chromium inside PlangOS with an animated page and a DevTools port bound to
  localhost, connects from Windows (WSL forwards localhost), starts Page.startScreencast and
  shows the frames in a borderless top-most window at 1:1 pixels on the primary monitor.

  Receiving is separate from painting: a background thread receives each frame and acks it at
  once (Chromium sends the next frame only after the ack); the window paints the newest frame.
  Two rates are reported: frames RECEIVED per second (Chromium + the pipe) and frames PAINTED
  per second (this side). The work is a small C# class compiled here by Add-Type.

  It runs `wsl --terminate PlangOS` before and after, which stops everything inside PlangOS.

  PROOF ONLY: a DevTools port gives full control of that browser to anything on this machine
  that connects to it. The real path is Chromium drawing into plang-screen (a compositor).

    .\stream.ps1                 15 seconds, JPEG frames at 1920 wide
    .\stream.ps1 -Seconds 30 -Format png -Quality 80 -Width 1280 -Port 9222

  Windows PowerShell 5.1 compatible. No install. Needs the PlangOS distro imported (..\start.ps1).
#>
[CmdletBinding()]
param(
    [int]$Seconds = 15,
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
        string latest;             // newest frame, base64; painted frames skip older ones
        Image image;
        DateTime first, end;
        public int Received, Painted;
        public long Bytes;
        public string Error;
        public double Elapsed { get { return first == default(DateTime) ? 0 : (DateTime.UtcNow - first).TotalSeconds; } }

        public StreamWindow(Rectangle bounds, int seconds)
        {
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            Bounds = bounds;
            TopMost = true;
            ShowInTaskbar = false;
            BackColor = Color.Black;
            DoubleBuffered = true;
            end = DateTime.UtcNow.AddSeconds(seconds);
            timer.Interval = 5;
            timer.Tick += delegate { Tick(); };
        }

        public void Connect(string url, string animation, string format, int quality, int w, int h)
        {
            ws.ConnectAsync(new Uri(url), CancellationToken.None).Wait();
            Send("Page.enable", "{}");
            Send("Runtime.evaluate", "{\"expression\":\"" + animation + "\"}");
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
            lock (ws) ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None).Wait();
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
            var elapsed = Elapsed;
            var text = string.Format("PlangOS stream  received {0:N1} fps  painted {1:N1} fps  {2:N2} MB/s",
                elapsed > 0 ? Received / elapsed : 0, elapsed > 0 ? Painted / elapsed : 0, elapsed > 0 ? Bytes / 1048576.0 / elapsed : 0);
            e.Graphics.FillRectangle(Brushes.Black, 10, 10, 620, 30);
            using (var font = new Font("Segoe UI", 13, FontStyle.Bold))
                e.Graphics.DrawString(text, font, Brushes.White, 16, 14);
        }

        public void Stop()
        {
            try { Send("Browser.close", "{}"); } catch { }
        }
    }
}
'@

[PlangOS.StreamWindow]::DpiAware()
$primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$w = [Math]::Min($primary.Width, $Width)
$h = [int]($w * $primary.Height / $primary.Width)

# --- the page, and its animation ----------------------------------------------------
$page = @"
<html><body style='margin:0;background:%23102030;color:white;font-family:sans-serif;overflow:hidden'>
<div style='position:absolute;left:40px;top:50px;font-size:42px'>Live from Chromium inside PlangOS</div>
<div id=clock style='position:absolute;left:40px;top:120px;font-size:64px'></div>
<div id=box style='position:absolute;top:240px;width:160px;height:160px;border-radius:20px;background:linear-gradient(135deg,%23ff5a36,%23ffd23f)'></div>
<div style='position:absolute;left:0;right:0;bottom:0;height:30px;background:linear-gradient(90deg,red,orange,yellow,lime,cyan,blue,violet)'></div>
</body></html>
"@ -replace "`r?`n", ''
# Headless Chromium doesn't run the inline script of a data: page opened from the command line,
# so the animation is sent over DevTools once connected (single quotes only: it goes into JSON).
$animation = "let t0=performance.now();function f(t){const x=(t-t0)/4%(innerWidth-160);box.style.left=x+'px';" +
    "box.style.transform='rotate('+(t/10%360)+'deg)';" +
    "clock.textContent=new Date().toLocaleTimeString()+'.'+String(Math.floor(t%1000)).padStart(3,'0')}" +
    "setInterval(()=>f(performance.now()),16);"

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
    throw "DevTools didn't answer on http://127.0.0.1:$Port. Is WSL localhost forwarding on (.wslconfig localhostForwarding)?"
}
Write-Host "Connected to $($target.webSocketDebuggerUrl)"

# --- stream: 1:1 pixels, centred on the primary monitor ------------------------------
$bounds = New-Object System.Drawing.Rectangle ($primary.X + [int](($primary.Width - $w) / 2)), ($primary.Y + [int](($primary.Height - $h) / 2)), $w, $h
$stream = New-Object PlangOS.StreamWindow $bounds, $Seconds
try { $stream.Connect($target.webSocketDebuggerUrl, $animation, $Format, $Quality, $w, $h) }
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
if ($stream.Error) { Write-Host "Receive stopped: $($stream.Error)" -ForegroundColor Yellow }
Write-Host ("Done: {0:N1} s, received {1} frames = {2:N1} fps, painted {3} = {4:N1} fps, {5:N1} MB = {6:N2} MB/s ({7}, {8}x{9})" -f `
    $e, $stream.Received, $(if ($e) { $stream.Received / $e } else { 0 }), $stream.Painted, $(if ($e) { $stream.Painted / $e } else { 0 }),
    ($stream.Bytes / 1MB), $(if ($e) { $stream.Bytes / 1MB / $e } else { 0 }), $Format, $w, $h)
