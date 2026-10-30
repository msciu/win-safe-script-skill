# win-safe-script

[![selftest](https://github.com/msciu/win-safe-script-skill/actions/workflows/selftest.yml/badge.svg)](https://github.com/msciu/win-safe-script-skill/actions/workflows/selftest.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Windows 上让 Agent 执行脚本时**不出编码事故**的一套东西：一个入口 Skill + 四份按语言对症的模板 + 一个确定性执行器 + 一个自测矩阵。

起因：在 Windows 上让 Agent 跑 `powershell -Command "..."` 或 `python -c "..."`，多行代码、中文、`$`、引号、反斜杠几乎必坏，于是出现"PowerShell 又把内联 JS 搞坏了，改用脚本文件"这类反复试错。本套装把这条经验固化成**默认路径**。

适用于任何支持 Agent Skills 的宿主（Claude Code、DeepSeek Harness 等）：`SKILL.md` + `references/` + `scripts/` 的目录结构，描述驱动触发，正文与模板按需加载。

> 命名：仓库名带 `-skill` 后缀表示这是一个 skill 仓库；**技能名仍是 `win-safe-script`**——Agent 调用、`SKILL.md` 的 `name` 字段、安装目录都用这个名字，只有仓库地址多了后缀。

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

### 一键装（推荐）

```powershell
git clone https://github.com/msciu/win-safe-script-skill.git
cd win-safe-script-skill
.\scripts\Install-SafeScript.ps1
```

脚本做四件事：定位源（不在 clone 里就自动从 GitHub 浅克隆）→ 复制 `SKILL.md`/`references/`/`scripts/` → 校验 front matter → 用装好的副本跑一次 `-Check` 自证。

```powershell
.\scripts\Install-SafeScript.ps1 -DryRun                      # 只看不动
.\scripts\Install-SafeScript.ps1 -Dest "D:\skills\win-safe-script"   # 换宿主目录
```

幂等，可当"更新"反复跑；目标目录会被整体替换。

### 手动装

```powershell
$dest = Join-Path $env:USERPROFILE '.agents\skills\win-safe-script'
robocopy .\win-safe-script-skill $dest /E /XD .git /NFL /NDL /NJH /NJS   # 排除 .git
# 新开一个会话后生效（Skill 目录在会话启动时扫描）
```

若用 Claude Code / 其他支持 Agent Skills 的宿主，把目录放到对应的 `skills/` 下即可，结构遵循 `SKILL.md + references/ + scripts/`。

## 验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-SafeScript.ps1
```

CI 在 `windows-latest` 上同时跑 **Windows PowerShell 5.1** 与 **PowerShell 7** 两档，均为阻断式（徽章见仓库首页）。

参考环境（Windows PowerShell 5.1 / 控制台代码页 936 / Node 24 / conda Python 3.12.7）实测：

```
env/probe                PASS   ps=5.1.26100.9711 py=True node=True activeCp=936
repo/ps1-bom             PASS   3 个 .ps1 均为 UTF-8 BOM
repo/skill-frontmatter   PASS   name=win-safe-script, description=485 字
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
PASS=14 FAIL=0 SKIP=0
```

用例覆盖的正是易坏点：源文件故意不写 BOM（执行器补齐）、源文件是 GBK（能救回并标记）、`$var`/`"a b"`/`C:\...\a&b`、位置参数、退出码透传、stderr 中文、超时强杀、大输出截断。缺少某语言解释器时该用例记 `SKIP`，并用"缺解释器必须明确报错"的用例兜底。

最后两项 `repo/*` 是**对仓库自身的守卫**：`.ps1` 丢了 UTF-8 BOM、或 `SKILL.md` 的 front matter 坏掉，自测直接 FAIL。这条是踩出来的——改仓库名时 `Install-SafeScript.ps1` 的 BOM 被编辑操作剥掉，CI 的安装冒烟立刻报 `ParserError`。

## 装好后怎么让 Agent 真的用上

触发靠 `description` 的语义匹配，不是硬规则。三种加码方式，按可靠性排序：

### 1. 项目指令里定规（最推荐）

在当前项目的 `AGENTS.md`（或 `CLAUDE.md`、`.cursor/rules`）里加一段：

```md
## Windows 脚本执行

- 在 Windows 上执行 PowerShell / Python / Batch / Node 脚本，一律先加载 `win-safe-script` 技能。
- 禁止 `powershell -Command`、`python -c`、`node -e` 执行多行或含中文的代码；
  先写文件，再用 `scripts/Invoke-SafeScript.ps1 -File` 跑。
- 参数放 JSON（`-ParamsJson` / `-ParamsFile`），不拼命令行。
- 判成功看返回 JSON 的 `ok` 与 `exitCode`，不要只看"有没有报错"。
- 环境不确定先跑 `Invoke-SafeScript.ps1 -Check`；缺解释器报 `CAPABILITY_MISSING` 时不要改脚本硬重试。
```

### 2. 一句话点名

> 用 win-safe-script 跑这个脚本

绕过语义匹配直接命中，适合偶发场景。

### 3. 观察调用形态

```
user  → 把 D:\data 下的 csv 全转成 UTF-8，并汇总行数
agent → 1) write 工具写 .tmp\convert.ps1
        2) Invoke-SafeScript.ps1 -File .tmp\convert.ps1 -ParamsFile .tmp\params.json
        3) 读单行 JSON：ok=true exitCode=0 stdout="…"（长输出看 artifacts.stdoutFile）
```

### 失败时的固定处置

| 返回 | 处置 |
|---|---|
| `CAPABILITY_MISSING` | 先 `-Check`，告诉用户缺什么或用 `-Interpreter` 指路径；不要改脚本硬重试 |
| `timedOut: true` | 脚本在等输入（`Read-Host` / `pause` / 必填 `param()`），改成 JSON 参数 |
| 乱码 | 读 `references/symptoms.md` 判方向（读端错，还是写端已经丢数据），不要靠 `chcp` 硬修 |
| `exitCode` 非 0 且 stderr 为空 | 命令或路径不存在（`9009` 常见于商店版 python 占位符） |

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

- 参数值含双引号或换行时不内联进 bat（只在 `params.json`），执行器会在 `notes` 里说明。
- 交互式脚本（`Read-Host`/`pause`/必填 `param()`）会走到超时，这是设计选择，不是缺陷。
- 需要 UAC 提权、GUI、长驻服务的脚本不适用。

## 贡献

改 `scripts/` 后请先跑 `Test-SafeScript.ps1`（14 项，含两道仓库守卫；缺解释器记 SKIP 但不得 FAIL）；CI 会在 `windows-latest` 上重跑。编码相关改动请在 PR 里附上 `-Check` 输出，便于确认验证环境。

## 许可证

[MIT](LICENSE)
