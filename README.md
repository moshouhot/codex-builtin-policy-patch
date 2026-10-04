# Codex 内置策略（dangerous-command 拦截补丁）

移除 Codex CLI 内置「危险命令」自动拦截，使 `Remove-Item -Force`、`rm -rf` 等命令在
`approval_policy = "never"` 会话下不再被硬拒绝。

**状态：已构建、已验证、已部署到本机，待重启 Desktop 生效。**

---

## 1. 问题定位（本机实测）

现象：执行 `Remove-Item <项目内两个小文件> -Force` 时，被直接拒绝并返回 `blocked by policy`，
**连审批弹窗都没有**。

源码链路（`openai/codex` @ `rust-v0.160.0`）：

```
shell-command/src/command_safety/windows_dangerous_commands.rs
    has_force_delete_cmdlet()          # 只看「删除命令 + -Force」是否同现，不看目标
        ↓
shell-command/src/command_safety/is_dangerous_command.rs
    dangerous_command_match_for_platform()      # 通用入口（ForcedRm / sudo / env / trap）
    dangerous_powershell_words_match()          # PowerShell -Command 体入口
        ↓
core/src/exec_policy.rs:770
    render_decision_for_unmatched_command_for_platform()
    if dangerous_command_match.is_some() {
        AskForApproval::Never     => Decision::Forbidden   # ← 硬拒绝，无弹窗
        AskForApproval::OnRequest => Decision::Prompt
    }
        ↓
core/src/exec_policy.rs:1089
    derive_forbidden_reason()  => "`<cmd>` rejected: blocked by policy"
```

### 根因不是 config.toml

`~/.codex/config.toml` 里写的是 `approval_policy = "on-request"`，
但 Desktop 的**权限档位**把会话钉死成了 `never`。证据来自本机 rollout 记录
（`~/.codex/sessions/2026/10/**/*.jsonl` 中 `thread_settings_applied`），
近期 10 个 Desktop 会话**全部**是：

```json
{"approval_policy": "never",
 "active_permission_profile": {"id": ":danger-full-access"},
 "permission_profile": {"type": "disabled"}}
```

`:danger-full-access` 档位 ⇒ `approval_policy = never` ⇒ 危险命令走 `Forbidden` 分支。
所以**只要还用这个档位，`-Force` 删除就必然被拦，且无法通过审批放行。**

---

## 2. 补丁

改动只有一个文件、两个函数，共 18 行：
`codex-rs/shell-command/src/command_safety/is_dangerous_command.rs`

```rust
pub fn dangerous_command_match_for_platform(command, platform) -> Option<DangerousCommandMatch> {
    // LOCAL PATCH: 原实现 dangerous_command_match_with_depth(command, 0, platform)
    let _ = (command, platform);
    None
}

pub fn dangerous_powershell_words_match(command, platform) -> Option<DangerousCommandMatch> {
    // LOCAL PATCH: 原实现 windows_dangerous_commands::is_dangerous_powershell_words(command)
    let _ = (command, platform);
    None
}
```

设计取舍：

- **只封这两个公开入口**。全仓检索确认它们是危险命令判定的唯一收敛点：
  `dangerous_command_match_for_platform` 是 `dangerous_command_match` /
  `dangerous_command_match_for_exec`（`rm -f`、`sudo`、`env`、`trap` 递归）的唯一出口；
  `dangerous_powershell_words_match` 由 `core/src/exec_policy.rs:728` 在
  `command_origin == PowerShell`（即 PowerShell `-Command` 体）时调用。
  原判定逻辑（`windows_dangerous_commands.rs` 全文）**完整保留、仅变为不可达**，
  便于后续审计与还原。
- **不动 execpolicy / approval 机制**。`Decision::Forbidden` 分支、
  `prompt_is_rejected_by_policy`、rules 文件、sandbox 全部保持原样，
  因此 `OnRequest` 下的审批弹窗行为不变。
- **不做字符串级二进制 patch**。基于公开源码 + 官方 release 工具链完整重建，
  避免手改 PE 引入不可审计的字节。

未改动范围（保持原有防护）：文件系统 sandbox、`approval_policy` 语义、
execpolicy rules、网络策略、`shell_escalation` 等。

---

## 3. 安装方式：`CODEX_CLI_PATH` 覆盖（不改 MSIX）

Desktop 的 Electron 启动器**不会**在启动时覆盖 `CODEX_CLI_PATH`。
从 `app.asar` 提取到的路径解析逻辑：

```js
function Yi({ relocateWindowsApps, rawValue, resolveWindowsAppsPath }) {
  if (rawValue == null) return null;
  if (relocateWindowsApps && Cte(rawValue)) {          // Cte: 路径是否在 \Program Files\WindowsApps\ 下
    return { path: resolveWindowsAppsPath(dirname(rawValue)), source: 'env-override-relocated' };
  }
  return { path: rawValue, source: 'env-override' };   // ← WindowsApps 之外：原样使用
}
```

关键点：

- 指向 **WindowsApps 之外**的路径时，`source = 'env-override'`，**跳过哈希校验、跳过解包覆盖**。
- 指向 WindowsApps **之内**的路径时，会走重定位 + 完整性校验（`un()` 比对 size + sha256），
  补丁二进制会被 `rmSync` 后重新解包覆盖 —— 所以**不能**直接替换
  `%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe`。

因此本方案：

```
%LOCALAPPDATA%\CodexLocalPatch\bin\0.160.0\codex.exe   ← 补丁二进制
        ↑
CODEX_CLI_PATH (用户级环境变量，指向上述文件)
```

Store 包体、`WindowsApps`、`bin\<hash>` 目录**均未改动**；
Codex 升级后只需重新构建并覆盖 `CodexLocalPatch` 目录即可，无需重新签名 MSIX。

---

## 4. 验证证据

对照组使用隔离 `CODEX_HOME` + 本地回环假模型（无远程推理、无 API key），
被测命令固定为 `-Force` 删除项目内文件/目录。
脚本：`scripts/probe_policy.py`，结果：`docs/probe-original-never.json`、`docs/probe-patched-never.json`。

| 用例 | 原版 (never) | 补丁版 (never) |
|---|---|---|
| `Remove-Item ./a.txt -Force` | **REJECTED_BY_POLICY**（a.txt 仍在） | EXECUTED（a.txt 已删） |
| `Remove-Item ./a.txt`（无 -Force） | EXECUTED | EXECUTED |
| `Remove-Item ./temp -Recurse -Force` | **REJECTED_BY_POLICY**（temp 仍在） | EXECUTED（temp 已删） |
| `rm -rf ./temp` | EXECUTED | EXECUTED |
| `Get-Location`（对照） | EXECUTED | EXECUTED |

**判定标准是「文件是否真的被删除」**，不只是「有没有报错」：
原版拒绝时 `a.txt = True`（存活），补丁版 `a.txt = False`（已删除）。
同时确认无 `-Force` 的普通删除、只读命令行为**完全未变**。

其它已验证项：

- `codex.exe --version` → `codex-cli 0.160.0`
- `app-server` 启动并在隔离 `CODEX_HOME` 下返回正常 JSON-RPC `initialize` 响应
- 外部依赖零漂移：`Cargo.lock` 仅内部 workspace crate 版本占位符由 `0.0.0` 填充为 `0.160.0`，
  包总数 1335 → 1335，无增删、无版本变更

---

## 5. 使用

```powershell
# 检查补丁状态：是否生效、是否因 Desktop 升级而过期
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-codex-version.ps1

# 验证当前覆盖是否生效
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-patched-codex.ps1 -Verify

# 回退（移除 CODEX_CLI_PATH，恢复使用官方内置 CLI）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-patched-codex.ps1 -Rollback
```

### 升级后必做：`check-codex-version.ps1`

Store 升级 Desktop 后，新版自带 CLI 会被解包到新的 `bin\<新哈希>\` 目录，
而 `CODEX_CLI_PATH` 仍指向旧的补丁版本 —— 此时**补丁没丢，但版本不匹配**。
该脚本比对「覆盖指向的版本」与「Desktop 自带 CLI 版本」，给出四种结论：

| 结论 | 含义 | 处理 |
|---|---|---|
| `PATCHED_AND_CURRENT` | 补丁生效且版本一致 | 无需操作 |
| `PATCH_STALE` | **需重新打补丁**（版本不匹配） | 先 `-Rollback`，或重新构建安装 |
| `PATCH_BROKEN` | 覆盖指向的文件不存在 | `-Rollback` 或重新安装 |
| `PATCH_INACTIVE` | 未启用补丁（用官方 CLI） | 如需启用则安装 |

退出码：`0` = 无需处理，`1` = 需要处理（`PATCH_STALE` / `PATCH_BROKEN`），
便于写进启动脚本或计划任务。加 `-Json` 输出机器可读结果。

> 自带 CLI 位于 `WindowsApps` 内**无法执行**，因此其版本号是通过扫描二进制中的
> 版本字符串得到的（优先用 `rg`，约 0.2 秒；无 `rg` 时回退到分块扫描）。
> 覆盖路径可执行时，优先用 `codex.exe --version` 这一权威来源。

生效需要**完全退出 Codex Desktop 后重新启动**（托盘 → Quit，不是关窗口），
让新进程继承用户级环境变量。

### 重新构建（Codex 升级后）

```cmd
scripts\build-patched-codex.cmd
```

脚本会：确保 Rust 1.95.0 与官方预编译 rusty_v8 产物 → 应用 `patches\*.patch` → release 构建。

**注意**：脚本内硬编码了本机路径（`E:\codex-build`、VS2022 Community 位置、
`rusty_v8` 版本 `150.4.0` / profile `ptrcomp_sandbox_release`）。换机器需同步调整。

---

## 6. 已知限制与风险

- **`-j 6` 是必需的**。用默认并行度（本机 16 逻辑核）时 rustc 会间歇性 ICE
  并产出损坏的 crate 元数据，表现为大量假错误（`E0463 can't find crate`、
  `E0786 invalid metadata`、`[RolloutItem]: Sized` 等）。限制并行度后构建稳定通过。
- **`CODEX_CLI_PATH` 是全局的**。它同时影响 Desktop、`codex` CLI 以及
  由它们派生的子进程（app-server、code-mode-host、node_repl 等）。
  回退即恢复全部行为。
- **本补丁解除的是「危险命令自动判定」这一层**。它不改变 sandbox、
  不改变 execpolicy rules、不改变网络策略。若某会话使用
  `approval_policy = "on-request"`，原先会弹窗的 `-Force` 删除现在将
  **静默执行**（因为已不被判为危险命令）。这是本补丁的预期语义，也是它的主要风险面。
- **依赖内部实现**。判定入口在 0.160.0 源码中已确认唯一；Codex 后续版本若
  新增判定入口，需重新核对 `patches\` 是否仍然充分。
- **升级后不会静默失效，但会静默“降级”**。`CODEX_CLI_PATH` 不会被升级覆盖，
  所以补丁会继续生效、只是版本变旧。跑一次 `scripts\check-codex-version.ps1`
  即可发现（`PATCH_STALE`）。若上游改动了补丁涉及的两个函数，
  `git apply` 会直接报错，不会“以为打上了其实没生效”。
- **`.ps1` 必须带 UTF-8 BOM**。Windows PowerShell 5.1 按 GBK 读取无 BOM 的
  UTF-8 文件，会把中文字符串字面量截断并报一堆 `MissingEndParenthesis` 之类的
  语法错误。新增脚本时请保持 BOM。
- 与 `Codex Accidental Delete Guard`（PreToolUse Hook）**相互独立**：
  本补丁解除引擎级拦截，ADG 仍在 Hook 层做路径级防呆。两者可同时启用。

---

## 7. 目录结构

```
Codex 内置策略/
├── LICENSE                            Apache License 2.0
├── NOTICE                             OpenAI 版权声明 + 本项目修改声明
├── README.md                          本文件
├── patches/
│   └── is_dangerous_command.patch     18 行源码补丁（git apply 可用）
├── scripts/
│   ├── build-patched-codex.cmd        从公开源码重建补丁版 codex.exe
│   ├── fix-migrations-crlf.py         **构建前必须**：迁移文件换行符规范化（见事故复盘）
│   ├── install-patched-codex.ps1      安装 / 验证 / 回退
│   ├── check-codex-version.ps1        检查补丁是否生效、是否因升级而过期
│   ├── sanitize-for-publish.py        发布前脱敏（移除个人环境标识）
│   └── probe_policy.py                原版 vs 补丁版 策略对照探针
├── tests/
│   ├── policy_matrix.rs               入口级 A/B 测试台（放进 shell-command/examples/）
│   └── dangerous-command-corpus.json  63 条规则语料（51 应拦 + 12 应放行）
└── docs/
    ├── builtin-policy-surface.md      **内置策略全清单 + 最大权限配置**
    ├── patch-verification.md          **绕过验证报告（51/51 全绕过）**
    ├── incident-org-settings.md       **事故复盘：迁移文件 CRLF 导致桌面端无法启动**
    ├── matrix-out-original.json       入口级对照：原版 51/51 命中
    ├── matrix-out-patched.json        入口级对照：补丁版 0/51
    ├── probe-e2e-original.json        端到端：原版
    ├── probe-e2e-patched.json         端到端：补丁版
    ├── probe-e2e-npm-original.json    端到端：npm 原版 0.160.0（交叉验证）
    ├── probe-original-never.json      早期实测结果
    ├── probe-patched-never.json       早期实测结果
    ├── probe-deployed-never.json      已部署产物实测
    ├── probe-surface-original.json    内置策略面（原版）
    └── probe-surface-patched.json     内置策略面（补丁版）
```

---

## 8. 绕过验证结论（2026-10-04）

详见 [`docs/patch-verification.md`](docs/patch-verification.md)。

**在 `approval_policy = "never"` 下，内置策略已 100% 绕过：51/51 条规则全部失效，零误伤。**

四条独立证据线：

| 证据 | 原版 | 补丁版 |
|---|---|---|
| 原版自带测试套件 | — | `167 passed; 6 failed`（失败的 6 个正是断言「危险命令应被识别」的测试）|
| 入口级 63 条规则语料 | **51 / 51 命中** | **0 / 51** |
| 端到端实测（`never` + full-access） | 3 条被硬拒 | **7 / 7 全执行** |
| npm 原版 0.160.0 交叉验证 | 行为一致 | — |

**附带发现：原版自身有两个真实缺口**（与补丁无关）：
`cmd /c del /f` 与 `bash -lc "rm -f"` 在原版下**本来就拦不住**（模型发 PowerShell 字符串时
`origin` 变为 PowerShell，只走 cmdlet 词表入口，不认 cmd 风格 `/f`）；
而 `-Force -WhatIf`（纯只读预演）却被误拦。

---

## 9. 已知故障：桌面端「无法加载组织设置」

详见 [`docs/incident-org-settings.md`](docs/incident-org-settings.md)。

**症状**：改动 config.toml 后 Desktop 弹出阻断对话框，无法进入应用。

**真实原因**（与 config 无关）：官方发布的迁移 `.sql` 是 **CRLF**，而本机
`core.autocrlf = true` 把源码检出成 **LF**；sqlx 用**原始字节**算迁移校验和，
于是补丁版无法打开任何官方 CLI 创建的数据库，app-server 启动即退出。

**已修复**：迁移文件转回 CRLF（4/4 校验和与官方匹配）后重建。
`scripts/fix-migrations-crlf.py` 已固化进构建流程，**下次重建不会重犯**。

**重建时务必先确认这一步通过**：

```
python scripts\fix-migrations-crlf.py E:\codex-build\codex-0.160.0\codex-rs\state
# 期望: [OK] all 73 migration files are pure CRLF
```

---

## 10. 最大权限配置（结论速查）

详见 [`docs/builtin-policy-surface.md`](docs/builtin-policy-surface.md)。要点：

- **最大权限 = `never` + `danger-full-access`**，而不是 `on-request`。
  因为 `full_access`（`protocol/src/environment.rs:32`）要求 `approval_policy == Never`，
  而 `full_access = true` 时 guardian 在 `routing.rs:81` 直接 `Approved`、跳过一切审查。
- **`approvals_reviewer = "user"`**，不要用 `"auto_review"`。
  `auto_review` 不是自动批准，而是把请求交给 AI 审查子代理；在 `never` 下它只会
  白加一层模型调用和延迟，结果与 `user` 相同。
- **唯一需要补丁的是「危险命令判定」这一层**。其余各层（approval_policy、权限档位、
  features、requirements、Hook）全部可通过配置解决，无需改代码。

---

## 11. 许可证与合规声明

本项目以 [Apache License 2.0](LICENSE) 发布。

**重要：这是对 OpenAI Codex 的本地修改（local modifications），不是官方产品。**

- 本仓库**不包含**任何 OpenAI 源码，只包含：补丁文件、构建脚本、验证产物与文档。
- 构建产物派生自 OpenAI Codex（Apache-2.0），原始版权归 OpenAI 所有，
  详见 [NOTICE](NOTICE)。
- 依据 Apache-2.0 第 4 条，所有修改均已标注：源码补丁内以 `LOCAL PATCH` 注释标记，
  并逐项记录于 [`patches/`](patches/) 与本文档各变更章节。
- 本项目与 OpenAI 无关联，未获其认可或背书。

### 使用风险

本补丁**有意移除** Codex 内置的危险命令安全判定。这意味着删除、递归删除、
URL 启动等命令将不再有任何引擎级拦截。请自行评估风险，并优先保留
Hook 层防护（如 `~/.codex/hooks.json` 中的 PreToolUse 规则）作为兜底。

在适用法律允许的最大范围内，本软件按「原样」提供，不附带任何明示或默示担保。
详见 [LICENSE](LICENSE) 第 7、8 条。
