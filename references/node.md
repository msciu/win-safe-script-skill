# Node.js（Windows）

Node 在 Windows 上默认 UTF-8，问题几乎都来自**内联 `node -e`** 和 **ESM/CJS 混用**。

## 内联为什么坏

`node -e "console.log('你好')"` 要过 cmd 的引号规则 + `%VAR%` 展开 + JS 词法；`$`、反引号、`"`、换行极易被破坏，Windows 上还会把 `\` 当转义。**一律写 `.mjs`/`.cjs` 文件。**

## 统一骨架（.mjs）

```js
import fs from 'node:fs';

const paramsPath = process.env.SCRIPT_PARAMS_FILE;
const params = paramsPath && fs.existsSync(paramsPath)
  ? JSON.parse(fs.readFileSync(paramsPath, 'utf8'))
  : {};

console.log(`你好 ${params.name ?? '世界'} 😀`);
process.exitCode = 0;
```

`.cjs` 用 `const fs = require('node:fs')`。执行器按扩展名决定，别把 ESM 代码写成 `.js`（取决于最近的 package.json `type`）。

## 高频坑

| 坑 | 现象 | 处理 |
|---|---|---|
| `node -e` 多行/中文 | `SyntaxError`、引号丢失 | 写文件 |
| `.js` 里用 `import` | `Cannot use import statement outside a module` | 改名 `.mjs` 或加 `"type":"module"` |
| 中文路径 | `ENOENT` | 路径加引号交给执行器；`path.join` 别手拼 `\` |
| 输出到重定向文件 | 一般正常；若被换成 cp936 控制台 | 执行器按 UTF-8 解码，异常时标 `encoding` |
| `console.log` 打对象 | 输出 `[object Object]` / 展开格式 | `JSON.stringify(x, null, 2)` 或 `console.log(JSON.stringify(x))` |
| `process.argv` | 中文参数被 cmd 中转坏 | 走 `SCRIPT_PARAMS_FILE`；必需位置参数由 `-Arguments` 传（不经 shell） |
| `process.exit()` 立即退出 | 异步写未 flush，末尾日志丢 | 用 `process.exitCode = N`，让事件循环自然结束 |
| 大日志 | 一次性 `console.log` 巨大字符串 | 分块 / 写文件，执行器会截断 stdout 并给 `artifacts.stdoutFile` |
| 子进程 | `exec` 拼串注入 | `spawn(exe, [args])`，`{ shell: false }` |

## 数据往返

要机器可读就别打印人读文本：

```js
console.log(JSON.stringify({ name: '张三', path: String.raw`C:\Program Files\测试` }));
```
