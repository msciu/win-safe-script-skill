# Changelog

## 1.1.2

- 修复 `Install-SafeScript.ps1` 丢失 UTF-8 BOM（编辑时被剥掉，PS 5.1 按 GBK 解析中文 → `ParserError`，CI 安装冒烟失败）。
- 守卫自身修 bug：CI checkout 为 CRLF，`name:` 行尾带 `\r`、`description` 多算 1 字导致误报；改为按 `\r?\n` 切分并 `Trim()`，新增 `.gitattributes` 统一行尾。
- 自测 14 项全通过（本地 + CI 双环境）。

## 1.1.1

- 仓库更名为 `win-safe-script-skill`（`-skill` 后缀标示这是 skill 仓库）；技能名仍是 `win-safe-script`，Agent 调用与安装目录不变。
- 同步更新 README 徽章/克隆地址、`Install-SafeScript.ps1 -Repo` 默认值、手动安装路径。
- 自测新增两道仓库守卫：`repo/ps1-bom`（脚本丢 BOM 直接 FAIL）、`repo/skill-frontmatter`（front matter 可解析）。本轮改名时 `Install-SafeScript.ps1` 的 BOM 被编辑器剥掉，CI 立刻抓到——于是把这类检查固化进自测。

## 1.1.0

- 新增 `scripts/Install-SafeScript.ps1`：一条命令安装/更新到 Skills 目录。幂等，支持 `-Dest`（换宿主）、`-DryRun`（只看不动）、`-SkipCheck`；不在 clone 里时自动浅克隆；装完用新副本跑 `-Check` 自证；拒绝源/目标互相包含。
- README 新增「装好后怎么让 Agent 真的用上」：项目指令块（AGENTS.md / CLAUDE.md）、点名用法、调用形态、失败处置表。
- CI 新增安装脚本冒烟（装到临时目录 → 校验文件 → 幂等重装）。

## 1.0.0

首个可发布版本。

- 入口 `SKILL.md`：6 条铁律、三步动作、执行器参数表、按症状路由到 5 份模板。
- `scripts/Invoke-SafeScript.ps1`：统一执行器
  - 禁止内联：源脚本落临时文件后以 `-File` 执行；
  - 编码矩阵：PS1=UTF-8 BOM（套包装脚本固定 `[Console]::OutputEncoding`，不改原脚本）、BAT=UTF-8 无 BOM + `chcp 65001` + CRLF、PY/JS=UTF-8；
  - 源文件编码容错：剥 BOM，UTF-8 严格解码失败回退 GBK 并标记；
  - 参数：`params.json` 经 `SCRIPT_PARAMS_FILE`；bat 额外内联 `set "P_键=值"`；
  - 输出：按字节落盘后严格 UTF-8 解码，非法字节回退 GBK 并标记 `encoding`；
  - 解释器探测：`-Interpreter` → `WSS_PYTHON` → conda 变量 → 进程 PATH → **注册表 PATH（含 condabin 上级）** → 常见目录 → 盘符浅扫 → `py` 启动器，逐个实跑 `-V` 验证，排除 WindowsApps 0 字节占位符；
  - 退出码透传、超时杀进程树、输出截断并保留 artifact。
- `scripts/Test-SafeScript.ps1`：13 项自测（4 语言 × 中文/emoji/引号/反斜杠/JSON 往返，加退出码、超时、截断、负例）。
- `references/`：PowerShell / Python / Batch / Node 各自的坑，以及乱码方向判定表。
- CI：GitHub Actions `windows-latest` 跑自测。

修复过的真实问题（均已固化为用例）：

- `Start-Process` 不带 `-Wait` 读不到 `ExitCode`，导致退出码丢失、解释器被误判不可用；
- `ConvertFrom-Json` 结果再套 `@()` 会多包一层，`$args` 变成 `System.Object[]`；
- cmd 里 `set "K=a&b"` 的 `^` 转义在 `call` 下二次解析不成立，改为内联 `set` 且展开必须带引号；
- `.bat` 写入 BOM 会触发 `'锘' 不是内部或外部命令`；
- conda 只在 PATH 注册 `condabin`，按 `python.exe` 扫 PATH 会漏掉解释器。
