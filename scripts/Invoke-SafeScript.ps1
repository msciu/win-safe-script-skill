#requires -Version 5.1
<#
.SYNOPSIS
    Windows 安全脚本执行器：禁止内联、强制编码、参数走文件、输出归一为 JSON。

.DESCRIPTION
    把代理写好的脚本正文规范化后落到临时目录再执行，规避三类问题：
      1. 内联执行被 shell / PowerShell / cmd 多层解析破坏（引号、$、反引号、换行）；
      2. 文件编码不一致（PS 5.1 对无 BOM 的 UTF-8 按 ANSI 解析、bat 带 BOM 报错）；
      3. 参数拼命令行被转义破坏（中文、空格、反斜杠）。

    语言约定：
      ps1 -> 包装脚本 + UTF-8 BOM，控制台输出强制 UTF-8
      py  -> UTF-8 无 BOM，PYTHONUTF8=1 / PYTHONIOENCODING=utf-8
      bat -> UTF-8 无 BOM，注入 @echo off + chcp 65001，CRLF 换行
      js  -> UTF-8，.js 内含顶层 import 时按 .mjs 执行

.PARAMETER File
    源脚本路径。原样写入即可，不需要自己处理编码或转义。

.PARAMETER Lang
    ps1 | py | bat | js。默认按扩展名判断。

.PARAMETER ParamsJson
    参数 JSON 字符串。写入 params.json，路径通过 SCRIPT_PARAMS_FILE 传给脚本。

.PARAMETER ParamsFile
    参数 JSON 文件路径（与 -ParamsJson 二选一）。

.PARAMETER Arguments
    位置参数数组，不经 shell 直接传给子进程。

.PARAMETER TimeoutSeconds
    超时秒数，默认 120。超时强杀进程树。

.PARAMETER WorkingDirectory
    工作目录，默认源脚本所在目录。

.PARAMETER OutDir
    运行目录的父目录，默认 %TEMP%\win-safe-script。

.PARAMETER Interpreter
    指定解释器路径（例如真实 python.exe、pwsh.exe）。

.PARAMETER MaxOutputChars
    stdout / stderr 返回上限，默认 8000；完整内容始终在 artifacts 里。

.PARAMETER Cleanup
    成功后删除临时目录（artifacts 将失效）。

.PARAMETER Check
    只探测环境能力并输出 JSON，不执行脚本。

.EXAMPLE
    Invoke-SafeScript.ps1 -File .\.tmp\job.ps1 -ParamsJson '{"name":"张三"}'

.EXAMPLE
    Invoke-SafeScript.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$File,
    [ValidateSet('ps1', 'py', 'bat', 'js')][string]$Lang,
    [string]$ParamsJson,
    [string]$ParamsFile,
    [string[]]$Arguments = @(),
    [string]$ArgumentsJson,
    [int]$TimeoutSeconds = 120,
    [string]$WorkingDirectory,
    [string]$OutDir,
    [string]$Interpreter,
    [int]$MaxOutputChars = 8000,
    [switch]$Cleanup,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 任何未预期异常也要返回 JSON，避免调用方拿到空输出。
trap {
    $msg = $_.Exception.Message
    $body = [ordered]@{
        schemaVersion = 1
        ok            = $false
        error         = [ordered]@{ code = 'INTERNAL_ERROR'; message = $msg; detail = $_.InvocationInfo.PositionMessage }
    }
    Write-Output ($body | ConvertTo-Json -Depth 8 -Compress)
    exit 70
}

# ---------------------------------------------------------------- 基础设施

function New-JsonText {
    param($Object)
    return ($Object | ConvertTo-Json -Depth 12 -Compress)
}

function Stop-SafeScript {
    param([string]$Code, [string]$Message, $Detail)
    $body = [ordered]@{
        schemaVersion = 1
        ok            = $false
        error         = [ordered]@{ code = $Code; message = $Message }
    }
    if ($null -ne $Detail) { $body.error['detail'] = $Detail }
    Write-Output (New-JsonText $body)
    exit 70
}

function Write-TextFile {
    param([string]$Path, [string]$Text, [switch]$Bom, [switch]$Crlf)
    if ($null -eq $Text) { $Text = '' }
    if ($Crlf) {
        $t = $Text -replace "`r`n", "`n"
        $Text = $t -replace "`n", "`r`n"
    }
    $enc = New-Object System.Text.UTF8Encoding([bool]$Bom)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# 读入源文件：识别/剥离 BOM，UTF-8 严格解码失败时回退 GBK 并标记。
function Read-SourceText {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hadBom = $false
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $hadBom = $true
        if ($bytes.Length -gt 3) { $bytes = $bytes[3..($bytes.Length - 1)] } else { $bytes = @() }
    }
    $text = ''
    $enc = 'utf-8'
    if ($bytes.Length -gt 0) {
        try {
            $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
        }
        catch {
            $text = [System.Text.Encoding]::GetEncoding(936).GetString($bytes)
            $enc = 'gbk'
        }
    }
    return [pscustomobject]@{ Text = $text; Encoding = $enc; HadBom = $hadBom }
}

# 读入子进程输出：UTF-8 严格解码，非法字节回退 GBK 并如实标记。
function Read-CapturedText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Text = ''; Encoding = 'none' }
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) {
        return [pscustomobject]@{ Text = ''; Encoding = 'none' }
    }
    $bom = $false
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bom = $true
        if ($bytes.Length -gt 3) { $bytes = $bytes[3..($bytes.Length - 1)] } else { $bytes = @() }
    }
    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
        $enc = 'utf-8'
    }
    catch {
        $text = [System.Text.Encoding]::GetEncoding(936).GetString($bytes)
        $enc = 'gbk'
    }
    if ($bom) { $enc = 'utf-8-bom' }
    return [pscustomobject]@{ Text = $text; Encoding = $enc }
}

function Limit-Text {
    param([string]$Text, [int]$Max)
    if ($null -eq $Text) { $Text = '' }
    if ($Max -le 0 -or $Text.Length -le $Max) {
        return [pscustomobject]@{ Text = $Text; Truncated = $false }
    }
    $head = [int][Math]::Floor($Max / 2)
    $tailLen = $Max - $head
    $marker = "`n...<truncated " + ($Text.Length - $Max) + " chars>...`n"
    $sliced = $Text.Substring(0, $head) + $marker + $Text.Substring($Text.Length - $tailLen)
    return [pscustomobject]@{ Text = $sliced; Truncated = $true }
}

function Format-Arg {
    param([string]$Value)
    if ($null -eq $Value -or $Value -eq '') { return '""' }
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Get-ConsoleCodePage {
    try {
        $out = & chcp.com 2>$null
        if ("$out" -match '(\d{3,5})') { return [int]$Matches[1] }
    }
    catch { }
    return $null
}

# 找可用 python。Windows 上常见三种"看起来有、其实不能用"：
#   1) WindowsApps 下的 0 字节商店占位符；
#   2) conda：PATH 里只有 <root>\condabin，真正的 python.exe 在其上一级；
#   3) 工具进程的 PATH 与交互式 shell 不同（注册表里还有一份）。
# 因此逐个候选实测 `-V`，能打印 "Python 3.x" 才采用。
function Add-PythonCandidate {
    param($List, $Seen, [string]$Path, [string]$Source, [string[]]$Prefix = @())
    if (-not $Path) { return }
    if ($Path -notmatch '\.exe$') { return }
    $key = $Path.ToLowerInvariant()
    if ($Seen.ContainsKey($key)) { return }
    $Seen[$key] = $true
    [void]$List.Add([pscustomobject]@{ Path = $Path; Source = $Source; Prefix = $Prefix })
}

function Test-PythonExe {
    param([string]$Path)
    if (-not $Path) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $item = Get-Item -LiteralPath $Path
        if ($item.Length -le 0) { return $null }   # 商店占位符
    }
    catch { return $null }
    $probe = Invoke-Probe -Exe $item.FullName -Arguments @('-V')
    if ($probe.ok -and $probe.text -match 'Python\s+3\.\d') {
        $ver = ($probe.text -split "`n")[0].Trim()
        return [pscustomobject]@{ Path = $item.FullName; Prefix = @(); Version = $ver; Source = '' }
    }
    return $null
}

function Get-PythonCandidates {
    param([switch]$Deep)
    $seen = @{}
    $list = New-Object System.Collections.ArrayList

    if ($Deep) {
        # 自定义安装路径（例如 <盘符>\Tools\anaconda 这类非默认位置）：扫盘符根下两层的 *conda*/*python* 目录
        try {
            foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
                if ($drive.DriveType -ne 'Fixed' -or -not $drive.IsReady) { continue }
                $skip = '^(Windows|Program Files|Program Files \(x86\)|ProgramData|\$Recycle\.Bin|System Volume Information|Recovery|PerfLogs|Users|Program Files \(x86\))$'
                $level1 = Get-ChildItem -LiteralPath $drive.RootDirectory.FullName -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch $skip }
                foreach ($d1 in $level1) {
                    if ($d1.Name -match 'conda|python') {
                        Add-PythonCandidate $list $seen (Join-Path $d1.FullName 'python.exe') 'drive-scan' @()
                    }
                    $level2 = Get-ChildItem -LiteralPath $d1.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -First 300
                    foreach ($d2 in $level2) {
                        if ($d2.Name -match 'conda|python') {
                            Add-PythonCandidate $list $seen (Join-Path $d2.FullName 'python.exe') 'drive-scan' @()
                        }
                    }
                }
            }
        }
        catch { }
        return $list
    }

    # 1) 显式环境变量
    Add-PythonCandidate $list $seen $env:WSS_PYTHON 'env:WSS_PYTHON' @()

    # 2) conda：CONDA_PREFIX / CONDA_ROOT / CONDA_EXE 推导
    foreach ($k in @('CONDA_PREFIX', 'CONDA_ROOT')) {
        $v = [Environment]::GetEnvironmentVariable($k)
        if ($v) { Add-PythonCandidate $list $seen (Join-Path $v 'python.exe') ('env:' + $k) @() }
    }
    if ($env:CONDA_EXE) {
        $root = Split-Path -Parent (Split-Path -Parent $env:CONDA_EXE)   # <root>\Scripts\conda.exe
        if ($root) { Add-PythonCandidate $list $seen (Join-Path $root 'python.exe') 'env:CONDA_EXE' @() }
    }

    # 3) 当前进程 PATH
    foreach ($name in @('python.exe', 'python3.exe')) {
        foreach ($c in @(Get-Command $name -All -ErrorAction SilentlyContinue)) {
            if ($c -and $c.Source) { Add-PythonCandidate $list $seen $c.Source 'process-PATH' @() }
        }
    }

    # 4) 注册表 PATH（工具进程常常看不到交互式 shell 的 PATH）
    foreach ($hive in @('HKCU:\Environment', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment')) {
        $raw = $null
        try { $raw = (Get-ItemProperty -Path $hive -Name Path -ErrorAction SilentlyContinue).Path } catch { }
        if (-not $raw) { continue }
        foreach ($entry in ($raw -split ';')) {
            if (-not $entry) { continue }
            $dir = [Environment]::ExpandEnvironmentVariables($entry.Trim())
            if (-not $dir) { continue }
            Add-PythonCandidate $list $seen (Join-Path $dir 'python.exe') 'registry-PATH' @()
            # conda 布局：PATH 指向 condabin / Scripts / bin，python 在上一级
            if ($dir -match '\\(condabin|Scripts|bin)$') {
                $parent = Split-Path -Parent $dir
                if ($parent) { Add-PythonCandidate $list $seen (Join-Path $parent 'python.exe') 'registry-PATH(conda-parent)' @() }
            }
        }
    }

    # 5) 常见安装位置
    $bases = @($env:USERPROFILE, $env:LOCALAPPDATA, $env:ProgramData, 'C:\', 'C:\Program Files')
    $names = @('anaconda3', 'miniconda3', 'Anaconda3', 'Miniconda3', 'mambaforge', 'miniforge3',
        'Python313', 'Python312', 'Python311', 'Python310')
    foreach ($base in $bases) {
        if (-not $base) { continue }
        foreach ($n in $names) {
            $dir = Join-Path $base $n
            if (Test-Path -LiteralPath $dir -PathType Container) {
                Add-PythonCandidate $list $seen (Join-Path $dir 'python.exe') 'common-dir' @()
            }
        }
    }
    $pyRoot = Join-Path $env:LOCALAPPDATA 'Programs\Python'
    if (Test-Path -LiteralPath $pyRoot) {
        Get-ChildItem -LiteralPath $pyRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Add-PythonCandidate $list $seen (Join-Path $_.FullName 'python.exe') 'python.org' @()
        }
    }

    # 6) py 启动器（本身是 launcher，需要 -3 前缀）
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py -and $py.Source) { Add-PythonCandidate $list $seen $py.Source 'py-launcher' @('-3') }

    return $list
}

function Find-Python {
    param([string]$Explicit)
    if ($Explicit) {
        $hit = Test-PythonExe -Path $Explicit
        if ($hit) { $hit.Source = 'param'; return $hit }
        return $null
    }
    foreach ($pass in @('fast', 'deep')) {
        if ($pass -eq 'fast') { $cands = Get-PythonCandidates }
        else { $cands = Get-PythonCandidates -Deep }
        foreach ($cand in $cands) {
            $hit = Test-PythonExe -Path $cand.Path
            if ($hit) {
                $hit.Source = $cand.Source
                $hit.Prefix = $cand.Prefix
                return $hit
            }
        }
    }
    return $null
}

function Invoke-Probe {
    param([string]$Exe, [string[]]$Arguments = @())
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wss-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $o = Join-Path $tmp 'o.txt'
    $e = Join-Path $tmp 'e.txt'
    $result = [pscustomobject]@{ ok = $false; exitCode = $null; text = '' }
    try {
        # 必须 -Wait：不带 -Wait 时 Start-Process 返回的对象读不到 ExitCode（句柄已释放）
        $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $o -RedirectStandardError $e
        $result.exitCode = $p.ExitCode
        $result.ok = ($p.ExitCode -eq 0)
        $result.text = ((Read-CapturedText -Path $o).Text + ' ' + (Read-CapturedText -Path $e).Text).Trim()
    }
    catch {
        $result.text = $_.Exception.Message
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $result
}

# ---------------------------------------------------------------- -Check

if ($Check) {
    $hostPs = $PSVersionTable.PSVersion.ToString()
    $consoleCp = $null
    try { $consoleCp = [Console]::OutputEncoding.CodePage } catch { }
    $activeCp = Get-ConsoleCodePage

    $psExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    $nodeExe = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
    $cmdExe = (Get-Command cmd.exe -ErrorAction SilentlyContinue).Source

    $py = Find-Python -Explicit $Interpreter
    $pyInfo = [ordered]@{ available = $false; path = $null; version = $null; reason = 'not-found' }
    if ($py) {
        # Find-Python 已经实测过 -V，这里直接用结果，避免再起一个进程
        $pyInfo.available = $true
        $pyInfo.path = $py.Path
        $pyInfo.version = $py.Version
        $pyInfo.source = $py.Source
        $pyInfo.reason = $null
    }
    else {
        $stub = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\python.exe'
        if (Test-Path -LiteralPath $stub) { $pyInfo.reason = 'windowsapps-stub-only' }
    }

    $nodeInfo = [ordered]@{ available = [bool]$nodeExe; path = $nodeExe }
    if ($nodeExe) { $nodeInfo.version = (Invoke-Probe -Exe $nodeExe -Arguments @('-v')).text }

    $notes = @()
    if (-not $pyInfo.available) {
        $notes += 'python 不可用：改用 PowerShell/Node 实现，或 winget install Python.Python.3.12 后用 -Interpreter 指定路径。'
    }
    if (-not $nodeExe) { $notes += 'node 不可用：js 模板不可用。' }
    if ($activeCp -ne 65001) {
        $notes += ('当前控制台代码页 ' + $activeCp + '（非 65001），执行器会在子进程内自行固定编码，无需手动 chcp。')
    }

    $body = [ordered]@{
        schemaVersion = 1
        ok            = $true
        mode          = 'check'
        host          = [ordered]@{
            psVersion   = $hostPs
            os          = [System.Environment]::OSVersion.VersionString
            consoleCp   = $consoleCp
            activeCp    = $activeCp
            temp        = [System.IO.Path]::GetTempPath()
        }
        interpreters  = [ordered]@{
            powershell = [ordered]@{ path = $psExe; version = $hostPs }
            pwsh       = [ordered]@{ path = $pwshExe }
            python     = $pyInfo
            node       = $nodeInfo
            cmd        = [ordered]@{ path = $cmdExe }
        }
        notes         = $notes
    }
    Write-Output (New-JsonText $body)
    exit 0
}

# ---------------------------------------------------------------- 主流程

if (-not $File) {
    Stop-SafeScript 'ARG_MISSING' '缺少 -File；只想探测环境请用 -Check。'
}

try {
    $sourceFull = (Resolve-Path -LiteralPath $File).ProviderPath
}
catch {
    Stop-SafeScript 'FILE_NOT_FOUND' ("找不到脚本文件：" + $File)
}
if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) {
    Stop-SafeScript 'FILE_NOT_FOUND' ("不是文件：" + $sourceFull)
}

$ext = [System.IO.Path]::GetExtension($sourceFull).ToLowerInvariant()
if (-not $Lang) {
    $langMap = @{ '.ps1' = 'ps1'; '.py' = 'py'; '.bat' = 'bat'; '.cmd' = 'bat'; '.js' = 'js'; '.mjs' = 'js'; '.cjs' = 'js' }
    if (-not $langMap.ContainsKey($ext)) {
        Stop-SafeScript 'LANG_UNKNOWN' ("无法从扩展名 " + $ext + " 判断语言，请用 -Lang ps1|py|bat|js。")
    }
    $Lang = $langMap[$ext]
}

# 参数
$paramsText = $null
if ($ParamsFile) {
    try { $paramsText = (Read-SourceText -Path (Resolve-Path -LiteralPath $ParamsFile).ProviderPath).Text }
    catch { Stop-SafeScript 'PARAMS_FILE_NOT_FOUND' ("找不到参数文件：" + $ParamsFile) }
}
elseif ($ParamsJson) {
    $paramsText = $ParamsJson
}
$paramsObject = $null
if ($null -ne $paramsText -and $paramsText.Trim().Length -gt 0) {
    try { $paramsObject = $paramsText.Trim() | ConvertFrom-Json }
    catch { Stop-SafeScript 'PARAMS_INVALID' '参数不是合法 JSON（中文请确保已按 UTF-8 提供）。' }
}

$src = Read-SourceText -Path $sourceFull

# 运行目录
$baseOut = $OutDir
if (-not $baseOut) { $baseOut = Join-Path ([System.IO.Path]::GetTempPath()) 'win-safe-script' }
try { New-Item -ItemType Directory -Force -Path $baseOut | Out-Null }
catch { Stop-SafeScript 'OUTDIR_FAILED' ("无法创建运行目录：" + $baseOut) }
$suffix = -join (1..4 | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
$work = Join-Path $baseOut ((Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' + $suffix)
New-Item -ItemType Directory -Force -Path $work | Out-Null

$notes = @()

# 工作目录：默认源脚本所在目录
$cwd = $WorkingDirectory
if (-not $cwd) { $cwd = Split-Path -Parent $sourceFull }
if (-not (Test-Path -LiteralPath $cwd -PathType Container)) {
    Stop-SafeScript 'CWD_INVALID' ("工作目录不存在：" + $cwd)
}

# 参数落地
$paramsPath = $null
$paramSetLines = @()
if ($null -ne $paramsObject) {
    $paramsPath = Join-Path $work 'params.json'
    Write-TextFile -Path $paramsPath -Text $paramsText.Trim()
    if ($Lang -eq 'bat') {
        if ($paramsObject -is [System.Management.Automation.PSCustomObject]) {
            foreach ($prop in $paramsObject.PSObject.Properties) {
                $name = 'P_' + ($prop.Name -replace '[^A-Za-z0-9_]', '_')
                $value = [string]$prop.Value
                if ($prop.Value -is [bool]) { if ($prop.Value) { $value = '1' } else { $value = '0' } }
                # 值直接内联进 user.bat 的 set 行：引号内的 & | < > 是字面量，不需 ^ 转义；
                # 只有 % 必须写成 %%（否则会被当成变量引用）。双引号与换行无法安全内联。
                if ($value -match '"') {
                    $notes += ('参数 ' + $prop.Name + ' 含双引号，未注入 bat（只在 params.json 里），请改读 SCRIPT_PARAMS_FILE。')
                    continue
                }
                if ($value -match "[`r`n]") {
                    $notes += ('参数 ' + $prop.Name + ' 含换行，未注入 bat，请改读 SCRIPT_PARAMS_FILE。')
                    continue
                }
                $value = $value -replace '%', '%%'
                $paramSetLines += ('set "' + $name + '=' + $value + '"')
            }
        }
        else {
            $notes += '参数是数组/标量，未注入 bat；请在 script 里解析 SCRIPT_PARAMS_FILE。'
        }
    }
}

# 解释器与参数
$exe = $null
$exeArgs = @()
$executedPath = $null
$executedEnc = 'utf-8'

switch ($Lang) {
    'ps1' {
        $executedPath = Join-Path $work 'user.ps1'
        Write-TextFile -Path $executedPath -Text $src.Text -Bom
        $executedEnc = 'utf-8-bom'
        $wrapper = @'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = [Console]::OutputEncoding
$ProgressPreference = 'SilentlyContinue'
$target = Join-Path $PSScriptRoot 'user.ps1'
$argv = @()
$argv = @()
if ($env:WSS_ARGS) {
    try {
        $parsed = $env:WSS_ARGS | ConvertFrom-Json
        if ($null -ne $parsed) { $argv = [string[]]$parsed }
    }
    catch { $argv = @() }
}
$global:LASTEXITCODE = 0
& $target @argv
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
exit [int]$code
'@
        $mainPs1 = Join-Path $work 'main.ps1'
        Write-TextFile -Path $mainPs1 -Text $wrapper -Bom
        $exe = 'powershell.exe'
        if ($Interpreter) { $exe = $Interpreter }
        $exeArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Format-Arg $mainPs1))
    }
    'py' {
        $py = Find-Python -Explicit $Interpreter
        if (-not $py) {
            Stop-SafeScript 'CAPABILITY_MISSING' 'python 不可用：已排查 PATH、conda（CONDA_PREFIX/CONDA_EXE）、注册表 PATH、常见安装目录与盘符浅扫，未找到能执行 -V 的 python.exe（WindowsApps 的 0 字节占位符会被排除）。可用 -Interpreter 指定真实路径，或 -Check 查看探测详情，或改用 ps1/js 实现。'
        }
        $executedPath = Join-Path $work 'user.py'
        Write-TextFile -Path $executedPath -Text $src.Text
        $exe = $py.Path
        $exeArgs = @()
        $exeArgs += $py.Prefix
        $exeArgs += (Format-Arg $executedPath)
    }
    'bat' {
        $executedPath = Join-Path $work 'user.bat'
        $preamble = "@echo off`r`nchcp 65001 >nul`r`n"
        if ($paramSetLines.Count -gt 0) { $preamble += (($paramSetLines -join "`r`n") + "`r`n") }
        Write-TextFile -Path $executedPath -Text ($preamble + $src.Text) -Crlf
        $exe = 'cmd.exe'
        if ($Interpreter) { $exe = $Interpreter }
        $exeArgs = @('/d', '/c', 'call', (Format-Arg $executedPath))
    }
    'js' {
        $jsExt = '.js'
        if ($ext -eq '.mjs') { $jsExt = '.mjs' }
        if ($ext -eq '.cjs') { $jsExt = '.cjs' }
        if ($jsExt -eq '.js' -and $src.Text -match '(?m)^\s*import\b(?!\s*\()') {
            $jsExt = '.mjs'
            $notes += '.js 内含顶层 import，已按 .mjs 执行。'
        }
        $executedPath = Join-Path $work ('user' + $jsExt)
        Write-TextFile -Path $executedPath -Text $src.Text
        $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
        if ($Interpreter) { $exe = $Interpreter }
        elseif ($nodeCmd) { $exe = $nodeCmd.Source }
        else { Stop-SafeScript 'CAPABILITY_MISSING' 'node 不可用：未找到 node.exe。改用 ps1 实现或安装 Node.js。' }
        $exeArgs = @((Format-Arg $executedPath))
    }
}

if ($ArgumentsJson) {
    try {
        $parsedArgs = $ArgumentsJson | ConvertFrom-Json
        if ($null -ne $parsedArgs) { $Arguments = [string[]]$parsedArgs }
    }
    catch { Stop-SafeScript 'ARGS_INVALID' '-ArgumentsJson 不是合法 JSON 数组，例如 ''["a","b"]''。' }
}
foreach ($a in $Arguments) { $exeArgs += (Format-Arg $a) }

# 子进程环境
$envNames = @('SCRIPT_PARAMS_FILE', 'SCRIPT_PARAMS_JSON', 'WSS_ARGS', 'WSS_SOURCE_DIR',
    'PYTHONUTF8', 'PYTHONIOENCODING', 'PYTHONLEGACYWINDOWSSTDIO')
$savedEnv = @{}
foreach ($n in $envNames) { $savedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }

if ($paramsPath) {
    [Environment]::SetEnvironmentVariable('SCRIPT_PARAMS_FILE', $paramsPath)
    [Environment]::SetEnvironmentVariable('SCRIPT_PARAMS_JSON', $paramsText.Trim())
}
[Environment]::SetEnvironmentVariable('WSS_ARGS', (ConvertTo-Json -InputObject @($Arguments) -Compress))
[Environment]::SetEnvironmentVariable('WSS_SOURCE_DIR', (Split-Path -Parent $sourceFull))
if ($Lang -eq 'py') {
    [Environment]::SetEnvironmentVariable('PYTHONUTF8', '1')
    [Environment]::SetEnvironmentVariable('PYTHONIOENCODING', 'utf-8')
    [Environment]::SetEnvironmentVariable('PYTHONLEGACYWINDOWSSTDIO', '0')
}

# 执行
$outFile = Join-Path $work 'stdout.txt'
$errFile = Join-Path $work 'stderr.txt'
$origCp = $null
if ($Lang -eq 'bat') { $origCp = Get-ConsoleCodePage }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
# 用 Process 而不是 Start-Process：后者在不带 -Wait 时拿不到 ExitCode（句柄已释放），
# 而 -Wait 又没法做超时。这里自行重定向 + 等待，输出按字节落盘，编码后判。
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = ($exeArgs -join ' ')
$psi.WorkingDirectory = $cwd
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi

$outStream = $null
$errStream = $null
$outCopy = $null
$errCopy = $null
try {
    if (-not $proc.Start()) { throw 'Process.Start 返回 false' }
    $outStream = [System.IO.File]::Create($outFile)
    $errStream = [System.IO.File]::Create($errFile)
    $outCopy = $proc.StandardOutput.BaseStream.CopyToAsync($outStream)
    $errCopy = $proc.StandardError.BaseStream.CopyToAsync($errStream)
}
catch {
    foreach ($n in $envNames) { [Environment]::SetEnvironmentVariable($n, $savedEnv[$n]) }
    Stop-SafeScript 'SPAWN_FAILED' ("无法启动解释器 " + $exe + "：" + $_.Exception.Message)
}

$timedOut = $false
if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    $timedOut = $true
    try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
    try { $null = $proc.WaitForExit(5000) } catch { }
}
try { $null = $proc.WaitForExit(500) } catch { }
if ($outCopy) { try { $null = $outCopy.Wait(5000) } catch { } }
if ($errCopy) { try { $null = $errCopy.Wait(5000) } catch { } }
try { if ($outStream) { $outStream.Dispose() } } catch { }
try { if ($errStream) { $errStream.Dispose() } } catch { }
$sw.Stop()

$exitCode = -1
try { $exitCode = [int]$proc.ExitCode } catch { }
try { $proc.Dispose() } catch { }

if ($null -ne $origCp) {
    try { & chcp.com ([string]$origCp) | Out-Null } catch { }
    $notes += ('已恢复控制台代码页 ' + $origCp + '（bat 内的 chcp 会作用于共享控制台）。')
}

foreach ($n in $envNames) { [Environment]::SetEnvironmentVariable($n, $savedEnv[$n]) }

$outRead = Read-CapturedText -Path $outFile
$errRead = Read-CapturedText -Path $errFile
$outLimited = Limit-Text -Text $outRead.Text -Max $MaxOutputChars
$errLimited = Limit-Text -Text $errRead.Text -Max $MaxOutputChars

if ($timedOut) {
    $notes += ('执行超过 ' + $TimeoutSeconds + ' 秒，已强制结束进程树；常见原因是脚本在等输入（param 必填 / Read-Host / pause）。')
}

$ok = (-not $timedOut) -and ($exitCode -eq 0)

$result = [ordered]@{
    schemaVersion = 1
    ok            = $ok
    lang          = $Lang
    exitCode      = $exitCode
    timedOut      = $timedOut
    durationMs    = [int]$sw.ElapsedMilliseconds
    command       = ($exe + ' ' + ($exeArgs -join ' '))
    workingDirectory = $cwd
    script        = [ordered]@{
        source           = $sourceFull
        executed         = $executedPath
        sourceEncoding   = $src.Encoding
        executedEncoding = $executedEnc
        sourceHadBom     = $src.HadBom
    }
    params        = [ordered]@{
        file  = $paramsPath
        vars  = $paramSetLines.Count
        bytes = 0
    }
    stdout        = $outLimited.Text
    stderr        = $errLimited.Text
    truncated     = [ordered]@{ stdout = $outLimited.Truncated; stderr = $errLimited.Truncated }
    encoding      = [ordered]@{ stdout = $outRead.Encoding; stderr = $errRead.Encoding }
    artifacts     = [ordered]@{
        dir        = $work
        stdoutFile = $outFile
        stderrFile = $errFile
        paramsFile = $paramsPath
        resultFile = (Join-Path $work 'result.json')
    }
    notes         = $notes
}
if ($paramsPath) {
    try { $result.params.bytes = (Get-Item -LiteralPath $paramsPath).Length } catch { }
}

$json = New-JsonText $result
try { Write-TextFile -Path (Join-Path $work 'result.json') -Text $json } catch { }

if ($Cleanup -and $ok) {
    try {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop
        $result.artifacts = [ordered]@{ dir = '(removed by -Cleanup)'; stdoutFile = ''; stderrFile = ''; paramsFile = ''; resultFile = '' }
        $json = New-JsonText $result
    }
    catch { }
}

Write-Output $json
exit $exitCode
