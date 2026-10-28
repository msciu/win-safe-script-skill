#requires -Version 5.1
<#
.SYNOPSIS
    win-safe-script 自测矩阵：验证 4 种语言在中文 / emoji / 引号 / 反斜杠 / JSON 往返下不坏。

.DESCRIPTION
    每个用例把"代理会写出的原始脚本"（UTF-8 无 BOM、含中文）交给 Invoke-SafeScript 执行，
    再断言 stdout 逐字相等、退出码、参数往返、超时标记。
    缺少的解释器记为 SKIP，不算失败；但"缺解释器"必须报出明确错误码。

.EXAMPLE
    .\Test-SafeScript.ps1
#>
[CmdletBinding()]
param(
    [string]$RunnerPath,
    [string]$WorkRoot
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot 在 param 默认值阶段可能尚未赋值，改在函数体内解析
if (-not $RunnerPath) {
    $RunnerPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Invoke-SafeScript.ps1'
}
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

function Write-Utf8 {
    param([string]$Path, [string]$Text, [switch]$Bom, [switch]$Gbk)
    if ($Gbk) {
        [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::GetEncoding(936).GetBytes($Text))
        return
    }
    $enc = New-Object System.Text.UTF8Encoding([bool]$Bom)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Invoke-Runner {
    param([hashtable]$Spec)
    # 进程内调用：参数走 PowerShell 原生绑定，避免命令行再套一层引号转义
    $splat = @{ OutDir = $Spec.OutDir }
    foreach ($k in @('File', 'Lang', 'ParamsFile', 'ParamsJson', 'ArgumentsJson', 'Interpreter')) {
        if ($Spec.ContainsKey($k) -and $null -ne $Spec[$k] -and "$($Spec[$k])" -ne '') { $splat[$k] = $Spec[$k] }
    }
    if ($Spec.ContainsKey('TimeoutSeconds') -and $Spec['TimeoutSeconds']) { $splat['TimeoutSeconds'] = [int]$Spec['TimeoutSeconds'] }
    if ($Spec.Check) { $splat['Check'] = $true }
    if ($Spec.Arguments) { $splat['Arguments'] = [string[]]$Spec['Arguments'] }

    $out = & $RunnerPath @splat 2>&1
    $code = $LASTEXITCODE
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $Spec.OutDir 'runner.stdout.txt'), $text, (New-Object System.Text.UTF8Encoding($false)))
    return $code
}

function Get-Result {
    param([string]$RunDir)
    $hit = Get-ChildItem -LiteralPath $RunDir -Recurse -Filter 'result.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $hit) { return $null }
    return [pscustomobject]@{
        Raw  = [System.IO.File]::ReadAllText($hit.FullName, [System.Text.Encoding]::UTF8)
        Json = ([System.IO.File]::ReadAllText($hit.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
}

function Get-RunnerStdout {
    param([string]$RunDir)
    $p = Join-Path $RunDir 'runner.stdout.txt'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
}

if (-not (Test-Path -LiteralPath $RunnerPath)) {
    Write-Host ("执行器不存在: " + $RunnerPath) -ForegroundColor Red
    exit 2
}

$root = $WorkRoot
if (-not $root) { $root = Join-Path ([System.IO.Path]::GetTempPath()) ('wss-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
New-Item -ItemType Directory -Force -Path $root | Out-Null
$srcDir = Join-Path $root 'src'
New-Item -ItemType Directory -Force -Path $srcDir | Out-Null

$rows = New-Object System.Collections.ArrayList
function Add-Row {
    param([string]$Case, [string]$Status, [string]$Detail)
    $null = $rows.Add([pscustomobject]@{ case = $Case; status = $Status; detail = $Detail })
}

function Assert-Case {
    param([string]$Case, [string]$RunDir, [int]$ExpectedExit, [string[]]$MustContain, [scriptblock]$Extra)
    $res = Get-Result -RunDir $RunDir
    if (-not $res) {
        Add-Row $Case 'FAIL' ('没有 result.json: ' + (Get-RunnerStdout -RunDir $RunDir))
        return
    }
    $j = $res.Json
    $problems = @()
    if ($j.exitCode -ne $ExpectedExit) { $problems += ('exitCode=' + $j.exitCode + ' expect=' + $ExpectedExit) }
    foreach ($needle in $MustContain) {
        if (-not ($j.stdout -and $j.stdout.Contains($needle))) { $problems += ('stdout 缺: ' + $needle) }
    }
    if ($Extra) {
        $extraProblems = & $Extra $j
        if ($extraProblems) { $problems += $extraProblems }
    }
    if ($problems.Count -eq 0) { Add-Row $Case 'PASS' ('exit=' + $j.exitCode + ' ' + $j.durationMs + 'ms') }
    else { Add-Row $Case 'FAIL' ($problems -join '; ') }
}

function New-RunDir {
    param([string]$Name)
    $d = Join-Path $root $Name
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# ---------------------------------------------------------------- 能力探测
$capDir = New-RunDir 'check'
$null = Invoke-Runner @{ OutDir = $capDir; Check = $true }
$capRaw = Get-RunnerStdout -RunDir $capDir
$cap = $capRaw | ConvertFrom-Json
$hasPy = [bool]$cap.interpreters.python.available
$hasNode = [bool]$cap.interpreters.node.available
if ($cap.ok) {
    Add-Row 'env/probe' 'PASS' ('ps=' + $cap.host.psVersion + ' py=' + $hasPy + ' node=' + $hasNode + ' activeCp=' + $cap.host.activeCp)
}
else { Add-Row 'env/probe' 'FAIL' $capRaw }

# 0) 子进程形态冒烟：代理通过 CLI 调执行器时退出码必须透传
$smokeDir = New-RunDir 'smoke'
$smokeSrc = Join-Path $srcDir 'smoke.ps1'
Write-Utf8 -Path $smokeSrc -Text "Write-Output '子进程形态 中文'; exit 5"
$q = { param($s) '"' + $s + '"' }
$sp = Start-Process powershell.exe -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (& $q $RunnerPath),
    '-File', (& $q $smokeSrc), '-OutDir', (& $q $smokeDir)
) -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput (Join-Path $smokeDir 'runner.stdout.txt') `
    -RedirectStandardError (Join-Path $smokeDir 'runner.stderr.txt')
$smokeRes = Get-Result -RunDir $smokeDir
if ($sp.ExitCode -eq 5 -and $smokeRes -and $smokeRes.Json.exitCode -eq 5 -and $smokeRes.Json.stdout -match '子进程形态') {
    Add-Row 'cli/child-process' 'PASS' 'exit=5 透传，中文正常'
}
else {
    $d = 'exit=' + $sp.ExitCode
    if ($smokeRes) { $d += ' json.exitCode=' + $smokeRes.Json.exitCode }
    Add-Row 'cli/child-process' 'FAIL' $d
}

# ---------------------------------------------------------------- 公共参数（中文 + 空格 + & + 反斜杠）
$cnName = '张三·测试'
$cnPath = 'C:\Program Files\测试 目录\a&b'
$paramsFile = Join-Path $srcDir 'params.json'
$paramsJson = '{"name":"' + $cnName + '","path":"' + ($cnPath -replace '\\', '\\') + '"}'
Write-Utf8 -Path $paramsFile -Text $paramsJson

# 1) ps1 编码 + $ + 引号 + argv（源文件故意不带 BOM）
$ps1Path = Join-Path $srcDir 'job.ps1'
Write-Utf8 -Path $ps1Path -Text @'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Stop'
$p = @{}
if ($env:SCRIPT_PARAMS_FILE) {
    $p = Get-Content -LiteralPath $env:SCRIPT_PARAMS_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
}
Write-Output ('name:' + $p.name)
Write-Output ('path:' + $p.path)
Write-Output 'emoji:😀'
Write-Output 'dollar:$var and $env:PATH'
Write-Output 'quoted:"a b"'
Write-Output ('argv:' + ($args -join '|'))
exit 0
'@
$run1 = New-RunDir 'r1'
$null = Invoke-Runner @{ File = $ps1Path; ParamsFile = $paramsFile; OutDir = $run1; Arguments = @('甲', '乙'); TimeoutSeconds = '60' }
Assert-Case -Case 'ps1/utf8-no-bom' -RunDir $run1 -ExpectedExit 0 -MustContain @(
    ('name:' + $cnName), ('path:' + $cnPath), 'emoji:😀', 'dollar:$var', 'quoted:"a b"', 'argv:甲|乙'
) -Extra {
    param($j)
    if ($j.script.executedEncoding -ne 'utf-8-bom') { return ('executedEncoding=' + $j.script.executedEncoding) }
    if ($j.script.sourceHadBom) { return 'sourceHadBom 应为 false' }
    if ($j.encoding.stdout -ne 'utf-8') { return ('stdoutEncoding=' + $j.encoding.stdout) }
    return $null
}

# 2) 退出码透传 + stderr 中文
$exitPath = Join-Path $srcDir 'exit.ps1'
Write-Utf8 -Path $exitPath -Text @'
Write-Output '中文退出测试'
[Console]::Error.WriteLine('错误信息：失败原因')
exit 42
'@
$run2 = New-RunDir 'r2'
$null = Invoke-Runner @{ File = $exitPath; OutDir = $run2 }
Assert-Case -Case 'ps1/exit-42' -RunDir $run2 -ExpectedExit 42 -MustContain @('中文退出测试') -Extra {
    param($j)
    if ($j.ok) { return 'ok 应为 false' }
    if (-not ($j.stderr -and $j.stderr.Contains('错误信息'))) { return 'stderr 丢失中文' }
    if ($j.encoding.stderr -ne 'utf-8') { return ('stderrEncoding=' + $j.encoding.stderr) }
    return $null
}

# 3) 源文件是 GBK 也能救回来
$gbkPath = Join-Path $srcDir 'gbk.ps1'
Write-Utf8 -Path $gbkPath -Text "Write-Output '这是GBK源码里的中文'" -Gbk
$run3 = New-RunDir 'r3'
$null = Invoke-Runner @{ File = $gbkPath; OutDir = $run3 }
Assert-Case -Case 'ps1/gbk-source' -RunDir $run3 -ExpectedExit 0 -MustContain @('这是GBK源码里的中文') -Extra {
    param($j)
    if ($j.script.sourceEncoding -ne 'gbk') { return ('sourceEncoding=' + $j.script.sourceEncoding) }
    return $null
}

# 4) bat：chcp + 参数内联 + 退出码（参数含空格与 &，必须用 "%P_x%" 展开）
$batPath = Join-Path $srcDir 'job.bat'
Write-Utf8 -Path $batPath -Text @'
echo 中文输出 bat
echo name:"%P_name%"
echo path:"%P_path%"
exit /b 3
'@
$run4 = New-RunDir 'r4'
$null = Invoke-Runner @{ File = $batPath; ParamsFile = $paramsFile; OutDir = $run4 }
Assert-Case -Case 'bat/chcp+params' -RunDir $run4 -ExpectedExit 3 -MustContain @('中文输出 bat', ('name:"' + $cnName + '"'), ('path:"' + $cnPath + '"')) -Extra {
    param($j)
    if ($j.params.vars -ne 2) { return ('注入变量数=' + $j.params.vars) }
    return $null
}

# 5) js：ESM + 参数 + JSON
$jsPath = Join-Path $srcDir 'job.js'
Write-Utf8 -Path $jsPath -Text @'
import fs from 'node:fs';
const p = JSON.parse(fs.readFileSync(process.env.SCRIPT_PARAMS_FILE, 'utf8'));
console.log('name:' + p.name);
console.log('path:' + p.path);
console.log('emoji:😀');
console.log('json:' + JSON.stringify({ k: '中文' }));
'@
$run5 = New-RunDir 'r5'
if ($hasNode) {
    $null = Invoke-Runner @{ File = $jsPath; ParamsFile = $paramsFile; OutDir = $run5 }
    Assert-Case -Case 'js/esm-params' -RunDir $run5 -ExpectedExit 0 -MustContain @(
        ('name:' + $cnName), ('path:' + $cnPath), 'emoji:😀', 'json:{"k":"中文"}'
    ) -Extra {
        param($j)
        if (-not ($j.notes -match 'mjs')) { return '应提示按 .mjs 执行' }
        return $null
    }
}
else { Add-Row 'js/esm-params' 'SKIP' 'node 不可用' }

# 6) py：可用则跑通，不可用必须明确报错（不能假成功）
$pyPath = Join-Path $srcDir 'job.py'
Write-Utf8 -Path $pyPath -Text @'
# -*- coding: utf-8 -*-
import json, os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
p = {}
if os.environ.get("SCRIPT_PARAMS_FILE"):
    with open(os.environ["SCRIPT_PARAMS_FILE"], encoding="utf-8") as f:
        p = json.load(f)
print("name:" + p.get("name", ""))
print("path:" + p.get("path", ""))
print("emoji:😀")
sys.exit(0)
'@
$run6 = New-RunDir 'r6'
$pyCode = Invoke-Runner @{ File = $pyPath; ParamsFile = $paramsFile; OutDir = $run6 }
if ($hasPy) {
    Assert-Case -Case 'py/utf8-params' -RunDir $run6 -ExpectedExit 0 -MustContain @(('name:' + $cnName), ('path:' + $cnPath), 'emoji:😀')
}
else {
    $raw6 = Get-RunnerStdout -RunDir $run6
    if ($pyCode -ne 0 -and $raw6 -match 'CAPABILITY_MISSING') {
        Add-Row 'py/missing-error' 'PASS' 'CAPABILITY_MISSING（exit 70）'
    }
    else { Add-Row 'py/missing-error' 'FAIL' ('exit=' + $pyCode + ' ' + $raw6) }
    Add-Row 'py/utf8-params' 'SKIP' 'python 不可用'
}

# 7) 超时强杀
$slowPath = Join-Path $srcDir 'slow.ps1'
Write-Utf8 -Path $slowPath -Text @'
Write-Output '开始等待'
Start-Sleep -Seconds 20
Write-Output '不该出现'
'@
$run7 = New-RunDir 'r7'
$null = Invoke-Runner @{ File = $slowPath; OutDir = $run7; TimeoutSeconds = '2' }
$res7 = Get-Result -RunDir $run7
if ($res7 -and $res7.Json.timedOut -and $res7.Json.durationMs -lt 15000 -and -not ($res7.Json.stdout -match '不该出现')) {
    Add-Row 'ps1/timeout-kill' 'PASS' ('timedOut=true, ' + $res7.Json.durationMs + 'ms')
}
else {
    $d = 'no result'
    if ($res7) { $d = ('timedOut=' + $res7.Json.timedOut + ' dur=' + $res7.Json.durationMs) }
    Add-Row 'ps1/timeout-kill' 'FAIL' $d
}

# 8) 大输出截断 + artifacts 完整
$bigPath = Join-Path $srcDir 'big.ps1'
Write-Utf8 -Path $bigPath -Text @'
$i = 0
while ($i -lt 3000) { Write-Output ('行' + $i + ' 中文内容'); $i++ }
'@
$run8 = New-RunDir 'r8'
$null = Invoke-Runner @{ File = $bigPath; OutDir = $run8 }
$res8 = Get-Result -RunDir $run8
if ($res8 -and $res8.Json.truncated.stdout -and $res8.Json.stdout.Length -le 8100) {
    $lines = @(Get-Content -LiteralPath $res8.Json.artifacts.stdoutFile -Encoding UTF8).Count
    if ($lines -eq 3000) { Add-Row 'ps1/truncate' 'PASS' ('3000 行，返回截断，artifact 完整（' + $lines + ' 行）') }
    else { Add-Row 'ps1/truncate' 'FAIL' ('artifact 行数=' + $lines) }
}
else { Add-Row 'ps1/truncate' 'FAIL' '未截断或 stdout 未限长' }

# 9) 负例
$run9 = New-RunDir 'r9'
$null = Invoke-Runner @{ File = (Join-Path $srcDir 'nope.ps1'); OutDir = $run9 }
if ((Get-RunnerStdout -RunDir $run9) -match 'FILE_NOT_FOUND') { Add-Row 'error/file-not-found' 'PASS' 'FILE_NOT_FOUND' }
else { Add-Row 'error/file-not-found' 'FAIL' (Get-RunnerStdout -RunDir $run9) }

$run10 = New-RunDir 'r10'
$null = Invoke-Runner @{ File = $ps1Path; ParamsJson = '{bad_json'; OutDir = $run10 }
if ((Get-RunnerStdout -RunDir $run10) -match 'PARAMS_INVALID') { Add-Row 'error/bad-json' 'PASS' 'PARAMS_INVALID' }
else { Add-Row 'error/bad-json' 'FAIL' (Get-RunnerStdout -RunDir $run10) }

# ---------------------------------------------------------------- 汇总
$pass = @($rows | Where-Object { $_.status -eq 'PASS' }).Count
$fail = @($rows | Where-Object { $_.status -eq 'FAIL' }).Count
$skip = @($rows | Where-Object { $_.status -eq 'SKIP' }).Count

Write-Host ''
Write-Host ('{0,-24} {1,-6} {2}' -f 'CASE', 'RESULT', 'DETAIL') -ForegroundColor Cyan
Write-Host ('-' * 78) -ForegroundColor DarkGray
foreach ($r in $rows) {
    $color = 'Green'
    if ($r.status -eq 'FAIL') { $color = 'Red' }
    elseif ($r.status -eq 'SKIP') { $color = 'Yellow' }
    Write-Host ('{0,-24} {1,-6} {2}' -f $r.case, $r.status, $r.detail) -ForegroundColor $color
}
Write-Host ('-' * 78) -ForegroundColor DarkGray
$summaryColor = 'Green'
if ($fail -gt 0) { $summaryColor = 'Red' }
Write-Host ("PASS=$pass FAIL=$fail SKIP=$skip   artifacts=" + $root) -ForegroundColor $summaryColor

$report = [ordered]@{
    schemaVersion = 1
    ok            = ($fail -eq 0)
    pass          = $pass
    fail          = $fail
    skip          = $skip
    capabilities  = $cap
    cases         = @($rows)
    artifacts     = $root
}
$reportPath = Join-Path $root 'test-report.json'
Write-Utf8 -Path $reportPath -Text ($report | ConvertTo-Json -Depth 8)
Write-Host ('report: ' + $reportPath) -ForegroundColor DarkGray

if ($fail -gt 0) { exit 1 }
exit 0
