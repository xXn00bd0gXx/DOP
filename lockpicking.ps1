# ═══════════════════════════════════════════════════════════
#  LOCKPICKING MINIGAME — Standalone
#  PowerShell 5+ Compatible | No Modules Required
#  Inspired by Elder Scrolls Oblivion + Rhythm Games
# ═══════════════════════════════════════════════════════════

# ── Setup ──
try { [Console]::CursorVisible = $false } catch {
    try { $Host.UI.RawUI.CursorSize = 0 } catch {}
}
$origFg = $Host.UI.RawUI.ForegroundColor
$origBg = $Host.UI.RawUI.BackgroundColor
try { $Host.UI.RawUI.BackgroundColor = 'Black' } catch {}
try { $Host.UI.RawUI.WindowTitle = "Lockpicking" } catch {}
Clear-Host

# ── Config ──
$TC    = 4        # tumbler count
$GH    = 10       # grid height (bounce rows)
$SW    = 2        # sweet zone (top N rows)
$CW    = 6        # column width per tumbler
$MAXPK = 3        # starting lockpicks
$FMS   = 45       # ms per frame

# ── State ──
$script:locked = @($false, $false, $false, $false)
$script:cur    = 0
$script:picks  = $MAXPK
$script:t      = 0.0
$script:run    = $true
$script:won    = $false
$script:msg    = ''
$script:msgC   = 'Gray'
$script:msgT   = 0

# Animation
$script:anim    = 'none'    # none | success | fail
$script:animF   = 0
$script:animPin = 0

# ── Tumbler Rhythm Setup ──
# Each tumbler has a unique frequency and phase offset.
# Phase offsets are staggered to create a visible wave pattern
# across all tumblers — the core "rhythm" element.
$rng = [System.Random]::new()
$script:frq = [double[]]::new($TC)
$script:phs = [double[]]::new($TC)
for ($i = 0; $i -lt $TC; $i++) {
    $script:frq[$i] = 2.0 + ($rng.NextDouble() * 0.8)
    $script:phs[$i] = $i * 1.3 + ($rng.NextDouble() * 0.5)
}

# ── Helper Functions ──

function Get-PinRow([int]$i) {
    if ($script:locked[$i]) { return 0 }
    $v = [Math]::Sin($script:t * $script:frq[$i] + $script:phs[$i])
    return [int][Math]::Round(($v + 1) / 2 * ($GH - 1))
}

function Test-Sweet([int]$i) { return ((Get-PinRow $i) -lt $SW) }

function W([string]$s, [ConsoleColor]$c) {
    Write-Host $s -NoNewline -ForegroundColor $c
}
function WL([string]$s, [ConsoleColor]$c) {
    Write-Host $s -ForegroundColor $c
}
function Reset-Cursor {
    try {
        $p = $Host.UI.RawUI.CursorPosition
        $p.X = 0; $p.Y = 0
        $Host.UI.RawUI.CursorPosition = $p
    } catch {
        try { [Console]::SetCursorPosition(0, 0) } catch {
            Clear-Host
        }
    }
}

# Inner width of the lock frame
$IW = $TC * $CW + ($TC - 1)

# ═══════════════════════════════════════════════════════════
#  RENDER
# ═══════════════════════════════════════════════════════════
function Render-Frame {

    Reset-Cursor

    # ── Shake offset on fail ──
    $sx = 0
    if ($script:anim -eq 'fail' -and $script:animF -lt 6) {
        $offsets = @(2, -2, 1, -1, 1, 0)
        $sx = $offsets[$script:animF]
    }
    $lPad = ' ' * [Math]::Max(0, 6 + $sx)
    $cPad = ' ' * [Math]::Max(0, 10 + $sx)

    # ═══════════════════════════════════
    #  TREASURE CHEST
    # ═══════════════════════════════════

    WL "" Gray
    WL "$cPad   ._______________." Yellow
    WL "$cPad  /   .--=====--.   \" Yellow

    W "$cPad /" Yellow; W "___" DarkYellow
    W "| " DarkYellow
    if ($script:won) { W "|" DarkYellow; W " OPEN! " Green; W "|" DarkYellow }
    else             { W "|" DarkYellow; W "LOCKED!" Red;    W "|" DarkYellow }
    W " |" DarkYellow; W "___" DarkYellow; WL "\" Yellow

    WL "$cPad |   | '-------' |   |" DarkYellow
    WL "$cPad |   '-----------'   |" DarkYellow
    WL "$cPad |_____________________|" DarkYellow
    WL "$cPad  \___________________/" DarkYellow
    WL "" Gray

    # ═══════════════════════════════════
    #  LOCK FRAME HEADER
    # ═══════════════════════════════════

    W "$lPad"; W ([char]0x2554) Cyan
    W ([string]([char]0x2550) * $IW) Cyan
    WL ([char]0x2557) Cyan

    W "$lPad"; W ([char]0x2551) Cyan; W " " Black
    W "LOCKPICKING" White
    $pickStr = "Picks: "
    for ($p = 0; $p -lt $MAXPK; $p++) {
        if ($p -lt $script:picks) { $pickStr += "> " }
        else { $pickStr += ". " }
    }
    $gap = $IW - 12 - $pickStr.Length
    if ($gap -lt 1) { $gap = 1 }
    W (' ' * $gap) Black
    if     ($script:picks -le 1) { W $pickStr Red    }
    elseif ($script:picks -le 2) { W $pickStr Yellow }
    else                         { W $pickStr Green  }
    WL ([char]0x2551) Cyan

    W "$lPad"; W ([char]0x2560) Cyan
    for ($c = 0; $c -lt $TC; $c++) {
        if ($c -gt 0) { W ([char]0x2564) Cyan }
        W ([string]([char]0x2550) * $CW) Cyan
    }
    WL ([char]0x2563) Cyan

    # ═══════════════════════════════════
    #  TUMBLER GRID
    # ═══════════════════════════════════

    for ($r = 0; $r -lt $GH; $r++) {
        $inSweet = ($r -lt $SW)

        if ($r -eq $SW) {
            W "$lPad"; W ([char]0x2551) Cyan
            for ($c = 0; $c -lt $TC; $c++) {
                if ($c -gt 0) { W "+" DarkGray }
                W ("------") DarkGray
            }
            WL ([char]0x2551) Cyan
        }

        W "$lPad"; W ([char]0x2551) Cyan

        for ($c = 0; $c -lt $TC; $c++) {
            if ($c -gt 0) {
                if ($inSweet) { W ([char]0x2502) DarkGreen }
                else          { W ([char]0x2502) DarkGray  }
            }

            $pinR   = Get-PinRow $c
            $isCur  = ($c -eq $script:cur)
            $isLck  = $script:locked[$c]
            $isAnim = ($script:anim -ne 'none' -and $c -eq $script:animPin)

            if ($pinR -eq $r) {
                if ($isLck) {
                    if ($isAnim -and $script:anim -eq 'success' -and ($script:animF % 4 -lt 2)) {
                        W " [##] " Yellow
                    } else {
                        W " [##] " Green
                    }
                }
                elseif ($isCur) {
                    if ($isAnim -and $script:anim -eq 'fail' -and ($script:animF % 3 -lt 2)) {
                        W " >XX< " Red
                    }
                    elseif ($inSweet) {
                        W " >##< " Yellow
                    }
                    else {
                        W " >##< " White
                    }
                }
                else {
                    W " [##] " Gray
                }
            }
            else {
                if ($inSweet) { W "  ~~  " DarkGreen }
                else          { W "      " Black     }
            }
        }

        WL ([char]0x2551) Cyan
    }

    W "$lPad"; W ([char]0x2560) Cyan
    for ($c = 0; $c -lt $TC; $c++) {
        if ($c -gt 0) { W ([char]0x2567) Cyan }
        W ([string]([char]0x2550) * $CW) Cyan
    }
    WL ([char]0x2563) Cyan

    # ═══════════════════════════════════
    #  CURRENT TUMBLER INDICATOR
    # ═══════════════════════════════════

    W "$lPad"; W ([char]0x2551) Cyan
    for ($c = 0; $c -lt $TC; $c++) {
        if ($c -gt 0) { W " " Black }
        if ($c -eq $script:cur -and -not $script:locked[$c]) {
            W "  /\  " Yellow
        } else {
            W "      " Black
        }
    }
    WL ([char]0x2551) Cyan

    W "$lPad"; W ([char]0x255A) Cyan
    W ([string]([char]0x2550) * $IW) Cyan
    WL ([char]0x255D) Cyan

    # ═══════════════════════════════════
    #  RHYTHM TIMING BAR
    # ═══════════════════════════════════

    $sync = -[Math]::Sin($script:t * $script:frq[$script:cur] + $script:phs[$script:cur])
    $barLen = 24
    $fill = [int][Math]::Max(0, [Math]::Round(($sync + 1) / 2 * $barLen))
    $barFull  = [string]([char]0x2588) * $fill
    $barEmpty = [string]([char]0x2591) * ($barLen - $fill)

    W "$lPad Timing: [" DarkGray
    if     ($sync -gt 0.75) { W $barFull Green;     W $barEmpty DarkGray }
    elseif ($sync -gt 0.3)  { W $barFull DarkGreen; W $barEmpty DarkGray }
    else                    { W $barFull DarkGray;   W $barEmpty DarkGray }
    WL "]" DarkGray

    W "$lPad         " DarkGray
    if ($sync -gt 0.75) { WL ">>> NOW! <<<        " Green }
    else                { WL "                    " DarkGray }

    # ═══════════════════════════════════
    #  MESSAGE + CONTROLS
    # ═══════════════════════════════════

    WL "" Gray
    if ($script:msg -ne '') {
        $padded = $script:msg.PadRight(55)
        WL "  $padded" $script:msgC
    } else {
        WL (' ' * 57) Gray
    }
    WL "" Gray
    WL "   [SPACE] Attempt Pick   [<][>] Select Tumbler   [ESC] Give Up" DarkCyan
    WL "" Gray
}

# ═══════════════════════════════════════════════════════════
#  INPUT HANDLING
# ═══════════════════════════════════════════════════════════
function Handle-Input {
    try { $hasKey = [Console]::KeyAvailable } catch { return }
    while ($hasKey) {
        try { $k = [Console]::ReadKey($true).Key } catch { return }

        if ($script:anim -ne 'none') {
            try { $hasKey = [Console]::KeyAvailable } catch { $hasKey = $false }
            continue
        }

        switch ($k) {

            'Spacebar' {
                if ($script:locked[$script:cur]) { break }

                if (Test-Sweet $script:cur) {
                    # ── SUCCESS ──
                    $script:locked[$script:cur] = $true
                    $script:anim    = 'success'
                    $script:animF   = 0
                    $script:animPin = $script:cur
                    $script:msg     = " * CLICK *  Tumbler $($script:cur + 1) is set!"
                    $script:msgC    = 'Green'
                    $script:msgT    = 35

                    $allDone = $true
                    for ($j = 0; $j -lt $TC; $j++) {
                        if (-not $script:locked[$j]) { $allDone = $false; break }
                    }
                    if ($allDone) {
                        $script:won  = $true
                        $script:msg  = " ** LOCK OPENED! The treasure is yours! **"
                        $script:msgC = 'Yellow'
                        $script:msgT = 999
                    }
                    else {
                        for ($j = 1; $j -le $TC; $j++) {
                            $nx = ($script:cur + $j) % $TC
                            if (-not $script:locked[$nx]) {
                                $script:cur = $nx; break
                            }
                        }
                    }
                }
                else {
                    # ── FAIL ──
                    $script:picks--
                    $script:anim    = 'fail'
                    $script:animF   = 0
                    $script:animPin = $script:cur

                    if ($script:picks -le 0) {
                        $script:msg  = " All lockpicks broken... the lock wins."
                        $script:msgC = 'DarkRed'
                        $script:msgT = 999
                        $script:run  = $false
                    }
                    else {
                        $script:msg  = " SNAP! Lockpick broke! ($($script:picks) left)"
                        $script:msgC = 'Red'
                        $script:msgT = 40

                        for ($j = 0; $j -lt $TC; $j++) {
                            if ($script:locked[$j] -and ($rng.NextDouble() -lt 0.25)) {
                                $script:locked[$j] = $false
                                $script:msg += " [T$($j+1) fell!]"
                            }
                        }
                    }
                }
            }

            'LeftArrow' {
                $unlocked = @()
                for ($j = 0; $j -lt $TC; $j++) {
                    if (-not $script:locked[$j]) { $unlocked += $j }
                }
                if ($unlocked.Count -gt 0) {
                    $idx = [Array]::IndexOf($unlocked, $script:cur)
                    if ($idx -le 0) { $script:cur = $unlocked[$unlocked.Count - 1] }
                    else            { $script:cur = $unlocked[$idx - 1] }
                }
            }

            'RightArrow' {
                $unlocked = @()
                for ($j = 0; $j -lt $TC; $j++) {
                    if (-not $script:locked[$j]) { $unlocked += $j }
                }
                if ($unlocked.Count -gt 0) {
                    $idx = [Array]::IndexOf($unlocked, $script:cur)
                    if ($idx -ge ($unlocked.Count - 1) -or $idx -lt 0) {
                        $script:cur = $unlocked[0]
                    }
                    else { $script:cur = $unlocked[$idx + 1] }
                }
            }

            'Escape' {
                $script:run  = $false
                $script:msg  = " You step away from the chest..."
                $script:msgC = 'DarkGray'
                $script:msgT = 999
            }
        }

        try { $hasKey = [Console]::KeyAvailable } catch { $hasKey = $false }
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
            Start-Sleep -Milliseconds 3
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
    try { [Console]::CursorVisible = $true } catch {
        try { $Host.UI.RawUI.CursorSize = 25 } catch {}
    }
    try { $Host.UI.RawUI.ForegroundColor = $origFg } catch {}
    try { $Host.UI.RawUI.BackgroundColor = $origBg } catch {}

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
