# ═══════════════════════════════════════════════════════════
#  LOCKPICKING MINIGAME - Compact Universal Version
#  PowerShell 5+ | No Modules | Console + ISE Safe
# ═══════════════════════════════════════════════════════════

Clear-Host
try { [Console]::CursorVisible = $false } catch {}

# ── Detect input method ──
$script:inputMode = 'none'
try {
    $null = [Console]::KeyAvailable
    $script:inputMode = 'console'
} catch {
    try {
        $null = $Host.UI.RawUI.KeyAvailable
        $script:inputMode = 'rawui'
    } catch {}
}
if ($script:inputMode -eq 'none') {
    Write-Host ""
    Write-Host "  This game requires powershell.exe console." -ForegroundColor Red
    Write-Host "  Cannot run in ISE or editors without key input." -ForegroundColor Red
    Write-Host ""
    return
}

# ── Ensure window fits our frame (28 lines) ──
$script:FRAME_H = 28
try {
    $bs = $Host.UI.RawUI.BufferSize
    if ($bs.Height -lt $script:FRAME_H + 5) {
        $bs.Height = $script:FRAME_H + 5
        $Host.UI.RawUI.BufferSize = $bs
    }
    $ws = $Host.UI.RawUI.WindowSize
    if ($ws.Height -lt $script:FRAME_H + 2) {
        $ws.Height = $script:FRAME_H + 2
        $Host.UI.RawUI.WindowSize = $ws
    }
    if ($ws.Width -lt 60) {
        $ws.Width = 60
        $Host.UI.RawUI.WindowSize = $ws
    }
} catch {}

# ── Reset cursor AND window scroll position ──
function Reset-Screen {
    try {
        $z = New-Object System.Management.Automation.Host.Coordinates(0, 0)
        $Host.UI.RawUI.CursorPosition = $z
        $Host.UI.RawUI.WindowPosition = $z
    } catch {
        try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
    }
}

function Get-Key {
    if ($script:inputMode -eq 'console') {
        try {
            if ([Console]::KeyAvailable) {
                return [Console]::ReadKey($true).Key.ToString()
            }
        } catch {}
    }
    elseif ($script:inputMode -eq 'rawui') {
        try {
            if ($Host.UI.RawUI.KeyAvailable) {
                return [string]($Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown').VirtualKeyCode)
            }
        } catch {}
    }
    return $null
}

# ── Config ──
$TC    = 4       # tumblers
$GH    = 8       # grid rows (reduced to fit screen)
$SZ    = 2       # sweet zone rows
$CW    = 6       # column width
$MAXPK = 3       # lockpicks
$FMS   = 50      # frame ms
$IW    = $TC * $CW + ($TC - 1)  # inner width

# ── State ──
$script:locked  = @($false, $false, $false, $false)
$script:cur     = 0
$script:picks   = $MAXPK
$script:t       = 0.0
$script:run     = $true
$script:won     = $false
$script:msg     = ''
$script:msgC    = 'Gray'
$script:msgT    = 0
$script:anim    = 'none'
$script:animF   = 0
$script:animPin = 0

# ── Rhythm ──
$script:rng = [System.Random]::new()
$script:frq = @(2.1, 2.5, 1.9, 2.7)
$script:phs = @(0.0, 1.3, 2.6, 3.9)
for ($i = 0; $i -lt $TC; $i++) {
    $script:frq[$i] += ($script:rng.NextDouble() - 0.5) * 0.3
    $script:phs[$i] += $script:rng.NextDouble() * 0.5
}

function Get-PinRow([int]$i) {
    if ($script:locked[$i]) { return 0 }
    $v = [Math]::Sin($script:t * $script:frq[$i] + $script:phs[$i])
    return [int][Math]::Round(($v + 1) / 2 * ($GH - 1))
}
function Test-Sweet([int]$i) { return ((Get-PinRow $i) -lt $SZ) }

# Box chars
$H  = [string]([char]0x2550);  $V  = [string]([char]0x2551)
$TL = [string]([char]0x2554);  $TR = [string]([char]0x2557)
$BL = [string]([char]0x255A);  $BR = [string]([char]0x255D)
$ML = [string]([char]0x2560);  $MR = [string]([char]0x2563)
$TJ = [string]([char]0x2564);  $BJ = [string]([char]0x2567)
$TV = [string]([char]0x2502)
$FK = [string]([char]0x2588);  $LB = [string]([char]0x2591)

# ═══════════════════════════════════════════════════════════
#  RENDER - Compact layout, fixed-width lines for clean shake
# ═══════════════════════════════════════════════════════════

$LINE_W = 60  # every line padded to this width

function Pad([string]$s) {
    if ($s.Length -ge $LINE_W) { return $s.Substring(0, $LINE_W) }
    return $s + (' ' * ($LINE_W - $s.Length))
}

function Render-Frame {
    Reset-Screen

    $sx = 0
    if ($script:anim -eq 'fail' -and $script:animF -lt 6) {
        $sa = @(2, -2, 1, -1, 1, 0); $sx = $sa[$script:animF]
    }
    $cp = ' ' * [Math]::Max(0, 9 + $sx)
    $lp = ' ' * [Math]::Max(0, 5 + $sx)

    # ── Chest ──
    Write-Host (Pad "$cp   ._______________."                ) -ForegroundColor Yellow
    Write-Host (Pad "$cp  /   .--=====--.   \"               ) -ForegroundColor Yellow

    # Chest lock line — build as single padded string with color segments
    $lockLine = "$cp /___| |"
    $lockStatus = if ($script:won) { " OPEN! " } else { "LOCKED!" }
    $lockEnd = "| |___\"
    $fullLockLine = $lockLine + $lockStatus + $lockEnd

    Write-Host (Pad $lockLine) -NoNewline -ForegroundColor DarkYellow
    # Overwrite the status portion with color
    Reset-Screen  # can't partial-overwrite easily, so build it with segments:

    # Actually let's just do the chest lock line properly:
    # We need each line fully padded. Easiest: build a full-width blank, then overlay.
    # Simpler approach: just write segments and pad the last one.

    # ── Let me redo this cleanly ──
    # For multi-color lines, write segments, then pad the final segment.

    Reset-Screen

    # ── LINE 1-7: Chest ──
    Write-Host (Pad "$cp   ._______________.")               -ForegroundColor Yellow
    Write-Host (Pad "$cp  /   .--=====--.   \")              -ForegroundColor Yellow

    # Chest body line (multi-color)
    Write-Host "$cp /___| |" -NoNewline -ForegroundColor DarkYellow
    if ($script:won) { Write-Host " OPEN! " -NoNewline -ForegroundColor Green }
    else             { Write-Host "LOCKED!" -NoNewline -ForegroundColor Red }
    $endStr = "| |___\"
    $used = "$cp /___| |".Length + 7 + $endStr.Length
    $trail = $LINE_W - $used
    if ($trail -lt 0) { $trail = 0 }
    Write-Host "$endStr$(' ' * $trail)" -ForegroundColor DarkYellow

    Write-Host (Pad "$cp |   | '-------' |   |")            -ForegroundColor DarkYellow
    Write-Host (Pad "$cp |   '-----------'   |")            -ForegroundColor DarkYellow
    Write-Host (Pad "$cp |_____________________|")           -ForegroundColor DarkYellow
    Write-Host (Pad "$cp  \___________________/")            -ForegroundColor DarkYellow

    # ── LINE 8: Top border ──
    Write-Host (Pad "$lp$TL$($H * $IW)$TR")                 -ForegroundColor Cyan

    # ── LINE 9: Title + Picks (multi-color) ──
    $pickStr = "Picks:"
    for ($p = 0; $p -lt $MAXPK; $p++) {
        if ($p -lt $script:picks) { $pickStr += " >" } else { $pickStr += " ." }
    }
    $pkC = 'Green'
    if ($script:picks -le 1) { $pkC = 'Red' }
    elseif ($script:picks -le 2) { $pkC = 'Yellow' }
    $gap = $IW - 13 - $pickStr.Length
    if ($gap -lt 0) { $gap = 0 }

    Write-Host "$lp$V" -NoNewline -ForegroundColor Cyan
    Write-Host " LOCKPICKING" -NoNewline -ForegroundColor White
    Write-Host "$(' ' * $gap) " -NoNewline
    Write-Host "$pickStr" -NoNewline -ForegroundColor $pkC
    $titleUsed = "$lp$V".Length + 12 + $gap + 1 + $pickStr.Length + 1
    $titleTrail = $LINE_W - $titleUsed
    if ($titleTrail -lt 0) { $titleTrail = 0 }
    Write-Host "$V$(' ' * $titleTrail)" -ForegroundColor Cyan

    # ── LINE 10: Grid top separator ──
    $sep = $ML
    for ($c = 0; $c -lt $TC; $c++) {
        if ($c -gt 0) { $sep += $TJ }
        $sep += $H * $CW
    }
    $sep += $MR
    Write-Host (Pad "$lp$sep") -ForegroundColor Cyan

    # ── Grid rows ──
    for ($r = 0; $r -lt $GH; $r++) {
        $inSweet = ($r -lt $SZ)

        # Sweet zone divider
        if ($r -eq $SZ) {
            $divLine = "$lp$V"
            for ($c = 0; $c -lt $TC; $c++) {
                if ($c -gt 0) { $divLine += "+" }
                $divLine += "------"
            }
            $divLine += $V
            Write-Host (Pad $divLine) -ForegroundColor DarkGray
        }

        # Build this row as segments for multi-color output
        # Left border
        Write-Host "$lp$V" -NoNewline -ForegroundColor Cyan

        for ($c = 0; $c -lt $TC; $c++) {
            if ($c -gt 0) {
                $sepC = 'DarkGray'
                if ($inSweet) { $sepC = 'DarkGreen' }
                Write-Host "$TV" -NoNewline -ForegroundColor $sepC
            }

            $pinR  = Get-PinRow $c
            $isCur = ($c -eq $script:cur)
            $isLck = $script:locked[$c]
            $isAn  = ($script:anim -ne 'none' -and $c -eq $script:animPin)

            if ($pinR -eq $r) {
                if ($isLck) {
                    $cc = 'Green'
                    if ($isAn -and $script:anim -eq 'success' -and ($script:animF % 4 -lt 2)) { $cc = 'Yellow' }
                    Write-Host " [##] " -NoNewline -ForegroundColor $cc
                }
                elseif ($isCur) {
                    if ($isAn -and $script:anim -eq 'fail' -and ($script:animF % 3 -lt 2)) {
                        Write-Host " >XX< " -NoNewline -ForegroundColor Red
                    } elseif ($inSweet) {
                        Write-Host " >##< " -NoNewline -ForegroundColor Yellow
                    } else {
                        Write-Host " >##< " -NoNewline -ForegroundColor White
                    }
                }
                else {
                    Write-Host " [##] " -NoNewline -ForegroundColor Gray
                }
            }
            else {
                if ($inSweet) { Write-Host "  ~~  " -NoNewline -ForegroundColor DarkGreen }
                else { Write-Host "      " -NoNewline }
            }
        }

        # Right border + padding to fixed width
        $rowUsed = "$lp$V".Length + ($TC * $CW) + ($TC - 1) + 1
        $rowTrail = $LINE_W - $rowUsed
        if ($rowTrail -lt 0) { $rowTrail = 0 }
        Write-Host "$V$(' ' * $rowTrail)" -ForegroundColor Cyan
    }

    # ── Bottom separator ──
    $sep2 = $ML
    for ($c = 0; $c -lt $TC; $c++) {
        if ($c -gt 0) { $sep2 += $BJ }
        $sep2 += $H * $CW
    }
    $sep2 += $MR
    Write-Host (Pad "$lp$sep2") -ForegroundColor Cyan

    # ── Tumbler indicator ──
    Write-Host "$lp$V" -NoNewline -ForegroundColor Cyan
    for ($c = 0; $c -lt $TC; $c++) {
        if ($c -gt 0) { Write-Host " " -NoNewline }
        if ($c -eq $script:cur -and -not $script:locked[$c]) {
            Write-Host "  /\  " -NoNewline -ForegroundColor Yellow
        } else { Write-Host "      " -NoNewline }
    }
    $arrowTrail = $LINE_W - ("$lp$V".Length + ($TC * $CW) + ($TC - 1) + 1)
    if ($arrowTrail -lt 0) { $arrowTrail = 0 }
    Write-Host "$V$(' ' * $arrowTrail)" -ForegroundColor Cyan

    # ── Bottom border ──
    Write-Host (Pad "$lp$BL$($H * $IW)$BR") -ForegroundColor Cyan

    # ── Timing bar (single line) ──
    $sync = -[Math]::Sin($script:t * $script:frq[$script:cur] + $script:phs[$script:cur])
    $barLen = 20
    $fill = [int][Math]::Max(0, [Math]::Round(($sync + 1) / 2 * $barLen))
    $remain = $barLen - $fill
    $barC = 'DarkGray'
    if ($sync -gt 0.75) { $barC = 'Green' }
    elseif ($sync -gt 0.3) { $barC = 'DarkGreen' }

    Write-Host "$lp Timing:[" -NoNewline -ForegroundColor DarkGray
    if ($fill -gt 0) { Write-Host "$($FK * $fill)" -NoNewline -ForegroundColor $barC }
    if ($remain -gt 0) { Write-Host "$($LB * $remain)" -NoNewline -ForegroundColor DarkGray }
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    $nowStr = if ($sync -gt 0.75) { ">>> NOW! <<<" } else { "            " }
    $barUsed = "$lp Timing:[".Length + $barLen + 2 + $nowStr.Length
    $barTrail = $LINE_W - $barUsed
    if ($barTrail -lt 0) { $barTrail = 0 }
    if ($sync -gt 0.75) { Write-Host "$nowStr$(' ' * $barTrail)" -ForegroundColor Green }
    else { Write-Host "$nowStr$(' ' * $barTrail)" }

    # ── Message ──
    if ($script:msg -ne '') {
        Write-Host (Pad "  $($script:msg)") -ForegroundColor $script:msgC
    } else {
        Write-Host (Pad "")
    }

    # ── Controls ──
    Write-Host (Pad "  [SPACE] Pick  [< >] Select  [ESC] Give Up") -ForegroundColor DarkCyan
}


# ═══════════════════════════════════════════════════════════
#  INPUT
# ═══════════════════════════════════════════════════════════

function Handle-Input {
    $key = Get-Key
    while ($key -ne $null) {
        if ($script:anim -ne 'none') { $key = Get-Key; continue }

        $isSpace = ($key -eq 'Spacebar' -or $key -eq '32')
        $isLeft  = ($key -eq 'LeftArrow' -or $key -eq 'Left' -or $key -eq '37')
        $isRight = ($key -eq 'RightArrow' -or $key -eq 'Right' -or $key -eq '39')
        $isEsc   = ($key -eq 'Escape' -or $key -eq '27')

        if ($isSpace -and -not $script:locked[$script:cur]) {
            if (Test-Sweet $script:cur) {
                # ── SUCCESS ──
                $script:locked[$script:cur] = $true
                $script:anim = 'success'
                $script:animF = 0
                $script:animPin = $script:cur
                $script:msg = "* CLICK * Tumbler $($script:cur + 1) is set!"
                $script:msgC = 'Green'
                $script:msgT = 35

                $allDone = $true
                for ($j = 0; $j -lt $TC; $j++) {
                    if (-not $script:locked[$j]) { $allDone = $false; break }
                }

                if ($allDone) {
                    $script:won = $true
                    $script:msg = "** LOCK OPENED! The treasure is yours! **"
                    $script:msgC = 'Yellow'
                    $script:msgT = 999
                } else {
                    for ($j = 1; $j -le $TC; $j++) {
                        $nx = ($script:cur + $j) % $TC
                        if (-not $script:locked[$nx]) { $script:cur = $nx; break }
                    }
                }
            }
            else {
                # ── FAIL ──
                $script:picks--
                $script:anim = 'fail'
                $script:animF = 0
                $script:animPin = $script:cur

                if ($script:picks -le 0) {
                    $script:msg = "All lockpicks broken... the lock wins."
                    $script:msgC = 'DarkRed'
                    $script:msgT = 999
                    $script:run = $false
                } else {
                    $script:msg = "SNAP! Pick broke! ($($script:picks) left)"
                    $script:msgC = 'Red'
                    $script:msgT = 40
                    for ($j = 0; $j -lt $TC; $j++) {
                        if ($script:locked[$j] -and ($script:rng.NextDouble() -lt 0.25)) {
                            $script:locked[$j] = $false
                            $script:msg += " [T$($j+1) fell!]"
                        }
                    }
                }
            }
        }
        elseif ($isLeft) {
            $ul = @()
            for ($j = 0; $j -lt $TC; $j++) { if (-not $script:locked[$j]) { $ul += $j } }
            if ($ul.Count -gt 0) {
                $idx = [Array]::IndexOf($ul, $script:cur)
                if ($idx -le 0) { $script:cur = $ul[$ul.Count - 1] }
                else { $script:cur = $ul[$idx - 1] }
            }
        }
        elseif ($isRight) {
            $ul = @()
            for ($j = 0; $j -lt $TC; $j++) { if (-not $script:locked[$j]) { $ul += $j } }
            if ($ul.Count -gt 0) {
                $idx = [Array]::IndexOf($ul, $script:cur)
                if ($idx -ge ($ul.Count - 1) -or $idx -lt 0) { $script:cur = $ul[0] }
                else { $script:cur = $ul[$idx + 1] }
            }
        }
        elseif ($isEsc) {
            $script:run = $false
            $script:msg = "You step away from the chest..."
            $script:msgC = 'DarkGray'
            $script:msgT = 999
        }

        $key = Get-Key
    }
}

# ═══════════════════════════════════════════════════════════
#  MAIN GAME LOOP
# ═══════════════════════════════════════════════════════════

$clock = [System.Diagnostics.Stopwatch]::StartNew()
$lastMs = $clock.ElapsedMilliseconds

try {
    while ($script:run) {
        $nowMs = $clock.ElapsedMilliseconds
        if (($nowMs - $lastMs) -lt $FMS) {
            Start-Sleep -Milliseconds 5
            continue
        }
        $dt = ($nowMs - $lastMs) / 1000.0
        $lastMs = $nowMs
        $script:t += $dt

        if ($script:msgT -gt 0) {
            $script:msgT--
            if ($script:msgT -eq 0 -and $script:run) { $script:msg = '' }
        }

        if ($script:anim -ne 'none') {
            $script:animF++
            if ($script:anim -eq 'success' -and $script:animF -ge 10) { $script:anim = 'none' }
            if ($script:anim -eq 'fail'    -and $script:animF -ge 8)  { $script:anim = 'none' }
        }

        Handle-Input

        if ($script:won -and $script:anim -eq 'none') {
            Render-Frame
            Start-Sleep -Milliseconds 1500
            $script:run = $false
            break
        }

        Render-Frame
    }

    Render-Frame
    Start-Sleep -Seconds 2
}
finally {
    try { [Console]::CursorVisible = $true } catch {}
    Write-Host ""
    if ($script:won) {
        Write-Host "  The chest creaks open..." -ForegroundColor Yellow
        Write-Host "  You found treasure inside!" -ForegroundColor Yellow
    }
    elseif ($script:picks -le 0) {
        Write-Host "  The lock holds firm. No picks remain." -ForegroundColor DarkGray
    }
    else {
        Write-Host "  You left the chest unopened." -ForegroundColor DarkGray
    }
    Write-Host ""
}
