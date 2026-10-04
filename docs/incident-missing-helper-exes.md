# 故障复盘 2：`codex-code-mode-host.exe` 找不到，工具全部无法运行

**症状**：Codex Desktop 重启后，发消息立即报错：

> 已批准继续，但当前被 **Codex 本地执行工具**阻塞：系统找不到
> `codex-code-mode-host.exe`，无法读取文件、修改代码或运行测试。

**结论**：**是我的安装脚本的缺陷**。它只把 `codex.exe` 复制到覆盖目录，
漏掉了 Desktop 必需的 3 个配套可执行文件。

---

## 1. 根因

Desktop 在 `app.asar` 里有一个**硬编码的配套文件清单**，它从 **`codex.exe` 所在目录**
解析这些文件：

```js
Lt = [
  'codex-code-mode-host.exe',
  'codex-windows-sandbox-setup.exe',
  'codex-command-runner.exe',
]
```

完整映射表：

```js
Rt = new Map([
  ['codex.exe',                      'codex'],
  ['codex-code-mode-host.exe',       'code-mode-host'],
  ['codex-windows-sandbox-setup.exe','sandbox-setup'],
  ['codex-command-runner.exe',       'command-runner'],
  ['rg.exe',                         'ripgrep'],
])
```

因为 `CODEX_CLI_PATH` 指向 `...\CodexLocalPatch\bin\0.160.0\codex.exe`，
Desktop 就去**那个目录**找这 3 个文件 —— 而安装脚本只放了 `codex.exe`，
所以找不到，工具链直接失效。

**`codex-code-mode-host.exe` 是代码模式（Code Mode）的宿主进程**，
读文件、改代码、跑测试都经它调度，所以它缺失等于所有本地执行工具瘫痪。

## 2. 为什么之前没暴露

这个缺陷从一开始就存在，但被两件事掩盖了：

1. 上一轮构建的二进制**读不了数据库**，app-server 启动即退出，Desktop 根本没走到
   工具调用阶段 —— 先撞上的是「无法加载组织设置」。
2. 我在排查上一轮事故时，**曾把官方 3 个 exe 误拷进补丁目录**，然后发现是假象就
   又**删掉了**。那次删除让我一度以为「补丁目录本来就只该有 `codex.exe`」，
   反而强化了错误认知。

修复数据库问题后，Desktop 能启动了，工具链缺失才暴露出来。

## 3. 修复

### 立即修复（已执行）

把官方目录的 3 个配套 exe 复制到补丁目录：

```
codex-code-mode-host.exe        74,697,520 bytes
codex-windows-sandbox-setup.exe 17,685,808 bytes
codex-command-runner.exe         8,207,152 bytes
```

验证：4 个文件齐全；补丁版实测能真实执行命令（`EXECUTED`）。

### 根本修复（已写入脚本）

`scripts/install-patched-codex.ps1` 现在会：

1. **自动复制** 3 个配套 exe 到覆盖目录（`Install-SiblingExes`）。
2. **安装后校验**，缺失就明确警告「Desktop will fail to run tools」（`Test-SiblingExes`）。
3. **`-Verify` 也检查配套文件**，缺失时报
   `RESULT: override active BUT helpers missing`，而不是只说「override active」。

同时修了一个真实 bug：参数默认值里写 `Join-Path $env:BUILD_ROOT ...`，
在某些宿主中求值时环境变量尚不可用，会抛
`无法将参数绑定到参数"Path"，因为该参数是空值`。已改为在脚本体内解析。

## 4. 教训

**任何「用环境变量覆盖某个二进制路径」的方案，都必须考虑同目录的配套文件。**

`CODEX_CLI_PATH` 不是只覆盖一个文件，它**改变了 Desktop 解析整个 CLI 目录的基准**。
只复制主程序必然导致配套组件失效。

更普遍地说：**当我把一个文件放到新位置时，应该先查清「谁和它同目录、谁依赖这种同目录关系」。**
这次的线索其实早就出现过 —— 官方目录里有 4 个 exe，而我当时只关注了其中 1 个。

## 5. 验证清单

以后改动安装路径后，按此清单验证：

```
# 1) 四个文件齐全
ls "$env:LOCALAPPDATA\CodexLocalPatch\bin\<ver>"
#    期望: codex.exe + codex-code-mode-host.exe
#          + codex-windows-sandbox-setup.exe + codex-command-runner.exe

# 2) 安装脚本自检
powershell -File scripts\install-patched-codex.ps1 -Verify
#    期望: "override active, helper executables present."

# 3) app-server 能起来
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"t","title":"t","version":"1"}}}' `
  | & "$env:CODEX_CLI_PATH" app-server   # 期望返回 result

# 4) 工具链真的能跑（最关键 —— 前 3 步都过也可能缺 helper）
python scripts\probe_policy.py "$env:CODEX_CLI_PATH" --approval never `
  --sandbox danger-full-access --cmd "Get-Location"   # 期望 EXECUTED

# 5) Desktop 端到端
#    重启 Desktop，发一条消息确认工具可用（不再报 code-mode-host 缺失）
```

第 4 步是**唯一能提前发现本类问题**的检查，前三步都会通过。
