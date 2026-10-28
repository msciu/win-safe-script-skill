#requires -Version 5.1
<#
.SYNOPSIS
    把 win-safe-script 安装/更新到 Agent Skills 目录，并自证可用。

.DESCRIPTION
    1) 找源：优先用当前 clone（本脚本所在仓库）；不在 clone 里时从 GitHub 浅克隆；
    2) 复制 SKILL.md / references / scripts / README / CHANGELOG / LICENSE；
    3) 校验 front matter（name、description）；
    4) 用安装后的副本跑一次 -Check，确认解释器与代码页可用。

    幂等：可反复执行，等于"更新"。默认会整体替换目标目录。

.PARAMETER Dest
    目标目录。默认 $env:USERPROFILE\.agents\skills\win-safe-script。
    其他宿主（如 Claude Code 的 ~/.claude/skills）请显式指定。

.PARAMETER Repo
    当前目录不是 clone 时使用的仓库地址。

.PARAMETER DryRun
    只打印将要做什么，不改动磁盘。

.PARAMETER SkipCheck
    安装后不跑 -Check。

.EXAMPLE
    .\scripts\Install-SafeScript.ps1

.EXAMPLE
    .\scripts\Install-SafeScript.ps1 -Dest "$env:APPDATA\Claude\skills\win-safe-script" -DryRun
#>
[CmdletBinding()]
param(
    [string]$Dest,
    [string]$Repo = 'https://github.com/msciu/win-safe-script-skill.git',
    [switch]$DryRun,
    [switch]$SkipCheck
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Text)
    Write-Host ('== ' + $Text) -ForegroundColor Cyan
}

if (-not $Dest) {
    $Dest = Join-Path (Join-Path $env:USERPROFILE '.agents\skills') 'win-safe-script'
}
$destFull = [System.IO.Path]::GetFullPath($Dest)

$srcFull = Split-Path -Parent $PSScriptRoot
$tempRoot = $null
$savedPrompt = $env:GIT_TERMINAL_PROMPT

try {
    if (-not (Test-Path -LiteralPath (Join-Path $srcFull 'SKILL.md'))) {
        Write-Step ('当前目录不是仓库 clone，改为从 GitHub 浅克隆：' + $Repo)
        if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
            throw '找不到 git.exe：请先 git clone 本仓库，再在仓库内运行本脚本。'
        }
        $env:GIT_TERMINAL_PROMPT = '0'
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wss-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $gitOut = git clone --depth 1 $Repo $tempRoot 2>&1
        if ($LASTEXITCODE -ne 0) { throw ('克隆失败：' + (($gitOut | Out-String).Trim())) }
        $srcFull = $tempRoot
    }

    # 源与目标不能互相包含，避免把源删掉
    $srcNorm = $srcFull.TrimEnd('\', '/')
    $destNorm = $destFull.TrimEnd('\', '/')
    if ($destNorm -eq $srcNorm -or $destNorm.StartsWith($srcNorm + '\') -or $srcNorm.StartsWith($destNorm + '\')) {
        throw ('目标与源互相包含，拒绝执行：dest=' + $destNorm + '  src=' + $srcNorm)
    }

    foreach ($need in @('SKILL.md', 'scripts\Invoke-SafeScript.ps1', 'scripts\Test-SafeScript.ps1', 'references')) {
        if (-not (Test-Path -LiteralPath (Join-Path $srcFull $need))) { throw ('源目录缺少：' + $need) }
    }

    $items = @('SKILL.md', 'README.md', 'CHANGELOG.md', 'LICENSE', 'references', 'scripts')
    $present = @($items | Where-Object { Test-Path -LiteralPath (Join-Path $srcFull $_) })

    $existing = 0
    if (Test-Path -LiteralPath $destFull) {
        $existing = @(Get-ChildItem -LiteralPath $destFull -Force -ErrorAction SilentlyContinue).Count
    }

    Write-Step ('源：' + $srcFull)
    Write-Step ('目标：' + $destFull)
    Write-Step ('复制：' + ($present -join ', '))
    if ($existing -gt 0) {
        Write-Host ('   目标已存在（' + $existing + ' 项），将被整体替换') -ForegroundColor Yellow
    }

    if ($DryRun) {
        Write-Host '   -DryRun：未改动磁盘' -ForegroundColor Yellow
        return
    }

    if (Test-Path -LiteralPath $destFull) { Remove-Item -LiteralPath $destFull -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $destFull | Out-Null
    foreach ($item in $present) {
        Copy-Item -LiteralPath (Join-Path $srcFull $item) -Destination $destFull -Recurse -Force
    }

    # 校验 front matter
    $skillPath = Join-Path $destFull 'SKILL.md'
    $text = [System.IO.File]::ReadAllText($skillPath, [System.Text.Encoding]::UTF8)
    $lines = $text -split "`n"
    if ($lines[0].Trim() -ne '---') { throw 'SKILL.md 缺少 front matter 起始行 ---' }
    $nameLine = @($lines | Where-Object { $_ -like 'name:*' })[0]
    $descLine = @($lines | Where-Object { $_ -like 'description:*' })[0]
    if (-not $nameLine -or $nameLine.Trim() -ne 'name: win-safe-script') { throw ('SKILL.md name 异常：' + $nameLine) }
    if (-not $descLine) { throw 'SKILL.md 缺少 description' }
    $descText = $descLine -replace '^description:\s*', ''
    if ($descText.Length -lt 20) { throw 'SKILL.md description 过短' }

    $copied = @(Get-ChildItem -LiteralPath $destFull -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '\\\.git\\' })
    Write-Host ('   已安装 ' + $copied.Count + ' 个文件；name=win-safe-script，description=' + $descText.Length + ' 字') -ForegroundColor Green

    if (-not $SkipCheck) {
        Write-Step '自检（安装后副本跑 -Check）'
        $checkJson = (& (Join-Path $destFull 'scripts\Invoke-SafeScript.ps1') -Check | Out-String).Trim()
        $j = $checkJson | ConvertFrom-Json
        Write-Host ('   ps=' + $j.host.psVersion +
            '  python=' + $j.interpreters.python.available +
            '  node=' + $j.interpreters.node.available +
            '  activeCp=' + $j.host.activeCp) -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '装好了，接下来：' -ForegroundColor Cyan
    Write-Host '  1) 新开一个会话——Skill 目录在会话启动时扫描，当前会话不会热更新'
    Write-Host '  2) 需要时点名：用 win-safe-script 跑这个脚本'
    Write-Host '  3) 更新：在仓库里 git pull，然后重跑本脚本'
}
finally {
    $env:GIT_TERMINAL_PROMPT = $savedPrompt
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
