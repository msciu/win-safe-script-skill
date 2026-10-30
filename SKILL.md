---
name: win-safe-script
description: 在 Windows 上跑脚本、执行脚本、写脚本、调试脚本、批量处理文件（转码、重命名、汇总行数）用本技能：PowerShell(.ps1)、Python(.py)、Batch/CMD(.bat)、Node.js(.js)，含中文/emoji/空格/反斜杠路径；也用于把 bash 脚本移植到 Windows 上跑、确认 python/node/pwsh/py 是否可用（含 conda、WindowsApps 占位符）。英文触发：run/execute/debug a Windows script; inline -Command / python -c / node -e breaks. 症状：中文乱码、GBK/UTF-8 BOM/代码页 936 或 65001、ParserError、NativeCommandError、UnicodeEncodeError、UnicodeDecodeError、引号或反斜杠被吞、$ 被提前展开、bat echo 中文乱码、脚本没输出、stdout 与 stderr 混在一起、退出码丢失或非 0、脚本超时被杀、输出被截断。
---

# win-safe-script

Windows 上执行脚本只有一条路：**写文件 → 用执行器跑 → 读 JSON**。

## 铁律

1. 不用 `-Command` / `-c` / `cmd /c "..."` 执行多行或含中文的代码，先落盘再执行。
2. 参数不进命令行：用 `-ParamsJson` / `-ParamsFile`，脚本读 `$env:SCRIPT_PARAMS_FILE`。
3. 编码交给执行器：ps1→UTF-8 **BOM**，bat→UTF-8 **无 BOM** + `chcp 65001`，py/js→UTF-8。
4. 判断成功看 `ok`（= 退出码 0 且未超时），不要靠"没报错"。
5. 先 `-Check` 探环境（本机可能没有 python），再跑。
6. 输出长只看 `artifacts.stdoutFile`，别把几 MB 日志塞回上下文。

## 三步动作

```powershell
# 1) 用 write 工具把脚本正文原样写到工作区（不转义、不缩进）
#    <ws>\.tmp\job.ps1
# 2) 执行（含空格的中文参数用 -ParamsFile，避免命令行再套一层引号）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Invoke-SafeScript.ps1" `
  -File "<ws>\.tmp\job.ps1" -ParamsJson '{"path":"C:\\Program Files\\测试目录"}'
# 3) 读 stdout 的单行 JSON：ok / exitCode / stdout / stderr / artifacts
```

## 执行器参数

| 参数 | 说明 |
|---|---|
| `-File` | 源脚本；`-Lang ps1\|py\|bat\|js` 可省略，默认按扩展名 |
| `-ParamsJson` / `-ParamsFile` | 参数 JSON，落成 `params.json`，路径经 `SCRIPT_PARAMS_FILE` 传入 |
| `-Arguments` / `-ArgumentsJson` | 位置参数（进程内用数组；跨进程用 JSON 串，避免引号被吃） |
| `-TimeoutSeconds` | 默认 120，超时强杀进程树并置 `timedOut: true` |
| `-WorkingDirectory` | 默认源脚本所在目录 |
| `-Interpreter` | 指定解释器（真实 python.exe、pwsh.exe 等） |
| `-MaxOutputChars` | 返回值上限，默认 8000；完整输出始终在 artifacts |
| `-Cleanup` | 成功后删临时目录 |
| `-Check` | 只探测环境：PS/pwsh/python/node/cmd、控制台代码页、建议 |

## 各语言取参数

```powershell
# ps1
$p = Get-Content -LiteralPath $env:SCRIPT_PARAMS_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
```
```python
# py
p = json.load(open(os.environ["SCRIPT_PARAMS_FILE"], encoding="utf-8"))
```
```js
// js
const p = JSON.parse(fs.readFileSync(process.env.SCRIPT_PARAMS_FILE, 'utf8'));
```
```bat
:: bat —— 执行器把键内联成 set "P_键=值"，展开必须带引号
echo "%P_name%"
```

## 按症状选模板

| 症状 / 场景 | 读这个 |
|---|---|
| 中文乱码、ParserError、`$` 被展开、内联 JS 被破坏 | `references/powershell.md` |
| `python -c` 失败、UnicodeEncodeError、csv 中文乱码、找不到/选错 python（conda） | `references/python.md` |
| bat 的 echo 中文乱码、参数丢失、exit code 不对 | `references/batch.md` |
| `node -e` 失败、JSON 中文、argv 乱码、ESM 报错 | `references/node.md` |
| 其他怪症状：没输出、被截断、超时、乱码方向判断 | `references/symptoms.md` |

## 边界

- `param()` 写 Mandatory 会让脚本挂起等输入（超时），参数一律从 JSON 读。
- 需要交互确认、GUI、长驻服务的脚本不走这里。
- 探测不到可用解释器时返回 `CAPABILITY_MISSING`，不要伪造成功；把 `-Check` 的结论告诉用户。
- 用 conda 时 `-Check` 会列出实际的 `path`/`version`/`source`；要锁某个环境就 `-Interpreter "<env>\python.exe"`。
- 自检：`scripts\Test-SafeScript.ps1`（4 语言 × 中文/emoji/引号/JSON 往返 + 超时/截断/退出码）。
