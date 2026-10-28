# win-safe-script

[![selftest](https://github.com/msciu/win-safe-script/actions/workflows/selftest.yml/badge.svg)](https://github.com/msciu/win-safe-script/actions/workflows/selftest.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Windows 上让 Agent 执行脚本时**不出编码事故**的一套东西：一个入口 Skill + 四份按语言对症的模板 + 一个确定性执行器 + 一个自测矩阵。

起因：在 Windows 上让 Agent 跑 `powershell -Command "..."` 或 `python -c "..."`，多行代码、中文、`$`、引号、反斜杠几乎必坏，于是出现"PowerShell 又把内联 JS 搞坏了，改用脚本文件"这类反复试错。本套装把这条经验固化成**默认路径**。

适用于任何支持 Agent Skills 的宿主（Claude Code、DeepSeek Harness 等）：`SKILL.md` + `references/` + `scripts/` 的目录结构，描述驱动触发，正文与模板按需加载。

## 目录

```
win-safe-script/
├── SKILL.md                      # 入口：铁律 + 三步动作 + 症状路由（常驻上下文）
├── references/                   # 按需加载，不占常驻上下文
│   ├── powershell.md             # 内联为什么坏、BOM、参数、13 个高频坑
│   ├── python.md                 # UTF-8 模式、编码声明、conda/商店占位符、csv
│   ├── batch.md                  # chcp、BOM 禁忌、参数内联与引号规则
│   ├── node.md                   # ESM/CJS、argv、JSON 输出
│   └── symptoms.md               # 乱码方向判定表、静默失败、截断、代码页泄漏
├── scripts/
│   ├── Invoke-SafeScript.ps1     # 执行器：规范化编码 → 落临时文件 → 执行 → 单行 JSON
│   └── Test-SafeScript.ps1       # 自测：4 语言 × 中文/emoji/引号/JSON 往返 + 超时/截断/退出码
├── .github/workflows/selftest.yml # CI：windows-latest 上跑自测
├── CHANGELOG.md
└── LICENSE
```

## 为什么是"一个 Skill"而不是四个

Skill 的 `description` 常驻系统提示，每个独立 Skill 都要付一次上下文成本。四个语言各建一个 Skill，会让"选哪个"变成新的失败点（选错→照错模板做）。

因此入口只有一个，命中后再按 `references/` 分诊加载——**上下文按需付费，模板按症状取用**。这与"减少上下文注入"的目标一致。

## 安装

```powershell
git clone https://github.com/msciu/win-safe-script.git
$dest = Join-Path $env:USERPROFILE '.agents\skills\win-safe-script'
robocopy .\win-safe-script $dest /E /XD .git /NFL /NDL /NJH /NJS   # 排除 .git
# 新开一个会话后生效（Skill 目录在会话启动时扫描）
```

若用 Claude Code / 其他支持 Agent Skills 的宿主，把目录放到对应的 `skills/` 下即可，结构遵循 `SKILL.md + references/ + scripts/`。

## 验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win-safe-script\scripts\Test-SafeScript.ps1
```

参考环境（Windows PowerShell 5.1 / 控制台代码页 936 / Node 24 / conda Python 3.12.7）实测：

```
env/probe                PASS   ps=5.1.26100.9711 py=True node=True activeCp=936
cli/child-process        PASS   exit=5 透传，中文正常
ps1/utf8-no-bom          PASS   exit=0
ps1/exit-42              PASS   exit=42
ps1/gbk-source           PASS   exit=0
bat/chcp+params          PASS   exit=3
js/esm-params            PASS   exit=0
py/utf8-params           PASS   exit=0
ps1/timeout-kill         PASS   timedOut=true
ps1/truncate             PASS   3000 行，返回截断，artifact 完整
error/file-not-found     PASS   FILE_NOT_FOUND
error/bad-json           PASS   PARAMS_INVALID
PASS=12 FAIL=0 SKIP=0
```

用例覆盖的正是易坏点：源文件故意不写 BOM（执行器补齐）、源文件是 GBK（能救回并标记）、`$var`/`"a b"`/`C:\...\a&b`、位置参数、退出码透传、stderr 中文、超时强杀、大输出截断。缺少某语言解释器时该用例记 `SKIP`，并用"缺解释器必须明确报错"的用例兜底。

## 执行器做了什么

| 环节 | 处理 |
|---|---|
| 源文件读取 | 剥 BOM；UTF-8 严格解码，失败回退 GBK 并在 `script.sourceEncoding` 标记 |
| ps1 | 重写为 UTF-8 **BOM**；套一层包装脚本固定 `[Console]::OutputEncoding`，原脚本一个字不改（不破坏 `param()` 位置） |
| bat | 重写为 UTF-8 **无 BOM**、CRLF；注入 `@echo off` + `chcp 65001`；参数内联为 `set "P_键=值"` |
| py | UTF-8 无 BOM；`PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`；解释器实测探测（PATH / conda / 注册表 PATH / 常见目录 / 盘符浅扫），排除 WindowsApps 0 字节占位符 |
| js | UTF-8；`.js` 里有顶层 `import` 自动按 `.mjs` 跑并记 `notes` |
| 参数 | `params.json`（UTF-8），路径经 `SCRIPT_PARAMS_FILE`；bat 另内联 `P_*` 变量 |
| 输出 | 重定向到文件按字节落盘，再严格 UTF-8 解码，非法字节回退 GBK 并标记 `encoding` |
| 退出码 | 原样作为结果 `exitCode`，也是执行器自身退出码；超时置 `timedOut` 并杀进程树 |
| 副作用 | bat 的 `chcp` 会改共享控制台代码页，执行后恢复原值 |

结果是一条单行 JSON，同时写一份到 `artifacts.resultFile`，便于调用方丢了 stdout 也能回读。

## 已知限制

- `pwsh`（PowerShell 7）分支未单测：本参考环境只有 Windows PowerShell 5.1。用 `-Interpreter pwsh.exe` 可指定，但脚本兼容性需自行确认。
- 参数值含双引号或换行时不内联进 bat（只在 `params.json`），执行器会在 `notes` 里说明。
- 交互式脚本（`Read-Host`/`pause`/必填 `param()`）会走到超时，这是设计选择，不是缺陷。
- 需要 UAC 提权、GUI、长驻服务的脚本不适用。

## 贡献

改 `scripts/` 后请先跑 `Test-SafeScript.ps1`（13 项，缺解释器记 SKIP 但不得 FAIL）；CI 会在 `windows-latest` 上重跑。编码相关改动请在 PR 里附上 `-Check` 输出，便于确认验证环境。

## 许可证

[MIT](LICENSE)
