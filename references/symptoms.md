# 症状速查（乱码方向 / 静默失败 / 截断）

## 1. 先判方向：乱码是哪一侧坏的

| 你看到的 | 实际发生 | 修法 |
|---|---|---|
| `涓枃`、`娴嬭瘯`（每个汉字变 2-3 个怪字） | UTF-8 字节被按 GBK(936) 解码 | 读取端显式 UTF-8：`[IO.File]::ReadAllText($p,[Text.UTF8Encoding]::new($false))`；PS1 源文件加 BOM |
| `中文` 看着对，但文件里是 `锟斤拷` / `??` | 已不可逆（写的时候目标编码表示不了，如 cp936 写 emoji） | 只能重跑，写入端强制 UTF-8 |
| 开头多出 `ï»¿` | UTF-8 BOM 被当正文读 | 读取时去 BOM：`-replace "^\uFEFF", ""` |
| `'锘' 不是内部或外部命令` / `﻿@echo off` 报错 | .bat 被写入了 BOM | bat 必须 UTF-8 **无** BOM |
| `UnicodeEncodeError: 'gbk' codec ...` | Python 输出走 936 控制台 | `PYTHONIOENCODING=utf-8` / `sys.stdout.reconfigure` |
| `ParserError` / `缺少语句块` / `意外的令牌` | 内联被 shell 截断，或 `$`/反引号被提前展开 | 改 `-File`，参数走 JSON |

判断口诀：**能读出"像 UTF-8 的乱码"=读端错；出现 `?`/`锟斤拷`=写端已丢数据。**

## 2. 没有输出 / 输出不全

| 现象 | 原因 | 处理 |
|---|---|---|
| `stdout` 空、`exitCode` 0 | 用了 `Write-Host` 且被重定向；或脚本其实没走到打印 | 机器可读用 `Write-Output`；查 `artifacts.stderrFile` |
| 有 `stderr` 但你以为成功 | 只看了 `stdout` | 永远同时看 `ok` + `stderr` |
| 输出末尾被切 | 超出 `-MaxOutputChars`（默认 8000） | 调大或读 `artifacts.stdoutFile` |
| 日志突然中断 | 进程被 kill（超时）或 `exit` 早退 | 看 `timedOut`；脚本末尾 flush |
| 中文在 JSON 里变 `\u4e2d` | `ConvertTo-Json`/`json.dumps` 转义 | 正常，解析后即中文；人读用 `ensure_ascii=False` |

## 3. 退出码与超时

- `exit code 1` 且无 stderr：命令不存在或路径错（`9009`=找不到程序，`9009` 常见于 python 占位符）。
- `timedOut: true`：脚本在等输入（`param()` Mandatory、`Read-Host`、`pause`、交互式确认）→ 改参数化。
- PowerShell 脚本的 `$LASTEXITCODE` 不会自动变成进程退出码，执行器已代理；自己写 `-File` 时用 `exit $LASTEXITCODE`。
- `cmd /c` 下 `exit` 会连 cmd 一起退，子例程用 `exit /b`。

## 4. 控制台代码页泄漏

`chcp 65001` 改的是**共享控制台**。bat 跑完后如果不恢复，调用方后续原生程序输出可能变成 UTF-8 而调用方仍按 936 解码（或相反）。
执行器在 bat 执行后会尝试恢复原代码页；自己手跑 bat 时，结尾补 `chcp <原值> >nul`（原值用 `chcp` 查）。

## 5. 三条排障命令

```powershell
# 文件到底什么编码？（看前 4 字节）
Format-Hex -Path .\job.ps1 -Count 4

# 文件内容按 UTF-8 读是否合法？
try { [Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes('.\job.ps1')) | Out-Null; 'utf8-ok' }
catch { 'not-utf8: ' + $_.Exception.Message }

# 本机能力
& "<skill>\scripts\Invoke-SafeScript.ps1" -Check
```

## 6. 不要做的事

- 看到乱码就 `chcp 936` / 改区域设置"修好"——只是把问题换到另一侧。
- 用 `-replace` 修补乱码字符串——已丢字节，修不回来。
- 反复重试同一条内联命令——同输入同结果，换模板。
