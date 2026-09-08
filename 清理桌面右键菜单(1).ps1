<#
============================================================
 右键菜单清理工具（通用版）
============================================================
 怎么用：
   直接运行本脚本 → 按提示输入你在右键菜单里看到的文字
   （例如：WPS、Code、Git、卸载、360、新建、共享、终端 …）
   → 脚本自动查找 → 列出命中项和它的来源软件
   → 逐项问你「是否删除」→ 你确认后才动手，删前自动备份。

 找不到时会明确告诉你"没有这一项"，不会误删别的东西。
 输入空行（直接回车）即可退出。

 ------------------------------------------------------------
 输入规则：
   · 不区分大小写，做「包含」匹配：输入 Code 能命中「通过 Code 打开」。
   · 支持通配符 * 和 ? ：例如输入 *卸载* 、Git? 。
   · 也会拿「来源软件 / 组件名 / 命令路径」一起匹配，
     所以输入 WPS 能命中菜单上不显示 WPS 字样、但由 WPS 注入的项。
   · 输入 [ 或 ] 这类字符可能被当成通配符，请改用 * 。

 ------------------------------------------------------------
 扫描范围（可在下方配置区调整）：
   默认扫「桌面空白处右键」用到的两套配置：
     · DesktopBackground   —— 桌面壁纸背景
     · Directory\Background —— 桌面空白处 / 文件夹窗口空白处
   注意：桌面空白处和文件夹窗口空白处共用 Directory\Background，
        所以清掉后这两处的菜单都会变化，这是系统机制，不是脚本问题。
   想连「在文件上右键」「在文件夹图标上右键」一起清理，
   把 $ScanScopes 加上 'File'、'Directory'、'Drive' 即可。

 ------------------------------------------------------------
 权限说明：
   · 用户级项（HKCU）普通权限即可删除。
   · 机器级项（HKLM，全机生效）：
       - 以管理员身份运行 PowerShell → 直接删除（先备份）；
       - 权限不足 → 脚本自动改用「按用户屏蔽」，只在你账户下隐藏，
         不改 HKLM、不影响其他账户，还原也干净。
       - 若是机器级的普通命令项（无法屏蔽），脚本会提示需要管理员权限。
   · 想一次性用管理员跑：右键开始菜单 →「Windows PowerShell(管理员)」，
     然后执行：  powershell -ExecutionPolicy Bypass -File "本脚本完整路径"

 ------------------------------------------------------------
 备份与还原：
   · 每次删除前，把该键导出成 .reg 存到同目录「右键菜单备份」文件夹。
   · 还原：双击对应 .reg 文件 → 确认导入 → 重启资源管理器即可。
   · 走「屏蔽」路线的项，记录在备份文件夹的「已屏蔽的组件.txt」，
     还原方法脚本会在结尾打印出来。

 ------------------------------------------------------------
 已知副作用：
   · 部分软件（如 WPS、输入法、网盘）升级后可能把菜单项重新写回来，
     届时重跑本脚本再删一次即可。
============================================================
#>

# ==================== 配置区 ====================
# 扫描范围，按需增删。可选值：
#   'DesktopBackground'   桌面壁纸背景
#   'DirectoryBackground' 桌面空白处 / 文件夹空白处（最常需要）
#   'Directory'           在文件夹图标上右键
#   'File'                在文件上右键
#   'Drive'               在磁盘盘符上右键
$ScanScopes = @('DesktopBackground', 'DirectoryBackground')

$BackupDir       = $null   # 留 $null = 脚本同目录下的「右键菜单备份」；也可写成固定路径，如 'D:\备份'
$RestartExplorer = $true   # 有实际改动时，是否重启资源管理器让菜单立刻刷新（会关闭已打开的文件夹窗口）
$ShowAllFirst    = $true   # 开始时是否先列出扫描到的全部项，方便你照着菜单文字输入关键词
# ================================================

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------- 路径与备份目录 ----------
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
if (-not $BackupDir) { $BackupDir = Join-Path $ScriptDir '右键菜单备份' }
$BlockMark = Join-Path $BackupDir '已屏蔽的组件.txt'

# ---------- 权限 ----------
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 按用户屏蔽 shell 扩展的标准位置：建一个以 CLSID 命名的空值，资源管理器就不再加载它
$BlockedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'

# ---------- 载入 Win32 API，用于把 @xxx.dll,-123 这种资源引用还原成真实中文 ----------
$ShlwapiReady = $false
try {
    Add-Type -Namespace 'Win32Interop' -Name 'Shlwapi' -UsingNamespace 'System.Text' -ErrorAction Stop -MemberDefinition @"
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
public static extern uint SHLoadIndirectString(string pszSource, StringBuilder pszOutBuf, uint cchOutBuf, IntPtr ppvReserved);
"@
    $ShlwapiReady = $true
} catch {
    $ShlwapiReady = $false   # 载入失败也不影响主流程，只是显示原始引用串
}

function Resolve-IndirectString {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    if ($Text -notmatch '^@') { return $Text }
    if (-not $ShlwapiReady) { return $Text }
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $hr = [Win32Interop.Shlwapi]::SHLoadIndirectString($Text, $sb, 1024, [IntPtr]::Zero)
        if ($hr -eq 0 -and $sb.Length -gt 0) { return $sb.ToString() }
    } catch { }
    return $Text
}

# ---------- 扫描范围对应的注册表根 ----------
$ScopeRoots = @{
    'DesktopBackground'   = @('HKLM:\SOFTWARE\Classes\DesktopBackground',
                              'HKCU:\Software\Classes\DesktopBackground')
    'DirectoryBackground' = @('HKLM:\SOFTWARE\Classes\Directory\Background',
                              'HKCU:\Software\Classes\Directory\Background')
    'Directory'           = @('HKLM:\SOFTWARE\Classes\Directory',
                              'HKCU:\Software\Classes\Directory')
    'Drive'               = @('HKLM:\SOFTWARE\Classes\Drive',
                              'HKCU:\Software\Classes\Drive')
    # 文件右键的类名就是星号 *，用 Registry:: 前缀 + LiteralPath 访问，避免被当成通配符
    'File'                = @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\*',
                              'Registry::HKEY_CURRENT_USER\Software\Classes\*')
}

# 判断注册表路径是否属于机器级（HKLM，全机生效）。
# 注意：Get-ChildItem 返回的 PSPath 实际形如
#   Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\...
# 而不是 'HKLM:\...'，所以不能用 StartsWith('HKLM') 判断，
# 否则机器级项会被误判成用户级，从而跳过「按用户屏蔽」的安全兜底。
function Test-IsMachineKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '(?i)HKEY_LOCAL_MACHINE') { return $true }
    if ($Path.StartsWith('HKLM:')) { return $true }
    return $false
}

# 读取注册表值（含 (default) 和具名值），失败返回空串
function Get-RegValue {
    param([string]$Path, [string]$Name = '(default)')
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $v = (Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue).$Name
        if ($null -eq $v) { return '' }
        return [string]$v
    } catch { return '' }
}

# 查 CLSID 的组件名和 DLL 路径（同时看 64 位和 32 位注册表）
function Get-ClsidInfo {
    param([string]$Clsid)
    $info = [pscustomobject]@{ Name = ''; Dll = '' }
    if ([string]::IsNullOrWhiteSpace($Clsid)) { return $info }
    $roots = @("Registry::HKEY_CLASSES_ROOT\CLSID\$Clsid",
               "Registry::HKEY_CLASSES_ROOT\Wow6432Node\CLSID\$Clsid")
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath $r) {
            if (-not $info.Name) { $info.Name = Get-RegValue -Path $r }
            $dll = Get-RegValue -Path (Join-Path $r 'InprocServer32')
            if (-not $info.Dll -and $dll) {
                $info.Dll = [System.Environment]::ExpandEnvironmentVariables($dll)
            }
        }
    }
    return $info
}

# ---------- 收集所有右键菜单项 ----------
function Get-ContextMenuItems {
    $list = New-Object System.Collections.ArrayList

    foreach ($scope in $ScanScopes) {
        if (-not $ScopeRoots.ContainsKey($scope)) { continue }
        foreach ($root in $ScopeRoots[$scope]) {
            if (-not (Test-Path -LiteralPath $root)) { continue }

            # A. Shell 下的普通命令项（如 git_shell、VSCode）
            $shellPath = Join-Path $root 'Shell'
            if (Test-Path -LiteralPath $shellPath) {
                foreach ($k in @(Get-ChildItem -LiteralPath $shellPath -ErrorAction SilentlyContinue)) {
                    $raw   = Get-RegValue -Path $k.PSPath
                    $mui   = Get-RegValue -Path $k.PSPath -Name 'MUIVerb'
                    $cmd   = Get-RegValue -Path (Join-Path $k.PSPath 'command')
                    $disp  = Resolve-IndirectString $(if ($mui) { $mui } else { $raw })
                    [void]$list.Add([pscustomobject]@{
                        Scope     = $scope
                        Kind      = '普通命令'
                        KeyName   = $k.PSChildName
                        Display   = $disp
                        RawText   = $raw
                        Command   = $cmd
                        Clsid     = ''
                        Component = ''
                        Dll       = ''
                        Path      = $k.PSPath
                        IsMachine = (Test-IsMachineKey -Path $k.PSPath)
                    })
                }
            }

            # B. shellex\ContextMenuHandlers 下的 shell 扩展（值是 CLSID）
            $ctxPath = Join-Path $root 'shellex\ContextMenuHandlers'
            if (Test-Path -LiteralPath $ctxPath) {
                foreach ($k in @(Get-ChildItem -LiteralPath $ctxPath -ErrorAction SilentlyContinue)) {
                    $clsid = Get-RegValue -Path $k.PSPath
                    $ci    = Get-ClsidInfo -Clsid $clsid
                    $disp  = if ($ci.Name) { $ci.Name } else { $clsid }
                    [void]$list.Add([pscustomobject]@{
                        Scope     = $scope
                        Kind      = 'Shell扩展'
                        KeyName   = $k.PSChildName.Trim()
                        Display   = $disp
                        RawText   = $clsid
                        Command   = ''
                        Clsid     = $clsid
                        Component = $ci.Name
                        Dll       = $ci.Dll
                        Path      = $k.PSPath
                        IsMachine = (Test-IsMachineKey -Path $k.PSPath)
                    })
                }
            }
        }
    }
    return $list
}

# ---------- 常见系统内置项的「菜单真实文字」别名 ----------
# 这些项在注册表里存的是英文组件名（如 New Menu Handler），
# 而右键菜单上显示的是中文（如「新建」），光靠组件名搜不到，
# 所以按注册表键名补一份中文别名，让你输入菜单上看到的字就能命中。
# 键名不区分大小写。
$BuiltInAlias = @{
    'new'             = '新建'
    'sharing'         = '共享 授予访问权限'
    'workfolders'     = '同步到工作文件夹 工作文件夹'
    'desktopslideshow'= '幻灯片放映 下一个桌面背景 切换背景'
    'display'         = '显示设置 屏幕分辨率'
    'personalize'     = '个性化 更改桌面背景 主题'
    'cmd'             = '命令窗口 终端 命令行 在此处打开命令窗口'
    'powershell'      = 'Powershell 窗口 终端 在此处打开 Powershell'
    'windowshere'     = '终端 在此处打开终端'
    'tortoisegit'     = '小乌龟 TortoiseGit Git 图标覆盖'
    'git_gui'         = 'Git 图形界面 Open Git GUI here'
    'git_shell'       = 'Git 命令行 Open Git Bash here'
    'filesyncex'      = 'OneDrive 云同步 始终保留在此设备上'
}

# ---------- 关键词匹配：把各项文本拼起来做包含/通配匹配 ----------
function Test-ItemMatch {
    param($Item, [string]$Keyword)
    $pattern = "*$Keyword*"

    # 显示名里的 & 是快捷键标记（如「个性化(&R)」），菜单上并不显示，去掉后再匹配，
    # 这样输入「个性化」也能命中。
    $displayClean = ($Item.Display -replace '&', '').Trim()

    $fields = @(
        $Item.Display,
        $displayClean,
        $Item.KeyName,
        $Item.RawText,
        $Item.Command,
        $Item.Component,
        $Item.Dll,
        $Item.Scope
    )

    # 再补上内置项的中文别名
    $aliasKey = ($Item.KeyName -replace '[^\w]', '').ToLower()
    if ($BuiltInAlias.ContainsKey($aliasKey)) { $fields += $BuiltInAlias[$aliasKey] }

    foreach ($f in $fields) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        if ($f -like $pattern) { return $true }
    }
    return $false
}

# 取出某项用于展示的「菜单真实文字」：内置项优先用别名，其它用显示名
function Get-ItemFriendlyName {
    param($Item)
    $aliasKey = ($Item.KeyName -replace '[^\w]', '').ToLower()
    $base = if ($Item.Display) { $Item.Display } else { $Item.KeyName }
    if ($BuiltInAlias.ContainsKey($aliasKey)) {
        $alias = ($BuiltInAlias[$aliasKey] -split ' ')[0]
        return "{0}（菜单上可能显示为：{1}）" -f $base, $alias
    }
    return $base
}

# ---------- 备份 ----------
function Backup-RegKey {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    # reg.exe 认 HKLM\... 这种写法，不认 PowerShell 的 HKLM:\... 和 Registry:: 前缀
    # 修复（2026-09-08）：Get-ChildItem 返回的 PSPath 实际带模块前缀，形如
    #   Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\...
    # 原来按 ^Registry:: 锚定的替换永远不命中，路径原样传给 reg.exe 导致导出恒失败，
    # 备份生成不了，删除被「备份失败，为安全起见未删除」拦截。
    # 改为先剥掉可选的「模块名\Registry::」前缀（模块名不含冒号），
    # 剩余 HKEY_ 开头的全名 reg.exe 直接认；再兜底转换 HKLM:\ / HKCU:\ 盘符式写法。
    $native = $Path -replace '^(?:[^:]+\\)?Registry::', '' `
                    -replace '^(HKCU|HKLM):\\',                '$1\'
    $safe = ($Label -replace '[\\/:*?"<>|]', '_')
    $file = Join-Path $BackupDir ("{0}_{1}.reg" -f $safe, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    & reg.exe export $native $file /y | Out-Null
    if (Test-Path -LiteralPath $file) { return $file } else { return $null }
}

# ---------- 查同一个 CLSID 还注册在哪些位置 ----------
# 「按用户屏蔽」是按组件全局生效的：一旦屏蔽，这个组件在所有位置的
# 右键菜单都会消失，不只是桌面。所以屏蔽前必须把连带影响列出来。
# 只扫常见的类根，避免遍历整个 Classes 造成明显卡顿。
$CommonClassRoots = @(
    'HKLM:\SOFTWARE\Classes',
    'HKCU:\Software\Classes'
)
$CommonClassNames = @(
    'DesktopBackground',
    'Directory', 'Directory\Background',
    'Drive', 'Folder', 'LibraryFolder',
    '*', 'AllFilesystemObjects',
    'lnk', 'exefile', 'txtfile', 'inifile', 'dllfile',
    '.zip', '.rar', '.7z'
)

function Get-ClsidUsageSites {
    param([string]$Clsid)
    $sites = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Clsid)) { return $sites }

    foreach ($root in $CommonClassRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($cls in $CommonClassNames) {
            $p = Join-Path (Join-Path $root $cls) 'shellex\ContextMenuHandlers'
            if (-not (Test-Path -LiteralPath $p)) { continue }
            foreach ($k in @(Get-ChildItem -LiteralPath $p -ErrorAction SilentlyContinue)) {
                $v = Get-RegValue -Path $k.PSPath
                if ($v -and $v.Trim().ToLower() -eq $Clsid.Trim().ToLower()) {
                    [void]$sites.Add([pscustomobject]@{
                        ClassName = $cls
                        KeyName   = $k.PSChildName
                        Path      = $k.PSPath
                        IsMachine = (Test-IsMachineKey -Path $k.PSPath)
                    })
                }
            }
        }
    }
    return $sites
}

# 把类名翻译成人话，方便看懂影响范围
function Get-ClassFriendlyName {
    param([string]$ClassName)
    switch ($ClassName) {
        'DesktopBackground'    { return '桌面壁纸背景右键' }
        'Directory\Background' { return '桌面空白处 / 文件夹窗口空白处右键' }
        'Directory'            { return '文件夹图标上右键' }
        'Drive'                { return '磁盘盘符上右键' }
        'Folder'               { return '所有文件夹（含虚拟文件夹）右键' }
        'LibraryFolder'        { return '库文件夹右键' }
        '*'                    { return '所有文件上右键' }
        'AllFilesystemObjects' { return '所有文件系统对象右键' }
        'lnk'                  { return '快捷方式上右键' }
        default                { return "$ClassName 类型文件上右键" }
    }
}

# ---------- 按用户屏蔽（HKLM 且无管理员权限时的替代方案） ----------
function Block-Extension {
    param([string]$Clsid)
    if (-not (Test-Path -LiteralPath $BlockedKey)) {
        New-Item -Path $BlockedKey -Force | Out-Null
    }
    New-ItemProperty -Path $BlockedKey -Name $Clsid -Value '' -PropertyType String -Force | Out-Null
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    Add-Content -LiteralPath $BlockMark -Value $Clsid -Encoding UTF8
}

# ---------- 执行删除 ----------
function Remove-MenuItem {
    param($Item)
    try {
        if ($Item.IsMachine -and -not $IsAdmin) {
            if ($Item.Clsid) {
                Block-Extension -Clsid $Item.Clsid
                return @{ Ok = $true; How = "已按用户屏蔽（权限不足，未改 HKLM）"; Backup = '' }
            }
            return @{ Ok = $false; How = ''; Backup = '' ;
                      Msg = '该项在 HKLM 且是普通命令项，无法屏蔽，需要以管理员身份运行' }
        }
        $bak = Backup-RegKey -Path $Item.Path -Label $Item.KeyName
        if (-not $bak) {
            return @{ Ok = $false; How = ''; Backup = ''; Msg = '备份失败，为安全起见未删除' }
        }
        # -Recurse 必需：Shell 下的项通常还有 command 子键
        Remove-Item -LiteralPath $Item.Path -Recurse -Force
        return @{ Ok = $true; How = '已删除'; Backup = $bak }
    }
    catch {
        return @{ Ok = $false; How = ''; Backup = ''; Msg = $_.Exception.Message }
    }
}

# ---------- 打印一项的详情 ----------
function Show-ItemDetail {
    param($Item, [int]$Index, [int]$Total)
    Write-Host ''
    Write-Host ("  [{0}/{1}] 菜单显示：{2}" -f $Index, $Total, (Get-ItemFriendlyName -Item $Item)) -ForegroundColor Cyan
    Write-Host ("         注册表键名：{0}    类型：{1}" -f $Item.KeyName, $Item.Kind)
    $levelText = if ($Item.IsMachine) {
        if ($IsAdmin) { '机器级 HKLM（全机生效，将以管理员身份删除）' }
        else { '机器级 HKLM（无管理员权限，将改用「按用户屏蔽」）' }
    } else { '用户级 HKCU（仅当前账户）' }
    Write-Host ("         所属范围  ：{0}    层级：{1}" -f $Item.Scope, $levelText)
    if ($Item.Command)   { Write-Host ("         执行命令  ：{0}" -f $Item.Command) }
    if ($Item.Component) { Write-Host ("         组件名称  ：{0}" -f $Item.Component) }
    if ($Item.Dll)       { Write-Host ("         来源文件  ：{0}" -f $Item.Dll) -ForegroundColor DarkGray }
    Write-Host ("         完整路径  ：{0}" -f $Item.Path) -ForegroundColor DarkGray

    # 只有「会走屏蔽路线」时才需要提示连带影响：
    # 屏蔽是按组件全局生效的，该组件注册的所有位置的菜单都会一起消失；
    # 而删除只删这一个键，不影响其它位置。
    if ($Item.IsMachine -and -not $IsAdmin -and $Item.Clsid) {
        $sites = @(Get-ClsidUsageSites -Clsid $Item.Clsid)
        $extra = @($sites | Where-Object { $_.Path -ne $Item.Path })
        Write-Host ''
        Write-Host '         ⚠ 本项将走「按用户屏蔽」，屏蔽是按组件全局生效的：' -ForegroundColor DarkYellow
        Write-Host ("           组件共注册在 {0} 处，除桌面外还会连带影响：" -f $sites.Count) -ForegroundColor DarkYellow
        if ($extra.Count -eq 0) {
            Write-Host '           （未发现其它位置，影响仅限当前这处）' -ForegroundColor DarkGray
        } else {
            foreach ($s in $extra) {
                Write-Host ("           · {0}   [键:{1}]" -f (Get-ClassFriendlyName -ClassName $s.ClassName), $s.KeyName) -ForegroundColor DarkYellow
            }
        }
        Write-Host '           若不希望连带影响，可改用管理员身份运行本脚本走「删除」路线。' -ForegroundColor DarkGray
    }
}

# 记录用户已同意屏蔽的组件，同一组件在批量处理时只确认一次
$ConfirmedBlocks = @{}

# ---------- 对一项执行删除/屏蔽，并打印结果 ----------
# 返回 $true 表示确实改动了系统
function Invoke-MenuItemRemoval {
    param($Item)

    # 屏蔽会影响该组件注册的所有位置，动手前再确认一次（每个组件只问一次）
    if ($Item.IsMachine -and -not $IsAdmin -and $Item.Clsid) {
        if (-not $ConfirmedBlocks.ContainsKey($Item.Clsid)) {
            Write-Host ''
            $ok = Read-Host '         确认接受上述连带影响并屏蔽该组件？[Y]确认屏蔽  [N]取消'
            if ($ok.Trim().ToLower() -ne 'y') {
                Write-Host '         已取消，未做任何改动。' -ForegroundColor DarkGray
                return $false
            }
            $ConfirmedBlocks[$Item.Clsid] = $true
        }
    }

    $r = Remove-MenuItem -Item $Item
    if ($r.Ok) {
        Write-Host ("         >> {0}" -f $r.How) -ForegroundColor Green
        if ($r.Backup) { Write-Host ("            备份：{0}" -f $r.Backup) -ForegroundColor DarkGray }
        if ($r.How -like '*屏蔽*' -and $Item.Clsid) { [void]$script:blockedList.Add($Item.Clsid) }
        return $true
    }
    Write-Host ("         >> 失败：{0}" -f $r.Msg) -ForegroundColor Red
    return $false
}

# ==================== 主流程 ====================
Write-Host ''
Write-Host '============ 右键菜单清理工具 ============' -ForegroundColor Yellow
Write-Host ("当前账户是否管理员：{0}" -f $(if ($IsAdmin) { '是' } else { '否（机器级项将改用"按用户屏蔽"）' }))
Write-Host ("扫描范围：{0}" -f ($ScanScopes -join ', '))
Write-Host ("备份目录：{0}" -f $BackupDir)

$items = @(Get-ContextMenuItems)
Write-Host ''
Write-Host ("共扫描到 {0} 个右键菜单项。" -f $items.Count) -ForegroundColor Green

if ($ShowAllFirst -and $items.Count -gt 0) {
    Write-Host ''
    Write-Host '--------- 当前全部菜单项（供你对照着输入关键词）---------' -ForegroundColor Yellow
    $n = 0
    foreach ($it in $items) {
        $n++
        $who = if ($it.Dll) { $it.Dll } elseif ($it.Command) { $it.Command } else { '' }
        Write-Host ("{0,3}. [{1}] {2}  <键:{3}>  {4}" -f $n, $it.Scope, (Get-ItemFriendlyName -Item $it), $it.KeyName, $who) -ForegroundColor DarkGray
    }
}

$changed = $false
$blockedList = New-Object System.Collections.ArrayList

while ($true) {
    Write-Host ''
    $kw = Read-Host '请输入要查找的菜单文字（直接回车退出）'
    if ([string]::IsNullOrWhiteSpace($kw)) { break }
    $kw = $kw.Trim()

    # 每次重新扫描，保证看到的是最新状态（上一轮删过的不会再出现）
    $items = @(Get-ContextMenuItems)
    $hits = @($items | Where-Object { Test-ItemMatch -Item $_ -Keyword $kw })

    if ($hits.Count -eq 0) {
        Write-Host ''
        Write-Host ("没有找到与「{0}」相关的菜单项。" -f $kw) -ForegroundColor DarkYellow
        Write-Host '  可以试试更短的词、英文名，或用 * 通配（例如 *Git*）。' -ForegroundColor DarkGray
        continue
    }

    Write-Host ''
    Write-Host ("「{0}」命中 {1} 项：" -f $kw, $hits.Count) -ForegroundColor Green

    $deleteAll = $false
    $quitKeyword = $false
    $idx = 0
    foreach ($h in $hits) {
        $idx++
        if ($quitKeyword) { break }
        Show-ItemDetail -Item $h -Index $idx -Total $hits.Count

        # 已经不在注册表里了（可能被其它进程改动）
        if (-not (Test-Path -LiteralPath $h.Path)) {
            Write-Host '         该项当前已不存在，跳过。' -ForegroundColor DarkGray
            continue
        }

        if ($deleteAll) {
            $ans = 'y'
        } else {
            Write-Host ''
            $ans = Read-Host '         是否删除？[Y]删除  [N]跳过  [A]删除本关键词全部命中  [Q]不再处理本关键词'
            $ans = $ans.Trim().ToLower()
        }

        switch ($ans) {
            'y' {
                if (Invoke-MenuItemRemoval -Item $h) { $changed = $true }
            }
            'a' {
                $deleteAll = $true
                if (Invoke-MenuItemRemoval -Item $h) { $changed = $true }
            }
            'q' { $quitKeyword = $true; Write-Host '         已跳过本关键词剩余项。' -ForegroundColor DarkGray }
            default { Write-Host '         已跳过。' -ForegroundColor DarkGray }
        }
    }
}

# ==================== 收尾 ====================
Write-Host ''
Write-Host '============ 结束 ============' -ForegroundColor Yellow

if ($changed) {
    Write-Host ("备份文件夹：{0}" -f $BackupDir) -ForegroundColor Green
    Write-Host '  还原方法：双击对应的 .reg 文件 → 确认导入。' -ForegroundColor DarkGray

    if ($blockedList.Count -gt 0) {
        Write-Host ''
        Write-Host '本次有项目走的是「按用户屏蔽」而非删除，还原方法：' -ForegroundColor Cyan
        foreach ($c in ($blockedList | Select-Object -Unique)) {
            Write-Host ("  Remove-ItemProperty -LiteralPath '{0}' -Name '{1}'" -f $BlockedKey, $c) -ForegroundColor DarkCyan
        }
        Write-Host ("  以上 CLSID 也已记录在：{0}" -f $BlockMark) -ForegroundColor DarkGray
    }

    if ($RestartExplorer) {
        Write-Host ''
        $re = Read-Host '是否立即重启资源管理器以刷新菜单？[Y/N]'
        if ($re.Trim().ToLower() -eq 'y') {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
            Write-Host '已刷新，现在可以右键桌面验证效果。' -ForegroundColor Green
        } else {
            Write-Host '改动需要注销重新登录（或重启电脑）后才会在菜单里消失。' -ForegroundColor DarkYellow
        }
    } else {
        Write-Host ''
        Write-Host '改动需要注销重新登录（或重启电脑）后才会在菜单里消失。' -ForegroundColor DarkYellow
    }
}
else {
    Write-Host '没有对系统做任何修改。' -ForegroundColor DarkGray
}
Write-Host ''
