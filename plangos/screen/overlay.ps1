<#
.SYNOPSIS
  Proof: draw pixels on the whole screen (every monitor), over all other windows.

.DESCRIPTION
  A borderless, top-most, click-through window covering the virtual screen (all monitors).
  Magenta is the transparent colour, so only what is drawn shows; clicks pass through to the
  windows underneath. On Windows the compositor (DWM) owns the display driver, so a layered
  top-most window is how anything draws "anywhere on the screen"; writing to the driver itself
  is the bare-metal stage (DRM).

    .\overlay.ps1                    test pattern: border, colour bars, moving square, fps
    .\overlay.ps1 -FromPlangOS       Chromium inside PlangOS renders a page to PNG; draw it here
    .\overlay.ps1 -Seconds 30        stay longer (default 15). Ctrl+C in this console also stops it.

  Windows PowerShell 5.1 compatible. No install.
#>
[CmdletBinding()]
param(
    [int]$Seconds = 15,
    [switch]$FromPlangOS,
    [string]$Distro = 'PlangOS'
)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace PlangOS -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
'@
# Real pixels, not DPI-scaled ones: one drawn pixel = one screen pixel.
[PlangOS.Win32]::SetProcessDPIAware() | Out-Null

$screen = [System.Windows.Forms.SystemInformation]::VirtualScreen   # all monitors
Write-Host ("Virtual screen: {0}x{1} at ({2},{3}), {4} monitor(s)" -f `
    $screen.Width, $screen.Height, $screen.X, $screen.Y, [System.Windows.Forms.Screen]::AllScreens.Count)

# --- optional: pixels from PlangOS --------------------------------------------------
$image = $null
if ($FromPlangOS) {
    $env:WSL_UTF8 = '1'
    $primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $html = "data:text/html,<body style='margin:0;background:magenta;font-family:sans-serif'>" +
            "<div style='position:absolute;left:40px;top:40px;padding:24px 32px;background:%23102040;color:white;font-size:40px;border-radius:12px'>" +
            "Rendered by Chromium inside PlangOS</div>" +
            "<div style='position:absolute;left:40px;top:160px;width:600px;height:40px;background:linear-gradient(90deg,red,orange,yellow,lime,cyan,blue,violet)'></div>" +
            "</body>"
    Write-Host "Rendering a page with Chromium inside $Distro ($($primary.Width)x$($primary.Height))..."
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $ErrorActionPreference = 'Continue'   # Chromium writes dbus warnings to stderr
    & wsl.exe -d $Distro --exec /usr/lib/chromium/chromium --headless --disable-gpu `
        --user-data-dir=/home/plang/.chromium --hide-scrollbars `
        "--window-size=$($primary.Width),$($primary.Height)" `
        --screenshot=/home/plang/screen.png $html 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    $png = "\\wsl.localhost\$Distro\home\plang\screen.png"
    if (-not (Test-Path $png)) { throw "Chromium did not write $png" }
    $image = [System.Drawing.Image]::FromStream([IO.MemoryStream]::new([IO.File]::ReadAllBytes($png)))
    Write-Host ("Got {0}x{1} pixels from PlangOS in {2:N1} s" -f $image.Width, $image.Height, $watch.Elapsed.TotalSeconds)
}

# --- the overlay window --------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition   = 'Manual'
$form.Bounds          = $screen
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.BackColor       = [System.Drawing.Color]::Magenta
$form.TransparencyKey = [System.Drawing.Color]::Magenta         # magenta pixels = see-through
$form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($form, $true, $null)

$state = @{ X = 0; Frames = 0; Start = [DateTime]::UtcNow; Fps = 0.0 }

$form.Add_Shown({
    # click-through + no alt-tab entry: WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW
    $GWL_EXSTYLE = -20
    $style = [PlangOS.Win32]::GetWindowLong($form.Handle, $GWL_EXSTYLE)
    [PlangOS.Win32]::SetWindowLong($form.Handle, $GWL_EXSTYLE, $style -bor 0x80000 -bor 0x20 -bor 0x80) | Out-Null
})

$form.Add_Paint({
    param($source, $e)
    $g = $e.Graphics
    $w = $form.ClientSize.Width; $h = $form.ClientSize.Height

    if ($image) {
        # PlangOS pixels on the primary monitor (virtual-screen coordinates can be negative)
        $p = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $g.DrawImage($image, $p.X - $screen.X, $p.Y - $screen.Y, $image.Width, $image.Height)
    }

    # a 12-pixel border around the whole virtual screen: proves the window spans every monitor
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Lime), 12
    $g.DrawRectangle($pen, 6, 6, $w - 12, $h - 12); $pen.Dispose()

    if (-not $image) {
        # colour bars across the middle of the whole desktop
        $colors = 'Red', 'Orange', 'Yellow', 'Lime', 'Cyan', 'Blue', 'Violet'
        $barW = [int]($w / $colors.Count)
        for ($i = 0; $i -lt $colors.Count; $i++) {
            $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromName($colors[$i]))
            $g.FillRectangle($b, $i * $barW, [int]($h / 2) - 20, $barW, 40); $b.Dispose()
        }
        # single pixels: a dotted diagonal, one pixel every 4, corner to corner
        $bmp = New-Object System.Drawing.Bitmap 1, 1; $bmp.SetPixel(0, 0, [System.Drawing.Color]::White)
        for ($x = 0; $x -lt $w; $x += 4) { $g.DrawImageUnscaled($bmp, $x, [int]($x * $h / $w)) }
        $bmp.Dispose()
    }

    # moving square: repaint speed
    $sq = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::OrangeRed)
    $g.FillRectangle($sq, $state.X, [int]($h / 2) + 60, 80, 80); $sq.Dispose()

    $font = New-Object System.Drawing.Font 'Segoe UI', 20, ([System.Drawing.FontStyle]::Bold)
    $text = ("PlangOS overlay  {0}x{1}  {2:N0} fps  (click-through; closes by itself)" -f $w, $h, $state.Fps)
    $g.FillRectangle([System.Drawing.Brushes]::Black, 30, 30, 900, 44)
    $g.DrawString($text, $font, [System.Drawing.Brushes]::White, 38, 36); $font.Dispose()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 16   # ~60 fps target
$timer.Add_Tick({
    $state.X = ($state.X + 12) % [Math]::Max(1, $form.ClientSize.Width)
    $state.Frames++
    $elapsed = ([DateTime]::UtcNow - $state.Start).TotalSeconds
    if ($elapsed -gt 0) { $state.Fps = $state.Frames / $elapsed }
    if ($elapsed -ge $Seconds) { $form.Close() }
    $form.Invalidate()
})
$timer.Start()

[System.Windows.Forms.Application]::Run($form)
$timer.Dispose(); if ($image) { $image.Dispose() }
Write-Host ("Done: {0} frames in {1:N1} s = {2:N0} fps over {3}x{4} pixels" -f `
    $state.Frames, ([DateTime]::UtcNow - $state.Start).TotalSeconds, $state.Fps, $screen.Width, $screen.Height)
