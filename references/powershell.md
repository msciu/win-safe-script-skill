# PowerShell（Windows PowerShell 5.1 / pwsh 7）

## 为什么内联必坏

`powershell -Command "..."` 要穿过 4 层解析：调用方 shell → Win32 命令行 → PowerShell 词法 → 字符串插值。反引号、`$`、`"`、`\`、换行都会被某层吃掉。**含中文/引号/多行的代码一律 `-File`。**

## 直接用执行器（推荐）

执行器会自动：写 UTF-8 **BOM** 的 `user.ps1` + 包装脚本、固定 `[Console]::OutputEncoding`、参数落 `params.json`、捕获 stdout/stderr。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Invoke-SafeScript.ps1" -File "<ws>\.tmp\job.ps1"
```

口袋版（自己写文件时必须照抄）：

```powershell
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)   # 输出→UTF-8
$OutputEncoding            = [Console]::OutputEncoding               # 管道给原生程序
$ErrorActionPreference    = 'Stop'                                    # 原生 stderr 变异常
```

## 参数传递

```powershell
# 脚本内
$p = @{}
if ($env:SCRIPT_PARAMS_FILE) {
  $p = Get-Content -LiteralPath $env:SCRIPT_PARAMS_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
}
$p.path        # 中文、空格、反斜杠原样，无需转义
```

执行器额外给 `SCRIPT_PARAMS_JSON`（原始 JSON 串）、`WSS_ARGS`（位置参数数组）。

## 高频坑

| 坑 | 现象 | 处理 |
|---|---|---|
| 文件无 BOM 且含中文 | 脚本里中文变 `涓枃`，但输出仍是合法 UTF-8 | 写文件时加 BOM：`[IO.File]::WriteAllText($p,$s,[Text.UTF8Encoding]::new($true))` |
| 用 `-Command` 传多行 | `ParserError: 缺少语句块` | 改 `-File` |
| 原生程序写 stderr | `NativeCommandError`，$? 变 False | `$ErrorActionPreference='Stop'` 或 `2>&1` 显式合并，再判 `$LASTEXITCODE` |
| `$LASTEXITCODE` 残留 | 上一条命令的码被当成这次的 | 调用前 `$global:LASTEXITCODE=0` |
| `Write-Host` | 重定向时看不到 / 进了 Information 流 | 机器可读输出用 `Write-Output`，诊断用 `Write-Host` |
| `ConvertTo-Json` 默认深度 2 | 嵌套字段被截成字符串 | `-Depth 10 -Compress` |
| `ConvertFrom-Json` 空串 | 报错 | 先判 `if ($raw.Trim())` |
| `Out-File`/`Set-Content` 默认编码 | 5.1 写 UTF-16LE，别的程序读成乱码/BOM 垃圾 | 显式 `-Encoding utf8`（5.1 的 utf8 = 带 BOM） |
| `Get-Content` 读 UTF-8 无 BOM | 5.1 按 ANSI(936) 读，中文乱码 | `-Encoding UTF8` 显式指定 |
| 中文路径 | `Test-Path`/`Get-Item` 通配符误伤 | `-LiteralPath`，变量加引号 |
| `param()` 有 Mandatory | 无参执行时挂起等输入 → 超时 | 参数走 JSON，`param()` 只留可选 |
| 管道给原生程序 | 中文进入 `cmd.exe` 变乱码 | `$OutputEncoding` + `[Console]::OutputEncoding` 都设 UTF-8，或干脆走文件 |
| `exit` 与 `return` | `return` 只退一层，码丢失 | 需要码用 `exit N`；执行器已代理 `$LASTEXITCODE` |

## 最小可用骨架

```powershell
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Stop'
$p = @{}
if ($env:SCRIPT_PARAMS_FILE) {
  $p = Get-Content -LiteralPath $env:SCRIPT_PARAMS_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
}
Write-Output ("hello " + $p.name)
exit 0
```

## 判断成功

只看 `$LASTEXITCODE` 和 `Invoke-SafeScript` 返回的 `ok`；`Write-Error` 不会改退出码。
