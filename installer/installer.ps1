#Requires -Version 5.1
<#
  《歧路旅人 II》MOD 一键安装器  (OT2FCLite Installer)
  ------------------------------------------------------------------
  用法（两种）：
    1) 双击同目录的「一键安装或卸载.bat」→ 弹出图形界面
    2) 命令行：
         powershell -ExecutionPolicy Bypass -File installer.ps1 -Status
         powershell -ExecutionPolicy Bypass -File installer.ps1 -Install
         powershell -ExecutionPolicy Bypass -File installer.ps1 -Uninstall
         powershell -ExecutionPolicy Bypass -File installer.ps1 -Uninstall -RemoveUe4ss
       可选 -GameDir "D:\SteamLibrary\steamapps\common\Octopath_Traveler2"（不填则自动检测）

  设计原则：
    * 只做“加法”：不覆盖你已有的 mods.txt 条目、不覆盖你已有的其它 MOD
    * 修改任何已有文件前先备份为 .bak（只备份一次）
    * 卸载只删本安装器放进去的东西；检测到其它 MOD 时不删 UE4SS 本体
#>
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$RemoveUe4ss,
    [switch]$Console,
    [string]$GameDir = "",
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$Script:Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:Payload   = Join-Path $Script:Root "payload"
$Script:ModSource = Join-Path $Script:Payload "OT2FCLite"
$Script:Ue4ssZip  = Join-Path $Script:Payload "UE4SS_v3.0.1.zip"
$Script:BackupDir = Join-Path $Script:Root "backup"
$Script:ModName   = "OT2FCLite"
$Script:LogBox    = $null
$Script:LogPath   = Join-Path $Script:Root "installer-log.txt"

function Write-Log {
    param([string]$Text)
    try {
        Add-Content -LiteralPath $Script:LogPath -Encoding UTF8 -Value ("[" + (Get-Date -Format "HH:mm:ss") + "] " + $Text)
    } catch { }
}

Write-Log "installer.ps1 started"
Write-Log ("root=" + $Script:Root)

# ---------------------------------------------------------------- helpers
function Write-Msg {
    param([string]$Text, [string]$Kind = "info")
    Write-Log ("[" + $Kind + "] " + $Text)
    if ($Script:LogBox -ne $null) {
        $prefix = switch ($Kind) { "ok" { "[OK] " } "warn" { "[!] " } "err" { "[X] " } default { "    " } }
        $Script:LogBox.AppendText($prefix + $Text + "`r`n")
        $Script:LogBox.SelectionStart = $Script:LogBox.Text.Length
        $Script:LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    } else {
        switch ($Kind) {
            "ok"   { Write-Host "[OK] $Text"   -ForegroundColor Green }
            "warn" { Write-Host "[!]  $Text"   -ForegroundColor Yellow }
            "err"  { Write-Host "[X]  $Text"   -ForegroundColor Red }
            default { Write-Host "     $Text" }
        }
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Are we actually able to write into the game folder? (more reliable than checking admin,
# because a Steam library outside Program Files does not need elevation at all)
function Test-CanWrite {
    param([string]$Dir)
    try {
        $probe = Join-Path $Dir (".ot2probe_" + [guid]::NewGuid().ToString("N") + ".tmp")
        Set-Content -LiteralPath $probe -Value "x" -Encoding ASCII
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}

function Get-SteamLibraries {
    $roots = New-Object System.Collections.Generic.List[string]
    $steam = $null
    foreach ($k in @("HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam")) {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            foreach ($n in @("SteamPath", "InstallPath")) {
                if ($null -ne $p.$n -and $p.$n -ne "") { $steam = $p.$n; break }
            }
        } catch { }
        if ($steam) { break }
    }
    if ($steam) {
        $steam = $steam -replace "/", "\"
        if (-not $roots.Contains($steam)) { $roots.Add($steam) }
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $vdf) {
            $txt = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
            foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
                $lib = $m.Groups[1].Value -replace "\\\\", "\"
                if (-not $roots.Contains($lib)) { $roots.Add($lib) }
            }
        }
    }
    foreach ($g in @("C:\Program Files (x86)\Steam", "C:\Program Files\Steam", "D:\Steam", "D:\SteamLibrary", "E:\SteamLibrary", "E:\Steam")) {
        if (Test-Path -LiteralPath $g) { if (-not $roots.Contains($g)) { $roots.Add($g) } }
    }
    return $roots
}

# returns the game root (the folder that contains Octopath_Traveler2\Binaries\Win64)
function Resolve-GameRoot {
    param([string]$Hint = "")
    $cands = New-Object System.Collections.Generic.List[string]
    if ($Hint -ne "") {
        $h = $Hint.TrimEnd("\")
        $cands.Add($h)
        if ($h -match "\\Binaries\\Win64$") { $cands.Add(($h -replace "\\Octopath_Traveler2\\Binaries\\Win64$", "")) }
        if ($h -match "\\Octopath_Traveler2$") { $cands.Add((Split-Path -Parent $h)) }
    }
    foreach ($lib in (Get-SteamLibraries)) {
        $cands.Add((Join-Path $lib "steamapps\common\Octopath_Traveler2"))
    }
    foreach ($c in $cands) {
        $win64 = Join-Path $c "Octopath_Traveler2\Binaries\Win64"
        if (Test-Path -LiteralPath (Join-Path $win64 "Octopath_Traveler2-Win64-Shipping.exe")) { return $c }
    }
    return $null
}

function Get-Win64 {
    param([string]$GameRoot)
    return (Join-Path $GameRoot "Octopath_Traveler2\Binaries\Win64")
}

function Backup-FileOnce {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $bak = "$Path.bak"
        if (-not (Test-Path -LiteralPath $bak)) {
            Copy-Item -LiteralPath $Path -Destination $bak -Force
            Write-Msg ("已备份原文件: " + (Split-Path -Leaf $Path) + ".bak") "info"
        }
    }
}

# set KEY = VALUE inside [SECTION] of an ini-style file (creates them if needed)
function Set-IniValue {
    param([string]$Path, [string]$Section, [string]$Key, [string]$Value)
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Path) {
        foreach ($l in (Get-Content -LiteralPath $Path)) { $lines.Add($l) }
    }
    $secIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ieq "[$Section]") { $secIdx = $i; break }
    }
    $keyIdx = -1
    if ($secIdx -ge 0) {
        for ($i = $secIdx + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -match "^\[") { break }
            if ($lines[$i] -match "^\s*" + [regex]::Escape($Key) + "\s*=") { $keyIdx = $i; break }
        }
    } else {
        $lines.Add("[$Section]"); $secIdx = $lines.Count - 1
    }
    if ($keyIdx -ge 0) {
        $lines[$keyIdx] = "$Key = $Value"
    } else {
        $lines.Insert($secIdx + 1, "$Key = $Value")
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
    return $true
}

function Get-IniValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($l in (Get-Content -LiteralPath $Path)) {
        if ($l -match "^\s*" + [regex]::Escape($Key) + "\s*=\s*(.+?)\s*$") { return $Matches[1] }
    }
    return $null
}

# ---------------------------------------------------------------- state
function Get-InstallState {
    param([string]$GameRoot)
    $win64 = Get-Win64 $GameRoot
    $modDir = Join-Path $win64 ("Mods\" + $Script:ModName)
    $ini = Join-Path $win64 "UE4SS-settings.ini"
    $modsTxt = Join-Path $win64 "Mods\mods.txt"
    $ue4ss = (Test-Path -LiteralPath (Join-Path $win64 "UE4SS.dll")) -and (Test-Path -LiteralPath (Join-Path $win64 "dwmapi.dll"))
    $registered = $false
    if (Test-Path -LiteralPath $modsTxt) {
        $registered = ((Get-Content -LiteralPath $modsTxt) | Where-Object { $_ -match "^\s*$($Script:ModName)\s*:\s*1\s*$" }).Count -gt 0
    }
    [pscustomobject]@{
        GameRoot   = $GameRoot
        Win64      = $win64
        Ue4ssCore  = $ue4ss
        ModExists  = (Test-Path -LiteralPath (Join-Path $modDir "Scripts\main.lua"))
        Registered = $registered
        IniExists  = (Test-Path -LiteralPath $ini)
        CacheFlag  = (Get-IniValue $ini "bUseUObjectArrayCache")
        GuiEnabled = (Get-IniValue $ini "GuiConsoleEnabled")
        GuiVisible = (Get-IniValue $ini "GuiConsoleVisible")
        Graphics   = (Get-IniValue $ini "GraphicsAPI")
    }
}

function Show-Status {
    param([string]$GameRoot)
    $st = Get-InstallState $GameRoot
    Write-Msg "游戏目录：$($st.GameRoot)"
    Write-Msg "运行目录：$($st.Win64)"
    Write-Msg ("UE4SS 加载器： " + $(if ($st.Ue4ssCore) { "已安装" } else { "未安装" })) $(if ($st.Ue4ssCore) { "ok" } else { "warn" })
    Write-Msg ("MOD 本体：     " + $(if ($st.ModExists) { "已安装" } else { "未安装" })) $(if ($st.ModExists) { "ok" } else { "warn" })
    Write-Msg ("mods.txt 注册： " + $(if ($st.Registered) { "已注册" } else { "未注册" })) $(if ($st.Registered) { "ok" } else { "warn" })
    Write-Msg ("配置 bUseUObjectArrayCache = " + $st.CacheFlag + "（必须是 false）") $(if ($st.CacheFlag -eq "false") { "ok" } else { "warn" })
    Write-Msg ("调试窗口 GuiConsoleEnabled = " + $st.GuiEnabled + " / Visible = " + $st.GuiVisible + "（0 = 隐藏）") "info"
    Write-Msg ("渲染 GraphicsAPI = " + $st.Graphics + "（建议 dx11）") "info"
    if ($st.Ue4ssCore -and $st.ModExists -and $st.Registered -and $st.CacheFlag -eq "false") {
        Write-Msg "结论：安装完整，可以进游戏按 F5 使用。" "ok"
        return $true
    }
    Write-Msg "结论：安装不完整或未安装。点「安装 / 更新」即可。" "warn"
    return $false
}

# ---------------------------------------------------------------- install
function Invoke-Install {
    param([string]$GameRoot)
    $st = Get-InstallState $GameRoot

    if (-not (Test-CanWrite $st.Win64)) {
        throw "没有写入游戏目录的权限。请用同目录的「一键安装或卸载.bat」启动（它会自动申请管理员权限），或右键 installer.ps1 选择「以管理员身份运行」。"
    }
    if (-not (Test-Path -LiteralPath $Script:ModSource)) {
        throw "找不到 payload\OT2FCLite，请确认安装器文件完整（不要把 installer.ps1 单独拷出来运行）。"
    }

    Write-Msg "==== 开始安装 ===="

    # 1) 备份存档
    try {
        $myGames = Join-Path $env:USERPROFILE "Documents\My Games\Octopath_Traveler2"
        if (Test-Path -LiteralPath $myGames) {
            if (-not (Test-Path -LiteralPath $Script:BackupDir)) { New-Item -ItemType Directory -Path $Script:BackupDir -Force | Out-Null }
            $dst = Join-Path $Script:BackupDir ("MyGames_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
            Copy-Item -LiteralPath $myGames -Destination $dst -Recurse -Force
            Write-Msg "存档已备份到：$dst" "ok"
        } else {
            Write-Msg "没有找到存档目录（如果你还没玩过可以忽略）。" "warn"
        }
    } catch {
        Write-Msg "备份存档失败（不影响安装）：$($_.Exception.Message)" "warn"
    }

    $win64 = $st.Win64
    if (-not (Test-Path -LiteralPath $win64)) { throw "运行目录不存在：$win64" }

    # 2) UE4SS 本体
    if ($st.Ue4ssCore) {
        Write-Msg "UE4SS 已存在，跳过（不会覆盖你已有的 MOD 与设置）。" "ok"
    } else {
        if (-not (Test-Path -LiteralPath $Script:Ue4ssZip)) {
            throw "找不到 payload\UE4SS_v3.0.1.zip，请确认安装器文件完整。"
        }
        Write-Msg "解压 UE4SS 到运行目录……"
        $tmp = Join-Path $env:TEMP ("ot2ue4ss_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        Expand-Archive -LiteralPath $Script:Ue4ssZip -DestinationPath $tmp -Force
        foreach ($item in (Get-ChildItem -LiteralPath $tmp)) {
            Copy-Item -LiteralPath $item.FullName -Destination $win64 -Recurse -Force
        }
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Msg "UE4SS 已安装。" "ok"
        if (Test-Path -LiteralPath (Join-Path $win64 "Mods\mods.txt.bak")) {
            Write-Msg "注意：UE4SS 自带了一份新的 mods.txt，你原来的已备份为 mods.txt.bak。" "warn"
            Write-Msg "如果你之前注册过其它 MOD，需要把它们的行手动加回 mods.txt。" "warn"
        }
    }

    # 3) 配置（关键）
    $ini = Join-Path $win64 "UE4SS-settings.ini"
    Backup-FileOnce $ini
    if (-not (Test-Path -LiteralPath $ini)) { New-Item -ItemType File -Path $ini -Force | Out-Null }
    Set-IniValue $ini "General" "bUseUObjectArrayCache" "false" | Out-Null
    Set-IniValue $ini "Debug"   "GraphicsAPI"           "dx11"  | Out-Null
    Set-IniValue $ini "Debug"   "GuiConsoleEnabled"     "0"     | Out-Null
    Set-IniValue $ini "Debug"   "GuiConsoleVisible"     "0"     | Out-Null
    Write-Msg "已写入关键配置：bUseUObjectArrayCache=false / GraphicsAPI=dx11 / 调试窗口关闭" "ok"

    # 4) MOD 本体
    $modDir = Join-Path $win64 ("Mods\" + $Script:ModName)
    if (Test-Path -LiteralPath $modDir) { Remove-Item -LiteralPath $modDir -Recurse -Force }
    New-Item -ItemType Directory -Path $modDir -Force | Out-Null
    Copy-Item -Path (Join-Path $Script:ModSource "*") -Destination $modDir -Recurse -Force
    Write-Msg "MOD 已复制到：$modDir" "ok"

    # 5) mods.txt 注册
    $modsTxt = Join-Path $win64 "Mods\mods.txt"
    Backup-FileOnce $modsTxt
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $modsTxt) {
        foreach ($l in (Get-Content -LiteralPath $modsTxt)) { $lines.Add($l) }
    }
    # 移除旧的同名行，避免重复
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match "^\s*$($Script:ModName)\s*:") { $lines.RemoveAt($i) }
    }
    $entry = "$($Script:ModName) : 1"
    $keyIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*Keybinds\s*:") { $keyIdx = $i; break }
    }
    if ($keyIdx -ge 0) { $lines.Insert($keyIdx, $entry) } else { $lines.Add($entry) }
    Set-Content -LiteralPath $modsTxt -Value $lines -Encoding ASCII
    Write-Msg "已在 mods.txt 注册 $entry" "ok"

    # 6) 验证
    $chk = Get-InstallState $GameRoot
    $ok = $chk.Ue4ssCore -and $chk.ModExists -and $chk.Registered -and ($chk.CacheFlag -eq "false")
    if ($ok) {
        Write-Msg "==== 安装完成 ====" "ok"
        Write-Msg "进游戏后：按 F5 换队 → 按手柄 Y 打开换人界面 → 关闭 → 天赋技能可用。" "info"
        Write-Msg "配置文件在：$modDir（swapkey / exphook / expratio / sharejp / jpratio）" "info"
        return $true
    }
    Write-Msg "==== 安装后自检未通过，请把上面的提示发给我 ====" "err"
    return $false
}

# ---------------------------------------------------------------- uninstall
function Invoke-Uninstall {
    param([string]$GameRoot, [bool]$AlsoUe4ss)
    if (-not (Test-CanWrite (Get-Win64 $GameRoot))) {
        throw "没有写入游戏目录的权限。请用同目录的「一键安装或卸载.bat」启动（它会自动申请管理员权限）。"
    }
    Write-Msg "==== 开始卸载 ===="
    $win64 = Get-Win64 $GameRoot

    # 1) 移除 mods.txt 注册
    $modsTxt = Join-Path $win64 "Mods\mods.txt"
    if (Test-Path -LiteralPath $modsTxt) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($l in (Get-Content -LiteralPath $modsTxt)) { $lines.Add($l) }
        $removed = $false
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match "^\s*$($Script:ModName)\s*:") { $lines.RemoveAt($i); $removed = $true }
        }
        if ($removed) {
            Set-Content -LiteralPath $modsTxt -Value $lines -Encoding ASCII
            Write-Msg "已从 mods.txt 移除注册项。" "ok"
        }
    }

    # 2) 移除 MOD 本体
    $modDir = Join-Path $win64 ("Mods\" + $Script:ModName)
    if (Test-Path -LiteralPath $modDir) {
        Remove-Item -LiteralPath $modDir -Recurse -Force
        Write-Msg "已删除 MOD 本体。" "ok"
    } else {
        Write-Msg "MOD 本体本来就不在。" "info"
    }

    # 3) 是否移除 UE4SS 本体
    if ($AlsoUe4ss) {
        $builtin = @("ActorDumperMod", "BPML_GenericFunctions", "BPModLoaderMod", "CheatManagerEnablerMod",
                     "ConsoleCommandsMod", "ConsoleEnablerMod", "jsbLuaProfilerMod", "Keybinds",
                     "LineTraceMod", "shared", "SplitScreenMod")
        $others = @()
        $modsRoot = Join-Path $win64 "Mods"
        if (Test-Path -LiteralPath $modsRoot) {
            foreach ($d in (Get-ChildItem -LiteralPath $modsRoot -Directory)) {
                if ($builtin -notcontains $d.Name) { $others += $d.Name }
            }
        }
        if ($others.Count -gt 0) {
            Write-Msg ("检测到还有其它 MOD：" + ($others -join ", ") + "。为免影响它们，本次不删除 UE4SS 本体。") "warn"
            Write-Msg "如果你的确要彻底清理，请手动删除 Win64 下的 dwmapi.dll、UE4SS.dll、UE4SS-settings.ini。" "info"
        } else {
            foreach ($f in @("dwmapi.dll", "UE4SS.dll", "UE4SS-settings.ini", "UE4SS.log",
                             "UE4SS_ObjectDump.txt", "Changelog.md", "imgui.ini")) {
                $p = Join-Path $win64 $f
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Msg "已删除 $f" "ok" }
            }
            Get-ChildItem -LiteralPath $win64 -Filter "crash_*.dmp" -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force
            }
            $dumpDir = Join-Path $win64 "CXXHeaderDump"
            if (Test-Path -LiteralPath $dumpDir) { Remove-Item -LiteralPath $dumpDir -Recurse -Force }
            # UE4SS 附带一份 README.md；只在内容确实是 UE4SS 说明时才删，避免误删别人的文件
            $rd = Join-Path $win64 "README.md"
            if (Test-Path -LiteralPath $rd) {
                try {
                    $head = (Get-Content -LiteralPath $rd -TotalCount 20 -ErrorAction Stop) -join " "
                    if ($head -match "UE4SS") { Remove-Item -LiteralPath $rd -Force; Write-Msg "已删除 UE4SS 的 README.md" "ok" }
                } catch { }
            }
            Write-Msg "UE4SS 本体已移除，游戏回到原版。" "ok"
            Write-Msg "（保留 Mods 文件夹与其中的内置模块，它们不会被加载，也不影响游戏。）" "info"
        }
    } else {
        Write-Msg "保留了 UE4SS 本体（只移除了本 MOD）。" "info"
    }

    $st = Get-InstallState $GameRoot
    if (-not $st.ModExists -and -not $st.Registered) { Write-Msg "==== 卸载完成 ====" "ok" ; return $true }
    Write-Msg "==== 卸载后仍有残留，请检查上面的提示 ====" "warn"
    return $false
}

# ---------------------------------------------------------------- console entry
function Invoke-Cli {
    $root = Resolve-GameRoot $GameDir
    if ($null -eq $root) {
        Write-Msg "没有自动找到游戏目录。请用 -GameDir 指定，例如：" "err"
        Write-Msg '  -GameDir "D:\SteamLibrary\steamapps\common\Octopath_Traveler2"' "info"
        exit 2
    }
    if ($Status)   { [void](Show-Status $root); exit 0 }
    if ($Install)  { if (Invoke-Install $root) { exit 0 } else { exit 1 } }
    if ($Uninstall) { if (Invoke-Uninstall $root $RemoveUe4ss.IsPresent) { exit 0 } else { exit 1 } }
    Show-Status $root | Out-Null
}

# ---------------------------------------------------------------- gui entry
function Invoke-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "《歧路旅人 II》MOD 一键安装器  v1.0"
    $form.Size = New-Object System.Drawing.Size(760, 560)
    $form.StartPosition = "CenterScreen"
    $form.MinimumSize = New-Object System.Drawing.Size(700, 500)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "游戏目录："
    $lbl.Location = New-Object System.Drawing.Point(14, 18)
    $lbl.AutoSize = $true
    $form.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(90, 15)
    $txt.Size = New-Object System.Drawing.Size(520, 26)
    $txt.Anchor = "Top,Left,Right"
    $auto = Resolve-GameRoot ""
    if ($null -ne $auto) { $txt.Text = $auto }
    $form.Controls.Add($txt)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "浏览…"
    $btnBrowse.Location = New-Object System.Drawing.Point(620, 13)
    $btnBrowse.Size = New-Object System.Drawing.Size(110, 30)
    $btnBrowse.Anchor = "Top,Right"
    $form.Controls.Add($btnBrowse)

    $btnStatus = New-Object System.Windows.Forms.Button
    $btnStatus.Text = "检查状态"
    $btnStatus.Location = New-Object System.Drawing.Point(14, 58)
    $btnStatus.Size = New-Object System.Drawing.Size(150, 40)
    $form.Controls.Add($btnStatus)

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = "安装 / 更新"
    $btnInstall.Location = New-Object System.Drawing.Point(176, 58)
    $btnInstall.Size = New-Object System.Drawing.Size(150, 40)
    $btnInstall.BackColor = [System.Drawing.Color]::FromArgb(200, 235, 200)
    $form.Controls.Add($btnInstall)

    $btnUninstall = New-Object System.Windows.Forms.Button
    $btnUninstall.Text = "卸载本 MOD"
    $btnUninstall.Location = New-Object System.Drawing.Point(338, 58)
    $btnUninstall.Size = New-Object System.Drawing.Size(150, 40)
    $form.Controls.Add($btnUninstall)

    $btnFull = New-Object System.Windows.Forms.Button
    $btnFull.Text = "彻底卸载(含UE4SS)"
    $btnFull.Location = New-Object System.Drawing.Point(500, 58)
    $btnFull.Size = New-Object System.Drawing.Size(150, 40)
    $form.Controls.Add($btnFull)

    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true
    $log.ScrollBars = "Vertical"
    $log.Location = New-Object System.Drawing.Point(14, 110)
    $log.Size = New-Object System.Drawing.Size(716, 400)
    $log.Anchor = "Top,Bottom,Left,Right"
    $log.Font = New-Object System.Drawing.Font("Consolas", 9)
    $log.ReadOnly = $true
    $log.BackColor = [System.Drawing.Color]::White
    $form.Controls.Add($log)
    $Script:LogBox = $log

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "提示：安装/卸载需要管理员权限。若提示权限不足，请关闭本窗口，改用同目录的「一键安装或卸载.bat」启动。"
    $hint.Location = New-Object System.Drawing.Point(14, 516)
    $hint.Size = New-Object System.Drawing.Size(716, 20)
    $hint.Anchor = "Bottom,Left,Right"
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($hint)

    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "请选择 Octopath_Traveler2 文件夹（里面应有 Octopath_Traveler2\Binaries\Win64）"
        if ($dlg.ShowDialog() -eq "OK") { $txt.Text = $dlg.SelectedPath }
    })

    $btnStatus.Add_Click({
        $root = Resolve-GameRoot $txt.Text
        $Script:LogBox.Clear()
        if ($null -eq $root) { Write-Msg "没找到游戏：请在「游戏目录」里选择正确路径。"; return }
        [void](Show-Status $root)
    })

    $btnInstall.Add_Click({
        $root = Resolve-GameRoot $txt.Text
        $Script:LogBox.Clear()
        if ($null -eq $root) { Write-Msg "没找到游戏：请点「浏览…」选择正确路径。" "err"; return }
        try { [void](Invoke-Install $root) } catch { Write-Msg $_.Exception.Message "err" }
    })

    $btnUninstall.Add_Click({
        $root = Resolve-GameRoot $txt.Text
        $Script:LogBox.Clear()
        if ($null -eq $root) { Write-Msg "没找到游戏：请点「浏览…」选择正确路径。" "err"; return }
        $r = [System.Windows.Forms.MessageBox]::Show("只移除本 MOD，保留 UE4SS 加载器？`r`n（这样其它 MOD 不受影响）", "确认卸载", "YesNo", "Question")
        if ($r -ne "Yes") { return }
        try { [void](Invoke-Uninstall $root $false) } catch { Write-Msg $_.Exception.Message "err" }
    })

    $btnFull.Add_Click({
        $root = Resolve-GameRoot $txt.Text
        $Script:LogBox.Clear()
        if ($null -eq $root) { Write-Msg "没找到游戏：请点「浏览…」选择正确路径。" "err"; return }
        $r = [System.Windows.Forms.MessageBox]::Show("将移除本 MOD 并删除 UE4SS 加载器（游戏回到完全原版）。`r`n如果还有其它 MOD，会跳过 UE4SS 的删除。继续？", "彻底卸载", "YesNo", "Warning")
        if ($r -ne "Yes") { return }
        try { [void](Invoke-Uninstall $root $true) } catch { Write-Msg $_.Exception.Message "err" }
    })

    $form.Add_Shown({
        $root = Resolve-GameRoot $txt.Text
        if ($null -eq $root) {
            Write-Msg "欢迎使用。请先点「浏览…」选择游戏目录：" "warn"
            Write-Msg "  …\steamapps\common\Octopath_Traveler2" "info"
        } else {
            Write-Msg "已自动找到游戏目录。" "ok"
            [void](Show-Status $root)
        }
    })

    [void]$form.ShowDialog()
}

# ---------------------------------------------------------------- console fallback
function Invoke-ConsoleMenu {
    $root = Resolve-GameRoot $GameDir
    while ($true) {
        Write-Host ""
        Write-Host "==================== 《歧路旅人 II》MOD 安装器 ===================="
        if ($null -eq $root) { Write-Host "游戏目录：[未找到] 请在下面输入路径" -ForegroundColor Yellow }
        else { Write-Host ("游戏目录：" + $root) -ForegroundColor Green }
        Write-Host "  1) 检查状态"
        Write-Host "  2) 安装 / 更新"
        Write-Host "  3) 卸载本 MOD（保留 UE4SS）"
        Write-Host "  4) 彻底卸载（含 UE4SS）"
        Write-Host "  5) 手动输入游戏目录"
        Write-Host "  0) 退出"
        $c = Read-Host "请选择"
        if ($c -eq "0") { break }
        if ($null -eq $root -and $c -ne "5") { Write-Host "请先选 5 指定游戏目录。" -ForegroundColor Yellow; continue }
        try {
            switch ($c) {
                "1" { [void](Show-Status $root) }
                "2" { [void](Invoke-Install $root) }
                "3" { [void](Invoke-Uninstall $root $false) }
                "4" { [void](Invoke-Uninstall $root $true) }
                "5" {
                    $p = Read-Host "请输入 Octopath_Traveler2 文件夹完整路径"
                    $tmp = Resolve-GameRoot $p
                    if ($null -eq $tmp) { Write-Host "这个路径下没找到游戏。" -ForegroundColor Red } else { $root = $tmp }
                }
                default { }
            }
        } catch {
            Write-Host ("出错：" + $_.Exception.Message) -ForegroundColor Red
        }
    }
}

function Start-GuiWithFallback {
    try {
        Write-Log "loading WinForms"
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        Write-Log "WinForms loaded, showing window"
        Invoke-Gui
        Write-Log "window closed normally"
    } catch {
        Write-Log ("GUI FAILED: " + $_.Exception.Message)
        try {
            [System.Windows.Forms.MessageBox]::Show("图形界面启动失败，已改为命令行模式。`r`n`r`n原因：" + $_.Exception.Message, "安装器", "OK", "Warning") | Out-Null
        } catch { Write-Host ("图形界面启动失败：" + $_.Exception.Message) -ForegroundColor Red }
        Invoke-ConsoleMenu
    }
}

# ---------------------------------------------------------------- main
if ($Install -or $Uninstall -or $Status) { Invoke-Cli }
elseif ($Console) { Invoke-ConsoleMenu }
else { Start-GuiWithFallback }
