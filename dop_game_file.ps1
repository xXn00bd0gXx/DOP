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



# ─── HELPERS ──────────────────────────────────────────────────────
function Write-C { param([string]$Text,[string]$Color="White",[string]$BG="")
    if($BG){
        Write-Host $Text -ForegroundColor $Color -BackgroundColor $BG -NoNewline
    } else {
        Write-Host $Text -ForegroundColor $Color -NoNewline
    }
}
function Write-CL { param([string]$Text,[string]$Color="White",[string]$BG="")
    if($BG){
        Write-Host $Text -ForegroundColor $Color -BackgroundColor $BG
    } else {
        Write-Host $Text -ForegroundColor $Color
    }
}
function Wait-Key { Write-Host ""; Write-C "[Press any key]" "DarkGray"; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
function clr { Clear-Host }

# Returns total DEF bonus from all equipped armor pieces
function Get-TotalArmorDEF {
    $total = 0
    foreach($slot in $script:EquippedArmor.Keys){
        if($script:EquippedArmor[$slot]){
            $total += $script:EquippedArmor[$slot].DEF
        }
    }
    return $total
}

# Returns bonus ATK if equipped weapon matches player class
function Get-WeaponClassBonus {
    if(-not $script:EquippedWeapon){ return 0 }
    if($script:EquippedWeapon.ClassAffinity -eq $script:PlayerClass){
        return $script:EquippedWeapon.AffinityBonus
    }
    return 0
}

# Returns total effective weapon ATK (base + class bonus)
function Get-TotalWeaponATK {
    if(-not $script:EquippedWeapon){ return 0 }
    return $script:EquippedWeapon.ATK + (Get-WeaponClassBonus)
}

# Returns MAG bonus from weapon (staves grant MAG)
function Get-WeaponMAGBonus {
    if($script:EquippedWeapon -and $script:EquippedWeapon.MAGBonus){
        return $script:EquippedWeapon.MAGBonus
    }
    return 0
}



# ─── LOOT GENERATION ─────────────────────────────────────────────
function New-RandomLoot {
    param([int]$Tier)
    $types = @("Rusty Dagger","Old Ring","Gem Shard","Goblin Ear","Bone Fragment",
               "Silver Pendant","Enchanted Dust","Wyvern Scale","Dark Shard","Ruby Chunk",
               "Golden Idol","Ancient Rune","Dragon Tooth","Shadow Gem","Demon Horn")
    $item = $types | Get-Random
    $value = (Get-Random -Min (5*$Tier) -Max (25*$Tier))
    @{ Name=$item; Value=$value; Tier=$Tier }
}

# ─── ENEMY FACTORIES ─────────────────────────────────────────────
function New-Enemy {
    param([string]$Type,[int]$Lvl)
    $b = switch ($Type) {
        "Goblin"  {@{HP=28;ATK=8; DEF=3; SPD=10;MAG=2; XP=20; G=Get-Random -Min 5  -Max 20}}
        "Zombie"  {@{HP=42;ATK=10;DEF=6; SPD=3; MAG=1; XP=30; G=Get-Random -Min 8  -Max 25}}
        "Thief"   {@{HP=22;ATK=12;DEF=4; SPD=14;MAG=3; XP=25; G=Get-Random -Min 15 -Max 40}}
        "Wizard"  {@{HP=32;ATK=5; DEF=4; SPD=8; MAG=16;XP=35; G=Get-Random -Min 10 -Max 35}}
        "Troll"   {@{HP=58;ATK=14;DEF=8; SPD=5; MAG=2; XP=45; G=Get-Random -Min 12 -Max 30}}
    }
    $s = 1+($Lvl-1)*0.3
    @{ Name="$Type";DisplayName="$Type (Lv$Lvl)";HP=[math]::Floor($b.HP*$s);MaxHP=[math]::Floor($b.HP*$s)
       ATK=[math]::Floor($b.ATK*$s);DEF=[math]::Floor($b.DEF*$s);SPD=[math]::Floor($b.SPD*$s)
       MAG=[math]::Floor($b.MAG*$s);XP=[math]::Floor($b.XP*$s);Gold=$b.G
       IsBoss=$false;IsMiniBoss=$false;Loot=(New-RandomLoot $Lvl);Stunned=$false;DropsKey=$false
       Abilities=@(
           @{Name="Attack";Power=0;Type="Normal"}
           switch($Type){
               "Wizard" {@{Name="Dark Bolt";Power=12;Type="Magic"}}
               "Troll"  {@{Name="Smash";Power=8;Type="Physical"}}
               "Thief"  {@{Name="Backstab";Power=10;Type="Physical"}}
               default  {@{Name="Bite";Power=4;Type="Physical"}}
           }
       )
    }
}

function New-MiniBoss {
    param([int]$Lvl)
    $names=@("Shadow Knight","Dark Shaman","Iron Golem","Venom Queen","Flame Warden")
    $n=$names|Get-Random; $s=1+($Lvl-1)*0.4
    @{ Name=$n;DisplayName="$n [MINI-BOSS]";HP=[math]::Floor(130*$s);MaxHP=[math]::Floor(130*$s)
       ATK=[math]::Floor(18*$s);DEF=[math]::Floor(12*$s);SPD=[math]::Floor(10*$s);MAG=[math]::Floor(12*$s)
       XP=[math]::Floor(150*$s);Gold=(Get-Random -Min 50 -Max 120)
       IsBoss=$false;IsMiniBoss=$true;Loot=(New-RandomLoot ($Lvl+1));Stunned=$false;DropsKey=$true
       Abilities=@(
           @{Name="Attack";Power=0;Type="Normal"}
           @{Name="Power Strike";Power=15;Type="Physical"}
           @{Name="Dark Wave";Power=12;Type="Magic"}
       )
    }
}

function New-Boss {
    param([int]$Lvl)
    $names=@("Lich King","Dragon Wyrm","Demon Lord","Abyssal Horror","Undead Titan")
    $n=$names|Get-Random; $s=1+($Lvl-1)*0.5
    @{ Name=$n;DisplayName=">>> $n [DUNGEON BOSS] <<<";HP=[math]::Floor(260*$s);MaxHP=[math]::Floor(260*$s)
       ATK=[math]::Floor(24*$s);DEF=[math]::Floor(16*$s);SPD=[math]::Floor(12*$s);MAG=[math]::Floor(16*$s)
       XP=[math]::Floor(400*$s);Gold=(Get-Random -Min 100 -Max 250)
       IsBoss=$true;IsMiniBoss=$false;Loot=(New-RandomLoot ($Lvl+2));Stunned=$false;DropsKey=$false
       Abilities=@(
           @{Name="Attack";Power=0;Type="Normal"}
           @{Name="Devastate";Power=20;Type="Physical"}
           @{Name="Soul Drain";Power=18;Type="Magic"}
           @{Name="Inferno";Power=25;Type="Magic"}
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
    $eTypes=@("Goblin","Zombie","Thief","Wizard","Troll")
    $enemies=@{}
    for($i=1;$i -lt [math]::Max($rooms.Count-2,1);$i++){
        $r=$rooms[$i]; $ne=Get-Random -Min 1 -Max 4
        for($e=0;$e -lt $ne;$e++){
            $ex=Get-Random -Min $r.X -Max ($r.X+$r.W)
            $ey=Get-Random -Min $r.Y -Max ($r.Y+$r.H)
            if($grid[$ey,$ex]-eq 0){
                $grid[$ey,$ex]=2
                $enemies["$ex,$ey"]=New-Enemy ($eTypes|Get-Random) $Level
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
        $enemies["$($mbR.CX),$($mbR.CY)"]=New-MiniBoss $Level
    }
    # Boss in last room
    $bR=$rooms[$rooms.Count-1]; $grid[$bR.CY,$bR.CX]=4
    $enemies["$($bR.CX),$($bR.CY)"]=New-Boss $Level
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
    @{Grid=$grid;W=$w;H=$h;Rooms=$rooms;Enemies=$enemies
      PX=$startR.CX;PY=$startR.CY;PDir=0;HasBossKey=$false;BossDefeated=$false}
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
    $vw=42; $vh=21

    # ── Box-drawing chars — swap to ASCII comments if these don't render ──
    $chVLine = [char]0x2502  # │  — or use '|'
    $chHLine = [char]0x2500  # ─  — or use '-'
    $chTL    = [char]0x250C  # ┌  — or use '+'
    $chTR    = [char]0x2510  # ┐  — or use '+'
    $chBL    = [char]0x2514  # └  — or use '+'
    $chBR    = [char]0x2518  # ┘  — or use '+'
    $chCross = [char]0x256C  # ╬  — or use '+'

    # ── Build 3D view buffer (now with 3 layers) ──
    $buf   = New-Object 'char[,]'   $vh,$vw   # character
    $fgbuf = New-Object 'string[,]' $vh,$vw   # foreground color
    $bgbuf = New-Object 'string[,]' $vh,$vw   # background color

    $halfY = [math]::Floor($vh/2)
    for($y=0;$y -lt $vh;$y++){for($x=0;$x -lt $vw;$x++){
        $buf[$y,$x]   = ' '
        $fgbuf[$y,$x] = "White"
        if($y -lt $halfY){ $bgbuf[$y,$x] = "DarkGray" }    # ceiling
        else             { $bgbuf[$y,$x] = "DarkYellow" }   # floor
    }}

    $bounds = @(
        @{L=0; R=41;T=0; B=20},
        @{L=5; R=36;T=3; B=17},
        @{L=10;R=31;T=6; B=14},
        @{L=15;R=26;T=8; B=12},
        @{L=18;R=23;T=9; B=11}
    )

    # Background colors per depth (index 0=nearest, 4=farthest)
    $shadeBG    = @("Cyan","DarkCyan","DarkCyan","DarkGray","Black")
    # Edge foreground per depth
    $shadeEdgeFG = @("White","White","Gray","Gray","DarkGray")

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

        if($wallAhead){
            # Fill wall face with background color
            for($y=$inner.T;$y -le $inner.B;$y++){
                for($x=$inner.L;$x -le $inner.R;$x++){
                    $buf[$y,$x]=' '; $fgbuf[$y,$x]=$efg; $bgbuf[$y,$x]=$bg
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
                    $buf[$y,$x]=' '; $fgbuf[$y,$x]=$efg; $bgbuf[$y,$x]=$bg
                }
            }
            # Diagonal top fill
            $dT=$inner.T-$outer.T; $dX=$inner.L-$outer.L
            if($dT -gt 0){
                for($row=$outer.T;$row -lt $inner.T;$row++){
                    $frac=($row-$outer.T)/$dT
                    $xEnd=[math]::Floor($outer.L+$frac*$dX)
                    for($x=$outer.L;$x -le $xEnd;$x++){
                        $buf[$row,$x]=' '; $fgbuf[$row,$x]=$efg; $bgbuf[$row,$x]=$bg
                    }
                }
                # Diagonal bottom fill
                $dB=$outer.B-$inner.B
                if($dB -gt 0){
                    for($row=($inner.B+1);$row -le $outer.B;$row++){
                        $frac=($outer.B-$row)/$dB
                        $xEnd=[math]::Floor($outer.L+$frac*$dX)
                        for($x=$outer.L;$x -le $xEnd;$x++){
                            $buf[$row,$x]=' '; $fgbuf[$row,$x]=$efg; $bgbuf[$row,$x]=$bg
                        }
                    }
                }
            }
            # Left vertical edge
            for($y=$inner.T;$y -le $inner.B;$y++){
                $buf[$y,$inner.L]=$chVLine; $fgbuf[$y,$inner.L]="White"; $bgbuf[$y,$inner.L]=$bg
            }
        }

        if($wallRight){
            # Fill right side wall
            for($y=$inner.T;$y -le $inner.B;$y++){
                for($x=($inner.R+1);$x -le $outer.R;$x++){
                    $buf[$y,$x]=' '; $fgbuf[$y,$x]=$efg; $bgbuf[$y,$x]=$bg
                }
            }
            # Diagonal top fill
            $dT=$inner.T-$outer.T; $dX=$outer.R-$inner.R
            if($dT -gt 0){
                for($row=$outer.T;$row -lt $inner.T;$row++){
                    $frac=($row-$outer.T)/$dT
                    $xStart=[math]::Floor($outer.R-$frac*$dX)
                    for($x=$xStart;$x -le $outer.R;$x++){
                        $buf[$row,$x]=' '; $fgbuf[$row,$x]=$efg; $bgbuf[$row,$x]=$bg
                    }
                }
                # Diagonal bottom fill
                $dB=$outer.B-$inner.B
                if($dB -gt 0){
                    for($row=($inner.B+1);$row -le $outer.B;$row++){
                        $frac=($outer.B-$row)/$dB
                        $xStart=[math]::Floor($outer.R-$frac*$dX)
                        for($x=$xStart;$x -le $outer.R;$x++){
                            $buf[$row,$x]=' '; $fgbuf[$row,$x]=$efg; $bgbuf[$row,$x]=$bg
                        }
                    }
                }
            }
            # Right vertical edge
            for($y=$inner.T;$y -le $inner.B;$y++){
                $buf[$y,$inner.R]=$chVLine; $fgbuf[$y,$inner.R]="White"; $bgbuf[$y,$inner.R]=$bg
            }
        }
    }
        # ── Entity sprite ──
    $fwd1=Get-Forward $pdir 1; $ax=$px+$fwd1[0]; $ay=$py+$fwd1[1]
    $cellAhead=if($ax -ge 0 -and $ax -lt $d.W -and $ay -ge 0 -and $ay -lt $d.H){$d.Grid[$ay,$ax]}else{1}
    if($cellAhead -ge 2 -and $cellAhead -le 6 -and (Get-Cell $d $ax $ay)-eq 0){
        $eColor=switch($cellAhead){2{"Red"}3{"Magenta"}4{"DarkRed"}5{"Green"}6{"Yellow"}7{"Yellow"}default{"White"}}
        $sprites=@{
            2=@("  /\  ","  \/  "," /||\ ","  /\  "," /  \ ")
            3=@(" [XX] "," \||/ "," /||\ "," |''| "," /  \ ")
            4=@(" {><} "," \@@/ ","/|XX|\","  ||  "," /  \ ")
            5=@(" ____ ","|    |","|EXIT|","|____|")
            6=@("  $$  "," $$$$ ","  $$  ")
            7=@("  /\  "," /  \ ","|HELP|"," /||\ "," /  \ ")
        }
        $sprite=$sprites[$cellAhead]
        if($sprite){
            $midX=[math]::Floor($vw/2); $midY=[math]::Floor($vh/2)
            $sy=$midY-[math]::Floor($sprite.Count/2)
            foreach($line in $sprite){
                $sx=$midX-[math]::Floor($line.Length/2)
                for($ci=0;$ci -lt $line.Length;$ci++){
                    $col=$sx+$ci
                    if($line[$ci] -ne ' ' -and $col -ge 0 -and $col -lt $vw -and $sy -ge 0 -and $sy -lt $vh){
                        $buf[$sy,$col]=$line[$ci]
                        $fgbuf[$sy,$col]=$eColor
                        # Keep existing bgbuf so sprite sits on wall/floor
                    }
                }
                $sy++
            }
        }
    }

    # ── Build minimap lines ──
    $mapR=5; $dirChar=switch($d.PDir){0{'^'}1{'>'}2{'v'}3{'<'}}
    $mapLines = [System.Collections.ArrayList]@()
    [void]$mapLines.Add("  MAP ")
    for($dy=-$mapR;$dy -le $mapR;$dy++){
        $ml=""
        for($dx=-$mapR;$dx -le $mapR;$dx++){
            $mx=$d.PX+$dx; $my=$d.PY+$dy
            if($dx -eq 0 -and $dy -eq 0){ $ml+=$dirChar }
            elseif($mx -lt 0 -or $mx -ge $d.W -or $my -lt 0 -or $my -ge $d.H){ $ml+=" " }
            else{
                $c=$d.Grid[$my,$mx]
                $ml+=switch($c){1{"#"} 0{"."} 2{"!"} 3{"M"} 4{"B"} 5{">"} 6{"$"} 7{"?"} default{" "}}
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

    $hudLines = @(
        "",
        " $($p.Name) Lv$($script:PlayerLevel) ($($script:PlayerClass))",
        " HP[$hpBar] $($p.HP)/$($p.MaxHP)",
        " MP[$mpBar] $($p.MP)/$($p.MaxMP)",
        " ATK:$($p.ATK+$wAtk) DEF:$($p.DEF+$aDef) SPD:$($p.SPD)",
        " MAG:$($p.MAG+$mBonus) Gold:$($script:Gold)",
        " Facing: $($dirNames[$d.PDir])",
        " XP: $($script:XP)/$($script:XPToNext)",
        " Wpn: $wepName$wepPerk",
        " Armor DEF: +$aDef"
    )
    if($script:HasBossKey){ $hudLines += " >> BOSS KEY <<" }
    if($script:Partner){ $hudLines += " Ally: $($script:Partner.Name)" }

    # ── Combine: right panel = minimap then HUD ──
    $rightLines = [System.Collections.ArrayList]@()
    foreach($ml in $mapLines){ [void]$rightLines.Add($ml) }
    foreach($hl in $hudLines){ [void]$rightLines.Add($hl) }
    # ── Render combined output ──
    $separator = "  | "
    for($y=0;$y -lt $vh;$y++){
        # 3D view row — now uses BackgroundColor
        for($x=0;$x -lt $vw;$x++){
            Write-Host ([string]$buf[$y,$x]) -ForegroundColor $fgbuf[$y,$x] -BackgroundColor $bgbuf[$y,$x] -NoNewline
        }
        # Reset background for separator + right panel
        Write-Host $separator -ForegroundColor DarkGray -NoNewline
        # Right panel row
        if($y -lt $rightLines.Count){
            $rl = $rightLines[$y]
            if($y -eq 0){
                Write-Host $rl -ForegroundColor DarkYellow -NoNewline
            }
            elseif($y -ge 1 -and $y -le 11){
                # Minimap row
                for($ci=0;$ci -lt $rl.Length;$ci++){
                    $ch=$rl[$ci]
                    if($ci -eq $mapR){
                        $mapRow = $y - 1
                        if($mapRow -eq $mapR){
                            Write-Host ([string]$ch) -ForegroundColor Green -NoNewline
                            continue
                        }
                    }
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
                        default {"DarkGray"}
                    }
                    Write-Host ([string]$ch) -ForegroundColor $cc -NoNewline
                }
            }
            elseif($rl -match "HP\["){
                for($ci=0;$ci -lt $rl.Length;$ci++){
                    $ch=$rl[$ci]
                    if($ch -eq '+'){Write-Host "+" -ForegroundColor $(if($hpPct -gt 0.5){"Green"}elseif($hpPct -gt 0.25){"Yellow"}else{"Red"}) -NoNewline}
                    elseif($ch -eq '-'){Write-Host "-" -ForegroundColor DarkGray -NoNewline}
                    else{Write-Host ([string]$ch) -ForegroundColor White -NoNewline}
                }
            }
            elseif($rl -match "MP\["){
                for($ci=0;$ci -lt $rl.Length;$ci++){
                    $ch=$rl[$ci]
                    if($ch -eq '+'){Write-Host "+" -ForegroundColor Cyan -NoNewline}
                    elseif($ch -eq '-'){Write-Host "-" -ForegroundColor DarkGray -NoNewline}
                    else{Write-Host ([string]$ch) -ForegroundColor White -NoNewline}
                }
            }
            elseif($rl -match "BOSS KEY"){Write-Host $rl -ForegroundColor Magenta -NoNewline}
            elseif($rl -match "Facing:|Gold:|ATK:|MAG:|XP:|Wpn:|Armor DEF:|Hit:|Ally:"){Write-Host $rl -ForegroundColor DarkGray -NoNewline}
            elseif($y -ge ($mapLines.Count + 1)){Write-Host $rl -ForegroundColor Yellow -NoNewline}
            else{Write-Host $rl -ForegroundColor Gray -NoNewline}
        }
        Write-Host ""
    }
    Write-CL ("="*70) "DarkYellow"
    if($script:StatusMsg){
        Write-CL "  $($script:StatusMsg)" "Yellow"
        $script:StatusMsg = ""
    }
}




# ─── COMBAT SYSTEM ───────────────────────────────────────────────
function Get-EnemyArt {
    param([string]$Type)
    switch($Type){
        "Goblin" { @(
            "    ,      ,    ",
            "   /(  _.  )\   ",
            "  / { (0)(0) }\ ",
            " |   \ ---- /  |",
            "  \   '-..-'  / ",
            "   '-._____.-'  ",
            "     /||  ||\   ",
            "    / ||  || \  "
        )}
        "Zombie" { @(
            "    .----.      ",
            "   / x  x \     ",
            "  |  ____  |    ",
            "  | |UUUU| |    ",
            "   \|____|/     ",
            "   /|    |\     ",
            "  / |    | \    ",
            " /  |    |  \   ",
            "    |    |      ",
            "   _|    |_     "
        )}
        "Thief" { @(
            "      _===_     ",
            "     / . . \    ",
            "    | \_=_/ |   ",
            "     \_____/    ",
            "    /|  |  |\   ",
            "   /_| /\ |_\  ",
            "     |/  \|    ",
            "     /\  /\    ",
            "    /  \/  \   "
        )}
        "Wizard" { @(
            "      /\        ",
            "     /  \       ",
            "    / ** \      ",
            "   /______\     ",
            "   | o  o |     ",
            "   | \__/ |     ",
            "    \____/      ",
            "   /| ** |\     ",
            "  / |/||\| \    ",
            "    / || \      "
        )}
        "Troll" { @(
            "   __......__   ",
            "  /  O    O  \  ",
            " |     __     | ",
            " |    |__|    | ",
            "  \  .----.  /  ",
            "   \/||||||\/   ",
            "   /|      |\   ",
            "  / |      | \  ",
            " |  |      |  | ",
            " |__|      |__| "
        )}
        "MiniBoss" { @(
            "   ___/\/\___   ",
            "  /  _    _  \  ",
            " |  {X}  {X}  | ",
            " |    \../    | ",
            " |   .===>.   | ",
            "  \ |||||||  /  ",
            "   \|_|__|_|/   ",
            "   /|=|  |=|\   ",
            "  //||    ||\\ ",
            " // ||    || \\"
        )}
        "Boss" { @(
            "     /\  /\     ",
            "  __/  \/  \__  ",
            " / _   /\   _ \",
            "| |X| /  \ |X| |",
            "| '-'/    \'-' |",
            " \ /<======>\ / ",
            "  |{  HATE  }|  ",
            "  | <======> |  ",
            " /|\ /\  /\ /|\ ",
            "/ | X  \/  X | \",
            "  |/|  /\  |\|  ",
            "   / \/  \/ \   "
        )}
        default { @(
            "    .---.       ",
            "   / o o \      ",
            "  |  ___  |     ",
            "   \_____/      ",
            "    /| |\       ",
            "   / | | \      "
        )}
    }
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
    $combatLog = [System.Collections.ArrayList]@()

    # Status effects on enemy (local to this fight)
    $ePoisoned  = $false
    $eSlowed    = $false
    $ePoisonDmg = 0

    # Miss chances
    $playerMissChance = [math]::Max(25 - ($script:PlayerLevel - 1) * 2 - [math]::Floor($p.SPD * 0.3), 3)
    $enemyMissChance  = [math]::Max(25 - ($script:DungeonLevel * 2), 5)
    if($e.IsMiniBoss){ $enemyMissChance = [math]::Max($enemyMissChance - 5, 3) }
    if($e.IsBoss){ $enemyMissChance = [math]::Max($enemyMissChance - 10, 2) }

    # Enemy art
    $artType  = if($e.IsMiniBoss){"MiniBoss"}elseif($e.IsBoss){"Boss"}else{$e.Name}
    $enemyArt = Get-EnemyArt $artType

    while($p.HP -gt 0 -and $e.HP -gt 0 -and !$fled){
        clr

        # ── Header ──
        Write-CL ("=" * 60) "DarkRed"
        Write-C "  " "Red"
        if($e.IsBoss){Write-CL $e.DisplayName "DarkRed"}
        elseif($e.IsMiniBoss){Write-CL $e.DisplayName "Magenta"}
        else{Write-CL $e.DisplayName "Red"}
        Write-CL ("=" * 60) "DarkRed"
        Write-Host ""

        # ── Enemy art + stats ──
        $eHPPct = [math]::Max($e.HP / $e.MaxHP, 0)
        $statusStr = ""
        if($ePoisoned){ $statusStr += " [POISON]" }
        if($eSlowed){ $statusStr += " [SLOW]" }
        if($e.Stunned){ $statusStr += " [STUN]" }

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
                $pad = 20 - $enemyArt[$i].Length
                if($pad -gt 0){Write-C (" " * $pad) "Black"}
            } else {
                Write-C ("  " + " " * 18) "Black"
            }
            Write-C "  " "Black"
            if($i -lt $statsLines.Count){
                if($null -eq $statsLines[$i]){
                    Write-C "  " "White"
                    Draw-CombatHPBar $e.HP $e.MaxHP 25 $(if($eHPPct -gt 0.5){"Red"}elseif($eHPPct -gt 0.25){"DarkYellow"}else{"DarkRed"})
                } elseif($statsLines[$i] -match "\[POISON\]|\[SLOW\]|\[STUN\]") {
                    Write-C $statsLines[$i] "Yellow"
                } else {
                    Write-C $statsLines[$i] "Gray"
                }
            }
            Write-Host ""
        }

        Write-Host ""
        Write-CL ("  " + "-" * 56) "DarkGray"
        Write-Host ""

        # ── Player stats ──
        $totalDEF = $p.DEF + $armorDEF + $defBuff
        $totalATK = $p.ATK + $bonusATK + $atkBuff
        $totalMAG = $p.MAG + $magBonus
        $pHPPct = [math]::Max($p.HP / $p.MaxHP, 0)
        $wep = if($script:EquippedWeapon){$script:EquippedWeapon.Name}else{"Bare Hands"}

        Write-C "  $($p.Name)" "Green"
        Write-CL "  (Lv$($script:PlayerLevel))  Weapon: $wep" "DarkGray"

        Write-C "  HP " "White"
        Draw-CombatHPBar $p.HP $p.MaxHP 20 $(if($pHPPct -gt 0.5){"Green"}elseif($pHPPct -gt 0.25){"Yellow"}else{"Red"})
        Write-CL " $($p.HP)/$($p.MaxHP)" "White"

        Write-C "  MP " "White"
        Draw-CombatHPBar $p.MP $p.MaxMP 20 "Cyan"
        Write-CL " $($p.MP)/$($p.MaxMP)" "White"

        Write-CL "  ATK:$totalATK DEF:$totalDEF SPD:$($p.SPD) MAG:$totalMAG" "DarkGray"
        Write-CL "  Hit:$((100 - $playerMissChance))% | Enemy Hit:$((100 - $enemyMissChance))%" "DarkGray"

        # ── Combat log ──
        if($combatLog.Count -gt 0){
            Write-Host ""
            $logStart = [math]::Max($combatLog.Count - 4, 0)
            for($li=$logStart;$li -lt $combatLog.Count;$li++){
                $entry = $combatLog[$li]
                Write-CL "  $($entry.Text)" $entry.Color
            }
        }

        # ── Action menu ──
        Write-Host ""
        Write-CL ("  " + "-" * 56) "DarkGray"
        $throwCount = $script:ThrowablePotions.Count
        Write-CL "   [1] Attack  [2] Ability  [3] Potion  [4] Throw($throwCount)  [5] Flee" "White"
        Write-CL ("  " + "-" * 56) "DarkGray"
        Write-C "  > " "Yellow"
        $choice = Read-Host

        $acted = $true
        switch($choice){
            "1" {
                if((Get-Random -Max 100) -lt $playerMissChance){
                    [void]$combatLog.Add(@{Text=">> You attack but MISS!";Color="DarkGray"})
                } else {
                    $raw = $totalATK - [math]::Floor($e.DEF * 0.5)
                    $playerDmg = [math]::Max($raw + (Get-Random -Min -2 -Max 4), 1)
                    $e.HP -= $playerDmg
                    [void]$combatLog.Add(@{Text=">> You attack for $playerDmg damage!";Color="Green"})

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
                    $ab = $p.Abilities[$ai]
                    $costStr = if($ab.Type -eq "Sacrifice"){"HP:$([math]::Floor($p.MaxHP * 0.15))"}else{"MP:$($ab.Cost)"}
                    $effStr = if($ab.Effect -and $ab.Effect -ne "None" -and $ab.Effect -ne "SacrificeHP"){" [$($ab.Effect)]"}else{""}
                    Write-CL "    [$($ai+1)] $($ab.Name)  ($costStr)  [$($ab.Type)] Pwr:$($ab.Power)$effStr" "Cyan"
                }
                Write-C "    > " "Yellow"; $ac = Read-Host
                $idx = [int]$ac - 1
                if($idx -ge 0 -and $idx -lt $p.Abilities.Count){
                    $ab = $p.Abilities[$idx]

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
                                    $playerMissChance = [math]::Max($playerMissChance - $val, 3)
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
                            if((Get-Random -Max 100) -lt $playerMissChance){
                                [void]$combatLog.Add(@{Text=">> $($ab.Name) MISSES!";Color="DarkGray"})
                            } else {
                                $base = if($ab.Type -eq "Magic" -or $ab.Type -eq "Sacrifice"){$p.MAG + $magBonus}else{$p.ATK + $bonusATK + $atkBuff}
                                $raw = $base + $ab.Power - [math]::Floor($e.DEF * 0.4)
                                $playerDmg = [math]::Max($raw + (Get-Random -Min -2 -Max 5), 1)
                                $e.HP -= $playerDmg
                                [void]$combatLog.Add(@{Text=">> $($ab.Name) hits for $playerDmg!";Color="Cyan"})

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
                                if($ab.Effect -eq "Slow" -and (Get-Random -Max 100) -lt 50){
                                    $eSlowed = $true
                                    [void]$combatLog.Add(@{Text="   Enemy is SLOWED!";Color="DarkCyan"})
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
                } else { $acted = $false }
            }
            "3" {
                if($script:Potions.Count -eq 0){
                    [void]$combatLog.Add(@{Text=">> No potions!";Color="Red"}); $acted = $false
                } else {
                    Write-Host ""
                    Write-CL "  ── Potions ──" "Green"
                    for($pi=0;$pi -lt $script:Potions.Count;$pi++){
                        $pot = $script:Potions[$pi]
                        Write-CL "    [$($pi+1)] $($pot.Name) - $($pot.Desc)" "Green"
                    }
                    Write-C "    > " "Yellow"; $pc = Read-Host
                    $pidx = [int]$pc - 1
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
                        }
                        $script:Potions.RemoveAt($pidx)
                    } else { $acted = $false }
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
                    $tidx = [int]$tc - 1
                    if($tidx -ge 0 -and $tidx -lt $script:ThrowablePotions.Count){
                        $tp = $script:ThrowablePotions[$tidx]
                        $throwDmg = $tp.Power + (Get-Random -Min -3 -Max 4)
                        $throwDmg = [math]::Max($throwDmg, 1)
                        $e.HP -= $throwDmg
                        [void]$combatLog.Add(@{Text=">> Threw $($tp.Name) for $throwDmg damage!";Color="DarkYellow"})

                        if($tp.Type -eq "ThrowPoison"){
                            $ePoisoned = $true
                            $ePoisonDmg = Get-Random -Min 4 -Max 8
                            [void]$combatLog.Add(@{Text="   Enemy is POISONED! ($ePoisonDmg/turn)";Color="DarkGreen"})
                        }
                        if($tp.Type -eq "ThrowSlow"){
                            $eSlowed = $true
                            [void]$combatLog.Add(@{Text="   Enemy is SLOWED!";Color="DarkCyan"})
                        }
                        $script:ThrowablePotions.RemoveAt($tidx)
                    } else { $acted = $false }
                }
            }
            "5" {
                if($e.IsBoss -or $e.IsMiniBoss){
                    [void]$combatLog.Add(@{Text=">> Cannot flee from this enemy!";Color="Red"})
                    $acted = $false
                } elseif((Get-Random -Max 100) -lt (40 + $p.SPD)){
                    [void]$combatLog.Add(@{Text=">> You escaped!";Color="Yellow"}); $fled = $true
                } else {
                    [void]$combatLog.Add(@{Text=">> Failed to flee!";Color="Red"})
                }
            }
            default { $acted = $false }
        }

        # ── Poison tick on enemy (after player acts) ──
        if($ePoisoned -and $e.HP -gt 0 -and !$fled){
            $e.HP -= $ePoisonDmg
            [void]$combatLog.Add(@{Text="   POISON ticks for $ePoisonDmg!";Color="DarkGreen"})
        }

        # ── Enemy turn ──
        if($e.HP -gt 0 -and !$fled -and $acted){
            # Slowed enemies have 35% chance to lose their turn
            if($eSlowed -and (Get-Random -Max 100) -lt 35){
                [void]$combatLog.Add(@{Text="<< $($e.DisplayName) is too SLOW to act!";Color="DarkCyan"})
            }
            elseif($e.Stunned){
                [void]$combatLog.Add(@{Text="<< $($e.DisplayName) is stunned!";Color="Yellow"})
                $e.Stunned = $false
            } else {
                # Enemy miss check
                if((Get-Random -Max 100) -lt $enemyMissChance){
                    [void]$combatLog.Add(@{Text="<< $($e.DisplayName) attacks but MISSES!";Color="DarkGray"})
                } else {
                    $totalPlayerDEF = $p.DEF + $armorDEF + $defBuff
                    $eAbility = $e.Abilities | Get-Random
                    if($eAbility.Type -eq "Normal"){
                        $eRaw = $e.ATK - [math]::Floor($totalPlayerDEF * 0.5)
                        $eDmg = [math]::Max($eRaw + (Get-Random -Min -2 -Max 3), 1)
                    } else {
                        $eBase = if($eAbility.Type -eq "Magic"){$e.MAG}else{$e.ATK}
                        $eRaw = $eBase + $eAbility.Power - [math]::Floor($totalPlayerDEF * 0.4)
                        $eDmg = [math]::Max($eRaw + (Get-Random -Min -1 -Max 4), 1)
                    }
                    $p.HP -= $eDmg
                    $aName = if($eAbility.Name -eq "Attack"){"attacks"}else{"uses $($eAbility.Name)"}
                    [void]$combatLog.Add(@{Text="<< $($e.DisplayName) $aName for $eDmg!";Color="Red"})
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
    
    }

    # ── Outcome ──
    if($p.HP -le 0){
        $p.HP = 0; return @{Result="Death"}
    }
    if($fled){ return @{Result="Fled"} }

    # ── Victory ──
    $script:KillCount++
    Update-QuestProgress "Kill"
    if($e.IsMiniBoss){ Update-QuestProgress "MiniBoss" }
    if($e.IsBoss){ Update-QuestProgress "Boss" }

    clr
    Write-CL ("=" * 60) "Green"
    Write-CL "  V I C T O R Y" "Green"
    Write-CL ("=" * 60) "Green"
    Write-Host ""

    foreach($line in $enemyArt){
        Write-CL "  $line" "DarkGray"
    }
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

    # Apply Thief gold bonus
    $goldGain = $e.Gold
    if($script:Partner -and $script:Partner.Class -eq "Thief"){
        $goldBonus = [math]::Floor($e.Gold * 0.15)
        $goldGain += $goldBonus
    }
    $script:Gold += $goldGain
    Write-CL "  + $goldGain Gold" "Yellow"
    if($script:Partner -and $script:Partner.Class -eq "Thief"){
        Write-CL "    ($($script:Partner.Name): +$goldBonus bonus gold)" "DarkYellow"
    }

    if($e.Loot){
        [void]$script:Inventory.Add($e.Loot)
        Write-CL "  + Loot: $($e.Loot.Name) (Value: $($e.Loot.Value)g)" "Magenta"
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
    while($script:XP -ge $script:XPToNext){
        $script:XP -= $script:XPToNext
        $script:PlayerLevel++
        $script:XPToNext = [math]::Floor($script:XPToNext * 1.5)
        $p.MaxHP += 10; $p.HP = $p.MaxHP; $p.MaxMP += 5; $p.MP = $p.MaxMP
        $p.ATK += 2; $p.DEF += 2; $p.SPD += 1; $p.MAG += 2
        Write-Host ""
        Write-CL "  *** LEVEL UP! Now Level $($script:PlayerLevel)! ***" "Yellow"
        Write-CL "  All stats increased! HP & MP fully restored!" "Yellow"
    }
    Wait-Key
    return @{Result="Won"}
}

function Show-GuildHall {
    $ghLoop = $true
    while($ghLoop){
        clr
        Write-CL "" "White"
        Write-CL "  ╔════════════════════════════════════════════════════╗" "DarkYellow"
        Write-CL "  ║          G U I L D   H A L L                       ║" "Yellow"
        Write-CL "  ╚════════════════════════════════════════════════════╝" "DarkYellow"
        Write-Host ""
        Write-CL "        ______|____________|______" "DarkGray"
        Write-CL "       |  __    __    __    __   |" "DarkGray"
        Write-CL "       | |  |  |  |  |  |  |  | |" "DarkYellow"
        Write-CL "       | |__|  |__|  |__|  |__| |" "DarkGray"
        Write-CL "       |   ADVENTURERS  GUILD    |" "Yellow"
        Write-CL "       |     ____                |" "DarkGray"
        Write-CL "       |    |    |               |" "DarkYellow"
        Write-CL "       |____|    |_______________|" "DarkGray"
        Write-Host ""

        Write-C "  Gold: " "DarkGray"; Write-CL "$($script:Gold)g" "Yellow"
        Write-Host ""

        if($script:Partner){
            Write-CL "  ╔══════════════════════════════════════════════╗" "DarkCyan"
            Write-CL "  ║  C U R R E N T   A L L Y                     ║" "Cyan"
            Write-CL "  ╠══════════════════════════════════════════════╣" "DarkCyan"
            Write-C  "  ║  " "DarkCyan"
            Write-C "$($script:Partner.Name)" "Green"
            Write-C "  ($($script:Partner.Class))" "Cyan"
            $allyPad = 36 - $script:Partner.Name.Length - $script:Partner.Class.Length
            if($allyPad -lt 0){$allyPad=0}
            Write-CL "$(' ' * $allyPad)║" "DarkCyan"
            Write-C  "  ║  " "DarkCyan"
            Write-C "$($script:Partner.Desc)" "DarkGray"
            $descPad = 42 - $script:Partner.Desc.Length
            if($descPad -lt 0){$descPad=0}
            Write-CL "$(' ' * $descPad)║" "DarkCyan"
            Write-CL "  ╚══════════════════════════════════════════════╝" "DarkCyan"
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

        Write-CL "  ╔══════════════════════════════════════════════════════════╗" "DarkGreen"
        Write-CL "  ║  A V A I L A B L E   R E C R U I T S                     ║" "Green"
        Write-CL "  ╠══════════════════════════════════════════════════════════╣" "DarkGreen"
        for($i=0;$i -lt $followers.Count;$i++){
            $f = $followers[$i]
            $affordable = if($script:Gold -ge $f.Price){"Green"}else{"DarkGray"}
            $recruited = if($script:Partner -and $script:Partner.Class -eq $f.Class){" [RECRUITED]"}else{""}
            Write-C  "  ║  " "DarkGreen"
            Write-C "[$($i+1)] " $affordable
            Write-C "$($f.Name)" $f.Color
            Write-C "  ($($f.Class))" "DarkGray"
            Write-C $recruited "Green"
            $rPad = 44 - $f.Name.Length - $f.Class.Length - $recruited.Length
            if($rPad -lt 0){$rPad=0}
            Write-CL "$(' ' * $rPad)║" "DarkGreen"
            Write-C  "  ║      " "DarkGreen"
            Write-C "$($f.Desc)" "White"
            $dPad = 48 - $f.Desc.Length
            if($dPad -lt 0){$dPad=0}
            Write-CL "$(' ' * $dPad)║" "DarkGreen"
            Write-C  "  ║      " "DarkGreen"
            Write-C "$($f.Detail)" "DarkGray"
            $dtPad = 48 - $f.Detail.Length
            if($dtPad -lt 0){$dtPad=0}
            Write-CL "$(' ' * $dtPad)║" "DarkGreen"
            Write-C  "  ║      " "DarkGreen"
            Write-C "Cost: $($f.Price)g" $affordable
            $cPad = 48 - "Cost: $($f.Price)g".Length
            if($cPad -lt 0){$cPad=0}
            Write-CL "$(' ' * $cPad)║" "DarkGreen"
            Write-CL "  ║                                                          ║" "DarkGreen"
        }
        Write-CL "  ╚══════════════════════════════════════════════════════════╝" "DarkGreen"
        Write-Host ""

        Write-CL "  ┌───────────────────────────────────────────┐" "DarkGray"
        Write-C  "  │  " "DarkGray"; Write-C "[1-3]" "White"; Write-CL " Recruit an ally                     │" "DarkGray"
        if($script:Partner){
            Write-C  "  │  " "DarkGray"; Write-C "[D]" "Red"; Write-CL "   Dismiss current ally               │" "DarkGray"
        }
        Write-C  "  │  " "DarkGray"; Write-C "[0]" "White"; Write-CL "   Back                               │" "DarkGray"
        Write-CL "  └───────────────────────────────────────────┘" "DarkGray"
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
        Write-CL "" "White"
        Write-CL "  ╔════════════════════════════════════════════════════╗" "DarkYellow"
        Write-CL "  ║     __        __         _                        ║" "DarkYellow"
        Write-C  "  ║" "DarkYellow"; Write-C "    / _|      / _|       | |" "Yellow"; Write-CL "                       ║" "DarkYellow"
        Write-C  "  ║" "DarkYellow"; Write-C "   | |_ ___  | |_ ___   | |__   ___ _ __ ___" "Yellow"; Write-CL "    ║" "DarkYellow"
        Write-C  "  ║" "DarkYellow"; Write-C "   |  _/ _ \ |  _/ _ \  | '_ \ / _ \ '__/ _ \" "Yellow"; Write-CL "   ║" "DarkYellow"
        Write-C  "  ║" "DarkYellow"; Write-C "   | || (_) || || (_) | | | | |  __/ | |  __/" "Yellow"; Write-CL "   ║" "DarkYellow"
        Write-C  "  ║" "DarkYellow"; Write-C "   |_| \___/ |_| \___/  |_| |_|\___|_|  \___|" "Yellow"; Write-CL "   ║" "DarkYellow"
        Write-CL "  ║                                                    ║" "DarkYellow"
        Write-CL "  ║          W A N D E R I N G   M E R C H A N T      ║" "DarkYellow"
        Write-CL "  ║                                                    ║" "DarkYellow"
        Write-CL "  ╚════════════════════════════════════════════════════╝" "DarkYellow"
        Write-Host ""
        Write-CL "         ___________" "DarkGray"
        Write-CL "        /           \" "DarkGray"
        Write-CL "       /   SHOP      \" "DarkYellow"
        Write-CL "      /_______________\" "DarkGray"
        Write-CL "      |  ___  |  ___  |" "DarkGray"
        Write-CL "      | |   | | |   | |" "DarkYellow"
        Write-CL "      | |___| | |___| |" "DarkGray"
        Write-CL "      |_______|_______|" "DarkGray"
        Write-Host ""

        Write-C "  ┌──────────────────────────┐" "Yellow"
        Write-Host ""
        Write-C "  │  " "Yellow"
        Write-C "Gold: $($script:Gold)g" "Yellow"
        $gpd = 24 - "Gold: $($script:Gold)g".Length
        if($gpd -gt 0){Write-C (" " * $gpd) "Black"}
        Write-CL "│" "Yellow"
        Write-CL "  └──────────────────────────┘" "Yellow"
        Write-Host ""

        Write-CL "  ┌─────────────────────────────────────────┐" "DarkGray"
        Write-CL "  │                                         │" "DarkGray"
        Write-C  "  │  " "DarkGray"; Write-C "[1]" "White"; Write-C " Buy Weapons    " "DarkCyan"
        Write-C  "[2]" "White"; Write-CL " Buy Armor      │" "DarkCyan"
        Write-CL "  │                                         │" "DarkGray"
        Write-C  "  │  " "DarkGray"; Write-C "[3]" "White"; Write-C " Buy Potions    " "Green"
        Write-C  "[4]" "White"; Write-CL " Sell Loot      │" "Magenta"
        Write-CL "  │                                         │" "DarkGray"
        Write-C  "  │  " "DarkGray"; Write-C "[5]" "White"; Write-CL " Leave Market                   │" "DarkGray"
        Write-CL "  │                                         │" "DarkGray"
        Write-CL "  └─────────────────────────────────────────┘" "DarkGray"
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
                        @{Key="Sword";  Label="Swords";  Class="Knight";     Color="Yellow"}
                        @{Key="Staff";  Label="Staves";  Class="Mage";       Color="Cyan"}
                        @{Key="Fist";   Label="Fists";   Class="Brawler";    Color="Red"}
                        @{Key="Bow";    Label="Bows";    Class="Ranger";     Color="Green"}
                        @{Key="Mace";   Label="Maces";   Class="Cleric";     Color="White"}
                        @{Key="Scythe"; Label="Scythes"; Class="Necromancer";Color="Magenta"}
                    )
                    for($ci=0;$ci -lt $catData.Count;$ci++){
                        $cat = $catData[$ci]
                        $match = if($cat.Class -eq $script:PlayerClass){" << YOUR CLASS"}else{""}
                        Write-C "  [$($ci+1)] " "White"
                        Write-C "$($cat.Label.PadRight(10))" $cat.Color
                        Write-C "($($cat.Class) affinity)" "DarkGray"
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

                    Write-CL "  ┌─────┬──────────────────┬────────┬─────────┬──────────┬──────────┐" "DarkGray"
                    Write-CL "  │  #  │ Weapon           │ ATK    │ Price   │ Perk     │ Bonus    │" "DarkGray"
                    Write-CL "  ├─────┼──────────────────┼────────┼─────────┼──────────┼──────────┤" "DarkGray"

                    for($i=0;$i -lt $filtered.Count;$i++){
                        $w = $filtered[$i]
                        $nameStr   = $w.Name.PadRight(16)
                        $atkStr    = ("+$($w.ATK)").PadRight(6)
                        $priceStr  = ("$($w.Price)g").PadRight(7)
                        $perkStr   = if($w.Perk){"$($w.Perk)"}else{"---"}
                        $perkStr   = $perkStr.PadRight(8)
                        $magStr    = if($w.MAGBonus){"MAG+$($w.MAGBonus)"}else{""}
                        $bonusStr  = if($w.ClassAffinity -eq $script:PlayerClass){"ATK+$($w.AffinityBonus)"}else{"---"}
                        if($magStr -and $bonusStr -ne "---"){ $bonusStr = "$bonusStr $magStr" }
                        elseif($magStr){ $bonusStr = $magStr }
                        $bonusStr  = $bonusStr.PadRight(8)
                        $affordable = if($script:Gold -ge $w.Price){"Green"}else{"DarkGray"}
                        $perkColor  = switch($w.Perk){"Bleed"{"DarkRed"}"Burn"{"DarkYellow"}"Poison"{"DarkGreen"}"Drain"{"Magenta"}"Stun"{"Yellow"}default{"DarkGray"}}
                        $bonusColor = if($w.ClassAffinity -eq $script:PlayerClass){"Green"}else{"DarkGray"}

                        Write-C "  │ " "DarkGray"
                        Write-C " $($i+1) " $affordable
                        Write-C "│ " "DarkGray"
                        Write-C $nameStr "Cyan"
                        Write-C "│ " "DarkGray"
                        Write-C $atkStr "White"
                        Write-C "│ " "DarkGray"
                        Write-C $priceStr $affordable
                        Write-C "│ " "DarkGray"
                        Write-C $perkStr $perkColor
                        Write-C "│ " "DarkGray"
                        Write-C $bonusStr $bonusColor
                        Write-CL "│" "DarkGray"
                    }
                    Write-CL "  └─────┴──────────────────┴────────┴─────────┴──────────┴──────────┘" "DarkGray"
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
                            if($script:EquippedWeapon){
                                $refund=[math]::Floor($script:EquippedWeapon.Price * 0.4)
                                $script:Gold += $refund
                                Write-CL "  Sold old $($script:EquippedWeapon.Name) for ${refund}g" "DarkGray"
                            }
                            $script:EquippedWeapon = $w
                            Write-CL "  Equipped $($w.Name)!" "Green"
                            $cb = Get-WeaponClassBonus
                            if($cb -gt 0){
                                Write-CL "  Class bonus active! +$cb ATK" "Green"
                            }
                            if($w.Perk){
                                Write-CL "  Weapon perk: $($w.Perk) ($($w.PerkChance)% chance on attack)" "DarkYellow"
                            }
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
                    $sIdx = [int]$slotPick - 1
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

                    Write-CL "  ┌─────┬──────────────────┬────────┬─────────┐" "DarkGray"
                    Write-CL "  │  #  │ Armor            │ DEF    │ Price   │" "DarkGray"
                    Write-CL "  ├─────┼──────────────────┼────────┼─────────┤" "DarkGray"
                    for($i=0;$i -lt $slotArmor.Count;$i++){
                        $a = $slotArmor[$i]
                        $nameStr  = $a.Name.PadRight(16)
                        $defStr   = ("+$($a.DEF)").PadRight(6)
                        $priceStr = ("$($a.Price)g").PadRight(7)
                        $affordable = if($script:Gold -ge $a.Price){"Green"}else{"DarkGray"}
                        $equipped = if($current -and $current.Name -eq $a.Name){"[ON]"}else{""}

                        Write-C "  │ " "DarkGray"
                        Write-C " $($i+1) " $affordable
                        Write-C "│ " "DarkGray"
                        Write-C $nameStr "Cyan"
                        Write-C "│ " "DarkGray"
                        Write-C $defStr "White"
                        Write-C "│ " "DarkGray"
                        Write-C $priceStr $affordable
                        Write-CL "│ $equipped" "Yellow"
                    }
                    Write-CL "  └─────┴──────────────────┴────────┴─────────┘" "DarkGray"
                    Write-Host ""
                    Write-C "  Buy # (0=back): " "Yellow"; $aPick = Read-Host
                    $aIdx = [int]$aPick - 1
                    if($aIdx -ge 0 -and $aIdx -lt $slotArmor.Count){
                        $a = $slotArmor[$aIdx]
                        if($script:Gold -ge $a.Price){
                            $script:Gold -= $a.Price
                            if($current){
                                $refund = [math]::Floor($current.Price * 0.4)
                                $script:Gold += $refund
                                Write-CL "  Sold old $($current.Name) for ${refund}g" "DarkGray"
                            }
                            $script:EquippedArmor[$chosenSlot] = $a
                            Write-CL "  Equipped $($a.Name) in $chosenSlot slot! (DEF+$($a.DEF))" "Green"
                            Write-CL "  Total Armor DEF: +$(Get-TotalArmorDEF)" "Cyan"
                        } else { Write-CL "  Not enough gold!" "Red" }
                        Wait-Key
                    }
                }
            }

            # ═══════════════════════════════════════════
            #  POTION SHOP
            # ═══════════════════════════════════════════
            "3" {
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
                    @{Name="Small Health Potion"; Type="Heal";    Power=30; Price=25;  Desc="Restore 30 HP";   Icon="[HP+]";  Category="Potion"}
                    @{Name="Large Health Potion"; Type="Heal";    Power=70; Price=60;  Desc="Restore 70 HP";   Icon="[HP++]"; Category="Potion"}
                    @{Name="Mana Potion";         Type="Mana";    Power=30; Price=30;  Desc="Restore 30 MP";   Icon="[MP+]";  Category="Potion"}
                    @{Name="Large Mana Potion";   Type="Mana";    Power=60; Price=55;  Desc="Restore 60 MP";   Icon="[MP++]"; Category="Potion"}
                    @{Name="Strength Elixir";     Type="ATKBuff"; Power=8;  Price=75;  Desc="ATK+8 in battle"; Icon="[ATK]";  Category="Potion"}
                    @{Name="Iron Skin Elixir";    Type="DEFBuff"; Power=8;  Price=75;  Desc="DEF+8 in battle"; Icon="[DEF]";  Category="Potion"}
                    @{Name="Acid Flask";          Type="Throw";   Power=25; Price=40;  Desc="Deal 25 damage";  Icon="[DMG]";  Category="Throwable"}
                    @{Name="Poison Flask";        Type="ThrowPoison"; Power=15; Price=50; Desc="15 dmg + Poison"; Icon="[PSN]"; Category="Throwable"}
                    @{Name="Frost Bomb";          Type="ThrowSlow";  Power=20; Price=55; Desc="20 dmg + Slow";   Icon="[SLW]"; Category="Throwable"}
                )

                Write-CL "  ── Healing & Buff Potions ──" "Green"
                Write-CL "  ┌─────┬──────────────────────┬────────────────┬─────────┐" "DarkGray"
                Write-CL "  │  #  │ Potion               │ Effect         │ Price   │" "DarkGray"
                Write-CL "  ├─────┼──────────────────────┼────────────────┼─────────┤" "DarkGray"
                for($i=0;$i -lt $potionShop.Count;$i++){
                    $pt=$potionShop[$i]
                    $nameStr = $pt.Name.PadRight(20)
                    $descStr = $pt.Desc.PadRight(14)
                    $priceStr= ("$($pt.Price)g").PadRight(7)
                    $affordable = if($script:Gold -ge $pt.Price){"Green"}else{"DarkGray"}
                    $typeColor = switch($pt.Type){
                        "Heal"{"Green"} "Mana"{"Cyan"} "ATKBuff"{"Yellow"} "DEFBuff"{"Yellow"}
                        "Throw"{"DarkRed"} "ThrowPoison"{"DarkGreen"} "ThrowSlow"{"DarkCyan"}
                        default{"White"}
                    }
                    # Add separator before throwables
                    if($i -eq 6){
                        Write-CL "  ├─────┼──────────────────────┼────────────────┼─────────┤" "DarkGray"
                        Write-CL "  │     │ -- THROWABLES --     │                │         │" "DarkYellow"
                        Write-CL "  ├─────┼──────────────────────┼────────────────┼─────────┤" "DarkGray"
                    }
                    Write-C "  │ " "DarkGray"
                    Write-C " $($i+1) " $affordable
                    Write-C "│ " "DarkGray"
                    Write-C "$nameStr" $typeColor
                    Write-C "│ " "DarkGray"
                    Write-C "$descStr" "White"
                    Write-C "│ " "DarkGray"
                    Write-C "$priceStr" $affordable
                    Write-CL "│" "DarkGray"
                }
                Write-CL "  └─────┴──────────────────────┴────────────────┴─────────┘" "DarkGray"
                Write-Host ""
                Write-C "  Buy # (0=back): " "Yellow"; $pi2=Read-Host
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
                    Wait-Key
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
            #  LEAVE MARKET
            # ═══════════════════════════════════════════
            "5" { $loop=$false }
        }
    }
}




# ─── DUNGEON EXPLORATION LOOP ────────────────────────────────────
function Enter-Dungeon {
    $script:DungeonLevel++
    $script:HasBossKey   = $false
    $script:BossDefeated = $false
    $script:Dungeon = New-Dungeon $script:DungeonLevel

    # Restore some HP/MP on entry
    $script:Player.HP = [math]::Min($script:Player.HP + [math]::Floor($script:Player.MaxHP*0.3), $script:Player.MaxHP)
    $script:Player.MP = [math]::Min($script:Player.MP + [math]::Floor($script:Player.MaxMP*0.3), $script:Player.MaxMP)

    $inDungeon = $true
    while($inDungeon -and $script:Player.HP -gt 0){
        $d = $script:Dungeon
        clr

        Render-Screen

        # Controls
        Write-CL "  [W] Forward  [A] Turn Left  [D] Turn Right  [S] Back  [P] Potion  [Q] Quit" "DarkGray"
        Write-C "  > " "Yellow"
        $key = Read-Host

        switch($key.ToUpper()){
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

                            $bonusGold = 100
                            $script:Gold += $bonusGold
                            Write-CL "  + $bonusGold Gold (Completion Bonus)" "Yellow"

                            Write-Host ""
                            Write-CL "  ── Treasure Haul ──" "Magenta"
                            for($ti=0;$ti -lt 3;$ti++){
                                $treasure = New-RandomLoot ($script:DungeonLevel + 1)
                                [void]$script:Inventory.Add($treasure)
                                Write-CL "    + $($treasure.Name) (Value: $($treasure.Value)g)" "Magenta"
                            }

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
                        $loot = New-RandomLoot $script:DungeonLevel
                        [void]$script:Inventory.Add($loot)
                        $tGold = Get-Random -Min 10 -Max (30 * $script:DungeonLevel)
                        $script:Gold += $tGold
                        $script:StatusMsg = "Treasure! Found $($loot.Name) and ${tGold}g!"
                        $d.Grid[$ny,$nx] = 0
                        Update-QuestProgress "Treasure"
                        $d.PX = $nx; $d.PY = $ny
                    }

                    elseif($cell -eq 7){
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
                        Wait-Key
                    }
                    else {
                        $d.PX = $nx; $d.PY = $ny
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
                        $pidx = [int]$pc - 1

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
    $classOrder = @("Knight","Mage","Brawler","Ranger","Cleric","Necromancer")
    clr
    Write-CL "" "White"
    Write-CL "  ╔══════════════════════════════════════════════╗" "DarkCyan"
    Write-CL "  ║       DEPTHS OF POWERSHELL                   ║" "Cyan"
    Write-CL "  ║       A Dungeon Crawler                      ║" "DarkCyan"
    Write-CL "  ╚══════════════════════════════════════════════╝" "DarkCyan"
    Write-Host ""
    Write-CL "  Choose your class:" "White"
    Write-Host ""

    for($i=0; $i -lt $classOrder.Count; $i++){
        $key = $classOrder[$i]
        $c = $classes[$key]
        $color = switch($key){
            "Knight"      {"Yellow"}
            "Mage"        {"Cyan"}
            "Brawler"     {"Red"}
            "Ranger"      {"Green"}
            "Cleric"      {"White"}
            "Necromancer" {"Magenta"}
        }
        Write-CL "  [$($i+1)] $($c.Name)" $color
        Write-CL "      $($c.Desc)" "DarkGray"
        Write-CL "      HP:$($c.MaxHP) MP:$($c.MaxMP) ATK:$($c.ATK) DEF:$($c.DEF) SPD:$($c.SPD) MAG:$($c.MAG)" "Gray"
        Write-C "      Abilities: " "DarkGray"
        Write-CL (($c.Abilities | ForEach-Object { $_.Name }) -join ", ") "Cyan"
        Write-C "      Weapon Affinity: " "DarkGray"
        Write-CL $c.Affinity "DarkYellow"
        Write-Host ""
    }

    Write-CL "  ┌──────────────────────────────────────────────────────┐" "DarkGray"
    Write-CL "  │  TIP: Weapons have class affinities. Equipping a    │" "DarkGray"
    Write-CL "  │  weapon matching your class grants bonus ATK!        │" "DarkGray"
    Write-CL "  └──────────────────────────────────────────────────────┘" "DarkGray"
    Write-Host ""

    Write-C "  > " "Yellow"; $pick = Read-Host
    $pickIdx = [int]$pick - 1
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
                @{Name="Shield Bash"; Cost=8;  Type="Physical"; Power=18; Effect="Stun"}
                @{Name="Holy Strike"; Cost=12; Type="Physical"; Power=28; Effect="None"}
                @{Name="Fortify";     Cost=10; Type="Buff";     Power=0;  Effect="DEF+5"}
            )
            Desc="High defense, strong melee attacks, sturdy."
            Affinity="Sword"
        }
        Mage = @{
            Name="Mage"; MaxHP=75; HP=75; MaxMP=80; MP=80
            ATK=6; DEF=5; SPD=10; MAG=18
            Abilities=@(
                @{Name="Fireball";      Cost=15; Type="Magic"; Power=30; Effect="Burn"}
                @{Name="Ice Shard";     Cost=12; Type="Magic"; Power=22; Effect="Slow"}
                @{Name="Arcane Shield"; Cost=20; Type="Buff";  Power=0;  Effect="DEF+8"}
            )
            Desc="Devastating magic, large MP pool, fragile."
            Affinity="Staff"
        }
        Brawler = @{
            Name="Brawler"; MaxHP=100; HP=100; MaxMP=40; MP=40
            ATK=16; DEF=8; SPD=12; MAG=3
            Abilities=@(
                @{Name="Fury Punch"; Cost=10; Type="Physical"; Power=24; Effect="None"}
                @{Name="Whirlwind";  Cost=15; Type="Physical"; Power=20; Effect="Bleed"}
                @{Name="Battle Cry"; Cost=12; Type="Buff";     Power=0;  Effect="ATK+5"}
            )
            Desc="Fast and aggressive, high attack, less durable."
            Affinity="Fist"
        }
        Ranger = @{
            Name="Ranger"; MaxHP=90; HP=90; MaxMP=50; MP=50
            ATK=12; DEF=7; SPD=15; MAG=6
            Abilities=@(
                @{Name="Quick Shot";   Cost=8;  Type="Physical"; Power=20; Effect="None"}
                @{Name="Poison Arrow"; Cost=14; Type="Physical"; Power=18; Effect="Poison"}
                @{Name="Shadow Step";  Cost=10; Type="Buff";     Power=0;  Effect="DEF+4"}
            )
            Desc="Fast and precise, high speed, evasive fighter."
            Affinity="Bow"
        }
        Cleric = @{
            Name="Cleric"; MaxHP=95; HP=95; MaxMP=70; MP=70
            ATK=8; DEF=10; SPD=7; MAG=14
            Abilities=@(
                @{Name="Smite";       Cost=12; Type="Magic"; Power=24; Effect="None"}
                @{Name="Holy Heal";   Cost=18; Type="Heal";  Power=40; Effect="None"}
                @{Name="Divine Ward"; Cost=15; Type="Buff";  Power=0;  Effect="DEF+7"}
            )
            Desc="Holy support, self-heals in combat, solid defense."
            Affinity="Mace"
        }
        Necromancer = @{
            Name="Necromancer"; MaxHP=70; HP=70; MaxMP=75; MP=75
            ATK=7; DEF=4; SPD=9; MAG=20
            Abilities=@(
                @{Name="Soul Drain"; Cost=14; Type="Magic";     Power=26; Effect="Drain"}
                @{Name="Curse";      Cost=16; Type="Magic";     Power=20; Effect="Weaken"}
                @{Name="Dark Pact";  Cost=0;  Type="Sacrifice"; Power=35; Effect="SacrificeHP"}
            )
            Desc="Dark magic master, drains life, fragile but deadly."
            Affinity="Scythe"
        }
    }
}

# ─── QUEST SYSTEM ─────────────────────────────────────────────────
function Get-RandomQuests {
    param([int]$DungeonLvl)
    $templates = @(
        @{Type="Kill";     DescTemplate="Slay {0} enemies in the dungeon";   TMin=3; TMax=7}
        @{Type="Kill";     DescTemplate="Defeat {0} foes to prove your worth"; TMin=5; TMax=10}
        @{Type="MiniBoss"; DescTemplate="Defeat the dungeon mini-boss";      TMin=1; TMax=1}
        @{Type="Boss";     DescTemplate="Defeat the dungeon boss";           TMin=1; TMax=1}
        @{Type="Rescue";   DescTemplate="Rescue the lost adventurer";        TMin=1; TMax=1}
        @{Type="Treasure"; DescTemplate="Open {0} treasure chests";          TMin=2; TMax=5}
    )
    $picked = $templates | Get-Random -Count 3
    $result = [System.Collections.ArrayList]@()
    foreach($t in $picked){
        $count = Get-Random -Min $t.TMin -Max ($t.TMax + 1)
        $desc = if($t.DescTemplate -match '\{0\}'){$t.DescTemplate -f $count}else{$t.DescTemplate}
        $goldReward = switch($t.Type){
            "Kill"     { 40 + $DungeonLvl * 20 + $count * 5 }
            "MiniBoss" { 80 + $DungeonLvl * 30 }
            "Boss"     { 150 + $DungeonLvl * 40 }
            "Rescue"   { 60 + $DungeonLvl * 25 }
            "Treasure" { 50 + $DungeonLvl * 15 + $count * 5 }
        }
        $xpReward = switch($t.Type){
            "Kill"     { 30 + $DungeonLvl * 15 + $count * 5 }
            "MiniBoss" { 60 + $DungeonLvl * 25 }
            "Boss"     { 100 + $DungeonLvl * 30 }
            "Rescue"   { 40 + $DungeonLvl * 20 }
            "Treasure" { 25 + $DungeonLvl * 15 }
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
        Write-CL "" "White"
        Write-CL "  ╔════════════════════════════════════════════════════╗" "DarkYellow"
        Write-CL "  ║          Q U E S T   B O A R D                     ║" "Yellow"
        Write-CL "  ╚════════════════════════════════════════════════════╝" "DarkYellow"
        Write-Host ""
        Write-CL "       ___________________________" "DarkGray"
        Write-CL "      |    |            |    |    |" "DarkGray"
        Write-CL "      |HELP| ADVENTURER |GOLD|FAME|" "DarkYellow"
        Write-CL "      | !  |  WANTED!!  | $$ | ** |" "Yellow"
        Write-CL "      |____|____________|____|____|" "DarkGray"
        Write-CL "      |         QUEST              |" "DarkGray"
        Write-CL "      |         BOARD              |" "DarkYellow"
        Write-CL "      |___________________________|" "DarkGray"
        Write-Host ""

        # ── Active Quests ──
        Write-CL "  ╔══════════════════════════════════════════════╗" "DarkCyan"
        Write-CL "  ║  A C T I V E   Q U E S T S                   ║" "Cyan"
        Write-CL "  ╠══════════════════════════════════════════════╣" "DarkCyan"
        if($script:Quests.Count -eq 0){
            Write-CL "  ║  No active quests. Accept one below!         ║" "DarkGray"
        } else {
            for($i=0;$i -lt $script:Quests.Count;$i++){
                $q = $script:Quests[$i]
                $statusIcon = if($q.TurnedIn){"[DONE]"}elseif($q.Complete){"[READY]"}else{"[$($q.Progress)/$($q.TargetCount)]"}
                $statusColor = if($q.TurnedIn){"DarkGray"}elseif($q.Complete){"Green"}else{"Yellow"}
                $desc = $q.Desc
                if($desc.Length -gt 30){$desc = $desc.Substring(0,30)}
                Write-C "  ║  " "DarkCyan"
                Write-C $statusIcon $statusColor
                Write-C " $desc" "White"
                $qPad = 40 - $statusIcon.Length - $desc.Length
                if($qPad -lt 0){$qPad=0}
                Write-CL "$(' ' * $qPad)║" "DarkCyan"
            }
        }
        Write-CL "  ╚══════════════════════════════════════════════╝" "DarkCyan"
        Write-Host ""

        # ── Available Quests ──
        Write-CL "  ╔══════════════════════════════════════════════╗" "DarkGreen"
        Write-CL "  ║  A V A I L A B L E                           ║" "Green"
        Write-CL "  ╠══════════════════════════════════════════════╣" "DarkGreen"
        $avail = @($script:AvailableQuests | Where-Object { -not $_.TurnedIn })
        if($avail.Count -eq 0){
            Write-CL "  ║  No quests available. Enter a dungeon and     ║" "DarkGray"
            Write-CL "  ║  come back later!                              ║" "DarkGray"
        } else {
            for($i=0;$i -lt $avail.Count;$i++){
                $q = $avail[$i]
                Write-C "  ║  " "DarkGreen"
                Write-C "[$($i+1)] " "White"
                Write-C "$($q.Desc)" "Green"
                $dPad = 37 - $q.Desc.Length
                if($dPad -lt 0){$dPad=0}
                Write-CL "$(' ' * $dPad)║" "DarkGreen"
                Write-C "  ║      " "DarkGreen"
                Write-C "Reward: $($q.RewardGold)g + $($q.RewardXP) XP" "Yellow"
                $rStr = "Reward: $($q.RewardGold)g + $($q.RewardXP) XP"
                $rPad = 37 - $rStr.Length
                if($rPad -lt 0){$rPad=0}
                Write-CL "$(' ' * $rPad)║" "DarkGreen"
            }
        }
        Write-CL "  ╚══════════════════════════════════════════════╝" "DarkGreen"
        Write-Host ""

        # ── Options ──
        Write-CL "  ┌───────────────────────────────────────────┐" "DarkGray"
        Write-C  "  │  " "DarkGray"; Write-C "[A]" "Green";   Write-CL " Accept a quest                      │" "DarkGray"
        Write-C  "  │  " "DarkGray"; Write-C "[T]" "Yellow";  Write-CL " Turn in completed quest             │" "DarkGray"
        Write-C  "  │  " "DarkGray"; Write-C "[R]" "DarkCyan";Write-CL " Refresh available quests (free)     │" "DarkGray"
        Write-C  "  │  " "DarkGray"; Write-C "[0]" "White";   Write-CL " Back                                │" "DarkGray"
        Write-CL "  └───────────────────────────────────────────┘" "DarkGray"
        Write-Host ""
        Write-C "  > " "Yellow"; $qCh = Read-Host

        switch($qCh.ToUpper()){
            "A" {
                if($script:Quests.Count -ge 3){
                    Write-CL "  You can only hold 3 quests at a time!" "Red"
                    Wait-Key
                } elseif($avail.Count -eq 0){
                    Write-CL "  No quests to accept!" "Red"
                    Wait-Key
                } else {
                    Write-C "  Accept quest #: " "Yellow"; $qPick = Read-Host
                    $qIdx = [int]$qPick - 1
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
                    Wait-Key
                } else {
                    Write-CL "  ── Completed Quests ──" "Yellow"
                    for($ti=0;$ti -lt $ready.Count;$ti++){
                        $rq = $ready[$ti]
                        Write-CL "  [$($ti+1)] $($rq.Desc) - $($rq.RewardGold)g + $($rq.RewardXP) XP" "Green"
                    }
                    Write-C "  Turn in #: " "Yellow"; $tPick = Read-Host
                    $tIdx = [int]$tPick - 1
                    if($tIdx -ge 0 -and $tIdx -lt $ready.Count){
                        $rq = $ready[$tIdx]
                        $rq.TurnedIn = $true
                        $script:Gold += $rq.RewardGold
                        $questXP = $rq.RewardXP
                        if($script:Partner -and $script:Partner.Class -eq "Bard"){
                            $questXPBonus = [math]::Floor($rq.RewardXP * 0.25)
                            $questXP += $questXPBonus
                        }
                        $script:XP += $questXP

                        Write-Host ""
                        Write-CL "  ╔══════════════════════════════════════╗" "Yellow"
                        Write-CL "  ║     QUEST COMPLETE!                  ║" "Yellow"
                        Write-CL "  ╚══════════════════════════════════════╝" "Yellow"
                        Write-CL "  + $($rq.RewardGold) Gold" "Yellow"
                        Write-CL "  + $questXP XP" "Cyan"
                        if($script:Partner -and $script:Partner.Class -eq "Bard"){
                            Write-CL "    ($($script:Partner.Name): +$questXPBonus bonus XP)" "DarkCyan"
                        }


                        # Check level up
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
                        # Remove turned-in quest from active list
                        $script:Quests.Remove($rq)
                        Wait-Key
                    }
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
        # Swords (Knight affinity) - Bleed perk on all blades
        @{Name="Iron Sword";       ATK=4;  Price=60;  WeaponType="Sword";  ClassAffinity="Knight";     AffinityBonus=3; Perk="Bleed"; PerkChance=15}
        @{Name="Steel Blade";      ATK=8;  Price=150; WeaponType="Sword";  ClassAffinity="Knight";     AffinityBonus=3; Perk="Bleed"; PerkChance=20}
        @{Name="Holy Sword";       ATK=14; Price=400; WeaponType="Sword";  ClassAffinity="Knight";     AffinityBonus=4; Perk="Bleed"; PerkChance=25}
        @{Name="Dragon Slayer";    ATK=20; Price=800; WeaponType="Sword";  ClassAffinity="Knight";     AffinityBonus=5; Perk="Bleed"; PerkChance=30}
        # Staves (Mage affinity) - MAGBonus on all staves
        @{Name="Wooden Staff";     ATK=3;  Price=50;  WeaponType="Staff";  ClassAffinity="Mage";       AffinityBonus=3; Perk=$null;   PerkChance=0;  MAGBonus=3}
        @{Name="Enchanted Staff";  ATK=6;  Price=200; WeaponType="Staff";  ClassAffinity="Mage";       AffinityBonus=4; Perk="Burn";  PerkChance=20; MAGBonus=6}
        @{Name="Arcane Staff";     ATK=10; Price=450; WeaponType="Staff";  ClassAffinity="Mage";       AffinityBonus=5; Perk="Burn";  PerkChance=30; MAGBonus=10}
        # Fists (Brawler affinity)
        @{Name="Iron Knuckles";    ATK=5;  Price=55;  WeaponType="Fist";   ClassAffinity="Brawler";    AffinityBonus=3; Perk=$null;   PerkChance=0}
        @{Name="Spiked Gauntlets"; ATK=10; Price=180; WeaponType="Fist";   ClassAffinity="Brawler";    AffinityBonus=4; Perk="Bleed"; PerkChance=20}
        @{Name="Titan Fists";      ATK=16; Price=500; WeaponType="Fist";   ClassAffinity="Brawler";    AffinityBonus=5; Perk=$null;   PerkChance=0}
        # Bows (Ranger affinity)
        @{Name="Short Bow";        ATK=4;  Price=55;  WeaponType="Bow";    ClassAffinity="Ranger";     AffinityBonus=3; Perk=$null;   PerkChance=0}
        @{Name="Longbow";          ATK=9;  Price=200; WeaponType="Bow";    ClassAffinity="Ranger";     AffinityBonus=4; Perk=$null;   PerkChance=0}
        @{Name="Elven Bow";        ATK=14; Price=450; WeaponType="Bow";    ClassAffinity="Ranger";     AffinityBonus=5; Perk="Poison";PerkChance=25}
        # Maces (Cleric affinity)
        @{Name="Wooden Mace";      ATK=4;  Price=50;  WeaponType="Mace";   ClassAffinity="Cleric";     AffinityBonus=3; Perk=$null;   PerkChance=0}
        @{Name="Iron Mace";        ATK=8;  Price=170; WeaponType="Mace";   ClassAffinity="Cleric";     AffinityBonus=4; Perk=$null;   PerkChance=0}
        @{Name="Holy Mace";        ATK=13; Price=420; WeaponType="Mace";   ClassAffinity="Cleric";     AffinityBonus=5; Perk="Stun";  PerkChance=20}
        # Scythes (Necromancer affinity)
        @{Name="Rusty Scythe";     ATK=5;  Price=60;  WeaponType="Scythe"; ClassAffinity="Necromancer"; AffinityBonus=3; Perk="Bleed"; PerkChance=15}
        @{Name="Shadow Scythe";    ATK=10; Price=220; WeaponType="Scythe"; ClassAffinity="Necromancer"; AffinityBonus=4; Perk="Drain"; PerkChance=25}
        @{Name="Death's Scythe";   ATK=16; Price=550; WeaponType="Scythe"; ClassAffinity="Necromancer"; AffinityBonus=5; Perk="Drain"; PerkChance=30}
        # Daggers & Other
        @{Name="Shadow Dagger";    ATK=12; Price=350; WeaponType="Dagger"; ClassAffinity="Ranger";     AffinityBonus=3; Perk="Bleed"; PerkChance=25}
        @{Name="War Hammer";       ATK=12; Price=300; WeaponType="Hammer"; ClassAffinity="Brawler";    AffinityBonus=3; Perk=$null;   PerkChance=0}
    )
}

# Returns all potions and throwables in a FIXED ORDER (index 0-8).
# Save/Load uses these indices to store which potions the player has.
# Index 0-5 = regular potions, index 6-8 = throwable potions.
function Get-PotionShop {
    @(
        @{Name="Small Health Potion"; Type="Heal";        Power=30; Price=25; Desc="Restore 30 HP";   Category="Potion"}
        @{Name="Large Health Potion"; Type="Heal";        Power=70; Price=60; Desc="Restore 70 HP";   Category="Potion"}
        @{Name="Mana Potion";         Type="Mana";        Power=30; Price=30; Desc="Restore 30 MP";   Category="Potion"}
        @{Name="Large Mana Potion";   Type="Mana";        Power=60; Price=55; Desc="Restore 60 MP";   Category="Potion"}
        @{Name="Strength Elixir";     Type="ATKBuff";     Power=8;  Price=75; Desc="ATK+8 in battle"; Category="Potion"}
        @{Name="Iron Skin Elixir";    Type="DEFBuff";     Power=8;  Price=75; Desc="DEF+8 in battle"; Category="Potion"}
        @{Name="Acid Flask";          Type="Throw";       Power=25; Price=40; Desc="Deal 25 damage";  Category="Throwable"}
        @{Name="Poison Flask";        Type="ThrowPoison"; Power=15; Price=50; Desc="15 dmg + Poison"; Category="Throwable"}
        @{Name="Frost Bomb";          Type="ThrowSlow";   Power=20; Price=55; Desc="20 dmg + Slow";   Category="Throwable"}
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
    $classOrder = @("Knight","Mage","Brawler","Ranger","Cleric","Necromancer")
    $classIdx = 0
    for($i = 0; $i -lt $classOrder.Count; $i++){
        if($classOrder[$i] -eq $script:PlayerClass){ $classIdx = $i; break }
    }

    # ── Weapon index: 0 = none, 1+ = position in shop ──
    $weapIdx = 0
    if($script:EquippedWeapon){
        $weapons = Get-WeaponShop
        for($i = 0; $i -lt $weapons.Count; $i++){
            if($weapons[$i].Name -eq $script:EquippedWeapon.Name){
                $weapIdx = $i + 1
                break
            }
        }
    }

    # ── Armor indices: 0 = empty, 1+ = position in shop ──
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

    # ── Potion counts (6 regular, 3 throwable) ──
    $potShop = Get-PotionShop
    $potCounts = @(0, 0, 0, 0, 0, 0)
    $throwCounts = @(0, 0, 0)

    foreach($pot in $script:Potions){
        for($i = 0; $i -lt 6; $i++){
            if($pot.Name -eq $potShop[$i].Name){
                $potCounts[$i]++
                break
            }
        }
    }
    foreach($tp in $script:ThrowablePotions){
        for($i = 6; $i -lt 9; $i++){
            if($tp.Name -eq $potShop[$i].Name){
                $throwCounts[$i - 6]++
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

    # ── Build save string: values joined by "|" ──
    $saveStr = @(
        "1"                          # [0]  format version
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
        $script:KillCount            # [15] kills
        $script:RoyalSuiteUses       # [16] royal suite uses
        $weapIdx                     # [17] weapon
        ($armorIndices -join ",")    # [18] armor "h,c,s,a,b"
        ($potCounts -join ",")       # [19] potion counts
        ($throwCounts -join ",")     # [20] throwable counts
        $partnerIdx                  # [21] partner
    ) -join "|"

    # ── Checksum ──
    # Add up all character codes in the string. If the player makes a typo
    # when entering the code later, this number won't match and we catch it.
    $sum = 0
    foreach($char in $saveStr.ToCharArray()){ $sum += [int]$char }
    $checksum = $sum % 9999
    $saveStr += "|$checksum"

    # ── Base64 encode ──
    # Converts the text into a safe string of letters, numbers, +, /, and =.
    # This is what the player copies down.
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
    # We expect 23 sections separated by "|" (22 data fields + 1 checksum).
    $parts = $saveStr -split '\|'
    if($parts.Count -ne 23){
        return @{ Success = $false; Error = "Save code is corrupted (wrong length)." }
    }

    # ── Verify checksum ──
    # Rebuild the string WITHOUT the last part (the checksum itself),
    # calculate what the checksum should be, and compare.
    $dataStr = ($parts[0..21]) -join "|"
    $sum = 0
    foreach($char in $dataStr.ToCharArray()){ $sum += [int]$char }
    $expectedCheck = $sum % 9999
    $actualCheck = [int]$parts[22]
    if($expectedCheck -ne $actualCheck){
        return @{ Success = $false; Error = "Checksum mismatch. Code may have a typo." }
    }

    # ── Verify version ──
    if($parts[0] -ne "1"){
        return @{ Success = $false; Error = "Unknown save format version." }
    }

    # ── Parse all the values ──
    # [int] converts text like "5" into the number 5.
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

    # Armor is stored as "h,c,s,a,b" — split by comma into 5 numbers
    $armorParts     = $parts[18] -split ','
    # Potions stored as "p0,p1,p2,p3,p4,p5"
    $potParts       = $parts[19] -split ','
    # Throwables stored as "t0,t1,t2"
    $throwParts     = $parts[20] -split ','
    $partnerIdx     = [int]$parts[21]

    # ── Validate class index ──
    $classOrder = @("Knight","Mage","Brawler","Ranger","Cleric","Necromancer")
    if($classIdx -lt 0 -or $classIdx -ge $classOrder.Count){
        return @{ Success = $false; Error = "Invalid class in save." }
    }
    $className = $classOrder[$classIdx]

    # ── Rebuild the player ──
    # Get the class template for abilities (abilities don't change with levels,
    # so we always pull them fresh from the template).
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
    # 0 = no weapon, 1+ = index into the weapon shop array
    $script:EquippedWeapon = $null
    if($weapIdx -gt 0){
        $weapons = Get-WeaponShop
        if($weapIdx -le $weapons.Count){
            $script:EquippedWeapon = $weapons[$weapIdx - 1]
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
            $script:EquippedArmor[$armorSlots[$s]] = $allArmor[$aIdx - 1]
        }
    }

    # ── Rebuild potions ──
    $script:Potions = [System.Collections.ArrayList]@()
    $script:ThrowablePotions = [System.Collections.ArrayList]@()
    $potShop = Get-PotionShop

    # Regular potions (indices 0-5 in the shop)
    for($i = 0; $i -lt 6; $i++){
        $count = [int]$potParts[$i]
        for($c = 0; $c -lt $count; $c++){
            [void]$script:Potions.Add($potShop[$i])
        }
    }
    # Throwables (indices 6-8 in the shop)
    for($i = 0; $i -lt 3; $i++){
        $count = [int]$throwParts[$i]
        for($c = 0; $c -lt $count; $c++){
            [void]$script:ThrowablePotions.Add($potShop[$i + 6])
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

    # ── Reset things that don't carry over ──
    $script:Inventory = [System.Collections.ArrayList]@()
    $script:Quests = [System.Collections.ArrayList]@()
    $script:AvailableQuests = $null
    $script:HasBossKey = $false
    $script:BossDefeated = $false
    $script:Dungeon = $null
    $script:DungeonKills = 0
    $script:DungeonTreasures = 0
    $script:RescueTarget = $null

    return @{ Success = $true; Error = "" }
}


function Get-ArmorShop {
    @(
        # Helmets
        @{Name="Leather Cap";     Slot="Helmet"; DEF=2;  Price=30}
        @{Name="Iron Helm";       Slot="Helmet"; DEF=4;  Price=80}
        @{Name="Steel Helm";      Slot="Helmet"; DEF=7;  Price=200}
        @{Name="Dragon Helm";     Slot="Helmet"; DEF=10; Price=450}
        # Chest
        @{Name="Leather Vest";    Slot="Chest";  DEF=3;  Price=40}
        @{Name="Chain Mail";      Slot="Chest";  DEF=6;  Price=120}
        @{Name="Plate Armor";     Slot="Chest";  DEF=10; Price=300}
        @{Name="Dragon Plate";    Slot="Chest";  DEF=14; Price=600}
        # Shields
        @{Name="Wooden Shield";   Slot="Shield"; DEF=2;  Price=25}
        @{Name="Iron Shield";     Slot="Shield"; DEF=5;  Price=100}
        @{Name="Tower Shield";    Slot="Shield"; DEF=8;  Price=250}
        @{Name="Enchanted Ward";  Slot="Shield"; DEF=11; Price=500}
        # Amulets
        @{Name="Copper Amulet";   Slot="Amulet"; DEF=1;  Price=35}
        @{Name="Silver Amulet";   Slot="Amulet"; DEF=3;  Price=90}
        @{Name="Gold Amulet";     Slot="Amulet"; DEF=5;  Price=220}
        @{Name="Diamond Amulet";  Slot="Amulet"; DEF=7;  Price=480}
        # Boots
        @{Name="Leather Boots";   Slot="Boots";  DEF=1;  Price=25}
        @{Name="Iron Greaves";    Slot="Boots";  DEF=3;  Price=75}
        @{Name="Steel Greaves";   Slot="Boots";  DEF=6;  Price=180}
        @{Name="Dragon Boots";    Slot="Boots";  DEF=9;  Price=400}
    )
}


# ─── MAIN MENU / GAME LOOP ──────────────────────────────────────
function Show-MainMenu {
    while($script:GameRunning){
        clr
        $p = $script:Player
        Write-CL "" "White"
        Write-CL "  ╔══════════════════════════════════════════════╗" "DarkYellow"
        Write-CL "  ║             TOWN SQUARE                      ║" "Yellow"
        Write-CL "  ╚══════════════════════════════════════════════╝" "DarkYellow"
        Write-Host ""
                Write-CL "  $($p.Name) | Lv$($script:PlayerLevel) | HP:$($p.HP)/$($p.MaxHP) MP:$($p.MP)/$($p.MaxMP) | Gold:$($script:Gold) | XP:$($script:XP)/$($script:XPToNext)" "Gray"
        Write-CL "  Weapon: $(if($script:EquippedWeapon){$script:EquippedWeapon.Name + ' (ATK+' + $script:EquippedWeapon.ATK + ')'}else{'Bare Hands'})" "DarkGray"
        Write-CL "  Potions: $($script:Potions.Count)  |  Loot Items: $($script:Inventory.Count)" "DarkGray"
        Write-CL "  Dungeons Cleared: $($script:DungeonLevel)" "DarkGray"
        Write-Host ""
        Write-CL "  [1] Enter Dungeon (Level $($script:DungeonLevel + 1))" "White"
        Write-CL "  [2] Visit Market" "White"
        Write-CL "  [3] View Inventory" "White"
        Write-CL "  [4] Rest (Restore HP/MP)" "White"
        Write-CL "  [5] View Stats & Abilities" "White"
        Write-CL "  [6] Quest Board" "White"
        Write-CL "  [7] Guild Hall" "White"
        Write-CL "  [8] Quit Game" "White"
        Write-CL "  [9] Save Game" "White"

        Write-Host ""
        Write-C "  > " "Yellow"; $ch = Read-Host

        switch($ch){
            "1" { Enter-Dungeon }
            "2" { Show-Market }
                                   "3" {
                $invLoop = $true
                while($invLoop){
                    clr
                    Write-CL "" "White"
                    Write-CL "  ╔════════════════════════════════════════════════════╗" "DarkCyan"
                    Write-CL "  ║              I N V E N T O R Y                     ║" "Cyan"
                    Write-CL "  ╚════════════════════════════════════════════════════╝" "DarkCyan"
                    Write-Host ""

                    # ── Character Summary ──
                    $p = $script:Player
                    $wepATK = Get-TotalWeaponATK
                    $armorDEF = Get-TotalArmorDEF
                    $magBonus = Get-WeaponMAGBonus

                    Write-C "  $($p.Name)" "Green"
                    Write-C "  ($($script:PlayerClass))" "Cyan"
                    Write-CL "  Lv$($script:PlayerLevel)  |  Gold: $($script:Gold)g" "DarkGray"
                    Write-Host ""

                    # ── Equipped Weapon ──
                    Write-CL "  ╔══════════════════════════════════════════════╗" "DarkYellow"
                    Write-CL "  ║  W E A P O N                                 ║" "Yellow"
                    Write-CL "  ╠══════════════════════════════════════════════╣" "DarkYellow"
                    if($script:EquippedWeapon){
                        $w = $script:EquippedWeapon
                        $cb = Get-WeaponClassBonus
                        $cbStr = if($cb -gt 0){" [+$cb class bonus]"}else{""}
                        $perkStr = if($w.Perk){" [$($w.Perk) $($w.PerkChance)%]"}else{""}
                        $magStr = if($w.MAGBonus){" [MAG+$($w.MAGBonus)]"}else{""}
                        Write-C "  ║  " "DarkYellow"
                        Write-C "$($w.Name)" "Cyan"
                        Write-C "  ATK+$($w.ATK)" "White"
                        Write-C $cbStr "Green"
                        Write-C $perkStr "DarkRed"
                        Write-C $magStr "Magenta"
                        $totalLen = $w.Name.Length + "  ATK+$($w.ATK)".Length + $cbStr.Length + $perkStr.Length + $magStr.Length
                        $wPad = 42 - $totalLen
                        if($wPad -lt 0){$wPad = 0}
                        Write-CL "$(' ' * $wPad)║" "DarkYellow"
                    } else {
                        Write-CL "  ║  Bare Hands                                 ║" "DarkGray"
                    }
                    Write-CL "  ╚══════════════════════════════════════════════╝" "DarkYellow"
                    Write-Host ""

                    # ── Equipped Armor ──
                    Write-CL "  ╔══════════════════════════════════════════════╗" "DarkCyan"
                    Write-CL "  ║  A R M O R                    DEF: +$("$armorDEF".PadRight(8))║" "Cyan"
                    Write-CL "  ╠══════════════════════════════════════════════╣" "DarkCyan"
                    $slots = @("Helmet","Chest","Shield","Amulet","Boots")
                    foreach($slot in $slots){
                        $piece = $script:EquippedArmor[$slot]
                        $slotLabel = "$($slot):".PadRight(9)
                        Write-C "  ║  " "DarkCyan"
                        Write-C $slotLabel "White"
                        if($piece){
                            $pName = "$($piece.Name) (DEF+$($piece.DEF))"
                            Write-C $pName "Cyan"
                            $aPad = 33 - $slotLabel.Length - $pName.Length + 9
                            if($aPad -lt 0){$aPad = 0}
                            Write-CL "$(' ' * $aPad)║" "DarkCyan"
                        } else {
                            Write-C "(empty)" "DarkGray"
                            $aPad = 33 - $slotLabel.Length - 7 + 9
                            if($aPad -lt 0){$aPad = 0}
                            Write-CL "$(' ' * $aPad)║" "DarkCyan"
                        }
                    }
                    Write-CL "  ╚══════════════════════════════════════════════╝" "DarkCyan"
                    Write-Host ""

                    # ── Potions ──
                    Write-CL "  ╔══════════════════════════════════════════════╗" "DarkGreen"
                    Write-CL "  ║  P O T I O N S  ($($script:Potions.Count) / 10)                       ║" "Green"
                    Write-CL "  ╠══════════════════════════════════════════════╣" "DarkGreen"
                    if($script:Potions.Count -eq 0){
                        Write-CL "  ║  (empty)                                     ║" "DarkGray"
                    } else {
                        $potionGroups = @{}
                        foreach($pt in $script:Potions){
                            if($potionGroups.ContainsKey($pt.Name)){
                                $potionGroups[$pt.Name].Count++
                            } else {
                                $potionGroups[$pt.Name] = @{Count=1;Desc=$pt.Desc;Type=$pt.Type}
                            }
                        }
                        foreach($key in $potionGroups.Keys){
                            $pg = $potionGroups[$key]
                            $typeIcon = switch($pg.Type){
                                "Heal"{"[HP]"} "Mana"{"[MP]"} "ATKBuff"{"[AT]"} "DEFBuff"{"[DF]"} default{"[??]"}
                            }
                            $typeColor = switch($pg.Type){
                                "Heal"{"Green"} "Mana"{"Cyan"} "ATKBuff"{"Yellow"} "DEFBuff"{"Yellow"} default{"White"}
                            }
                            Write-C "  ║  " "DarkGreen"
                            Write-C $typeIcon $typeColor
                            Write-C " $key" "White"
                            Write-C " x$($pg.Count)" "DarkGray"
                            $ppad = 38 - $key.Length - $typeIcon.Length - " x$($pg.Count)".Length
                            if($ppad -lt 0){$ppad=0}
                            Write-CL "$(' ' * $ppad)║" "DarkGreen"
                        }
                    }
                    Write-CL "  ╚══════════════════════════════════════════════╝" "DarkGreen"
                    Write-Host ""

                    # ── Throwables ──
                    Write-CL "  ╔══════════════════════════════════════════════╗" "DarkYellow"
                    Write-CL "  ║  T H R O W A B L E S  ($($script:ThrowablePotions.Count) / 5)                  ║" "DarkYellow"
                    Write-CL "  ╠══════════════════════════════════════════════╣" "DarkYellow"
                    if($script:ThrowablePotions.Count -eq 0){
                        Write-CL "  ║  (empty)                                     ║" "DarkGray"
                    } else {
                        $throwGroups = @{}
                        foreach($tp in $script:ThrowablePotions){
                            if($throwGroups.ContainsKey($tp.Name)){
                                $throwGroups[$tp.Name].Count++
                            } else {
                                $throwGroups[$tp.Name] = @{Count=1;Desc=$tp.Desc;Type=$tp.Type}
                            }
                        }
                        foreach($key in $throwGroups.Keys){
                            $tg = $throwGroups[$key]
                            $tIcon = switch($tg.Type){
                                "Throw"{"[DMG]"} "ThrowPoison"{"[PSN]"} "ThrowSlow"{"[SLW]"} default{"[??]"}
                            }
                            $tColor = switch($tg.Type){
                                "Throw"{"Red"} "ThrowPoison"{"DarkGreen"} "ThrowSlow"{"DarkCyan"} default{"White"}
                            }
                            Write-C "  ║  " "DarkYellow"
                            Write-C $tIcon $tColor
                            Write-C " $key" "White"
                            Write-C " x$($tg.Count)" "DarkGray"
                            $tpad = 37 - $key.Length - $tIcon.Length - " x$($tg.Count)".Length
                            if($tpad -lt 0){$tpad=0}
                            Write-CL "$(' ' * $tpad)║" "DarkYellow"
                        }
                    }
                    Write-CL "  ╚══════════════════════════════════════════════╝" "DarkYellow"
                    Write-Host ""

                    # ── Loot ──
                    Write-CL "  ╔══════════════════════════════════════════════╗" "DarkMagenta"
                    Write-CL "  ║  L O O T  ($($script:Inventory.Count) items)                          ║" "Magenta"
                    Write-CL "  ╠══════════════════════════════════════════════╣" "DarkMagenta"
                    if($script:Inventory.Count -eq 0){
                        Write-CL "  ║  (empty)                                     ║" "DarkGray"
                    } else {
                        $totalVal = 0
                        for($i=0;$i -lt $script:Inventory.Count;$i++){
                            $it=$script:Inventory[$i]
                            $totalVal += $it.Value
                            $iName = "$($i+1). $($it.Name)"
                            $iVal  = "$($it.Value)g"
                            Write-C "  ║  " "DarkMagenta"
                            Write-C $iName.PadRight(32) "Magenta"
                            Write-C $iVal "Yellow"
                            $lPad = 8 - $iVal.Length
                            if($lPad -lt 0){$lPad=0}
                            Write-CL "$(' ' * $lPad)║" "DarkMagenta"
                        }
                        Write-CL "  ╠══════════════════════════════════════════════╣" "DarkMagenta"
                        Write-C "  ║  Total Sell Value: " "DarkMagenta"
                        Write-C "${totalVal}g" "Yellow"
                        $tvPad = 24 - "${totalVal}g".Length
                        if($tvPad -lt 0){$tvPad=0}
                        Write-CL "$(' ' * $tvPad)║" "DarkMagenta"
                    }
                    Write-CL "  ╚══════════════════════════════════════════════╝" "DarkMagenta"
                    Write-Host ""

                    # ── Options ──
                    Write-CL "  ┌─────────────────────────────────────────┐" "DarkGray"
                    Write-C  "  │  " "DarkGray"; Write-C "[U]" "Red"; Write-CL " Unequip Gear (20% refund)          │" "DarkGray"
                    Write-C  "  │  " "DarkGray"; Write-C "[0]" "White"; Write-CL " Back                               │" "DarkGray"
                    Write-CL "  └─────────────────────────────────────────┘" "DarkGray"
                    Write-Host ""
                    Write-C "  > " "Yellow"; $invCh = Read-Host

                    switch($invCh.ToUpper()){
                        "U" {
                            clr
                            Write-CL "  ── Unequip Gear ──" "Red"
                            Write-CL "  You will receive 20% of the item price back." "DarkGray"
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
                                $uIdx = [int]$uPick - 1
                                if($uIdx -ge 0 -and $uIdx -lt $unequipOptions.Count){
                                    $uSlot = $unequipOptions[$uIdx].Slot
                                    if($uSlot -eq "Weapon"){
                                        $refund = [math]::Floor($script:EquippedWeapon.Price * 0.2)
                                        Write-CL "  Unequipped $($script:EquippedWeapon.Name). Refund: ${refund}g" "Yellow"
                                        $script:Gold += $refund
                                        $script:EquippedWeapon = $null
                                    } else {
                                        $piece = $script:EquippedArmor[$uSlot]
                                        $refund = [math]::Floor($piece.Price * 0.2)
                                        Write-CL "  Unequipped $($piece.Name). Refund: ${refund}g" "Yellow"
                                        $script:Gold += $refund
                                        $script:EquippedArmor[$uSlot] = $null
                                    }
                                    Wait-Key
                                }
                            }
                        }
                        "0" { $invLoop = $false }
                        default { $invLoop = $false }
                    }
                }
            }



                        "4" {
                clr
                Write-CL "" "White"
                Write-CL "  ╔════════════════════════════════════════════════════╗" "DarkYellow"
                Write-CL "  ║           T H E   W E A R Y   L A N T E R N       ║" "Yellow"
                Write-CL "  ╚════════════════════════════════════════════════════╝" "DarkYellow"
                Write-Host ""
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

                Write-CL "  ┌────────────────────────────────────────────┐" "DarkGray"
                Write-C  "  │  " "DarkGray"; Write-C "Current HP: $($p.HP)/$($p.MaxHP)" "Green"
                $hp1 = 40 - "Current HP: $($p.HP)/$($p.MaxHP)".Length
                Write-CL "$(' ' * $hp1)│" "DarkGray"
                Write-C  "  │  " "DarkGray"; Write-C "Current MP: $($p.MP)/$($p.MaxMP)" "Cyan"
                $mp1 = 40 - "Current MP: $($p.MP)/$($p.MaxMP)".Length
                Write-CL "$(' ' * $mp1)│" "DarkGray"
                Write-C  "  │  " "DarkGray"; Write-C "Gold: $($script:Gold)g" "Yellow"
                $g1 = 40 - "Gold: $($script:Gold)g".Length
                Write-CL "$(' ' * $g1)│" "DarkGray"
                Write-CL "  └────────────────────────────────────────────┘" "DarkGray"
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
                    Write-CL "  ┌─────────────────────────────────────────────┐" "DarkGray"
                    Write-CL "  │                                             │" "DarkGray"
                    Write-C  "  │  " "DarkGray"; Write-C "[1]" "White"; Write-C " Quick Nap" "Green"
                    Write-CL "          -  15g  (50% HP/MP)    │" "DarkGray"
                    Write-C  "  │  " "DarkGray"; Write-C "[2]" "White"; Write-C " Full Rest" "Cyan"
                    Write-CL "          -  30g  (100% HP/MP)   │" "DarkGray"
                    Write-C  "  │  " "DarkGray"; Write-C "[3]" "White"; Write-C " Royal Suite" "Magenta"
                    Write-CL "        -  60g  (Full + ATK/DEF) │" "DarkGray"
                    Write-C  "  │  " "DarkGray"; Write-C "[0]" "DarkGray"
                    Write-CL " Leave                                     │" "DarkGray"
                    Write-CL "  │                                             │" "DarkGray"
                    Write-CL "  └─────────────────────────────────────────────┘" "DarkGray"
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
                Write-CL "  ║  $($p2.Name) - $($script:PlayerClass) - Level $($script:PlayerLevel)" "Cyan"
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

                Write-C "  ATK: $($p2.ATK)" "White"
                if($wAtk -gt 0){
                    Write-C " + $wAtk wpn" "DarkCyan"
                    if($cb -gt 0){ Write-C " ($cb class)" "Green" }
                }
                Write-CL "  = $atkTotal total" "Yellow"

                Write-C "  DEF: $($p2.DEF)" "White"
                if($aDef -gt 0){ Write-C " + $aDef armor" "DarkCyan" }
                Write-CL "  = $defTotal total" "Yellow"

                Write-CL "  SPD: $($p2.SPD)" "White"

                Write-C "  MAG: $($p2.MAG)" "White"
                if($mBonus -gt 0){ Write-C " + $mBonus staff" "DarkCyan" }
                Write-CL "  = $magTotal total" "Yellow"

                Write-Host ""
                Write-CL "  XP:  $($script:XP) / $($script:XPToNext)" "DarkCyan"
                Write-CL "  Kills: $($script:KillCount)" "DarkGray"
                Write-Host ""

                # ── Equipment ──
                Write-CL "  ── EQUIPMENT ──" "Yellow"
                if($script:EquippedWeapon){
                    $w = $script:EquippedWeapon
                    $perkStr = if($w.Perk){" | Perk: $($w.Perk) ($($w.PerkChance)%)"}else{""}
                    $magStr = if($w.MAGBonus){" | MAG+$($w.MAGBonus)"}else{""}
                    $affStr = if($w.ClassAffinity -eq $script:PlayerClass){"MATCH"}else{$w.ClassAffinity}
                    Write-CL "  Weapon: $($w.Name)  ATK+$($w.ATK)  [$affStr]$perkStr$magStr" "Cyan"
                } else {
                    Write-CL "  Weapon: Bare Hands" "DarkGray"
                }
                Write-Host ""

                $slots = @("Helmet","Chest","Shield","Amulet","Boots")
                foreach($slot in $slots){
                    $piece = $script:EquippedArmor[$slot]
                    $slotLabel = "$($slot):".PadRight(9)
                    if($piece){
                        Write-CL "  $slotLabel $($piece.Name) (DEF+$($piece.DEF))" "Cyan"
                    } else {
                        Write-CL "  $slotLabel (empty)" "DarkGray"
                    }
                }
                Write-Host ""

                # ── Weapon Affinity Tip ──
                Write-CL "  ┌──────────────────────────────────────────────────┐" "DarkGray"
                Write-CL "  │  Your class affinity: $($script:PlayerClass)" "DarkGray"
                Write-CL "  │  Weapons matching your class give bonus ATK.     │" "DarkGray"
                Write-CL "  └──────────────────────────────────────────────────┘" "DarkGray"
                Write-Host ""

                # ── Abilities ──
                Write-CL "  ── ABILITIES ──" "Yellow"
                foreach($ab in $p2.Abilities){
                    $costStr = if($ab.Type -eq "Sacrifice"){"HP:15%"}else{"MP:$($ab.Cost)"}
                    $effStr = if($ab.Effect -and $ab.Effect -ne "None" -and $ab.Effect -ne "SacrificeHP"){" [$($ab.Effect)]"}else{""}
                    Write-CL "    $($ab.Name)  |  $costStr  |  $($ab.Type)  |  Pwr:$($ab.Power)$effStr" "Cyan"
                }
                Wait-Key
            }

            "6" { Show-QuestBoard }
            "7" { Show-GuildHall }

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
                Write-CL "  Write down or copy this code. You can use it" "DarkGray"
                Write-CL "  to continue your game next time you play." "DarkGray"
                Write-Host ""
                Write-CL "  NOTE: Loot was converted to gold. Quests were reset." "DarkYellow"
                Write-CL "  TIP: Use Ctrl+C to copy your code, and Ctrl+V to paste it in later." "DarkCyan"
                Write-Host ""
                Read-Host "  Press Enter to continue"
            }
        }
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
    Write-CL "    A first-person dungeon crawler" "DarkGray"
    Write-CL "    with turn-based RPG combat" "DarkGray"
    Write-Host ""
    Write-CL "    ─────────────────────────────────" "DarkGray"
    Write-CL "    CONTROLS (in dungeon):" "Gray"
    Write-CL "      W = Move Forward    S = Move Back" "Gray"
    Write-CL "      A = Turn Left       D = Turn Right" "Gray"
    Write-CL "    ─────────────────────────────────" "DarkGray"
    Write-CL "    SYMBOLS (on minimap):" "Gray"
    Write-CL "      ! = Enemy   M = Mini-Boss" "Gray"
    Write-CL "      B = Boss    > = Exit   $ = Treasure" "Gray"
    Write-CL "    ─────────────────────────────────" "DarkGray"
    Write-Host ""
    Wait-Key

    # ═══════════════════════════════════════════════════
    #  NEW / LOAD PROMPT  (this is the new part)
    # ═══════════════════════════════════════════════════
    clr
    Write-Host ""
    Write-CL "  ╔══════════════════════════════════════════════════╗" "DarkYellow"
    Write-CL "  ║         DEPTHS OF POWERSHELL                     ║" "Yellow"
    Write-CL "  ╚══════════════════════════════════════════════════╝" "DarkYellow"
    Write-Host ""
    Write-CL "  ┌─────────────────────────────────────────┐" "DarkGray"
    Write-C  "  │  " "DarkGray"; Write-C "[1]" "Green";  Write-CL " New Game                          │" "White"
    Write-C  "  │  " "DarkGray"; Write-C "[2]" "Cyan";   Write-CL " Load Save Code                    │" "White"
    Write-CL "  └─────────────────────────────────────────┘" "DarkGray"
    Write-Host ""
    Write-C "  > " "Yellow"; $startChoice = Read-Host

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
    Show-MainMenu
}

# Launch the game
Start-Game


