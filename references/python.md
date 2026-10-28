# Python（Windows，UTF-8 模式）

## 先确认"哪个 python"能用

Windows 上最常见的三种"看起来有、其实不能用"：

1. `WindowsApps\python.exe` 是 **0 字节商店占位符**，执行返回 9009 或弹商店；
2. **conda**：PATH 里常常只有 `<root>\condabin`（不含 python.exe），真正的解释器在 `<root>\python.exe`；
3. 工具进程的 PATH 与交互式 shell 不同——注册表里还有一份 PATH。

执行器的查找顺序（每个候选都实测 `python.exe -V`，能打印 `Python 3.x` 才采用）：

```
-Interpreter → WSS_PYTHON → CONDA_PREFIX/CONDA_ROOT/CONDA_EXE
→ 当前进程 PATH → 注册表 PATH（含 condabin 的上一级）
→ 常见安装目录 → 盘符根下两层 *conda*/*python* 目录 → py 启动器
```

先跑 `Invoke-SafeScript.ps1 -Check` 看 `interpreters.python`（含 `path`/`version`/`source`）。
全都没找到时才报 `CAPABILITY_MISSING`——此时不要伪造成功，要么让用户装，要么 `-Interpreter` 指路径，要么改用 ps1/js。

conda 用户注意：

- 要用某个具体环境，直接给解释器绝对路径：`-Interpreter "<conda 根>\envs\<环境名>\python.exe"`（`-Check` 输出里的 `path` 就在根目录下，按同样结构拼）。先 `conda env list` 确认环境名，不要猜。
- 不要指望 `conda activate`：执行器不经过 shell 初始化，激活脚本不会被执行；要换环境就换 `-Interpreter`。
- 脚本里 `print(sys.executable)` 自证用的是哪个解释器，排查"装了这个包却 import 不到"时先看这行。

## 三条硬规则

```python
# 1) 文件头声明（放第一/二行）
# -*- coding: utf-8 -*-
# 2) 输出强制 UTF-8（即使被重定向、即使控制台是 936）
import sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")
# 3) 参数从 JSON 文件读，不用 %* / sys.argv 传中文
import json, os
p = {}
fp = os.environ.get("SCRIPT_PARAMS_FILE")
if fp and os.path.getsize(fp):
    with open(fp, encoding="utf-8") as f:
        p = json.load(f)
```

执行器已自动设 `PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`、`PYTHONLEGACYWINDOWSSTDIO=0`，但**别依赖**：自己显式写 `encoding=`。

## 高频坑

| 坑 | 现象 | 处理 |
|---|---|---|
| `python -c "..."` | `SyntaxError` / 引号被吃 / 中文乱码 | 写 `.py` 文件执行 |
| `open()` 不带 encoding | 中文路径所在机（cp936）读出乱码，或 `UnicodeDecodeError` | 一律 `encoding="utf-8"` |
| 写 CSV/Excel 给 Windows 用户 | Excel 打开中文乱码 | 写 CSV 用 `encoding="utf-8-sig"`；xlsx 用 openpyxl |
| `print` 到重定向文件 | `UnicodeEncodeError: 'gbk' codec can't encode` | 见上 reconfigure / `PYTHONIOENCODING` |
| `subprocess` 调 cmd/powershell | 中文参数变 `?`，或输出乱码 | `text=True, encoding="utf-8", errors="replace"`，命令传 list 不拼串 |
| 路径拼接字符串 | `C:\a\b` 里 `\n` `\t` 被当转义 | `pathlib.Path(r"C:\a\b")` 或原始字符串 |
| `sys.argv` 收中文 | 本机通常没问题，但被 cmd 中转会坏 | 走 `SCRIPT_PARAMS_FILE` |
| 多版本 | `python` 指向 3.13 而包装在 3.11 | `-Interpreter "C:\...\python.exe"`，脚本里 `print(sys.executable)` 自证 |
| 长任务 | 无输出直到结束（缓冲） | `flush=True` 或 `-u`；执行器超时默认 120s |

## 最小可用骨架

```python
# -*- coding: utf-8 -*-
import json, os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

params = {}
if os.environ.get("SCRIPT_PARAMS_FILE"):
    with open(os.environ["SCRIPT_PARAMS_FILE"], encoding="utf-8") as f:
        params = json.load(f)

print(f"你好 {params.get('name', '世界')} 😀")
sys.exit(0)
```

## 数据往返自查

脚本要产出结构化数据时，**用 JSON 输出而不是人读文本**，并显式 `ensure_ascii=False`：

```python
print(json.dumps({"name": "张三", "path": r"C:\Program Files\测试"}, ensure_ascii=False))
```
