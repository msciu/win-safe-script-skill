# Batch / CMD（chcp 65001）

## 编码契约：UTF-8 **无 BOM** + 首行 `chcp 65001`

- 有 BOM：cmd 把 BOM 当命令，报 `'锘' 不是内部或外部命令` 或 `﻿@echo` 失败。
- 无 BOM 且不 `chcp 65001`：中文按 936 解析，echo 出来是 `涓枃` / `????`。
- 文件换行用 **CRLF**（LF 在 `goto`/`for` 场景下会出怪问题）。

执行器**自动注入**这两行并转 CRLF，所以脚本正文不用自己写：

```bat
@echo off
chcp 65001 >nul
```

`chcp` 改的是**共享控制台**的代码页，执行器跑完 bat 会尽力恢复原代码页（见 symptoms.md）。

## 参数传递

执行器把 JSON 的每个键内联成 `set "P_键=值"`，插在 `chcp` 之后、脚本正文之前（单次解析，不走 `call`，避免二次转义）：

```bat
@echo off
chcp 65001 >nul
echo 名字:"%P_name%"
```

规则：

- **展开时必须带引号** `"%P_x%"`：值里的 `&` `|` `<` `>` 在引号内是字面量，不带引号会被当成命令分隔符。
- `%` 在写入时已转义成 `%%`，脚本里照常用 `%P_x%`。
- 值含双引号或换行时不内联（只留在 params.json 里），执行器在 `notes` 里说明，此时改读 `SCRIPT_PARAMS_FILE`。
- 键名映射：`[A-Za-z0-9_]` 之外的字符换成 `_` 并加前缀 `P_`（`user-name` → `P_user_name`）。
- 位置参数：`-Arguments` 传数组，脚本里用 `%1 %2`；值里别再自己加引号。
- 键名大小写：JSON 里写成小写，脚本里按 `P_` + 原样大小写取。

## 高频坑

| 坑 | 现象 | 处理 |
|---|---|---|
| `echo 中文` 在无 chcp 下 | 乱码 | 首行 `chcp 65001>nul`（执行器已做） |
| `setlocal enabledelayedexpansion` + 值含 `!` | `!` 被吃掉 | 不用延迟展开，或对值做转义 |
| `exit /b` vs `exit` | `exit` 关掉整个 cmd，码可能丢 | 子例程外 `exit /b N` |
| `for /f` 读 UTF-8 文件 | 中文乱码 | `chcp 65001` 后 `for /f "usebackq delims=" %%i in ("file.txt")`，或用 `type`+`findstr` |
| 路径含空格 | 被拆成两个参数 | 全程 `"%~1"` / `"%VAR%"` |
| 中文目录 + `cd` | 跨盘符 `cd` 不生效 | `cd /d "%~dp0"` |
| robocopy / xcopy 退出码 | 0-7 都算成功，`if errorlevel 1` 误判 | `robocopy ... & if %ERRORLEVEL% GEQ 8 exit /b %ERRORLEVEL%` |
| `%ERRORLEVEL%` 在块内 | 展开时机错，读到旧值 | 用 `if errorlevel N` 或延迟展开 |
| 混用 PS 语法 | `$var`、`-eq` 报错 | 这是 cmd，不是 PS |
| 中文注释 `::` + 括号块 | 块内 `::` 注释导致解析错 | 块内用 `rem` |

## 什么时候别用 bat

涉及 JSON、正则、Unicode 排序、并发、HTTP → 直接上 PowerShell 或 Node。bat 只做：文件搬运、服务启停、简单串行命令。

## 最小可用骨架

```bat
@echo off
chcp 65001 >nul
setlocal
echo 开始处理: "%P_target%"
dir /b "%P_target%"
if errorlevel 1 exit /b 2
echo 完成
exit /b 0
```
