# ══════════════════════════════════════════════════════════════════
#  DEPTHS OF POWERSHELL
# ══════════════════════════════════════════════════════════════════
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "Depths of PowerShell"

# ─── GLOBAL STATE ─────────────────────────────────────────────────
$script:Player       = $null
$script:PlayerClass  = ""          # tracks class name for weapon affinity
$script:Dungeon      = $null
$script:DungeonLevel = 0
$script:Inventory    = [System.Collections.ArrayList]@()
$script:Gold         = 50
$script:XP           = 0
$script:PlayerLevel  = 1
$script:XPToNext     = 100
$script:HasBossKey   = $false
$script:BossDefeated = $false
$script:Potions      = [System.Collections.ArrayList]@()
$script:ThrowablePotions = [System.Collections.ArrayList]@()  # Phase 2 combat items
$script:EquippedWeapon = $null
$script:EquippedArmor  = @{       # 5 armor slots
    Helmet = $null
    Chest  = $null
    Shield = $null
    Amulet = $null
    Boots  = $null
}
$script:GameRunning  = $true
$script:StatusMsg    = ""
$script:KillCount    = 0           # tracks total kills (for quests)
$script:Partner      = $null       # guild companion (Phase 3)
$script:Quests       = [System.Collections.ArrayList]@()  # active quests (Phase 3)
$script:RescueTarget = $null       # rescue quest NPC in dungeon (Phase 3)
$script:AvailableQuests  = $null
$script:DungeonKills     = 0
$script:DungeonTreasures = 0
$script:RoyalSuiteUses = 0

# ─── NEW IN v2.0 ──────────────────────────────────────────────────
$script:LuckTurnsLeft    = 0       # Potion of Luck: temporary +crit%
$script:LuckBonus        = 0       # how much hit% the active Luck adds
$script:Stance           = "Balanced"  # combat stance: "Aggressive", "Balanced", "Defensive"
$script:TrainingPoints   = @{      # stat bumps purchased at training ground
    ATK = 0; DEF = 0; SPD = 0; MAG = 0; HP = 0; MP = 0
}
$script:Streak           = 0       # consecutive dungeon clears without dying
$script:BestStreak       = 0
$script:Achievements     = @{}     # name -> $true when unlocked
$script:DailyDungeonDate = ""      # stores yyyy-MM-dd of last daily run
$script:DailyDungeonDone = $false
$script:TutorialSeen     = $false
$script:TotalKills       = 0       # lifetime (separate from $script:KillCount for quests)
$script:BossesDefeated   = 0       # lifetime dungeon bosses
$script:WeaponsOwned     = @{}     # weapon name -> $true (for collection tracking)
$script:ArmorOwned       = @{}     # armor name -> $true
$script:OwnsDutchmanBlade = $false # one-time encounter flag
$script:CompletedQuests   = 0      # lifetime quest turn-ins (for achievement)
$script:DailyDungeonActive = $false # set true during Daily run by main menu
$script:Lockpicks          = 5      # starting count; separate from Inventory so market can't sell
$script:DisturbedChests    = @{}    # set of "x,y" keys for chests abandoned mid-pick per-dungeon
$script:EncountersThisDungeon = 0   # cap at 2 per dungeon (Dutchman doesn't count)
$script:EncounterTiles     = @{}    # per-tile encounter history; tile can't fire twice in same dungeon
# Special end-of-dungeon items — never sold in shops, only earned by clearing
$script:RepairKits         = 0      # one-use, restores ALL gear durability to full
$script:ExtraStrongPotions = 0      # one-use in combat, restores ALL HP and MP
# Lifetime stat counters added in v1.3 — drive new achievements
$script:TotalCrits         = 0      # lifetime crits landed
$script:TotalLocksPicked   = 0      # lifetime successful chest unlocks
$script:TotalBareKills     = 0      # lifetime kills with no weapon equipped
$script:TotalUntouched     = 0      # times reached boss room above 75% HP
$script:TotalStanceSwaps   = 0      # times changed stance
$script:TotalRepairs       = 0      # times paid the blacksmith for a repair



# ─── HELPERS ──────────────────────────────────────────────────────

# ── FRAME BUFFER (for flicker-free dungeon redraws) ─────────────────
# When $script:Buffered is $true, Write-C / Write-CL append to an
# in-memory frame buffer instead of writing directly to the host.
# Calling Flush-Frame compares the new buffer to the previous frame
# and only writes the cells that changed, by cursor-positioning. This
# eliminates the screen flash from Clear-Host on every dungeon turn.
#
# Hosts that don't support cursor positioning fall back to Clear-Host
# + full-paint automatically.
$script:Buffered    = $false       # is buffered output active?
$script:FrameBuf    = $null        # array of @{Text;Fg;Bg} cells, indexed [row,col]
# Buffer dimensions are sized to the actual console window so that
# cursor positioning never overflows (which would scroll the terminal
# and invalidate every other absolute position we wrote).
# We reserve ZERO rows for "below buffer" content — controls bar and
# prompt go INTO the buffer and get diff-painted with the rest.
$script:FrameRows   = 36
$script:FrameCols   = 100
try {
    $ws = $Host.UI.RawUI.WindowSize
    if($ws.Width  -ge 60){
        if($ws.Width -le 120){ $script:FrameCols = $ws.Width }
        else { $script:FrameCols = 120 }
    }
    if($ws.Height -ge 24){
        # Reserve 1 trailing row so the cursor parking spot doesn't trigger scroll.
        $script:FrameRows = [math]::Min($ws.Height - 1, 50)
    }
} catch {}
$script:FrameRow    = 0            # current write row
$script:FrameCol    = 0            # current write col
$script:PrevFrame   = $null        # previous frame for diff
$script:CursorPosOK = $null        # null=untested, $true=works, $false=fallback to Clear-Host
$script:BufferedFirstFrame = $true # full-paint on first frame after Begin-Frame

function Test-CursorPositionOK {
    if($null -ne $script:CursorPosOK){ return $script:CursorPosOK }
    try {
        $null = $Host.UI.RawUI.CursorPosition
        $script:CursorPosOK = $true
    } catch {
        $script:CursorPosOK = $false
    }
    return $script:CursorPosOK
}

function Begin-Frame {
    # Detect window-size changes since the last frame. If the size has
    # changed (or this is the first frame), resize the buffer to match
    # the new window and force a full repaint to avoid stale-cell
    # mismatches against the previous frame.
    #
    # The dungeon view needs ~30 rows: ~27 for the 3D viewport + minimap
    # + HUD + status, plus 2 controls bar lines + 1 prompt. We require
    # 32 rows of headroom to enable buffered rendering. Smaller windows
    # fall back to Clear-Host + full-paint each frame (slower but
    # correct — no scroll-induced tearing).
    $script:BufferedDisabled = $false
    try {
        $ws = $Host.UI.RawUI.WindowSize
        if($ws.Width -lt 80 -or $ws.Height -lt 32){
            # Too small for buffered rendering. Fall back to clear-and-redraw.
            $script:BufferedDisabled = $true
            $script:Buffered = $false
            $script:PrevFrame = $null
            $script:BufferedFirstFrame = $true
            return
        }
        $newCols = $script:FrameCols
        $newRows = $script:FrameRows
        if($ws.Width -le 120){ $newCols = $ws.Width }
        else { $newCols = 120 }
        # Buffer height: leave 2 rows of safety margin under the window
        # so the cursor never hits the bottom and triggers terminal scroll.
        $newRows = [math]::Min($ws.Height - 2, 50)
        if($newCols -ne $script:FrameCols -or $newRows -ne $script:FrameRows){
            $script:FrameCols = $newCols
            $script:FrameRows = $newRows
            $script:PrevFrame = $null
            $script:BufferedFirstFrame = $true
        }
    } catch {
        $script:BufferedDisabled = $true
        $script:Buffered = $false
        return
    }

    # Allocate a fresh buffer of empty cells. Mark cursor pos at home.
    $script:FrameBuf = New-Object 'object[,]' $script:FrameRows, $script:FrameCols
    for($r=0; $r -lt $script:FrameRows; $r++){
        for($c=0; $c -lt $script:FrameCols; $c++){
            $script:FrameBuf[$r,$c] = @{Text=' '; Fg='Gray'; Bg=''}
        }
    }
    $script:FrameRow = 0
    $script:FrameCol = 0
    $script:Buffered = $true
}

function Buf-Write {
    param([string]$Text, [string]$Fg='Gray', [string]$Bg='')
    if(-not $script:FrameBuf){ return }
    if($null -eq $Text){ return }
    foreach($ch in $Text.ToCharArray()){
        if($ch -eq "`n"){
            $script:FrameRow++
            $script:FrameCol = 0
            continue
        }
        if($script:FrameRow -ge $script:FrameRows){ return }
        if($script:FrameCol -ge $script:FrameCols){
            # truncate rather than wrapping
            continue
        }
        $script:FrameBuf[$script:FrameRow, $script:FrameCol] = @{Text=[string]$ch; Fg=$Fg; Bg=$Bg}
        $script:FrameCol++
    }
}

function Buf-Newline {
    if(-not $script:FrameBuf){ return }
    $script:FrameRow++
    $script:FrameCol = 0
}

# Diff current frame vs previous and paint only changed cells.
# On hosts without cursor positioning, fall back to Clear-Host + full
# repaint (which is identical to the pre-buffer behavior).
function Flush-Frame {
    if(-not $script:FrameBuf){ return }
    $script:Buffered = $false   # writes after this go directly to host

    if(-not (Test-CursorPositionOK)){
        # Fallback path: dump entire buffer with regular writes
        Clear-Host
        for($r=0; $r -lt $script:FrameRows; $r++){
            $hasContent = $false
            for($c=0; $c -lt $script:FrameCols; $c++){
                if($script:FrameBuf[$r,$c].Text -ne ' '){ $hasContent = $true; break }
            }
            if(-not $hasContent){ Write-Host ""; continue }
            $line = ""
            $curFg = $null; $curBg = $null
            for($c=0; $c -lt $script:FrameCols; $c++){
                $cell = $script:FrameBuf[$r,$c]
                if($cell.Fg -ne $curFg -or $cell.Bg -ne $curBg){
                    if($line.Length -gt 0){
                        if($curBg){ Write-Host $line -ForegroundColor $curFg -BackgroundColor $curBg -NoNewline }
                        else      { Write-Host $line -ForegroundColor $curFg -NoNewline }
                        $line = ""
                    }
                    $curFg = $cell.Fg; $curBg = $cell.Bg
                }
                $line += $cell.Text
            }
            if($line.Length -gt 0){
                if($curBg){ Write-Host $line -ForegroundColor $curFg -BackgroundColor $curBg }
                else      { Write-Host $line -ForegroundColor $curFg }
            } else {
                Write-Host ""
            }
        }
        $script:PrevFrame = $script:FrameBuf
        $script:FrameBuf = $null
        return
    }

    # Hide cursor during paint to avoid blink flicker
    $cursorWasVisible = $true
    try { $cursorWasVisible = [Console]::CursorVisible } catch {}
    try { [Console]::CursorVisible = $false } catch {}

    if($script:BufferedFirstFrame -or -not $script:PrevFrame){
        # First frame: full clear and paint
        Clear-Host
        for($r=0; $r -lt $script:FrameRows; $r++){
            try {
                $pos = New-Object System.Management.Automation.Host.Coordinates 0, $r
                $Host.UI.RawUI.CursorPosition = $pos
            } catch { break }
            # Find last non-blank col on this row to avoid trailing spaces
            $lastCol = -1
            for($c=$script:FrameCols - 1; $c -ge 0; $c--){
                if($script:FrameBuf[$r,$c].Text -ne ' '){ $lastCol = $c; break }
            }
            if($lastCol -lt 0){ continue }
            $line = ""
            $curFg = $null; $curBg = $null
            for($c=0; $c -le $lastCol; $c++){
                $cell = $script:FrameBuf[$r,$c]
                if($cell.Fg -ne $curFg -or $cell.Bg -ne $curBg){
                    if($line.Length -gt 0){
                        if($curBg){ Write-Host $line -ForegroundColor $curFg -BackgroundColor $curBg -NoNewline }
                        else      { Write-Host $line -ForegroundColor $curFg -NoNewline }
                        $line = ""
                    }
                    $curFg = $cell.Fg; $curBg = $cell.Bg
                }
                $line += $cell.Text
            }
            if($line.Length -gt 0){
                if($curBg){ Write-Host $line -ForegroundColor $curFg -BackgroundColor $curBg -NoNewline }
                else      { Write-Host $line -ForegroundColor $curFg -NoNewline }
            }
        }
        $script:BufferedFirstFrame = $false
    } else {
        # Diff and paint only changed runs of cells
        for($r=0; $r -lt $script:FrameRows; $r++){
            $c = 0
            while($c -lt $script:FrameCols){
                $newCell = $script:FrameBuf[$r,$c]
                $oldCell = $script:PrevFrame[$r,$c]
                if($newCell.Text -ne $oldCell.Text -or $newCell.Fg -ne $oldCell.Fg -or $newCell.Bg -ne $oldCell.Bg){
                    # Found a changed cell — find run of consecutive changes with same fg/bg
                    $runStart = $c
                    $runFg = $newCell.Fg
                    $runBg = $newCell.Bg
                    $runText = $newCell.Text
                    $c++
                    while($c -lt $script:FrameCols){
                        $nc = $script:FrameBuf[$r,$c]
                        $oc = $script:PrevFrame[$r,$c]
                        $changed = ($nc.Text -ne $oc.Text -or $nc.Fg -ne $oc.Fg -or $nc.Bg -ne $oc.Bg)
                        if(-not $changed -or $nc.Fg -ne $runFg -or $nc.Bg -ne $runBg){ break }
                        $runText += $nc.Text
                        $c++
                    }
                    try {
                        $pos = New-Object System.Management.Automation.Host.Coordinates $runStart, $r
                        $Host.UI.RawUI.CursorPosition = $pos
                        if($runBg){ Write-Host $runText -ForegroundColor $runFg -BackgroundColor $runBg -NoNewline }
                        else      { Write-Host $runText -ForegroundColor $runFg -NoNewline }
                    } catch {
                        # If positioning fails, abandon partial-redraw and full-paint next time
                        $script:BufferedFirstFrame = $true
                        break
                    }
                } else {
                    $c++
                }
            }
        }
    }

    # Restore cursor visibility. The CALLER is responsible for parking the
    # cursor wherever it should appear (e.g. at a prompt) — Flush-Frame
    # leaves it wherever the last paint write put it.
    try { [Console]::CursorVisible = $cursorWasVisible } catch {}

    $script:PrevFrame = $script:FrameBuf
    $script:FrameBuf = $null
}

# Reset buffered mode — call when leaving the dungeon to force full paint next time.
function Reset-FrameBuffer {
    $script:Buffered = $false
    $script:FrameBuf = $null
    $script:PrevFrame = $null
    $script:BufferedFirstFrame = $true
}

function Write-C { param([string]$Text,[string]$Color="White",[string]$BG="")
    if($script:Buffered){
        Buf-Write $Text $Color $BG
        return
    }
    if($BG){
        Write-Host $Text -ForegroundColor $Color -BackgroundColor $BG -NoNewline
    } else {
        Write-Host $Text -ForegroundColor $Color -NoNewline
    }
}
function Write-CL { param([string]$Text,[string]$Color="White",[string]$BG="")
    if($script:Buffered){
        Buf-Write $Text $Color $BG
        Buf-Newline
        return
    }
    if($BG){
        Write-Host $Text -ForegroundColor $Color -BackgroundColor $BG
    } else {
        Write-Host $Text -ForegroundColor $Color
    }
}
function Wait-Key { Write-Host ""; Write-C "[Press any key]" "DarkGray"; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
function clr {
    Clear-Host
    # Any non-dungeon clear invalidates the buffered dungeon state, so the
    # next dungeon render starts with a full paint instead of a partial diff.
    $script:BufferedFirstFrame = $true
    $script:PrevFrame = $null
}

# Safely parse a string into an integer. Returns $Default (0 by default) for
# any non-numeric input — including empty strings, letters, spaces, etc.
# Use this everywhere the user types a number into a Read-Host menu so a
# stray keystroke can't crash the game with a casting exception.
function ConvertTo-SafeInt {
    param(
        [string]$Value,
        [int]$Default = 0
    )
    if([string]::IsNullOrWhiteSpace($Value)){ return $Default }
    $trimmed = $Value.Trim()
    $val = 0
    if([int]::TryParse($trimmed, [ref]$val)){ return $val }
    return $Default
}

# ─── ABILITY SCALING ─────────────────────────────────────────────
# Player abilities evolve at levels 5, 10, 15. Each tier adds power.
# Capped at 3 upgrades (max tier reached at level 15).
#
# Returns the current ability tier index (0 = base, 1, 2, or 3).
function Get-AbilityTier {
    param([int]$Level)
    if($Level -ge 15){ return 3 }
    if($Level -ge 10){ return 2 }
    if($Level -ge 5){  return 1 }
    return 0
}

# Returns a roman-numeral suffix for the ability name based on tier.
# Base tier (0) returns empty string so the base name is unchanged.
function Get-TierSuffix {
    param([int]$Tier)
    switch($Tier){
        1 { " II" }
        2 { " III" }
        3 { " IV" }
        default { "" }
    }
}

# Returns a scaled copy of an ability with its Power upgraded by tier
# and its Name appended with " II / III / IV".
# Heals scale more (the player's MaxHP grows fast); buffs are also scaled.
function Get-ScaledAbility {
    param($Ability, [int]$Level)
    $tier = Get-AbilityTier $Level
    if($tier -le 0){ return $Ability }
    $copy = @{}
    foreach($k in $Ability.Keys){ $copy[$k] = $Ability[$k] }
    # +25% power per tier (rounded up). Healing scales the same way.
    if($Ability.Power -gt 0){
        $copy.Power = [int][math]::Ceiling($Ability.Power * (1 + 0.25 * $tier))
    }
    $copy.Name = $Ability.Name + (Get-TierSuffix $tier)
    return $copy
}

# Returns total DEF bonus from all equipped armor pieces
function Get-TotalArmorDEF {
    $total = 0
    foreach($slot in $script:EquippedArmor.Keys){
        $piece = $script:EquippedArmor[$slot]
        if($piece -and -not (Test-ItemBroken $piece)){
            $total += $piece.DEF
        }
    }
    return $total
}

# Returns bonus ATK if equipped weapon matches player class
# Helper used by shop tables: pads a string to $Width with a leading space,
# truncating if the text is longer than the column. Renders text exactly
# inside a cell of the given width, lining up with border dashes.
function Pad-Cell {
    param([string]$Text, [int]$Width)
    $s = " $Text"
    if($s.Length -ge $Width){ return $s.Substring(0, $Width) }
    return $s.PadRight($Width)
}

# ─── DURABILITY SYSTEM ────────────────────────────────────────────
# Weapons and armor have a durability pool. Broken items stay equipped
# but contribute 0 stat bonus. Repairs happen at the blacksmith.
#
# Max durability formulas:
#   Weapons: max(20, ATK * 2)     — tier scales linearly with hits
#   Armor:   max(15, DEF * 3)     — tier scales with hits absorbed
#
# Returns the computed max durability for a given item.
# ─── INVENTORY WEIGHT SYSTEM ─────────────────────────────────────
# Carry capacity: 100 + (avg(ATK,DEF) * 5). Updates whenever stats change.
# Equipped gear is FREE. Gold, lockpicks, repair kits, ESPs, potions weigh 0.
# Loot weight = ceil(value/30). Equipment in inventory has fixed slot/type weight.
function Get-MaxCarryWeight {
    param($Player)
    if(-not $Player){ return 100 }
    $avgStat = ($Player.ATK + $Player.DEF) / 2
    return [int](100 + ($avgStat * 5))
}

# Returns the weight an inventory item contributes when carried (NOT equipped).
function Get-ItemWeight {
    param($Item)
    if(-not $Item){ return 0 }
    if($Item.ContainsKey("Weight")){ return [int]$Item.Weight }
    # Fallback: classify by Kind / Slot / WeaponType
    if($Item.Kind -eq "Weapon" -or $Item.WeaponType){
        $wt = switch($Item.WeaponType){
            "Dagger"     { 4 }
            "Staff"      { 4 }
            "Wand"       { 4 }
            "Sword"      { 5 }
            "Mace"       { 5 }
            "Bow"        { 5 }
            "Greatsword" { 6 }
            "Scythe"     { 6 }
            "Hammer"     { 6 }
            default      { 5 }
        }
        return $wt
    }
    if($Item.Kind -eq "Armor" -or $Item.Slot){
        $wt = switch($Item.Slot){
            "Helmet" { 2 }
            "Chest"  { 4 }
            "Shield" { 3 }
            "Amulet" { 1 }
            "Boots"  { 2 }
            default  { 2 }
        }
        return $wt
    }
    # Potions all weigh 1 — small but not free
    if($Item.Kind -eq "Potion" -or $Item.Type -in @("Heal","Mana","ATKBuff","DEFBuff","Luck","Throw","ThrowPoison","ThrowSlow")){
        return 1
    }
    # Loot fallback: ceil(value / 30)
    if($Item.Value){
        return [math]::Max(1, [math]::Ceiling([int]$Item.Value / 30.0))
    }
    return 1
}

# Sums weight across the inventory bag.
function Get-CurrentCarryWeight {
    $w = 0
    foreach($it in $script:Inventory){
        $w += (Get-ItemWeight $it)
    }
    # Lockpicks weigh 1 each
    $w += [int]$script:Lockpicks
    # Potions and throwables in their respective bags weigh 1 each
    if($script:Potions){
        $w += $script:Potions.Count
    }
    if($script:ThrowablePotions){
        $w += $script:ThrowablePotions.Count
    }
    return $w
}

# True if the player is at or over their carry cap.
function Test-Encumbered {
    $cur = Get-CurrentCarryWeight
    $max = Get-MaxCarryWeight $script:Player
    return ($cur -gt $max)
}

# Stamps Weight + Kind onto a loot item. Idempotent.
function Init-ItemWeight {
    param($Item, [string]$Kind = "Loot")
    if(-not $Item){ return $null }
    if(-not $Item.Kind){ $Item.Kind = $Kind }
    if(-not $Item.ContainsKey("Weight")){ $Item.Weight = (Get-ItemWeight $Item) }
    return $Item
}

# ─── GEAR ACQUISITION HELPERS ────────────────────────────────────
# Unified flow for "I just got a weapon/armor — should I equip it now,
# or stow it in my inventory?" Used by all gear sources (shop, merchant,
# encounters, drops). The user picks each time.
#
# If the target slot is empty, auto-equip with no prompt — there's no
# meaningful choice (equipping vs. carrying a useless item with weight).
function Invoke-GearAcquired {
    param(
        $Item,                    # the new item (hashtable)
        [string]$Kind             # "Weapon" or "Armor"
    )
    if(-not $Item){ return }

    if($Kind -eq "Weapon"){
        $currentEquipped = $script:EquippedWeapon
        if(-not $currentEquipped){
            # Slot empty — auto-equip with no prompt
            $script:EquippedWeapon = $Item
            Write-CL "  Equipped: $($Item.Name)" "Green"
            return
        }
        Write-Host ""
        Write-CL "  You already have $($currentEquipped.Name) equipped." "DarkGray"
        Write-CL "  New item: $($Item.Name)" "Yellow"
        Write-Host ""
        Write-CL "    [1] Equip $($Item.Name) now (old goes to inventory)" "Cyan"
        Write-CL "    [2] Stow $($Item.Name) in inventory" "DarkCyan"
        Write-Host ""
        Write-C "    > " "Yellow"
        $c = Read-Host
        if($c -eq "1"){
            # Old equipped goes to inventory; new becomes equipped.
            # Stamp Kind so weight calc works.
            if(-not $currentEquipped.Kind){ $currentEquipped.Kind = "Weapon" }
            [void]$script:Inventory.Add($currentEquipped)
            $script:EquippedWeapon = $Item
            Write-CL "  Equipped $($Item.Name); $($currentEquipped.Name) stowed in bag." "Green"
        } else {
            if(-not $Item.Kind){ $Item.Kind = "Weapon" }
            [void]$script:Inventory.Add($Item)
            Write-CL "  Stowed $($Item.Name) in your bag." "DarkCyan"
        }
        if(Test-Encumbered){
            Write-CL "  -- OVER ENCUMBERED -- you cannot enter dungeons or move on the dungeon grid." "Red"
        }
        return
    }

    if($Kind -eq "Armor"){
        $slot = $Item.Slot
        if(-not $slot){
            # Defensive: shouldn't happen, but fall back to stow
            if(-not $Item.Kind){ $Item.Kind = "Armor" }
            [void]$script:Inventory.Add($Item)
            Write-CL "  Stowed $($Item.Name) in your bag." "DarkCyan"
            return
        }
        $currentEquipped = $script:EquippedArmor[$slot]
        if(-not $currentEquipped){
            $script:EquippedArmor[$slot] = $Item
            Write-CL "  Equipped: $($Item.Name) ($slot)" "Green"
            return
        }
        Write-Host ""
        Write-CL "  You already have $($currentEquipped.Name) equipped in $slot slot." "DarkGray"
        Write-CL "  New item: $($Item.Name)" "Yellow"
        Write-Host ""
        Write-CL "    [1] Equip $($Item.Name) now (old goes to inventory)" "Cyan"
        Write-CL "    [2] Stow $($Item.Name) in inventory" "DarkCyan"
        Write-Host ""
        Write-C "    > " "Yellow"
        $c = Read-Host
        if($c -eq "1"){
            if(-not $currentEquipped.Kind){ $currentEquipped.Kind = "Armor" }
            [void]$script:Inventory.Add($currentEquipped)
            $script:EquippedArmor[$slot] = $Item
            Write-CL "  Equipped $($Item.Name); $($currentEquipped.Name) stowed in bag." "Green"
        } else {
            if(-not $Item.Kind){ $Item.Kind = "Armor" }
            [void]$script:Inventory.Add($Item)
            Write-CL "  Stowed $($Item.Name) in your bag." "DarkCyan"
        }
        if(Test-Encumbered){
            Write-CL "  -- OVER ENCUMBERED -- you cannot enter dungeons or move on the dungeon grid." "Red"
        }
        return
    }
}

# Equip an item already in $script:Inventory by index. The currently
# equipped piece (if any) goes back to inventory. Returns $true on
# success, $false if the index is invalid or the item kind is wrong.
function Invoke-EquipFromInventory {
    param([int]$InvIndex)
    if($InvIndex -lt 0 -or $InvIndex -ge $script:Inventory.Count){
        Write-CL "  Invalid inventory index." "Red"
        return $false
    }
    $item = $script:Inventory[$InvIndex]
    $kind = $item.Kind

    if($kind -eq "Weapon" -or $item.WeaponType){
        $oldWep = $script:EquippedWeapon
        $script:Inventory.RemoveAt($InvIndex)
        if($oldWep){
            if(-not $oldWep.Kind){ $oldWep.Kind = "Weapon" }
            [void]$script:Inventory.Add($oldWep)
            Write-CL "  Equipped $($item.Name); $($oldWep.Name) goes to bag." "Green"
        } else {
            Write-CL "  Equipped $($item.Name)." "Green"
        }
        $script:EquippedWeapon = $item
        return $true
    }
    elseif($kind -eq "Armor" -or $item.Slot){
        $slot = $item.Slot
        if(-not $slot){
            Write-CL "  This item has no armor slot — cannot equip." "Red"
            return $false
        }
        $oldArm = $script:EquippedArmor[$slot]
        $script:Inventory.RemoveAt($InvIndex)
        if($oldArm){
            if(-not $oldArm.Kind){ $oldArm.Kind = "Armor" }
            [void]$script:Inventory.Add($oldArm)
            Write-CL "  Equipped $($item.Name) ($slot); $($oldArm.Name) goes to bag." "Green"
        } else {
            Write-CL "  Equipped $($item.Name) ($slot)." "Green"
        }
        $script:EquippedArmor[$slot] = $item
        return $true
    }
    else {
        Write-CL "  This isn't a weapon or armor — cannot equip." "DarkGray"
        return $false
    }
}

# ─── COMBAT STANCE ───────────────────────────────────────────────
# Aggressive: ATK x1.30 / DEF x0.70 — more damage out, more in
# Balanced  : ATK x1.00 / DEF x1.00 — neutral
# Defensive : ATK x0.70 / DEF x1.30 — less damage out, less in
# Switching is a free action during any combat turn.
function Get-StanceATKMult {
    switch($script:Stance){
        "Aggressive" { 1.30 }
        "Defensive"  { 0.70 }
        default      { 1.00 }
    }
}
function Get-StanceDEFMult {
    switch($script:Stance){
        "Aggressive" { 0.70 }
        "Defensive"  { 1.30 }
        default      { 1.00 }
    }
}
function Get-StanceColor {
    switch($script:Stance){
        "Aggressive" { "Red" }
        "Defensive"  { "Cyan" }
        default      { "Yellow" }
    }
}
function Get-StanceShortLabel {
    switch($script:Stance){
        "Aggressive" { "AGG" }
        "Defensive"  { "DEF" }
        default      { "BAL" }
    }
}

function Get-MaxDurability {
    param($Item)
    if(-not $Item){ return 0 }
    # Dutchman's Blade is cursed — never breaks
    if($Item.Name -eq "Dutchman's Blade"){ return -1 }
    if($Item.ATK){
        return [math]::Max(20, [int]$Item.ATK * 2)
    } elseif($Item.DEF){
        return [math]::Max(15, [int]$Item.DEF * 3)
    }
    return 20
}

# When the player buys or equips a new item, stamp durability fields onto it.
# We clone the hashtable so the shop catalog entries aren't mutated.
function Init-ItemDurability {
    param($Item)
    if(-not $Item){ return $null }
    $max = Get-MaxDurability $Item
    $copy = @{}
    foreach($k in $Item.Keys){ $copy[$k] = $Item[$k] }
    $copy.MaxDurability = $max
    $copy.Durability    = $max  # full on pickup
    return $copy
}

# True if an item is broken (has finite durability and is at 0).
# Dutchman's Blade (MaxDurability = -1) is NEVER broken.
function Test-ItemBroken {
    param($Item)
    if(-not $Item){ return $false }
    if($Item.MaxDurability -lt 0){ return $false }  # indestructible
    if(-not $Item.ContainsKey("Durability")){ return $false }
    return ($Item.Durability -le 0)
}

# Returns a damage-to-durability color for display.
function Get-DurabilityColor {
    param($Item)
    if(-not $Item){ return "DarkGray" }
    if($Item.MaxDurability -lt 0){ return "Magenta" }  # cursed / immortal
    $cur = $Item.Durability
    $max = $Item.MaxDurability
    if($max -le 0){ return "DarkGray" }
    $pct = $cur / $max
    if($cur -le 0)    { return "Red" }
    elseif($pct -le 0.25) { return "DarkRed" }
    elseif($pct -le 0.5)  { return "DarkYellow" }
    else                  { return "Green" }
}

# Build a short durability label like "[42/60]" or "[BROKEN]" or "[∞]".
function Format-Durability {
    param($Item)
    if(-not $Item){ return "" }
    if($Item.MaxDurability -lt 0){ return "[INDESTRUCTIBLE]" }
    if(-not $Item.ContainsKey("Durability")){ return "" }
    if($Item.Durability -le 0){ return "[BROKEN]" }
    return "[$($Item.Durability)/$($Item.MaxDurability)]"
}

# Repair cost: (missing / max) * Price. Dutchman's Blade is never damaged.
function Get-RepairCost {
    param($Item)
    if(-not $Item){ return 0 }
    if($Item.MaxDurability -lt 0){ return 0 }
    $missing = $Item.MaxDurability - $Item.Durability
    if($missing -le 0){ return 0 }
    $price = if($Item.Price){ [int]$Item.Price } else { 50 }
    $cost = [math]::Floor(($missing / $Item.MaxDurability) * $price)
    if($cost -lt 1){ $cost = 1 }
    return $cost
}

function Get-WeaponClassBonus {
    if(-not $script:EquippedWeapon){ return 0 }
    if(Test-ItemBroken $script:EquippedWeapon){ return 0 }
    $w = $script:EquippedWeapon
    # Direct class match (Knight+Knight-affinity sword, Mage+Mage-affinity staff, etc.)
    if($w.ClassAffinity -eq $script:PlayerClass){
        return $w.AffinityBonus
    }
    # Shared-affinity fallbacks: new classes inherit bonuses from a related class
    # because the shop doesn't carry "Berserker"/"Warlock" tagged weapons.
    #   Berserker -> shares sword affinity with Knight
    #   Warlock   -> shares staff affinity with Mage
    $sharedAffinity = switch($script:PlayerClass){
        "Berserker" { "Knight" }
        "Warlock"   { "Mage" }
        default     { $null }
    }
    if($sharedAffinity -and $w.ClassAffinity -eq $sharedAffinity){
        return $w.AffinityBonus
    }
    return 0
}

# True if a weapon's affinity matches the player's class (directly or via shared).
# Used by shop UIs to show "MATCH" / green highlights.
function Test-WeaponClassMatch {
    param($Weapon)
    if(-not $Weapon){ return $false }
    if($Weapon.ClassAffinity -eq $script:PlayerClass){ return $true }
    $sharedAffinity = switch($script:PlayerClass){
        "Berserker" { "Knight" }
        "Warlock"   { "Mage" }
        default     { $null }
    }
    if($sharedAffinity -and $Weapon.ClassAffinity -eq $sharedAffinity){ return $true }
    return $false
}

# Returns total effective weapon ATK (base + class bonus) — 0 if broken
function Get-TotalWeaponATK {
    if(-not $script:EquippedWeapon){ return 0 }
    if(Test-ItemBroken $script:EquippedWeapon){ return 0 }
    return $script:EquippedWeapon.ATK + (Get-WeaponClassBonus)
}

# Returns MAG bonus from weapon (staves grant MAG) — 0 if broken
function Get-WeaponMAGBonus {
    if(-not $script:EquippedWeapon){ return 0 }
    if(Test-ItemBroken $script:EquippedWeapon){ return 0 }
    if($script:EquippedWeapon.MAGBonus){
        return $script:EquippedWeapon.MAGBonus
    }
    return 0
}

# ─── REAL-TIME INPUT (dungeon only) ──────────────────────────────
# All keys (W/A/S/D, P, Q, arrows, etc.) register instantly — no Enter
# required. On each call the queue is drained up front so auto-repeat
# from a previously-held key doesn't cause runaway movement or menu
# double-fire.
#
# Returns an uppercase ASCII character.
function Read-DungeonKey {
    # Discard queued-up keys (stale pre-dungeon input or auto-repeat leftovers).
    while($Host.UI.RawUI.KeyAvailable){
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    while($true){
        if($Host.UI.RawUI.KeyAvailable){
            $k = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            # Arrow keys map to WASD
            switch($k.VirtualKeyCode){
                37 { return 'A' }
                38 { return 'W' }
                39 { return 'D' }
                40 { return 'S' }
            }
            if($k.Character -and $k.Character -ne [char]0){
                $c = [string]$k.Character
                if($c -match '^[A-Za-z0-9]$'){
                    return $c.ToUpper()
                }
            }
        }
        Start-Sleep -Milliseconds 25
    }
}

# Briefly flash a status line (used for animations without a full redraw)
function Flash-Line {
    param([int]$Row,[string]$Text,[string]$Color="White",[int]$Ms=120)
    try {
        $prevPos = $Host.UI.RawUI.CursorPosition
        $pos = New-Object System.Management.Automation.Host.Coordinates 0, $Row
        $Host.UI.RawUI.CursorPosition = $pos
        Write-Host (" " * 70) -NoNewline
        $Host.UI.RawUI.CursorPosition = $pos
        Write-Host $Text -ForegroundColor $Color -NoNewline
        Start-Sleep -Milliseconds $Ms
        $Host.UI.RawUI.CursorPosition = $prevPos
    } catch {
        # Fallback for hosts without cursor positioning
    }
}

# ─── ACHIEVEMENTS ────────────────────────────────────────────────
function Get-AchievementList {
    @(
        @{Id="FirstBlood";     Name="First Blood";         Desc="Defeat your first enemy";              Gold=20;  XP=0;   Req="kills:1"}
        @{Id="Slayer10";       Name="Slayer";              Desc="Defeat 10 enemies";                    Gold=50;  XP=25;  Req="kills:10"}
        @{Id="Slayer50";       Name="Seasoned Slayer";     Desc="Defeat 50 enemies";                    Gold=150; XP=100; Req="kills:50"}
        @{Id="Slayer200";      Name="Exterminator";        Desc="Defeat 200 enemies";                   Gold=500; XP=400; Req="kills:200"}
        @{Id="BossKiller";     Name="Boss Slayer";         Desc="Defeat your first dungeon boss";       Gold=100; XP=50;  Req="bosses:1"}
        @{Id="BossKiller5";    Name="Legendary Hero";      Desc="Defeat 5 dungeon bosses";              Gold=400; XP=300; Req="bosses:5"}
        @{Id="BossKiller10";   Name="Dungeon Master";      Desc="Defeat 10 dungeon bosses";             Gold=1000;XP=750; Req="bosses:10"}
        @{Id="DeepDiver";      Name="Deep Diver";          Desc="Clear dungeon level 5";                Gold=200; XP=150; Req="dungeon:5"}
        @{Id="AbyssWalker";    Name="Abyss Walker";        Desc="Clear dungeon level 10";               Gold=600; XP=500; Req="dungeon:10"}
        @{Id="Wealthy";        Name="Wealthy";             Desc="Accumulate 1000 gold";                 Gold=0;   XP=100; Req="gold:1000"}
        @{Id="Tycoon";         Name="Tycoon";              Desc="Accumulate 5000 gold";                 Gold=0;   XP=500; Req="gold:5000"}
        @{Id="FullPlate";      Name="Knight Errant";       Desc="Equip all 5 armor slots";              Gold=150; XP=100; Req="armor:all"}
        @{Id="Collector";      Name="Collector";           Desc="Own 10 different weapons (in shop history)"; Gold=300;XP=200; Req="weapons:10"}
        @{Id="Streak3";        Name="Hot Streak";          Desc="Clear 3 dungeons in a row without dying";  Gold=200;XP=150; Req="streak:3"}
        @{Id="Streak5";        Name="Unstoppable";         Desc="Clear 5 dungeons in a row without dying";  Gold=500;XP=400; Req="streak:5"}
        @{Id="Lucky";          Name="Luck of the Damned";  Desc="Win the Flying Dutchman coin toss";    Gold=0;   XP=200; Req="event:dutchman"}
        @{Id="Bard";           Name="Musical Soul";        Desc="Meet the Healing Bard";                Gold=30;  XP=25;  Req="event:bard"}
        @{Id="Merchant";       Name="A Rare Deal";         Desc="Buy from the Lost Merchant";           Gold=0;   XP=50;  Req="event:merchant"}
        @{Id="Trainer";        Name="Iron Discipline";     Desc="Spend 500g at the Training Grounds";   Gold=100; XP=100; Req="training:500"}
        @{Id="Master";         Name="Hone of the Master";  Desc="Spend 2000g at the Training Grounds";  Gold=500; XP=500; Req="training:2000"}
        @{Id="QuestGiver";     Name="Loremaster";          Desc="Complete 10 quests";                   Gold=200; XP=250; Req="quests:10"}
        @{Id="DailyDiver";     Name="Daily Grinder";       Desc="Complete the Daily Dungeon";           Gold=150; XP=150; Req="daily:1"}
        # ── New in v1.3 ──
        @{Id="FirstCrit";      Name="Sharp Eye";           Desc="Land your first critical hit";         Gold=30;  XP=25;  Req="crits:1"}
        @{Id="CritMaster";     Name="Crit Master";         Desc="Land 50 critical hits";                Gold=300; XP=250; Req="crits:50"}
        @{Id="CritLord";       Name="Crit Lord";           Desc="Land 200 critical hits";               Gold=800; XP=700; Req="crits:200"}
        @{Id="Locksmith";      Name="Locksmith";           Desc="Pick 10 locks";                        Gold=200; XP=150; Req="lockspicked:10"}
        @{Id="MasterThief";    Name="Master Thief";        Desc="Pick 30 locks";                        Gold=600; XP=500; Req="lockspicked:30"}
        @{Id="PackRat";        Name="Pack Rat";            Desc="Carry 100 weight at once";             Gold=100; XP=100; Req="carry:100"}
        @{Id="Hoarder";        Name="Hoarder";             Desc="Carry 200 weight at once";             Gold=300; XP=300; Req="carry:200"}
        @{Id="IronFist";       Name="Iron Fist";           Desc="Defeat 10 enemies bare-handed";        Gold=400; XP=300; Req="barehands:10"}
        @{Id="UntouchedRun";   Name="Untouched";           Desc="Reach a boss room above 75% HP";       Gold=200; XP=200; Req="untouched:1"}
        @{Id="StanceShifter";  Name="Stance Shifter";      Desc="Switch combat stance 25 times";        Gold=150; XP=150; Req="stanceswaps:25"}
        @{Id="TrueScholar";    Name="True Scholar";        Desc="Complete 25 quests";                   Gold=500; XP=500; Req="quests:25"}
        @{Id="GearGuru";       Name="Gear Guru";           Desc="Repair gear at the blacksmith 10 times"; Gold=150; XP=150; Req="repairs:10"}
        @{Id="HighRoller";     Name="High Roller";         Desc="Accumulate 10000 gold";                Gold=0;   XP=1000; Req="gold:10000"}
        @{Id="DeepestDive";    Name="Deepest Dive";        Desc="Clear dungeon level 20";               Gold=2000; XP=1500; Req="dungeon:20"}
    )
}

function Try-UnlockAchievement {
    param([string]$Id)
    if($script:Achievements.ContainsKey($Id)){ return } # already unlocked
    $list = Get-AchievementList
    $ach = $list | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if(-not $ach){ return }
    $script:Achievements[$Id] = $true
    $script:Gold += $ach.Gold
    $script:XP   += $ach.XP
    # Queue a status message; caller will display it next redraw
    $script:StatusMsg = "ACHIEVEMENT: $($ach.Name) (+$($ach.Gold)g, +$($ach.XP)xp)"
    # Flash immediately too, so combat screens see it
    Write-Host ""
    Write-CL "  ★ ACHIEVEMENT UNLOCKED ★" "Yellow"
    Write-CL "  $($ach.Name) — $($ach.Desc)" "Yellow"
    if($ach.Gold -gt 0){ Write-CL "  +$($ach.Gold) Gold" "DarkYellow" }
    if($ach.XP   -gt 0){ Write-CL "  +$($ach.XP) XP"   "DarkCyan" }
    Start-Sleep -Milliseconds 500
}

# Called in many places to check every achievement's criteria
function Check-Achievements {
    $stats = @{
        kills        = $script:TotalKills
        bosses       = $script:BossesDefeated
        dungeon      = $script:DungeonLevel
        gold         = $script:Gold
        weapons      = $script:WeaponsOwned.Count
        streak       = $script:BestStreak
        training     = 0  # filled below
        quests       = $script:CompletedQuests
        daily        = if($script:DailyDungeonDone){1}else{0}
        # New v1.3 stats
        crits        = $script:TotalCrits
        lockspicked  = $script:TotalLocksPicked
        carry        = (Get-CurrentCarryWeight)
        barehands    = $script:TotalBareKills
        untouched    = $script:TotalUntouched
        stanceswaps  = $script:TotalStanceSwaps
        repairs      = $script:TotalRepairs
    }
    # Training total spent is tracked as sum of TrainingPoints * baseline (approx)
    $trSum = 0
    foreach($k in $script:TrainingPoints.Keys){ $trSum += $script:TrainingPoints[$k] }
    $stats.training = $trSum * 100  # each point roughly cost 100g+

    # Armor completion
    $fullArmor = $true
    foreach($slot in @("Helmet","Chest","Shield","Amulet","Boots")){
        if(-not $script:EquippedArmor[$slot]){ $fullArmor = $false; break }
    }

    foreach($ach in (Get-AchievementList)){
        if($script:Achievements.ContainsKey($ach.Id)){ continue }
        $parts = $ach.Req -split ":"
        $key = $parts[0]; $val = $parts[1]
        $unlock = $false
        if($key -eq "armor" -and $val -eq "all" -and $fullArmor){ $unlock = $true }
        elseif($key -eq "event"){ continue }  # event achievements unlock explicitly
        elseif($stats.ContainsKey($key)){
            $num = [int]$val
            if($stats[$key] -ge $num){ $unlock = $true }
        }
        if($unlock){ Try-UnlockAchievement $ach.Id }
    }
}

function Get-TrainingCost {
    param([string]$Stat)
    # Each level of training costs more than the last. Caps at +10.
    $current = $script:TrainingPoints[$Stat]
    if($current -ge 10){ return -1 }  # maxed
    return 100 + ($current * 50)
}



# ─── LOOT GENERATION ─────────────────────────────────────────────
function New-RandomLoot {
    param([int]$Tier)
    $types = @("Rusty Dagger","Old Ring","Gem Shard","Goblin Ear","Bone Fragment",
               "Silver Pendant","Enchanted Dust","Wyvern Scale","Dark Shard","Ruby Chunk",
               "Golden Idol","Ancient Rune","Dragon Tooth","Shadow Gem","Demon Horn")
    $item = $types | Get-Random
    $value = (Get-Random -Min (5*$Tier) -Max (25*$Tier))
    # Per-item weight overrides — gems/rings are realistically valuable but light;
    # tooth/scale/horn/idol are bulky regardless of value.
    $weight = switch($item){
        "Old Ring"        { 1 }
        "Gem Shard"       { 1 }
        "Silver Pendant"  { 1 }
        "Enchanted Dust"  { 1 }
        "Ruby Chunk"      { 2 }
        "Shadow Gem"      { 1 }
        "Ancient Rune"    { 2 }
        "Goblin Ear"      { 1 }
        "Bone Fragment"   { 2 }
        "Demon Horn"      { 4 }
        "Dragon Tooth"    { 5 }
        "Wyvern Scale"    { 4 }
        "Dark Shard"      { 2 }
        "Golden Idol"     { 6 }
        "Rusty Dagger"    { 4 }
        default           { [math]::Max(1, [math]::Ceiling($value / 30.0)) }
    }
    @{ Name=$item; Value=$value; Tier=$Tier; Kind="Loot"; Weight=[int]$weight }
}

# ─── ENEMY FACTORIES ─────────────────────────────────────────────
# ─── DUNGEON SCALING ─────────────────────────────────────────────
# Enemy levels are now relative to the player's level, with floor/ceiling
# rules that vary by role and dungeon mode.
#
#   Normal dungeon, regular enemy : [PL - 4, PL + 2]
#   Normal dungeon, miniboss/boss : [PL,     PL + 2]   (never below player)
#   Daily dungeon, ALL enemies     : [PL,     PL + 2]   (always at least PL — hard mode)
#
# This makes raw "Dungeon Level" (the floor counter) only matter for ambient
# difficulty backdrop and reward scaling; combat level is anchored to the
# player so a level-15 player isn't farming level-1 dungeons trivially.
function Get-ScaledEnemyLevel {
    param(
        [int]$PlayerLevel,
        [string]$Role = "Regular",   # "Regular", "MiniBoss", "Boss"
        [bool]$IsDaily = $false
    )
    if($IsDaily){
        $minL = $PlayerLevel
        $maxL = $PlayerLevel + 2
    } elseif($Role -eq "MiniBoss" -or $Role -eq "Boss"){
        $minL = $PlayerLevel
        $maxL = $PlayerLevel + 2
    } else {
        $minL = $PlayerLevel - 4
        $maxL = $PlayerLevel + 2
    }
    if($minL -lt 1){ $minL = 1 }
    if($maxL -lt $minL){ $maxL = $minL }
    return Get-Random -Min $minL -Max ($maxL + 1)  # inclusive of $maxL
}

function New-Enemy {
    param([string]$Type,[int]$Lvl)
    # Special case: Mimic mirrors player stats and abilities
    if($Type -eq "Mimic"){
        return New-MimicEnemy $Lvl
    }
    $b = switch ($Type) {
        "Goblin"   {@{HP=28;ATK=8; DEF=3; SPD=10;MAG=2; XP=20; G=Get-Random -Min 5  -Max 20}}
        "Zombie"   {@{HP=42;ATK=10;DEF=6; SPD=3; MAG=1; XP=30; G=Get-Random -Min 8  -Max 25}}
        "Thief"    {@{HP=22;ATK=12;DEF=4; SPD=14;MAG=3; XP=25; G=Get-Random -Min 15 -Max 40}}
        "Wizard"   {@{HP=32;ATK=5; DEF=4; SPD=8; MAG=16;XP=35; G=Get-Random -Min 10 -Max 35}}
        "Troll"    {@{HP=58;ATK=14;DEF=8; SPD=5; MAG=2; XP=45; G=Get-Random -Min 12 -Max 30}}
        "Skeleton" {@{HP=36;ATK=11;DEF=5; SPD=8; MAG=3; XP=32; G=Get-Random -Min 10 -Max 30}}
    }
    $s = 1+($Lvl-1)*0.3
    # Build ability list with cooldowns. Type-specific abilities now include
    # heals or self-buffs at higher levels for variety.
    $abilities = @(
        @{Name="Attack"; Power=0; Type="Normal"; Cooldown=0}
    )
    switch($Type){
        "Wizard"   {
            $abilities += @{Name="Dark Bolt"; Power=12; Type="Magic"; Cooldown=2}
            if($Lvl -ge 3){
                $abilities += @{Name="Arcane Barrier"; Power=0; Type="Buff"; Effect="DEF+4"; Cooldown=4}
            }
        }
        "Troll"    {
            $abilities += @{Name="Smash"; Power=8; Type="Physical"; Cooldown=2}
            if($Lvl -ge 4){
                $abilities += @{Name="Regenerate"; Power=15; Type="Heal"; Cooldown=5}
            }
        }
        "Thief"    {
            $abilities += @{Name="Backstab"; Power=10; Type="Physical"; Cooldown=2}
            if($Lvl -ge 3){
                $abilities += @{Name="Sharpen Blade"; Power=0; Type="Buff"; Effect="ATK+3"; Cooldown=4}
            }
        }
        "Skeleton" {
            $abilities += @{Name="Bone Throw"; Power=9; Type="Physical"; Cooldown=2}
            if($Lvl -ge 5){
                $abilities += @{Name="Marrow Knit"; Power=12; Type="Heal"; Cooldown=5}
            }
        }
        "Zombie"   {
            $abilities += @{Name="Bite"; Power=4; Type="Physical"; Cooldown=2}
            if($Lvl -ge 4){
                $abilities += @{Name="Festering Wound"; Power=0; Type="Buff"; Effect="ATK+2"; Cooldown=4}
            }
        }
        default    {
            $abilities += @{Name="Bite"; Power=4; Type="Physical"; Cooldown=2}
        }
    }
    @{ Name="$Type";DisplayName="$Type (Lv$Lvl)";HP=[math]::Floor($b.HP*$s);MaxHP=[math]::Floor($b.HP*$s)
       ATK=[math]::Floor($b.ATK*$s);DEF=[math]::Floor($b.DEF*$s);SPD=[math]::Floor($b.SPD*$s)
       MAG=[math]::Floor($b.MAG*$s);XP=[math]::Floor($b.XP*$s);Gold=$b.G
       IsBoss=$false;IsMiniBoss=$false;Loot=(New-RandomLoot $Lvl);Stunned=$false;DropsKey=$false
       Abilities=$abilities
    }
}

# Mimic copies the player's class, HP, ATK/DEF/SPD/MAG and hits
# for scaled damage using the player's signature abilities.
# Displays different sprites per class via the "MimicX" keys in Get-EnemyArt.
function New-MimicEnemy {
    param([int]$Lvl)
    $p = $script:Player
    $pc = $script:PlayerClass
    # Scale slightly based on player stats — roughly 85% to feel evenly matched
    $scale = 0.85 + ($Lvl - 1) * 0.05
    if($scale -gt 1.2){ $scale = 1.2 }
    $mimicHP  = [math]::Floor($p.MaxHP * 0.85 * $scale)
    $mimicATK = [math]::Floor(($p.ATK + (Get-TotalWeaponATK)) * 0.9 * $scale)
    $mimicDEF = [math]::Floor(($p.DEF + (Get-TotalArmorDEF)) * 0.85 * $scale)
    $mimicSPD = [math]::Floor($p.SPD * 0.9)
    $mimicMAG = [math]::Floor($p.MAG * 0.9 * $scale)
    if($mimicATK -lt 5){ $mimicATK = 5 }
    if($mimicDEF -lt 3){ $mimicDEF = 3 }
    # Class-specific ability set
    $mimicAbilities = @(@{Name="Attack";Power=0;Type="Normal"})
    switch($pc){
        "Knight"      { $mimicAbilities += @{Name="Shield Bash";Power=12;Type="Physical"} }
        "Mage"        { $mimicAbilities += @{Name="Fireball";   Power=14;Type="Magic"} }
        "Brawler"     { $mimicAbilities += @{Name="Flurry";     Power=11;Type="Physical"} }
        "Ranger"      { $mimicAbilities += @{Name="Piercing Shot";Power=13;Type="Physical"} }
        "Cleric"      { $mimicAbilities += @{Name="Holy Smite"; Power=13;Type="Magic"} }
        "Necromancer" { $mimicAbilities += @{Name="Life Drain"; Power=12;Type="Magic"} }
        "Berserker"   { $mimicAbilities += @{Name="Savage Cleave";Power=16;Type="Physical"} }
        "Warlock"     { $mimicAbilities += @{Name="Eldritch Blast";Power=15;Type="Magic"} }
        default       { $mimicAbilities += @{Name="Mirror Strike";Power=10;Type="Physical"} }
    }
    # Sprite key: "MimicKnight", "MimicMage", etc. If unknown, falls back to "Mimic".
    $mimicSpriteName = "Mimic$pc"
    @{ Name=$mimicSpriteName
       DisplayName="Mimic (masquerading as $pc)"
       HP=$mimicHP; MaxHP=$mimicHP
       ATK=$mimicATK; DEF=$mimicDEF; SPD=$mimicSPD; MAG=$mimicMAG
       XP=[math]::Floor(80 * $scale)
       Gold=(Get-Random -Min 40 -Max 100)
       IsBoss=$false; IsMiniBoss=$false
       Loot=(New-RandomLoot ($Lvl+1))
       Stunned=$false; DropsKey=$false
       Abilities=$mimicAbilities
    }
}

function New-MiniBoss {
    param([int]$Lvl)
    $names=@("Shadow Knight","Dark Shaman","Iron Golem","Venom Queen","Flame Warden","Bone Colossus","Frost Wyrm","Void Sentinel")
    $n=$names|Get-Random
    # Softer scaling: was 1+(Lvl-1)*0.4 — now 1+(Lvl-1)*0.30
    $s = 1 + ($Lvl - 1) * 0.30
    # Equipment drops: 30% weapon, 30% armor (independent rolls). Tier scales with level.
    $weaponDrop = $null; $armorDrop = $null
    if((Get-Random -Max 100) -lt 30){
        $tierMin = [math]::Max(1, $Lvl * 30)
        $tierMax = [math]::Max(150, $Lvl * 70)
        $pool = Get-WeaponShop | Where-Object { $_.Price -ge $tierMin -and $_.Price -le $tierMax }
        if($pool.Count -gt 0){ $weaponDrop = $pool | Get-Random }
    }
    if((Get-Random -Max 100) -lt 30){
        $tierMin = [math]::Max(1, $Lvl * 25)
        $tierMax = [math]::Max(120, $Lvl * 60)
        $pool = Get-ArmorShop | Where-Object { $_.Price -ge $tierMin -and $_.Price -le $tierMax }
        if($pool.Count -gt 0){ $armorDrop = $pool | Get-Random }
    }
    @{ Name=$n;DisplayName="$n [MINI-BOSS]";HP=[math]::Floor(130*$s);MaxHP=[math]::Floor(130*$s)
       ATK=[math]::Floor(18*$s);DEF=[math]::Floor(12*$s);SPD=[math]::Floor(10*$s);MAG=[math]::Floor(12*$s)
       XP=[math]::Floor(150*$s);Gold=(Get-Random -Min 50 -Max 120)
       IsBoss=$false;IsMiniBoss=$true;Loot=(New-RandomLoot ($Lvl+1));Stunned=$false;DropsKey=$true
       WeaponDrop=$weaponDrop; ArmorDrop=$armorDrop
       Abilities=@(
           @{Name="Attack";       Power=0;  Type="Normal";   Cooldown=0}
           @{Name="Power Strike"; Power=15; Type="Physical"; Cooldown=2}
           @{Name="Dark Wave";    Power=12; Type="Magic";    Cooldown=3}
           @{Name="Iron Skin";    Power=0;  Type="Buff";     Effect="DEF+5"; Cooldown=5}
           @{Name="Blood Mend";   Power=20; Type="Heal";                    Cooldown=6}
       )
    }
}

function New-Boss {
    param([int]$Lvl)
    $names=@("Lich King","Dragon Wyrm","Demon Lord","Abyssal Horror","Undead Titan","Shadow Emperor","Plague Bringer","World Eater")
    $n=$names|Get-Random
    # Much softer boss HP scaling; ATK scales slower too.
    # Previous: 1 + (Lvl-1)*0.5 on everything. Now:
    #   HP:  1 + (Lvl-1)*0.35   — was becoming bullet-spongy
    #   ATK: 1 + (Lvl-1)*0.32   — player struggled to survive hits
    $hpScale  = 1 + ($Lvl - 1) * 0.35
    $atkScale = 1 + ($Lvl - 1) * 0.32
    # Boss drops: 50% weapon, 50% armor — bigger tier range
    $weaponDrop = $null; $armorDrop = $null
    if((Get-Random -Max 100) -lt 50){
        $tierMin = [math]::Max(50, $Lvl * 50)
        $tierMax = [math]::Max(300, $Lvl * 120)
        $pool = Get-WeaponShop | Where-Object { $_.Price -ge $tierMin -and $_.Price -le $tierMax }
        if($pool.Count -gt 0){ $weaponDrop = $pool | Get-Random }
    }
    if((Get-Random -Max 100) -lt 50){
        $tierMin = [math]::Max(40, $Lvl * 40)
        $tierMax = [math]::Max(250, $Lvl * 100)
        $pool = Get-ArmorShop | Where-Object { $_.Price -ge $tierMin -and $_.Price -le $tierMax }
        if($pool.Count -gt 0){ $armorDrop = $pool | Get-Random }
    }
    @{ Name=$n;DisplayName=">>> $n [DUNGEON BOSS] <<<";HP=[math]::Floor(260*$hpScale);MaxHP=[math]::Floor(260*$hpScale)
       ATK=[math]::Floor(24*$atkScale);DEF=[math]::Floor(16*$hpScale);SPD=[math]::Floor(12*$atkScale);MAG=[math]::Floor(16*$atkScale)
       XP=[math]::Floor(400*$hpScale);Gold=(Get-Random -Min 100 -Max 250) + $Lvl * 40
       IsBoss=$true;IsMiniBoss=$false;Loot=(New-RandomLoot ($Lvl+2));Stunned=$false;DropsKey=$false
       WeaponDrop=$weaponDrop; ArmorDrop=$armorDrop
       # Telegraph: $TelegraphNext flags that next turn a big move is coming, giving player a chance to defend.
       TelegraphNext=$false
       Abilities=@(
           @{Name="Attack";        Power=0;  Type="Normal";   Cooldown=0}
           @{Name="Devastate";     Power=20; Type="Physical"; Cooldown=3}
           @{Name="Soul Drain";    Power=18; Type="Magic";    Cooldown=3}
           @{Name="Inferno";       Power=25; Type="Magic";    Cooldown=4}
           @{Name="Boss Roar";     Power=0;  Type="Buff";     Effect="ATK+6"; Cooldown=5}
           @{Name="Dark Mending";  Power=30; Type="Heal";                    Cooldown=7}
       )
    }
}

# ─── DUNGEON GENERATION ──────────────────────────────────────────
function New-Dungeon {
    param([int]$Level)
    $w=21; $h=21
    $grid = New-Object 'int[,]' $h,$w
    for($y=0;$y -lt $h;$y++){for($x=0;$x -lt $w;$x++){$grid[$y,$x]=1}}

    # Generate rooms
    $rooms=[System.Collections.ArrayList]@()
    $att=0; $target=6+[math]::Min($Level,4)
    while($rooms.Count -lt $target -and $att -lt 300){
        $att++
        $rw=Get-Random -Min 3 -Max 7; $rh=Get-Random -Min 3 -Max 6
        $rx=Get-Random -Min 1 -Max ($w-$rw-1); $ry=Get-Random -Min 1 -Max ($h-$rh-1)
        $ok=$true
        foreach($r in $rooms){
            if($rx -lt ($r.X+$r.W+1) -and ($rx+$rw) -gt ($r.X-1) -and
               $ry -lt ($r.Y+$r.H+1) -and ($ry+$rh) -gt ($r.Y-1)){$ok=$false;break}
        }
        if(-not $ok){continue}
        for($y=$ry;$y -lt ($ry+$rh);$y++){for($x=$rx;$x -lt ($rx+$rw);$x++){$grid[$y,$x]=0}}
        [void]$rooms.Add(@{X=$rx;Y=$ry;W=$rw;H=$rh;CX=[math]::Floor($rx+$rw/2);CY=[math]::Floor($ry+$rh/2)})
    }

    # Connect rooms with corridors
    for($i=0;$i -lt $rooms.Count-1;$i++){
        $a=$rooms[$i];$b=$rooms[$i+1]
        $cx=$a.CX;$cy=$a.CY;$tx=$b.CX;$ty=$b.CY
        if((Get-Random -Max 2)-eq 0){
            while($cx-ne $tx){$grid[$cy,$cx]=0;$cx+=if($tx-gt $cx){1}else{-1}}
            while($cy-ne $ty){$grid[$cy,$cx]=0;$cy+=if($ty-gt $cy){1}else{-1}}
        }else{
            while($cy-ne $ty){$grid[$cy,$cx]=0;$cy+=if($ty-gt $cy){1}else{-1}}
            while($cx-ne $tx){$grid[$cy,$cx]=0;$cx+=if($tx-gt $cx){1}else{-1}}
        }
        $grid[$ty,$tx]=0
    }

    # Place entities  (0=floor,1=wall,2=enemy,3=miniboss,4=boss,5=exit,6=treasure)
    # Weighted enemy pool: Skeleton is mid-rare, Mimic is rare (shows up ~once per dungeon)
    $eTypes=@("Goblin","Goblin","Zombie","Zombie","Thief","Wizard","Troll","Skeleton","Skeleton")
    # Mimic has a chance to spawn per dungeon (small), added separately below
    $enemies=@{}
    for($i=1;$i -lt [math]::Max($rooms.Count-2,1);$i++){
        $r=$rooms[$i]; $ne=Get-Random -Min 1 -Max 4
        for($e=0;$e -lt $ne;$e++){
            $ex=Get-Random -Min $r.X -Max ($r.X+$r.W)
            $ey=Get-Random -Min $r.Y -Max ($r.Y+$r.H)
            if($grid[$ey,$ex]-eq 0){
                $grid[$ey,$ex]=2
                # Use scaled level relative to player, not raw dungeon floor
                $spawnLvl = Get-ScaledEnemyLevel -PlayerLevel $script:PlayerLevel -Role "Regular" -IsDaily $script:DailyDungeonActive
                # ~5% chance this slot is a Mimic instead of a regular enemy
                if((Get-Random -Max 100) -lt 5){
                    $enemies["$ex,$ey"]=New-Enemy "Mimic" $spawnLvl
                } else {
                    $enemies["$ex,$ey"]=New-Enemy ($eTypes|Get-Random) $spawnLvl
                }
            }
        }
        if((Get-Random -Max 100)-lt 40){
            $tx2=Get-Random -Min $r.X -Max ($r.X+$r.W)
            $ty2=Get-Random -Min $r.Y -Max ($r.Y+$r.H)
            if($grid[$ty2,$tx2]-eq 0){$grid[$ty2,$tx2]=6}
        }
    }

    # Mini-boss in second-to-last room
    if($rooms.Count -ge 3){
        $mbR=$rooms[$rooms.Count-2]; $grid[$mbR.CY,$mbR.CX]=3
        $mbLvl = Get-ScaledEnemyLevel -PlayerLevel $script:PlayerLevel -Role "MiniBoss" -IsDaily $script:DailyDungeonActive
        $enemies["$($mbR.CX),$($mbR.CY)"]=New-MiniBoss $mbLvl
    }
    # Boss in last room
    $bR=$rooms[$rooms.Count-1]; $grid[$bR.CY,$bR.CX]=4
    $bossLvl = Get-ScaledEnemyLevel -PlayerLevel $script:PlayerLevel -Role "Boss" -IsDaily $script:DailyDungeonActive
    $enemies["$($bR.CX),$($bR.CY)"]=New-Boss $bossLvl
    # Exit
    $placed=$false
    for($y=$bR.Y;$y -lt $bR.Y+$bR.H -and !$placed;$y++){
        for($x=$bR.X;$x -lt $bR.X+$bR.W -and !$placed;$x++){
            if($grid[$y,$x]-eq 0){$grid[$y,$x]=5;$placed=$true}
        }
    }

        # Place rescue NPC if player has an active Rescue quest
    $hasRescueQuest = $false
    foreach($q in $script:Quests){
        if($q.Type -eq "Rescue" -and -not $q.Complete -and -not $q.TurnedIn){
            $hasRescueQuest = $true; break
        }
    }
    if($hasRescueQuest -and $rooms.Count -ge 3){
        $rescueRoom = $rooms[(Get-Random -Min 1 -Max ($rooms.Count - 2))]
        $rx2 = Get-Random -Min $rescueRoom.X -Max ($rescueRoom.X + $rescueRoom.W)
        $ry2 = Get-Random -Min $rescueRoom.Y -Max ($rescueRoom.Y + $rescueRoom.H)
        if($grid[$ry2,$rx2] -eq 0){
            $grid[$ry2,$rx2] = 7
        }
    }


    $startR=$rooms[0]
    # Fog of war: 2D bool array tracking which tiles the player has seen.
    # All false initially. Render-Screen reveals tiles around the player each turn.
    $seen = New-Object 'bool[,]' $h, $w
    @{Grid=$grid;W=$w;H=$h;Rooms=$rooms;Enemies=$enemies
      PX=$startR.CX;PY=$startR.CY;PDir=0;HasBossKey=$false;BossDefeated=$false
      Seen=$seen}
}
function Get-Cell {
    param($d,$dx,$dy)
    if($dx -lt 0 -or $dx -ge $d.W -or $dy -lt 0 -or $dy -ge $d.H){return 1}
    $v=$d.Grid[$dy,$dx]
    if($v -eq 1){return 1}else{return 0}
}

function Get-Forward {
    param($dir,$dist)
    switch($dir){
        0{@(0,-$dist)}
        1{@($dist,0)}
        2{@(0,$dist)}
        3{@(-$dist,0)}
    }
}

function Get-Left {
    param($dir,$dist)
    switch($dir){
        0{@(-$dist,0)}
        1{@(0,-$dist)}
        2{@($dist,0)}
        3{@(0,$dist)}
    }
}

# ─── 3D RENDERER ─────────────────────────────────────────────────
function Render-Screen {
    $d=$script:Dungeon; $px=$d.PX; $py=$d.PY; $pdir=$d.PDir
    $p=$script:Player
    # Expanded viewport: was 42x21, now 56x24 (+33% area)
    $vw=56; $vh=24

    # ── Box-drawing chars ──
    $chVLine = [char]0x2502
    $chHLine = [char]0x2500
    $chTL    = [char]0x250C
    $chTR    = [char]0x2510
    $chBL    = [char]0x2514
    $chBR    = [char]0x2518
    $chCross = [char]0x256C
    $chHalfU = [char]0x2580  # ▀  upper half block  (top cell lit, bottom dark)
    $chHalfL = [char]0x2584  # ▄  lower half block  (bottom cell lit, top dark)
    $chFull  = [char]0x2588  # █  full block
    $chShadeL= [char]0x2591  # ░  light shade
    $chShadeM= [char]0x2592  # ▒  medium shade
    $chShadeD= [char]0x2593  # ▓  dark shade
    $chDot   = [char]0x00B7  # ·  middle dot (floor texture)

    # ── Build 3D view buffer ──
    $buf   = New-Object 'char[,]'   $vh,$vw
    $fgbuf = New-Object 'string[,]' $vh,$vw
    $bgbuf = New-Object 'string[,]' $vh,$vw

    $halfY = [math]::Floor($vh/2)
    for($y=0;$y -lt $vh;$y++){for($x=0;$x -lt $vw;$x++){
        $buf[$y,$x]   = ' '
        $fgbuf[$y,$x] = "White"
        if($y -lt $halfY){ $bgbuf[$y,$x] = "Black" }         # ceiling: black
        else             { $bgbuf[$y,$x] = "DarkGray" }      # floor: dark gray
    }}

    # ── Floor checkerboard texture ──
    # Adds depth cues on the floor using middle-dots spaced by distance from camera
    for($y=$halfY;$y -lt $vh;$y++){
        # rows closer to bottom = nearer = denser pattern
        $closeness = $y - $halfY
        # Use alternating pattern per player position so walking feels like scrolling
        $phase = ($px + $py + $pdir) % 4
        for($x=0;$x -lt $vw;$x++){
            if((($x + $closeness + $phase) % 6) -eq 0){
                $buf[$y,$x] = $chDot
                $fgbuf[$y,$x] = "DarkYellow"
            }
        }
    }
    # Ceiling speckle (faint stars / stone bits)
    for($y=0;$y -lt $halfY;$y++){
        for($x=0;$x -lt $vw;$x++){
            if((($x * 7 + $y * 3 + $px * 2 + $py) % 37) -eq 0){
                $buf[$y,$x] = $chDot
                $fgbuf[$y,$x] = "DarkGray"
            }
        }
    }

    # 5 depth layers (same count, but wider/taller to fit larger viewport)
    $bounds = @(
        @{L=0; R=55;T=0; B=23},
        @{L=7; R=48;T=3; B=20},
        @{L=14;R=41;T=6; B=17},
        @{L=20;R=35;T=9; B=14},
        @{L=24;R=31;T=10;B=13}
    )

    # Background fog per depth (near -> far)
    $shadeBG    = @("DarkCyan","DarkBlue","DarkBlue","Black","Black")
    # Edge foreground per depth (gradient for fog effect)
    $shadeEdgeFG = @("White","Cyan","Gray","DarkGray","DarkGray")
    # Wall fill shade character per depth (near is full, far is stippled for fog)
    $shadeFill   = @(' ',' ',$chShadeL,$chShadeM,$chShadeD)

    for($depth=4;$depth -ge 1;$depth--){
        $fwd=Get-Forward $pdir $depth
        $fdx=$px+$fwd[0]; $fdy=$py+$fwd[1]
        $leftOff=Get-Left $pdir 1
        $lx=$fdx+$leftOff[0]; $ly=$fdy+$leftOff[1]
        $rx=$fdx-$leftOff[0]; $ry=$fdy-$leftOff[1]
        $wallAhead=(Get-Cell $d $fdx $fdy)-eq 1
        $wallLeft =(Get-Cell $d $lx $ly)-eq 1
        $wallRight=(Get-Cell $d $rx $ry)-eq 1
        $outer=$bounds[$depth-1]; $inner=$bounds[$depth]
        $bg  = $shadeBG[$depth]
        $efg = $shadeEdgeFG[$depth]
        $fillCh = $shadeFill[$depth]

        if($wallAhead){
            # Fill wall face
            for($y=$inner.T;$y -le $inner.B;$y++){
                for($x=$inner.L;$x -le $inner.R;$x++){
                    $buf[$y,$x]=$fillCh; $fgbuf[$y,$x]=$efg; $bgbuf[$y,$x]=$bg
                }
            }
            # Stone block texture lines (horizontal brick effect)
            $brickRow1 = $inner.T + [math]::Floor(($inner.B-$inner.T)/3)
            $brickRow2 = $inner.T + [math]::Floor(($inner.B-$inner.T)*2/3)
            if($depth -le 2){
                for($x=$inner.L+1;$x -lt $inner.R;$x++){
                    $buf[$brickRow1,$x]=[char]0x2500
                    $fgbuf[$brickRow1,$x]="DarkGray"
                    $bgbuf[$brickRow1,$x]=$bg
                    $buf[$brickRow2,$x]=[char]0x2500
                    $fgbuf[$brickRow2,$x]="DarkGray"
                    $bgbuf[$brickRow2,$x]=$bg
                }
            }
            # Door handle
            $midX=[math]::Floor(($inner.L+$inner.R)/2)
            $midY=[math]::Floor(($inner.T+$inner.B)/2)
            if(($inner.R-$inner.L)-gt 4){
                $buf[$midY,$midX]=$chCross; $fgbuf[$midY,$midX]="White"; $bgbuf[$midY,$midX]=$bg
            }
            # Horizontal edges
            for($x=$inner.L;$x -le $inner.R;$x++){
                $buf[$inner.T,$x]=$chHLine; $fgbuf[$inner.T,$x]="White"; $bgbuf[$inner.T,$x]=$bg
                $buf[$inner.B,$x]=$chHLine; $fgbuf[$inner.B,$x]="White"; $bgbuf[$inner.B,$x]=$bg
            }
            # Corners
            $buf[$inner.T,$inner.L]=$chTL; $fgbuf[$inner.T,$inner.L]="White"; $bgbuf[$inner.T,$inner.L]=$bg
            $buf[$inner.T,$inner.R]=$chTR; $fgbuf[$inner.T,$inner.R]="White"; $bgbuf[$inner.T,$inner.R]=$bg
            $buf[$inner.B,$inner.L]=$chBL; $fgbuf[$inner.B,$inner.L]="White"; $bgbuf[$inner.B,$inner.L]=$bg
            $buf[$inner.B,$inner.R]=$chBR; $fgbuf[$inner.B,$inner.R]="White"; $bgbuf[$inner.B,$inner.R]=$bg
        }

        if($wallLeft){
            # Fill left side wall
            for($y=$inner.T;$y -le $inner.B;$y++){
                for($x=$outer.L;$x -lt $inner.L;$x++){
                    $buf[$y,$x]=$fillCh; $fgbuf[$y,$x]=$efg; $bgbuf[$y,$x]=$bg
                }
            }
            # Diagonal top fill
            $dT=$inner.T-$outer.T; $dX=$inner.L-$outer.L
            if($dT -gt 0){
                for($row=$outer.T;$row -lt $inner.T;$row++){
                    $frac=($row-$outer.T)/$dT
                    $xEnd=[math]::Floor($outer.L+$frac*$dX)
                    for($x=$outer.L;$x -le $xEnd;$x++){
                        $buf[$row,$x]=$fillCh; $fgbuf[$row,$x]=$efg; $bgbuf[$row,$x]=$bg
                    }
                }
                # Diagonal bottom fill
                $dB=$outer.B-$inner.B
                if($dB -gt 0){
                    for($row=($inner.B+1);$row -le $outer.B;$row++){
                        $frac=($outer.B-$row)/$dB
                        $xEnd=[math]::Floor($outer.L+$frac*$dX)
                        for($x=$outer.L;$x -le $xEnd;$x++){
                            $buf[$row,$x]=$fillCh; $fgbuf[$row,$x]=$efg; $bgbuf[$row,$x]=$bg
                        }
                    }
                }
            }
            # Left vertical edge
            for($y=$inner.T;$y -le $inner.B;$y++){
                $buf[$y,$inner.L]=$chVLine; $fgbuf[$y,$inner.L]="White"; $bgbuf[$y,$inner.L]=$bg
            }
            # Torch on left wall (only nearest layer, only sometimes)
            if($depth -eq 1 -and (($px + $py + $pdir * 3) % 3) -eq 0){
                $torchRow = $inner.T + 2
                $torchCol = [math]::Floor(($outer.L + $inner.L) / 2)
                if($torchRow -lt $inner.B -and $torchCol -lt $inner.L){
                    # Flicker between two chars based on player position for cheap animation
                    $flicker = if((($px + $py) % 2) -eq 0){"*"}else{"^"}
                    $buf[$torchRow,$torchCol] = [char]$flicker
                    $fgbuf[$torchRow,$torchCol] = "Yellow"
                    # Glow above
                    if($torchRow-1 -ge 0){
                        $buf[($torchRow-1),$torchCol] = [char]0x00B0
                        $fgbuf[($torchRow-1),$torchCol] = "DarkYellow"
                    }
                }
            }
        }

        if($wallRight){
            # Fill right side wall
            for($y=$inner.T;$y -le $inner.B;$y++){
                for($x=($inner.R+1);$x -le $outer.R;$x++){
                    $buf[$y,$x]=$fillCh; $fgbuf[$y,$x]=$efg; $bgbuf[$y,$x]=$bg
                }
            }
            # Diagonal top fill
            $dT=$inner.T-$outer.T; $dX=$outer.R-$inner.R
            if($dT -gt 0){
                for($row=$outer.T;$row -lt $inner.T;$row++){
                    $frac=($row-$outer.T)/$dT
                    $xStart=[math]::Floor($outer.R-$frac*$dX)
                    for($x=$xStart;$x -le $outer.R;$x++){
                        $buf[$row,$x]=$fillCh; $fgbuf[$row,$x]=$efg; $bgbuf[$row,$x]=$bg
                    }
                }
                # Diagonal bottom fill
                $dB=$outer.B-$inner.B
                if($dB -gt 0){
                    for($row=($inner.B+1);$row -le $outer.B;$row++){
                        $frac=($outer.B-$row)/$dB
                        $xStart=[math]::Floor($outer.R-$frac*$dX)
                        for($x=$xStart;$x -le $outer.R;$x++){
                            $buf[$row,$x]=$fillCh; $fgbuf[$row,$x]=$efg; $bgbuf[$row,$x]=$bg
                        }
                    }
                }
            }
            # Right vertical edge
            for($y=$inner.T;$y -le $inner.B;$y++){
                $buf[$y,$inner.R]=$chVLine; $fgbuf[$y,$inner.R]="White"; $bgbuf[$y,$inner.R]=$bg
            }
            # Right-wall torch
            if($depth -eq 1 -and (($px * 2 + $py + $pdir) % 3) -eq 0){
                $torchRow = $inner.T + 2
                $torchCol = [math]::Floor(($outer.R + $inner.R) / 2)
                if($torchRow -lt $inner.B -and $torchCol -gt $inner.R){
                    $flicker = if((($px + $py) % 2) -eq 0){"^"}else{"*"}
                    $buf[$torchRow,$torchCol] = [char]$flicker
                    $fgbuf[$torchRow,$torchCol] = "Yellow"
                    if($torchRow-1 -ge 0){
                        $buf[($torchRow-1),$torchCol] = [char]0x00B0
                        $fgbuf[($torchRow-1),$torchCol] = "DarkYellow"
                    }
                }
            }
        }
    }
        # ── Entity sprite (bigger, more detailed) ──
    $fwd1=Get-Forward $pdir 1; $ax=$px+$fwd1[0]; $ay=$py+$fwd1[1]
    $cellAhead=if($ax -ge 0 -and $ax -lt $d.W -and $ay -ge 0 -and $ay -lt $d.H){$d.Grid[$ay,$ax]}else{1}
    if($cellAhead -ge 2 -and $cellAhead -le 7 -and (Get-Cell $d $ax $ay)-eq 0){
        $eColor=switch($cellAhead){2{"Red"}3{"Magenta"}4{"DarkRed"}5{"Green"}6{"Yellow"}7{"Yellow"}default{"White"}}
        # New larger sprites (10w x 7h) with more detail
        $sprites=@{
            2=@(
                "   .--.   ",
                "  /o  o\  ",
                " | (>>) | ",
                "  \ ^^ /  ",
                "  /|__|\  ",
                " d |  | b ",
                "   /  \   "
            )
            3=@(
                "  [____]  ",
                "  [XMBX]  ",
                " {|OOOO|} ",
                "  |****|  ",
                "  /|==|\  ",
                " // || \\ ",
                "  /    \  "
            )
            4=@(
                " {><oo><} ",
                " |BOSS!!!| ",
                "/  @  @  \ ",
                "|  /\/\  | ",
                "|  |XX|  | ",
                " \ \--/ / ",
                " /|    |\ "
            )
            5=@(
                "  ______  ",
                " |DDDDDD| ",
                " |D EXIT D| ",
                " |D >>>> D| ",
                " |DDDDDDD| ",
                " |______| ",
                "  ||__||  "
            )
            6=@(
                "  ._____________. ",
                " /    .-===-.    \",
                "/___| |###| |___\ ",
                "|   | '---' |   | ",
                "|   '-------'   | ",
                "|_______________| ",
                "\_______________/ "
            )
            7=@(
                "   /\     ",
                "  /  \    ",
                " | ?? |   ",
                " | HELP|  ",
                "  \__/    ",
                "  /||\    ",
                " / || \   "
            )
        }
        $sprite=$sprites[$cellAhead]
        if($sprite){
            $midX=[math]::Floor($vw/2); $midY=[math]::Floor($vh/2)
            $sy=$midY-[math]::Floor($sprite.Count/2)
            foreach($line in $sprite){
                $sx=$midX-[math]::Floor($line.Length/2)
                for($ci=0;$ci -lt $line.Length;$ci++){
                    $col=$sx+$ci
                    $inBounds = ($col -ge 0 -and $col -lt $vw -and $sy -ge 0 -and $sy -lt $vh)
                    if(-not $inBounds){ continue }
                    if($line[$ci] -ne ' '){
                        # Draw this sprite glyph (wall-face chars under it are overwritten)
                        $buf[$sy,$col]=$line[$ci]
                        $fgbuf[$sy,$col]=$eColor
                    } else {
                        # Space in the sprite: also clear any wall-face chars (│ ─ etc.)
                        # from the buffer so the dungeon wall's outline doesn't bleed
                        # through the sprite's negative space. Background stays as-is
                        # (so depth fog / wall fill still shows through transparently).
                        $under = $buf[$sy,$col]
                        if($under -ne ' '){
                            $buf[$sy,$col] = ' '
                        }
                    }
                }
                $sy++
            }
        }
    }

    # ── Fog of war: reveal tiles within sight radius around player ──
    # Lazy-init Seen for any dungeons that pre-date the field (loaded saves)
    if(-not $d.Seen){
        $d.Seen = New-Object 'bool[,]' $d.H, $d.W
    }
    $sightR = 3   # reveal a 7x7 area around the player each render
    for($dy=-$sightR;$dy -le $sightR;$dy++){
        for($dx=-$sightR;$dx -le $sightR;$dx++){
            $mx = $d.PX + $dx; $my = $d.PY + $dy
            if($mx -ge 0 -and $mx -lt $d.W -and $my -ge 0 -and $my -lt $d.H){
                $d.Seen[$my, $mx] = $true
            }
        }
    }

    # ── Build minimap lines: windowed view centered on player, with fog ──
    # 11x21 window keeps the right panel within the 3D viewport's 24 rows.
    $dirChar = switch($d.PDir){0{'^'}1{'>'}2{'v'}3{'<'}}
    $mapLines = [System.Collections.ArrayList]@()
    [void]$mapLines.Add("  MAP ")
    $mapR = 5    # half-radius (window is (2R+1) tall)
    $mapW = 10   # half-width (window is (2W+1) wide)
    for($dy=-$mapR; $dy -le $mapR; $dy++){
        $ml = ""
        for($dx=-$mapW; $dx -le $mapW; $dx++){
            $mx = $d.PX + $dx
            $my = $d.PY + $dy
            if($mx -lt 0 -or $mx -ge $d.W -or $my -lt 0 -or $my -ge $d.H){
                $ml += " "  # outside dungeon bounds
            } elseif($mx -eq $d.PX -and $my -eq $d.PY){
                $ml += $dirChar
            } elseif(-not $d.Seen[$my, $mx]){
                $ml += "·"  # fog
            } else {
                $c = $d.Grid[$my, $mx]
                $ml += switch($c){1{"#"} 0{"."} 2{"!"} 3{"M"} 4{"B"} 5{">"} 6{"$"} 7{"?"} default{" "}}
            }
        }
        [void]$mapLines.Add($ml)
    }
    # ── Build HUD lines ──
    $dirNames=@("North","East","South","West")
    $wAtk = Get-TotalWeaponATK
    $aDef = Get-TotalArmorDEF
    $mBonus = Get-WeaponMAGBonus
    $hpPct=$p.HP/$p.MaxHP
    $hpBar="+" * [math]::Max([math]::Floor($hpPct*15),0)
    $hpBar+="-" * (15 - $hpBar.Length)
    $mpBar="+" * [math]::Max([math]::Floor(($p.MP/$p.MaxMP)*15),0)
    $mpBar+="-" * (15 - $mpBar.Length)

    $wepName = if($script:EquippedWeapon){$script:EquippedWeapon.Name}else{"Bare Hands"}
    $wepPerk = if($script:EquippedWeapon -and $script:EquippedWeapon.Perk){" [$($script:EquippedWeapon.Perk)]"}else{""}

    $hudCurW = Get-CurrentCarryWeight
    $hudMaxW = Get-MaxCarryWeight $p
    $hudLines = @(
        "",
        " $($p.Name) Lv$($script:PlayerLevel)",
        " HP[$hpBar] $($p.HP)/$($p.MaxHP)",
        " MP[$mpBar] $($p.MP)/$($p.MaxMP)",
        " ATK:$($p.ATK+$wAtk) DEF:$($p.DEF+$aDef) SPD:$($p.SPD)",
        " MAG:$($p.MAG+$mBonus) Gold:$($script:Gold)",
        " Facing: $($dirNames[$d.PDir])",
        " XP: $($script:XP)/$($script:XPToNext)",
        " Wpn: $wepName$wepPerk",
        " Armor DEF: +$aDef",
        " Lockpicks: $($script:Lockpicks)",
        " Carry: $hudCurW/$hudMaxW"
    )
    # Note: streak no longer displayed in dungeon HUD — it crowded the boss key
    # indicator. Streak is still tracked and shown on the stats page.
    if($script:HasBossKey){ $hudLines += " >> BOSS KEY <<" }
    if($script:Partner){ $hudLines += " Ally: $($script:Partner.Name)" }
    # Active quests are no longer shown inline. Press [J] in dungeon to view
    # the full quest log with progress bars.

    # ── Combine: right panel = minimap then HUD ──
    $rightLines = [System.Collections.ArrayList]@()
    foreach($ml in $mapLines){ [void]$rightLines.Add($ml) }
    foreach($hl in $hudLines){ [void]$rightLines.Add($hl) }
    # ── Render combined output (uses frame buffer if Buffered mode is on) ──
    # When buffered, calls go to Buf-Write and Flush-Frame paints only changes.
    # Otherwise they fall through to direct host writes via Write-C/Write-CL.
    $separator = "  | "
    $maxY = $vh
    if($rightLines.Count -gt $maxY){ $maxY = $rightLines.Count }
    for($y=0;$y -lt $maxY;$y++){
        if($y -lt $vh){
            for($x=0;$x -lt $vw;$x++){
                Write-C ([string]$buf[$y,$x]) $fgbuf[$y,$x] $bgbuf[$y,$x]
            }
        } else {
            # Pad blank where the 3D view has ended but the right panel continues
            Write-C (' ' * $vw) "Gray"
        }
        Write-C $separator "DarkGray"
        if($y -lt $rightLines.Count){
            $rl = $rightLines[$y]
            if($y -eq 0){
                Write-C $rl "DarkYellow"
            }
            elseif($y -ge 1 -and $y -lt $mapLines.Count){
                # Per-character coloring of the minimap row
                for($ci=0;$ci -lt $rl.Length;$ci++){
                    $ch = $rl[$ci]
                    $cc = switch($ch){
                        '#' {"DarkBlue"}
                        '.' {"DarkGray"}
                        '!' {"Red"}
                        'M' {"Magenta"}
                        'B' {"DarkRed"}
                        '$' {"Yellow"}
                        '?' {"Yellow"}
                        '^' {"Green"}
                        'v' {"Green"}
                        '<' {"Green"}
                        '>' {"Green"}
                        '·' {"DarkGray"}    # fog of war
                        default {"DarkGray"}
                    }
                    Write-C ([string]$ch) $cc
                }
            }
            elseif($rl -match "HP\["){
                for($ci=0;$ci -lt $rl.Length;$ci++){
                    $ch=$rl[$ci]
                    if($ch -eq '+'){
                        $hpC = if($hpPct -gt 0.5){"Green"}elseif($hpPct -gt 0.25){"Yellow"}else{"Red"}
                        Write-C "+" $hpC
                    }
                    elseif($ch -eq '-'){ Write-C "-" "DarkGray" }
                    else{ Write-C ([string]$ch) "White" }
                }
            }
            elseif($rl -match "MP\["){
                for($ci=0;$ci -lt $rl.Length;$ci++){
                    $ch=$rl[$ci]
                    if($ch -eq '+'){ Write-C "+" "Cyan" }
                    elseif($ch -eq '-'){ Write-C "-" "DarkGray" }
                    else{ Write-C ([string]$ch) "White" }
                }
            }
            elseif($rl -match "BOSS KEY"){ Write-C $rl "Magenta" }
            elseif($rl -match "Quest:"){ Write-C $rl "Cyan" }
            elseif($rl -match "Carry:"){
                $carryColor = if(Test-Encumbered){"Red"}else{"DarkGray"}
                Write-C $rl $carryColor
            }
            elseif($rl -match "Facing:|Gold:|ATK:|MAG:|XP:|Wpn:|Armor DEF:|Hit:|Ally:|Lockpicks:"){
                Write-C $rl "DarkGray"
            }
            else{ Write-C $rl "Gray" }
        }
        Write-CL "" "Gray"
    }
    Write-CL ("="*80) "DarkYellow"
    if($script:StatusMsg){
        Write-CL "  $($script:StatusMsg)" "Yellow"
        $script:StatusMsg = ""
    }
}




# ─── COMBAT SYSTEM ───────────────────────────────────────────────
function Get-EnemyArt {
    param([string]$Type)
    # Bigger, more detailed sprites (16 wide x 10+ tall)
    # Uses half-block chars ▀▄█ and shade ▒▓░ for more detail on a PS 5.1 console
    switch($Type){
        "Goblin" { @(
            "       ,      ,      ",
            "      /(      )\     ",
            "     (  \_/\_/  )    ",
            "      \  >..<  /     ",
            "      | (>><<) |     ",
            "       \  \/  /      ",
            "        '-..-'       ",
            "       /|    |\      ",
            "      / |    | \     ",
            "     /  |    |  \    ",
            "        /_\__/_\     ",
            "        |_|  |_|     "
        )}
        "Zombie" { @(
            "      .--''--.       ",
            "     /  x  x   \     ",
            "    | .-'--'-.  |    ",
            "    |(  ____  ) |    ",
            "    | |UUUUUU| |     ",
            "     \|______|/      ",
            "    __/|    |\__     ",
            "   /  /|____|\  \    ",
            "  |  / |    | \  |   ",
            "  | /  |    |  \ |   ",
            "    |  |    |  |     ",
            "    |__|    |__|     ",
            "   /___\    /___\    "
        )}
        "Thief" { @(
            "      .-==~==-.      ",
            "     /  ..  ..  \    ",
            "    |   (0)(0)   |   ",
            "    |    \_/\_   |   ",
            "     \  '----'  /    ",
            "      \_.-..-._/     ",
            "     /|  ||  |\      ",
            "    / | /||\ | \     ",
            "   /  |/ || \|  \    ",
            "   | [] [] [] |      ",
            "    \  belt  /       ",
            "     /\    /\        ",
            "    /  \__/  \       "
        )}
        "Wizard" { @(
            "       ▄▄▄       ",
            "      ╱   ╲      ",
            "     ╱ ✦   ╲     ",
            "    ╱   ✦   ╲    ",
            "   ╱_________╲   ",
            "   █▓ ◉   ◉ ▓█   ",
            "   █▓   ╲_╱  ▓█   ",
            "    ▀█▓▓▓▓▓█▀    ",
            "    ║▓▓▓▓▓▓║    ",
            "   ═╝▓▓▓▓▓▓╚═   ",
            "    ║║▓▓▓▓║║    ",
            "   ══╩╩══╩╩══   "
        )}
        "Troll" { @(
            "    ▄▄██████▄▄    ",
            "  ▄██▒▒▒▒▒▒▒▒██▄  ",
            " ██▒▒ ◎    ◎ ▒▒██ ",
            " █▒▒▒   ▲▲   ▒▒▒█ ",
            " █▒▒▒ ┌────┐ ▒▒▒█ ",
            " █▒▒▒ │ ▼▼ │ ▒▒▒█ ",
            "  ▀█▒▒└────┘▒▒█▀  ",
            "   ║▒▓▓▓▓▓▓▓▒║   ",
            "  ═╝▒▓██████▓▒╚═  ",
            "   ║▓▒▒▒▒▒▒▒▓║   ",
            "   ║▓▓▒▒▒▒▓▓▓║   ",
            "  ══╩╩═══════╩╩══ "
        )}
        "MiniBoss" { @(
            "    ▄▄▀▀██▀▀▄▄    ",
            "   ▄╱▓▓▓▓▓▓▓▓╲▄   ",
            "  ██▓▓ {X}  {X}▓▓██  ",
            " █▓▓▓  ╲──╱  ▓▓▓█ ",
            " █▓▓▓ ═══>═══ ▓▓▓█ ",
            "  ██▓▓▓█████▓▓▓██  ",
            "   ▀▓╱═╤═╤═╤═╲▓▀   ",
            "    ║▓║ ║ ║ ║▓║    ",
            "   ═╝▓╚═╧═╧═╧╝▓╚═  ",
            "    ▓║▓▓▓▓▓▓║▓    ",
            "   ╱▓║██████║▓╲   ",
            "  ══╩╩═══════╩╩══ "
        )}
        "Boss" { @(
            "    ╔═══╗   ╔═══╗   ",
            "    ║▲▼▲║   ║▲▼▲║   ",
            "  ▄▄╚═══╝═══╚═══╝▄▄  ",
            " ▄█▓ ✦    ╱╲    ✦ ▓█▄ ",
            " █▓▓▓█{X}╱  ╲{X}█▓▓▓█ ",
            " █▓▓▓╱═════════╲▓▓▓█ ",
            "  █▓╱<===HATE===>╲▓█  ",
            "   ║▓▓▓▓▓▓▓▓▓▓▓▓▓║   ",
            "   ║▓╔═╤═╤═╤═╤═╗▓║   ",
            "  ╔╝▓║ ║ ║ ║ ║ ║▓╚╗  ",
            "  ║▓▓╚═╧═╧═╧═╧═╝▓▓║  ",
            "  ║▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓║  ",
            "  ╚═╩╩═════════╩╩═╝  "
        )}
        "Skeleton" { @(
            '       .-"""-.      ',
            '      /  __  \      ',
            '     | (oo)| |      ',
            '     |  ==  ||      ',
            '      \____/        ',
            '       ||||         ',
            '      /|||||\       ',
            '     |\\|||/|       ',
            '     |  |||   |     ',
            '      \ |||  /      ',
            '       \|||/        ',
            '        |||         ',
            '       /| |\        ',
            '      /_| |_\       '
        )}
        "Mimic" { @(
            "     _,---.---._     ",
            "    /   /   \   \    ",
            "   |  GRRR   AH  |   ",
            "   | >@<====>@<  |   ",
            "   |  \        / |   ",
            "    \  VVVVVVVV /    ",
            "     '---------'     ",
            "     |o|      |o|    ",
            "     |_|      |_|    ",
            "     | |  $$  | |    ",
            "     |_|      |_|    "
        )}
        "MimicKnight" { @(
            "        _____         ",
            "       /o   o\        ",
            "      |  III  |       ",
            "      |  \_/  |       ",
            "       \_____/        ",
            "       /|===|\        ",
            "      / |   | \       ",
            "     |  |{+}|  |      ",
            "     |  |===|  |      ",
            "      \ |___| /       ",
            "       /|   |\        ",
            "      //|___|\\       "
        )}
        "MimicMage" { @(
            "         /\          ",
            "        /**\         ",
            "       /_**_\        ",
            "        |oo|         ",
            "        |<>|         ",
            "         \/          ",
            "        /  \         ",
            "       / ** \        ",
            "      | *||* |       ",
            "       \||||/        ",
            "        ||||         ",
            "       /\||/\        "
        )}
        "MimicBrawler" { @(
            "         ___         ",
            "        /o o\        ",
            "       | >-< |       ",
            "        \___/        ",
            "      __/   \__      ",
            "     / |     | \     ",
            "    O  |     |  O    ",
            "    | /       \ |    ",
            "     V|       |V     ",
            "      |===|===|      ",
            "      | | | | |      ",
            "      |_|   |_|      "
        )}
        "MimicRanger" { @(
            "       .--'--.       ",
            "      /  ^ ^  \      ",
            "     |   ~_~   |     ",
            "      \_/'-'\_/      ",
            "     ))|_____|((     ",
            "    //  |###|  \\    ",
            "   //   |###|   \\   ",
            "  {}    |   |    {}  ",
            "        |   |        ",
            "       /|   |\       ",
            "      / |   | \      ",
            "     /__|   |__\     "
        )}
        "MimicCleric" { @(
            "       .-===-.       ",
            "      /   +   \      ",
            "     |  o   o  |     ",
            "     |   \_/   |     ",
            "      \___+___/      ",
            "       /|   |\       ",
            "      / | + | \      ",
            "     |  |===|  |     ",
            "     |  |+++|  |     ",
            "      \ |===| /      ",
            "       /|   |\       ",
            "      /_|___|_\      "
        )}
        "MimicNecromancer" { @(
            "       ,-===-,       ",
            "      /  X X  \      ",
            "     |  skull  |     ",
            "     |   /V\   |     ",
            "      \_-___-_/      ",
            "      /|     |\      ",
            "     / |)   (|  \    ",
            "    |  |  $  |   |   ",
            "    |  |__|__|   |   ",
            "     \ | VVV | /     ",
            "      /|     |\      ",
            "     //|_____|\\     "
        )}
        "MimicBerserker" { @(
            "        ,===,        ",
            "       / >=< \       ",
            "      |  X X  |      ",
            "      | /###\ |      ",
            "       \=VVV=/       ",
            "     __/|===|\__     ",
            "    / ||     || \    ",
            "   /  ||SLASH||  \   ",
            "  /_  ||=====||  _\  ",
            "  | ||==BLOOD==|| |  ",
            "  |_||    |    ||_|  ",
            "    //   /|\   \\    "
        )}
        "MimicWarlock" { @(
            "       .~~.~~.       ",
            "      (  ..  )       ",
            "     | ~ /\ ~ |      ",
            "      \_<><>_/       ",
            "     /~~|  |~~\      ",
            "    ( (_|DP|_) )     ",
            "     \  |  |  /      ",
            "      ~~|  |~~       ",
            "     _/|    |\_      ",
            "    /  |    |  \     ",
            "   //  |____|  \\    ",
            "  //   /    \   \\   "
        )}
        default { @(
            "      ▄▄▄▄      ",
            "    ▄█▒▒▒▒█▄    ",
            "   █▒ o  o ▒█   ",
            "   █▒  __   ▒█   ",
            "    ▀█▒▒▒▒█▀    ",
            "     ║▒▒▒║     ",
            "    ═╝▒▒▒╚═    ",
            "     ║║║║     "
        )}
    }
}

# Returns a "hit flash" variant of the art — with background briefly red
# Used during combat damage animation. Returns same lines; caller handles color.
function Get-EnemyHitFrame {
    param([string]$Type)
    $base = Get-EnemyArt $Type
    # Return as-is; caller colors differently
    return $base
}

function Draw-CombatHPBar {
    param([int]$Current,[int]$Max,[int]$Width,[string]$Color)
    $filled = [math]::Max([math]::Floor(($Current/$Max)*$Width),0)
    $empty = $Width - $filled
    Write-C "[" "White"
    Write-C ("=" * $filled) $Color
    Write-C ("-" * $empty) "DarkGray"
    Write-C "]" "White"
}

function Start-Combat {
    param($Enemy)
    $p = $script:Player; $e = $Enemy
    $fled = $false; $won = $false

    # Equipment bonuses
    $bonusATK  = Get-TotalWeaponATK
    $armorDEF  = Get-TotalArmorDEF
    $magBonus  = Get-WeaponMAGBonus
    $defBuff   = 0; $atkBuff = 0
    $defendCooldown = 0   # turns until Defend can be used again (0 = ready)
    # Per-ability cooldown tracker: name -> remaining turns. Cleared at the
    # start of each combat so cooldowns don't carry between fights.
    $abilityCooldowns = @{}
    # Per-ENEMY-ability cooldown tracker (separate from player's). Each key is
    # the enemy ability Name -> remaining turns until usable again.
    $enemyAbilityCD   = @{}
    # Enemy buff state: tracks +ATK/+DEF self-buffs from Buff abilities. The
    # buff lasts until $enemyBuffTurns expires, at which point it wears off.
    $enemyBonusATK    = 0
    $enemyBonusDEF    = 0
    $enemyBuffTurns   = 0
    $combatLog = [System.Collections.ArrayList]@()

    # Status effects on enemy (local to this fight)
    $ePoisoned  = $false
    $eSlowed    = $false
    $ePoisonDmg = 0

    # ── NEW HIT CHANCE SYSTEM ──
    # Player base 70%, enemy base 65%. Hard cap at 90%, floor at 20%.
    # Adjusted by level, SPD, status effects.
    #
    #   Player hit = 70 + min(level-1, 15) + floor(SPD * 0.3)  (capped 90, floored 20)
    #   Enemy  hit = 65 + DungeonLevel * 1.5                   (capped 90, floored 20)
    #
    # Slow drops target's hit% by 25; Stun sets 0 for one turn.
    # Luck potion previously added to hit chance — now it boosts CRIT CHANCE
    # via Get-PlayerCrit. Hit chance no longer takes a luck argument.
    function Get-PlayerHit {
        param($level,$spd)
        $h = 70 + [math]::Min($level - 1, 15) + [math]::Floor($spd * 0.3)
        if($h -gt 90){ $h = 90 }
        if($h -lt 20){ $h = 20 }
        return $h
    }
    # Player crit chance: 5% base, +1% per 4 SPD, plus active Luck buff.
    # Capped at 60% so the game never feels deterministic.
    function Get-PlayerCrit {
        param($spd, $luckBonus)
        $c = 5 + [math]::Floor($spd / 4) + $luckBonus
        if($c -gt 60){ $c = 60 }
        if($c -lt 0){ $c = 0 }
        return $c
    }
    function Get-EnemyHit {
        param($dungeonLvl,$isMini,$isBoss)
        $h = 65 + [math]::Floor($dungeonLvl * 1.5)
        if($isMini){ $h += 3 }
        if($isBoss){ $h += 5 }
        if($h -gt 90){ $h = 90 }
        if($h -lt 20){ $h = 20 }
        return $h
    }
    # Enemy crit chance: 4% base + scales mildly with dungeon level.
    # Mini-bosses get +3, bosses +6. Capped at 30% so it can't snowball.
    function Get-EnemyCrit {
        param($dungeonLvl,$isMini,$isBoss)
        $c = 4 + [math]::Floor($dungeonLvl / 3)
        if($isMini){ $c += 3 }
        if($isBoss){ $c += 6 }
        if($c -gt 30){ $c = 30 }
        if($c -lt 0){ $c = 0 }
        return $c
    }

    $playerHitChance = Get-PlayerHit $script:PlayerLevel $p.SPD
    $enemyHitChance  = Get-EnemyHit $script:DungeonLevel $e.IsMiniBoss $e.IsBoss
    $playerCritChance = Get-PlayerCrit $p.SPD $script:LuckBonus
    $enemyCritChance  = Get-EnemyCrit $script:DungeonLevel $e.IsMiniBoss $e.IsBoss

    # Enemy art
    $artType  = if($e.IsMiniBoss){"MiniBoss"}elseif($e.IsBoss){"Boss"}else{$e.Name}
    $enemyArt = Get-EnemyArt $artType

    # ── Animation helpers (closures so they share $combatLog/$e) ──
    function Show-AttackAnim {
        param([string]$Type,[int]$Damage,[string]$Color="Yellow")
        # Short animated burst - player side
        $frames = switch($Type){
            "sword"  { @("  ╱","  ╱╱"," ╱╱╱","╱╱╱>","══>═"," ══>"," > ","    ") }
            "magic"  { @("  *","  **","  ***"," ****","*****","  ✦","  .","    ") }
            "ranged" { @("  .","  .-","  .->"," .-->",".--->","  ->","  >"," .") }
            "fist"   { @("  o","  oo"," o<<","o<<<","<<<!"," <!","  !","   ") }
            default  { @("  !","  !!","  !!!"," !!!!","!!!!!","  !!","  !","   ") }
        }
        foreach($f in $frames){
            Write-C "    " "Black"
            Write-CL $f $Color
            Start-Sleep -Milliseconds 35
            # Cursor up one line & clear
            try {
                $pos = $Host.UI.RawUI.CursorPosition
                $newY = $pos.Y - 1
                if($newY -ge 0){
                    $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, $newY
                    Write-Host (" " * 20) -NoNewline
                    $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, $newY
                }
            } catch {}
        }
        # Damage popup
        Write-C "    " "Black"
        Write-CL " -$Damage! " "Red"
        Start-Sleep -Milliseconds 150
        try {
            $pos = $Host.UI.RawUI.CursorPosition
            $newY = $pos.Y - 1
            if($newY -ge 0){
                $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, $newY
                Write-Host (" " * 20) -NoNewline
                $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, $newY
            }
        } catch {}
    }

    function Show-EnemyAttackAnim {
        param([int]$Damage)
        # Reversed direction for enemy attacks
        $frames = @("<   ","<<  ","<<< ","<<<<","<<< "," << ","  < ","    ")
        foreach($f in $frames){
            Write-C "    " "Black"
            Write-CL $f "Red"
            Start-Sleep -Milliseconds 30
            try {
                $pos = $Host.UI.RawUI.CursorPosition
                $newY = $pos.Y - 1
                if($newY -ge 0){
                    $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, $newY
                    Write-Host (" " * 20) -NoNewline
                    $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, $newY
                }
            } catch {}
        }
        Write-C "    " "Black"
        Write-CL " YOU -$Damage! " "DarkRed"
        Start-Sleep -Milliseconds 200
        try {
            $pos = $Host.UI.RawUI.CursorPosition
            $newY = $pos.Y - 1
            if($newY -ge 0){
                $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, $newY
                Write-Host (" " * 20) -NoNewline
                $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, $newY
            }
        } catch {}
    }

    # Decide animation type from equipped weapon
    $animType = "default"
    if($script:EquippedWeapon){
        switch($script:EquippedWeapon.WeaponType){
            "Sword"  { $animType = "sword" }
            "Staff"  { $animType = "magic" }
            "Bow"    { $animType = "ranged" }
            "Fist"   { $animType = "fist" }
            "Mace"   { $animType = "sword" }
            "Scythe" { $animType = "sword" }
            "Dagger" { $animType = "sword" }
            "Hammer" { $animType = "fist" }
            default  { $animType = "default" }
        }
    }

    while($p.HP -gt 0 -and $e.HP -gt 0 -and !$fled){
        clr

        # ── Broken-gear warnings (once per turn, to keep pressure on) ──
        if($script:EquippedWeapon -and (Test-ItemBroken $script:EquippedWeapon)){
            [void]$combatLog.Add(@{Text=">> WARNING: $($script:EquippedWeapon.Name) is BROKEN — no ATK bonus!";Color="Red"})
        }
        foreach($armorSlot in @("Helmet","Chest","Shield","Amulet","Boots")){
            $armorPiece = $script:EquippedArmor[$armorSlot]
            if($armorPiece -and (Test-ItemBroken $armorPiece)){
                [void]$combatLog.Add(@{Text=">> WARNING: $($armorPiece.Name) is BROKEN — no DEF!";Color="Red"})
            }
        }

        # ── Header ──
        Write-CL ("=" * 70) "DarkRed"
        Write-C "  " "Red"
        if($e.IsBoss){Write-CL $e.DisplayName "DarkRed"}
        elseif($e.IsMiniBoss){Write-CL $e.DisplayName "Magenta"}
        else{Write-CL $e.DisplayName "Red"}
        Write-CL ("=" * 70) "DarkRed"
        Write-Host ""

        # ── Enemy art + stats ──
        $eHPPct = [math]::Max($e.HP / $e.MaxHP, 0)
        $statusStr = ""
        if($ePoisoned){ $statusStr += " [POISON]" }
        if($eSlowed){ $statusStr += " [SLOW]" }
        if($e.Stunned){ $statusStr += " [STUN]" }
        if($e.IsBoss -and $e.TelegraphNext){ $statusStr += " [CHARGING!]" }

        $statsLines = @(
            "",
            "  $($e.DisplayName)",
            "$statusStr",
            $null,
            "  $($e.HP) / $($e.MaxHP) HP",
            "",
            "  ATK: $($e.ATK)  DEF: $($e.DEF)",
            "  SPD: $($e.SPD)  MAG: $($e.MAG)",
            ""
        )

        $maxLines = [math]::Max($enemyArt.Count, $statsLines.Count)
        for($i=0;$i -lt $maxLines;$i++){
            if($i -lt $enemyArt.Count){
                $artColor = if($e.IsBoss){"DarkRed"}elseif($e.IsMiniBoss){"Magenta"}else{"Red"}
                Write-C "  $($enemyArt[$i])" $artColor
                $pad = 24 - $enemyArt[$i].Length
                if($pad -gt 0){Write-C (" " * $pad) "Black"}
            } else {
                Write-C ("  " + " " * 22) "Black"
            }
            Write-C "  " "Black"
            if($i -lt $statsLines.Count){
                if($null -eq $statsLines[$i]){
                    Write-C "  " "White"
                    Draw-CombatHPBar $e.HP $e.MaxHP 30 $(if($eHPPct -gt 0.5){"Red"}elseif($eHPPct -gt 0.25){"DarkYellow"}else{"DarkRed"})
                } elseif($statsLines[$i] -match "\[POISON\]|\[SLOW\]|\[STUN\]|\[CHARGING") {
                    Write-C $statsLines[$i] "Yellow"
                } else {
                    Write-C $statsLines[$i] "Gray"
                }
            }
            Write-Host ""
        }

        Write-Host ""
        Write-CL ("  " + "-" * 66) "DarkGray"
        Write-Host ""

        # ── Player stats (with stance applied) ──
        $stanceATK = Get-StanceATKMult
        $stanceDEF = Get-StanceDEFMult
        $totalDEF = [int][math]::Floor(($p.DEF + $armorDEF + $defBuff) * $stanceDEF)
        $totalATK = [int][math]::Floor(($p.ATK + $bonusATK + $atkBuff) * $stanceATK)
        $totalMAG = [int][math]::Floor(($p.MAG + $magBonus) * $stanceATK)  # MAG scales with ATK multiplier
        $pHPPct = [math]::Max($p.HP / $p.MaxHP, 0)
        $wep = if($script:EquippedWeapon){$script:EquippedWeapon.Name}else{"Bare Hands"}

        Write-C "  $($p.Name)" "Green"
        Write-CL "  (Lv$($script:PlayerLevel))  Weapon: $wep" "DarkGray"

        Write-C "  HP " "White"
        Draw-CombatHPBar $p.HP $p.MaxHP 25 $(if($pHPPct -gt 0.5){"Green"}elseif($pHPPct -gt 0.25){"Yellow"}else{"Red"})
        Write-CL " $($p.HP)/$($p.MaxHP)" "White"

        Write-C "  MP " "White"
        Draw-CombatHPBar $p.MP $p.MaxMP 25 "Cyan"
        Write-CL " $($p.MP)/$($p.MaxMP)" "White"

        Write-CL "  ATK:$totalATK DEF:$totalDEF SPD:$($p.SPD) MAG:$totalMAG" "DarkGray"
        $luckStr = if($script:LuckTurnsLeft -gt 0){" | LUCK +$($script:LuckBonus)% crit ($($script:LuckTurnsLeft)t)"}else{""}
        Write-CL "  Hit:$($playerHitChance)% Crit:$($playerCritChance)%$luckStr | Enemy Hit:$($enemyHitChance)% Crit:$($enemyCritChance)%" "DarkGray"
        Write-C "  Stance: " "DarkGray"; Write-CL "[$(Get-StanceShortLabel)] $($script:Stance)" (Get-StanceColor)

        # ── Combat log ──
        if($combatLog.Count -gt 0){
            Write-Host ""
            $logStart = [math]::Max($combatLog.Count - 5, 0)
            for($li=$logStart;$li -lt $combatLog.Count;$li++){
                $entry = $combatLog[$li]
                Write-CL "  $($entry.Text)" $entry.Color
            }
        }

        # ── Action menu ──
        Write-Host ""
        Write-CL ("  " + "-" * 66) "DarkGray"
        $throwCount = $script:ThrowablePotions.Count
        $defLabel = if($defendCooldown -gt 0){"Defend(${defendCooldown}t)"}else{"Defend"}
        Write-CL "   [1] Attack  [2] Ability  [3] Potion  [4] Throw($throwCount)  [5] $defLabel  [6] Flee" "White"
        Write-CL "   [T] Stance (free action)" "DarkCyan"
        Write-CL ("  " + "-" * 66) "DarkGray"
        Write-C "  > " "Yellow"
        $choice = Read-Host

        $acted = $true
        $playerDefending = $false

        switch($choice){
            "1" {
                if((Get-Random -Max 100) -ge $playerHitChance){
                    [void]$combatLog.Add(@{Text=">> You attack but MISS!";Color="DarkGray"})
                } else {
                    $raw = $totalATK - [math]::Floor($e.DEF * 0.5)
                    $playerDmg = [math]::Max($raw + (Get-Random -Min -2 -Max 4), 1)
                    # Crit roll: 2x damage if it lands
                    $isCrit = ((Get-Random -Max 100) -lt $playerCritChance)
                    if($isCrit){ $playerDmg *= 2 }
                    Show-AttackAnim $animType $playerDmg "Yellow"
                    $e.HP -= $playerDmg
                    if($isCrit){
                        [void]$combatLog.Add(@{Text=">> CRITICAL HIT! $playerDmg damage!";Color="Yellow"})
                        Update-QuestProgress "Crit"; $script:TotalCrits++
                    } else {
                        [void]$combatLog.Add(@{Text=">> You attack for $playerDmg damage!";Color="Green"})
                    }

                    # Weapon durability: successful hit consumes 1 point (unless indestructible)
                    if($script:EquippedWeapon -and $script:EquippedWeapon.MaxDurability -ge 0 -and $script:EquippedWeapon.Durability -gt 0){
                        $script:EquippedWeapon.Durability--
                        if($script:EquippedWeapon.Durability -le 0){
                            [void]$combatLog.Add(@{Text="   *CRACK* $($script:EquippedWeapon.Name) SHATTERS — 0 ATK bonus!";Color="Red"})
                        } elseif($script:EquippedWeapon.Durability -eq [int]($script:EquippedWeapon.MaxDurability * 0.25)){
                            [void]$combatLog.Add(@{Text="   Your $($script:EquippedWeapon.Name) groans — durability low!";Color="DarkYellow"})
                        }
                    }

                    # Weapon perk proc
                    if($script:EquippedWeapon -and $script:EquippedWeapon.Perk){
                        if((Get-Random -Max 100) -lt $script:EquippedWeapon.PerkChance){
                            switch($script:EquippedWeapon.Perk){
                                "Bleed" {
                                    $bleedDmg = Get-Random -Min 3 -Max 9
                                    $e.HP -= $bleedDmg
                                    [void]$combatLog.Add(@{Text="   BLEED! $bleedDmg extra damage!";Color="DarkRed"})
                                }
                                "Burn" {
                                    $burnDmg = Get-Random -Min 3 -Max 8
                                    $e.HP -= $burnDmg
                                    [void]$combatLog.Add(@{Text="   BURN! $burnDmg extra damage!";Color="DarkYellow"})
                                }
                                "Poison" {
                                    $ePoisoned = $true
                                    $ePoisonDmg = Get-Random -Min 4 -Max 8
                                    [void]$combatLog.Add(@{Text="   Enemy is POISONED! ($ePoisonDmg/turn)";Color="DarkGreen"})
                                }
                                "Drain" {
                                    $drainAmt = [math]::Floor($playerDmg * 0.25)
                                    $p.HP = [math]::Min($p.HP + $drainAmt, $p.MaxHP)
                                    [void]$combatLog.Add(@{Text="   DRAIN! Restored $drainAmt HP!";Color="Magenta"})
                                }
                                "Stun" {
                                    $e.Stunned = $true
                                    [void]$combatLog.Add(@{Text="   STUN! Enemy stunned!";Color="Yellow"})
                                }
                            }
                        }
                    }
                }
            }
            "2" {
                Write-Host ""
                Write-CL "  ── Abilities ──" "Cyan"
                for($ai=0;$ai -lt $p.Abilities.Count;$ai++){
                    $ab = Get-ScaledAbility $p.Abilities[$ai] $script:PlayerLevel
                    $costStr = if($ab.Type -eq "Sacrifice"){"HP:$([math]::Floor($p.MaxHP * 0.15))"}else{"MP:$($ab.Cost)"}
                    $effStr = if($ab.Effect -and $ab.Effect -ne "None" -and $ab.Effect -ne "SacrificeHP"){" [$($ab.Effect)]"}else{""}
                    # Show cooldown state per ability
                    $cdLeft = 0
                    if($abilityCooldowns.ContainsKey($ab.Name)){ $cdLeft = $abilityCooldowns[$ab.Name] }
                    if($cdLeft -gt 0){
                        Write-CL "    [$($ai+1)] $($ab.Name)  ($costStr)  [$($ab.Type)] Pwr:$($ab.Power)$effStr  -- COOLDOWN ${cdLeft}t --" "DarkGray"
                    } else {
                        Write-CL "    [$($ai+1)] $($ab.Name)  ($costStr)  [$($ab.Type)] Pwr:$($ab.Power)$effStr" "Cyan"
                    }
                }
                Write-C "    > " "Yellow"; $ac = Read-Host
                $idx = (ConvertTo-SafeInt -Value $ac) - 1
                if($idx -ge 0 -and $idx -lt $p.Abilities.Count){
                    $ab = Get-ScaledAbility $p.Abilities[$idx] $script:PlayerLevel

                    # Check cooldown FIRST
                    $cdLeft = 0
                    if($abilityCooldowns.ContainsKey($ab.Name)){ $cdLeft = $abilityCooldowns[$ab.Name] }
                    if($cdLeft -gt 0){
                        [void]$combatLog.Add(@{Text=">> $($ab.Name) is still on cooldown ($cdLeft turns)!";Color="DarkGray"})
                        $acted = $false
                        # break out of switch case — need to continue to next iteration
                    } else {
                    # Check cost
                    $canUse = $true
                    if($ab.Type -eq "Sacrifice"){
                        $hpCost = [math]::Floor($p.MaxHP * 0.15)
                        if($p.HP -le $hpCost){
                            [void]$combatLog.Add(@{Text=">> Not enough HP to sacrifice!";Color="Red"})
                            $canUse = $false; $acted = $false
                        }
                    } else {
                        if($p.MP -lt $ab.Cost){
                            [void]$combatLog.Add(@{Text=">> Not enough MP!";Color="Red"})
                            $canUse = $false; $acted = $false
                        }
                    }

                    if($canUse){
                        # Pay cost
                        if($ab.Type -eq "Sacrifice"){
                            $hpCost = [math]::Floor($p.MaxHP * 0.15)
                            $p.HP -= $hpCost
                            [void]$combatLog.Add(@{Text=">> Sacrificed $hpCost HP!";Color="DarkMagenta"})
                        } else {
                            $p.MP -= $ab.Cost
                        }

                        # Set this ability's cooldown. Use the CD field from the
                        # base ability template (default 2 if missing). The cooldown
                        # decrements at end of turn, so a Cooldown=2 ability skips
                        # the next 2 turns then is ready again.
                        $cdVal = if($p.Abilities[$idx].Cooldown){[int]$p.Abilities[$idx].Cooldown}else{2}
                        $abilityCooldowns[$ab.Name] = $cdVal

                        if($ab.Type -eq "Buff"){
                            switch -Wildcard ($ab.Effect){
                                "DEF*" {
                                    $val = [int]($ab.Effect -replace '[^0-9]','')
                                    $defBuff += $val
                                    [void]$combatLog.Add(@{Text=">> Defense raised by $val!";Color="Cyan"})
                                }
                                "ATK*" {
                                    $val = [int]($ab.Effect -replace '[^0-9]','')
                                    $atkBuff += $val
                                    [void]$combatLog.Add(@{Text=">> Attack raised by $val!";Color="Cyan"})
                                }
                                "SPD*" {
                                    $val = [int]($ab.Effect -replace '[^0-9]','')
                                    # Under new system: SPD buff directly increases hit%
                                    $playerHitChance = [math]::Min($playerHitChance + ($val * 2), 90)
                                    [void]$combatLog.Add(@{Text=">> Speed raised! Hit chance improved!";Color="Cyan"})
                                }
                            }
                        }
                        elseif($ab.Type -eq "Heal"){
                            $healAmt = $ab.Power + [math]::Floor(($p.MAG + $magBonus) * 0.5)
                            $healed = [math]::Min($healAmt, $p.MaxHP - $p.HP)
                            $p.HP += $healed
                            [void]$combatLog.Add(@{Text=">> $($ab.Name) restores $healed HP!";Color="Green"})
                        }
                        else {
                            # Damage ability
                            if((Get-Random -Max 100) -ge $playerHitChance){
                                [void]$combatLog.Add(@{Text=">> $($ab.Name) MISSES!";Color="DarkGray"})
                            } else {
                                $base = if($ab.Type -eq "Magic" -or $ab.Type -eq "Sacrifice"){$p.MAG + $magBonus}else{$p.ATK + $bonusATK + $atkBuff}
                                # Apply stance multiplier (same scaler for ATK and MAG)
                                $base = [int][math]::Floor($base * (Get-StanceATKMult))
                                $raw = $base + $ab.Power - [math]::Floor($e.DEF * 0.4)
                                $playerDmg = [math]::Max($raw + (Get-Random -Min -2 -Max 5), 1)
                                # Crit roll on abilities too
                                $isCrit = ((Get-Random -Max 100) -lt $playerCritChance)
                                if($isCrit){ $playerDmg *= 2 }
                                $abAnim = if($ab.Type -eq "Magic" -or $ab.Type -eq "Sacrifice"){"magic"}else{$animType}
                                Show-AttackAnim $abAnim $playerDmg "Cyan"
                                $e.HP -= $playerDmg
                                if($isCrit){
                                    [void]$combatLog.Add(@{Text=">> CRITICAL $($ab.Name) hits for $playerDmg!";Color="Yellow"})
                                    Update-QuestProgress "Crit"; $script:TotalCrits++
                                } else {
                                    [void]$combatLog.Add(@{Text=">> $($ab.Name) hits for $playerDmg!";Color="Cyan"})
                                }

                                # Weapon durability: ability hits also wear the weapon (counts for magic/physical)
                                if($script:EquippedWeapon -and $script:EquippedWeapon.MaxDurability -ge 0 -and $script:EquippedWeapon.Durability -gt 0){
                                    $script:EquippedWeapon.Durability--
                                    if($script:EquippedWeapon.Durability -le 0){
                                        [void]$combatLog.Add(@{Text="   *CRACK* $($script:EquippedWeapon.Name) SHATTERS — 0 ATK bonus!";Color="Red"})
                                    }
                                }

                                # Status-inflicting effects now rework Slow to drop enemy hit chance
                                if($ab.Effect -eq "Stun" -and (Get-Random -Max 100) -lt 40){
                                    $e.Stunned = $true
                                    [void]$combatLog.Add(@{Text="   Enemy is STUNNED!";Color="Yellow"})
                                }
                                if($ab.Effect -eq "Burn" -and (Get-Random -Max 100) -lt 50){
                                    $burnDmg = Get-Random -Min 3 -Max 8
                                    $e.HP -= $burnDmg
                                    [void]$combatLog.Add(@{Text="   BURN deals $burnDmg extra!";Color="DarkYellow"})
                                }
                                if($ab.Effect -eq "Bleed" -and (Get-Random -Max 100) -lt 45){
                                    $bleedDmg = Get-Random -Min 4 -Max 10
                                    $e.HP -= $bleedDmg
                                    [void]$combatLog.Add(@{Text="   BLEED deals $bleedDmg extra!";Color="DarkRed"})
                                }
                                if($ab.Effect -eq "Poison" -and (Get-Random -Max 100) -lt 50){
                                    $ePoisoned = $true
                                    $ePoisonDmg = Get-Random -Min 4 -Max 8
                                    [void]$combatLog.Add(@{Text="   Enemy POISONED! ($ePoisonDmg/turn)";Color="DarkGreen"})
                                }
                                if($ab.Effect -eq "Slow" -and (Get-Random -Max 100) -lt 60){
                                    $eSlowed = $true
                                    # NEW: Slow lowers enemy's hit chance by 25 (floored at 20)
                                    $enemyHitChance = [math]::Max($enemyHitChance - 25, 20)
                                    [void]$combatLog.Add(@{Text="   Enemy SLOWED! -25% hit chance!";Color="DarkCyan"})
                                }
                                if($ab.Effect -eq "Drain"){
                                    $drainAmt = [math]::Floor($playerDmg * 0.3)
                                    $p.HP = [math]::Min($p.HP + $drainAmt, $p.MaxHP)
                                    [void]$combatLog.Add(@{Text="   DRAIN! Restored $drainAmt HP!";Color="Magenta"})
                                }
                                if($ab.Effect -eq "Weaken" -and (Get-Random -Max 100) -lt 50){
                                    $weakenAmt = [math]::Max([math]::Floor($e.ATK * 0.15), 1)
                                    $e.ATK -= $weakenAmt
                                    [void]$combatLog.Add(@{Text="   CURSE! Enemy ATK -$weakenAmt!";Color="DarkMagenta"})
                                }
                            }
                        }
                    }
                    }   # close: } else { (cooldown branch) — runs ability when not on CD
                } else { $acted = $false }
            }
            "3" {
                $hasESP = ($script:ExtraStrongPotions -gt 0)
                if($script:Potions.Count -eq 0 -and -not $hasESP){
                    [void]$combatLog.Add(@{Text=">> No potions!";Color="Red"}); $acted = $false
                } else {
                    Write-Host ""
                    Write-CL "  ── Potions ──" "Green"
                    if($hasESP){
                        Write-CL "    [E] Extra Strong Potion x$($script:ExtraStrongPotions) - Full HP + MP restore" "Magenta"
                    }
                    for($pi=0;$pi -lt $script:Potions.Count;$pi++){
                        $pot = $script:Potions[$pi]
                        Write-CL "    [$($pi+1)] $($pot.Name) - $($pot.Desc)" "Green"
                    }
                    Write-C "    > " "Yellow"; $pc = Read-Host
                    if($pc -match '^[Ee]$' -and $hasESP){
                        # Use Extra Strong Potion
                        $hpRestored = $p.MaxHP - $p.HP
                        $mpRestored = $p.MaxMP - $p.MP
                        $p.HP = $p.MaxHP
                        $p.MP = $p.MaxMP
                        $script:ExtraStrongPotions--
                        [void]$combatLog.Add(@{Text=">> EXTRA STRONG! +$hpRestored HP, +$mpRestored MP!";Color="Magenta"})
                    } else {
                        $pidx = (ConvertTo-SafeInt -Value $pc) - 1
                        if($pidx -ge 0 -and $pidx -lt $script:Potions.Count){
                            $pot = $script:Potions[$pidx]
                            switch($pot.Type){
                                "Heal" {
                                    $healed = [math]::Min($pot.Power, $p.MaxHP - $p.HP)
                                    $p.HP += $healed
                                    [void]$combatLog.Add(@{Text=">> Healed for $healed HP!";Color="Green"})
                                }
                                "Mana" {
                                    $restored = [math]::Min($pot.Power, $p.MaxMP - $p.MP)
                                    $p.MP += $restored
                                    [void]$combatLog.Add(@{Text=">> Restored $restored MP!";Color="Cyan"})
                                }
                                "ATKBuff" {
                                    $atkBuff += $pot.Power
                                    [void]$combatLog.Add(@{Text=">> Attack boosted by $($pot.Power)!";Color="Yellow"})
                                }
                            "DEFBuff" {
                                $defBuff += $pot.Power
                                [void]$combatLog.Add(@{Text=">> Defense boosted by $($pot.Power)!";Color="Yellow"})
                            }
                            "Luck" {
                                # Luck potion now boosts CRIT chance for several turns
                                $script:LuckBonus = $pot.Power
                                $script:LuckTurnsLeft = 3
                                $playerCritChance = Get-PlayerCrit $p.SPD $script:LuckBonus
                                [void]$combatLog.Add(@{Text=">> LUCK +$($pot.Power)% crit for 3 turns!";Color="Yellow"})
                            }
                        }
                        $script:Potions.RemoveAt($pidx)
                        } else { $acted = $false }
                    }
                }
            }

            "4" {
                if($script:ThrowablePotions.Count -eq 0){
                    [void]$combatLog.Add(@{Text=">> No throwables!";Color="Red"}); $acted=$false
                } else {
                    Write-Host ""
                    Write-CL "  ── Throwables ──" "DarkYellow"
                    for($ti=0;$ti -lt $script:ThrowablePotions.Count;$ti++){
                        $tp = $script:ThrowablePotions[$ti]
                        Write-CL "    [$($ti+1)] $($tp.Name) - $($tp.Desc)" "DarkYellow"
                    }
                    Write-C "    > " "Yellow"; $tc = Read-Host
                    $tidx = (ConvertTo-SafeInt -Value $tc) - 1
                    if($tidx -ge 0 -and $tidx -lt $script:ThrowablePotions.Count){
                        $tp = $script:ThrowablePotions[$tidx]
                        $throwDmg = $tp.Power + (Get-Random -Min -3 -Max 4)
                        $throwDmg = [math]::Max($throwDmg, 1)
                        Show-AttackAnim "ranged" $throwDmg "DarkYellow"
                        $e.HP -= $throwDmg
                        [void]$combatLog.Add(@{Text=">> Threw $($tp.Name) for $throwDmg damage!";Color="DarkYellow"})

                        if($tp.Type -eq "ThrowPoison"){
                            $ePoisoned = $true
                            $ePoisonDmg = Get-Random -Min 4 -Max 8
                            [void]$combatLog.Add(@{Text="   Enemy is POISONED! ($ePoisonDmg/turn)";Color="DarkGreen"})
                        }
                        if($tp.Type -eq "ThrowSlow"){
                            $eSlowed = $true
                            $enemyHitChance = [math]::Max($enemyHitChance - 25, 20)
                            [void]$combatLog.Add(@{Text="   Enemy SLOWED! -25% hit chance!";Color="DarkCyan"})
                        }
                        $script:ThrowablePotions.RemoveAt($tidx)
                    } else { $acted = $false }
                }
            }
            "5" {
                # Defend: halves incoming damage. Has a 2-turn cooldown after use
                # so it's a tactical commitment, not a spam button.
                if($defendCooldown -gt 0){
                    [void]$combatLog.Add(@{Text=">> Defend is recovering. ($defendCooldown more turn(s))";Color="DarkGray"})
                    $acted = $false
                } else {
                    $playerDefending = $true
                    $defendCooldown = 3   # decrements at end of THIS turn -> 2 actual turns of cooldown
                    [void]$combatLog.Add(@{Text=">> You brace for impact. DEF doubled this turn.";Color="Cyan"})
                }
            }
            "6" {
                if($e.IsBoss -or $e.IsMiniBoss){
                    [void]$combatLog.Add(@{Text=">> Cannot flee from this enemy!";Color="Red"})
                    $acted = $false
                } elseif((Get-Random -Max 100) -lt (40 + $p.SPD)){
                    [void]$combatLog.Add(@{Text=">> You escaped!";Color="Yellow"}); $fled = $true
                } else {
                    [void]$combatLog.Add(@{Text=">> Failed to flee!";Color="Red"})
                }
            }
            "T" {
                # Stance switch — FREE ACTION, doesn't consume turn.
                # PowerShell switch is case-insensitive by default, so 'T' or 't' both match.
                Write-Host ""
                Write-CL "  ── Switch Stance ──" "Cyan"
                $curLabel = "[CURRENT: $($script:Stance)]"
                Write-CL "  $curLabel" (Get-StanceColor)
                Write-Host ""
                Write-CL "    [1] Aggressive  ATK +30% / DEF -30%" "Red"
                Write-CL "    [2] Balanced    no change (neutral)" "Yellow"
                Write-CL "    [3] Defensive   ATK -30% / DEF +30%" "Cyan"
                Write-CL "    [0] Cancel" "DarkGray"
                Write-Host ""
                Write-C "    > " "Yellow"
                $sChoice = Read-Host
                $newStance = switch($sChoice){
                    "1" { "Aggressive" }
                    "2" { "Balanced" }
                    "3" { "Defensive" }
                    default { $null }
                }
                if($newStance -and $newStance -ne $script:Stance){
                    $script:Stance = $newStance
                    $script:TotalStanceSwaps++
                    [void]$combatLog.Add(@{Text=">> Stance: $newStance.";Color=(Get-StanceColor)})
                }
                # Free action — does NOT cost a turn
                $acted = $false
            }
            default { $acted = $false }
        }

        # ── Poison tick on enemy (after player acts) ──
        if($ePoisoned -and $e.HP -gt 0 -and !$fled){
            $e.HP -= $ePoisonDmg
            [void]$combatLog.Add(@{Text="   POISON ticks for $ePoisonDmg!";Color="DarkGreen"})
        }

        # ── Boss telegraph handling ──
        # If a boss fired its telegraph last turn, this turn it unleashes Inferno.
        # Also: bosses will randomly telegraph 25% of the time their turn starts,
        # giving the player a defensive opening.
        $forcedBossAbility = $null
        if($e.IsBoss){
            if($e.TelegraphNext){
                # Execute the telegraphed move
                $forcedBossAbility = @{Name="Inferno";Power=25;Type="Magic"}
                $e.TelegraphNext = $false
                [void]$combatLog.Add(@{Text="<< $($e.DisplayName) UNLEASHES its charged attack!";Color="DarkRed"})
            }
        }

        # ── Enemy turn ──
        if($e.HP -gt 0 -and !$fled -and $acted){
            # Slow no longer makes the enemy lose turns — it reduced their hit% instead
            if($e.Stunned){
                [void]$combatLog.Add(@{Text="<< $($e.DisplayName) is stunned!";Color="Yellow"})
                $e.Stunned = $false
            } else {
                # ── Choose the enemy's action ──
                # Decision tree:
                #   1. Forced boss telegraphed move (always wins)
                #   2. Below 30% HP AND a Heal is off-cooldown -> Heal
                #   3. No buff active AND a Buff is off-cooldown AND 30% chance -> Buff
                #   4. 35% chance to use a damage ability (random off-cooldown one) — caps spam
                #   5. Otherwise: basic Attack
                $eAbility = $null
                if($forcedBossAbility){
                    $eAbility = $forcedBossAbility
                }
                else {
                    $hpPctE = $e.HP / [math]::Max($e.MaxHP, 1)
                    # Filter abilities by category and off-cooldown
                    $allAbil = @($e.Abilities)
                    $healAbil = @($allAbil | Where-Object {
                        $_.Type -eq "Heal" -and (-not $enemyAbilityCD.ContainsKey($_.Name) -or $enemyAbilityCD[$_.Name] -le 0)
                    })
                    $buffAbil = @($allAbil | Where-Object {
                        $_.Type -eq "Buff" -and (-not $enemyAbilityCD.ContainsKey($_.Name) -or $enemyAbilityCD[$_.Name] -le 0)
                    })
                    $dmgAbil = @($allAbil | Where-Object {
                        ($_.Type -eq "Physical" -or $_.Type -eq "Magic") -and (-not $enemyAbilityCD.ContainsKey($_.Name) -or $enemyAbilityCD[$_.Name] -le 0)
                    })
                    $basicAtk = @($allAbil | Where-Object { $_.Type -eq "Normal" })

                    if($hpPctE -lt 0.3 -and $healAbil.Count -gt 0){
                        $eAbility = $healAbil | Get-Random
                    }
                    elseif($enemyBuffTurns -le 0 -and $buffAbil.Count -gt 0 -and (Get-Random -Max 100) -lt 30){
                        $eAbility = $buffAbil | Get-Random
                    }
                    elseif($dmgAbil.Count -gt 0 -and (Get-Random -Max 100) -lt 35){
                        $eAbility = $dmgAbil | Get-Random
                    }
                    else {
                        # Fall back to basic Attack (always available, never on cooldown)
                        if($basicAtk.Count -gt 0){
                            $eAbility = $basicAtk[0]
                        } else {
                            $eAbility = @{Name="Attack"; Power=0; Type="Normal"; Cooldown=0}
                        }
                    }
                }

                # ── Resolve the chosen ability ──
                if($eAbility.Type -eq "Heal"){
                    # Self-heal: doesn't roll to hit, doesn't damage player.
                    $healAmt = $eAbility.Power + [math]::Floor($e.MAG * 0.4)
                    $actualHeal = [math]::Min($healAmt, $e.MaxHP - $e.HP)
                    $e.HP += $actualHeal
                    [void]$combatLog.Add(@{Text="<< $($e.DisplayName) uses $($eAbility.Name) — restores $actualHeal HP!";Color="Green"})
                    # Set cooldown
                    $cd = if($eAbility.Cooldown){[int]$eAbility.Cooldown}else{4}
                    $enemyAbilityCD[$eAbility.Name] = $cd
                }
                elseif($eAbility.Type -eq "Buff"){
                    # Self-buff (ATK+N or DEF+N) for ~3 turns
                    $effectStr = "$($eAbility.Effect)"
                    $val = [int]($effectStr -replace '[^0-9]','')
                    if($effectStr -match 'ATK'){
                        $enemyBonusATK += $val
                        [void]$combatLog.Add(@{Text="<< $($e.DisplayName) uses $($eAbility.Name) — ATK +$val!";Color="DarkYellow"})
                    } elseif($effectStr -match 'DEF'){
                        $enemyBonusDEF += $val
                        [void]$combatLog.Add(@{Text="<< $($e.DisplayName) uses $($eAbility.Name) — DEF +$val!";Color="DarkCyan"})
                    }
                    $enemyBuffTurns = 3
                    $cd = if($eAbility.Cooldown){[int]$eAbility.Cooldown}else{4}
                    $enemyAbilityCD[$eAbility.Name] = $cd
                }
                else {
                    # Damaging ability or basic attack
                    if((Get-Random -Max 100) -ge $enemyHitChance){
                        $aName = if($eAbility.Name -eq "Attack"){"attacks"}else{"uses $($eAbility.Name)"}
                        [void]$combatLog.Add(@{Text="<< $($e.DisplayName) $aName but MISSES!";Color="DarkGray"})
                    } else {
                        # Stance multiplier applies to player DEF before incoming damage calc
                        $totalPlayerDEF = [int][math]::Floor(($p.DEF + $armorDEF + $defBuff) * (Get-StanceDEFMult))
                        # Defending DOUBLES the (already-stance-modified) DEF this turn
                        if($playerDefending){ $totalPlayerDEF = $totalPlayerDEF * 2 }

                        $effATK = $e.ATK + $enemyBonusATK
                        $effMAG = $e.MAG + $enemyBonusATK   # buff helps both

                        if($eAbility.Type -eq "Normal"){
                            $eRaw = $effATK - [math]::Floor($totalPlayerDEF * 0.5)
                            $eDmg = [math]::Max($eRaw + (Get-Random -Min -2 -Max 3), 1)
                        } else {
                            $eBase = if($eAbility.Type -eq "Magic"){$effMAG}else{$effATK}
                            $eRaw = $eBase + $eAbility.Power - [math]::Floor($totalPlayerDEF * 0.4)
                            $eDmg = [math]::Max($eRaw + (Get-Random -Min -1 -Max 4), 1)
                        }
                        # Enemy crit roll: 2x damage if it lands
                        $eIsCrit = ((Get-Random -Max 100) -lt $enemyCritChance)
                        if($eIsCrit){ $eDmg *= 2 }
                        Show-EnemyAttackAnim $eDmg
                        $p.HP -= $eDmg
                        $aName = if($eAbility.Name -eq "Attack"){"attacks"}else{"uses $($eAbility.Name)"}
                        $defNote = if($playerDefending){" (defended!)"}else{""}
                        if($eIsCrit){
                            [void]$combatLog.Add(@{Text="<< CRITICAL! $($e.DisplayName) $aName for $eDmg!$defNote";Color="Red"})
                        } else {
                            [void]$combatLog.Add(@{Text="<< $($e.DisplayName) $aName for $eDmg!$defNote";Color="Red"})
                        }

                        # Armor durability: 50% chance a random equipped piece loses 1
                        if((Get-Random -Max 100) -lt 50){
                            $armorSlots = @("Helmet","Chest","Shield","Amulet","Boots")
                            $wornSlots = @($armorSlots | Where-Object { $script:EquippedArmor[$_] -and $script:EquippedArmor[$_].Durability -gt 0 })
                            if($wornSlots.Count -gt 0){
                                $hitSlot = $wornSlots | Get-Random
                                $piece = $script:EquippedArmor[$hitSlot]
                                $piece.Durability--
                                if($piece.Durability -le 0){
                                    [void]$combatLog.Add(@{Text="   *SNAP* Your $($piece.Name) is DESTROYED — 0 DEF!";Color="Red"})
                                } elseif($piece.Durability -eq [int]($piece.MaxDurability * 0.25)){
                                    [void]$combatLog.Add(@{Text="   Your $($piece.Name) is battered — durability low!";Color="DarkYellow"})
                                }
                            }
                        }
                    }
                    # Set cooldown for ability (basic Attack always has cd=0)
                    if($eAbility.Cooldown -and [int]$eAbility.Cooldown -gt 0){
                        $enemyAbilityCD[$eAbility.Name] = [int]$eAbility.Cooldown
                    }

                    # Boss telegraph for next turn (25% chance, if healthy enough)
                    if($e.IsBoss -and -not $e.TelegraphNext -and -not $forcedBossAbility -and (Get-Random -Max 100) -lt 25){
                        $e.TelegraphNext = $true
                        [void]$combatLog.Add(@{Text="<< $($e.DisplayName) begins CHARGING a devastating attack! DEFEND!";Color="DarkYellow"})
                    }
                }
            }

            # Tick down enemy ability cooldowns at end of enemy turn
            if($enemyAbilityCD.Count -gt 0){
                $cdKeys = @($enemyAbilityCD.Keys)
                foreach($cdN in $cdKeys){
                    if($enemyAbilityCD[$cdN] -gt 0){ $enemyAbilityCD[$cdN]-- }
                }
            }
            # Tick down enemy buff timer
            if($enemyBuffTurns -gt 0){
                $enemyBuffTurns--
                if($enemyBuffTurns -le 0 -and ($enemyBonusATK -gt 0 -or $enemyBonusDEF -gt 0)){
                    [void]$combatLog.Add(@{Text="<< $($e.DisplayName)'s buff fades.";Color="DarkGray"})
                    $enemyBonusATK = 0
                    $enemyBonusDEF = 0
                }
            }
        }
        # ── Partner: Healer ──
        if($script:Partner -and $script:Partner.Class -eq "Healer" -and $p.HP -gt 0 -and !$fled){
            $hpPctCheck = $p.HP / $p.MaxHP
            if($hpPctCheck -lt 0.5 -and (Get-Random -Max 100) -lt 30){
                $partnerHeal = Get-Random -Min 15 -Max 26
                $actualHeal = [math]::Min($partnerHeal, $p.MaxHP - $p.HP)
                $p.HP += $actualHeal
                [void]$combatLog.Add(@{Text="<< $($script:Partner.Name) heals you for $actualHeal HP!";Color="Green"})
            }
        }

        # Decrement Defend cooldown
        if($defendCooldown -gt 0 -and $acted){
            $defendCooldown--
        }

        # Tick down per-ability cooldowns (each acted turn).
        if($acted -and $abilityCooldowns.Count -gt 0){
            $cdKeys = @($abilityCooldowns.Keys)
            foreach($cdName in $cdKeys){
                if($abilityCooldowns[$cdName] -gt 0){
                    $abilityCooldowns[$cdName]--
                }
            }
        }

        # Decrement Luck
        if($script:LuckTurnsLeft -gt 0 -and $acted){
            $script:LuckTurnsLeft--
            if($script:LuckTurnsLeft -le 0){
                $script:LuckBonus = 0
                $playerCritChance = Get-PlayerCrit $p.SPD 0
                [void]$combatLog.Add(@{Text="   Luck potion wears off.";Color="DarkGray"})
            }
        }

    }

    # ── Outcome ──
    if($p.HP -le 0){
        $p.HP = 0
        # Streak reset
        $script:Streak = 0
        # Clear luck
        $script:LuckTurnsLeft = 0; $script:LuckBonus = 0
        return @{Result="Death"}
    }
    if($fled){
        $script:LuckTurnsLeft = 0; $script:LuckBonus = 0
        return @{Result="Fled"}
    }

    # ── Victory ──
    $script:KillCount++
    $script:TotalKills++
    Update-QuestProgress "Kill"
    if($e.IsMiniBoss){ Update-QuestProgress "MiniBoss" }
    if($e.IsBoss){
        Update-QuestProgress "Boss"
        $script:BossesDefeated++
    }
    # Bare-handed quest: credit only if no weapon was equipped during the fight.
    if(-not $script:EquippedWeapon){
        Update-QuestProgress "BareHands"; $script:TotalBareKills++
    }

    clr
    Write-CL ("=" * 70) "Green"
    Write-CL "  V I C T O R Y" "Green"
    Write-CL ("=" * 70) "Green"
    Write-Host ""

    # Death dissolve animation on the enemy
    for($fade=0;$fade -lt 3;$fade++){
        clr
        Write-CL ("=" * 70) "Green"
        Write-CL "  V I C T O R Y" "Green"
        Write-CL ("=" * 70) "Green"
        Write-Host ""
        $fadeColor = switch($fade){0{"DarkGray"}1{"DarkBlue"}2{"Black"}}
        foreach($line in $enemyArt){
            Write-CL "  $line" $fadeColor
        }
        Start-Sleep -Milliseconds 140
    }
    clr
    Write-CL ("=" * 70) "Green"
    Write-CL "  V I C T O R Y" "Green"
    Write-CL ("=" * 70) "Green"
    Write-Host ""
    Write-CL "  $($e.DisplayName) defeated!" "Green"
    Write-Host ""

    # Apply Bard XP bonus
    $xpGain = $e.XP
    if($script:Partner -and $script:Partner.Class -eq "Bard"){
        $xpBonus = [math]::Floor($e.XP * 0.25)
        $xpGain += $xpBonus
    }
    $script:XP += $xpGain
    Write-CL "  + $xpGain XP" "Cyan"
    if($script:Partner -and $script:Partner.Class -eq "Bard"){
        Write-CL "    ($($script:Partner.Name): +$xpBonus bonus XP)" "DarkCyan"
    }

    # Apply Thief gold bonus, plus streak multiplier
    $goldGain = $e.Gold
    if($script:Partner -and $script:Partner.Class -eq "Thief"){
        $goldBonus = [math]::Floor($e.Gold * 0.15)
        $goldGain += $goldBonus
    }
    if($script:Streak -ge 2){
        $streakBonus = [math]::Floor($goldGain * 0.15 * [math]::Min($script:Streak, 6))
        $goldGain += $streakBonus
        Write-CL "  + $streakBonus Gold (streak bonus x$($script:Streak))" "Yellow"
    }
    # Gold goes through the loot screen now — flows better visually with the
    # rest of the drops. Always free weight, but listed alongside loot items.

    # ── Build loot pile from this enemy ──
    $lootPile = @()
    if($goldGain -gt 0){
        $lootPile += @{
            Name     = "Gold ($goldGain)"
            Kind     = "Gold"
            Quantity = $goldGain
            Weight   = 0
            Value    = $goldGain
        }
    }
    if($e.Loot){
        $lootPile += (Init-ItemWeight $e.Loot "Loot")
    }
    # Mini-boss / boss may drop weapon and/or armor (set on enemy by factory)
    if($e.WeaponDrop){
        $lootPile += (Init-ItemWeight $e.WeaponDrop "Weapon")
    }
    if($e.ArmorDrop){
        $lootPile += (Init-ItemWeight $e.ArmorDrop "Armor")
    }
    # Potion drop: regular 12%, mini-boss 25%, boss 40%
    $potionDropChance = if($e.IsBoss){40}elseif($e.IsMiniBoss){25}else{12}
    if((Get-Random -Max 100) -lt $potionDropChance){
        $potShop = Get-PotionShop
        if($potShop -and $potShop.Count -gt 0){
            $potTemplate = $potShop | Get-Random
            $potCopy = @{}
            foreach($k in $potTemplate.Keys){ $potCopy[$k] = $potTemplate[$k] }
            # Determine kind by Type field
            if($potCopy.Type -in @("Throw","ThrowPoison","ThrowSlow")){
                $potCopy.Kind = "Throwable"
            } else {
                $potCopy.Kind = "Potion"
            }
            $potCopy.Weight = 1
            $lootPile += $potCopy
        }
    }
    if($e.DropsKey){
        $script:HasBossKey = $true; $script:Dungeon.HasBossKey = $true
        Write-Host ""
        Write-CL "  *** BOSS KEY ACQUIRED! ***" "Magenta"
        Write-CL "  You can now unlock the Boss Room!" "Magenta"
    }
    if($e.IsBoss){
        $script:BossDefeated = $true; $script:Dungeon.BossDefeated = $true
        Write-Host ""
        Write-CL "  *** DUNGEON BOSS DEFEATED! ***" "Yellow"
        Write-CL "  Find the exit to complete the dungeon!" "Yellow"
    }

    # Show loot screen if there's anything droppable
    if($lootPile.Count -gt 0){
        Wait-Key
        $taken = Show-LootScreen -Title "$($e.Name) DROPPED" -Items $lootPile
        if($taken.Count -gt 0){
            clr
            Write-Host ""
            Write-CL "  Loot stowed:" "Magenta"
            foreach($t in $taken){
                $kindTag = switch($t.Kind){"Weapon"{"[Wpn]"}"Armor"{"[Arm]"}default{""}}
                Write-CL "    + $($t.Name) $kindTag" "Magenta"
            }
            Write-Host ""
        } else {
            Write-CL "  Nothing taken." "DarkGray"
            Write-Host ""
        }
    }
    while($script:XP -ge $script:XPToNext){
        $script:XP -= $script:XPToNext
        $script:PlayerLevel++
        $script:XPToNext = [math]::Floor($script:XPToNext * 1.5)
        $p.MaxHP += 10; $p.HP = $p.MaxHP; $p.MaxMP += 5; $p.MP = $p.MaxMP
        $p.ATK += 2; $p.DEF += 2; $p.SPD += 1; $p.MAG += 2
        Write-Host ""
        Write-CL "  *** LEVEL UP! Now Level $($script:PlayerLevel)! ***" "Yellow"
        Write-CL "  All stats increased! HP & MP fully restored!" "Yellow"
        # Ability tier upgrade notification at milestone levels
        if($script:PlayerLevel -in @(5,10,15)){
            $newTier = Get-AbilityTier $script:PlayerLevel
            Write-CL "  *** ABILITIES UPGRADED TO TIER $newTier! ***" "Magenta"
            Write-CL "  Your abilities now hit harder. (+25% Pwr per tier)" "Magenta"
        }
    }

    # Check for achievements after each victory
    Check-Achievements

    Wait-Key
    return @{Result="Won"}
}


function Show-GuildHall {
    $ghLoop = $true
    while($ghLoop){
        clr
        Write-Host ""
        # 60-char-wide banner (interior 56)
        Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkYellow"
        Write-CL "  ║                    G U I L D   H A L L                   ║" "Yellow"
        Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkYellow"
        Write-Host ""
        # Guild house ASCII (roughly 30 wide)
        Write-CL "          _______|__________|_______          " "DarkGray"
        Write-CL "         |  __   __   __   __  |         " "DarkGray"
        Write-CL "         | |  | |  | |  | |  | |         " "DarkYellow"
        Write-CL "         | |__| |__| |__| |__| |         " "DarkGray"
        Write-CL "         |                     |         " "DarkGray"
        Write-CL "         |  ADVENTURERS GUILD  |         " "Yellow"
        Write-CL "         |       _______       |         " "DarkGray"
        Write-CL "         |      |       |      |         " "DarkYellow"
        Write-CL "         |______|       |______|         " "DarkGray"
        Write-Host ""

        Write-C "  Gold: " "DarkGray"; Write-CL "$($script:Gold)g" "Yellow"
        Write-Host ""

        # ── Current Ally box (60 char wide, interior 56) ──
        $bar = "═" * 56
        if($script:Partner){
            Write-CL "  ╔$bar╗" "DarkCyan"
            Write-C "  ║ " "DarkCyan"; Write-C "C U R R E N T   A L L Y" "Cyan"
            $hdr = "C U R R E N T   A L L Y"
            $hpad = 55 - $hdr.Length
            Write-CL ("$(' ' * $hpad)║") "DarkCyan"
            Write-CL "  ╠$bar╣" "DarkCyan"

            $allyLine = "$($script:Partner.Name)  ($($script:Partner.Class))"
            Write-C "  ║ " "DarkCyan"
            Write-C "$($script:Partner.Name)" "Green"
            Write-C "  ($($script:Partner.Class))" "Cyan"
            $allyPad = 55 - $allyLine.Length
            if($allyPad -lt 0){$allyPad=0}
            Write-CL "$(' ' * $allyPad)║" "DarkCyan"

            Write-C "  ║ " "DarkCyan"
            Write-C $script:Partner.Desc "DarkGray"
            $dPad = 55 - $script:Partner.Desc.Length
            if($dPad -lt 0){$dPad=0}
            Write-CL "$(' ' * $dPad)║" "DarkCyan"

            Write-CL "  ╚$bar╝" "DarkCyan"
            Write-Host ""
        } else {
            Write-CL "  You have no ally. Recruit one below!" "DarkGray"
            Write-Host ""
        }

        $followers = @(
            @{
                Name="Sister Maren"; Class="Healer"; Price=200
                Desc="Heals you when HP drops below 50%"
                Detail="30% chance to heal 15-25 HP after each combat turn"
                Color="Green"
            }
            @{
                Name="Fingers McGee"; Class="Thief"; Price=250
                Desc="+15% gold from enemy defeats"
                Detail="Flat 15% bonus gold added to all combat rewards"
                Color="Yellow"
            }
            @{
                Name="Lyric the Wise"; Class="Bard"; Price=225
                Desc="+25% XP from all sources"
                Detail="25% bonus XP from combat victories and quests"
                Color="Cyan"
            }
        )

        # Recruits box (same 60/56 width)
        Write-CL "  ╔$bar╗" "DarkGreen"
        Write-C "  ║ " "DarkGreen"
        Write-C "A V A I L A B L E   R E C R U I T S" "Green"
        $rhdr = "A V A I L A B L E   R E C R U I T S"
        $rhpad = 55 - $rhdr.Length
        Write-CL ("$(' ' * $rhpad)║") "DarkGreen"
        Write-CL "  ╠$bar╣" "DarkGreen"

        for($i=0;$i -lt $followers.Count;$i++){
            $f = $followers[$i]
            $affordable = if($script:Gold -ge $f.Price){"Green"}else{"DarkGray"}
            $recruited = if($script:Partner -and $script:Partner.Class -eq $f.Class){" [RECRUITED]"}else{""}

            # Line 1: "[N] Name  (Class) [RECRUITED]"
            $line1 = "[$($i+1)] $($f.Name)  ($($f.Class))$recruited"
            Write-C "  ║ " "DarkGreen"
            Write-C "[$($i+1)] " $affordable
            Write-C "$($f.Name)" $f.Color
            Write-C "  ($($f.Class))" "DarkGray"
            if($recruited){Write-C $recruited "Green"}
            $pad1 = 55 - $line1.Length
            if($pad1 -lt 0){$pad1=0}
            Write-CL "$(' ' * $pad1)║" "DarkGreen"

            # Line 2: indented Desc
            $line2 = "     $($f.Desc)"
            Write-C "  ║ " "DarkGreen"
            Write-C $line2 "White"
            $pad2 = 55 - $line2.Length
            if($pad2 -lt 0){$pad2=0}
            Write-CL "$(' ' * $pad2)║" "DarkGreen"

            # Line 3: indented Detail
            $line3 = "     $($f.Detail)"
            Write-C "  ║ " "DarkGreen"
            Write-C $line3 "DarkGray"
            $pad3 = 55 - $line3.Length
            if($pad3 -lt 0){$pad3=0}
            Write-CL "$(' ' * $pad3)║" "DarkGreen"

            # Line 4: indented Cost
            $line4 = "     Cost: $($f.Price)g"
            Write-C "  ║ " "DarkGreen"
            Write-C $line4 $affordable
            $pad4 = 55 - $line4.Length
            if($pad4 -lt 0){$pad4=0}
            Write-CL "$(' ' * $pad4)║" "DarkGreen"

            if($i -lt ($followers.Count - 1)){
                Write-CL "  ║$(' ' * 56)║" "DarkGreen"
            }
        }
        Write-CL "  ╚$bar╝" "DarkGreen"
        Write-Host ""

        # Bottom action menu (interior width 44 chars)
        $mBar = "─" * 44
        Write-CL "  ┌$mBar┐" "DarkGray"
        $row1 = " [1-3] Recruit an ally"
        $pad1 = 42 - $row1.Length
        Write-C "  │" "DarkGray"; Write-C " [1-3]" "White"; Write-C " Recruit an ally" "White"
        Write-CL ("$(' ' * $pad1) │") "DarkGray"
        if($script:Partner){
            $row2 = " [D]   Dismiss current ally"
            $pad2 = 42 - $row2.Length
            Write-C "  │" "DarkGray"; Write-C " [D]" "Red"; Write-C "   Dismiss current ally" "White"
            Write-CL ("$(' ' * $pad2) │") "DarkGray"
        }
        $row3 = " [0]   Back"
        $pad3 = 42 - $row3.Length
        Write-C "  │" "DarkGray"; Write-C " [0]" "White"; Write-C "   Back" "White"
        Write-CL ("$(' ' * $pad3) │") "DarkGray"
        Write-CL "  └$mBar┘" "DarkGray"
        Write-Host ""
        Write-C "  > " "Yellow"; $gCh = Read-Host

        switch($gCh.ToUpper()){
            {$_ -in @("1","2","3")} {
                $fIdx = [int]$_ - 1
                $f = $followers[$fIdx]
                if($script:Partner -and $script:Partner.Class -eq $f.Class){
                    Write-CL "  You've already recruited $($f.Name)!" "DarkGray"
                    Wait-Key
                }
                elseif($script:Gold -lt $f.Price){
                    Write-CL "  Not enough gold! Need $($f.Price)g." "Red"
                    Wait-Key
                } else {
                    if($script:Partner){
                        Write-CL "  $($script:Partner.Name) has been dismissed." "DarkGray"
                        Write-CL "  (No refund for previous ally)" "DarkGray"
                    }
                    $script:Gold -= $f.Price
                    $script:Partner = @{
                        Name  = $f.Name
                        Class = $f.Class
                        Desc  = $f.Desc
                    }
                    Write-Host ""
                    Write-CL "  ╔══════════════════════════════════════╗" "Green"
                    Write-CL "  ║     ALLY RECRUITED!                   ║" "Green"
                    Write-CL "  ╚══════════════════════════════════════╝" "Green"
                    Write-CL "  $($f.Name) joins your party!" "Green"
                    Write-CL "  $($f.Detail)" "DarkGray"
                    Wait-Key
                }
            }
            "D" {
                if($script:Partner){
                    Write-C "  Dismiss $($script:Partner.Name)? (y/n): " "Red"
                    $confirm = Read-Host
                    if($confirm -eq 'y'){
                        Write-CL "  $($script:Partner.Name) leaves your party." "DarkGray"
                        $script:Partner = $null
                        Wait-Key
                    }
                } else {
                    Write-CL "  No ally to dismiss." "DarkGray"
                    Wait-Key
                }
            }
            "0" { $ghLoop = $false }
        }
    }
}


# ─── MARKET SYSTEM ───────────────────────────────────────────────
function Show-Market {
    $loop = $true
    while($loop){
        clr
        Write-Host ""
        # ── User-provided market art: The Old Quarter Market ──
        # Note: Single-quoted strings so nothing like $$ or { } gets interpolated
        Write-CL '    .        *    .    *        .        *    .     *   .         ' "DarkGray"
        Write-CL ' .     *  .    .    *    .  *     .  *    .    *    .  .   *      ' "DarkGray"
        Write-CL "═══════════════════════════════════════════════════════════════════" "DarkYellow"
        Write-CL "                  [*] THE OLD QUARTER MARKET [*]                   " "Yellow"
        Write-CL "═══════════════════════════════════════════════════════════════════" "DarkYellow"
        Write-Host ""
        # Stall banners / flags
        Write-CL "         |>            |>            |>            |>              " "Red"
        Write-CL "    _____|_____   _____|_____   _____|_____   _____|_____          " "DarkYellow"
        Write-CL "   /  /  |  \  \ /  /  |  \  \ /  /  |  \  \ /  /  |  \  \         " "DarkYellow"
        Write-CL "  /  /   |   \  /  /   |   \  /  /   |   \  /  /   |   \  \        " "DarkYellow"
        Write-CL " /__/    |    \/__/    |    \/__/    |    \/__/    |    \__\       " "DarkYellow"
        # Stall names
        Write-C  " |  IRONHIDE  ||  BLADE'S    ||   MYSTIC    || GRIZZLE'S   |" "Yellow"
        Write-Host ""
        Write-C  " |  ARMORY    ||  EDGE       ||   BREWS     || LOOT & PAWN |" "Yellow"
        Write-Host ""
        Write-CL " |============||=============||=============||=============|" "DarkGray"
        Write-CL " |            ||             ||             ||             |" "DarkGray"
        # Stall contents - row by row, using Write-C for per-stall color
        Write-C  " |  T  .-.    " "Cyan"
        Write-C  "||  {======>   " "White"
        Write-C  "|| .~. .~. .~. " "Green"
        Write-CL "||  WE BUY:    |" "Magenta"
        Write-C  " | /|\/   \   " "Cyan"
        Write-C  "||             " "White"
        Write-C  "|| |R| |B| |P| " "Green"
        Write-CL "|| ~~~~~~~~~~  |" "DarkMagenta"
        Write-C  " | \|/| O |   " "Cyan"
        Write-C  "|| {===]>      " "White"
        Write-C  "|| |_| |_| |_| " "Green"
        Write-CL "|| *DRAGON     |" "Magenta"
        Write-C  " |  ^ |   |   " "Cyan"
        Write-C  "||             " "White"
        Write-C  "||             " "Green"
        Write-CL "||  SCALES     |" "Magenta"
        Write-C  " |    '---'   " "Cyan"
        Write-C  "|| ,+++++{D    " "White"
        Write-C  "|| .~.     .~. " "Green"
        Write-CL "|| *GOBLIN     |" "Magenta"
        Write-C  " |            " "Cyan"
        Write-C  "||             " "White"
        Write-C  "|| |G|     |Y| " "Green"
        Write-CL "||  TEETH      |" "Magenta"
        Write-C  " | [=|=|=]    " "Cyan"
        Write-C  "|| \\_//       " "White"
        Write-C  "|| |_|     |_| " "Green"
        Write-CL "|| *CURSED     |" "Magenta"
        Write-C  " | |     |    " "Cyan"
        Write-C  "||  |--|       " "White"
        Write-C  "||             " "Green"
        Write-CL "||  RELICS     |" "Magenta"
        Write-C  " | |#|#|#|    " "Cyan"
        Write-C  "||  |  |       " "White"
        Write-C  "||  _       _  " "Green"
        Write-CL "|| *GEM STONES |" "Magenta"
        Write-C  " | |#|#|#|    " "Cyan"
        Write-C  "||  |__|       " "White"
        Write-C  "|| | \     / | " "Green"
        Write-CL "||             |" "DarkMagenta"
        Write-C  " | |_____|    " "Cyan"
        Write-C  "||             " "White"
        Write-C  "|| |  |~~~|  | " "Green"
        Write-CL "|| .===. .===. |" "Magenta"
        Write-C  " |            " "Cyan"
        Write-C  "||   /|        " "White"
        Write-C  "|| |  | ~ |  | " "Green"
        Write-CL "|| |   | | $ | |" "Magenta"
        Write-C  " | .---.      " "Cyan"
        Write-C  "||  / |   /\   " "White"
        Write-C  "|| |  |___|  | " "Green"
        Write-CL "|| | G | | G | |" "Magenta"
        Write-C  " || H E |     " "Cyan"
        Write-C  "|| /  |  /||\  " "White"
        Write-C  "|| |_________| " "Green"
        Write-CL "|| | O | | O | |" "Magenta"
        Write-C  " || L M |     " "Cyan"
        Write-C  "||/   | / || \ " "White"
        Write-C  "||             " "Green"
        Write-CL "|| | L | | L | |" "Magenta"
        Write-C  " ||_____|     " "Cyan"
        Write-C  "||    |/  ||  \" "White"
        Write-C  "||  CAULDRON   " "Green"
        Write-CL "|| | D | | D | |" "Magenta"
        Write-C  " |            " "Cyan"
        Write-C  "||        ||   " "White"
        Write-C  "||  SPECIAL:   " "Green"
        Write-CL "|| |   | |   | |" "Magenta"
        Write-C  " | SHIELDS    " "Cyan"
        Write-C  "|| SWORDS ||   " "White"
        Write-C  "||  30 GOLD    " "Green"
        Write-CL "|| '===' '===' |" "Magenta"
        Write-C  " | 40-100g    " "Cyan"
        Write-C  "|| 50-200g||   " "White"
        Write-C  "||             " "Green"
        Write-CL "|| FAIR PRICES!|" "Magenta"
        Write-CL " |___________ ||________||___||_____________||_____________|" "DarkGray"
        Write-CL " |_||_||_||_||_||_||_||_||_||_||_||_||_||_||_||_||_||_||_|" "DarkGray"
        Write-Host ""

        # ── Gold pouch (26 wide) + Merchant Says (36 wide) side-by-side ──
        # Top borders
        Write-C  "  ┌─ Coin Pouch ───────────┐  " "Yellow"
        Write-CL "┌─ Merchant Says ──────────────────┐"  "DarkYellow"
        # Content line
        $goldText = "Gold: $($script:Gold)g"
        $goldInner = 24  # interior width of pouch (26 minus 2 walls)
        $goldPad = $goldInner - 1 - $goldText.Length  # -1 for the leading space
        if($goldPad -lt 0){$goldPad = 0}
        Write-C "  │ " "Yellow"
        Write-C $goldText "Yellow"
        Write-C (" " * $goldPad) "Black"
        Write-C "│  " "Yellow"

        $tip = switch(Get-Random -Max 5){
            0 { "'Fresh steel, barely used!'" }
            1 { "'A scythe for shadow-touched souls?'" }
            2 { "'These potions brew by moonlight.'" }
            3 { "'Your loot, my coin. Fair trade.'" }
            4 { "'Dragon-scale armor, fitted to you.'" }
        }
        $tipInner = 34
        $tipPad = $tipInner - 1 - $tip.Length
        if($tipPad -lt 0){$tipPad = 0}
        Write-C "│ " "DarkYellow"
        Write-C $tip "DarkYellow"
        Write-C (" " * $tipPad) "Black"
        Write-CL "│" "DarkYellow"

        # Bottom borders
        Write-C  "  └─────────────────────────┘  " "Yellow"
        Write-CL "└──────────────────────────────────┘"  "DarkYellow"
        Write-Host ""

        # ── Action menu: single clean 2-column box ──
        # Column interior width = 30, total box = 2*(30)+3 = 63 between ┌ and ┐
        $colW = 30
        $bar = "─" * $colW
        Write-CL "  ┌$bar┬$bar┐" "DarkGray"

        $actions = @(
            @( @{N="[1]";L="Weapons Stall";      C="Yellow"},
               @{N="[2]";L="Armor Stall";        C="Cyan"} ),
            @( @{N="[3]";L="Potions & Elixirs";  C="Green"},
               @{N="[4]";L="Sell Your Loot";     C="Magenta"} ),
            @( @{N="[5]";L="Locksmith (picks)";  C="DarkCyan"},
               @{N="[6]";L="Blacksmith (repair)";C="DarkRed"} ),
            @( @{N="[7]";L="Leave the bazaar";   C="DarkGray"},
               @{N=""   ;L="";                   C="DarkGray"} )
        )
        foreach($r in $actions){
            $lCell = " $($r[0].N) $($r[0].L)"
            $rCell = if($r[1].N){ " $($r[1].N) $($r[1].L)" } else { "" }
            $lPad = $colW - $lCell.Length
            if($lPad -lt 0){$lPad = 0}
            $rPad = $colW - $rCell.Length
            if($rPad -lt 0){$rPad = 0}

            Write-C "  │" "DarkGray"
            if($r[0].N){
                Write-C " $($r[0].N)" $r[0].C
                Write-C " $($r[0].L)" "White"
            }
            Write-C (" " * $lPad) "Black"
            Write-C "│" "DarkGray"

            if($r[1].N){
                Write-C " $($r[1].N)" $r[1].C
                Write-C " $($r[1].L)" "White"
            }
            Write-C (" " * $rPad) "Black"
            Write-CL "│" "DarkGray"
        }
        Write-CL "  └$bar┴$bar┘" "DarkGray"
        Write-Host ""
        Write-C "  > " "Yellow"; $ch=Read-Host

        switch($ch){
            # ═══════════════════════════════════════════
            #  WEAPON SHOP
            # ═══════════════════════════════════════════
            "1" {
                $wepLoop = $true
                while($wepLoop){
                    clr
                    Write-CL "  ╔════════════════════════════════════════════════════════╗" "DarkCyan"
                    Write-CL "  ║                  W E A P O N S                         ║" "Cyan"
                    Write-CL "  ╚════════════════════════════════════════════════════════╝" "DarkCyan"
                    Write-Host ""
                    Write-C "  Gold: " "DarkGray"; Write-CL "$($script:Gold)g" "Yellow"
                    Write-C "  Class: " "DarkGray"; Write-CL "$($script:PlayerClass)" "Cyan"
                    Write-C "  Equipped: " "DarkGray"
                    if($script:EquippedWeapon){
                        $wb = Get-WeaponClassBonus
                        $wbStr = if($wb -gt 0){" [+$wb class bonus]"}else{""}
                        Write-CL "$($script:EquippedWeapon.Name) (ATK+$($script:EquippedWeapon.ATK)$wbStr)" "Cyan"
                    } else { Write-CL "Bare Hands" "DarkGray" }
                    Write-Host ""

                    Write-CL "  Select weapon category:" "White"
                    Write-Host ""
                    $catData = @(
                        @{Key="Sword";  Label="Swords";  Classes=@("Knight","Berserker"); Color="Yellow"}
                        @{Key="Staff";  Label="Staves";  Classes=@("Mage","Warlock");     Color="Cyan"}
                        @{Key="Fist";   Label="Fists";   Classes=@("Brawler");            Color="Red"}
                        @{Key="Bow";    Label="Bows";    Classes=@("Ranger");             Color="Green"}
                        @{Key="Mace";   Label="Maces";   Classes=@("Cleric");             Color="White"}
                        @{Key="Scythe"; Label="Scythes"; Classes=@("Necromancer");        Color="Magenta"}
                    )
                    for($ci=0;$ci -lt $catData.Count;$ci++){
                        $cat = $catData[$ci]
                        $match = if($cat.Classes -contains $script:PlayerClass){" << YOUR CLASS"}else{""}
                        $classList = ($cat.Classes -join "/") + " affinity"
                        Write-C "  [$($ci+1)] " "White"
                        Write-C "$($cat.Label.PadRight(10))" $cat.Color
                        Write-C "($classList)" "DarkGray"
                        Write-CL $match "Green"
                    }
                    Write-CL "  [7] Other Weapons" "DarkGray"
                    Write-CL "  [0] Back to Market" "DarkGray"
                    Write-Host ""
                    Write-C "  > " "Yellow"; $wCat = Read-Host

                    if($wCat -eq "0"){ $wepLoop = $false; continue }

                    # Determine filter
                    $allWeapons = Get-WeaponShop
                    $typeFilter = switch($wCat){
                        "1"{"Sword"} "2"{"Staff"} "3"{"Fist"} "4"{"Bow"}
                        "5"{"Mace"} "6"{"Scythe"} "7"{"Other"} default{$null}
                    }
                    if(-not $typeFilter){ continue }

                    if($typeFilter -eq "Other"){
                        $filtered = $allWeapons | Where-Object { $_.WeaponType -notin @("Sword","Staff","Fist","Bow","Mace","Scythe") }
                    } else {
                        $filtered = $allWeapons | Where-Object { $_.WeaponType -eq $typeFilter }
                    }
                    $filtered = @($filtered)
                    if($filtered.Count -eq 0){
                        Write-CL "  No weapons in this category." "DarkGray"
                        Wait-Key; continue
                    }

                    clr
                    Write-CL "  ╔════════════════════════════════════════════════════════╗" "DarkCyan"
                    $catLabel = if($typeFilter -eq "Other"){"OTHER WEAPONS"}else{$typeFilter.ToUpper() + "S"}
                    Write-CL "  ║  $($catLabel.PadRight(52))║" "Cyan"
                    Write-CL "  ╚════════════════════════════════════════════════════════╝" "DarkCyan"
                    Write-Host ""
                    Write-C "  Gold: " "DarkGray"; Write-CL "$($script:Gold)g" "Yellow"
                    Write-Host ""

                    # Column widths (interior — dashes in border = spaces in data)
                    # Row = "│" + cw1 + "│" + cw2 + "│" + cw3 + "│" + cw4 + "│" + cw5 + "│" + cw6 + "│"
                    $cw1 = 5   # #
                    $cw2 = 18  # Weapon
                    $cw3 = 8   # ATK
                    $cw4 = 9   # Price
                    $cw5 = 10  # Perk
                    $cw6 = 10  # Bonus

                    $top = "  ┌$('─'*$cw1)┬$('─'*$cw2)┬$('─'*$cw3)┬$('─'*$cw4)┬$('─'*$cw5)┬$('─'*$cw6)┐"
                    $mid = "  ├$('─'*$cw1)┼$('─'*$cw2)┼$('─'*$cw3)┼$('─'*$cw4)┼$('─'*$cw5)┼$('─'*$cw6)┤"
                    $bot = "  └$('─'*$cw1)┴$('─'*$cw2)┴$('─'*$cw3)┴$('─'*$cw4)┴$('─'*$cw5)┴$('─'*$cw6)┘"

                    $headerRow = "  │" + (Pad-Cell "#" $cw1) + "│" + (Pad-Cell "Weapon" $cw2) + "│" + (Pad-Cell "ATK" $cw3) + "│" + (Pad-Cell "Price" $cw4) + "│" + (Pad-Cell "Perk" $cw5) + "│" + (Pad-Cell "Bonus" $cw6) + "│"

                    Write-CL $top "DarkGray"
                    Write-CL $headerRow "DarkGray"
                    Write-CL $mid "DarkGray"

                    for($i=0;$i -lt $filtered.Count;$i++){
                        $w = $filtered[$i]
                        $idxCell   = Pad-Cell ("$($i+1)") $cw1
                        $nameCell  = Pad-Cell $w.Name $cw2
                        $atkCell   = Pad-Cell ("+$($w.ATK)") $cw3
                        $priceCell = Pad-Cell ("$($w.Price)g") $cw4

                        $perkText   = if($w.Perk){"$($w.Perk)"}else{"---"}
                        $perkCell   = Pad-Cell $perkText $cw5

                        $magStr = if($w.MAGBonus){"M+$($w.MAGBonus)"}else{""}
                        $isMatch = Test-WeaponClassMatch $w
                        $bonusText = if($isMatch){"ATK+$($w.AffinityBonus)"}else{"---"}
                        if($magStr -and $bonusText -ne "---"){ $bonusText = "$bonusText $magStr" }
                        elseif($magStr){ $bonusText = $magStr }
                        $bonusCell = Pad-Cell $bonusText $cw6

                        $affordable = if($script:Gold -ge $w.Price){"Green"}else{"DarkGray"}
                        $perkColor  = switch($w.Perk){"Bleed"{"DarkRed"}"Burn"{"DarkYellow"}"Poison"{"DarkGreen"}"Drain"{"Magenta"}"Stun"{"Yellow"}default{"DarkGray"}}
                        $bonusColor = if($isMatch){"Green"}else{"DarkGray"}

                        Write-C "  │" "DarkGray"
                        Write-C $idxCell $affordable
                        Write-C "│" "DarkGray"
                        Write-C $nameCell "Cyan"
                        Write-C "│" "DarkGray"
                        Write-C $atkCell "White"
                        Write-C "│" "DarkGray"
                        Write-C $priceCell $affordable
                        Write-C "│" "DarkGray"
                        Write-C $perkCell $perkColor
                        Write-C "│" "DarkGray"
                        Write-C $bonusCell $bonusColor
                        Write-CL "│" "DarkGray"
                    }
                    Write-CL $bot "DarkGray"
                    Write-Host ""
                    Write-CL "  Bonus column shows extra ATK when YOUR class matches." "DarkGray"
                    Write-CL "  Perks trigger randomly on basic attacks." "DarkGray"
                    Write-Host ""
                    Write-C "  Buy # (0=back): " "Yellow"; $bi=Read-Host
                    $widx=[int]$bi - 1
                    if($widx -ge 0 -and $widx -lt $filtered.Count){
                        $w = $filtered[$widx]
                        if($script:Gold -ge $w.Price){
                            $script:Gold -= $w.Price
                            $newWeapon = Init-ItemDurability $w
                            if(-not $newWeapon.Kind){ $newWeapon.Kind = "Weapon" }
                            $script:WeaponsOwned[$w.Name] = $true
                            Invoke-GearAcquired -Item $newWeapon -Kind "Weapon"
                            $cb = Get-WeaponClassBonus
                            if($cb -gt 0 -and $script:EquippedWeapon -eq $newWeapon){
                                Write-CL "  Class bonus active! +$cb ATK" "Green"
                            }
                            if($w.Perk -and $script:EquippedWeapon -eq $newWeapon){
                                Write-CL "  Weapon perk: $($w.Perk) ($($w.PerkChance)% chance on attack)" "DarkYellow"
                            }
                            Check-Achievements
                        } else { Write-CL "  Not enough gold!" "Red" }
                        Wait-Key
                    }
                }
            }

            # ═══════════════════════════════════════════
            #  ARMOR SHOP
            # ═══════════════════════════════════════════
            "2" {
                $armorLoop = $true
                while($armorLoop){
                    clr
                    Write-CL "  ╔════════════════════════════════════════════════════════╗" "DarkCyan"
                    Write-CL "  ║                    A R M O R                           ║" "Cyan"
                    Write-CL "  ╚════════════════════════════════════════════════════════╝" "DarkCyan"
                    Write-Host ""
                    Write-C "  Gold: " "DarkGray"; Write-CL "$($script:Gold)g" "Yellow"
                    Write-C "  Total Armor DEF: " "DarkGray"; Write-CL "+$(Get-TotalArmorDEF)" "Cyan"
                    Write-Host ""

                    # Show current equipment
                    Write-CL "  ── Currently Equipped ──" "DarkGray"
                    $slots = @("Helmet","Chest","Shield","Amulet","Boots")
                    for($si=0;$si -lt $slots.Count;$si++){
                        $slot = $slots[$si]
                        $piece = $script:EquippedArmor[$slot]
                        $slotStr = "$($slot):".PadRight(9)
                        Write-C "  [$($si+1)] $slotStr" "White"
                        if($piece){
                            Write-CL "$($piece.Name) (DEF+$($piece.DEF))" "Cyan"
                        } else {
                            Write-CL "(empty)" "DarkGray"
                        }
                    }
                    Write-Host ""
                    Write-CL "  [0] Back to Market" "DarkGray"
                    Write-Host ""
                    Write-C "  Select slot to browse: " "Yellow"; $slotPick = Read-Host

                    if($slotPick -eq "0"){ $armorLoop = $false; continue }
                    $sIdx = (ConvertTo-SafeInt -Value $slotPick) - 1
                    if($sIdx -lt 0 -or $sIdx -ge $slots.Count){ continue }
                    $chosenSlot = $slots[$sIdx]

                    # Show armor for that slot
                    $allArmor = Get-ArmorShop
                    $slotArmor = @($allArmor | Where-Object { $_.Slot -eq $chosenSlot })

                    clr
                    Write-CL "  ╔════════════════════════════════════════════════════════╗" "DarkCyan"
                    Write-CL "  ║  $($chosenSlot.ToUpper().PadRight(52))║" "Cyan"
                    Write-CL "  ╚════════════════════════════════════════════════════════╝" "DarkCyan"
                    Write-Host ""
                    Write-C "  Gold: " "DarkGray"; Write-CL "$($script:Gold)g" "Yellow"
                    $current = $script:EquippedArmor[$chosenSlot]
                    Write-C "  Current: " "DarkGray"
                    if($current){ Write-CL "$($current.Name) (DEF+$($current.DEF))" "Cyan" }
                    else { Write-CL "(empty)" "DarkGray" }
                    Write-Host ""

                    # Column widths
                    $cw1 = 5   # #
                    $cw2 = 18  # Armor name
                    $cw3 = 8   # DEF
                    $cw4 = 9   # Price
                    $cw5 = 6   # Equipped marker

                    $top = "  ┌$('─'*$cw1)┬$('─'*$cw2)┬$('─'*$cw3)┬$('─'*$cw4)┬$('─'*$cw5)┐"
                    $mid = "  ├$('─'*$cw1)┼$('─'*$cw2)┼$('─'*$cw3)┼$('─'*$cw4)┼$('─'*$cw5)┤"
                    $bot = "  └$('─'*$cw1)┴$('─'*$cw2)┴$('─'*$cw3)┴$('─'*$cw4)┴$('─'*$cw5)┘"

                    $headerRow = "  │" + (Pad-Cell "#" $cw1) + "│" + (Pad-Cell "Armor" $cw2) + "│" + (Pad-Cell "DEF" $cw3) + "│" + (Pad-Cell "Price" $cw4) + "│" + (Pad-Cell "" $cw5) + "│"

                    Write-CL $top "DarkGray"
                    Write-CL $headerRow "DarkGray"
                    Write-CL $mid "DarkGray"

                    for($i=0;$i -lt $slotArmor.Count;$i++){
                        $a = $slotArmor[$i]
                        $idxCell   = Pad-Cell ("$($i+1)") $cw1
                        $nameCell  = Pad-Cell $a.Name $cw2
                        $defCell   = Pad-Cell ("+$($a.DEF)") $cw3
                        $priceCell = Pad-Cell ("$($a.Price)g") $cw4
                        $equipped = if($current -and $current.Name -eq $a.Name){"[ON]"}else{""}
                        $eqCell    = Pad-Cell $equipped $cw5

                        $affordable = if($script:Gold -ge $a.Price){"Green"}else{"DarkGray"}

                        Write-C "  │" "DarkGray"
                        Write-C $idxCell $affordable
                        Write-C "│" "DarkGray"
                        Write-C $nameCell "Cyan"
                        Write-C "│" "DarkGray"
                        Write-C $defCell "White"
                        Write-C "│" "DarkGray"
                        Write-C $priceCell $affordable
                        Write-C "│" "DarkGray"
                        Write-C $eqCell "Yellow"
                        Write-CL "│" "DarkGray"
                    }
                    Write-CL $bot "DarkGray"
                    Write-Host ""
                    Write-C "  Buy # (0=back): " "Yellow"; $aPick = Read-Host
                    $aIdx = (ConvertTo-SafeInt -Value $aPick) - 1
                    if($aIdx -ge 0 -and $aIdx -lt $slotArmor.Count){
                        $a = $slotArmor[$aIdx]
                        if($script:Gold -ge $a.Price){
                            $script:Gold -= $a.Price
                            $newArmor = Init-ItemDurability $a
                            if(-not $newArmor.Kind){ $newArmor.Kind = "Armor" }
                            if(-not $newArmor.Slot){ $newArmor.Slot = $chosenSlot }
                            $script:ArmorOwned[$a.Name] = $true
                            Invoke-GearAcquired -Item $newArmor -Kind "Armor"
                            Write-CL "  Total Armor DEF: +$(Get-TotalArmorDEF)" "Cyan"
                            Check-Achievements
                        } else { Write-CL "  Not enough gold!" "Red" }
                        Wait-Key
                    }
                }
            }

            # ═══════════════════════════════════════════
            #  POTION SHOP  (loops on purchase — player exits explicitly with 0)
            # ═══════════════════════════════════════════
            "3" {
                $potLoop = $true
                while($potLoop){
                    clr
                    Write-CL "" "Green"
                    Write-CL "  ╔════════════════════════════════════════════╗" "DarkGreen"
                    Write-CL "  ║            P O T I O N S                   ║" "Green"
                    Write-CL "  ╚════════════════════════════════════════════╝" "DarkGreen"
                    Write-Host ""
                    Write-C "  Gold: " "DarkGray"; Write-CL "$($script:Gold)g" "Yellow"
                    Write-C "  Potions: " "DarkGray"; Write-CL "$($script:Potions.Count) / 10" "Green"
                    Write-C "  Throwables: " "DarkGray"; Write-CL "$($script:ThrowablePotions.Count) / 5" "DarkYellow"
                    Write-Host ""

                    $potionShop = @(
                        @{Name="Small Health Potion"; Type="Heal";    Power=30; Price=25;  Desc="Restore 30 HP";     Icon="[HP+]";  Category="Potion"}
                        @{Name="Large Health Potion"; Type="Heal";    Power=70; Price=60;  Desc="Restore 70 HP";     Icon="[HP++]"; Category="Potion"}
                        @{Name="Mana Potion";         Type="Mana";    Power=30; Price=30;  Desc="Restore 30 MP";     Icon="[MP+]";  Category="Potion"}
                        @{Name="Large Mana Potion";   Type="Mana";    Power=60; Price=55;  Desc="Restore 60 MP";     Icon="[MP++]"; Category="Potion"}
                        @{Name="Strength Elixir";     Type="ATKBuff"; Power=8;  Price=75;  Desc="ATK+8 in battle";   Icon="[ATK]";  Category="Potion"}
                        @{Name="Iron Skin Elixir";    Type="DEFBuff"; Power=8;  Price=75;  Desc="DEF+8 in battle";   Icon="[DEF]";  Category="Potion"}
                        @{Name="Potion of Luck";      Type="Luck";    Power=20; Price=90;  Desc="+20% crit, 3 turns"; Icon="[LCK]";  Category="Potion"}
                        @{Name="Acid Flask";          Type="Throw";   Power=25; Price=40;  Desc="Deal 25 damage";    Icon="[DMG]";  Category="Throwable"}
                        @{Name="Poison Flask";        Type="ThrowPoison"; Power=15; Price=50; Desc="15 dmg + Poison"; Icon="[PSN]"; Category="Throwable"}
                        @{Name="Frost Bomb";          Type="ThrowSlow";  Power=20; Price=55; Desc="20 dmg + Slow";   Icon="[SLW]"; Category="Throwable"}
                    )

                    # Column widths — match borders exactly using Pad-Cell
                    $cw1 = 5   # #
                    $cw2 = 22  # Potion name
                    $cw3 = 20  # Effect
                    $cw4 = 9   # Price

                    $top = "  ┌$('─'*$cw1)┬$('─'*$cw2)┬$('─'*$cw3)┬$('─'*$cw4)┐"
                    $mid = "  ├$('─'*$cw1)┼$('─'*$cw2)┼$('─'*$cw3)┼$('─'*$cw4)┤"
                    $bot = "  └$('─'*$cw1)┴$('─'*$cw2)┴$('─'*$cw3)┴$('─'*$cw4)┘"
                    $headerRow = "  │" + (Pad-Cell "#" $cw1) + "│" + (Pad-Cell "Potion" $cw2) + "│" + (Pad-Cell "Effect" $cw3) + "│" + (Pad-Cell "Price" $cw4) + "│"

                    Write-CL "  ── Healing & Buff Potions ──" "Green"
                    Write-CL $top "DarkGray"
                    Write-CL $headerRow "DarkGray"
                    Write-CL $mid "DarkGray"

                    for($i=0;$i -lt $potionShop.Count;$i++){
                        $pt=$potionShop[$i]
                        $affordable = if($script:Gold -ge $pt.Price){"Green"}else{"DarkGray"}
                        $typeColor = switch($pt.Type){
                            "Heal"{"Green"} "Mana"{"Cyan"} "ATKBuff"{"Yellow"} "DEFBuff"{"Yellow"}
                            "Luck"{"Magenta"} "Throw"{"DarkRed"} "ThrowPoison"{"DarkGreen"} "ThrowSlow"{"DarkCyan"}
                            default{"White"}
                        }
                        if($i -eq 7){
                            # Mid-divider and THROWABLES label — width-matched to the table
                            Write-CL $mid "DarkGray"
                            $thLabel = "  │" + (Pad-Cell "" $cw1) + "│" + (Pad-Cell "-- THROWABLES --" $cw2) + "│" + (Pad-Cell "" $cw3) + "│" + (Pad-Cell "" $cw4) + "│"
                            Write-CL $thLabel "DarkYellow"
                            Write-CL $mid "DarkGray"
                        }
                        $idxCell   = Pad-Cell ("$($i+1)") $cw1
                        $nameCell  = Pad-Cell $pt.Name $cw2
                        $descCell  = Pad-Cell $pt.Desc $cw3
                        $priceCell = Pad-Cell ("$($pt.Price)g") $cw4

                        Write-C "  │" "DarkGray"
                        Write-C $idxCell $affordable
                        Write-C "│" "DarkGray"
                        Write-C $nameCell $typeColor
                        Write-C "│" "DarkGray"
                        Write-C $descCell "White"
                        Write-C "│" "DarkGray"
                        Write-C $priceCell $affordable
                        Write-CL "│" "DarkGray"
                    }
                    Write-CL $bot "DarkGray"
                    Write-Host ""
                    Write-C "  Buy # (0=leave shop): " "Yellow"; $pi2=Read-Host
                    if($pi2 -eq "0"){ $potLoop = $false; continue }
                    $pidx2=[int]$pi2 - 1
                    if($pidx2 -ge 0 -and $pidx2 -lt $potionShop.Count){
                        $pt=$potionShop[$pidx2]
                        if($pt.Category -eq "Throwable"){
                            if($script:ThrowablePotions.Count -ge 5){
                                Write-CL "  Throwable inventory full! (5/5)" "Red"
                            }
                            elseif($script:Gold -ge $pt.Price){
                                $script:Gold -= $pt.Price
                                [void]$script:ThrowablePotions.Add($pt)
                                Write-CL "  Bought $($pt.Name)!" "Green"
                            } else { Write-CL "  Not enough gold!" "Red" }
                        } else {
                            if($script:Potions.Count -ge 10){
                                Write-CL "  Potion inventory full! (10/10)" "Red"
                            }
                            elseif($script:Gold -ge $pt.Price){
                                $script:Gold -= $pt.Price
                                [void]$script:Potions.Add($pt)
                                Write-CL "  Bought $($pt.Name)!" "Green"
                            } else { Write-CL "  Not enough gold!" "Red" }
                        }
                        Start-Sleep -Milliseconds 800  # brief feedback instead of Wait-Key; loops back for another purchase
                    }
                }
            }

            # ═══════════════════════════════════════════
            #  SELL LOOT
            # ═══════════════════════════════════════════
            "4" {
                clr
                Write-CL "" "Magenta"
                Write-CL "  ╔════════════════════════════════════════════╗" "DarkMagenta"
                Write-CL "  ║           S E L L   L O O T                ║" "Magenta"
                Write-CL "  ╚════════════════════════════════════════════╝" "DarkMagenta"
                Write-Host ""
                Write-C "  Gold: " "DarkGray"; Write-CL "$($script:Gold)g" "Yellow"
                Write-Host ""

                if($script:Inventory.Count -eq 0){
                    Write-CL "  ┌─────────────────────────────────┐" "DarkGray"
                    Write-CL "  │  Your bags are empty...         │" "DarkGray"
                    Write-CL "  └─────────────────────────────────┘" "DarkGray"
                    Wait-Key
                } else {
                    Write-CL "  ┌─────┬──────────────────────┬──────────┐" "DarkGray"
                    Write-CL "  │  #  │ Item                 │ Value    │" "DarkGray"
                    Write-CL "  ├─────┼──────────────────────┼──────────┤" "DarkGray"
                    $totalVal = 0
                    for($i=0;$i -lt $script:Inventory.Count;$i++){
                        $it=$script:Inventory[$i]
                        $totalVal += $it.Value
                        $nameStr = $it.Name.PadRight(20)
                        $valStr  = ("$($it.Value)g").PadRight(8)
                        Write-C "  │ " "DarkGray"
                        Write-C " $($i+1) " "White"
                        Write-C "│ " "DarkGray"
                        Write-C "$nameStr" "Magenta"
                        Write-C "│ " "DarkGray"
                        Write-C "$valStr" "Yellow"
                        Write-CL "│" "DarkGray"
                    }
                    Write-CL "  └─────┴──────────────────────┴──────────┘" "DarkGray"
                    Write-Host ""
                    Write-CL "  Total sell value: ${totalVal}g" "Yellow"
                    Write-Host ""
                    Write-CL "  [A] Sell ALL    [#] Sell one    [0] Back" "White"
                    Write-C "  > " "Yellow"; $si=Read-Host
                    if($si -eq 'A' -or $si -eq 'a'){
                        $script:Gold += $totalVal
                        $script:Inventory.Clear()
                        Write-CL "  Sold everything for ${totalVal}g!" "Green"
                        Write-CL "  Gold: $($script:Gold)g" "Yellow"
                        Wait-Key
                    } else {
                        $sidx=[int]$si - 1
                        if($sidx -ge 0 -and $sidx -lt $script:Inventory.Count){
                            $it=$script:Inventory[$sidx]
                            $script:Gold += $it.Value
                            Write-CL "  Sold $($it.Name) for $($it.Value)g!" "Green"
                            Write-CL "  Gold: $($script:Gold)g" "Yellow"
                            $script:Inventory.RemoveAt($sidx)
                            Wait-Key
                        }
                    }
                }
            }

            # ═══════════════════════════════════════════
            #  LOCKSMITH (lockpicks)
            # ═══════════════════════════════════════════
            "5" {
                $locksmithLoop = $true
                while($locksmithLoop){
                    clr
                    Write-Host ""
                    Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkCyan"
                    Write-CL "  ║                    T H E   L O C K S M I T H             ║" "Cyan"
                    Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkCyan"
                    Write-Host ""
                    # Small locksmith stall art
                    Write-CL "          _____________" "DarkGray"
                    Write-CL "         |  _________  |" "DarkGray"
                    Write-CL "         | |  PICKS  | |" "DarkCyan"
                    Write-CL "         | |  25g ea | |" "Cyan"
                    Write-CL "         | |_________| |" "DarkGray"
                    Write-CL "         |  o=    =o   |" "DarkCyan"
                    Write-CL "         |_____________|" "DarkGray"
                    Write-Host ""
                    Write-C "  Gold: " "DarkGray"; Write-CL "$($script:Gold)g" "Yellow"
                    Write-C "  Current lockpicks: " "DarkGray"; Write-CL "$($script:Lockpicks)" "Cyan"
                    Write-Host ""
                    Write-CL "  The locksmith adjusts her monocle:" "DarkGray"
                    Write-CL "  'Need picks? 25 gold each. Say how many.'" "White"
                    Write-Host ""
                    Write-CL "  ┌──────────────────────────────────────────┐" "DarkGray"
                    Write-CL "  │  Enter quantity (0 to leave)             │" "DarkGray"
                    Write-CL "  └──────────────────────────────────────────┘" "DarkGray"
                    Write-Host ""
                    Write-C "  > " "Yellow"; $qtyStr = Read-Host
                    $qty = 0
                    if([int]::TryParse($qtyStr, [ref]$qty) -and $qty -gt 0){
                        $cost = 25 * $qty
                        if($script:Gold -ge $cost){
                            $script:Gold -= $cost
                            $script:Lockpicks += $qty
                            Write-CL "  She slides $qty pick(s) across the counter for ${cost}g." "Green"
                            Wait-Key
                        } else {
                            Write-CL "  'That'll be $cost gold — come back when you have it.'" "Red"
                            Wait-Key
                        }
                    } else {
                        $locksmithLoop = $false
                    }
                }
            }

            # ═══════════════════════════════════════════
            #  BLACKSMITH (repair gear)
            # ═══════════════════════════════════════════
            "6" { Show-Blacksmith }

            # ═══════════════════════════════════════════
            #  LEAVE MARKET
            # ═══════════════════════════════════════════
            "7" { $loop=$false }
        }
    }
}




# ─── BLACKSMITH ──────────────────────────────────────────────────
# Repair equipped weapon and/or armor pieces. Cost = (missing/max) * Price.
# Lists individually with a "Repair All" bulk option (10% discount).
# Dutchman's Blade can't be repaired (never breaks).
# ─── LOOT SCREEN (arrow-key navigation) ───────────────────────────
# Presents a list of items. Player navigates with Up/Down (or W/S),
# toggles selection with Space, views item details with V, takes all
# with A, confirms with Enter, cancels (takes nothing) with Esc.
#
# Items must be initialized with Kind/Weight before being passed in
# (use Init-ItemWeight or pass items from New-RandomLoot).
#
# Returns the list of items taken (which the caller does NOT need to
# add to inventory — this function routes them itself based on Kind).
function Show-LootScreen {
    param(
        [string]$Title = "LOOT FOUND",
        $Items = @()
    )
    # Defensive: coerce to array. PS unwraps single-element arrays in some hosts.
    if($Items -isnot [array]){ $Items = @($Items) }
    if(-not $Items -or $Items.Count -eq 0){ return @() }

    $itemCount = $Items.Count
    $marked = New-Object 'bool[]' $itemCount   # default false; user opts in
    $cursor = 0                                # which row is highlighted

    function _LootRouteAndStow {
        param($Items, $marked)
        $taken = @()
        $rejected = @()
        for($i=0; $i -lt $Items.Count; $i++){
            if(-not $marked[$i]){ continue }
            $it = $Items[$i]
            $kindKnown = $it.Kind
            # Gold pile → add to $script:Gold (always, no cap, no weight)
            if($kindKnown -eq "Gold"){
                $qty = if($it.Quantity){[int]$it.Quantity}else{0}
                $script:Gold += $qty
                $taken += $it
            }
            # Lockpicks bundle → increment $script:Lockpicks counter
            elseif($kindKnown -eq "Lockpicks"){
                $qty = if($it.Quantity){[int]$it.Quantity}else{1}
                $script:Lockpicks += $qty
                $taken += $it
            }
            # Throwables → throwable bag (max 5)
            elseif($it.Type -in @("Throw","ThrowPoison","ThrowSlow") -or $kindKnown -eq "Throwable"){
                if($script:ThrowablePotions.Count -lt 5){
                    [void]$script:ThrowablePotions.Add($it)
                    $taken += $it
                } else {
                    $rejected += $it
                }
            }
            # Regular potions → potion belt (max 10)
            elseif($kindKnown -eq "Potion" -or $it.Type -in @("Heal","Mana","ATKBuff","DEFBuff","Luck")){
                if($script:Potions.Count -lt 10){
                    [void]$script:Potions.Add($it)
                    $taken += $it
                } else {
                    $rejected += $it
                }
            }
            # Loot, weapons, armor → main inventory bag
            else {
                [void]$script:Inventory.Add($it)
                $taken += $it
                # Track for LootHunter quest (any non-Gold/Lockpick/Potion/Throw item)
                if($it.Kind -eq "Loot" -or $it.Kind -eq "Weapon" -or $it.Kind -eq "Armor"){
                    Update-QuestProgress "LootHunter"
                }
            }
        }
        return @{ Taken = $taken; Rejected = $rejected }
    }

    function _LootShowDetailCard {
        param($Item)
        clr
        Write-Host ""
        $boxW = 56
        $bar = "═" * $boxW
        Write-CL ("  ╔" + $bar + "╗") "DarkCyan"
        $title = " " + $Item.Name
        if($title.Length -gt $boxW){ $title = $title.Substring(0, $boxW) }
        $title = $title.PadRight($boxW)
        Write-C "  ║" "DarkCyan"; Write-C $title "Yellow"; Write-CL "║" "DarkCyan"
        Write-CL ("  ╠" + ("─" * $boxW) + "╣") "DarkCyan"
        $rows = @()
        $kindStr = if($Item.Kind){ $Item.Kind } else { "Item" }
        $rows += "  Type:       $kindStr"
        if($Item.WeaponType){ $rows += "  WeaponType: $($Item.WeaponType)" }
        if($Item.Slot){       $rows += "  Slot:       $($Item.Slot)" }
        if($Item.ATK){        $rows += "  ATK:        +$($Item.ATK)" }
        if($Item.DEF){        $rows += "  DEF:        +$($Item.DEF)" }
        if($Item.MAGBonus){   $rows += "  MAG:        +$($Item.MAGBonus)" }
        if($Item.MaxDurability){
            $dCur = if($Item.Durability){ $Item.Durability } else { $Item.MaxDurability }
            $rows += "  Durability: $dCur/$($Item.MaxDurability)"
        }
        if($Item.Value){      $rows += "  Value:      $($Item.Value)g" }
        if($Item.Price){      $rows += "  Price:      $($Item.Price)g" }
        $weightV = Get-ItemWeight $Item
        $rows += "  Weight:     $weightV"
        if($Item.ClassAffinity){
            $bonusStr = if($Item.AffinityBonus){"+$($Item.AffinityBonus) ATK"}else{""}
            $rows += "  Affinity:   $($Item.ClassAffinity) $bonusStr"
        }
        if($Item.Perk){
            $perkChance = if($Item.PerkChance){"$($Item.PerkChance)%"}else{""}
            $rows += "  Perk:       $($Item.Perk) $perkChance"
        }
        if($Item.Effect -and $Item.Effect -ne "None"){
            $rows += "  Effect:     $($Item.Effect)"
        }
        if($Item.Power){
            $rows += "  Power:      $($Item.Power)"
        }
        if($Item.Desc){
            # Wrap description if too long
            $desc = $Item.Desc
            if($desc.Length -gt ($boxW - 4)){
                $desc = $desc.Substring(0, $boxW - 7) + "..."
            }
            $rows += "  Desc:       $desc"
        }
        foreach($r in $rows){
            $padded = $r
            if($padded.Length -gt $boxW){ $padded = $padded.Substring(0, $boxW) }
            $padded = $padded.PadRight($boxW)
            Write-C "  ║" "DarkCyan"; Write-C $padded "Gray"; Write-CL "║" "DarkCyan"
        }
        Write-CL ("  ╚" + $bar + "╝") "DarkCyan"
        Write-Host ""
        Write-CL "  [Press any key to return to loot screen]" "DarkGray"
        # Drain any held keys then wait for one fresh press
        try {
            while($Host.UI.RawUI.KeyAvailable){
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
        } catch {}
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }

    # Drain any leftover keys before entering the loop
    try {
        while($Host.UI.RawUI.KeyAvailable){
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    } catch {}

    while($true){
        clr
        Write-Host ""
        Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkYellow"
        $titleStr = $Title
        if($titleStr.Length -gt 56){ $titleStr = $titleStr.Substring(0, 56) }
        $titlePadded = $titleStr.PadLeft(($titleStr.Length + 56) / 2).PadRight(56)
        Write-C "  ║" "DarkYellow"; Write-C $titlePadded "Yellow"; Write-CL "║" "DarkYellow"
        Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkYellow"
        Write-Host ""

        $maxW = Get-MaxCarryWeight $script:Player
        $curW = Get-CurrentCarryWeight
        $selectedW = 0
        for($i=0; $i -lt $itemCount; $i++){
            if($marked[$i]){ $selectedW += (Get-ItemWeight $Items[$i]) }
        }
        $afterW = $curW + $selectedW
        $weightColor = if($afterW -gt $maxW){"Red"}elseif($afterW -gt ($maxW * 0.85)){"Yellow"}else{"Green"}

        Write-C "  Carry: " "DarkGray"
        Write-C "$curW" "White"
        Write-C " / $maxW" "White"
        Write-C "                       [Selected: " "DarkGray"
        Write-C "+$selectedW" $weightColor
        Write-CL "]" "DarkGray"
        if($afterW -gt $maxW){
            Write-CL "  -- selection exceeds carry weight --" "Red"
        }
        Write-Host ""

        # Item rows
        for($i=0; $i -lt $itemCount; $i++){
            $it = $Items[$i]
            $isCursor = ($i -eq $cursor)
            $box = if($marked[$i]){"[X]"}else{"[ ]"}
            $kindTag = switch($it.Kind){
                "Weapon"    { "[Wpn]" }
                "Armor"     { "[Arm]" }
                "Potion"    { "[Pot]" }
                "Throwable" { "[Thr]" }
                "Lockpicks" { "[Pck]" }
                "Gold"      { "[Gld]" }
                default     { "[Loot]" }
            }
            $name = $it.Name
            if($name.Length -gt 24){ $name = $name.Substring(0,24) }
            $w = Get-ItemWeight $it
            $valStr = if($it.Value){"$($it.Value)g"}elseif($it.Price){"$($it.Price)g"}else{"---"}

            # Cursor arrow
            if($isCursor){ Write-C "  > " "Yellow" }
            else { Write-C "    " "DarkGray" }

            # Checkbox
            $boxColor = if($marked[$i]){"Green"}else{"DarkGray"}
            Write-C $box $boxColor

            # Name (highlighted if cursor on it)
            $nameColor = if($isCursor){"White"}elseif($marked[$i]){"White"}else{"Gray"}
            Write-C " " $nameColor
            Write-C $name.PadRight(24) $nameColor

            # Kind tag
            $tagColor = switch($it.Kind){
                "Weapon"    { "Yellow" }
                "Armor"     { "DarkCyan" }
                "Potion"    { "Green" }
                "Throwable" { "DarkYellow" }
                "Lockpicks" { "Cyan" }
                "Gold"      { "Yellow" }
                default     { "Magenta" }
            }
            Write-C " " "DarkGray"
            Write-C $kindTag.PadRight(7) $tagColor

            # Weight
            Write-C "  " "DarkGray"
            $wColor = if(($curW + $w) -gt $maxW){"Red"}else{"DarkGray"}
            Write-C "${w}wt".PadRight(5) $wColor

            # Value
            Write-C "  " "DarkGray"
            Write-CL $valStr.PadLeft(6) "DarkGray"
        }

        Write-Host ""
        Write-CL "  ──────────────────────────────────────────────────" "DarkGray"
        Write-CL "  [Up/Down] move    [Space] toggle    [V] details" "DarkCyan"
        Write-CL "  [A] take all      [Enter] confirm   [Esc] none" "DarkCyan"

        # Wait for a key
        $key = $null
        while(-not $key){
            if($Host.UI.RawUI.KeyAvailable){
                $k = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                # Map virtual keys
                switch($k.VirtualKeyCode){
                    38 { $key = "UP" }       # Up arrow
                    40 { $key = "DOWN" }     # Down arrow
                    32 { $key = "SPACE" }    # Space
                    13 { $key = "ENTER" }    # Enter
                    27 { $key = "ESC" }      # Escape
                }
                if(-not $key -and $k.Character -and $k.Character -ne [char]0){
                    $c = [string]$k.Character
                    switch -Regex ($c){
                        '^[Ww]$' { $key = "UP" }
                        '^[Ss]$' { $key = "DOWN" }
                        '^[Aa]$' { $key = "ALL" }
                        '^[Vv]$' { $key = "VIEW" }
                        ' '      { $key = "SPACE" }
                    }
                }
            }
            Start-Sleep -Milliseconds 25
        }

        switch($key){
            "UP" {
                $cursor--
                if($cursor -lt 0){ $cursor = $itemCount - 1 }
            }
            "DOWN" {
                $cursor++
                if($cursor -ge $itemCount){ $cursor = 0 }
            }
            "SPACE" {
                $marked[$cursor] = -not $marked[$cursor]
            }
            "ALL" {
                # Smart take-all: mark items greedily until weight cap reached
                $tentativeW = $curW
                for($i=0; $i -lt $itemCount; $i++){
                    $w = Get-ItemWeight $Items[$i]
                    if(($tentativeW + $w) -le $maxW){
                        $marked[$i] = $true
                        $tentativeW += $w
                    } else {
                        $marked[$i] = $false
                    }
                }
            }
            "VIEW" {
                _LootShowDetailCard $Items[$cursor]
            }
            "ENTER" {
                # Block if over weight
                $finalAfter = $curW + $selectedW
                if($finalAfter -gt $maxW){
                    Write-Host ""
                    Write-CL "  Cannot confirm — selection exceeds carry weight!" "Red"
                    Write-CL "  Press any key, then unmark some items." "DarkGray"
                    try { while($Host.UI.RawUI.KeyAvailable){ $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } } catch {}
                    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                    continue
                }
                # Route + stow
                $result = _LootRouteAndStow $Items $marked
                if($result.Rejected.Count -gt 0){
                    Write-Host ""
                    Write-CL "  Some potions/throwables couldnt fit:" "Yellow"
                    foreach($r in $result.Rejected){
                        Write-CL "    ! $($r.Name) — your belt is full" "DarkYellow"
                    }
                    Wait-Key
                }
                return $result.Taken
            }
            "ESC" {
                return @()
            }
        }
    }
}


# ─── DROP SCREEN (arrow-key navigation) ───────────────────────────
# Mark items in inventory + potions + throwables, set lockpick drop
# quantity, then confirm to destroy. Equipped weapon/armor are shown
# at the top as a visual reminder — they are NOT droppable here (use
# the [U] Unequip option in the inventory screen for that).
function Show-DropScreen {
    $invCount = $script:Inventory.Count
    $potCount = $script:Potions.Count
    $thrCount = $script:ThrowablePotions.Count
    $hasPicks = ($script:Lockpicks -gt 0)

    if($invCount -eq 0 -and $potCount -eq 0 -and $thrCount -eq 0 -and -not $hasPicks){
        Write-CL "  Nothing droppable." "DarkGray"
        Wait-Key
        return
    }

    # Virtual row layout (in display order):
    #   row 0..invCount-1                            -> $script:Inventory[i]
    #   row invCount..invCount+potCount-1            -> $script:Potions[i - invCount]
    #   row invCount+potCount..potEnd+thrCount-1     -> $script:ThrowablePotions[...]
    #   row picksRow (if hasPicks)                   -> lockpick quantity control
    $potStart = $invCount
    $thrStart = $invCount + $potCount
    $picksRow = $invCount + $potCount + $thrCount
    $totalRows = $picksRow
    if($hasPicks){ $totalRows++ }

    $invMarked = New-Object 'bool[]' ([math]::Max($invCount, 1))
    $potMarked = New-Object 'bool[]' ([math]::Max($potCount, 1))
    $thrMarked = New-Object 'bool[]' ([math]::Max($thrCount, 1))
    $picksDropQty = 0
    $cursor = 0

    # Drain leftover keys
    try {
        while($Host.UI.RawUI.KeyAvailable){
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    } catch {}

    while($true){
        clr
        Write-Host ""
        Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkRed"
        Write-CL "  ║              D R O P   I T E M S                         ║" "Red"
        Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkRed"
        Write-Host ""

        $maxW = Get-MaxCarryWeight $script:Player
        $curW = Get-CurrentCarryWeight
        $shedW = $picksDropQty
        for($i=0; $i -lt $invCount; $i++){
            if($invMarked[$i]){ $shedW += (Get-ItemWeight $script:Inventory[$i]) }
        }
        for($i=0; $i -lt $potCount; $i++){
            if($potMarked[$i]){ $shedW += 1 }
        }
        for($i=0; $i -lt $thrCount; $i++){
            if($thrMarked[$i]){ $shedW += 1 }
        }
        $afterW = $curW - $shedW
        $afterColor = if($afterW -gt $maxW){"Red"}else{"Green"}

        Write-C "  Carry: " "DarkGray"
        Write-C "$curW" "White"
        Write-C " (-$shedW dropped) = " "DarkGray"
        Write-C "$afterW" $afterColor
        Write-CL " / $maxW max" "DarkGray"
        Write-Host ""
        if($afterW -gt $maxW){
            Write-CL "  Still over weight - mark more items." "Red"
            Write-Host ""
        }

        # ─── Equipped reminder (NOT droppable) ───
        $hasEquipped = ($script:EquippedWeapon -ne $null)
        foreach($s in @("Helmet","Chest","Shield","Amulet","Boots")){
            if($script:EquippedArmor[$s]){ $hasEquipped = $true; break }
        }
        if($hasEquipped){
            Write-CL "  EQUIPPED (use Unequip in inventory to drop):" "DarkCyan"
            if($script:EquippedWeapon){
                Write-CL "    [E] $($script:EquippedWeapon.Name) [Wpn]" "Cyan"
            }
            foreach($s in @("Helmet","Chest","Shield","Amulet","Boots")){
                $piece = $script:EquippedArmor[$s]
                if($piece){
                    Write-CL "    [E] $($piece.Name) [$s]" "Cyan"
                }
            }
            Write-Host ""
        }

        # Helper: render a row
        # Inventory items
        for($i=0; $i -lt $invCount; $i++){
            $rowIdx = $i
            $isCursor = ($cursor -eq $rowIdx)
            $it = $script:Inventory[$i]
            if($isCursor){ Write-C "  > " "Yellow" } else { Write-C "    " "DarkGray" }
            $box = if($invMarked[$i]){"[X]"}else{"[ ]"}
            $boxColor = if($invMarked[$i]){"Red"}else{"DarkGray"}
            Write-C $box $boxColor
            $name = $it.Name
            if($name.Length -gt 24){ $name = $name.Substring(0,24) }
            $nameColor = if($isCursor){"White"}elseif($invMarked[$i]){"Red"}else{"White"}
            Write-C " " $nameColor
            Write-C $name.PadRight(24) $nameColor
            $kindTag = switch($it.Kind){
                "Weapon" { "[Wpn]" }
                "Armor"  { "[Arm]" }
                "Potion" { "[Pot]" }
                default  { "[Loot]" }
            }
            $tagColor = switch($it.Kind){
                "Weapon" { "Yellow" }
                "Armor"  { "DarkCyan" }
                "Potion" { "Green" }
                default  { "Magenta" }
            }
            Write-C " " "DarkGray"
            Write-C $kindTag.PadRight(7) $tagColor
            $w = Get-ItemWeight $it
            Write-C "  " "DarkGray"
            Write-C "${w}wt".PadRight(5) "DarkGray"
            Write-C "  " "DarkGray"
            $valStr = if($it.Value){"$($it.Value)g"}else{"---"}
            Write-CL $valStr.PadLeft(6) "DarkGray"
        }

        # Potions
        for($i=0; $i -lt $potCount; $i++){
            $rowIdx = $potStart + $i
            $isCursor = ($cursor -eq $rowIdx)
            $pot = $script:Potions[$i]
            if($isCursor){ Write-C "  > " "Yellow" } else { Write-C "    " "DarkGray" }
            $box = if($potMarked[$i]){"[X]"}else{"[ ]"}
            $boxColor = if($potMarked[$i]){"Red"}else{"DarkGray"}
            Write-C $box $boxColor
            $name = $pot.Name
            if($name.Length -gt 24){ $name = $name.Substring(0,24) }
            $nameColor = if($isCursor){"White"}elseif($potMarked[$i]){"Red"}else{"White"}
            Write-C " " $nameColor
            Write-C $name.PadRight(24) $nameColor
            Write-C " " "DarkGray"
            Write-C "[Pot]".PadRight(7) "Green"
            Write-C "  " "DarkGray"
            Write-C "1wt".PadRight(5) "DarkGray"
            Write-C "  " "DarkGray"
            $valStr = if($pot.Price){"$($pot.Price)g"}else{"---"}
            Write-CL $valStr.PadLeft(6) "DarkGray"
        }

        # Throwables
        for($i=0; $i -lt $thrCount; $i++){
            $rowIdx = $thrStart + $i
            $isCursor = ($cursor -eq $rowIdx)
            $thr = $script:ThrowablePotions[$i]
            if($isCursor){ Write-C "  > " "Yellow" } else { Write-C "    " "DarkGray" }
            $box = if($thrMarked[$i]){"[X]"}else{"[ ]"}
            $boxColor = if($thrMarked[$i]){"Red"}else{"DarkGray"}
            Write-C $box $boxColor
            $name = $thr.Name
            if($name.Length -gt 24){ $name = $name.Substring(0,24) }
            $nameColor = if($isCursor){"White"}elseif($thrMarked[$i]){"Red"}else{"White"}
            Write-C " " $nameColor
            Write-C $name.PadRight(24) $nameColor
            Write-C " " "DarkGray"
            Write-C "[Thr]".PadRight(7) "DarkYellow"
            Write-C "  " "DarkGray"
            Write-C "1wt".PadRight(5) "DarkGray"
            Write-C "  " "DarkGray"
            $valStr = if($thr.Price){"$($thr.Price)g"}else{"---"}
            Write-CL $valStr.PadLeft(6) "DarkGray"
        }

        # Lockpicks row
        if($hasPicks){
            $isCursor = ($cursor -eq $picksRow)
            if($isCursor){ Write-C "  > " "Yellow" } else { Write-C "    " "DarkGray" }
            $boxColor = if($picksDropQty -gt 0){"Red"}else{"DarkGray"}
            Write-C "[~]" $boxColor
            $nameColor = if($isCursor){"White"}else{"Gray"}
            Write-C " " $nameColor
            Write-C "Lockpicks".PadRight(24) $nameColor
            Write-C " " "DarkGray"
            Write-C "[Pck]".PadRight(7) "Cyan"
            Write-C "  " "DarkGray"
            Write-C "${picksDropQty}wt".PadRight(5) "DarkGray"
            Write-C "  " "DarkGray"
            $qtyDisplay = if($picksDropQty -gt 0){"DROP $picksDropQty / $($script:Lockpicks)"}else{"keep all $($script:Lockpicks)"}
            Write-CL $qtyDisplay.PadLeft(16) "DarkGray"
        }

        Write-Host ""
        Write-CL "  --------------------------------------------------" "DarkGray"
        Write-CL "  [Up/Down] move    [Space] toggle    [+/-] pick qty" "DarkCyan"
        Write-CL "  [D] drop marked   [Esc] cancel" "DarkCyan"

        # Read key
        $key = $null
        while(-not $key){
            if($Host.UI.RawUI.KeyAvailable){
                $k = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                switch($k.VirtualKeyCode){
                    38 { $key = "UP" }
                    40 { $key = "DOWN" }
                    32 { $key = "SPACE" }
                    13 { $key = "ENTER" }
                    27 { $key = "ESC" }
                    187 { $key = "PLUS" }
                    189 { $key = "MINUS" }
                    107 { $key = "PLUS" }
                    109 { $key = "MINUS" }
                }
                if(-not $key -and $k.Character -and $k.Character -ne [char]0){
                    $c = [string]$k.Character
                    switch -Regex ($c){
                        '^[Ww]$' { $key = "UP" }
                        '^[Ss]$' { $key = "DOWN" }
                        '^[Dd]$' { $key = "DROP" }
                        '^\+$'  { $key = "PLUS" }
                        '^=$'    { $key = "PLUS" }
                        '^-$'    { $key = "MINUS" }
                        ' '      { $key = "SPACE" }
                    }
                }
            }
            Start-Sleep -Milliseconds 25
        }

        switch($key){
            "UP" {
                $cursor--
                if($cursor -lt 0){ $cursor = $totalRows - 1 }
            }
            "DOWN" {
                $cursor++
                if($cursor -ge $totalRows){ $cursor = 0 }
            }
            "SPACE" {
                # Determine which list the cursor is on
                if($hasPicks -and $cursor -eq $picksRow){
                    if($picksDropQty -eq 0){ $picksDropQty = $script:Lockpicks }
                    else { $picksDropQty = 0 }
                } elseif($cursor -ge $thrStart){
                    $i = $cursor - $thrStart
                    if($i -ge 0 -and $i -lt $thrCount){ $thrMarked[$i] = -not $thrMarked[$i] }
                } elseif($cursor -ge $potStart){
                    $i = $cursor - $potStart
                    if($i -ge 0 -and $i -lt $potCount){ $potMarked[$i] = -not $potMarked[$i] }
                } else {
                    $i = $cursor
                    if($i -ge 0 -and $i -lt $invCount){ $invMarked[$i] = -not $invMarked[$i] }
                }
            }
            "PLUS" {
                if($hasPicks -and $cursor -eq $picksRow){
                    if($picksDropQty -lt $script:Lockpicks){ $picksDropQty++ }
                }
            }
            "MINUS" {
                if($hasPicks -and $cursor -eq $picksRow){
                    if($picksDropQty -gt 0){ $picksDropQty-- }
                }
            }
            { $_ -eq "DROP" -or $_ -eq "ENTER" } {
                $invDropCount = 0
                for($i=0; $i -lt $invCount; $i++){ if($invMarked[$i]){ $invDropCount++ } }
                $potDropCount = 0
                for($i=0; $i -lt $potCount; $i++){ if($potMarked[$i]){ $potDropCount++ } }
                $thrDropCount = 0
                for($i=0; $i -lt $thrCount; $i++){ if($thrMarked[$i]){ $thrDropCount++ } }
                $totalDrops = $invDropCount + $potDropCount + $thrDropCount + $picksDropQty
                if($totalDrops -eq 0){
                    if($key -eq "DROP"){
                        Write-Host ""
                        Write-CL "  Nothing marked to drop." "DarkGray"
                        Wait-Key
                    }
                    continue
                }
                Write-Host ""
                $parts = @()
                if($invDropCount -gt 0){ $parts += "$invDropCount item(s)" }
                if($potDropCount -gt 0){ $parts += "$potDropCount potion(s)" }
                if($thrDropCount -gt 0){ $parts += "$thrDropCount throwable(s)" }
                if($picksDropQty -gt 0){ $parts += "$picksDropQty lockpick(s)" }
                $msg = "Drop " + ($parts -join " + ") + "?"
                Write-C "  $msg (y/n): " "Yellow"
                $confirm = Read-Host
                if($confirm -eq 'y' -or $confirm -eq 'Y'){
                    # Reverse-iterate each list
                    for($i = $invCount - 1; $i -ge 0; $i--){
                        if($invMarked[$i]){ $script:Inventory.RemoveAt($i) }
                    }
                    for($i = $potCount - 1; $i -ge 0; $i--){
                        if($potMarked[$i]){ $script:Potions.RemoveAt($i) }
                    }
                    for($i = $thrCount - 1; $i -ge 0; $i--){
                        if($thrMarked[$i]){ $script:ThrowablePotions.RemoveAt($i) }
                    }
                    if($picksDropQty -gt 0){
                        $script:Lockpicks -= $picksDropQty
                        if($script:Lockpicks -lt 0){ $script:Lockpicks = 0 }
                    }
                    Write-CL "  Dropped: $($parts -join ', ')." "Red"
                    Wait-Key
                    return
                }
            }
            "ESC" { return }
        }
    }
}




function Show-Blacksmith {
    $smithLoop = $true
    while($smithLoop){
        clr
        Write-Host ""
        Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkRed"
        Write-CL "  ║                  T H E   B L A C K S M I T H             ║" "Red"
        Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkRed"
        Write-Host ""
        # Forge art
        Write-CL "           _______________" "DarkGray"
        Write-CL "          /   _________   \" "DarkGray"
        Write-CL "         |   /    ^    \   |" "Red"
        Write-CL "         |  /    ( )    \  |" "DarkYellow"
        Write-CL "         | |    ~~~~~    | |" "DarkYellow"
        Write-CL "         | |   ~ FIRE ~  | |" "Yellow"
        Write-CL "         | |   ~~~~~~~   | |" "DarkYellow"
        Write-CL "          \|_____________|/" "DarkGray"
        Write-CL "         ///  |  ANVIL  |  \\\\\\" "DarkGray"
        Write-Host ""
        Write-C "  Gold: " "DarkGray"; Write-CL "$($script:Gold)g" "Yellow"
        Write-Host ""

        # Gather all damaged items
        $damaged = @()  # list of @{ Kind=Weapon/Armor; Slot=...; Item=...; Cost=... }
        if($script:EquippedWeapon -and $script:EquippedWeapon.MaxDurability -ge 0){
            $wCost = Get-RepairCost $script:EquippedWeapon
            if($wCost -gt 0){
                $damaged += @{ Kind="Weapon"; Slot="Weapon"; Item=$script:EquippedWeapon; Cost=$wCost }
            }
        }
        foreach($slot in @("Helmet","Chest","Shield","Amulet","Boots")){
            $piece = $script:EquippedArmor[$slot]
            if($piece -and $piece.MaxDurability -ge 0){
                $cost = Get-RepairCost $piece
                if($cost -gt 0){
                    $damaged += @{ Kind="Armor"; Slot=$slot; Item=$piece; Cost=$cost }
                }
            }
        }

        if($damaged.Count -eq 0){
            Write-CL "  The smith looks over your gear." "DarkGray"
            Write-CL "  'Everything's in fine shape. Off with ye.'" "White"
            Write-Host ""
            Read-Host "  [Press Enter to continue]" | Out-Null
            return
        }

        Write-CL "  The smith squints at your gear:" "DarkGray"
        Write-CL "  'Let's see what needs mending...'" "White"
        Write-Host ""

        # Table of damaged items
        $cw1 = 5; $cw2 = 10; $cw3 = 24; $cw4 = 13; $cw5 = 10
        $top = "  ┌$('─'*$cw1)┬$('─'*$cw2)┬$('─'*$cw3)┬$('─'*$cw4)┬$('─'*$cw5)┐"
        $mid = "  ├$('─'*$cw1)┼$('─'*$cw2)┼$('─'*$cw3)┼$('─'*$cw4)┼$('─'*$cw5)┤"
        $bot = "  └$('─'*$cw1)┴$('─'*$cw2)┴$('─'*$cw3)┴$('─'*$cw4)┴$('─'*$cw5)┘"
        $headerRow = "  │" + (Pad-Cell "#" $cw1) + "│" + (Pad-Cell "Slot" $cw2) + "│" + (Pad-Cell "Item" $cw3) + "│" + (Pad-Cell "Durability" $cw4) + "│" + (Pad-Cell "Cost" $cw5) + "│"

        Write-CL $top "DarkGray"
        Write-CL $headerRow "DarkGray"
        Write-CL $mid "DarkGray"

        $totalCost = 0
        for($i=0; $i -lt $damaged.Count; $i++){
            $d = $damaged[$i]
            $it = $d.Item
            $idxCell   = Pad-Cell ("$($i+1)") $cw1
            $slotCell  = Pad-Cell $d.Slot $cw2
            $nameCell  = Pad-Cell $it.Name $cw3
            $durCell   = Pad-Cell "$($it.Durability)/$($it.MaxDurability)" $cw4
            $costCell  = Pad-Cell ("$($d.Cost)g") $cw5
            $affordable = if($script:Gold -ge $d.Cost){"Green"}else{"DarkGray"}
            $durColor   = Get-DurabilityColor $it
            $totalCost += $d.Cost

            Write-C "  │" "DarkGray"
            Write-C $idxCell $affordable
            Write-C "│" "DarkGray"
            Write-C $slotCell "White"
            Write-C "│" "DarkGray"
            Write-C $nameCell "Cyan"
            Write-C "│" "DarkGray"
            Write-C $durCell $durColor
            Write-C "│" "DarkGray"
            Write-C $costCell $affordable
            Write-CL "│" "DarkGray"
        }
        Write-CL $bot "DarkGray"
        Write-Host ""

        # Repair All bundle (10% discount)
        $bulkCost = [math]::Floor($totalCost * 0.9)
        $bulkAffordable = if($script:Gold -ge $bulkCost){"Green"}else{"DarkGray"}

        Write-C "  [A] " "Yellow"
        Write-C "Repair All — " "White"
        Write-C "${bulkCost}g" $bulkAffordable
        Write-CL "  (10% bulk discount)" "DarkGray"
        Write-CL "  [0] Leave" "White"
        Write-Host ""
        Write-C "  Repair which? (number / A / 0): " "Yellow"
        $ch = Read-Host

        if($ch -eq "0" -or $ch -eq ""){ return }

        if($ch -match '^[Aa]$'){
            # Repair all
            if($script:Gold -ge $bulkCost){
                $script:Gold -= $bulkCost
                foreach($d in $damaged){
                    $d.Item.Durability = $d.Item.MaxDurability
                }
                Write-Host ""
                Write-CL "  The smith works through the pile. Sparks fly." "Yellow"
                Write-CL "  All gear fully repaired for ${bulkCost}g." "Green"
                Update-QuestProgress "Repair"; $script:TotalRepairs++
                Write-Host ""
                Read-Host "  [Press Enter to continue]" | Out-Null
            } else {
                Write-CL "  'Not enough gold for the lot. Try one at a time.'" "Red"
                Wait-Key
            }
        } else {
            $pick = 0
            if([int]::TryParse($ch, [ref]$pick) -and $pick -ge 1 -and $pick -le $damaged.Count){
                $d = $damaged[$pick - 1]
                if($script:Gold -ge $d.Cost){
                    $script:Gold -= $d.Cost
                    $d.Item.Durability = $d.Item.MaxDurability
                    Write-Host ""
                    Write-CL "  The smith hammers away at your $($d.Item.Name)." "Yellow"
                    Write-CL "  Repaired for $($d.Cost)g." "Green"
                    Update-QuestProgress "Repair"; $script:TotalRepairs++
                    Write-Host ""
                    Read-Host "  [Press Enter to continue]" | Out-Null
                } else {
                    Write-CL "  'Come back with more gold, adventurer.'" "Red"
                    Wait-Key
                }
            } else {
                Write-CL "  'I don't know which one ye mean.'" "DarkGray"
                Wait-Key
            }
        }
    }
}


# ─── RANDOM ENCOUNTERS ───────────────────────────────────────────
# Triggered during dungeon movement. Pulls player out of navigation
# briefly to present a choice. Dutchman is rare and unlocks the
# best weapon in the game (or demotes the player by 2 levels).
function Start-RandomEncounter {
    param([string]$Type = "")
    # If the player was holding a movement key when the encounter triggered,
    # the OS keeps queueing keystrokes. The first Read-Host or Wait-Key in
    # the encounter would immediately consume those as the player's answer,
    # making the encounter flash by unseen. Drain the buffer first, and also
    # pause briefly so the "encountering something" moment feels deliberate.
    try {
        while($Host.UI.RawUI.KeyAvailable){
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    } catch {}
    Start-Sleep -Milliseconds 150
    # Second drain in case new auto-repeats arrived during the pause
    try {
        while($Host.UI.RawUI.KeyAvailable){
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    } catch {}

    $p = $script:Player
    if(-not $Type){
        # Pick from available options.
        # - Alchemist can't spawn if potion bag is full (trade would be wasted).
        # - Bard can't spawn if HP and MP are both already full (heal would be wasted).
        $options = @("Merchant")
        if($p.HP -lt $p.MaxHP -or $p.MP -lt $p.MaxMP){
            $options += "Bard"
        }
        if($script:Potions.Count -lt 10){
            $options += "Alchemist"
        }
        $Type = $options | Get-Random
    }

    clr
    switch($Type){
        "Bard" {
            Write-Host ""
            Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkMagenta"
            Write-CL "  ║             T H E   H E A L I N G   B A R D             ║" "Magenta"
            Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkMagenta"
            Write-Host ""
            Write-CL "           ♪    ♫        ♪         ♫      ♪" "Yellow"
            Write-CL "               ▄▄▄▄               " "Magenta"
            Write-CL "             ▄█▓▓▓▓█▄             " "Magenta"
            Write-CL "            █▓▓ o o ▓▓█           " "Magenta"
            Write-CL "            █▓▓  □  ▓▓█           " "Magenta"
            Write-CL "             ▀█▓▓▓▓█▀             " "Magenta"
            Write-CL "               ║║                   ║│═─═│║" "DarkMagenta"
            Write-CL "              ═╩╩═               │═─═│" "DarkMagenta"
            Write-CL "              ║▓▓║                ║── ║" "DarkMagenta"
            Write-CL "              ╝▓▓╚               ╚═══╝" "DarkMagenta"
            Write-Host ""
            Write-CL "  A cheerful bard strums a lute in a forgotten alcove." "Gray"
            Write-CL "  'Traveler! Let my song mend your weary soul.'" "Yellow"
            Write-Host ""
            $hpRestore = [math]::Floor($p.MaxHP * (Get-Random -Min 30 -Max 61) / 100)
            $mpRestore = [math]::Floor($p.MaxMP * (Get-Random -Min 30 -Max 61) / 100)
            $p.HP = [math]::Min($p.HP + $hpRestore, $p.MaxHP)
            $p.MP = [math]::Min($p.MP + $mpRestore, $p.MaxMP)
            Write-CL "  You feel refreshed! +$hpRestore HP, +$mpRestore MP" "Green"
            Write-CL "  HP: $($p.HP)/$($p.MaxHP)  MP: $($p.MP)/$($p.MaxMP)" "White"
            Try-UnlockAchievement "Bard"
            Write-Host ""
            Read-Host "  [Press Enter to continue]" | Out-Null
        }
        "Merchant" {
            Write-Host ""
            Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkYellow"
            Write-CL "  ║             T H E   L O S T   M E R C H A N T          ║" "Yellow"
            Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkYellow"
            Write-Host ""
            Write-CL "              ▄▄▄▄▄▄▄▄▄▄▄▄▄▄              " "DarkYellow"
            Write-CL "             █▓CART   GOODS▓█            " "Yellow"
            Write-CL "             █▓  ▀▄▄▄▄▄▄▀  ▓█            " "Yellow"
            Write-CL "              ▀▄▄████████▄▄▀             " "DarkYellow"
            Write-CL "                ◎        ◎                " "DarkYellow"
            Write-Host ""
            Write-CL "  A disheveled merchant emerges from the shadows." "Gray"
            Write-CL "  'Lost for weeks! Please — take anything! 60% off!'" "Yellow"
            Write-Host ""
            # Pick one random high-tier item
            $allWpn = Get-WeaponShop | Where-Object { $_.Price -ge 300 }
            $allArm = Get-ArmorShop | Where-Object { $_.Price -ge 200 }
            $allPot = Get-PotionShop | Where-Object { $_.Category -eq "Potion" }

            $offerKind = Get-Random -Min 0 -Max 3
            $item = $null; $itemKind = "None"; $origPrice = 0
            switch($offerKind){
                0 {
                    if($allWpn.Count -gt 0){ $item = $allWpn | Get-Random; $itemKind = "Weapon"; $origPrice = $item.Price }
                }
                1 {
                    if($allArm.Count -gt 0){ $item = $allArm | Get-Random; $itemKind = "Armor"; $origPrice = $item.Price }
                }
                2 {
                    if($allPot.Count -gt 0){ $item = $allPot | Get-Random; $itemKind = "Potion"; $origPrice = $item.Price }
                }
            }
            if(-not $item){
                Write-CL "  The merchant's cart is empty. He apologizes and vanishes." "DarkGray"
                Write-Host ""
                Read-Host "  [Press Enter to continue]" | Out-Null
                return
            }
            $salePrice = [math]::Floor($origPrice * 0.4)
            Write-CL "  Offer: $($item.Name) [$itemKind]" "Cyan"
            Write-C "  Normal price: " "DarkGray"; Write-CL "$($origPrice)g" "DarkYellow"
            Write-C "  Today's price: " "DarkGray"; Write-CL "$($salePrice)g (60% off!)" "Yellow"
            Write-Host ""
            Write-C "  Buy? (y/n): " "Yellow"; $ans = Read-Host
            if($ans -eq 'y' -or $ans -eq 'Y'){
                if($script:Gold -ge $salePrice){
                    $script:Gold -= $salePrice
                    switch($itemKind){
                        "Weapon" {
                            $newWeapon = Init-ItemDurability $item
                            if(-not $newWeapon.Kind){ $newWeapon.Kind = "Weapon" }
                            $script:WeaponsOwned[$item.Name] = $true
                            Invoke-GearAcquired -Item $newWeapon -Kind "Weapon"
                        }
                        "Armor" {
                            if(-not $item.Slot){
                                Write-CL "  The merchant fumbles. The piece slips and is lost." "Red"
                                Write-CL "  (No slot info — refunding ${salePrice}g)" "DarkGray"
                                $script:Gold += $salePrice
                            } else {
                                $newArmor = Init-ItemDurability $item
                                if(-not $newArmor.Kind){ $newArmor.Kind = "Armor" }
                                $script:ArmorOwned[$item.Name] = $true
                                Invoke-GearAcquired -Item $newArmor -Kind "Armor"
                            }
                        }
                        "Potion" {
                            if($script:Potions.Count -ge 10){
                                Write-CL "  Your potion bag is full! The merchant frowns." "Red"
                                Write-CL "  (Refunded ${salePrice}g)" "DarkGray"
                                $script:Gold += $salePrice
                            } else {
                                [void]$script:Potions.Add($item)
                                Write-CL "  Added $($item.Name) to your potion bag." "Green"
                            }
                        }
                    }
                    Try-UnlockAchievement "Merchant"
                    Check-Achievements
                } else {
                    Write-CL "  'Ah... no gold. Such a shame.'" "Red"
                }
            } else {
                Write-CL "  'Suit yourself, friend.'" "DarkGray"
            }
            Write-Host ""
            Read-Host "  [Press Enter to continue]" | Out-Null
        }
        "Alchemist" {
            Write-Host ""
            Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkGreen"
            Write-CL "  ║          T H E   W A N D E R I N G   A L C H E M I S T  ║" "Green"
            Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkGreen"
            Write-Host ""
            Write-CL "                ░░░░░▄▄▄▄░░░░░               " "DarkGreen"
            Write-CL "              ▄▀ BUBBLE BUBBLE▀▄            " "Green"
            Write-CL "              ║~~~~~~~~~~~~~~~║            " "Green"
            Write-CL "              ║    POTIONS    ║            " "DarkGreen"
            Write-CL "               ▀▄▄▄▄▄▄▄▄▄▄▄▄▀             " "DarkGreen"
            Write-Host ""
            Write-CL "  A bent-backed alchemist stirs a cauldron." "Gray"
            Write-CL "  'Trade me 2 loot trinkets — I'll brew you something useful.'" "Green"
            Write-Host ""
            if($script:Inventory.Count -lt 2){
                Write-CL "  'Alas, you carry too little to trade. Come back when you loot more.'" "DarkGray"
                Write-Host ""
                Read-Host "  [Press Enter to continue]" | Out-Null
                return
            }
            if($script:Potions.Count -ge 10){
                Write-CL "  The alchemist glances at your bulging potion bag." "DarkGray"
                Write-CL "  'Your satchel overflows already. Drink one, then return.'" "Green"
                Write-Host ""
                Read-Host "  [Press Enter to continue]" | Out-Null
                return
            }
            Write-C "  Trade 2 loot items for a random potion? (y/n): " "Yellow"
            $ans = Read-Host
            if($ans -eq 'y' -or $ans -eq 'Y'){
                for($i=0; $i -lt 2; $i++){
                    $rmIdx = Get-Random -Min 0 -Max $script:Inventory.Count
                    $lost = $script:Inventory[$rmIdx]
                    $script:Inventory.RemoveAt($rmIdx)
                    Write-CL "  Traded: $($lost.Name)" "DarkGray"
                }
                $availablePotions = Get-PotionShop | Where-Object { $_.Category -eq "Potion" }
                $got = $availablePotions | Get-Random
                [void]$script:Potions.Add($got)
                Write-CL "  The alchemist hands you: $($got.Name)" "Green"
            } else {
                Write-CL "  'Wise to hoard, perhaps. Be gone.'" "DarkGray"
            }
            Write-Host ""
            Read-Host "  [Press Enter to continue]" | Out-Null
        }
        "RepairSmith" {
            Write-Host ""
            Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkRed"
            Write-CL "  ║          A   W A N D E R I N G   M E T A L S M I T H    ║" "Red"
            Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkRed"
            Write-Host ""
            # Small forge-on-cart art
            Write-CL "             ___________ " "DarkGray"
            Write-CL "            /  ___      \" "DarkGray"
            Write-CL "           |  /  ^  \   |" "Red"
            Write-CL "           | |  ( ) | _|" "Yellow"
            Write-CL "           | | ~~~  || /" "DarkYellow"
            Write-CL "            \|______|//" "DarkGray"
            Write-CL "            o^o^^^^o^o" "DarkGray"
            Write-Host ""
            Write-CL "  An old smith with a portable forge nods at your gear." "Gray"
            Write-CL "  'Aye, lemme set that right. No charge — pay it forward.'" "Yellow"
            Write-Host ""

            # Repair every damaged piece to full
            $totalPointsRestored = 0
            $itemsTouched = 0

            if($script:EquippedWeapon -and $script:EquippedWeapon.MaxDurability -ge 0){
                $missing = $script:EquippedWeapon.MaxDurability - $script:EquippedWeapon.Durability
                if($missing -gt 0){
                    $script:EquippedWeapon.Durability = $script:EquippedWeapon.MaxDurability
                    $totalPointsRestored += $missing
                    $itemsTouched++
                    Write-CL "  ✓ $($script:EquippedWeapon.Name) repaired (+$missing)" "Green"
                }
            }
            foreach($slotN in @("Helmet","Chest","Shield","Amulet","Boots")){
                $piece = $script:EquippedArmor[$slotN]
                if($piece -and $piece.MaxDurability -ge 0){
                    $missing = $piece.MaxDurability - $piece.Durability
                    if($missing -gt 0){
                        $piece.Durability = $piece.MaxDurability
                        $totalPointsRestored += $missing
                        $itemsTouched++
                        Write-CL "  ✓ $($piece.Name) repaired (+$missing)" "Green"
                    }
                }
            }

            Write-Host ""
            if($itemsTouched -eq 0){
                Write-CL "  Your gear is already in fine shape. The smith shrugs and moves on." "DarkGray"
            } else {
                Write-CL "  $itemsTouched item(s) restored. $totalPointsRestored durability points returned." "Yellow"
                Write-CL "  'Be safe down there, friend.'" "Cyan"
            }
            Write-Host ""
            Read-Host "  [Press Enter to continue]" | Out-Null
        }
        "Dutchman" {
            # Only trigger once per game if already owned
            if($script:OwnsDutchmanBlade){
                Write-CL "  A phantom ship drifts by, but the captain nods and vanishes." "DarkGray"
                Write-Host ""
                Read-Host "  [Press Enter to continue]" | Out-Null
                return
            }
            Write-Host ""
            Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkCyan"
            Write-CL "  ║           T H E   F L Y I N G   D U T C H M A N         ║" "Cyan"
            Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkCyan"
            Write-Host ""
            # User-provided ghost ship art (single-quoted to avoid interpolation)
            Write-CL '                             |    |    |              ' "White"
            Write-CL '                            )_)  )_)  )_)              ' "DarkCyan"
            Write-CL '                           )___))___))___)\           ' "DarkCyan"
            Write-CL '                          )____)____)_____)\\         ' "DarkCyan"
            Write-CL '                        _____|____|____|____\\\__     ' "Cyan"
            Write-CL '               ---------\                   /---------' "Cyan"
            Write-CL '                 ^^^^^ ^^^^^^^^^^^^^^^^^^^^^            ' "Blue"
            Write-CL '                   ^^^^      ^^^^     ^^^    ^^        ' "Blue"
            Write-CL '                        ^^^^      ^^^                  ' "DarkBlue"
            Write-Host ""
            Write-CL "  The Flying Dutchman materializes before you, its spectral" "Gray"
            Write-CL "  captain stepping through stone walls. He holds out a blade" "Gray"
            Write-CL "  that crackles with dark energy — and a coin." "Gray"
            Write-Host ""
            Write-CL "  'A wager, mortal. Call heads or tails.'" "Cyan"
            Write-CL "  'WIN — and take my blade: the DUTCHMAN'S BLADE." "DarkCyan"
            Write-CL "         ATK+100, worth 10,000 gold, steals life on hit.'" "DarkCyan"
            Write-CL "  'LOSE — and forfeit TWO levels of your experience.'" "DarkRed"
            Write-Host ""
            Write-C "  Accept the wager? (y/n): " "Yellow"; $ans = Read-Host
            if($ans -ne 'y' -and $ans -ne 'Y'){
                Write-CL "  The Dutchman chuckles and fades. Perhaps you were wise." "DarkGray"
                Write-Host ""
                Read-Host "  [Press Enter to continue]" | Out-Null
                return
            }
            Write-Host ""
            Write-C "  Call it! (h)eads or (t)ails: " "Yellow"; $call = Read-Host
            $call = $call.ToLower()
            if($call -ne 'h' -and $call -ne 't'){
                Write-CL "  The Dutchman scowls. 'Choose, coward!'" "Red"
                Write-Host ""
                Read-Host "  [Press Enter to continue]" | Out-Null
                return
            }
            # Coin flip
            Write-Host ""
            Write-CL "  The coin spins in the air..." "DarkGray"
            for($i=0; $i -lt 6; $i++){
                $face = if(($i % 2) -eq 0){"( H )"}else{"( T )"}
                Write-C "    " "Black"; Write-CL $face "Yellow"
                Start-Sleep -Milliseconds 140
                try {
                    $pos = $Host.UI.RawUI.CursorPosition
                    $newY = $pos.Y - 1
                    if($newY -ge 0){
                        $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, $newY
                        Write-Host (" " * 20) -NoNewline
                        $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, $newY
                    }
                } catch {}
            }
            $result = if((Get-Random -Min 0 -Max 2) -eq 0){"h"}else{"t"}
            $resFace = if($result -eq 'h'){"( H )"}else{"( T )"}
            Write-CL "  Result: $resFace" "Yellow"
            Write-Host ""
            if($call -eq $result){
                Write-CL "  The Dutchman bows solemnly." "Cyan"
                Write-CL "  'The blade is yours. Use it well, mortal.'" "DarkCyan"
                # Add the blade
                $dutchBlade = @{
                    Name="Dutchman's Blade"; ATK=100; Price=10000; WeaponType="Sword"
                    ClassAffinity="None"; AffinityBonus=0; Perk="Drain"; PerkChance=40
                }
                $newBlade = Init-ItemDurability $dutchBlade
                if(-not $newBlade.Kind){ $newBlade.Kind = "Weapon" }
                $script:OwnsDutchmanBlade = $true
                $script:WeaponsOwned["Dutchman's Blade"] = $true
                Invoke-GearAcquired -Item $newBlade -Kind "Weapon"
                Try-UnlockAchievement "Lucky"
                Check-Achievements
            } else {
                Write-CL "  The Dutchman laughs, cold and hollow." "DarkRed"
                Write-CL "  'Your soul grows dimmer, mortal.'" "Red"
                $oldLvl = $script:PlayerLevel
                $script:PlayerLevel = [math]::Max($script:PlayerLevel - 2, 1)
                $lost = $oldLvl - $script:PlayerLevel
                # Pull stats back proportionally
                $p.MaxHP = [math]::Max($p.MaxHP - (10 * $lost), 50)
                $p.MaxMP = [math]::Max($p.MaxMP - (5 * $lost), 20)
                $p.ATK   = [math]::Max($p.ATK - (2 * $lost), 3)
                $p.DEF   = [math]::Max($p.DEF - (2 * $lost), 3)
                $p.SPD   = [math]::Max($p.SPD - (1 * $lost), 3)
                $p.MAG   = [math]::Max($p.MAG - (2 * $lost), 2)
                if($p.HP -gt $p.MaxHP){ $p.HP = $p.MaxHP }
                if($p.MP -gt $p.MaxMP){ $p.MP = $p.MaxMP }
                Write-CL "  You lost $lost levels. (Now level $($script:PlayerLevel))" "Red"
            }
            Write-Host ""
            Read-Host "  [Press Enter to continue]" | Out-Null
        }
    }
}

# ─── DUNGEON EXPLORATION LOOP ────────────────────────────────────
# ─── LOCKPICKING MINIGAME ─────────────────────────────────────────
# Adapted from the standalone lockpicking.ps1. Wrapped as a function that:
#   - Takes number of tumblers (difficulty) scaled by dungeon level
#   - Uses actual $script:Lockpicks count (displayed as a number)
#   - Returns @{ Success; Aborted; PicksUsed }
#   - Uses $script:lp* names so it doesn't clobber main game state
function Start-Lockpicking {
    param(
        [int]$Tumblers = 4,      # 3 (easy), 4 (normal), 5 (hard)
        [int]$AvailablePicks = 5
    )

    # Drain stale keys so a held movement key doesn't auto-break a pick
    try {
        while($Host.UI.RawUI.KeyAvailable){
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    } catch {}

    # Snapshot screen state so we can restore after
    $wasVisible = $true
    try { $wasVisible = [Console]::CursorVisible } catch {}
    try { [Console]::CursorVisible = $false } catch {}

    # Input mode detection (same as original)
    $script:lpInputMode = 'none'
    try { $null = [Console]::KeyAvailable; $script:lpInputMode = 'console' } catch {
        try { $null = $Host.UI.RawUI.KeyAvailable; $script:lpInputMode = 'rawui' } catch {}
    }
    if($script:lpInputMode -eq 'none'){
        Write-CL "  Lockpicking unavailable in this host (needs key input)." "Red"
        Wait-Key
        return @{ Success=$false; Aborted=$true; PicksUsed=0 }
    }

    # Config - scaled difficulty
    $TC    = $Tumblers       # tumblers
    $GH    = 8               # grid rows
    $SZ    = 2               # sweet zone rows: abs(row-center) < SZ -> 3-row window
    $CW    = 6               # column width
    $FMS   = 50              # frame ms
    $IW    = $TC * $CW + ($TC - 1)

    # State (all lp-prefixed)
    $script:lpLocked = @()
    for($i=0;$i -lt $TC;$i++){ $script:lpLocked += $false }
    $script:lpCur     = 0
    $script:lpPicks   = $AvailablePicks
    $script:lpPicksUsed = 0
    $script:lpT       = 0.0
    $script:lpRun     = $true
    $script:lpWon     = $false
    $script:lpAborted = $false
    $script:lpMsg     = ''
    $script:lpMsgC    = 'Gray'
    $script:lpMsgT    = 0
    $script:lpAnim    = 'none'
    $script:lpAnimF   = 0
    $script:lpAnimPin = 0

    # Rhythm — a bit faster as more tumblers, plus per-tumbler random sweet-zone center
    $script:lpRng = [System.Random]::new()
    $script:lpFrq = @()
    $script:lpPhs = @()
    $script:lpSweet = @()  # sweet zone center row per tumbler (random per lock)
    for($i=0;$i -lt $TC;$i++){
        $script:lpFrq += 2.0 + $i * 0.22 + ($script:lpRng.NextDouble() - 0.5) * 0.3
        $script:lpPhs += $i * 1.3 + $script:lpRng.NextDouble() * 0.5
        # Sweet zone can be anywhere from row 0 to row GH-1 (so sometimes top, sometimes bottom, sometimes middle)
        $script:lpSweet += $script:lpRng.Next(0, $GH)
    }

    $H  = [string]([char]0x2550); $V  = [string]([char]0x2551)
    $TL = [string]([char]0x2554); $TR = [string]([char]0x2557)
    $BL = [string]([char]0x255A); $BR = [string]([char]0x255D)
    $ML = [string]([char]0x2560); $MR = [string]([char]0x2563)
    $TJ = [string]([char]0x2564); $BJ = [string]([char]0x2567)
    $TV = [string]([char]0x2502)
    $FK = [string]([char]0x2588); $LB = [string]([char]0x2591)

    $LINE_W = 80

    function lp-Pad([string]$s){
        if($s.Length -ge $LINE_W){ return $s.Substring(0, $LINE_W) }
        return $s + (' ' * ($LINE_W - $s.Length))
    }
    function lp-ResetScreen {
        try {
            $z = New-Object System.Management.Automation.Host.Coordinates(0,0)
            $Host.UI.RawUI.CursorPosition = $z
        } catch {
            try { [Console]::SetCursorPosition(0,0) } catch { Clear-Host }
        }
    }
    function lp-GetKey {
        if($script:lpInputMode -eq 'console'){
            try { if([Console]::KeyAvailable){ return [Console]::ReadKey($true).Key.ToString() } } catch {}
        } elseif($script:lpInputMode -eq 'rawui'){
            try { if($Host.UI.RawUI.KeyAvailable){ return [string]($Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown').VirtualKeyCode) } } catch {}
        }
        return $null
    }
    function lp-GetPinRow([int]$i){
        if($script:lpLocked[$i]){ return 0 }
        $v = [Math]::Sin($script:lpT * $script:lpFrq[$i] + $script:lpPhs[$i])
        return [int][Math]::Round(($v + 1) / 2 * ($GH - 1))
    }
    function lp-TestSweet([int]$i){
        $row = lp-GetPinRow $i
        $center = $script:lpSweet[$i]
        # SZ=1 means single row; SZ=2 would mean center row plus one above
        return ([math]::Abs($row - $center) -lt $SZ)
    }

    Clear-Host

    # Render frame — drawn from scratch each tick
    $renderFrame = {
        lp-ResetScreen
        $sx = 0
        if($script:lpAnim -eq 'fail' -and $script:lpAnimF -lt 6){
            $sa = @(2,-2,1,-1,1,0); $sx = $sa[$script:lpAnimF]
        }
        $cp = ' ' * [Math]::Max(0, 9 + $sx)
        $lp = ' ' * [Math]::Max(0, 5 + $sx)

        # Chest
        Write-Host (lp-Pad "$cp   ._______________.")     -ForegroundColor Yellow
        Write-Host (lp-Pad "$cp  /   .--=====--.   \")    -ForegroundColor Yellow
        Write-Host "$cp /___| |" -NoNewline -ForegroundColor DarkYellow
        if($script:lpWon){ Write-Host " OPEN! " -NoNewline -ForegroundColor Green }
        else { Write-Host "LOCKED!" -NoNewline -ForegroundColor Red }
        $endStr = "| |___\"
        $used   = "$cp /___| |".Length + 7 + $endStr.Length
        $trail  = $LINE_W - $used
        if($trail -lt 0){ $trail = 0 }
        Write-Host "$endStr$(' ' * $trail)" -ForegroundColor DarkYellow
        Write-Host (lp-Pad "$cp |   | '-------' |   |")   -ForegroundColor DarkYellow
        Write-Host (lp-Pad "$cp |   '-----------'   |")   -ForegroundColor DarkYellow
        Write-Host (lp-Pad "$cp |_____________________|") -ForegroundColor DarkYellow
        Write-Host (lp-Pad "$cp  \___________________/")  -ForegroundColor DarkYellow

        # Top border
        Write-Host (lp-Pad "$lp$TL$($H * $IW)$TR") -ForegroundColor Cyan

        # Title row (shows PICK COUNT AS NUMBER)
        $pkC = 'Green'
        if($script:lpPicks -le 1){ $pkC = 'Red' }
        elseif($script:lpPicks -le 2){ $pkC = 'Yellow' }
        $pickStr = "Picks: $($script:lpPicks)"
        $gap = $IW - 13 - $pickStr.Length - 1
        if($gap -lt 1){ $gap = 1 }
        Write-Host "$lp$V" -NoNewline -ForegroundColor Cyan
        Write-Host " LOCKPICKING" -NoNewline -ForegroundColor White
        Write-Host "$(' ' * $gap) " -NoNewline
        Write-Host $pickStr -NoNewline -ForegroundColor $pkC
        $titleUsed  = "$lp$V".Length + 12 + $gap + 1 + $pickStr.Length + 1
        $titleTrail = $LINE_W - $titleUsed
        if($titleTrail -lt 0){ $titleTrail = 0 }
        Write-Host "$V$(' ' * $titleTrail)" -ForegroundColor Cyan

        # Grid top separator
        $sep = $ML
        for($c=0;$c -lt $TC;$c++){
            if($c -gt 0){ $sep += $TJ }
            $sep += $H * $CW
        }
        $sep += $MR
        Write-Host (lp-Pad "$lp$sep") -ForegroundColor Cyan

        # Grid rows
        for($r=0;$r -lt $GH;$r++){
            Write-Host "$lp$V" -NoNewline -ForegroundColor Cyan
            for($c=0;$c -lt $TC;$c++){
                # Per-tumbler sweet check: cell is "in sweet" if this column's
                # sweet center is within $SZ rows of the current row.
                $cellSweet = ([math]::Abs($r - $script:lpSweet[$c]) -lt $SZ)

                if($c -gt 0){
                    $sepC = 'DarkGray'
                    if($cellSweet){ $sepC = 'DarkGreen' }
                    Write-Host "$TV" -NoNewline -ForegroundColor $sepC
                }
                $pinR  = lp-GetPinRow $c
                $isCur = ($c -eq $script:lpCur)
                $isLck = $script:lpLocked[$c]
                $isAn  = ($script:lpAnim -ne 'none' -and $c -eq $script:lpAnimPin)
                if($pinR -eq $r){
                    if($isLck){
                        $cc = 'Green'
                        if($isAn -and $script:lpAnim -eq 'success' -and ($script:lpAnimF % 4 -lt 2)){ $cc = 'Yellow' }
                        Write-Host " [##] " -NoNewline -ForegroundColor $cc
                    } elseif($isCur){
                        if($isAn -and $script:lpAnim -eq 'fail' -and ($script:lpAnimF % 3 -lt 2)){
                            Write-Host " >XX< " -NoNewline -ForegroundColor Red
                        } elseif($cellSweet){
                            Write-Host " >##< " -NoNewline -ForegroundColor Yellow
                        } else {
                            Write-Host " >##< " -NoNewline -ForegroundColor White
                        }
                    } else {
                        Write-Host " [##] " -NoNewline -ForegroundColor Gray
                    }
                } else {
                    if($cellSweet){ Write-Host "  ~~  " -NoNewline -ForegroundColor DarkGreen }
                    else { Write-Host "      " -NoNewline }
                }
            }
            $rowUsed  = "$lp$V".Length + ($TC * $CW) + ($TC - 1) + 1
            $rowTrail = $LINE_W - $rowUsed
            if($rowTrail -lt 0){ $rowTrail = 0 }
            Write-Host "$V$(' ' * $rowTrail)" -ForegroundColor Cyan
        }

        # Bottom separator
        $sep2 = $ML
        for($c=0;$c -lt $TC;$c++){
            if($c -gt 0){ $sep2 += $BJ }
            $sep2 += $H * $CW
        }
        $sep2 += $MR
        Write-Host (lp-Pad "$lp$sep2") -ForegroundColor Cyan

        # Selector arrow
        Write-Host "$lp$V" -NoNewline -ForegroundColor Cyan
        for($c=0;$c -lt $TC;$c++){
            if($c -gt 0){ Write-Host " " -NoNewline }
            if($c -eq $script:lpCur -and -not $script:lpLocked[$c]){
                Write-Host "  /\  " -NoNewline -ForegroundColor Yellow
            } else { Write-Host "      " -NoNewline }
        }
        $arrowTrail = $LINE_W - ("$lp$V".Length + ($TC * $CW) + ($TC - 1) + 1)
        if($arrowTrail -lt 0){ $arrowTrail = 0 }
        Write-Host "$V$(' ' * $arrowTrail)" -ForegroundColor Cyan

        Write-Host (lp-Pad "$lp$BL$($H * $IW)$BR") -ForegroundColor Cyan

        # Timing bar — now reflects the ACTIVE pin's distance from its sweet center.
        # Closer to center = fuller bar / greener color. When in sweet zone (SZ rows of
        # center), bar shows ">>> NOW! <<<". This makes the visual cue match the actual
        # win condition.
        $curPin = $script:lpCur
        $pinRow = lp-GetPinRow $curPin
        $sweetCenter = $script:lpSweet[$curPin]
        $rowDist = [math]::Abs($pinRow - $sweetCenter)
        # Distance maps to 0..1 closeness (0 = far, 1 = on sweet)
        $closeness = 1.0 - ([double]$rowDist / [double]($GH - 1))
        if($closeness -lt 0){ $closeness = 0 }

        $barLen = 20
        $fill = [int][Math]::Round($closeness * $barLen)
        if($fill -lt 0){ $fill = 0 }
        if($fill -gt $barLen){ $fill = $barLen }
        $remain = $barLen - $fill

        $inSweet = (lp-TestSweet $curPin)
        $barC = 'DarkGray'
        if($inSweet){ $barC = 'Green' }
        elseif($closeness -gt 0.7){ $barC = 'DarkGreen' }
        elseif($closeness -gt 0.4){ $barC = 'Yellow' }

        Write-Host "$lp Timing:[" -NoNewline -ForegroundColor DarkGray
        if($fill -gt 0){ Write-Host "$($FK * $fill)" -NoNewline -ForegroundColor $barC }
        if($remain -gt 0){ Write-Host "$($LB * $remain)" -NoNewline -ForegroundColor DarkGray }
        Write-Host "] " -NoNewline -ForegroundColor DarkGray
        $nowStr = if($inSweet){ ">>> NOW! <<<" } else { "            " }
        $barUsed = "$lp Timing:[".Length + $barLen + 2 + $nowStr.Length
        $barTrail = $LINE_W - $barUsed
        if($barTrail -lt 0){ $barTrail = 0 }
        if($inSweet){ Write-Host "$nowStr$(' ' * $barTrail)" -ForegroundColor Green }
        else { Write-Host "$nowStr$(' ' * $barTrail)" }

        # Message line
        if($script:lpMsg -ne ''){
            Write-Host (lp-Pad "  $($script:lpMsg)") -ForegroundColor $script:lpMsgC
        } else {
            Write-Host (lp-Pad "")
        }
        Write-Host (lp-Pad "  [SPACE] Pick  [< >] Select  [ESC] Walk Away") -ForegroundColor DarkCyan
    }

    # Input handler
    $handleInput = {
        $key = lp-GetKey
        while($key -ne $null){
            if($script:lpAnim -ne 'none'){ $key = lp-GetKey; continue }
            $isSpace = ($key -eq 'Spacebar' -or $key -eq '32')
            $isLeft  = ($key -eq 'LeftArrow' -or $key -eq 'Left' -or $key -eq '37')
            $isRight = ($key -eq 'RightArrow' -or $key -eq 'Right' -or $key -eq '39')
            $isEsc   = ($key -eq 'Escape' -or $key -eq '27')

            if($isSpace -and -not $script:lpLocked[$script:lpCur]){
                if(lp-TestSweet $script:lpCur){
                    $script:lpLocked[$script:lpCur] = $true
                    $script:lpAnim = 'success'
                    $script:lpAnimF = 0
                    $script:lpAnimPin = $script:lpCur
                    $script:lpMsg = "* CLICK * Tumbler $($script:lpCur + 1) is set!"
                    $script:lpMsgC = 'Green'
                    $script:lpMsgT = 35
                    $allDone = $true
                    for($j=0;$j -lt $TC;$j++){
                        if(-not $script:lpLocked[$j]){ $allDone = $false; break }
                    }
                    if($allDone){
                        $script:lpWon = $true
                        $script:lpMsg = "** LOCK OPENED! The chest is yours! **"
                        $script:lpMsgC = 'Yellow'
                        $script:lpMsgT = 999
                    } else {
                        for($j=1;$j -le $TC;$j++){
                            $nx = ($script:lpCur + $j) % $TC
                            if(-not $script:lpLocked[$nx]){ $script:lpCur = $nx; break }
                        }
                    }
                } else {
                    $script:lpPicks--
                    $script:lpPicksUsed++
                    $script:lpAnim = 'fail'
                    $script:lpAnimF = 0
                    $script:lpAnimPin = $script:lpCur
                    if($script:lpPicks -le 0){
                        $script:lpMsg = "All lockpicks broken... the lock wins."
                        $script:lpMsgC = 'DarkRed'
                        $script:lpMsgT = 999
                        $script:lpRun = $false
                    } else {
                        $script:lpMsg = "SNAP! Pick broke! ($($script:lpPicks) left)"
                        $script:lpMsgC = 'Red'
                        $script:lpMsgT = 40
                        for($j=0;$j -lt $TC;$j++){
                            if($script:lpLocked[$j] -and ($script:lpRng.NextDouble() -lt 0.25)){
                                $script:lpLocked[$j] = $false
                                $script:lpMsg += " [T$($j+1) fell!]"
                            }
                        }
                    }
                }
            } elseif($isLeft){
                $ul = @()
                for($j=0;$j -lt $TC;$j++){ if(-not $script:lpLocked[$j]){ $ul += $j } }
                if($ul.Count -gt 0){
                    $idx = [Array]::IndexOf($ul, $script:lpCur)
                    if($idx -le 0){ $script:lpCur = $ul[$ul.Count - 1] }
                    else { $script:lpCur = $ul[$idx - 1] }
                }
            } elseif($isRight){
                $ul = @()
                for($j=0;$j -lt $TC;$j++){ if(-not $script:lpLocked[$j]){ $ul += $j } }
                if($ul.Count -gt 0){
                    $idx = [Array]::IndexOf($ul, $script:lpCur)
                    if($idx -ge ($ul.Count - 1) -or $idx -lt 0){ $script:lpCur = $ul[0] }
                    else { $script:lpCur = $ul[$idx + 1] }
                }
            } elseif($isEsc){
                $script:lpRun = $false
                $script:lpAborted = $true
                $script:lpMsg = "You step away. The lock remains, disturbed."
                $script:lpMsgC = 'DarkGray'
                $script:lpMsgT = 999
            }
            $key = lp-GetKey
        }
    }

    # Main loop
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $lastMs = $clock.ElapsedMilliseconds
    try {
        while($script:lpRun){
            $nowMs = $clock.ElapsedMilliseconds
            if(($nowMs - $lastMs) -lt $FMS){
                Start-Sleep -Milliseconds 5
                continue
            }
            $dt = ($nowMs - $lastMs) / 1000.0
            $lastMs = $nowMs
            $script:lpT += $dt

            if($script:lpMsgT -gt 0){
                $script:lpMsgT--
                if($script:lpMsgT -eq 0 -and $script:lpRun){ $script:lpMsg = '' }
            }
            if($script:lpAnim -ne 'none'){
                $script:lpAnimF++
                if($script:lpAnim -eq 'success' -and $script:lpAnimF -ge 10){ $script:lpAnim = 'none' }
                if($script:lpAnim -eq 'fail' -and $script:lpAnimF -ge 8){ $script:lpAnim = 'none' }
            }

            & $handleInput

            if($script:lpWon -and $script:lpAnim -eq 'none'){
                & $renderFrame
                Start-Sleep -Milliseconds 1500
                $script:lpRun = $false
                break
            }
            & $renderFrame
        }
        & $renderFrame
        Start-Sleep -Seconds 1
    } finally {
        try { [Console]::CursorVisible = $wasVisible } catch {}
        # Drain any queued keys from the minigame so they don't leak into the dungeon loop
        try {
            while($Host.UI.RawUI.KeyAvailable){
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
        } catch {}
    }

    return @{
        Success    = $script:lpWon
        Aborted    = $script:lpAborted
        PicksUsed  = $script:lpPicksUsed
    }
}



function Enter-Dungeon {
    $script:DungeonLevel++
    $script:HasBossKey   = $false
    $script:BossDefeated = $false
    $script:Dungeon = New-Dungeon $script:DungeonLevel
    $script:DisturbedChests = @{}  # fresh dungeon = fresh disturbed-chest tracking
    $script:EncountersThisDungeon = 0  # reset encounter cap counter
    $script:EncounterTiles = @{}      # reset per-tile encounter history

    # Restore some HP/MP on entry
    $script:Player.HP = [math]::Min($script:Player.HP + [math]::Floor($script:Player.MaxHP*0.3), $script:Player.MaxHP)
    $script:Player.MP = [math]::Min($script:Player.MP + [math]::Floor($script:Player.MaxMP*0.3), $script:Player.MaxMP)

    # Reset frame buffer so the first dungeon render is a full paint
    Reset-FrameBuffer

    # If the terminal window is too small for buffered rendering, show a
    # one-time informational page so the player knows how to enable the
    # smoother mode. The game still plays fine at any size — small
    # windows just fall back to clear-and-redraw each frame.
    try {
        $ws = $Host.UI.RawUI.WindowSize
        if($ws.Width -lt 80 -or $ws.Height -lt 32){
            clr
            Write-Host ""
            Write-CL "  ╔══════════════════════════════════════════════════════════════════╗" "DarkYellow"
            Write-CL "  ║              W I N D O W   T O O   S M A L L                     ║" "Yellow"
            Write-CL "  ╚══════════════════════════════════════════════════════════════════╝" "DarkYellow"
            Write-Host ""
            Write-C   "  Your terminal is currently " "Gray"
            Write-C   "$($ws.Width)x$($ws.Height)" "DarkYellow"
            Write-CL  ". The dungeon will play just fine," "Gray"
            Write-CL  "  but you'll see a full screen refresh on every step." "Gray"
            Write-Host ""
            Write-C   "  Resize the window to at least " "Gray"
            Write-C   "80x32" "Cyan"
            Write-CL  " to enable " "Gray"
            Write-C   "  smooth rendering" "Cyan"
            Write-CL  " — the dungeon updates near real-time, redrawing" "Gray"
            Write-CL  "  only the parts that changed instead of repainting the whole screen" "Gray"
            Write-CL  "  each turn." "Gray"
            Write-Host ""
            Write-C   "  The simplest fix: " "White"
            Write-CL  "maximize the window." "White"
            Write-CL  "  Click the maximize button in the top-right corner of your terminal," "Gray"
            Write-C   "  or press " "Gray"
            Write-C   "Win+Up Arrow" "DarkGray"
            Write-CL  " on Windows. You can also resize at any time" "Gray"
            Write-CL  "  during play and the game will switch modes automatically." "Gray"
            Write-Host ""
            Write-C   "  [Press Enter to continue]" "DarkGray"
            Read-Host | Out-Null
        }
    } catch {}

    # Movement throttle: after a WASD action, the player must wait at
    # least $moveCooldownMs before the next movement registers. This
    # stops keyboard auto-repeat from zooming the player across the map
    # now that the render is fast enough to make every tick count.
    $moveCooldownMs   = 130
    $lastMoveStamp    = [DateTime]::MinValue   # time of last WASD action

    $inDungeon = $true
    while($inDungeon -and $script:Player.HP -gt 0){
        $d = $script:Dungeon

        # Render everything (3D viewport, minimap, HUD, status, controls bar)
        # into the frame buffer, then Flush-Frame paints only changed cells.
        # The controls bar lives INSIDE the buffer so the cursor never has
        # to write past the buffer's last row, which would scroll the
        # terminal and invalidate our absolute cursor positions.
        Begin-Frame
        if($script:BufferedDisabled){
            # Window too short for buffered rendering — old-style clear+draw
            clr
            Render-Screen
            Write-CL "  [W] Forward  [A] Turn Left  [D] Turn Right  [S] Back" "DarkGray"
            Write-CL "  [P] Potion   [I] Inventory  [J] Quests  [Q] Quit" "DarkGray"
            Write-C "  > " "Yellow"
        } else {
            Render-Screen
            # Controls bar at the bottom of the buffer
            Write-CL "  [W] Forward  [A] Turn Left  [D] Turn Right  [S] Back" "DarkGray"
            Write-CL "  [P] Potion   [I] Inventory  [J] Quests  [Q] Quit" "DarkGray"
            Write-C "  > " "Yellow"
            # Capture where the prompt ends, so after Flush-Frame we can put
            # the cursor there for the user's keystroke to echo cleanly.
            $promptRow = $script:FrameRow
            $promptCol = $script:FrameCol
            Flush-Frame
            # Position the cursor at the end of the prompt so the keystroke
            # echo lands in the right spot. Falls through silently on hosts
            # without positioning.
            if(Test-CursorPositionOK){
                try {
                    $r = [math]::Min($promptRow, $script:FrameRows - 1)
                    $c = [math]::Min($promptCol, $script:FrameCols - 1)
                    $pos = New-Object System.Management.Automation.Host.Coordinates $c, $r
                    $Host.UI.RawUI.CursorPosition = $pos
                } catch {}
            }
        }

        # Movement throttle: enforce minimum dwell time since the last
        # WASD action before reading the next key. Non-movement keys are
        # not throttled (the cap only applies AFTER a previous move).
        $sinceMove = ([DateTime]::Now - $lastMoveStamp).TotalMilliseconds
        if($sinceMove -lt $moveCooldownMs){
            $waitMs = [int]($moveCooldownMs - $sinceMove)
            if($waitMs -gt 0){ Start-Sleep -Milliseconds $waitMs }
            # Drain any keys queued during the cooldown so auto-repeat
            # doesn't immediately register the next move.
            try {
                while($Host.UI.RawUI.KeyAvailable){
                    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                }
            } catch {}
        }

        $key = Read-DungeonKey
        # Don't echo the key in buffered mode — it would scroll the terminal
        # if the cursor is at the last visible row. The next frame's
        # diff-paint will show the result of the action anyway.
        if($script:BufferedDisabled){
            Write-Host $key -ForegroundColor Cyan
        }

        # Encumbrance gate: WASD movement blocked when over weight cap.
        # Player must open inventory (key 'I') and drop items to free up space.
        $upperKey = $key.ToUpper()
        $isMoveKey = ($upperKey -eq "W" -or $upperKey -eq "A" -or $upperKey -eq "S" -or $upperKey -eq "D")
        if($isMoveKey){
            # Stamp the move time even if the action ends up blocked — the
            # cooldown still applies so spamming W against a wall doesn't
            # fall through into hyper-speed input later.
            $lastMoveStamp = [DateTime]::Now
        }
        if($isMoveKey -and (Test-Encumbered)){
            $cur = Get-CurrentCarryWeight
            $max = Get-MaxCarryWeight $script:Player
            $script:StatusMsg = "OVER ENCUMBERED ($cur/$max) — open inventory [I] and drop items"
            continue
        }

        switch($upperKey){
            "W" {
                $fwd = Get-Forward $d.PDir 1
                $nx = $d.PX + $fwd[0]
                $ny = $d.PY + $fwd[1]
                if($nx -ge 0 -and $nx -lt $d.W -and $ny -ge 0 -and $ny -lt $d.H -and $d.Grid[$ny,$nx] -ne 1){
                    $cell = $d.Grid[$ny,$nx]

                    if($cell -eq 2 -or $cell -eq 3){
                        $eKey = "$nx,$ny"
                        if($d.Enemies.ContainsKey($eKey)){
                            $result = Start-Combat $d.Enemies[$eKey]
                            if($result.Result -eq "Death"){
                                $inDungeon = $false
                            }
                            elseif($result.Result -eq "Won"){
                                $d.Enemies.Remove($eKey)
                                $d.Grid[$ny,$nx] = 0
                                $d.PX = $nx; $d.PY = $ny
                            }
                        }
                    }
                    elseif($cell -eq 4){
                        if($script:HasBossKey){
                            $script:StatusMsg = "You unlock the boss room with the key!"
                            # Survivor quest: credit if HP is above 50% when entering the boss room
                            if($script:Player.HP -gt ($script:Player.MaxHP * 0.5)){
                                Update-QuestProgress "Survivor"
                            }
                            # Untouched achievement counter: 75% HP threshold (stricter)
                            if($script:Player.HP -gt ($script:Player.MaxHP * 0.75)){
                                $script:TotalUntouched++
                            }
                            $eKey = "$nx,$ny"
                            if($d.Enemies.ContainsKey($eKey)){
                                $result = Start-Combat $d.Enemies[$eKey]
                                if($result.Result -eq "Death"){
                                    $inDungeon = $false
                                }
                                elseif($result.Result -eq "Won"){
                                    $d.Enemies.Remove($eKey)
                                    $d.Grid[$ny,$nx] = 0
                                    $d.PX = $nx; $d.PY = $ny
                                }
                            }
                        } else {
                            $script:StatusMsg = "The door is LOCKED. Defeat the mini-boss for the key!"
                        }
                    }
                    elseif($cell -eq 5){
                        if($script:BossDefeated){
                            $d.PX = $nx; $d.PY = $ny
                            clr
                            Write-CL "" "Green"
                            Write-CL "  ╔════════════════════════════════════════════════════╗" "DarkYellow"
                            Write-CL "  ║                                                    ║" "DarkYellow"
                            Write-CL "  ║          D U N G E O N   C L E A R E D !           ║" "Yellow"
                            Write-CL "  ║                                                    ║" "DarkYellow"
                            Write-CL "  ╚════════════════════════════════════════════════════╝" "DarkYellow"
                            Write-Host ""
                            Write-CL "       .     *    .   *     .    *   .    *" "DarkYellow"
                            Write-CL "    *    .      .       *      .       .   " "Yellow"
                            Write-CL "       .    *      .      *    .    *      " "DarkYellow"
                            Write-Host ""
                            Write-CL "  You emerge victorious from Dungeon Level $($script:DungeonLevel)!" "Green"
                            Write-Host ""

                            # Streak tracking: survived a clear
                            $script:Streak++
                            if($script:Streak -gt $script:BestStreak){
                                $script:BestStreak = $script:Streak
                            }
                            Write-CL "  Current clear streak: $($script:Streak)x" "Yellow"

                            $dailyMultiplier = if($script:DailyDungeonActive){2}else{1}
                            $bonusGold = 100 * $dailyMultiplier
                            $script:Gold += $bonusGold
                            if($dailyMultiplier -gt 1){
                                Write-CL "  + $bonusGold Gold (DAILY DUNGEON 2x BONUS!)" "Yellow"
                            } else {
                                Write-CL "  + $bonusGold Gold (Completion Bonus)" "Yellow"
                            }

                            Write-Host ""
                            Write-CL "  ── Treasure Haul ──" "Magenta"
                            Write-CL "  (clear-bonus loot bypasses carry weight)" "DarkGray"
                            $lootCount = 3 * $dailyMultiplier
                            for($ti=0;$ti -lt $lootCount;$ti++){
                                $treasure = Init-ItemWeight (New-RandomLoot ($script:DungeonLevel + 1)) "Loot"
                                [void]$script:Inventory.Add($treasure)
                                Write-CL "    + $($treasure.Name) (Value: $($treasure.Value)g, Wt: $($treasure.Weight))" "Magenta"
                            }
                            # If this clear loot put the player over weight, flag it
                            if(Test-Encumbered){
                                $cur = Get-CurrentCarryWeight
                                $max = Get-MaxCarryWeight $script:Player
                                Write-Host ""
                                Write-CL "  ! You're now over-encumbered ($cur/$max)." "Yellow"
                                Write-CL "    Visit the Market or Inventory before entering another dungeon." "DarkGray"
                            }

                            # ── Special items: not sold in shops, only earned here ──
                            # Repair Kit: 25% per clear (50% on Daily)
                            $kitChance = if($script:DailyDungeonActive){50}else{25}
                            if((Get-Random -Max 100) -lt $kitChance){
                                $kits = if($script:DailyDungeonActive){2}else{1}
                                $script:RepairKits += $kits
                                $kitWord = if($kits -eq 1){"Repair Kit"}else{"Repair Kits"}
                                Write-CL "    * $kits $kitWord found! (use to instantly repair all gear)" "Cyan"
                            }
                            # Extra Strong Potion: 20% per clear (40% on Daily)
                            $espChance = if($script:DailyDungeonActive){40}else{20}
                            if((Get-Random -Max 100) -lt $espChance){
                                $script:ExtraStrongPotions++
                                Write-CL "    * 1 Extra Strong Potion found! (full HP+MP restore in combat)" "Green"
                            }

                            # Mark daily dungeon done if applicable
                            if($script:DailyDungeonActive){
                                $script:DailyDungeonDone = $true
                                Try-UnlockAchievement "DailyDiver"
                            }

                            Check-Achievements

                            Write-Host ""
                            $totalLoot = 0
                            foreach($it in $script:Inventory){ $totalLoot += $it.Value }
                            Write-CL "  Total loot in inventory: ${totalLoot}g sell value" "DarkGray"
                            Write-CL "  Gold on hand: $($script:Gold)g" "Yellow"
                            Write-Host ""
                            Wait-Key
                            $inDungeon = $false
                        } else {
                            $script:StatusMsg = "Defeat the BOSS before you can leave!"
                        }
                    }
                    elseif($cell -eq 6){
                        # ── LOCKPICKING FLOW ──
                        $chestKey = "$nx,$ny"

                        # Already disturbed (from earlier abort)? chest is jammed
                        if($script:DisturbedChests.ContainsKey($chestKey)){
                            $script:StatusMsg = "This chest is jammed from earlier tampering."
                        }
                        # Out of picks? can't attempt at all
                        elseif($script:Lockpicks -lt 1){
                            $script:StatusMsg = "You need a lockpick to open this chest."
                        }
                        else {
                            # Difficulty scales with dungeon level
                            # Tumbler count scales with dungeon depth
                            $tumblers = 3
                            if($script:DungeonLevel -ge 3){  $tumblers = 4 }
                            if($script:DungeonLevel -ge 6){  $tumblers = 5 }
                            if($script:DungeonLevel -ge 10){ $tumblers = 6 }

                            $result = Start-Lockpicking -Tumblers $tumblers -AvailablePicks $script:Lockpicks

                            # Deduct picks used (whether success, fail, or abort)
                            $script:Lockpicks -= $result.PicksUsed
                            if($script:Lockpicks -lt 0){ $script:Lockpicks = 0 }

                            if($result.Success){
                                # ── Success: award loot, higher tumbler count = better rewards ──
                                clr
                                Write-Host ""
                                Write-CL "  The lock gives way with a satisfying CLICK!" "Yellow"
                                Write-Host ""

                                $goldMin = 10 * $tumblers
                                $goldMax = $goldMin + (20 * $tumblers) + (15 * $script:DungeonLevel)
                                $tGold = Get-Random -Min $goldMin -Max $goldMax
                                $tGold = [int]$tGold

                                # Build chest loot pile — gold goes in here too
                                $chestPile = @()
                                if($tGold -gt 0){
                                    $chestPile += @{
                                        Name     = "Gold ($tGold)"
                                        Kind     = "Gold"
                                        Quantity = $tGold
                                        Weight   = 0
                                        Value    = $tGold
                                    }
                                }
                                $chestPile += (Init-ItemWeight (New-RandomLoot ($script:DungeonLevel + $tumblers - 3)) "Loot")

                                # Small chance of rare drop
                                $rareRoll = Get-Random -Max 100
                                if($rareRoll -lt 10){
                                    # 10%: hidden potion
                                    $potShop = Get-PotionShop | Where-Object { $_.Category -eq "Potion" }
                                    $potDrop = $potShop | Get-Random
                                    $potCopy = @{}
                                    foreach($k in $potDrop.Keys){ $potCopy[$k] = $potDrop[$k] }
                                    $potCopy.Kind = "Potion"
                                    $potCopy.Weight = 1
                                    $chestPile += $potCopy
                                } elseif($rareRoll -lt 25){
                                    # 15%: bonus lockpicks (now a stackable lootable item)
                                    $bonusPicks = Get-Random -Min 1 -Max 4
                                    $pickBundle = @{
                                        Name      = "Lockpick Bundle (x$bonusPicks)"
                                        Kind      = "Lockpicks"
                                        Quantity  = $bonusPicks
                                        Weight    = $bonusPicks    # 1wt per pick
                                        Value     = $bonusPicks * 25
                                        Desc      = "$bonusPicks lockpicks. Each weighs 1."
                                    }
                                    $chestPile += $pickBundle
                                }

                                Update-QuestProgress "Treasure"
                                Update-QuestProgress "Lockpicker"; $script:TotalLocksPicked++
                                $d.Grid[$ny,$nx] = 0      # remove chest (taken or not)
                                $d.PX = $nx; $d.PY = $ny

                                Wait-Key
                                $taken = Show-LootScreen -Title "TREASURE INSIDE" -Items $chestPile
                                if($taken.Count -gt 0){
                                    clr
                                    Write-Host ""
                                    Write-CL "  Loot stowed:" "Magenta"
                                    foreach($t in $taken){
                                        $kindTag = switch($t.Kind){"Weapon"{"[Wpn]"}"Armor"{"[Arm]"}default{""}}
                                        Write-CL "    + $($t.Name) $kindTag" "Magenta"
                                    }
                                    Write-Host ""
                                    Read-Host "  [Press Enter to continue]" | Out-Null
                                } else {
                                    Write-CL "  You leave the chest's contents behind." "DarkGray"
                                    Read-Host "  [Press Enter to continue]" | Out-Null
                                }
                            } elseif($result.Aborted){
                                # ESC = disturbed, can't retry
                                $script:DisturbedChests[$chestKey] = $true
                                $script:StatusMsg = "You walk away. The lock is disturbed — it won't yield again."
                            } else {
                                # Ran out of picks = also disturbed (consistent with abort)
                                $script:DisturbedChests[$chestKey] = $true
                                $script:StatusMsg = "All picks broke. The lock stays shut."
                            }
                        }
                    }

                    elseif($cell -eq 7){
                        # Drain held-key buffer so a held W doesn't skip through
                        try {
                            while($Host.UI.RawUI.KeyAvailable){
                                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                            }
                        } catch {}
                        clr
                        Write-CL "" "Yellow"
                        Write-CL "  ╔════════════════════════════════════════════════════╗" "DarkYellow"
                        Write-CL "  ║                                                    ║" "DarkYellow"
                        Write-CL "  ║       'Thank the gods you found me!'               ║" "Yellow"
                        Write-CL "  ║       'I've been lost down here for days!'         ║" "Yellow"
                        Write-CL "  ║                                                    ║" "DarkYellow"
                        Write-CL "  ╚════════════════════════════════════════════════════╝" "DarkYellow"
                        Write-Host ""
                        Write-CL "  The lost adventurer follows you to safety." "Green"
                        Write-Host ""
                        Update-QuestProgress "Rescue"
                        $d.Grid[$ny,$nx] = 0
                        $d.PX = $nx; $d.PY = $ny
                        Read-Host "  [Press Enter to continue]" | Out-Null
                    }
                    else {
                        $d.PX = $nx; $d.PY = $ny
                        # Random encounter roll on each forward step (empty floor only).
                        # Dutchman: level 15+, daily-dungeon only, not if already won.
                        # Non-Dutchman encounters: ~1.5% per step, cap of 2 per dungeon.
                        # Tiles that already triggered an encounter this dungeon don't fire again.
                        $tileKey = "$nx,$ny"
                        $tileFreshForEncounter = -not $script:EncounterTiles.ContainsKey($tileKey)
                        $roll = Get-Random -Minimum 0 -Maximum 1000
                        $dutchAllowed = (
                            $script:DailyDungeonActive -and
                            $script:PlayerLevel -ge 15 -and
                            -not $script:OwnsDutchmanBlade
                        )
                        # Repair encounter (rare metalsmith): 0.3% per step, any dungeon, any level.
                        # Only fires if there's actually damaged gear to repair.
                        $hasDamagedGear = $false
                        if($script:EquippedWeapon -and $script:EquippedWeapon.MaxDurability -ge 0 -and $script:EquippedWeapon.Durability -lt $script:EquippedWeapon.MaxDurability){
                            $hasDamagedGear = $true
                        }
                        if(-not $hasDamagedGear){
                            foreach($slotN in @("Helmet","Chest","Shield","Amulet","Boots")){
                                $pp = $script:EquippedArmor[$slotN]
                                if($pp -and $pp.MaxDurability -ge 0 -and $pp.Durability -lt $pp.MaxDurability){ $hasDamagedGear = $true; break }
                            }
                        }
                        if($dutchAllowed -and $roll -lt 15){
                            $script:EncounterTiles[$tileKey] = $true
                            Start-RandomEncounter -Type "Dutchman"
                        } elseif($hasDamagedGear -and $roll -ge 15 -and $roll -lt 20 -and $tileFreshForEncounter){
                            # 0.5% (5 in 1000) chance for free repair encounter — rare gift
                            $script:EncounterTiles[$tileKey] = $true
                            Start-RandomEncounter -Type "RepairSmith"
                        } elseif($roll -lt 15 -and $script:EncountersThisDungeon -lt 2 -and $tileFreshForEncounter){
                            $script:EncountersThisDungeon++
                            $script:EncounterTiles[$tileKey] = $true
                            Start-RandomEncounter
                        }
                    }

                } else {
                    $script:StatusMsg = "You bump into a wall."
                }
            }
            "S" {
                $fwd = Get-Forward $d.PDir 1
                $nx = $d.PX - $fwd[0]
                $ny = $d.PY - $fwd[1]
                if($nx -ge 0 -and $nx -lt $d.W -and $ny -ge 0 -and $ny -lt $d.H -and $d.Grid[$ny,$nx] -ne 1){
                    $d.PX = $nx; $d.PY = $ny
                    # Backward step: rarer (~0.8%), still cap-limited and tile-tracked
                    $tileKey = "$nx,$ny"
                    $tileFreshForEncounter = -not $script:EncounterTiles.ContainsKey($tileKey)
                    $roll = Get-Random -Minimum 0 -Maximum 1000
                    $dutchAllowed = (
                        $script:DailyDungeonActive -and
                        $script:PlayerLevel -ge 15 -and
                        -not $script:OwnsDutchmanBlade
                    )
                    if($dutchAllowed -and $roll -lt 10){
                        $script:EncounterTiles[$tileKey] = $true
                        Start-RandomEncounter -Type "Dutchman"
                    } elseif($roll -lt 8 -and $script:EncountersThisDungeon -lt 2 -and $tileFreshForEncounter){
                        $script:EncountersThisDungeon++
                        $script:EncounterTiles[$tileKey] = $true
                        Start-RandomEncounter
                    }
                }
            }
            "A" { $d.PDir = ($d.PDir + 3) % 4 }
            "D" { $d.PDir = ($d.PDir + 1) % 4 }
            "P" {
                $healPotions = @($script:Potions | Where-Object { $_.Type -eq "Heal" -or $_.Type -eq "Mana" })
                if($healPotions.Count -eq 0){
                    $script:StatusMsg = "No healing or mana potions!"
                } else {
                    $p = $script:Player
                    if($p.HP -eq $p.MaxHP -and $p.MP -eq $p.MaxMP){
                        $script:StatusMsg = "HP and MP already full!"
                    } else {
                        clr
                        Write-CL "" "White"
                        Write-CL "  ╔════════════════════════════════════════════════════╗" "DarkGreen"
                        Write-CL "  ║              U S E   P O T I O N                    ║" "Green"
                        Write-CL "  ╚════════════════════════════════════════════════════╝" "DarkGreen"
                        Write-Host ""
                        Write-C "  HP: $($p.HP)/$($p.MaxHP)" "Green"
                        Write-CL "    MP: $($p.MP)/$($p.MaxMP)" "Cyan"
                        Write-Host ""

                        for($pi=0;$pi -lt $healPotions.Count;$pi++){
                            $pot = $healPotions[$pi]
                            $potColor = if($pot.Type -eq "Heal"){"Green"}else{"Cyan"}
                            Write-CL "  [$($pi+1)] $($pot.Name) - $($pot.Desc)" $potColor
                        }
                        Write-CL "  [0] Cancel" "DarkGray"
                        Write-Host ""
                        Write-C "  > " "Yellow"; $pc = Read-Host
                        $pidx = (ConvertTo-SafeInt -Value $pc) - 1

                        if($pidx -ge 0 -and $pidx -lt $healPotions.Count){
                            $pot = $healPotions[$pidx]
                            switch($pot.Type){
                                "Heal" {
                                    if($p.HP -eq $p.MaxHP){
                                        $script:StatusMsg = "HP already full!"
                                    } else {
                                        $healed = [math]::Min($pot.Power, $p.MaxHP - $p.HP)
                                        $p.HP += $healed
                                        $script:StatusMsg = "Used $($pot.Name)! Restored $healed HP! ($($p.HP)/$($p.MaxHP))"
                                        $script:Potions.Remove($pot)
                                    }
                                }
                                "Mana" {
                                    if($p.MP -eq $p.MaxMP){
                                        $script:StatusMsg = "MP already full!"
                                    } else {
                                        $restored = [math]::Min($pot.Power, $p.MaxMP - $p.MP)
                                        $p.MP += $restored
                                        $script:StatusMsg = "Used $($pot.Name)! Restored $restored MP! ($($p.MP)/$($p.MaxMP))"
                                        $script:Potions.Remove($pot)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            "I" {
                # Open inventory mid-dungeon. Useful for using Repair Kits or
                # dropping items when over-encumbered.
                Show-InventoryScreen
            }

            "J" {
                # Quick quest log view — see all active quests and progress
                # without leaving the dungeon.
                Show-QuestLog
            }

            "Q" {
                Write-C "  Abandon dungeon? (y/n): " "Red"
                $confirm = Read-Host
                if($confirm -eq 'y'){
                    clr
                    Write-CL "" "Red"
                    Write-CL "  ╔════════════════════════════════════════════════════╗" "DarkRed"
                    Write-CL "  ║                                                    ║" "DarkRed"
                    Write-CL "  ║       You fumble in fear as you flee the            ║" "Red"
                    Write-CL "  ║       dungeon, dropping loot behind you...          ║" "Red"
                    Write-CL "  ║                                                    ║" "DarkRed"
                    Write-CL "  ╚════════════════════════════════════════════════════╝" "DarkRed"
                    Write-Host ""

                    if($script:Inventory.Count -gt 0){
                        $lossPct = (Get-Random -Min 15 -Max 51) / 100.0
                        $loseCount = [math]::Max([math]::Ceiling($script:Inventory.Count * $lossPct), 1)

                        # Shuffle and remove random items
                        $lostItems = [System.Collections.ArrayList]@()
                        for($li=0;$li -lt $loseCount;$li++){
                            if($script:Inventory.Count -eq 0){ break }
                            $removeIdx = Get-Random -Min 0 -Max $script:Inventory.Count
                            $lostItem = $script:Inventory[$removeIdx]
                            [void]$lostItems.Add($lostItem)
                            $script:Inventory.RemoveAt($removeIdx)
                        }

                        $lostValue = 0
                        Write-CL "  Lost items:" "DarkRed"
                        foreach($lost in $lostItems){
                            Write-CL "    - $($lost.Name) ($($lost.Value)g)" "Red"
                            $lostValue += $lost.Value
                        }
                        Write-Host ""
                        $pctDisplay = [math]::Floor($lossPct * 100)
                        Write-CL "  You lost $($lostItems.Count) item(s) worth ${lostValue}g! (${pctDisplay}% of your loot)" "DarkRed"
                    } else {
                        Write-CL "  You had nothing to lose... but your dignity." "DarkGray"
                    }

                    # Also lose a small percentage of gold
                    $goldLossPct = (Get-Random -Min 5 -Max 16) / 100.0
                    $goldLost = [math]::Floor($script:Gold * $goldLossPct)
                    if($goldLost -gt 0){
                        $script:Gold -= $goldLost
                        Write-CL "  Dropped ${goldLost}g in your panic!" "DarkYellow"
                    }

                    Write-Host ""
                    Write-CL "  Remaining Gold: $($script:Gold)g" "Yellow"
                    Write-CL "  Remaining Loot: $($script:Inventory.Count) item(s)" "DarkGray"
                    Write-Host ""
                    Wait-Key
                    $inDungeon = $false
                    $script:DungeonLevel--
                }
            

            }
        }
    }

        if($script:Player.HP -le 0){
        clr
        Write-CL "" "Red"
        Write-CL "  ╔══════════════════════════════════════════════════════╗" "DarkRed"
        Write-CL "  ║                                                      ║" "DarkRed"
        Write-CL "  ║             Y O U   H A V E   D I E D                ║" "Red"
        Write-CL "  ║                                                      ║" "DarkRed"
        Write-CL "  ╚══════════════════════════════════════════════════════╝" "DarkRed"
        Write-Host ""
        Write-CL "          _______________" "DarkGray"
        Write-CL "         /               \" "DarkGray"
        Write-CL "        |  R.I.P.         |" "DarkGray"
        Write-CL "        |                 |" "DarkGray"
        Write-CL "        |  $($script:Player.Name.PadRight(16))|" "DarkGray"
        Write-CL "        |  Level $($script:PlayerLevel.ToString().PadRight(10))|" "DarkGray"
        Write-CL "        |                 |" "DarkGray"
        Write-CL "        |  Fell in the    |" "DarkGray"
        Write-CL "        |  depths...      |" "DarkGray"
        Write-CL "        |_________________|" "DarkGray"
        Write-CL "        /                 \" "DarkGray"
        Write-CL "       /___________________\" "DarkGray"
        Write-Host ""
        Write-CL "  ── Final Stats ──" "DarkYellow"
        Write-CL "  Dungeon Level Reached: $($script:DungeonLevel)" "DarkGray"
        Write-CL "  Player Level: $($script:PlayerLevel)" "DarkGray"
        Write-CL "  Gold: $($script:Gold)" "DarkGray"
        Write-CL "  Enemies Slain: Many." "DarkGray"
        Write-Host ""
        Write-CL "  ┌─────────────────────────────────────┐" "DarkGray"
        Write-CL "  │                                     │" "DarkGray"
        Write-C  "  │  " "DarkGray"; Write-C "[1]" "Green"; Write-CL " Play Again (New Character)    │" "White"
        Write-C  "  │  " "DarkGray"; Write-C "[2]" "Yellow"; Write-CL " Play Again (Same Character)   │" "White"
        Write-C  "  │  " "DarkGray"; Write-C "[3]" "Red"; Write-CL " Quit Game                     │" "White"
        Write-CL "  │                                     │" "DarkGray"
        Write-CL "  └─────────────────────────────────────┘" "DarkGray"
        Write-Host ""
        Write-C "  > " "Yellow"
        $deathChoice = Read-Host

        switch($deathChoice){
            "1" {
                # Full restart with new character
                Show-CharacterSelect
                # Reset dungeon level
                $script:DungeonLevel = 0
            }
            "2" {
                $script:Player.HP = $script:Player.MaxHP
                $script:Player.MP = $script:Player.MaxMP
                $script:Gold = 50
                $script:Inventory.Clear()
                $script:Potions.Clear()
                $script:ThrowablePotions.Clear()
                [void]$script:Potions.Add(@{Name="Small Health Potion";Type="Heal";Power=30;Price=25;Desc="Restore 30 HP"})
                $script:DungeonLevel = [math]::Max($script:DungeonLevel - 1, 0)
                $script:EquippedWeapon = $null
                $script:EquippedArmor = @{Helmet=$null;Chest=$null;Shield=$null;Amulet=$null;Boots=$null}
                $script:KillCount = 0
                $script:HasBossKey = $false
                $script:BossDefeated = $false
                Write-Host ""
                Write-CL "  You awaken at the town square, battered but alive..." "Yellow"
                Write-CL "  Your gold and items are gone, but your experience remains." "DarkGray"
                Write-CL "  Level: $($script:PlayerLevel)  |  Starting Gold: 50g" "DarkGray"
                Wait-Key
            }

            "3" {
                clr
                Write-CL "" "White"
                Write-CL "  Thanks for playing DEPTHS OF POWERSHELL!" "Yellow"
                Write-CL "  Final Stats: Level $($script:PlayerLevel) $($script:Player.Name)" "Gray"
                Write-Host ""
                $script:GameRunning = $false
                return
            }
            default {
                Show-CharacterSelect
                $script:DungeonLevel = 0
            }
        }
    }
}



# ─── CHARACTER CREATION ──────────────────────────────────────────
function Show-CharacterSelect {
    $classes = Get-ClassTemplates
    $classOrder = @("Knight","Mage","Brawler","Ranger","Cleric","Necromancer","Berserker","Warlock")
    clr
    Write-CL "" "White"
    Write-CL "  ╔══════════════════════════════════════════════════════════════════════════╗" "DarkCyan"
    Write-CL "  ║                 D E P T H S   O F   P O W E R S H E L L                  ║" "Cyan"
    Write-CL "  ║                         Choose Your Class                                ║" "DarkCyan"
    Write-CL "  ╚══════════════════════════════════════════════════════════════════════════╝" "DarkCyan"
    Write-Host ""

    # Arrange in a 3-row x 2-column grid:
    #   [1] Knight     [2] Mage
    #   [3] Brawler    [4] Ranger
    #   [5] Cleric     [6] Necromancer
    # (The requested "1 3 / 2 4" reads as columns, but in 2-wide layout
    #  odd indices go on the left, evens on the right, which is equivalent.)

    $colorMap = @{
        Knight      = "Yellow"
        Mage        = "Cyan"
        Brawler     = "Red"
        Ranger      = "Green"
        Cleric      = "White"
        Necromancer = "Magenta"
        Berserker   = "DarkRed"
        Warlock     = "DarkMagenta"
    }

    # Render each row as a two-up card (interior width 50 to fit full descriptions)
    $cardW = 50
    $bar   = "═" * $cardW

    for($row=0; $row -lt 4; $row++){
        $leftIdx  = $row * 2
        $rightIdx = $row * 2 + 1
        if($leftIdx -ge $classOrder.Count){ break }

        $lKey = $classOrder[$leftIdx]
        $rKey = if($rightIdx -lt $classOrder.Count){$classOrder[$rightIdx]}else{$null}
        $lC   = $classes[$lKey]
        $rC   = if($rKey){$classes[$rKey]}else{$null}
        $lCol = $colorMap[$lKey]
        $rCol = if($rKey){$colorMap[$rKey]}else{"Gray"}

        # Top border
        Write-C "  ╔$bar╗" "DarkGray"
        if($rC){ Write-CL "  ╔$bar╗" "DarkGray" } else { Write-Host "" }

        # Class title line
        $lTitle = "[$($leftIdx+1)] $($lC.Name)"
        Write-C "  ║ " "DarkGray"
        Write-C $lTitle $lCol
        $lPad = ($cardW - 1) - $lTitle.Length
        if($lPad -lt 0){$lPad=0}
        Write-C ("$(' ' * $lPad)║  ") "DarkGray"

        if($rC){
            $rTitle = "[$($rightIdx+1)] $($rC.Name)"
            Write-C "║ " "DarkGray"
            Write-C $rTitle $rCol
            $rPad = ($cardW - 1) - $rTitle.Length
            if($rPad -lt 0){$rPad=0}
            Write-CL ("$(' ' * $rPad)║") "DarkGray"
        } else {
            Write-Host ""
        }

        # Description line (no truncation — cards are wide enough)
        $lDesc = $lC.Desc
        Write-C "  ║ " "DarkGray"
        Write-C $lDesc "Gray"
        $lPad2 = ($cardW - 1) - $lDesc.Length
        if($lPad2 -lt 0){$lPad2=0}
        Write-C ("$(' ' * $lPad2)║  ") "DarkGray"

        if($rC){
            $rDesc = $rC.Desc
            Write-C "║ " "DarkGray"
            Write-C $rDesc "Gray"
            $rPad2 = ($cardW - 1) - $rDesc.Length
            if($rPad2 -lt 0){$rPad2=0}
            Write-CL ("$(' ' * $rPad2)║") "DarkGray"
        } else {
            Write-Host ""
        }

        # Stats line
        $lStats = "HP$($lC.MaxHP) MP$($lC.MaxMP) ATK$($lC.ATK) DEF$($lC.DEF) SPD$($lC.SPD) MAG$($lC.MAG)"
        Write-C "  ║ " "DarkGray"
        Write-C $lStats "DarkCyan"
        $lPad3 = ($cardW - 1) - $lStats.Length
        if($lPad3 -lt 0){$lPad3=0}
        Write-C ("$(' ' * $lPad3)║  ") "DarkGray"

        if($rC){
            $rStats = "HP$($rC.MaxHP) MP$($rC.MaxMP) ATK$($rC.ATK) DEF$($rC.DEF) SPD$($rC.SPD) MAG$($rC.MAG)"
            Write-C "║ " "DarkGray"
            Write-C $rStats "DarkCyan"
            $rPad3 = ($cardW - 1) - $rStats.Length
            if($rPad3 -lt 0){$rPad3=0}
            Write-CL ("$(' ' * $rPad3)║") "DarkGray"
        } else {
            Write-Host ""
        }

        # Affinity line
        $lAff = "Affinity: $($lC.Affinity)"
        Write-C "  ║ " "DarkGray"
        Write-C $lAff "DarkYellow"
        $lPad4 = ($cardW - 1) - $lAff.Length
        if($lPad4 -lt 0){$lPad4=0}
        Write-C ("$(' ' * $lPad4)║  ") "DarkGray"

        if($rC){
            $rAff = "Affinity: $($rC.Affinity)"
            Write-C "║ " "DarkGray"
            Write-C $rAff "DarkYellow"
            $rPad4 = ($cardW - 1) - $rAff.Length
            if($rPad4 -lt 0){$rPad4=0}
            Write-CL ("$(' ' * $rPad4)║") "DarkGray"
        } else {
            Write-Host ""
        }

        # Bottom border
        Write-C "  ╚$bar╝" "DarkGray"
        if($rC){ Write-CL "  ╚$bar╝" "DarkGray" } else { Write-Host "" }
    }

    Write-Host ""
    Write-CL "  TIP: Weapons matching your class grant bonus ATK." "DarkGray"
    Write-Host ""

    Write-C "  > " "Yellow"; $pick = Read-Host
    $pickIdx = (ConvertTo-SafeInt -Value $pick) - 1
    if($pickIdx -lt 0 -or $pickIdx -ge $classOrder.Count){ $pickIdx = 0 }
    $className = $classOrder[$pickIdx]
    $template = $classes[$className]

    $script:PlayerClass = $className
    $script:Player = @{
        Name      = $template.Name
        HP        = $template.HP
        MaxHP     = $template.MaxHP
        MP        = $template.MP
        MaxMP     = $template.MaxMP
        ATK       = $template.ATK
        DEF       = $template.DEF
        SPD       = $template.SPD
        MAG       = $template.MAG
        Abilities = $template.Abilities
    }
    $script:EquippedWeapon = $null
    $script:EquippedArmor = @{
        Helmet = $null
        Chest  = $null
        Shield = $null
        Amulet = $null
        Boots  = $null
    }
    $script:Gold = 50
    $script:Inventory.Clear()
    $script:Potions.Clear()
    $script:ThrowablePotions.Clear()
    [void]$script:Potions.Add(@{Name="Small Health Potion";Type="Heal";Power=30;Price=25;Desc="Restore 30 HP"})
    $script:DungeonLevel = 0
    $script:PlayerLevel = 1
    $script:XP = 0
    $script:XPToNext = 100
    $script:KillCount = 0
    $script:Partner = $null
    $script:Quests.Clear()
    $script:TrainingPoints = @{ ATK=0; DEF=0; SPD=0; MAG=0; HP=0; MP=0 }
    $script:Streak = 0
    $script:BestStreak = 0
    $script:Achievements = @{}
    $script:TotalKills = 0
    $script:BossesDefeated = 0
    $script:WeaponsOwned = @{}
    $script:ArmorOwned = @{}
    $script:OwnsDutchmanBlade = $false
    $script:CompletedQuests = 0
    $script:DailyDungeonActive = $false
    $script:Lockpicks = 5
    $script:RepairKits = 0
    $script:ExtraStrongPotions = 0
    $script:DisturbedChests = @{}
    $script:LuckTurnsLeft = 0; $script:LuckBonus = 0
    $script:Stance = "Balanced"
    # New v1.3 lifetime stat counters
    $script:TotalCrits = 0
    $script:TotalLocksPicked = 0
    $script:TotalBareKills = 0
    $script:TotalUntouched = 0
    $script:TotalStanceSwaps = 0
    $script:TotalRepairs = 0

    Write-Host ""
    Write-CL "  You are a $className. Your journey begins..." "Green"
    Wait-Key
}


function Get-ClassTemplates {
    @{
        Knight = @{
            Name="Knight"; MaxHP=120; HP=120; MaxMP=30; MP=30
            ATK=14; DEF=12; SPD=8; MAG=4
            Abilities=@(
                @{Name="Shield Bash"; Cost=8;  Type="Physical"; Power=18; Effect="Stun";  Cooldown=3}
                @{Name="Holy Strike"; Cost=12; Type="Physical"; Power=28; Effect="None";  Cooldown=2}
                @{Name="Fortify";     Cost=10; Type="Buff";     Power=0;  Effect="DEF+5"; Cooldown=4}
            )
            Desc="High defense, strong melee attacks, sturdy."
            Affinity="Sword"
        }
        Mage = @{
            Name="Mage"; MaxHP=75; HP=75; MaxMP=80; MP=80
            ATK=6; DEF=5; SPD=10; MAG=18
            Abilities=@(
                @{Name="Fireball";      Cost=15; Type="Magic"; Power=30; Effect="Burn";  Cooldown=2}
                @{Name="Ice Shard";     Cost=12; Type="Magic"; Power=22; Effect="Slow";  Cooldown=3}
                @{Name="Arcane Shield"; Cost=20; Type="Buff";  Power=0;  Effect="DEF+8"; Cooldown=4}
            )
            Desc="Devastating magic, large MP pool, fragile."
            Affinity="Staff"
        }
        Brawler = @{
            Name="Brawler"; MaxHP=100; HP=100; MaxMP=40; MP=40
            ATK=16; DEF=8; SPD=12; MAG=3
            Abilities=@(
                @{Name="Fury Punch"; Cost=10; Type="Physical"; Power=24; Effect="None";  Cooldown=2}
                @{Name="Whirlwind";  Cost=15; Type="Physical"; Power=20; Effect="Bleed"; Cooldown=2}
                @{Name="Battle Cry"; Cost=12; Type="Buff";     Power=0;  Effect="ATK+5"; Cooldown=4}
            )
            Desc="Fast and aggressive, high attack, less durable."
            Affinity="Fist"
        }
        Ranger = @{
            Name="Ranger"; MaxHP=90; HP=90; MaxMP=50; MP=50
            ATK=12; DEF=7; SPD=15; MAG=6
            Abilities=@(
                @{Name="Quick Shot";   Cost=8;  Type="Physical"; Power=20; Effect="None";   Cooldown=2}
                @{Name="Poison Arrow"; Cost=14; Type="Physical"; Power=18; Effect="Poison"; Cooldown=3}
                @{Name="Shadow Step";  Cost=10; Type="Buff";     Power=0;  Effect="DEF+4";  Cooldown=4}
            )
            Desc="Fast and precise, high speed, evasive fighter."
            Affinity="Bow"
        }
        Cleric = @{
            Name="Cleric"; MaxHP=95; HP=95; MaxMP=70; MP=70
            ATK=8; DEF=10; SPD=7; MAG=14
            Abilities=@(
                @{Name="Smite";       Cost=12; Type="Magic"; Power=24; Effect="None";  Cooldown=2}
                @{Name="Holy Heal";   Cost=18; Type="Heal";  Power=40; Effect="None";  Cooldown=3}
                @{Name="Divine Ward"; Cost=15; Type="Buff";  Power=0;  Effect="DEF+7"; Cooldown=4}
            )
            Desc="Holy support, self-heals, solid defense."
            Affinity="Mace"
        }
        Necromancer = @{
            Name="Necromancer"; MaxHP=70; HP=70; MaxMP=75; MP=75
            ATK=7; DEF=4; SPD=9; MAG=20
            Abilities=@(
                @{Name="Soul Drain"; Cost=14; Type="Magic";     Power=26; Effect="Drain";       Cooldown=2}
                @{Name="Curse";      Cost=16; Type="Magic";     Power=20; Effect="Weaken";      Cooldown=3}
                @{Name="Dark Pact";  Cost=0;  Type="Sacrifice"; Power=35; Effect="SacrificeHP"; Cooldown=5}
            )
            Desc="Dark magic master, drains life, deadly."
            Affinity="Scythe"
        }
        Berserker = @{
            Name="Berserker"; MaxHP=115; HP=115; MaxMP=25; MP=25
            ATK=17; DEF=8; SPD=11; MAG=3
            Abilities=@(
                @{Name="Blood Rage";   Cost=6;  Type="Buff";     Power=0;  Effect="ATK8";        Cooldown=4}
                @{Name="Cleave";       Cost=10; Type="Physical"; Power=22; Effect="Bleed";       Cooldown=2}
                @{Name="War Cry";      Cost=8;  Type="Physical"; Power=8;  Effect="Stun";        Cooldown=3}
                @{Name="Undying Fury"; Cost=0;  Type="Sacrifice";Power=40; Effect="SacrificeHP"; Cooldown=5}
            )
            Desc="Frenzied melee; trades defense for aggression."
            Affinity="Sword"
        }
        Warlock = @{
            Name="Warlock"; MaxHP=72; HP=72; MaxMP=80; MP=80
            ATK=6; DEF=4; SPD=8; MAG=21
            Abilities=@(
                @{Name="Eldritch Blast"; Cost=10; Type="Magic";     Power=24; Effect="None";        Cooldown=2}
                @{Name="Hex";            Cost=12; Type="Magic";     Power=15; Effect="Weaken";      Cooldown=3}
                @{Name="Summon Imp";     Cost=18; Type="Magic";     Power=20; Effect="Burn";        Cooldown=3}
                @{Name="Dark Bargain";   Cost=0;  Type="Sacrifice"; Power=38; Effect="SacrificeHP"; Cooldown=5}
            )
            Desc="Cursed caster bound by a fiendish pact."
            Affinity="Staff"
        }
    }
}

# ─── QUEST SYSTEM ─────────────────────────────────────────────────
function Get-RandomQuests {
    param([int]$DungeonLvl)
    $templates = @(
        @{Type="Kill";       DescTemplate="Slay {0} enemies in the dungeon";   TMin=3; TMax=7}
        @{Type="Kill";       DescTemplate="Defeat {0} foes to prove your worth"; TMin=5; TMax=10}
        @{Type="MiniBoss";   DescTemplate="Defeat the dungeon mini-boss";      TMin=1; TMax=1}
        @{Type="Boss";       DescTemplate="Defeat the dungeon boss";           TMin=1; TMax=1}
        @{Type="Rescue";     DescTemplate="Rescue the lost adventurer";        TMin=1; TMax=1}
        @{Type="Treasure";   DescTemplate="Open {0} treasure chests";          TMin=2; TMax=5}
        # New quest types added in v1.3:
        @{Type="Crit";       DescTemplate="Land {0} critical hits in combat";  TMin=3; TMax=8}
        @{Type="Lockpicker"; DescTemplate="Successfully pick {0} locks";       TMin=2; TMax=5}
        @{Type="LootHunter"; DescTemplate="Collect {0} loot items";            TMin=4; TMax=10}
        @{Type="Survivor";   DescTemplate="Reach the boss room above 50% HP";  TMin=1; TMax=1}
        @{Type="BareHands";  DescTemplate="Defeat {0} enemies bare-handed";    TMin=2; TMax=4}
        @{Type="Repair";     DescTemplate="Repair gear at the blacksmith {0} times"; TMin=1; TMax=3}
    )
    $picked = $templates | Get-Random -Count 5
    $result = [System.Collections.ArrayList]@()
    foreach($t in $picked){
        $count = Get-Random -Min $t.TMin -Max ($t.TMax + 1)
        $desc = if($t.DescTemplate -match '\{0\}'){$t.DescTemplate -f $count}else{$t.DescTemplate}
        $goldReward = switch($t.Type){
            "Kill"       { 40 + $DungeonLvl * 20 + $count * 5 }
            "MiniBoss"   { 80 + $DungeonLvl * 30 }
            "Boss"       { 150 + $DungeonLvl * 40 }
            "Rescue"     { 60 + $DungeonLvl * 25 }
            "Treasure"   { 50 + $DungeonLvl * 15 + $count * 5 }
            "Crit"       { 60 + $DungeonLvl * 20 + $count * 8 }
            "Lockpicker" { 70 + $DungeonLvl * 20 + $count * 10 }
            "LootHunter" { 40 + $DungeonLvl * 15 + $count * 6 }
            "Survivor"   { 90 + $DungeonLvl * 30 }
            "BareHands"  { 100 + $DungeonLvl * 35 + $count * 12 }
            "Repair"     { 50 + $DungeonLvl * 15 + $count * 10 }
            default      { 50 + $DungeonLvl * 20 }
        }
        $xpReward = switch($t.Type){
            "Kill"       { 30 + $DungeonLvl * 15 + $count * 5 }
            "MiniBoss"   { 60 + $DungeonLvl * 25 }
            "Boss"       { 100 + $DungeonLvl * 30 }
            "Rescue"     { 40 + $DungeonLvl * 20 }
            "Treasure"   { 25 + $DungeonLvl * 15 }
            "Crit"       { 35 + $DungeonLvl * 15 + $count * 4 }
            "Lockpicker" { 40 + $DungeonLvl * 15 + $count * 6 }
            "LootHunter" { 25 + $DungeonLvl * 12 + $count * 4 }
            "Survivor"   { 70 + $DungeonLvl * 25 }
            "BareHands"  { 80 + $DungeonLvl * 30 + $count * 10 }
            "Repair"     { 30 + $DungeonLvl * 12 + $count * 8 }
            default      { 30 + $DungeonLvl * 15 }
        }
        [void]$result.Add(@{
            Type=$t.Type; Desc=$desc; TargetCount=$count
            Progress=0; RewardGold=$goldReward; RewardXP=$xpReward
            Complete=$false; TurnedIn=$false
        })
    }
    return $result
}

function Update-QuestProgress {
    param([string]$Type, [int]$Amount = 1)
    foreach($q in $script:Quests){
        if($q.Type -eq $Type -and -not $q.Complete -and -not $q.TurnedIn){
            $q.Progress = [math]::Min($q.Progress + $Amount, $q.TargetCount)
            if($q.Progress -ge $q.TargetCount){
                $q.Complete = $true
                $script:StatusMsg = "Quest complete: $($q.Desc)!"
            }
        }
    }
}

function Show-QuestBoard {
    $qbLoop = $true
    # Generate available quests if none exist yet
if(-not $script:AvailableQuests -or $script:AvailableQuests.Count -eq 0){
    $script:AvailableQuests = [System.Collections.ArrayList]@(Get-RandomQuests ($script:DungeonLevel + 1))
}

    while($qbLoop){
        clr
        Write-Host ""
        # 60-char banner
        Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkYellow"
        Write-CL "  ║                   Q U E S T   B O A R D                  ║" "Yellow"
        Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkYellow"
        Write-Host ""
        # Notice board art
        Write-CL "          ___________________________          " "DarkGray"
        Write-CL "         |    |            |    |    |         " "DarkGray"
        Write-CL "         |HELP| ADVENTURER |GOLD|FAME|         " "DarkYellow"
        Write-CL "         | !  |  WANTED!!  | `$`$ | ** |         " "Yellow"
        Write-CL "         |____|____________|____|____|         " "DarkGray"
        Write-CL "         |         QUEST              |         " "DarkGray"
        Write-CL "         |         BOARD              |         " "DarkYellow"
        Write-CL "         |____________________________|         " "DarkGray"
        Write-Host ""

        # ── Active Quests (60 wide / 56 interior) ──
        $bar = "═" * 56
        Write-CL "  ╔$bar╗" "DarkCyan"
        Write-C "  ║ " "DarkCyan"; Write-C "A C T I V E   Q U E S T S" "Cyan"
        $aHdr = "A C T I V E   Q U E S T S"
        $aPad = 55 - $aHdr.Length
        Write-CL ("$(' ' * $aPad)║") "DarkCyan"
        Write-CL "  ╠$bar╣" "DarkCyan"
        if($script:Quests.Count -eq 0){
            $msg = " No active quests. Accept one below!"
            $msgPad = 55 - $msg.Length
            Write-C "  ║" "DarkCyan"; Write-C $msg "DarkGray"
            Write-CL ("$(' ' * $msgPad)║") "DarkCyan"
        } else {
            for($i=0;$i -lt $script:Quests.Count;$i++){
                $q = $script:Quests[$i]
                $statusIcon = if($q.TurnedIn){"[DONE]"}elseif($q.Complete){"[READY]"}else{"[$($q.Progress)/$($q.TargetCount)]"}
                $statusColor = if($q.TurnedIn){"DarkGray"}elseif($q.Complete){"Green"}else{"Yellow"}
                $desc = $q.Desc
                # Truncate at 44 chars with ellipsis to leave room for status + padding
                $maxDesc = 44
                if($desc.Length -gt $maxDesc){ $desc = $desc.Substring(0, $maxDesc - 3) + "..." }
                $fullLine = " $statusIcon $desc"
                $qPad = 55 - $fullLine.Length
                if($qPad -lt 0){$qPad = 0}
                Write-C "  ║" "DarkCyan"
                Write-C " $statusIcon" $statusColor
                Write-C " $desc" "White"
                Write-CL ("$(' ' * $qPad)║") "DarkCyan"
            }
        }
        Write-CL "  ╚$bar╝" "DarkCyan"
        Write-Host ""

        # ── Available Quests (same 60/56 width) ──
        Write-CL "  ╔$bar╗" "DarkGreen"
        Write-C "  ║ " "DarkGreen"; Write-C "A V A I L A B L E" "Green"
        $vHdr = "A V A I L A B L E"
        $vPad = 55 - $vHdr.Length
        Write-CL ("$(' ' * $vPad)║") "DarkGreen"
        Write-CL "  ╠$bar╣" "DarkGreen"
        $avail = @($script:AvailableQuests | Where-Object { -not $_.TurnedIn })
        if($avail.Count -eq 0){
            $m1 = " No quests available. Enter a dungeon and"
            $m2 = " come back later!"
            Write-C "  ║" "DarkGreen"; Write-C $m1 "DarkGray"
            Write-CL ("$(' ' * (55 - $m1.Length))║") "DarkGreen"
            Write-C "  ║" "DarkGreen"; Write-C $m2 "DarkGray"
            Write-CL ("$(' ' * (55 - $m2.Length))║") "DarkGreen"
        } else {
            for($i=0;$i -lt $avail.Count;$i++){
                $q = $avail[$i]
                $desc = $q.Desc
                $maxD = 48
                if($desc.Length -gt $maxD){ $desc = $desc.Substring(0, $maxD - 3) + "..." }
                $line1 = " [$($i+1)] $desc"
                $p1 = 55 - $line1.Length
                if($p1 -lt 0){$p1 = 0}
                Write-C "  ║" "DarkGreen"
                Write-C " [$($i+1)] " "White"
                Write-C $desc "Green"
                Write-CL ("$(' ' * $p1)║") "DarkGreen"

                $line2 = "     Reward: $($q.RewardGold)g + $($q.RewardXP) XP"
                $p2 = 55 - $line2.Length
                if($p2 -lt 0){$p2 = 0}
                Write-C "  ║" "DarkGreen"
                Write-C $line2 "Yellow"
                Write-CL ("$(' ' * $p2)║") "DarkGreen"
            }
        }
        Write-CL "  ╚$bar╝" "DarkGreen"
        Write-Host ""

        # ── Options menu (interior 44) ──
        $obar = "─" * 44
        Write-CL "  ┌$obar┐" "DarkGray"
        $optRows = @(
            @{N="[A]"; C="Green";   L="Accept a quest"}
            @{N="[T]"; C="Yellow";  L="Turn in all completed"}
            @{N="[R]"; C="DarkCyan";L="Refresh available quests (free)"}
            @{N="[0]"; C="White";   L="Back"}
        )
        foreach($o in $optRows){
            $full = " $($o.N) $($o.L)"
            $pp = 42 - $full.Length
            if($pp -lt 0){$pp = 0}
            Write-C "  │" "DarkGray"
            Write-C " $($o.N)" $o.C
            Write-C " $($o.L)" "White"
            Write-CL ("$(' ' * $pp) │") "DarkGray"
        }
        Write-CL "  └$obar┘" "DarkGray"
        Write-Host ""
        Write-C "  > " "Yellow"; $qCh = Read-Host

        switch($qCh.ToUpper()){
            "A" {
                if($script:Quests.Count -ge 5){
                    Write-CL "  You can only hold 5 quests at a time!" "Red"
                    Wait-Key
                } elseif($avail.Count -eq 0){
                    Write-CL "  No quests to accept!" "Red"
                    Wait-Key
                } else {
                    Write-C "  Accept quest #: " "Yellow"; $qPick = Read-Host
                    $qIdx = (ConvertTo-SafeInt -Value $qPick) - 1
                    if($qIdx -ge 0 -and $qIdx -lt $avail.Count){
                        $accepted = $avail[$qIdx]
                        [void]$script:Quests.Add($accepted)
                        $script:AvailableQuests.Remove($accepted)
                        Write-CL "  Quest accepted: $($accepted.Desc)" "Green"
                        Wait-Key
                    }
                }
            }
            "T" {
                $ready = @($script:Quests | Where-Object { $_.Complete -and -not $_.TurnedIn })
                if($ready.Count -eq 0){
                    Write-CL "  No completed quests to turn in!" "Red"
                    Read-Host "  [Press Enter to continue]" | Out-Null
                } else {
                    Write-Host ""
                    Write-CL "  ╔════════════════════════════════════════════╗" "Yellow"
                    Write-CL "  ║   TURNING IN $($ready.Count.ToString().PadRight(2)) COMPLETED QUEST(S)         ║" "Yellow"
                    Write-CL "  ╚════════════════════════════════════════════╝" "Yellow"
                    Write-Host ""

                    $totalGold = 0
                    $totalXP   = 0
                    $totalBardBonus = 0
                    $isBard = ($script:Partner -and $script:Partner.Class -eq "Bard")

                    foreach($rq in $ready){
                        $rq.TurnedIn = $true
                        $script:CompletedQuests++
                        $totalGold += $rq.RewardGold
                        $thisXP = $rq.RewardXP
                        if($isBard){
                            $bonus = [math]::Floor($rq.RewardXP * 0.25)
                            $totalBardBonus += $bonus
                            $thisXP += $bonus
                        }
                        $totalXP += $thisXP
                        Write-CL "  ✓ $($rq.Desc)" "Green"
                        Write-CL "    + $($rq.RewardGold)g, + $thisXP XP" "DarkGray"
                        $script:Quests.Remove($rq) | Out-Null
                    }

                    if($script:CompletedQuests -ge 10){
                        Try-UnlockAchievement "QuestGiver"
                    }

                    $script:Gold += $totalGold
                    $script:XP   += $totalXP

                    Write-Host ""
                    Write-CL "  ──────────────────────────────────────────" "DarkGray"
                    Write-CL "  TOTAL: + $totalGold Gold, + $totalXP XP" "Yellow"
                    if($isBard -and $totalBardBonus -gt 0){
                        Write-CL "    ($($script:Partner.Name): +$totalBardBonus bonus XP)" "DarkCyan"
                    }

                    # Level-up check (may cascade across multiple levels)
                    $p = $script:Player
                    while($script:XP -ge $script:XPToNext){
                        $script:XP -= $script:XPToNext
                        $script:PlayerLevel++
                        $script:XPToNext = [math]::Floor($script:XPToNext * 1.5)
                        $p.MaxHP+=10; $p.HP=$p.MaxHP; $p.MaxMP+=5; $p.MP=$p.MaxMP
                        $p.ATK+=2; $p.DEF+=2; $p.SPD+=1; $p.MAG+=2
                        Write-Host ""
                        Write-CL "  *** LEVEL UP! Now Level $($script:PlayerLevel)! ***" "Yellow"
                    }
                    Write-Host ""
                    Read-Host "  [Press Enter to continue]" | Out-Null
                }
            }
            "R" {
                $script:AvailableQuests = [System.Collections.ArrayList]@(Get-RandomQuests ($script:DungeonLevel + 1))
                Write-CL "  New quests posted!" "Green"
                Wait-Key
            }
            "0" { $qbLoop = $false }
        }
    }
}


# ─── SHOP DATA ────────────────────────────────────────────────────
function Get-WeaponShop {
    @(
        # ── SWORDS (Knight affinity) ──
        @{Name="Iron Sword";       ATK=4;  Price=60;   WeaponType="Sword";  ClassAffinity="Knight";      AffinityBonus=3; Perk="Bleed"; PerkChance=15}
        @{Name="Steel Blade";      ATK=8;  Price=150;  WeaponType="Sword";  ClassAffinity="Knight";      AffinityBonus=3; Perk="Bleed"; PerkChance=20}
        @{Name="Holy Sword";       ATK=14; Price=400;  WeaponType="Sword";  ClassAffinity="Knight";      AffinityBonus=4; Perk="Bleed"; PerkChance=25}
        @{Name="Dragon Slayer";    ATK=20; Price=800;  WeaponType="Sword";  ClassAffinity="Knight";      AffinityBonus=5; Perk="Bleed"; PerkChance=30}
        @{Name="Mythic Greatsword";ATK=28; Price=1600; WeaponType="Sword";  ClassAffinity="Knight";      AffinityBonus=7; Perk="Bleed"; PerkChance=35}
        @{Name="Sunsteel Claymore";ATK=36; Price=3200; WeaponType="Sword";  ClassAffinity="Knight";      AffinityBonus=9; Perk="Burn";  PerkChance=40}

        # ── SWORDS (Berserker affinity) — leans into bleed/drain/raw damage ──
        @{Name="Serrated Cleaver";   ATK=7;  Price=130;  WeaponType="Sword"; ClassAffinity="Berserker"; AffinityBonus=4; Perk="Bleed"; PerkChance=25}
        @{Name="Bloodthirst Blade";  ATK=13; Price=380;  WeaponType="Sword"; ClassAffinity="Berserker"; AffinityBonus=5; Perk="Drain"; PerkChance=30}
        @{Name="Warlord's Falchion"; ATK=21; Price=900;  WeaponType="Sword"; ClassAffinity="Berserker"; AffinityBonus=6; Perk="Bleed"; PerkChance=40}
        @{Name="Rageborn Greatblade";ATK=30; Price=1900; WeaponType="Sword"; ClassAffinity="Berserker"; AffinityBonus=8; Perk="Bleed"; PerkChance=50}
        @{Name="Gorefeast Reaver";   ATK=38; Price=3600; WeaponType="Sword"; ClassAffinity="Berserker"; AffinityBonus=10;Perk="Drain"; PerkChance=55}

        # ── STAVES (Mage affinity) — MAGBonus on all ──
        @{Name="Wooden Staff";     ATK=3;  Price=50;   WeaponType="Staff";  ClassAffinity="Mage";        AffinityBonus=3; Perk=$null;   PerkChance=0;  MAGBonus=3}
        @{Name="Enchanted Staff";  ATK=6;  Price=200;  WeaponType="Staff";  ClassAffinity="Mage";        AffinityBonus=4; Perk="Burn";  PerkChance=20; MAGBonus=6}
        @{Name="Arcane Staff";     ATK=10; Price=450;  WeaponType="Staff";  ClassAffinity="Mage";        AffinityBonus=5; Perk="Burn";  PerkChance=30; MAGBonus=10}
        @{Name="Archmage Rod";     ATK=16; Price=1100; WeaponType="Staff";  ClassAffinity="Mage";        AffinityBonus=6; Perk="Burn";  PerkChance=40; MAGBonus=16}
        @{Name="Voidwalker Staff"; ATK=22; Price=2400; WeaponType="Staff";  ClassAffinity="Mage";        AffinityBonus=8; Perk="Drain"; PerkChance=45; MAGBonus=22}
        @{Name="Celestial Spire";  ATK=30; Price=4500; WeaponType="Staff";  ClassAffinity="Mage";        AffinityBonus=10;Perk="Burn";  PerkChance=50; MAGBonus=30}

        # ── STAVES (Warlock affinity) — leans into curse/drain ──
        @{Name="Cursed Rod";         ATK=5;  Price=120;  WeaponType="Staff"; ClassAffinity="Warlock"; AffinityBonus=4; Perk="Drain"; PerkChance=25; MAGBonus=5}
        @{Name="Hexweaver Staff";    ATK=9;  Price=350;  WeaponType="Staff"; ClassAffinity="Warlock"; AffinityBonus=5; Perk="Drain"; PerkChance=30; MAGBonus=9}
        @{Name="Fiendbound Scepter"; ATK=15; Price=950;  WeaponType="Staff"; ClassAffinity="Warlock"; AffinityBonus=6; Perk="Drain"; PerkChance=40; MAGBonus=15}
        @{Name="Nightmare Spire";    ATK=22; Price=2100; WeaponType="Staff"; ClassAffinity="Warlock"; AffinityBonus=8; Perk="Drain"; PerkChance=45; MAGBonus=22}
        @{Name="Doompact Grimoire";  ATK=32; Price=4200; WeaponType="Staff"; ClassAffinity="Warlock"; AffinityBonus=10;Perk="Burn";  PerkChance=55; MAGBonus=32}

        # ── FISTS (Brawler affinity) ──
        @{Name="Iron Knuckles";    ATK=5;  Price=55;   WeaponType="Fist";   ClassAffinity="Brawler";     AffinityBonus=3; Perk=$null;   PerkChance=0}
        @{Name="Spiked Gauntlets"; ATK=10; Price=180;  WeaponType="Fist";   ClassAffinity="Brawler";     AffinityBonus=4; Perk="Bleed"; PerkChance=20}
        @{Name="Titan Fists";      ATK=16; Price=500;  WeaponType="Fist";   ClassAffinity="Brawler";     AffinityBonus=5; Perk=$null;   PerkChance=0}
        @{Name="Earthshaker Gloves";ATK=24;Price=1300; WeaponType="Fist";   ClassAffinity="Brawler";     AffinityBonus=7; Perk="Stun";  PerkChance=35}
        @{Name="Gods-Fury Wraps";  ATK=34; Price=3000; WeaponType="Fist";   ClassAffinity="Brawler";     AffinityBonus=9; Perk="Bleed"; PerkChance=45}

        # ── BOWS (Ranger affinity) ──
        @{Name="Short Bow";        ATK=4;  Price=55;   WeaponType="Bow";    ClassAffinity="Ranger";      AffinityBonus=3; Perk=$null;   PerkChance=0}
        @{Name="Longbow";          ATK=9;  Price=200;  WeaponType="Bow";    ClassAffinity="Ranger";      AffinityBonus=4; Perk=$null;   PerkChance=0}
        @{Name="Elven Bow";        ATK=14; Price=450;  WeaponType="Bow";    ClassAffinity="Ranger";      AffinityBonus=5; Perk="Poison";PerkChance=25}
        @{Name="Windrider Bow";    ATK=22; Price=1200; WeaponType="Bow";    ClassAffinity="Ranger";      AffinityBonus=7; Perk="Poison";PerkChance=35}
        @{Name="Thunderstrike Bow";ATK=32; Price=2800; WeaponType="Bow";    ClassAffinity="Ranger";      AffinityBonus=9; Perk="Stun";  PerkChance=30}

        # ── MACES (Cleric affinity) ──
        @{Name="Wooden Mace";      ATK=4;  Price=50;   WeaponType="Mace";   ClassAffinity="Cleric";      AffinityBonus=3; Perk=$null;   PerkChance=0}
        @{Name="Iron Mace";        ATK=8;  Price=170;  WeaponType="Mace";   ClassAffinity="Cleric";      AffinityBonus=4; Perk=$null;   PerkChance=0}
        @{Name="Holy Mace";        ATK=13; Price=420;  WeaponType="Mace";   ClassAffinity="Cleric";      AffinityBonus=5; Perk="Stun";  PerkChance=20}
        @{Name="Heavenlight Mace"; ATK=20; Price=1050; WeaponType="Mace";   ClassAffinity="Cleric";      AffinityBonus=7; Perk="Stun";  PerkChance=30}
        @{Name="Seraphim's Hammer";ATK=30; Price=2600; WeaponType="Mace";   ClassAffinity="Cleric";      AffinityBonus=9; Perk="Burn";  PerkChance=40; MAGBonus=12}

        # ── SCYTHES (Necromancer affinity) ──
        @{Name="Rusty Scythe";     ATK=5;  Price=60;   WeaponType="Scythe"; ClassAffinity="Necromancer"; AffinityBonus=3; Perk="Bleed"; PerkChance=15}
        @{Name="Shadow Scythe";    ATK=10; Price=220;  WeaponType="Scythe"; ClassAffinity="Necromancer"; AffinityBonus=4; Perk="Drain"; PerkChance=25}
        @{Name="Death's Scythe";   ATK=16; Price=550;  WeaponType="Scythe"; ClassAffinity="Necromancer"; AffinityBonus=5; Perk="Drain"; PerkChance=30}
        @{Name="Soulreaper";       ATK=24; Price=1400; WeaponType="Scythe"; ClassAffinity="Necromancer"; AffinityBonus=7; Perk="Drain"; PerkChance=40; MAGBonus=10}
        @{Name="Oblivion Harvest"; ATK=34; Price=3300; WeaponType="Scythe"; ClassAffinity="Necromancer"; AffinityBonus=9; Perk="Drain"; PerkChance=50; MAGBonus=18}

        # ── DAGGERS & OTHER ──
        @{Name="Shadow Dagger";    ATK=12; Price=350;  WeaponType="Dagger"; ClassAffinity="Ranger";      AffinityBonus=3; Perk="Bleed"; PerkChance=25}
        @{Name="War Hammer";       ATK=12; Price=300;  WeaponType="Hammer"; ClassAffinity="Brawler";     AffinityBonus=3; Perk=$null;   PerkChance=0}
        @{Name="Phoenix Edge";     ATK=25; Price=1800; WeaponType="Dagger"; ClassAffinity="Ranger";      AffinityBonus=5; Perk="Burn";  PerkChance=40}
        @{Name="Worldbreaker Maul";ATK=28; Price=2100; WeaponType="Hammer"; ClassAffinity="Brawler";     AffinityBonus=5; Perk="Stun";  PerkChance=35}
    )
}

# Returns all potions and throwables in a FIXED ORDER (index 0-9).
# Save/Load uses these indices to store which potions the player has.
# Index 0-6 = regular potions, index 7-9 = throwable potions.
function Get-PotionShop {
    @(
        @{Name="Small Health Potion"; Type="Heal";        Power=30; Price=25; Desc="Restore 30 HP";     Category="Potion"}
        @{Name="Large Health Potion"; Type="Heal";        Power=70; Price=60; Desc="Restore 70 HP";     Category="Potion"}
        @{Name="Mana Potion";         Type="Mana";        Power=30; Price=30; Desc="Restore 30 MP";     Category="Potion"}
        @{Name="Large Mana Potion";   Type="Mana";        Power=60; Price=55; Desc="Restore 60 MP";     Category="Potion"}
        @{Name="Strength Elixir";     Type="ATKBuff";     Power=8;  Price=75; Desc="ATK+8 in battle";   Category="Potion"}
        @{Name="Iron Skin Elixir";    Type="DEFBuff";     Power=8;  Price=75; Desc="DEF+8 in battle";   Category="Potion"}
        @{Name="Potion of Luck";      Type="Luck";        Power=20; Price=90; Desc="+20% crit, 3 turns"; Category="Potion"}
        @{Name="Acid Flask";          Type="Throw";       Power=25; Price=40; Desc="Deal 25 damage";    Category="Throwable"}
        @{Name="Poison Flask";        Type="ThrowPoison"; Power=15; Price=50; Desc="15 dmg + Poison";   Category="Throwable"}
        @{Name="Frost Bomb";          Type="ThrowSlow";   Power=20; Price=55; Desc="20 dmg + Slow";     Category="Throwable"}
    )
}

# ─── SAVE / LOAD SYSTEM ──────────────────────────────────────────

function Save-Game {
    $p = $script:Player

    # ── Convert inventory loot to gold ──
    $lootGold = 0
    foreach($item in $script:Inventory){ $lootGold += $item.Value }
    $totalGold = $script:Gold + $lootGold

    # ── Class index (0-5) ──
    $classOrder = @("Knight","Mage","Brawler","Ranger","Cleric","Necromancer","Berserker","Warlock")
    $classIdx = 0
    for($i = 0; $i -lt $classOrder.Count; $i++){
        if($classOrder[$i] -eq $script:PlayerClass){ $classIdx = $i; break }
    }

    # ── Weapon index: 0 = none, 1-N = shop position, 999 = Dutchman's Blade ──
    $weapIdx = 0
    if($script:EquippedWeapon){
        if($script:EquippedWeapon.Name -eq "Dutchman's Blade"){
            $weapIdx = 999
        } else {
            $weapons = Get-WeaponShop
            for($i = 0; $i -lt $weapons.Count; $i++){
                if($weapons[$i].Name -eq $script:EquippedWeapon.Name){
                    $weapIdx = $i + 1
                    break
                }
            }
        }
    }

    # ── Armor indices ──
    $allArmor = Get-ArmorShop
    $armorSlots = @("Helmet","Chest","Shield","Amulet","Boots")
    $armorIndices = @(0, 0, 0, 0, 0)
    for($s = 0; $s -lt $armorSlots.Count; $s++){
        $piece = $script:EquippedArmor[$armorSlots[$s]]
        if($piece){
            for($i = 0; $i -lt $allArmor.Count; $i++){
                if($allArmor[$i].Name -eq $piece.Name){
                    $armorIndices[$s] = $i + 1
                    break
                }
            }
        }
    }

    # ── Potion counts (v2: 7 regular including Luck, 3 throwable) ──
    $potShop = Get-PotionShop
    $potCounts = @(0, 0, 0, 0, 0, 0, 0)
    $throwCounts = @(0, 0, 0)

    foreach($pot in $script:Potions){
        for($i = 0; $i -lt 7; $i++){
            if($pot.Name -eq $potShop[$i].Name){
                $potCounts[$i]++
                break
            }
        }
    }
    foreach($tp in $script:ThrowablePotions){
        for($i = 7; $i -lt 10; $i++){
            if($tp.Name -eq $potShop[$i].Name){
                $throwCounts[$i - 7]++
                break
            }
        }
    }

    # ── Partner: 0=none, 1=Healer, 2=Thief, 3=Bard ──
    $partnerIdx = 0
    if($script:Partner){
        switch($script:Partner.Class){
            "Healer" { $partnerIdx = 1 }
            "Thief"  { $partnerIdx = 2 }
            "Bard"   { $partnerIdx = 3 }
        }
    }

    # ── v2 additions ──
    # Achievement bitmask — iterate the list in order; '1' if unlocked, '0' otherwise
    $achList = Get-AchievementList
    $achBits = ""
    foreach($a in $achList){
        if($script:Achievements.ContainsKey($a.Id)){ $achBits += "1" } else { $achBits += "0" }
    }
    # Training points joined "ATK,DEF,SPD,MAG,HP,MP"
    $tp = $script:TrainingPoints
    $trainStr = "$($tp.ATK),$($tp.DEF),$($tp.SPD),$($tp.MAG),$($tp.HP),$($tp.MP)"
    $dutchFlag = if($script:OwnsDutchmanBlade){1}else{0}
    $dailyDone = if($script:DailyDungeonDone){1}else{0}
    $tutSeen   = if($script:TutorialSeen){1}else{0}

    # ── Build save string: version "3" = durability-aware format ──
    # Serialize durability of each equipped piece as "weapon,helmet,chest,shield,amulet,boots"
    # Each value is "cur/max", or "-1" for none-equipped, or "X" for indestructible (Dutchman's Blade).
    $durParts = @()
    if($script:EquippedWeapon){
        if($script:EquippedWeapon.MaxDurability -lt 0){
            $durParts += "X"  # indestructible
        } elseif($script:EquippedWeapon.ContainsKey("Durability")){
            $durParts += "$($script:EquippedWeapon.Durability)/$($script:EquippedWeapon.MaxDurability)"
        } else {
            $durParts += "-1"
        }
    } else {
        $durParts += "-1"
    }
    foreach($slot in @("Helmet","Chest","Shield","Amulet","Boots")){
        $piece = $script:EquippedArmor[$slot]
        if($piece -and $piece.ContainsKey("Durability")){
            $durParts += "$($piece.Durability)/$($piece.MaxDurability)"
        } else {
            $durParts += "-1"
        }
    }
    $durStr = $durParts -join ","

    $saveStr = @(
        "5"                          # [0]  format version (v5: lifetime stat counters)
        $classIdx                    # [1]  class
        $script:PlayerLevel          # [2]  level
        $script:XP                   # [3]  current XP
        $script:XPToNext             # [4]  XP to next level
        $totalGold                   # [5]  gold (loot converted)
        $p.HP                        # [6]  current HP
        $p.MaxHP                     # [7]  max HP
        $p.MP                        # [8]  current MP
        $p.MaxMP                     # [9]  max MP
        $p.ATK                       # [10] ATK
        $p.DEF                       # [11] DEF
        $p.SPD                       # [12] SPD
        $p.MAG                       # [13] MAG
        $script:DungeonLevel         # [14] dungeon level
        $script:KillCount            # [15] kills (quest counter)
        $script:RoyalSuiteUses       # [16] royal suite uses
        $weapIdx                     # [17] weapon
        ($armorIndices -join ",")    # [18] armor "h,c,s,a,b"
        ($potCounts -join ",")       # [19] potion counts (7)
        ($throwCounts -join ",")     # [20] throwable counts (3)
        $partnerIdx                  # [21] partner
        # ── v2 extensions ──
        0                            # [22] streak (always saved as 0)
        $script:BestStreak           # [23]
        $script:TotalKills           # [24]
        $script:BossesDefeated       # [25]
        $achBits                     # [26] achievement bitmask
        $trainStr                    # [27] training points
        $dutchFlag                   # [28] owns Dutchman's Blade
        $script:DailyDungeonDate     # [29] daily dungeon date
        $dailyDone                   # [30] daily done flag
        $tutSeen                     # [31] tutorial seen
        $script:Lockpicks            # [32] lockpick count
        # ── v3 extension ──
        $durStr                      # [33] durability "weapon,helmet,chest,shield,amulet,boots"
        # ── v3 extension ──
        "$($script:RepairKits),$($script:ExtraStrongPotions)"  # [34] special items
        $script:Stance               # [35] combat stance ("Aggressive"/"Balanced"/"Defensive")
        # ── v5 extension: lifetime stat counters (drives new achievements) ──
        # Single packed field to keep the format compact: comma-separated.
        "$($script:TotalCrits),$($script:TotalLocksPicked),$($script:TotalBareKills),$($script:TotalUntouched),$($script:TotalStanceSwaps),$($script:TotalRepairs),$($script:CompletedQuests)"  # [36]
    ) -join "|"

    # ── Checksum ──
    $sum = 0
    foreach($char in $saveStr.ToCharArray()){ $sum += [int]$char }
    $checksum = $sum % 9999
    $saveStr += "|$checksum"

    # ── Base64 encode ──
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($saveStr)
    $code = [Convert]::ToBase64String($bytes)

    return $code
}


function Load-Game {
    param([string]$Code)

    # ── Try to decode the Base64 string back into text ──
    # If the player typed garbage, this will fail, so we use try/catch.
    try {
        $bytes = [Convert]::FromBase64String($Code)
        $saveStr = [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        return @{ Success = $false; Error = "Invalid save code format." }
    }

    # ── Split into parts ──
    $parts = $saveStr -split '\|'
    $ver = $parts[0]
    # Only v4 and v5 accepted. v1/v2 predate durability; v3 predates the
    # inventory weight system. v4 = inventory weight; v5 = adds lifetime
    # stat counters for the new achievements.
    if($ver -eq "1" -or $ver -eq "2" -or $ver -eq "3"){
        return @{ Success = $false; Error = "This save is from an older version and can't be loaded. The inventory weight update requires a new character." }
    }
    if($ver -ne "4" -and $ver -ne "5"){
        return @{ Success = $false; Error = "Unknown save format version '$ver'." }
    }
    # Accepted lengths (parts including checksum):
    #   v4 with stance:    37  (36 data + 1 checksum)
    #   v4 without stance: 36  (legacy v4)
    #   v5:                38  (37 data + 1 checksum)
    $expectedLen = $parts.Count
    $validLen = switch($ver){
        "4" { @(36, 37) -contains $expectedLen }
        "5" { $expectedLen -eq 38 }
    }
    if(-not $validLen){
        return @{ Success = $false; Error = "Save code is corrupted (wrong length for v$ver)." }
    }

    # ── Verify checksum ──
    $dataEnd = $expectedLen - 2
    $dataStr = ($parts[0..$dataEnd]) -join "|"
    $sum = 0
    foreach($char in $dataStr.ToCharArray()){ $sum += [int]$char }
    $expectedCheck = $sum % 9999
    $actualCheck = [int]$parts[$expectedLen - 1]
    if($expectedCheck -ne $actualCheck){
        return @{ Success = $false; Error = "Checksum mismatch. Code may have a typo." }
    }

    # ── Parse core fields (shared between v1 and v2) ──
    $classIdx       = [int]$parts[1]
    $playerLevel    = [int]$parts[2]
    $xp             = [int]$parts[3]
    $xpToNext       = [int]$parts[4]
    $gold           = [int]$parts[5]
    $hp             = [int]$parts[6]
    $maxHP          = [int]$parts[7]
    $mp             = [int]$parts[8]
    $maxMP          = [int]$parts[9]
    $atk            = [int]$parts[10]
    $def            = [int]$parts[11]
    $spd            = [int]$parts[12]
    $mag            = [int]$parts[13]
    $dungeonLevel   = [int]$parts[14]
    $killCount      = [int]$parts[15]
    $royalSuiteUses = [int]$parts[16]
    $weapIdx        = [int]$parts[17]
    $armorParts     = $parts[18] -split ','
    $potParts       = $parts[19] -split ','
    $throwParts     = $parts[20] -split ','
    $partnerIdx     = [int]$parts[21]

    # ── Validate class ──
    $classOrder = @("Knight","Mage","Brawler","Ranger","Cleric","Necromancer","Berserker","Warlock")
    if($classIdx -lt 0 -or $classIdx -ge $classOrder.Count){
        return @{ Success = $false; Error = "Invalid class in save." }
    }
    $className = $classOrder[$classIdx]

    # ── Rebuild the player ──
    $classes = Get-ClassTemplates
    $template = $classes[$className]
    $script:PlayerClass = $className
    $script:Player = @{
        Name      = $template.Name
        HP        = $hp
        MaxHP     = $maxHP
        MP        = $mp
        MaxMP     = $maxMP
        ATK       = $atk
        DEF       = $def
        SPD       = $spd
        MAG       = $mag
        Abilities = $template.Abilities
    }
    $script:PlayerLevel    = $playerLevel
    $script:XP             = $xp
    $script:XPToNext       = $xpToNext
    $script:Gold           = $gold
    $script:DungeonLevel   = $dungeonLevel
    $script:KillCount      = $killCount
    $script:RoyalSuiteUses = $royalSuiteUses

    # ── Rebuild weapon ──
    # 999 = Dutchman's Blade (special handling)
    $script:EquippedWeapon = $null
    if($weapIdx -eq 999){
        $dutch = @{
            Name="Dutchman's Blade"; ATK=100; Price=10000; WeaponType="Sword"
            ClassAffinity="None"; AffinityBonus=0; Perk="Drain"; PerkChance=40
        }
        $script:EquippedWeapon = Init-ItemDurability $dutch
        $script:OwnsDutchmanBlade = $true
    } elseif($weapIdx -gt 0){
        $weapons = Get-WeaponShop
        if($weapIdx -le $weapons.Count){
            $script:EquippedWeapon = Init-ItemDurability $weapons[$weapIdx - 1]
        }
    }

    # ── Rebuild armor ──
    $script:EquippedArmor = @{
        Helmet = $null; Chest = $null; Shield = $null
        Amulet = $null; Boots = $null
    }
    $allArmor = Get-ArmorShop
    $armorSlots = @("Helmet","Chest","Shield","Amulet","Boots")
    for($s = 0; $s -lt $armorSlots.Count; $s++){
        $aIdx = [int]$armorParts[$s]
        if($aIdx -gt 0 -and $aIdx -le $allArmor.Count){
            $script:EquippedArmor[$armorSlots[$s]] = Init-ItemDurability $allArmor[$aIdx - 1]
        }
    }

    # ── Rebuild potions (v3: 7 regular, 3 throwables) ──
    $script:Potions = [System.Collections.ArrayList]@()
    $script:ThrowablePotions = [System.Collections.ArrayList]@()
    $potShop = Get-PotionShop

    for($i = 0; $i -lt 7; $i++){
        if($i -ge $potParts.Count){ break }
        $count = [int]$potParts[$i]
        for($c = 0; $c -lt $count; $c++){
            [void]$script:Potions.Add($potShop[$i])
        }
    }
    for($i = 0; $i -lt 3; $i++){
        if($i -ge $throwParts.Count){ break }
        $count = [int]$throwParts[$i]
        for($c = 0; $c -lt $count; $c++){
            [void]$script:ThrowablePotions.Add($potShop[$i + 7])
        }
    }

    # ── Rebuild partner ──
    $script:Partner = $null
    if($partnerIdx -gt 0){
        $partnerData = @(
            @{ Name="Sister Maren";  Class="Healer"; Desc="Heals you when HP drops below 50%" }
            @{ Name="Fingers McGee"; Class="Thief";  Desc="+15% gold from enemy defeats" }
            @{ Name="Lyric the Wise"; Class="Bard";  Desc="+25% XP from all sources" }
        )
        if($partnerIdx -le $partnerData.Count){
            $script:Partner = $partnerData[$partnerIdx - 1]
        }
    }

    # ── v3 extended fields ──
    # Streak is read but discarded — always fresh on load by design
    $script:Streak         = 0
    $script:BestStreak     = [int]$parts[23]
    $script:TotalKills     = [int]$parts[24]
    $script:BossesDefeated = [int]$parts[25]

    # Achievement bitmask
    $script:Achievements = @{}
    $achBits = $parts[26]
    $achList = Get-AchievementList
    for($i = 0; $i -lt $achList.Count; $i++){
        if($i -lt $achBits.Length -and $achBits[$i] -eq '1'){
            $script:Achievements[$achList[$i].Id] = $true
        }
    }

    # Training points
    $trainStr = $parts[27]
    $trainParts = $trainStr -split ','
    if($trainParts.Count -eq 6){
        $script:TrainingPoints = @{
            ATK = [int]$trainParts[0]
            DEF = [int]$trainParts[1]
            SPD = [int]$trainParts[2]
            MAG = [int]$trainParts[3]
            HP  = [int]$trainParts[4]
            MP  = [int]$trainParts[5]
        }
    }
    if([int]$parts[28] -eq 1){ $script:OwnsDutchmanBlade = $true }
    $script:DailyDungeonDate = $parts[29]
    $script:DailyDungeonDone = ([int]$parts[30] -eq 1)
    $script:TutorialSeen     = ([int]$parts[31] -eq 1)
    $script:Lockpicks        = [int]$parts[32]
    $script:DisturbedChests  = @{}

    # Durability: "weapon,helmet,chest,shield,amulet,boots" each as "cur/max", "X", or "-1"
    $durParts = $parts[33] -split ','
    function _Apply-DurParse {
        param($Item, [string]$Raw)
        if(-not $Item){ return }
        if($Raw -eq "X"){
            # Indestructible (Dutchman's Blade)
            $Item.MaxDurability = -1
            return
        }
        if($Raw -eq "-1"){
            # No durability tracking (shouldn't happen on v3 for equipped items, but safe)
            $max = Get-MaxDurability $Item
            $Item.MaxDurability = $max
            $Item.Durability    = $max
            return
        }
        $bits = $Raw -split '/'
        if($bits.Count -eq 2){
            $Item.Durability    = [int]$bits[0]
            $Item.MaxDurability = [int]$bits[1]
        }
    }
    if($script:EquippedWeapon){
        _Apply-DurParse -Item $script:EquippedWeapon -Raw $durParts[0]
    }
    $slotOrder = @("Helmet","Chest","Shield","Amulet","Boots")
    for($si=0; $si -lt $slotOrder.Count; $si++){
        $piece = $script:EquippedArmor[$slotOrder[$si]]
        if($piece){
            _Apply-DurParse -Item $piece -Raw $durParts[$si + 1]
        }
    }

    # ── Special items (field [34]): "repairKits,extraStrongPotions" ──
    $script:RepairKits = 0
    $script:ExtraStrongPotions = 0
    $specialParts = $parts[34] -split ','
    if($specialParts.Count -ge 2){
        $script:RepairKits = [int]$specialParts[0]
        $script:ExtraStrongPotions = [int]$specialParts[1]
    }

    # ── Stance (field [35]): "Aggressive"/"Balanced"/"Defensive" ──
    # Older v4 saves predate the stance field; default to Balanced.
    $script:Stance = "Balanced"
    if($parts.Count -ge 37){
        $loadedStance = $parts[35]
        if($loadedStance -in @("Aggressive","Balanced","Defensive")){
            $script:Stance = $loadedStance
        }
    }

    # ── Lifetime stat counters (field [36], v5+): comma-separated.
    # Older v4 saves don't have this field — counters reset to 0.
    # Order: Crits, LocksPicked, BareKills, Untouched, StanceSwaps, Repairs, CompletedQuests
    $script:TotalCrits       = 0
    $script:TotalLocksPicked = 0
    $script:TotalBareKills   = 0
    $script:TotalUntouched   = 0
    $script:TotalStanceSwaps = 0
    $script:TotalRepairs     = 0
    # CompletedQuests stays whatever was already loaded (or 0 if not set)
    if($parts.Count -ge 38){
        try {
            $countersStr = $parts[36]
            $countersArr = $countersStr -split ","
            if($countersArr.Count -ge 6){
                $script:TotalCrits       = [int]$countersArr[0]
                $script:TotalLocksPicked = [int]$countersArr[1]
                $script:TotalBareKills   = [int]$countersArr[2]
                $script:TotalUntouched   = [int]$countersArr[3]
                $script:TotalStanceSwaps = [int]$countersArr[4]
                $script:TotalRepairs     = [int]$countersArr[5]
            }
            if($countersArr.Count -ge 7){
                $script:CompletedQuests = [int]$countersArr[6]
            }
        } catch {
            # Malformed counters — leave at 0, don't fail the whole load
        }
    }

    # ── Reset transient state ──
    $script:Inventory = [System.Collections.ArrayList]@()
    $script:Quests = [System.Collections.ArrayList]@()
    $script:AvailableQuests = $null
    $script:HasBossKey = $false
    $script:BossDefeated = $false
    $script:Dungeon = $null
    $script:DungeonKills = 0
    $script:DungeonTreasures = 0
    $script:RescueTarget = $null
    $script:LuckTurnsLeft = 0; $script:LuckBonus = 0

    return @{ Success = $true; Error = "" }
}


function Get-ArmorShop {
    @(
        # ── HELMETS ──
        @{Name="Leather Cap";       Slot="Helmet"; DEF=2;  Price=30}
        @{Name="Iron Helm";         Slot="Helmet"; DEF=4;  Price=80}
        @{Name="Steel Helm";        Slot="Helmet"; DEF=7;  Price=200}
        @{Name="Dragon Helm";       Slot="Helmet"; DEF=10; Price=450}
        @{Name="Mythril Crown";     Slot="Helmet"; DEF=14; Price=900}
        @{Name="Archon's Diadem";   Slot="Helmet"; DEF=18; Price=1800}
        # ── CHEST ──
        @{Name="Leather Vest";      Slot="Chest";  DEF=3;  Price=40}
        @{Name="Chain Mail";        Slot="Chest";  DEF=6;  Price=120}
        @{Name="Plate Armor";       Slot="Chest";  DEF=10; Price=300}
        @{Name="Dragon Plate";      Slot="Chest";  DEF=14; Price=600}
        @{Name="Mythril Cuirass";   Slot="Chest";  DEF=18; Price=1200}
        @{Name="Aegis of Kings";    Slot="Chest";  DEF=24; Price=2500}
        # ── SHIELDS ──
        @{Name="Wooden Shield";     Slot="Shield"; DEF=2;  Price=25}
        @{Name="Iron Shield";       Slot="Shield"; DEF=5;  Price=100}
        @{Name="Tower Shield";      Slot="Shield"; DEF=8;  Price=250}
        @{Name="Enchanted Ward";    Slot="Shield"; DEF=11; Price=500}
        @{Name="Runecarved Bulwark";Slot="Shield"; DEF=15; Price=1100}
        @{Name="Starlight Aegis";   Slot="Shield"; DEF=20; Price=2300}
        # ── AMULETS ──
        @{Name="Copper Amulet";     Slot="Amulet"; DEF=1;  Price=35}
        @{Name="Silver Amulet";     Slot="Amulet"; DEF=3;  Price=90}
        @{Name="Gold Amulet";       Slot="Amulet"; DEF=5;  Price=220}
        @{Name="Diamond Amulet";    Slot="Amulet"; DEF=7;  Price=480}
        @{Name="Soulbound Pendant"; Slot="Amulet"; DEF=10; Price=1000}
        @{Name="Eye of the Old Ones";Slot="Amulet";DEF=14; Price=2100}
        # ── BOOTS ──
        @{Name="Leather Boots";     Slot="Boots";  DEF=1;  Price=25}
        @{Name="Iron Greaves";      Slot="Boots";  DEF=3;  Price=75}
        @{Name="Steel Greaves";     Slot="Boots";  DEF=6;  Price=180}
        @{Name="Dragon Boots";      Slot="Boots";  DEF=9;  Price=400}
        @{Name="Windstrider Boots"; Slot="Boots";  DEF=13; Price=850}
        @{Name="Boots of Legends";  Slot="Boots";  DEF=17; Price=1900}
    )
}


# ─── TRAINING GROUNDS ─────────────────────────────────────────────
function Show-TrainingGrounds {
    $loop = $true
    while($loop){
        clr
        Write-Host ""
        Write-CL "  ╔══════════════════════════════════════════════════════════════════════╗" "DarkRed"
        Write-CL "  ║              T H E   T R A I N I N G   G R O U N D S                ║" "Red"
        Write-CL "  ║                    'Hone your skills — for a price.'                ║" "DarkRed"
        Write-CL "  ╚══════════════════════════════════════════════════════════════════════╝" "DarkRed"
        Write-Host ""
        Write-CL "           _____                 ╱|  ╱|" "DarkGray"
        Write-CL "          |_____|__          ___| |_| |__" "DarkGray"
        Write-CL "         /|     |  \        /    \___/   \" "DarkYellow"
        Write-CL "        / |  X  |   \      /    <  o  >   \" "Red"
        Write-CL "       /__|_____|____\    /__________________\" "DarkGray"
        Write-CL "        ||     ||           |  DUMMY  ||WEAPON|" "DarkGray"
        Write-CL "        ||     ||           |_________||______|" "DarkGray"
        Write-Host ""

        $p = $script:Player
        Write-CL "  ┌──────────────────────────────────────────────────────────────────┐" "DarkGray"
        Write-C  "  │  Gold: " "DarkGray"; Write-C "$($script:Gold)g" "Yellow"
        $goldPadNeeded = 58 - "Gold: $($script:Gold)g".Length
        if($goldPadNeeded -lt 0){ $goldPadNeeded = 0 }
        Write-CL ("$(' ' * $goldPadNeeded)│") "DarkGray"
        Write-CL "  │  Training teaches your body to bear more, hit harder, move     │" "DarkGray"
        Write-CL "  │  faster. Each bump costs more than the last. Max +10 per stat. │" "DarkGray"
        Write-CL "  └──────────────────────────────────────────────────────────────────┘" "DarkGray"
        Write-Host ""

        $stats = @(
            @{Key="ATK"; Label="Strength (ATK)";    Gain=2; Color="Red"}
            @{Key="DEF"; Label="Toughness (DEF)";   Gain=2; Color="Cyan"}
            @{Key="SPD"; Label="Agility (SPD)";     Gain=1; Color="Green"}
            @{Key="MAG"; Label="Focus (MAG)";       Gain=2; Color="Magenta"}
            @{Key="HP";  Label="Vitality (MaxHP)";  Gain=8; Color="DarkRed"}
            @{Key="MP";  Label="Willpower (MaxMP)"; Gain=5; Color="DarkCyan"}
        )
        Write-CL "  ┌─────┬────────────────────────┬───────────┬──────────┬──────────┐" "DarkGray"
        Write-CL "  │  #  │ Stat                   │ Trained   │ Next +   │ Cost     │" "DarkGray"
        Write-CL "  ├─────┼────────────────────────┼───────────┼──────────┼──────────┤" "DarkGray"
        for($i=0; $i -lt $stats.Count; $i++){
            $s = $stats[$i]
            $current = $script:TrainingPoints[$s.Key]
            $cost = Get-TrainingCost $s.Key
            $costStr = if($cost -lt 0){"MAXED"}else{"$($cost)g"}
            $trainStr = "+$current / +10"
            $nextStr  = if($cost -lt 0){"--"}else{"+$($s.Gain)"}
            $affordable = if($cost -lt 0){"DarkGray"}elseif($script:Gold -ge $cost){"Green"}else{"DarkGray"}
            Write-C "  │ " "DarkGray"
            Write-C " $($i+1) " $affordable
            Write-C "│ " "DarkGray"
            Write-C $s.Label.PadRight(23) $s.Color
            Write-C "│ " "DarkGray"
            Write-C $trainStr.PadRight(10) "White"
            Write-C "│ " "DarkGray"
            Write-C $nextStr.PadRight(9) "Yellow"
            Write-C "│ " "DarkGray"
            Write-C $costStr.PadRight(9) $affordable
            Write-CL "│" "DarkGray"
        }
        Write-CL "  └─────┴────────────────────────┴───────────┴──────────┴──────────┘" "DarkGray"
        Write-Host ""
        Write-CL "  [0] Leave the training grounds" "DarkGray"
        Write-Host ""
        Write-C "  > " "Yellow"; $ch = Read-Host
        if($ch -eq "0"){ $loop = $false; continue }
        $idx = (ConvertTo-SafeInt -Value $ch) - 1
        if($idx -lt 0 -or $idx -ge $stats.Count){ continue }
        $s = $stats[$idx]
        $cost = Get-TrainingCost $s.Key
        if($cost -lt 0){
            Write-CL "  That stat is already maxed." "Yellow"
            Wait-Key; continue
        }
        if($script:Gold -lt $cost){
            Write-CL "  Not enough gold. The trainer crosses her arms." "Red"
            Wait-Key; continue
        }
        $script:Gold -= $cost
        $script:TrainingPoints[$s.Key]++
        switch($s.Key){
            "ATK" { $p.ATK += $s.Gain }
            "DEF" { $p.DEF += $s.Gain }
            "SPD" { $p.SPD += $s.Gain }
            "MAG" { $p.MAG += $s.Gain }
            "HP"  { $p.MaxHP += $s.Gain; $p.HP = [math]::Min($p.HP + $s.Gain, $p.MaxHP) }
            "MP"  { $p.MaxMP += $s.Gain; $p.MP = [math]::Min($p.MP + $s.Gain, $p.MaxMP) }
        }
        Write-Host ""
        Write-CL "  The trainer nods approvingly." "Yellow"
        Write-CL "  +$($s.Gain) $($s.Key) (permanent)" "Green"
        Check-Achievements
        Wait-Key
    }
}

# ─── ACHIEVEMENTS MENU ────────────────────────────────────────────
function Show-AchievementsMenu {
    clr
    Write-Host ""
    Write-CL "  ╔══════════════════════════════════════════════════════════════════════╗" "DarkMagenta"
    Write-CL "  ║                      A C H I E V E M E N T S                         ║" "Magenta"
    Write-CL "  ╚══════════════════════════════════════════════════════════════════════╝" "DarkMagenta"
    Write-Host ""
    $list = Get-AchievementList
    $unlocked = $script:Achievements.Count
    $total = $list.Count
    Write-CL "  Progress: $unlocked / $total  ($([math]::Floor($unlocked * 100 / $total))%)" "Yellow"
    Write-Host ""
    foreach($ach in $list){
        $isDone = $script:Achievements.ContainsKey($ach.Id)
        $marker = if($isDone){"[✓]"}else{"[ ]"}
        $color  = if($isDone){"Green"}else{"DarkGray"}
        $nameCol = if($isDone){"Yellow"}else{"DarkGray"}
        Write-C "  $marker " $color
        Write-C $ach.Name.PadRight(24) $nameCol
        Write-C " — " $color
        Write-C $ach.Desc.PadRight(40) $color
        Write-CL " (+$($ach.Gold)g, +$($ach.XP)xp)" "DarkCyan"
    }
    Write-Host ""
    Write-CL "  Some achievements unlock from specific events — keep exploring!" "DarkGray"
    Wait-Key
}


# ─── MAIN MENU / GAME LOOP ──────────────────────────────────────
function Show-MainMenu {
    while($script:GameRunning){
        # ── Reset daily dungeon flag if the day changed ──
        $today = (Get-Date).ToString("yyyy-MM-dd")
        if($script:DailyDungeonDate -ne $today){
            $script:DailyDungeonDate = $today
            $script:DailyDungeonDone = $false
        }
        clr
        $p = $script:Player
        Write-Host ""
        # ── Town banner (aligned 83-char box, matching action grid width) ──
        Write-CL "  ╔═════════════════════════════════════════════════════════════════════════════════╗" "DarkYellow"
        Write-CL "  ║                              T O W N   S Q U A R E                              ║" "Yellow"
        Write-CL "  ║                      The last settlement before the Depths                      ║" "DarkYellow"
        Write-CL "  ╚═════════════════════════════════════════════════════════════════════════════════╝" "DarkYellow"
        Write-Host ""
        # ASCII skyline of the town (user-provided)
        Write-CL '                                         .                                       ' "DarkGray"
        Write-CL '                                        /|\                                      ' "DarkGray"
        Write-CL '                                       / | \                                     ' "DarkGray"
        Write-CL '                   .                  /  |  \            .                       ' "DarkGray"
        Write-CL '                  /|\        _       /___|___\          /|\                      ' "DarkGray"
        Write-CL '                 / | \      |~|      |  |_|  |         / | \                     ' "DarkGray"
        Write-CL '                /  |  \     |.|   _  | |   | |    _   /  |  \                    ' "DarkGray"
        Write-CL '     .    *    /___|___\   /| |\  |~|| |___| |   |~| /___|___\                   ' "DarkGray"
        Write-CL '    /|\  /|\  |  _   _ |  |   | |.|||_______||   |.||  _   _ |                   ' "DarkGray"
        Write-CL '   / | \/ | \ | |_| |_||  |___|_|  ||   |   ||  /| || |_| |_||                   ' "DarkGray"
        Write-CL '  /__|_/__|__\| |       | |       | ||   |   || |   || |     ||                  ' "DarkGray"
        Write-CL ' |    |    |  | |  ___  | |  ___  | ||  _|_  || |___|| | ___ ||    /\            ' "DarkGray"
        Write-CL ' |____|____|__| | |   | | | |   | | || |   | ||_____|| ||   |||   /  \           ' "DarkGray"
        Write-CL ' |  |    |  | | | |___| | | |___| | || |___| ||  |  || ||___|||  / /\ \          ' "DarkGray"
        Write-CL ' |  | [] |  | | |_______| |_______| ||_______||  |  || |_____|| / /  \ \         ' "DarkGray"
        Write-CL ' |  |    |  | |_|  |||  |_|  |||  |_||  |||  ||  |  ||_|  |  ||/ / [] \ \        ' "DarkGray"
        Write-CL ' |__|____|__| |  |_|||__|  |_|||__|  ||__|||__||__|__||  |_|__||_/______\_\      ' "DarkGray"
        Write-CL ' |  |    |  | |    |||  |    |||  |  ||  |||  ||  |  ||   |   ||    ||   |      ' "DarkGray"
        Write-CL '_|__|____|__|_|____|||||_|____|||||__|_|__||||_||__|__|_|__|___|_|__||___|_     ' "DarkGray"
        Write-CL '   ~      ~    ^^  ~~ ~  ~~ ^^ ~~  ~  ^^  ~~   ~~  ^^ ~    ~~    ^^   ~~        ' "DarkBlue"
        Write-Host ""

        # ── Player status block (83-char width matching banner/grid) ──
        $hpPct = $p.HP / $p.MaxHP
        $hpColor = if($hpPct -gt 0.5){"Green"}elseif($hpPct -gt 0.25){"Yellow"}else{"Red"}
        Write-CL "  ╔═════════════════════════════════════════════════════════════════════════════════╗" "DarkCyan"
        Write-C  "  ║  " "DarkCyan"
        Write-C "$($p.Name)" "Green"
        Write-C "  Lv$($script:PlayerLevel)" "Yellow"
        $topLine = "$($p.Name)  Lv$($script:PlayerLevel)"
        $pad1 = 79 - $topLine.Length
        if($pad1 -lt 0){$pad1=0}
        Write-CL ("$(' ' * $pad1)║") "DarkCyan"

        Write-C  "  ║  " "DarkCyan"
        Write-C "HP: " "White"
        Write-C "$($p.HP)/$($p.MaxHP)" $hpColor
        Write-C "   MP: " "White"
        Write-C "$($p.MP)/$($p.MaxMP)" "Cyan"
        Write-C "   Gold: " "White"
        Write-C "$($script:Gold)g" "Yellow"
        Write-C "   XP: " "White"
        Write-C "$($script:XP)/$($script:XPToNext)" "DarkCyan"
        $statLine = "HP: $($p.HP)/$($p.MaxHP)   MP: $($p.MP)/$($p.MaxMP)   Gold: $($script:Gold)g   XP: $($script:XP)/$($script:XPToNext)"
        $pad2 = 79 - $statLine.Length
        if($pad2 -lt 0){$pad2=0}
        Write-CL ("$(' ' * $pad2)║") "DarkCyan"

        $streakTxt = if($script:Streak -gt 0){"Streak: $($script:Streak)x"}else{""}
        Write-C  "  ║  " "DarkCyan"
        Write-C "Dungeons Cleared: $($script:DungeonLevel)" "DarkGray"
        $dungLine = "Dungeons Cleared: $($script:DungeonLevel)"
        if($streakTxt){
            Write-C "   " "DarkCyan"
            Write-C $streakTxt "Yellow"
            $dungLine += "   $streakTxt"
        }
        $achCount = $script:Achievements.Count
        $totalAch = (Get-AchievementList).Count
        Write-C "   Achievements: " "DarkGray"
        Write-C "$achCount/$totalAch" "Magenta"
        $dungLine += "   Achievements: $achCount/$totalAch"
        $pad3 = 79 - $dungLine.Length
        if($pad3 -lt 0){$pad3=0}
        Write-CL ("$(' ' * $pad3)║") "DarkCyan"
        Write-CL "  ╚═════════════════════════════════════════════════════════════════════════════════╝" "DarkCyan"
        Write-Host ""

        # ── Action grid: fixed 2-column layout, each column 40 chars wide ──
        # Total box width = 2 + 40 + 1 + 40 = 83 chars
        $colW = 40
        $hbar = "═" * $colW
        Write-CL "  ╔$hbar╦$hbar╗" "DarkGray"

        # First row: Enter Dungeon / Daily Dungeon
        $leftCell  = " [1] Enter Dungeon"
        $dtxt = if($script:DailyDungeonDone){" (DONE)"}else{" (2x rewards!)"}
        $rightCell = " [2] Daily Dungeon$dtxt"
        $lPad = $colW - $leftCell.Length
        if($lPad -lt 0){$lPad=0}
        $rPad = $colW - $rightCell.Length
        if($rPad -lt 0){$rPad=0}
        Write-C "  ║" "DarkGray"
        Write-C " [1]" "Green"; Write-C " Enter Dungeon" "White"
        Write-C ("$(' ' * $lPad)║") "DarkGray"
        Write-C " [2]" "Green"; Write-C " Daily Dungeon" "White"
        $dtxtColor = if($script:DailyDungeonDone){"DarkGray"}else{"Yellow"}
        Write-C $dtxt $dtxtColor
        Write-CL ("$(' ' * $rPad)║") "DarkGray"

        Write-CL "  ╠$hbar╬$hbar╣" "DarkGray"

        $rows = @(
            @( @{N="[3]";L="Visit the Market";   C="Cyan";       Desc="Buy & sell gear"},
               @{N="[4]";L="View Inventory";     C="Magenta";    Desc="Manage loot & gear"} ),
            @( @{N="[5]";L="Weary Lantern Inn";  C="Yellow";     Desc="Rest & recover"},
               @{N="[6]";L="Training Grounds";   C="Red";        Desc="Hone your skills"} ),
            @( @{N="[7]";L="Quest Board";        C="DarkYellow"; Desc="Accept bounties"},
               @{N="[8]";L="Guild Hall";         C="Green";      Desc="Hire companions"} ),
            @( @{N="[9]";L="View Stats";         C="White";      Desc="Abilities & gear"},
               @{N="[A]";L="Achievements";       C="DarkMagenta";Desc="Review milestones"} ),
            @( @{N="[S]";L="Save Game";          C="DarkGreen";  Desc="Export save code"},
               @{N="[Q]";L="Quit";               C="DarkRed";    Desc="Leave the town"} )
        )
        # Cell layout inside each column:
        #   " [N] Label" + spaces_to_labelW + "Desc" + padding_to_colW
        $labelW = 22  # width reserved for "[N] Label" part including leading space
        foreach($r in $rows){
            $l = $r[0]; $rg = $r[1]

            $lLabel = " $($l.N) $($l.L)"           # e.g. " [3] Visit the Market"
            $lDesc  = $l.Desc
            $lSpace = $labelW - $lLabel.Length
            if($lSpace -lt 1){$lSpace = 1}
            $lUsed  = $lLabel.Length + $lSpace + $lDesc.Length
            $lTail  = $colW - $lUsed
            if($lTail -lt 0){$lTail = 0}

            $rLabel = " $($rg.N) $($rg.L)"
            $rDesc  = $rg.Desc
            $rSpace = $labelW - $rLabel.Length
            if($rSpace -lt 1){$rSpace = 1}
            $rUsed  = $rLabel.Length + $rSpace + $rDesc.Length
            $rTail  = $colW - $rUsed
            if($rTail -lt 0){$rTail = 0}

            Write-C "  ║" "DarkGray"
            Write-C " $($r[0].N)" $r[0].C
            Write-C " $($r[0].L)" "White"
            Write-C (" " * $lSpace) "Black"
            Write-C $lDesc "DarkGray"
            Write-C (" " * $lTail) "Black"
            Write-C "║" "DarkGray"

            Write-C " $($r[1].N)" $r[1].C
            Write-C " $($r[1].L)" "White"
            Write-C (" " * $rSpace) "Black"
            Write-C $rDesc "DarkGray"
            Write-C (" " * $rTail) "Black"
            Write-CL "║" "DarkGray"
        }
        Write-CL "  ╚$hbar╩$hbar╝" "DarkGray"
        Write-Host ""
        Write-C "  > " "Yellow"; $ch = Read-Host

        # Re-map choices to match old indices where logic is already correct
        # Old: 1=Dungeon 2=Market 3=Inventory 4=Rest 5=Stats 6=Quest 7=Guild 8=Quit 9=Save
        # New:
        #   1 => Dungeon           (was 1)
        #   2 => Daily Dungeon     (new)
        #   3 => Market            (was 2)
        #   4 => Inventory         (was 3)
        #   5 => Rest/Inn          (was 4)
        #   6 => Training Grounds  (new)
        #   7 => Quest Board       (was 6)
        #   8 => Guild Hall        (was 7)
        #   9 => Stats             (was 5)
        #   A => Achievements      (new)
        #   S => Save              (was 9)
        #   Q => Quit              (was 8)
        # PowerShell hash literals are case-insensitive, so we only need one entry per key.
        # Normalize single-letter inputs to upper-case before lookup.
        $map = @{
            "1" = "1"; "2" = "D"; "3" = "2"; "4" = "3"; "5" = "4"
            "6" = "T"; "7" = "6"; "8" = "7"; "9" = "5"
            "A" = "A"
            "S" = "9"
            "Q" = "8"
        }
        $chKey = if($ch){$ch.ToUpper()}else{""}
        $routed = if($map.ContainsKey($chKey)){$map[$chKey]}else{$ch}

        switch($routed){
            "1" {
                if(Test-Encumbered){
                    $cur = Get-CurrentCarryWeight
                    $max = Get-MaxCarryWeight $script:Player
                    clr
                    Write-Host ""
                    Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkRed"
                    Write-CL "  ║              T O O   E N C U M B E R E D                ║" "Red"
                    Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkRed"
                    Write-Host ""
                    Write-CL "  You're carrying $cur weight (max $max)." "Yellow"
                    Write-CL "  Sell loot at the Market or visit Inventory to drop items." "Gray"
                    Write-Host ""
                    Wait-Key
                } else {
                    Enter-Dungeon
                }
            }
            "D" {
                # Daily dungeon: Enter-Dungeon with double rewards flag
                if(Test-Encumbered){
                    $cur = Get-CurrentCarryWeight
                    $max = Get-MaxCarryWeight $script:Player
                    clr
                    Write-Host ""
                    Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkRed"
                    Write-CL "  ║              T O O   E N C U M B E R E D                ║" "Red"
                    Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkRed"
                    Write-Host ""
                    Write-CL "  You're carrying $cur weight (max $max)." "Yellow"
                    Write-CL "  The Daily herald frowns at your overloaded pack." "DarkGray"
                    Write-Host ""
                    Wait-Key
                    continue
                }
                $today = (Get-Date).ToString("yyyy-MM-dd")
                if($script:DailyDungeonDate -ne $today){
                    # Reset daily for new day
                    $script:DailyDungeonDate = $today
                    $script:DailyDungeonDone = $false
                }
                if($script:DailyDungeonDone){
                    clr
                    Write-CL "  The herald nods." "Gray"
                    Write-CL "  'You've already braved the Daily Dungeon today. Return tomorrow.'" "Yellow"
                    Wait-Key
                } else {
                    $script:DailyDungeonActive = $true
                    Enter-Dungeon
                    $script:DailyDungeonActive = $false
                }
            }
            "2" { Show-Market }
            "3" { Show-InventoryScreen }



                        "4" {
                clr
                Write-Host ""
                # 52-char-wide banner
                Write-CL "  ╔══════════════════════════════════════════════════╗" "DarkYellow"
                Write-CL "  ║          T H E   W E A R Y   L A N T E R N      ║" "Yellow"
                Write-CL "  ╚══════════════════════════════════════════════════╝" "DarkYellow"
                Write-Host ""
                # Hanging lantern (original art from v1.2)
                Write-CL "              _.._" "DarkYellow"
                Write-CL "            .' .-'``." "Yellow"
                Write-CL "           /  /      \" "Yellow"
                Write-CL "           |  |  0  ||" "DarkYellow"
                Write-CL "           \  \     /" "Yellow"
                Write-CL "            '._'-._'" "DarkYellow"
                Write-CL "               |  |" "DarkGray"
                Write-CL "             __|__|__" "DarkGray"
                Write-CL "            |________|" "DarkGray"
                Write-Host ""

                $p = $script:Player
                $hpMissing = $p.MaxHP - $p.HP
                $mpMissing = $p.MaxMP - $p.MP

                # Stats box (interior 44 chars)
                $sBar = "─" * 44
                Write-CL "  ┌$sBar┐" "DarkGray"
                $line1 = "Current HP: $($p.HP)/$($p.MaxHP)"
                $pad1 = 42 - $line1.Length
                if($pad1 -lt 0){$pad1=0}
                Write-C  "  │ " "DarkGray"; Write-C $line1 "Green"; Write-CL ("$(' ' * $pad1) │") "DarkGray"
                $line2 = "Current MP: $($p.MP)/$($p.MaxMP)"
                $pad2 = 42 - $line2.Length
                if($pad2 -lt 0){$pad2=0}
                Write-C  "  │ " "DarkGray"; Write-C $line2 "Cyan"; Write-CL ("$(' ' * $pad2) │") "DarkGray"
                $line3 = "Gold: $($script:Gold)g"
                $pad3 = 42 - $line3.Length
                if($pad3 -lt 0){$pad3=0}
                Write-C  "  │ " "DarkGray"; Write-C $line3 "Yellow"; Write-CL ("$(' ' * $pad3) │") "DarkGray"
                Write-CL "  └$sBar┘" "DarkGray"
                Write-Host ""

                if($p.HP -eq $p.MaxHP -and $p.MP -eq $p.MaxMP){
                    Write-CL "  The innkeeper looks at you:" "DarkGray"
                    Write-CL "  'You look well rested already, friend!'" "Yellow"
                    Write-Host ""
                    Wait-Key
                } else {
                    Write-CL "  The innkeeper greets you warmly:" "DarkGray"
                    Write-CL "  'Welcome, weary traveler! What'll it be?'" "Yellow"
                    Write-Host ""
                    # Menu box (interior 54 chars). Each line: " [N] Label<pad>-  DetailText<pad-end> │"
                    $mBar = "─" * 54
                    $options = @(
                        @{N="[1]"; Label="Quick Nap";    Color="Green";    Detail="15g  (50% HP/MP)"}
                        @{N="[2]"; Label="Full Rest";    Color="Cyan";     Detail="30g  (100% HP/MP)"}
                        @{N="[3]"; Label="Royal Suite";  Color="Magenta";  Detail="60g  (Full + ATK/DEF)"}
                        @{N="[0]"; Label="Leave";        Color="DarkGray"; Detail=""}
                    )
                    Write-CL "  ┌$mBar┐" "DarkGray"
                    foreach($opt in $options){
                        $head    = " $($opt.N) $($opt.Label)"
                        $headPad = 22 - $head.Length
                        if($headPad -lt 1){$headPad = 1}
                        $midSep  = if($opt.Detail){"-  "}else{"   "}
                        $midLen  = 3
                        $tailLen = 54 - $head.Length - $headPad - $midLen - $opt.Detail.Length - 1
                        if($tailLen -lt 0){$tailLen = 0}

                        Write-C "  │" "DarkGray"
                        Write-C " $($opt.N)" "White"
                        Write-C " $($opt.Label)" $opt.Color
                        Write-C (" " * $headPad) "Black"
                        if($opt.Detail){
                            Write-C $midSep "DarkGray"
                            Write-C $opt.Detail "White"
                        } else {
                            Write-C (" " * $midLen) "Black"
                        }
                        Write-C (" " * $tailLen) "Black"
                        Write-CL " │" "DarkGray"
                    }
                    Write-CL "  └$mBar┘" "DarkGray"
                    Write-Host ""
                    Write-C "  > " "Yellow"; $restChoice = Read-Host

                    switch($restChoice){
                        "1" {
                            if($script:Gold -ge 15){
                                $script:Gold -= 15
                                $healAmt = [math]::Floor($p.MaxHP * 0.5)
                                $manaAmt = [math]::Floor($p.MaxMP * 0.5)
                                $p.HP = [math]::Min($p.HP + $healAmt, $p.MaxHP)
                                $p.MP = [math]::Min($p.MP + $manaAmt, $p.MaxMP)
                                Write-Host ""
                                Write-CL "  You take a quick nap on a straw bed..." "DarkGray"
                                Write-CL "  zzz..." "DarkCyan"
                                Start-Sleep -Milliseconds 800
                                Write-CL "  zzzZZZ..." "Cyan"
                                Start-Sleep -Milliseconds 800
                                Write-Host ""
                                Write-CL "  Recovered $healAmt HP and $manaAmt MP!" "Green"
                                Write-CL "  HP: $($p.HP)/$($p.MaxHP)  MP: $($p.MP)/$($p.MaxMP)" "White"
                            } else {
                                Write-CL "  'Sorry friend, no coin, no pillow.'" "Red"
                            }
                            Wait-Key
                        }
                        "2" {
                            if($script:Gold -ge 30){
                                $script:Gold -= 30
                                $p.HP = $p.MaxHP
                                $p.MP = $p.MaxMP
                                Write-Host ""
                                Write-CL "  You settle into a comfortable bed..." "DarkGray"
                                Write-CL "  zzz..." "DarkCyan"
                                Start-Sleep -Milliseconds 600
                                Write-CL "  zzzZZZ..." "Cyan"
                                Start-Sleep -Milliseconds 600
                                Write-CL "  ZZZZZZ..." "White"
                                Start-Sleep -Milliseconds 600
                                Write-Host ""
                                Write-CL "  Fully restored! HP: $($p.MaxHP)/$($p.MaxHP)  MP: $($p.MaxMP)/$($p.MaxMP)" "Green"
                            } else {
                                Write-CL "  'Sorry friend, no coin, no pillow.'" "Red"
                            }
                            Wait-Key
                        }
                        "3" {
                            if($script:RoyalSuiteUses -ge 3){
                                Write-CL "  'You've enjoyed our finest rooms before...'" "DarkGray"
                                Write-CL "  'The enchantments no longer affect you, friend.'" "DarkGray"
                                Write-CL "  (Royal Suite stat boost capped at 3 uses)" "DarkYellow"
                                Wait-Key
                            }
                            elseif($script:Gold -ge 60){
                                $script:Gold -= 60
                                $p.HP = $p.MaxHP
                                $p.MP = $p.MaxMP
                                Write-Host ""
                                Write-CL "  You sink into a luxurious feather bed..." "DarkGray"
                                Write-CL "  A warm bath, fine wine, enchanted candles..." "DarkMagenta"
                                Start-Sleep -Milliseconds 600
                                Write-CL "  zzz..." "DarkCyan"
                                Start-Sleep -Milliseconds 600
                                Write-CL "  zzzZZZ..." "Cyan"
                                Start-Sleep -Milliseconds 600
                                Write-CL "  ZZZZZZ..." "White"
                                Start-Sleep -Milliseconds 800
                                Write-Host ""
                                Write-CL "  You awaken feeling POWERFUL!" "Yellow"
                                Write-Host ""

                                $p.ATK += 3
                                $p.DEF += 3
                                $script:RoyalSuiteUses++
                                Write-CL "  Fully restored! HP: $($p.MaxHP)/$($p.MaxHP)  MP: $($p.MaxMP)/$($p.MaxMP)" "Green"
                                Write-CL "  ATK +3 and DEF +3 from the enchanted rest!" "Magenta"
                                Write-CL "  (Permanent stat boost!)" "DarkMagenta"
                            } else {
                                Write-CL "  'The royal suite requires deeper pockets, friend.'" "Red"
                            }
                            Wait-Key
                        }
                        "0" { }
                        default { }
                    }
                }
            }

            "5" {
                clr
                $p2 = $script:Player
                $wAtk = Get-TotalWeaponATK
                $aDef = Get-TotalArmorDEF
                $mBonus = Get-WeaponMAGBonus
                $cb = Get-WeaponClassBonus

                Write-CL "  ╔══════════════════════════════════════════════════╗" "Cyan"
                Write-CL "  ║  $($p2.Name) - Level $($script:PlayerLevel)" "Cyan"
                Write-CL "  ╚══════════════════════════════════════════════════╝" "Cyan"
                Write-Host ""

                # ── Core Stats ──
                Write-CL "  ── STATS ──" "Yellow"
                Write-C "  HP:  $($p2.HP) / $($p2.MaxHP)" "Green"
                Write-CL "     MP:  $($p2.MP) / $($p2.MaxMP)" "Cyan"
                Write-Host ""

                $atkTotal = $p2.ATK + $wAtk
                $defTotal = $p2.DEF + $aDef
                $magTotal = $p2.MAG + $mBonus

                # Training-derived bonuses (already baked into $p2.STAT, but show breakdown)
                # Per Show-TrainingGrounds: ATK +2, DEF +2, SPD +1, MAG +2, HP +10, MP +5 per pt
                $tp = $script:TrainingPoints
                $trnATK = if($tp){$tp.ATK * 2}else{0}
                $trnDEF = if($tp){$tp.DEF * 2}else{0}
                $trnSPD = if($tp){$tp.SPD * 1}else{0}
                $trnMAG = if($tp){$tp.MAG * 2}else{0}

                Write-C "  ATK: $($p2.ATK)" "White"
                if($trnATK -gt 0){ Write-C " (+$trnATK trn)" "Magenta" }
                if($wAtk -gt 0){
                    Write-C " + $wAtk wpn" "DarkCyan"
                    if($cb -gt 0){ Write-C " ($cb class)" "Green" }
                }
                Write-CL "  = $atkTotal total" "Yellow"

                Write-C "  DEF: $($p2.DEF)" "White"
                if($trnDEF -gt 0){ Write-C " (+$trnDEF trn)" "Magenta" }
                if($aDef -gt 0){ Write-C " + $aDef armor" "DarkCyan" }
                Write-CL "  = $defTotal total" "Yellow"

                Write-C "  SPD: $($p2.SPD)" "White"
                if($trnSPD -gt 0){ Write-C " (+$trnSPD trn)" "Magenta" }
                Write-Host ""

                Write-C "  MAG: $($p2.MAG)" "White"
                if($trnMAG -gt 0){ Write-C " (+$trnMAG trn)" "Magenta" }
                if($mBonus -gt 0){ Write-C " + $mBonus staff" "DarkCyan" }
                Write-CL "  = $magTotal total" "Yellow"

                Write-Host ""
                Write-CL "  XP:  $($script:XP) / $($script:XPToNext)" "DarkCyan"
                Write-CL "  Kills: $($script:KillCount) (total: $($script:TotalKills))" "DarkGray"
                Write-C  "  Lockpicks: " "DarkGray"; Write-CL "$($script:Lockpicks)" "Cyan"
                Write-C  "  Dungeon Streak: " "DarkGray"
                $curStreakColor = if($script:Streak -ge 3){"Yellow"}elseif($script:Streak -ge 1){"White"}else{"DarkGray"}
                Write-C  "$($script:Streak)" $curStreakColor
                Write-C  "   Best: " "DarkGray"
                $bestColor = if($script:BestStreak -ge 5){"Magenta"}elseif($script:BestStreak -ge 3){"Yellow"}else{"White"}
                Write-CL "$($script:BestStreak)" $bestColor
                Write-CL "  Bosses Defeated: $($script:BossesDefeated)" "DarkGray"
                Write-Host ""

                # ── Weapon Affinity Tip ──
                Write-CL "  ┌──────────────────────────────────────────────────┐" "DarkGray"
                Write-CL "  │  Your class affinity: $($script:PlayerClass)" "DarkGray"
                Write-CL "  │  Weapons matching your class give bonus ATK.     │" "DarkGray"
                Write-CL "  └──────────────────────────────────────────────────┘" "DarkGray"
                Write-Host ""

                # ── Abilities ──
                $abilTier = Get-AbilityTier $script:PlayerLevel
                $tierLabel = if($abilTier -gt 0){" (Tier $abilTier)"}else{""}
                Write-CL "  ── ABILITIES$tierLabel ──" "Yellow"
                foreach($abBase in $p2.Abilities){
                    $ab = Get-ScaledAbility $abBase $script:PlayerLevel
                    $costStr = if($ab.Type -eq "Sacrifice"){"HP:15%"}else{"MP:$($ab.Cost)"}
                    $effStr = if($ab.Effect -and $ab.Effect -ne "None" -and $ab.Effect -ne "SacrificeHP"){" [$($ab.Effect)]"}else{""}
                    Write-CL "    $($ab.Name)  |  $costStr  |  $($ab.Type)  |  Pwr:$($ab.Power)$effStr" "Cyan"
                }
                if($abilTier -lt 3){
                    $nextLevel = if($abilTier -eq 0){5}elseif($abilTier -eq 1){10}else{15}
                    Write-CL "    (Next ability upgrade at level $nextLevel)" "DarkGray"
                }
                Wait-Key
            }

            "6" { Show-QuestBoard }
            "7" { Show-GuildHall }

            "T" { Show-TrainingGrounds }
            "A" { Show-AchievementsMenu }

            "8" {
                Write-C "  Really quit? (y/n): " "Red"; $confirm = Read-Host
                if($confirm -eq 'y'){
                    $script:GameRunning = $false
                    clr
                    Write-CL "" "White"
                    Write-CL "  Thanks for playing DEPTHS OF POWERSHELL!" "Yellow"
                    Write-CL "  Final Stats: Level $($script:PlayerLevel) $($p.Name) | Gold: $($script:Gold) | Dungeons: $($script:DungeonLevel)" "Gray"
                    Write-Host ""
                }
            }

            "9" {
                clr
                Write-CL "" "White"
                Write-CL "  ╔════════════════════════════════════════════════════╗" "DarkYellow"
                Write-CL "  ║            S A V E   G A M E                       ║" "Yellow"
                Write-CL "  ╚════════════════════════════════════════════════════╝" "DarkYellow"
                Write-Host ""
                Write-CL "  Preparing save code..." "DarkGray"
                Write-Host ""

                # Convert loot to gold and tell the player
                $lootVal = 0
                foreach($item in $script:Inventory){ $lootVal += $item.Value }
                if($lootVal -gt 0){
                    Write-CL "  Loot inventory converted to gold: +${lootVal}g" "Yellow"
                }
                if($script:Quests.Count -gt 0){
                    Write-CL "  Active quests will not be saved." "DarkGray"
                }
                Write-Host ""

                $code = Save-Game
                Write-CL "  ┌──────────────────────────────────────────────────────┐" "Green"
                Write-CL "  │  YOUR SAVE CODE (copy this entire string):           │" "Green"
                Write-CL "  └──────────────────────────────────────────────────────┘" "Green"
                Write-Host ""
                Write-CL "  $code" "Cyan"
                Write-Host ""
                # ── Try to auto-copy to clipboard (Windows PS 5.1 has Set-Clipboard) ──
                $clipboardOk = $false
                try {
                    Set-Clipboard -Value $code -ErrorAction Stop
                    $clipboardOk = $true
                } catch {
                    $clipboardOk = $false
                }
                if($clipboardOk){
                    Write-CL "  ✔ Save code copied to your clipboard automatically!" "Green"
                } else {
                    Write-CL "  (Clipboard copy unavailable — select the text manually.)" "DarkGray"
                }
                Write-Host ""
                Write-CL "  Write down or paste this code. You can use it" "DarkGray"
                Write-CL "  to continue your game next time you play." "DarkGray"
                Write-Host ""
                Write-CL "  NOTE: Loot was converted to gold. Quests were reset." "DarkYellow"
                Write-Host ""
                Read-Host "  Press Enter to continue"
            }
        }
    }
}



# ─── CHANGELOG ───────────────────────────────────────────────────
# Paginated release notes. Grouped into three categories. Shown from the
# launch menu, returns back to the launch menu when dismissed.
function Show-Changelog {
    $pages = @(
        @{Title="NEW FEATURES"; Color="Green"; Lines=@(
            "  COMBAT & ENEMIES"
            "    * Enemies can now CRITICAL HIT (4% base, scaling with"
            "      dungeon depth, +3 mini-boss / +6 boss, capped at 30%)."
            "    * Enemies have new ability types: damage, self-buffs, and"
            "      self-heals. Higher-level normal enemies and all bosses"
            "      gain extra abilities like Iron Skin, Blood Mend, etc."
            "    * Smart enemy AI throttles ability use (~35% damage abil,"
            "      ~30% buff chance, heals only when below 30% HP) so"
            "      combat feels strategic, not spammy."
            "    * Per-ability COOLDOWNS for the player too. Each ability"
            "      tracks its own cooldown after use; menu shows remaining"
            "      turns. No more spamming your strongest spell."
            ""
            "  RENDERING"
            "    * Frame-buffer rendering for the dungeon view: only the"
            "      cells that change are repainted, no more full-screen"
            "      flash on every step. Auto-detects window size and"
            "      enables when terminal is at least 80x32."
            "    * Live window-resize detection — resize your terminal"
            "      mid-dungeon and the buffer adapts."
            "    * Helpful in-game tip if your window is too small to use"
            "      buffered mode (suggests maximizing)."
            ""
            "  INVENTORY & GEAR"
            "    * Unified loot screen with arrow-key navigation, Space"
            "      to toggle, V for item details, A to take-all, Enter"
            "      to confirm. Gold flows through it too (0 weight)."
            "    * Drop screen rebuilt with the same UX. Drop weapons,"
            "      armor, loot, potions, throwables — and lockpicks with"
            "      a quantity slider (+/-)."
            "    * Equipped items shown but locked at the top of the drop"
            "      screen as a reminder."
            "    * NEW: [E] Equip from Bag in the inventory screen. Stows"
            "      currently-equipped piece automatically."
            "    * NEW: [I] Inventory works mid-dungeon (out of combat)."
            "    * NEW: [J] Quest Log in the dungeon — view all active"
            "      quests with progress bars without returning to town."
            "    * Lockpicks now have weight (1 each). Chest bonus picks"
            "      come as a Lockpick Bundle in the loot screen."
            "    * Potions and throwables now have weight (1 each) and"
            "      are droppable through the drop screen."
            ""
            "  QUESTS & PROGRESSION"
            "    * 6 new quest types: Critical Hits, Lockpicker, Loot"
            "      Hunter, Survivor (boss room above 50% HP), Bare-Handed"
            "      Kills, Repair gear at the blacksmith."
            "    * Active quest cap raised from 3 to 5."
            "    * Quest Board now offers 5 random quests at a time."
            "    * 13 new achievements: First Crit, Crit Master, Crit Lord,"
            "      Locksmith, Master Thief, Pack Rat, Hoarder, Iron Fist,"
            "      Untouched, Stance Shifter, True Scholar, Gear Guru,"
            "      High Roller, Deepest Dive."
        )}
        @{Title="GAMEPLAY IMPROVEMENTS"; Color="Cyan"; Lines=@(
            "  GEAR ACQUISITION FLOW"
            "    * No more 20% sell-on-replace refund. Gear stays in your"
            "      possession when you buy/find a new piece."
            "    * Buying or finding gear with a slot occupied prompts:"
            "      'Equip now (old goes to bag)' or 'Stow new in bag'."
            "    * Old equipped piece moves to your inventory bag with"
            "      its weight applied. Sell at the Market when you want."
            "    * Unequip works the same way — moves to bag, no refund."
            "    * Applies to Market, Wandering Merchant, Flying Dutchman,"
            "      and all gear-acquisition events."
            ""
            "  MOVEMENT & CONTROLS"
            "    * Movement throttle (~7 steps/sec max) prevents keyboard"
            "      auto-repeat from zooming you across the dungeon."
            "    * Non-movement keys (P, I, J, Q) bypass the throttle —"
            "      always instant."
            "    * Dungeon controls bar split into two lines for clarity."
            ""
            "  HUD & UI"
            "    * Combat HUD shows enemy crit % alongside enemy hit %."
            "    * Inventory display: per-item weight column and total"
            "      weight footer. Combined Potions+Throwables section."
            "    * Town Square no longer shows 'Lv1' on Enter Dungeon"
            "      since dungeons scale to your player level."
            "    * Quest line removed from in-dungeon HUD — press [J]"
            "      for the full quest journal instead."
        )}
        @{Title="BUG FIXES & QUALITY OF LIFE"; Color="Yellow"; Lines=@(
            "  LOOT SCREEN OVERHAUL"
            "    * Fixed 'take all' button silently failing on multi-item"
            "      drops (root cause: array type coercion on PowerShell"
            "      hosts that returned booleans as scalars)."
            "    * Fixed 'You walk away empty-handed' wording when you"
            "      explicitly took nothing."
            "    * Removed redundant [N] none and [S] skip buttons."
            ""
            "  RENDERING FIXES"
            "    * Fixed black space below 3D viewport when minimap was"
            "      shorter than the view. Switched to a windowed minimap"
            "      with fog of war that fits within the viewport rows."
            "    * Fixed screen tearing in small terminals — buffered"
            "      mode is now strictly gated on 80x32 minimum."
            ""
            "  CLASS SELECTION FIX"
            "    * Fixed bug where any number you picked at character"
            "      creation defaulted to Knight. ConvertTo-SafeInt's"
            "      `\$Input` parameter conflicted with PowerShell's reserved"
            "      automatic variable. Renamed to `\$Value` everywhere."
            ""
            "  LOCKPICKING REBALANCE"
            "    * Timing bar now reflects ACTUAL sweet-spot proximity"
            "      (was previously a meaningless secondary sin wave)."
            "    * Sweet zone widened from 1 row to 3 rows for fairer"
            "      timing windows."
            ""
            "  TUTORIAL"
            "    * Added pages on Enemy AI, Quests, and updated existing"
            "      pages to reflect new mechanics. Removed outdated"
            "      'hold key down' note (movement is now snappy)."
        )}
    )

    foreach($page in $pages){
        clr
        Write-Host ""
        Write-CL "  ╔══════════════════════════════════════════════════════════════════╗" "DarkMagenta"
        Write-CL "  ║                    C H A N G E L O G   -   v1.3                  ║" "Magenta"
        Write-CL "  ╚══════════════════════════════════════════════════════════════════╝" "DarkMagenta"
        Write-Host ""
        Write-CL "  >>> $($page.Title)" $page.Color
        Write-CL ("  " + ("-" * 60)) "DarkGray"
        Write-Host ""
        foreach($line in $page.Lines){
            Write-CL $line "Gray"
        }
        Write-Host ""
        Read-Host "  [Press Enter to continue]" | Out-Null
    }
}



# ─── ENTRY POINT ─────────────────────────────────────────────────
function Start-Game {
    $script:GameRunning = $true
    clr

    # Title screen
    Write-Host ""
    Write-CL "     ____  _____ ____ _____ _   _ ____" "DarkCyan"
    Write-CL "    |  _ \| ____|  _ \_   _| | | / ___|" "Cyan"
    Write-CL "    | | | |  _| | |_) || | | |_| \___ \" "Cyan"
    Write-CL "    | |_| | |___|  __/ | | |  _  |___) |" "Cyan"
    Write-CL "    |____/|_____|_|    |_| |_| |_|____/" "DarkCyan"
    Write-Host ""
    Write-CL "          O F   P O W E R S H E L L" "DarkYellow"
    Write-Host ""
    Write-CL "                  Version 1.3" "DarkGray"
    Write-Host ""
    Write-CL "    A first-person dungeon crawler" "DarkGray"
    Write-CL "    with turn-based RPG combat" "DarkGray"
    Write-Host ""
    Wait-Key

    # ═══════════════════════════════════════════════════
    #  NEW / LOAD / CHANGELOG PROMPT
    # ═══════════════════════════════════════════════════
    $menuLoop = $true
    while($menuLoop){
        clr
        Write-Host ""
        Write-CL "  ╔══════════════════════════════════════════════════╗" "DarkYellow"
        Write-CL "  ║         DEPTHS OF POWERSHELL                     ║" "Yellow"
        Write-CL "  ║              Version 1.3                       ║" "DarkGray"
        Write-CL "  ╚══════════════════════════════════════════════════╝" "DarkYellow"
        Write-Host ""
        Write-CL "  ┌─────────────────────────────────────────┐" "DarkGray"
        Write-C  "  │  " "DarkGray"; Write-C "[1]" "Green";  Write-CL " New Game                          │" "White"
        Write-C  "  │  " "DarkGray"; Write-C "[2]" "Cyan";   Write-CL " Load Save Code                    │" "White"
        Write-C  "  │  " "DarkGray"; Write-C "[3]" "Magenta";Write-CL " View Changelog                    │" "White"
        Write-CL "  └─────────────────────────────────────────┘" "DarkGray"
        Write-Host ""
        Write-C "  > " "Yellow"; $startChoice = Read-Host

        if($startChoice -eq "3"){
            Show-Changelog
            continue  # back to menu
        }
        $menuLoop = $false  # fall through to handling [1] or [2]
    }

    if($startChoice -eq "2"){
        # ── LOAD PATH ──
        clr
        Write-Host ""
        Write-CL "  ╔══════════════════════════════════════════════════╗" "DarkCyan"
        Write-CL "  ║         L O A D   G A M E                        ║" "Cyan"
        Write-CL "  ╚══════════════════════════════════════════════════╝" "DarkCyan"
        Write-Host ""
        Write-CL "  Paste or type your save code below." "DarkGray"
        Write-CL "  (It's the Base64 string you copied last time)" "DarkGray"
        Write-Host ""
        Write-C "  Code: " "Yellow"
        $code = Read-Host

        # Trim whitespace in case they accidentally copied spaces
        $code = $code.Trim()

        $result = Load-Game $code

        if($result.Success){
            Write-Host ""
            Write-CL "  ╔══════════════════════════════════════╗" "Green"
            Write-CL "  ║       SAVE LOADED SUCCESSFULLY!       ║" "Green"
            Write-CL "  ╚══════════════════════════════════════╝" "Green"
            Write-Host ""
            $p = $script:Player
            Write-CL "  Welcome back, $($p.Name)!" "Yellow"
            Write-CL "  Class: $($script:PlayerClass)  Level: $($script:PlayerLevel)" "DarkGray"
            Write-CL "  HP: $($p.HP)/$($p.MaxHP)  MP: $($p.MP)/$($p.MaxMP)" "DarkGray"
            Write-CL "  Gold: $($script:Gold)g" "Yellow"
            Write-CL "  Dungeon Level: $($script:DungeonLevel)" "DarkGray"
            if($script:EquippedWeapon){
                Write-CL "  Weapon: $($script:EquippedWeapon.Name)" "Cyan"
            }
            if($script:Partner){
                Write-CL "  Ally: $($script:Partner.Name) ($($script:Partner.Class))" "Green"
            }
            Write-Host ""
            Write-CL "  Your loot was converted to gold." "DarkYellow"
            Write-CL "  Quests have been reset - visit the Quest Board!" "DarkYellow"
            Write-Host ""
            Wait-Key
            # Skip lore and character select, go straight to town
            Show-MainMenu
            return
        } else {
            # Load failed — tell them why and fall through to new game
            Write-Host ""
            Write-CL "  ╔══════════════════════════════════════╗" "Red"
            Write-CL "  ║         LOAD FAILED                   ║" "Red"
            Write-CL "  ╚══════════════════════════════════════╝" "Red"
            Write-CL "  $($result.Error)" "DarkRed"
            Write-Host ""
            Write-CL "  Starting a new game instead..." "DarkGray"
            Wait-Key
        }
    }

    # ── NEW GAME PATH (lore + character select, same as before) ──

    # ── Story Intro ──
    clr
    Write-Host ""
    Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkCyan"
    Write-CL "  ║                 T H E   L O R E                          ║" "Cyan"
    Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkCyan"
    Write-Host ""
    Write-CL "  In the age before automation, the realm was at peace." "Gray"
    Write-CL "  Scripts ran on time. Logs were clean. Cron jobs never failed." "Gray"
    Write-Host ""
    Start-Sleep -Milliseconds 1200
    Write-CL "  Then came the Great Deprecated Update." "DarkYellow"
    Write-Host ""
    Start-Sleep -Milliseconds 1200
    Write-CL "  A careless wizard cast an untested script upon the kingdom's" "Gray"
    Write-CL "  core infrastructure. No -WhatIf. No -Confirm. Just..." "Gray"
    Write-Host ""
    Start-Sleep -Milliseconds 800
    Write-CL "    Invoke-Catastrophe -Force -NoRollback" "Red"
    Write-Host ""
    Start-Sleep -Milliseconds 1500
    Write-CL "  The earth split open. Beneath the Server Halls of the old" "Gray"
    Write-CL "  kingdom, a vast dungeon materialized — twisting corridors" "Gray"
    Write-CL "  of corrupted memory, haunted by rogue processes and daemon" "Gray"
    Write-CL "  threads that refused to terminate." "Gray"
    Write-Host ""
    Start-Sleep -Milliseconds 1200
    Write-CL "  They call it... the Depths of PowerShell." "Cyan"
    Write-Host ""
    Start-Sleep -Milliseconds 1500
    Wait-Key
    clr
    Write-Host ""
    Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkCyan"
    Write-CL "  ║                 T H E   L O R E                          ║" "Cyan"
    Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkCyan"
    Write-Host ""
    Write-CL "  The Guild of SysAdmins posted a bounty:" "DarkYellow"
    Write-Host ""
    Write-CL "  ┌──────────────────────────────────────────────────────┐" "Yellow"
    Write-CL "  │                                                      │" "Yellow"
    Write-CL "  │   WANTED: Brave soul to descend into the Depths.     │" "Yellow"
    Write-CL "  │                                                      │" "Yellow"
    Write-CL "  │   Objective: Reach the bottom. Find the root shell.  │" "Yellow"
    Write-CL "  │   Terminate the runaway process known only as...     │" "Yellow"
    Write-CL "  │                                                      │" "Yellow"
    Write-C  "  │           " "Yellow"
    Write-C "the Lich King of Legacy Code" "Red"
    Write-CL "             │" "Yellow"
    Write-CL "  │                                                      │" "Yellow"
    Write-CL "  │   WARNING: This task cannot be run as a background   │" "Yellow"
    Write-CL "  │   job. You must go in person.                        │" "Yellow"
    Write-CL "  │                                                      │" "Yellow"
    Write-CL "  │   Payment: All the gold your pipeline can carry.     │" "Yellow"
    Write-CL "  │                                                      │" "Yellow"
    Write-CL "  └──────────────────────────────────────────────────────┘" "Yellow"
    Write-Host ""
    Start-Sleep -Milliseconds 1000
    Write-CL "  You step forward. You have no -ErrorAction SilentlyContinue." "Gray"
    Write-CL "  If you fail, the exception will not be caught." "Gray"
    Write-Host ""
    Start-Sleep -Milliseconds 1200
    Write-CL "  There is only one way out: through." "White"
    Write-Host ""
    Wait-Key

    Show-CharacterSelect

    # ── Tutorial offer (new game only) ──
    if(-not $script:TutorialSeen){
        clr
        Write-Host ""
        Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkGreen"
        Write-CL "  ║             W E L C O M E ,   A D V E N T U R E R      ║" "Green"
        Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkGreen"
        Write-Host ""
        Write-CL "  This is your first time in the Depths." "White"
        Write-Host ""
        Write-C "  Would you like a quick tutorial? (y/n): " "Yellow"
        $tut = Read-Host
        if($tut -eq 'y' -or $tut -eq 'Y'){
            Show-Tutorial
        }
        $script:TutorialSeen = $true
    }

    Show-MainMenu
}

# ─── INVENTORY SCREEN ─────────────────────────────────────────────
# Extracted so it can be called from both Town Square ([3]) and from
# inside a dungeon ([I] key). Same UI, same options.
# ─── QUEST LOG ────────────────────────────────────────────────────
# Quick view of all active quests with progress bars. Called from the
# dungeon's [J] key and the town square's quest board for at-a-glance
# tracking. Read-only — accept/turn-in still happens at the board.
function Show-QuestLog {
    clr
    Write-Host ""
    Write-CL "  ╔══════════════════════════════════════════════════════════════════╗" "DarkYellow"
    Write-CL "  ║                       Q U E S T   L O G                          ║" "Yellow"
    Write-CL "  ╚══════════════════════════════════════════════════════════════════╝" "DarkYellow"
    Write-Host ""

    if(-not $script:Quests -or $script:Quests.Count -eq 0){
        Write-CL "  No active quests. Visit the Quest Board in town to accept some." "DarkGray"
        Write-Host ""
        Wait-Key
        return
    }

    $active = @($script:Quests | Where-Object { -not $_.TurnedIn })
    if($active.Count -eq 0){
        Write-CL "  All quests turned in! Visit the Quest Board for new ones." "DarkGray"
        Write-Host ""
        Wait-Key
        return
    }

    $i = 1
    foreach($q in $active){
        $statusTag = if($q.Complete){"[READY TO TURN IN]"}else{"[$($q.Progress)/$($q.TargetCount)]"}
        $statusColor = if($q.Complete){"Green"}else{"Yellow"}
        Write-C "  [$i] " "DarkGray"
        Write-C $q.Desc "White"
        Write-C "  " "DarkGray"
        Write-CL $statusTag $statusColor

        # Progress bar (10 cells)
        if(-not $q.Complete -and $q.TargetCount -gt 0){
            $pct = $q.Progress / $q.TargetCount
            $filled = [math]::Floor($pct * 20)
            if($filled -lt 0){$filled = 0}; if($filled -gt 20){$filled = 20}
            $empty = 20 - $filled
            Write-C "      [" "DarkGray"
            Write-C ('=' * $filled) "Green"
            Write-C ('-' * $empty) "DarkGray"
            Write-C "]" "DarkGray"
            Write-CL "  Reward: $($q.RewardGold)g + $($q.RewardXP) XP" "DarkYellow"
        } else {
            Write-CL "      Reward: $($q.RewardGold)g + $($q.RewardXP) XP" "DarkYellow"
        }
        Write-Host ""
        $i++
    }

    Write-CL "  Turn in completed quests at the Quest Board in town." "DarkGray"
    Write-Host ""
    Wait-Key
}

function Show-InventoryScreen {
    $invLoop = $true
    while($invLoop){
        clr
        Write-Host ""
        # ── Consistent 60-char-wide boxes with interior 58 ──
        # Pattern: "  ║" + content(58 chars exactly) + "║"
        # Where content starts with a space and ends with space padding
        $BoxW = 58              # interior width
        $barH = "═" * $BoxW     # horizontal bar
        # Helper: pad a visible-length string to exactly $BoxW chars
        function Pad-Box {
            param([string]$s,[int]$width=$BoxW)
            if($s.Length -ge $width){
                return $s.Substring(0,$width)
            }
            return $s + (" " * ($width - $s.Length))
        }

        # 60-char banner
        Write-CL ("  ╔" + $barH + "╗") "DarkCyan"
        $title = " I N V E N T O R Y "
        $tSpace = [math]::Floor(($BoxW - $title.Length) / 2)
        $tLine  = (" " * $tSpace) + $title
        Write-C "  ║" "DarkCyan"
        Write-C (Pad-Box $tLine) "Cyan"
        Write-CL "║" "DarkCyan"
        Write-CL ("  ╚" + $barH + "╝") "DarkCyan"
        Write-Host ""

        # ── Character summary line (class shown ONCE: $p.Name IS the class name) ──
        $p = $script:Player
        $wepATK = Get-TotalWeaponATK
        $armorDEF = Get-TotalArmorDEF
        $magBonus = Get-WeaponMAGBonus

        Write-C "  $($p.Name)" "Green"
        $curW = Get-CurrentCarryWeight
        $maxW = Get-MaxCarryWeight $script:Player
        $weightColor = if($curW -gt $maxW){"Red"}elseif($curW -gt ($maxW * 0.85)){"Yellow"}else{"Green"}
        Write-CL "   Lv$($script:PlayerLevel)  |  Gold: $($script:Gold)g  |  Lockpicks: $($script:Lockpicks)" "DarkGray"
        Write-C  "   Carry: " "DarkGray"
        Write-CL "$curW / $maxW" $weightColor
        if($script:RepairKits -gt 0 -or $script:ExtraStrongPotions -gt 0){
            Write-C  "   Special items: " "DarkGray"
            if($script:RepairKits -gt 0){
                Write-C "Repair Kits x$($script:RepairKits)  " "Cyan"
            }
            if($script:ExtraStrongPotions -gt 0){
                Write-C "Extra Strong Potions x$($script:ExtraStrongPotions)" "Magenta"
            }
            Write-Host ""
        }
        Write-Host ""

        # ── Equipped Weapon ──
        Write-CL ("  ╔" + $barH + "╗") "DarkYellow"
        # Header row
        Write-C "  ║" "DarkYellow"
        Write-C (Pad-Box " W E A P O N") "Yellow"
        Write-CL "║" "DarkYellow"
        Write-CL ("  ╠" + $barH + "╣") "DarkYellow"
        # Body row
        if($script:EquippedWeapon){
            $w = $script:EquippedWeapon
            $cb = Get-WeaponClassBonus
            $cbStr   = if($cb -gt 0){" [+$cb class bonus]"}else{""}
            $perkStr = if($w.Perk){" [$($w.Perk) $($w.PerkChance)%]"}else{""}
            $magStr  = if($w.MAGBonus){" [MAG+$($w.MAGBonus)]"}else{""}
            $durStr  = " " + (Format-Durability $w)  # leading space separator
            $durColr = Get-DurabilityColor $w
            # Render colored segments inline, then compute remaining pad
            $emitted = 0
            Write-C "  ║" "DarkYellow"
            Write-C " $($w.Name)" "Cyan";     $emitted += 1 + $w.Name.Length
            Write-C "  ATK+$($w.ATK)" "White"; $emitted += 6 + "$($w.ATK)".Length
            if($cbStr){   Write-C $cbStr "Green";     $emitted += $cbStr.Length }
            if($perkStr){ Write-C $perkStr "DarkRed"; $emitted += $perkStr.Length }
            if($magStr){  Write-C $magStr "Magenta";  $emitted += $magStr.Length }
            if($durStr.Trim()){ Write-C $durStr $durColr; $emitted += $durStr.Length }
            $remaining = $BoxW - $emitted
            if($remaining -lt 0){ $remaining = 0 }
            Write-C (" " * $remaining) "Black"
            Write-CL "║" "DarkYellow"
        } else {
            Write-C "  ║" "DarkYellow"
            Write-C (Pad-Box " Bare Hands") "DarkGray"
            Write-CL "║" "DarkYellow"
        }
        Write-CL ("  ╚" + $barH + "╝") "DarkYellow"
        Write-Host ""

        # ── Equipped Armor ──
        Write-CL ("  ╔" + $barH + "╗") "DarkCyan"
        # Header with right-aligned DEF total
        $armorHdr = "A R M O R"
        $armorDefStr = "DEF: +$armorDEF "
        $midLen = $BoxW - 1 - $armorHdr.Length - $armorDefStr.Length  # 1 leading space
        if($midLen -lt 1){$midLen = 1}
        Write-C "  ║" "DarkCyan"
        Write-C " $armorHdr" "Cyan"
        Write-C (" " * $midLen) "Black"
        Write-C $armorDefStr "White"
        Write-CL "║" "DarkCyan"
        Write-CL ("  ╠" + $barH + "╣") "DarkCyan"
        $slots = @("Helmet","Chest","Shield","Amulet","Boots")
        foreach($slot in $slots){
            $piece = $script:EquippedArmor[$slot]
            $slotLabel = "$($slot):".PadRight(10)
            Write-C "  ║" "DarkCyan"
            Write-C " $slotLabel" "White"
            if($piece){
                $pText = "$($piece.Name) (DEF+$($piece.DEF))"
                Write-C $pText "Cyan"
                $dStr = " " + (Format-Durability $piece)
                $dClr = Get-DurabilityColor $piece
                Write-C $dStr $dClr
                $used = 1 + 10 + $pText.Length + $dStr.Length
            } else {
                Write-C "(empty)" "DarkGray"
                $used = 1 + 10 + 7
            }
            $pad = $BoxW - $used
            if($pad -lt 0){$pad = 0}
            Write-C (" " * $pad) "Black"
            Write-CL "║" "DarkCyan"
        }
        Write-CL ("  ╚" + $barH + "╝") "DarkCyan"
        Write-Host ""

        # ── Loot / Items ──
        Write-CL ("  ╔" + $barH + "╗") "DarkMagenta"
        $lootHdr = " L O O T  ($($script:Inventory.Count) items)"
        Write-C "  ║" "DarkMagenta"
        Write-C (Pad-Box $lootHdr) "Magenta"
        Write-CL "║" "DarkMagenta"
        Write-CL ("  ╠" + $barH + "╣") "DarkMagenta"
        if($script:Inventory.Count -eq 0){
            Write-C "  ║" "DarkMagenta"
            Write-C (Pad-Box " (empty)") "DarkGray"
            Write-CL "║" "DarkMagenta"
        } else {
            $totalVal = 0
            $totalWt  = 0
            for($i=0;$i -lt $script:Inventory.Count;$i++){
                $it=$script:Inventory[$i]
                $totalVal += $it.Value
                $iWt = Get-ItemWeight $it
                $totalWt += $iWt
                $kindTag = switch($it.Kind){
                    "Weapon" { "[Wpn]" }
                    "Armor"  { "[Arm]" }
                    "Potion" { "[Pot]" }
                    default  { "[Loot]" }
                }
                $iName = "$($i+1). $($it.Name) $kindTag"
                $iVal  = "$($it.Value)g"
                $iWtStr = "${iWt}wt"
                $namePad = 36
                if($iName.Length -gt $namePad){ $iName = $iName.Substring(0, $namePad - 3) + "..." }
                Write-C "  ║" "DarkMagenta"
                Write-C " " "Black"
                Write-C $iName.PadRight($namePad) "Magenta"
                Write-C " " "Black"
                Write-C $iWtStr.PadLeft(5) "DarkGray"
                Write-C " " "Black"
                Write-C $iVal.PadLeft(8) "Yellow"
                $used = 1 + $namePad + 1 + 5 + 1 + 8
                $pad = $BoxW - $used
                if($pad -lt 0){$pad = 0}
                Write-C (" " * $pad) "Black"
                Write-CL "║" "DarkMagenta"
            }
            Write-CL ("  ╠" + $barH + "╣") "DarkMagenta"
            Write-C "  ║" "DarkMagenta"
            Write-C " Total: " "White"
            Write-C "${totalVal}g" "Yellow"
            Write-C " | " "DarkGray"
            Write-C "${totalWt}wt" "DarkGray"
            $used = 1 + 8 + "${totalVal}g".Length + 3 + "${totalWt}wt".Length
            $pad = $BoxW - $used
            if($pad -lt 0){$pad = 0}
            Write-C (" " * $pad) "Black"
            Write-CL "║" "DarkMagenta"
        }
        Write-CL ("  ╚" + $barH + "╝") "DarkMagenta"
        Write-Host ""

        # ── Potions / Throwables ──
        $potCount = $script:Potions.Count
        $thrCount = $script:ThrowablePotions.Count
        if($potCount -gt 0 -or $thrCount -gt 0){
            Write-CL ("  ╔" + $barH + "╗") "DarkGreen"
            $consHdr = " P O T I O N S  ($potCount)  +  T H R O W A B L E S  ($thrCount)"
            Write-C "  ║" "DarkGreen"
            Write-C (Pad-Box $consHdr) "Green"
            Write-CL "║" "DarkGreen"
            Write-CL ("  ╠" + $barH + "╣") "DarkGreen"
            $idx = 0
            for($pi=0; $pi -lt $potCount; $pi++){
                $idx++
                $pot = $script:Potions[$pi]
                $iName = "$idx. $($pot.Name) [Pot]"
                $iVal  = if($pot.Price){"$($pot.Price)g"}else{"---"}
                if($iName.Length -gt 36){ $iName = $iName.Substring(0,33) + "..." }
                Write-C "  ║" "DarkGreen"
                Write-C " " "Black"
                Write-C $iName.PadRight(36) "Green"
                Write-C " " "Black"
                Write-C "1wt".PadLeft(5) "DarkGray"
                Write-C " " "Black"
                Write-C $iVal.PadLeft(8) "Yellow"
                $used = 1 + 36 + 1 + 5 + 1 + 8
                $pad = $BoxW - $used
                if($pad -lt 0){$pad = 0}
                Write-C (" " * $pad) "Black"
                Write-CL "║" "DarkGreen"
            }
            for($ti=0; $ti -lt $thrCount; $ti++){
                $idx++
                $thr = $script:ThrowablePotions[$ti]
                $iName = "$idx. $($thr.Name) [Thr]"
                $iVal  = if($thr.Price){"$($thr.Price)g"}else{"---"}
                if($iName.Length -gt 36){ $iName = $iName.Substring(0,33) + "..." }
                Write-C "  ║" "DarkGreen"
                Write-C " " "Black"
                Write-C $iName.PadRight(36) "DarkYellow"
                Write-C " " "Black"
                Write-C "1wt".PadLeft(5) "DarkGray"
                Write-C " " "Black"
                Write-C $iVal.PadLeft(8) "Yellow"
                $used = 1 + 36 + 1 + 5 + 1 + 8
                $pad = $BoxW - $used
                if($pad -lt 0){$pad = 0}
                Write-C (" " * $pad) "Black"
                Write-CL "║" "DarkGreen"
            }
            Write-CL ("  ╚" + $barH + "╝") "DarkGreen"
            Write-Host ""
        }


        # ── Options (interior 44) ──
        $oBar = "─" * 44
        Write-CL "  ┌$oBar┐" "DarkGray"
        $row1 = " [U] Unequip Gear (move to bag)"
        $pad1 = 42 - $row1.Length
        if($pad1 -lt 0){$pad1 = 0}
        Write-C "  │" "DarkGray"; Write-C " [U]" "Red"; Write-C " Unequip Gear (move to bag)" "White"
        Write-CL ("$(' ' * $pad1) │") "DarkGray"
        $eRow = " [E] Equip from Bag"
        $ePad = 42 - $eRow.Length
        if($ePad -lt 0){$ePad = 0}
        Write-C "  │" "DarkGray"; Write-C " [E]" "Green"; Write-C " Equip from Bag" "White"
        Write-CL ("$(' ' * $ePad) │") "DarkGray"
        $kRow = " [K] Use Repair Kit (x$($script:RepairKits))"
        $kPad = 42 - $kRow.Length
        if($kPad -lt 0){$kPad = 0}
        Write-C "  │" "DarkGray"; Write-C " [K]" "Cyan"; Write-C " Use Repair Kit (x$($script:RepairKits))" "White"
        Write-CL ("$(' ' * $kPad) │") "DarkGray"
        $dRow = " [D] Drop Items (destroy)"
        $dPad = 42 - $dRow.Length
        if($dPad -lt 0){$dPad = 0}
        Write-C "  │" "DarkGray"; Write-C " [D]" "DarkRed"; Write-C " Drop Items (destroy)" "White"
        Write-CL ("$(' ' * $dPad) │") "DarkGray"
        $row2 = " [0] Back"
        $pad2 = 42 - $row2.Length
        if($pad2 -lt 0){$pad2 = 0}
        Write-C "  │" "DarkGray"; Write-C " [0]" "White"; Write-C " Back" "White"
        Write-CL ("$(' ' * $pad2) │") "DarkGray"
        Write-CL "  └$oBar┘" "DarkGray"
        Write-Host ""
        Write-C "  > " "Yellow"; $invCh = Read-Host

        switch($invCh.ToUpper()){
            "D" {
                Show-DropScreen
            }
            "K" {
                if($script:RepairKits -le 0){
                    Write-CL "  You don't have any Repair Kits." "Red"
                    Wait-Key
                    continue
                }
                # Check if anything actually needs repair
                $needsRepair = $false
                if($script:EquippedWeapon -and $script:EquippedWeapon.MaxDurability -ge 0 -and $script:EquippedWeapon.Durability -lt $script:EquippedWeapon.MaxDurability){
                    $needsRepair = $true
                }
                if(-not $needsRepair){
                    foreach($slotN in @("Helmet","Chest","Shield","Amulet","Boots")){
                        $piece = $script:EquippedArmor[$slotN]
                        if($piece -and $piece.MaxDurability -ge 0 -and $piece.Durability -lt $piece.MaxDurability){
                            $needsRepair = $true; break
                        }
                    }
                }
                if(-not $needsRepair){
                    Write-CL "  All your gear is already at full durability." "DarkGray"
                    Wait-Key
                    continue
                }
                # Repair everything
                $script:RepairKits--
                Write-Host ""
                Write-CL "  *POP* You crack open the Repair Kit." "Cyan"
                if($script:EquippedWeapon -and $script:EquippedWeapon.MaxDurability -ge 0){
                    $script:EquippedWeapon.Durability = $script:EquippedWeapon.MaxDurability
                    Write-CL "    ✓ $($script:EquippedWeapon.Name) restored" "Green"
                }
                foreach($slotN in @("Helmet","Chest","Shield","Amulet","Boots")){
                    $piece = $script:EquippedArmor[$slotN]
                    if($piece -and $piece.MaxDurability -ge 0){
                        $piece.Durability = $piece.MaxDurability
                        Write-CL "    ✓ $($piece.Name) restored" "Green"
                    }
                }
                Write-CL "  All gear repaired! ($($script:RepairKits) kit(s) remaining)" "Cyan"
                Wait-Key
            }
            "U" {
                clr
                Write-CL "  ── Unequip Gear ──" "Red"
                Write-CL "  Items go back to your inventory bag (no refund)." "DarkGray"
                Write-Host ""
                $unequipOptions = [System.Collections.ArrayList]@()
                if($script:EquippedWeapon){
                    [void]$unequipOptions.Add(@{Label="Weapon: $($script:EquippedWeapon.Name)";Slot="Weapon"})
                }
                foreach($slot in $slots){
                    if($script:EquippedArmor[$slot]){
                        [void]$unequipOptions.Add(@{Label="$($slot): $($script:EquippedArmor[$slot].Name)";Slot=$slot})
                    }
                }
                if($unequipOptions.Count -eq 0){
                    Write-CL "  Nothing equipped to remove." "DarkGray"
                    Wait-Key
                } else {
                    for($ui=0;$ui -lt $unequipOptions.Count;$ui++){
                        Write-CL "  [$($ui+1)] $($unequipOptions[$ui].Label)" "White"
                    }
                    Write-CL "  [0] Cancel" "DarkGray"
                    Write-Host ""
                    Write-C "  > " "Yellow"; $uPick = Read-Host
                    $uIdx = (ConvertTo-SafeInt -Value $uPick) - 1
                    if($uIdx -ge 0 -and $uIdx -lt $unequipOptions.Count){
                        $uSlot = $unequipOptions[$uIdx].Slot
                        if($uSlot -eq "Weapon"){
                            # Special warning for Dutchman's Blade — even though
                            # it now goes to the bag (and could be re-equipped),
                            # players might not realize it's irreplaceable.
                            if($script:EquippedWeapon.Name -eq "Dutchman's Blade"){
                                Write-Host ""
                                Write-CL "  ╔══════════════════════════════════════════════════╗" "DarkRed"
                                Write-CL "  ║         N O T E                                  ║" "Red"
                                Write-CL "  ╚══════════════════════════════════════════════════╝" "DarkRed"
                                Write-CL "  The Dutchman's Blade is one of a kind." "Yellow"
                                Write-CL "  It will go to your bag — be careful not to drop it." "Yellow"
                                Write-Host ""
                                Write-C "  Continue? (y/N): " "Red"
                                $confirm = Read-Host
                                if($confirm -ne "y" -and $confirm -ne "Y"){
                                    Write-CL "  The Blade remains at your side." "Green"
                                    Read-Host "  [Press Enter to continue]" | Out-Null
                                    continue
                                }
                            }
                            $oldWep = $script:EquippedWeapon
                            if(-not $oldWep.Kind){ $oldWep.Kind = "Weapon" }
                            [void]$script:Inventory.Add($oldWep)
                            $script:EquippedWeapon = $null
                            Write-CL "  Unequipped $($oldWep.Name) — moved to bag." "Yellow"
                            if(Test-Encumbered){
                                Write-CL "  -- OVER ENCUMBERED -- you cannot move on the dungeon grid." "Red"
                            }
                        } else {
                            $piece = $script:EquippedArmor[$uSlot]
                            if(-not $piece.Kind){ $piece.Kind = "Armor" }
                            [void]$script:Inventory.Add($piece)
                            $script:EquippedArmor[$uSlot] = $null
                            Write-CL "  Unequipped $($piece.Name) — moved to bag." "Yellow"
                            if(Test-Encumbered){
                                Write-CL "  -- OVER ENCUMBERED -- you cannot move on the dungeon grid." "Red"
                            }
                        }
                        Wait-Key
                    }
                }
            }
            "E" {
                clr
                Write-CL "  ── Equip from Bag ──" "Green"
                Write-CL "  Pick a weapon or armor in your inventory to equip." "DarkGray"
                Write-CL "  Currently equipped item (if any) goes to the bag." "DarkGray"
                Write-Host ""
                # Find equippable items in inventory
                $equipOptions = [System.Collections.ArrayList]@()
                for($ei=0; $ei -lt $script:Inventory.Count; $ei++){
                    $it = $script:Inventory[$ei]
                    if($it.Kind -eq "Weapon" -or $it.WeaponType){
                        [void]$equipOptions.Add(@{Index=$ei; Label="Weapon: $($it.Name) (ATK+$($it.ATK))"; Item=$it})
                    } elseif($it.Kind -eq "Armor" -or $it.Slot){
                        $defStr = if($it.DEF){"DEF+$($it.DEF)"}else{""}
                        [void]$equipOptions.Add(@{Index=$ei; Label="$($it.Slot): $($it.Name) ($defStr)"; Item=$it})
                    }
                }
                if($equipOptions.Count -eq 0){
                    Write-CL "  No equippable items in your bag." "DarkGray"
                    Wait-Key
                } else {
                    for($oi=0; $oi -lt $equipOptions.Count; $oi++){
                        Write-CL "  [$($oi+1)] $($equipOptions[$oi].Label)" "White"
                    }
                    Write-CL "  [0] Cancel" "DarkGray"
                    Write-Host ""
                    Write-C "  > " "Yellow"; $ePick = Read-Host
                    $eIdx = (ConvertTo-SafeInt -Value $ePick) - 1
                    if($eIdx -ge 0 -and $eIdx -lt $equipOptions.Count){
                        $invIdx = $equipOptions[$eIdx].Index
                        Invoke-EquipFromInventory -InvIndex $invIdx | Out-Null
                        Wait-Key
                    }
                }
            }
            "0" { $invLoop = $false }
            default { $invLoop = $false }
        }
    }
}

function Show-Tutorial {
    $pages = @(
        @{Title="1. THE TOWN SQUARE"; Lines=@(
            "  The TOWN SQUARE is your hub between dungeon runs."
            ""
            "  From here you can:"
            "   * Enter a dungeon (gain XP, gold, loot)"
            "   * Visit the Market to buy gear, armor, potions, lockpicks"
            "   * Repair damaged equipment at the Blacksmith"
            "   * Rest at the Weary Lantern Inn to recover HP/MP"
            "   * Train at the Training Grounds (boost stats for gold)"
            "   * Accept quests for bonus rewards (up to 5 active)"
            "   * Hire companions from the Guild Hall"
            "   * Manage gear and inventory ([3] Inventory)"
            ""
            "  You select actions by typing their number or letter."
        )}
        @{Title="2. DUNGEON MOVEMENT"; Lines=@(
            "  Inside a dungeon, movement is REAL-TIME. Just press keys —"
            "  no Enter needed."
            ""
            "  Controls:"
            "    W — walk forward         S — step back"
            "    A — turn left            D — turn right"
            "    P — use a healing potion I — open inventory"
            "    J — view quest log       Q — quit the dungeon"
            "    (arrow keys also work for movement)"
            ""
            "  Movement is gently throttled to about 7 steps per second so"
            "  holding a key doesn't zoom you across the map."
            ""
            "  PERFORMANCE TIP: For the smoothest rendering, resize your"
            "  terminal to at least 80x32 (or maximize it). The game will"
            "  use partial-redraw mode and only repaint the parts of the"
            "  screen that change. Smaller windows fall back to full"
            "  refreshes, which still works but flickers."
            ""
            "  A 3D view shows the corridor ahead; a minimap is on the right."
            "  Look for:  ! enemies   M mini-boss   B boss"
            "             $ treasure  > exit        ? lost adventurer"
        )}
        @{Title="3. COMBAT BASICS"; Lines=@(
            "  Combat is turn-based. Options each round:"
            ""
            "    [1] Attack   — basic weapon strike"
            "    [2] Ability  — class spells/skills (costs MP, has cooldown)"
            "    [3] Potion   — drink from your potion bag"
            "    [4] Throw    — hurl flasks and bombs"
            "    [5] Defend   — double DEF this turn (great vs. boss charges)"
            "    [6] Flee     — try to run (bosses can't be fled from)"
            "    [T] Stance   — switch stance (free action, no turn cost)"
            ""
            "  HIT & CRIT:"
            "    Hit chance caps at 90%. Slow/Stun effects drop enemy accuracy."
            "    Both you AND enemies can crit for 2x damage."
            "    Bosses sometimes CHARGE a big attack — DEFEND when you see it!"
            ""
            "  ABILITY COOLDOWNS:"
            "    Each ability has its own cooldown after use, shown in the"
            "    ability menu. Manage them — you can't spam your strongest"
            "    spell every turn. Different abilities have different CDs."
        )}
        @{Title="4. ENEMY ABILITIES & AI"; Lines=@(
            "  Enemies aren't just punching bags. They have abilities too:"
            ""
            "    * DAMAGE abilities    (Power Strike, Dark Wave, Inferno...)"
            "    * SELF-BUFFS         (ATK or DEF up for 3 turns)"
            "    * HEALING             (recover their own HP)"
            ""
            "  ENEMY AI is throttled — they won't spam abilities every turn."
            "  Roughly 35% of turns will use a damage ability if one is off"
            "  cooldown, otherwise they basic-attack. Buffs and heals are"
            "  used sparingly so combat feels fair, not frustrating."
            ""
            "  TRIGGERS YOU CAN PLAN AROUND:"
            "    * Below 30% HP, enemies with a heal will use it"
            "    * Without a buff active, they may self-buff (~30% chance)"
            "    * Bosses telegraph their biggest attacks — defend that turn"
            ""
            "  Mini-bosses and bosses have wider ability sets including"
            "  heals and buffs. Higher-level normal enemies (troll, skeleton,"
            "  zombie, wizard, thief) gain extra abilities at deeper floors."
        )}
        @{Title="5. GEAR & DURABILITY"; Lines=@(
            "  Every class has a weapon AFFINITY. Matching weapon type = bonus ATK."
            ""
            "    Knight → Sword    Mage → Staff    Brawler → Fist"
            "    Ranger → Bow      Cleric → Mace   Necromancer → Scythe"
            "    Berserker → Sword   Warlock → Staff"
            ""
            "  Weapon perks like Bleed, Burn, Poison trigger on attack."
            "  Armor covers 5 slots: Helmet, Chest, Shield, Amulet, Boots."
            ""
            "  DURABILITY: Every weapon and armor piece has a durability pool."
            "   * Weapons lose 1 point per successful hit you land."
            "   * Armor has a 50% chance to lose 1 point when you take damage."
            "   * A BROKEN item (0 durability) gives 0 stat bonus until repaired."
            ""
            "  Visit the BLACKSMITH in the market to repair gear. Cost scales"
            "  with the damage done. Repair All gives a 10% bulk discount."
            ""
            "  EQUIPPING & UNEQUIPPING:"
            "    Buying or finding new gear with a slot already occupied"
            "    will prompt you: equip now (old goes to bag) or stow new."
            "    No more sell-on-replace — your gear stays with you."
            "    Use [E] Equip from Bag in the inventory screen to swap."
            "    Use [U] Unequip Gear to move equipped pieces back to bag."
            ""
            "  Rare encounters in dungeons include the Healing Bard, Lost"
            "  Merchant, Wandering Alchemist — and the Flying Dutchman, who"
            "  offers a legendary blade on a coin toss."
        )}
        @{Title="6. INVENTORY & WEIGHT"; Lines=@(
            "  Every item you carry has weight. Your bag's max capacity is"
            "  100 + (avg of ATK,DEF) x 5."
            ""
            "  WEIGHT-FREE ITEMS:"
            "    * Equipped weapon and armor"
            "    * Gold, repair kits, extra strong potions"
            ""
            "  WEIGHTED ITEMS (count toward your cap):"
            "    * Loot items (gems, scales, idols, etc.)"
            "    * Spare weapons and armor in your bag (boss/miniboss drops)"
            "    * Potions and throwables (1 weight each)"
            "    * Lockpicks (1 weight each)"
            ""
            "  WHEN YOU'RE OVER ENCUMBERED:"
            "    * In a dungeon, WASD movement is BLOCKED. Open inventory [I]"
            "      and use [D] Drop Items to destroy unwanted items."
            "    * In town, you can't enter another dungeon. Sell at the"
            "      Market or drop items via the Inventory."
            ""
            "  END-OF-DUNGEON loot bypasses the weight cap, but you'll need"
            "  to clear space in town before adventuring again."
            ""
            "  LOOT SCREEN (chest contents, enemy drops):"
            "    Up/Down — move cursor   Space — toggle take/leave"
            "    A — take all that fit   V — view item details"
            "    Enter — confirm         Esc — take nothing"
            ""
            "  Gold also flows through the loot screen for visual consistency,"
            "  but it has 0 weight and is always safe to take."
        )}
        @{Title="7. COMBAT STANCES"; Lines=@(
            "  In combat, press [T] to switch your STANCE. This is a"
            "  FREE ACTION — it doesn't cost your turn."
            ""
            "  THREE STANCES:"
            "    AGGRESSIVE  ATK +30%  /  DEF -30%   (deal more, take more)"
            "    BALANCED    no change              (neutral default)"
            "    DEFENSIVE   ATK -30%  /  DEF +30%  (deal less, take less)"
            ""
            "  Stance affects BOTH basic attacks and abilities, including"
            "  magic damage. It also persists between fights — you'll keep"
            "  the same stance across the dungeon until you switch again."
            ""
            "  TACTICAL TIPS:"
            "    * Use Aggressive to finish off a low-HP enemy quickly"
            "    * Use Defensive against bosses with charged-attack telegraphs"
            "    * Combine Defensive with [5] Defend for huge damage reduction"
            "    * Stance is shown in the combat HUD with a color tag"
        )}
        @{Title="8. QUESTS"; Lines=@(
            "  The QUEST BOARD in town offers 5 randomly-generated quests."
            "  You can hold up to 5 active quests at a time."
            ""
            "  QUEST TYPES:"
            "    * Kill X enemies          * Defeat the dungeon mini-boss"
            "    * Defeat the boss          * Open X chests"
            "    * Rescue the lost adventurer"
            "    * Land X critical hits     * Pick X locks"
            "    * Collect X loot items     * Reach boss room above 50% HP"
            "    * X kills bare-handed      * Repair gear at the Blacksmith"
            ""
            "  Press [J] in the dungeon to view the QUEST LOG with progress"
            "  bars. Quests don't auto-complete — return to the board to"
            "  turn in finished quests for gold and XP."
            ""
            "  Rewards scale with dungeon level and target count, so deeper"
            "  dungeons offer more lucrative bounties."
        )}
        @{Title="9. SAVING YOUR PROGRESS"; Lines=@(
            "  From the Town Square, press [S] to generate a SAVE CODE."
            ""
            "  The code is a long Base64 string — copy it somewhere safe!"
            "  When you relaunch the game, choose LOAD SAVE CODE and paste it."
            ""
            "  Notes:"
            "   * Loot items are converted to gold on save."
            "   * Active quests are reset on save (visit the board again)."
            "   * Achievements, training, and best-streak record persist."
            "   * Your CURRENT dungeon streak does NOT persist — each load"
            "     starts fresh. Your best-ever streak is preserved though."
            ""
            "  Good luck, adventurer. The Depths await."
        )}
    )

    foreach($page in $pages){
        clr
        Write-Host ""
        Write-CL "  ╔══════════════════════════════════════════════════════════════════╗" "DarkCyan"
        Write-CL "  ║                    T U T O R I A L                               ║" "Cyan"
        Write-CL "  ║  $($page.Title.PadRight(64))║" "Yellow"
        Write-CL "  ╚══════════════════════════════════════════════════════════════════╝" "DarkCyan"
        Write-Host ""
        foreach($line in $page.Lines){
            Write-CL $line "Gray"
        }
        Write-Host ""
        Wait-Key
    }
    clr
    Write-CL "  Tutorial complete! May your gold pile high." "Green"
    Wait-Key
}

# Launch the game
Start-Game
