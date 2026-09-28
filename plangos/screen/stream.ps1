<#
.SYNOPSIS
  Proof: a live stream of Chromium frames from PlangOS drawn on the screen.

.DESCRIPTION
  Starts headless Chromium inside PlangOS with an animated page and a DevTools port bound to
  localhost, connects from Windows (WSL forwards localhost), starts Page.startScreencast and
  draws every frame on the primary monitor through a top-most, click-through overlay.
  Reports frames per second and MB/s at the end.

  PROOF ONLY: a DevTools port gives full control of that browser to anything on this machine
  that connects to it. The real path is Chromium drawing into plang-screen (a compositor).

    .\stream.ps1                 15 seconds, JPEG frames
    .\stream.ps1 -Seconds 30 -Format png -Quality 80 -Port 9222

  Windows PowerShell 5.1 compatible. No install. Needs the PlangOS distro imported (..\start.ps1).
#>
[CmdletBinding()]
param(
    [int]$Seconds = 15,
    [ValidateSet('jpeg', 'png')] [string]$Format = 'jpeg',
    [int]$Quality = 80,
    [int]$Port = 9222,
    [string]$Distro = 'PlangOS'
)
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace PlangOS -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
'@
[PlangOS.Win32]::SetProcessDPIAware() | Out-Null

$primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$width  = [Math]::Min($primary.Width, 1920)     # a sane frame size; the overlay scales it up
$height = [int]($width * $primary.Height / $primary.Width)

# --- the page: something that moves, so frames keep coming -------------------------
$page = @"
<html><body style='margin:0;background:%23102030;color:white;font-family:sans-serif;overflow:hidden'>
<div style='position:absolute;left:40px;top:30px;font-size:42px'>Live from Chromium inside PlangOS</div>
<div id=clock style='position:absolute;left:40px;top:100px;font-size:64px'></div>
<div id=box style='position:absolute;top:220px;width:160px;height:160px;border-radius:20px;background:linear-gradient(135deg,%23ff5a36,%23ffd23f)'></div>
<div style='position:absolute;left:0;right:0;bottom:0;height:30px;background:linear-gradient(90deg,red,orange,yellow,lime,cyan,blue,violet)'></div>
</body></html>
"@ -replace "`r?`n", ''
$url = "data:text/html,$page"
# Headless Chromium doesn't run the inline script of a data: page opened from the command line,
# so the animation is sent over DevTools once connected (single quotes only: it goes into JSON).
$animation = "let t0=performance.now();function f(t){const x=(t-t0)/4%(innerWidth-160);box.style.left=x+'px';" +
    "box.style.transform='rotate('+(t/10%360)+'deg)';" +
    "clock.textContent=new Date().toLocaleTimeString()+'.'+String(Math.floor(t%1000)).padStart(3,'0')}" +
    "setInterval(()=>f(performance.now()),16);"

# --- start Chromium in PlangOS -------------------------------------------------------
Write-Host "Starting Chromium in $Distro (${width}x${height}, DevTools on localhost:$Port)..."
$chromeArgs = "-d $Distro --exec /usr/lib/chromium/chromium --headless --disable-gpu " +
    "--user-data-dir=/home/plang/.chromium-stream --hide-scrollbars --window-size=$width,$height " +
    "--remote-debugging-address=127.0.0.1 --remote-debugging-port=$Port --remote-allow-origins=* `"$url`""
$chrome = Start-Process wsl.exe -ArgumentList $chromeArgs -WindowStyle Hidden -PassThru

# wait for DevTools, then find the page's WebSocket
$target = $null
for ($i = 0; $i -lt 60 -and -not $target; $i++) {
    Start-Sleep -Milliseconds 250
    try {
        $list = Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 2
        $target = $list | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
    } catch { }
}
if (-not $target) {
    $chrome | Stop-Process -ErrorAction SilentlyContinue
    throw "DevTools didn't answer on http://127.0.0.1:$Port. Is WSL localhost forwarding on (.wslconfig localhostForwarding)?"
}
Write-Host "Connected to $($target.webSocketDebuggerUrl)"

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
$ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()

$script:msgId = 0
function Send-Cdp([string]$method, [string]$params = '{}') {
    $script:msgId++
    $json = "{`"id`":$($script:msgId),`"method`":`"$method`",`"params`":$params}"
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object ArraySegment[byte] -ArgumentList (, $bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}

Send-Cdp 'Page.enable'
Send-Cdp 'Runtime.evaluate' "{`"expression`":`"$animation`"}"
Send-Cdp 'Page.startScreencast' "{`"format`":`"$Format`",`"quality`":$Quality,`"maxWidth`":$width,`"maxHeight`":$height,`"everyNthFrame`":1}"

# --- receiving: polled from the UI timer, one message at a time ----------------------
$recvBuffer = New-Object byte[] (1024 * 1024)
$message = New-Object System.IO.MemoryStream
$state = @{ Frames = 0; Bytes = 0L; Start = $null; Image = $null; Fps = 0.0; Task = $null; LastFrame = $null }

function Start-Receive {
    $seg = New-Object ArraySegment[byte] -ArgumentList (, $recvBuffer)
    $state.Task = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None)
}

function Read-Messages {
    # drain everything that has arrived; never block the UI
    while ($state.Task -and $state.Task.IsCompleted) {
        $r = $state.Task.Result
        $message.Write($recvBuffer, 0, $r.Count)
        if ($r.EndOfMessage) {
            $text = [Text.Encoding]::UTF8.GetString($message.ToArray())
            $message.SetLength(0)
            if ($text.StartsWith('{"method":"Page.screencastFrame"')) {
                $data = [regex]::Match($text, '"data":"([^"]+)"').Groups[1].Value
                $session = [regex]::Match($text, '"sessionId":(\d+)').Groups[1].Value
                Send-Cdp 'Page.screencastFrameAck' "{`"sessionId`":$session}"   # ask for the next one
                $raw = [Convert]::FromBase64String($data)
                $old = $state.Image
                $state.Image = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream (, $raw)))
                if ($old) { $old.Dispose() }
                if (-not $state.Start) { $state.Start = [DateTime]::UtcNow }
                $state.Frames++
                $state.Bytes += $raw.Length
                $elapsed = ([DateTime]::UtcNow - $state.Start).TotalSeconds
                if ($elapsed -gt 0) { $state.Fps = $state.Frames / $elapsed }
            }
        }
        if ($ws.State -eq 'Open') { Start-Receive } else { $state.Task = $null }
    }
}

# --- the overlay ---------------------------------------------------------------------
$screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'; $form.StartPosition = 'Manual'; $form.Bounds = $primary
$form.TopMost = $true; $form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::Magenta; $form.TransparencyKey = [System.Drawing.Color]::Magenta
$form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($form, $true, $null)
$form.Add_Shown({
    $style = [PlangOS.Win32]::GetWindowLong($form.Handle, -20)
    [PlangOS.Win32]::SetWindowLong($form.Handle, -20, $style -bor 0x80000 -bor 0x20 -bor 0x80) | Out-Null
})
$form.Add_Paint({
    param($source, $e)
    $g = $e.Graphics
    if ($state.Image) {
        # the frame, as large as fits the primary monitor, centred
        $scale = [Math]::Min($form.ClientSize.Width / $state.Image.Width, $form.ClientSize.Height / $state.Image.Height) * 0.9
        $w = [int]($state.Image.Width * $scale); $h = [int]($state.Image.Height * $scale)
        $g.DrawImage($state.Image, [int](($form.ClientSize.Width - $w) / 2), [int](($form.ClientSize.Height - $h) / 2), $w, $h)
    }
    $font = New-Object System.Drawing.Font 'Segoe UI', 16, ([System.Drawing.FontStyle]::Bold)
    $mbps = if ($state.Start) { $state.Bytes / 1MB / ([DateTime]::UtcNow - $state.Start).TotalSeconds } else { 0 }
    $text = "PlangOS stream  {0} frames  {1:N1} fps  {2:N2} MB/s  ({3})" -f $state.Frames, $state.Fps, $mbps, $Format
    $g.FillRectangle([System.Drawing.Brushes]::Black, 20, 20, 700, 36)
    $g.DrawString($text, $font, [System.Drawing.Brushes]::White, 26, 24); $font.Dispose()
})

$began = [DateTime]::UtcNow
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 10
$timer.Add_Tick({
    Read-Messages
    if (([DateTime]::UtcNow - $began).TotalSeconds -ge $Seconds -or -not $state.Task) { $form.Close() }
    $form.Invalidate()
})

Start-Receive
$timer.Start()
[System.Windows.Forms.Application]::Run($form)

# --- stop ----------------------------------------------------------------------------
$timer.Dispose()
try { Send-Cdp 'Browser.close' } catch { }
Start-Sleep -Milliseconds 500
$chrome | Stop-Process -ErrorAction SilentlyContinue
$elapsed = if ($state.Start) { ([DateTime]::UtcNow - $state.Start).TotalSeconds } else { 0 }
Write-Host ("Done: {0} frames in {1:N1} s = {2:N1} fps, {3:N1} MB total, {4:N2} MB/s ({5}, {6}x{7})" -f `
    $state.Frames, $elapsed, $state.Fps, ($state.Bytes / 1MB),
    $(if ($elapsed -gt 0) { $state.Bytes / 1MB / $elapsed } else { 0 }), $Format, $width, $height)
