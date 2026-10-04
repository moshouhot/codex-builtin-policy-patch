# Codex 内置策略清单（0.160.0 源码级）

本文回答两个问题：**Codex 内置限制到底有哪些**，以及**要最大权限该怎么配**。

---

## 1. 最大权限的正确配置

### 1.1 关键源码

`ext/guardian-reviewer/src/routing.rs:81` —— 审批请求进入审查器后的第一件事：

```rust
if self.full_access {
    return Some(match self.host.validate_action() {
        Ok(_) => ReviewDecision::Approved,   // 直接批准，跳过一切 AI 审查
        Err(decision) => decision,
    });
}
```

`protocol/src/environment.rs:32` —— `full_access` 何时为真：

```rust
pub fn has_full_access(approval_policy, thread_profile, environments) -> bool {
    approval_policy == AskForApproval::Never     // ← 必须 Never
        && /* 每个 environment 的 */ permission_profile == Disabled   // ← 必须 danger-full-access
}
```

**结论：`full_access` 只在 `never` + `danger-full-access` 下成立。**
`on-request` 永远拿不到 `full_access`，因此永远走「审查 → 可能弹窗」这条路。

### 1.2 权限档位映射（`utils/approval-presets/src/lib.rs`）

| Desktop 档位 | approval_policy | permission_profile |
|---|---|---|
| Read Only | `on-request` | `read-only` |
| Default（默认） | `on-request` | `workspace-write` |
| **Full Access** | **`never`** | **`disabled`（danger-full-access）** |

### 1.3 推荐配置

```toml
approval_policy = "never"
default_permissions = ":danger-full-access"
approvals_reviewer = "user"

[features]
network_proxy = false        # 默认已是 false，显式写一遍更保险
```

**为什么 `approvals_reviewer = "user"` 而不是 `"auto_review"`：**

`auto_review` 不是「自动批准」，而是把审批请求路由给一个 **AI 审查子代理（Guardian）**
做风险判定。在 `never` + `danger-full-access` 下 `full_access = true`，
guardian 在 `routing.rs:81` **直接批准**，`auto_review` 只是白加一层模型调用和延迟。
`user` 更简单、更快、无额外 token 消耗，效果相同。

### 1.4 唯一还需要补丁的地方

`never` 下，`dangerous_command_match` 命中会让命令走：

```
core/src/exec_policy.rs:800
    if dangerous_command_match.is_some() {
        AskForApproval::Never => Decision::Forbidden    // ← 硬拒绝，无弹窗
    }
```

这是**唯一**在 `never` 下仍会拦你的东西，也正是本仓库补丁移除的对象。
所以：**补丁 + `never` + `danger-full-access` = 零拦截、零弹窗**。

---

## 2. 内置策略全清单

### 2.1 危险命令判定（唯一「无弹窗硬拒」路径）

`shell-command/src/command_safety/`，两个公开入口（本补丁的封堵点）：

| 入口 | 适用 | 覆盖的规则 |
|---|---|---|
| `dangerous_command_match_for_platform` | 通用 argv | `rm -f/-rf/--force`；`sudo <cmd>` 递归；`env VAR=x <cmd>` 递归；`trap` 动作递归；shell `-c` 内字面量命令 |
| `dangerous_powershell_words_match` | PowerShell `-Command` 体 | `Remove-Item`/`ri`/`rm`/`del`/`erase`/`rd`/`rmdir` 与 `-Force` 同段；URL 启动（`Start-Process`/`Invoke-Item`/`ShellExecute`/`rundll32 url.dll`/`mshta`/浏览器/`explorer` + http(s) URL） |

**实测出的检查器缺口**（原版 `never` 下）：

| 命令 | 原版结果 |
|---|---|
| `Remove-Item ./a.txt -Force` | **REJECTED_BY_POLICY** |
| `Remove-Item ./temp -Recurse -Force` | **REJECTED_BY_POLICY** |
| `Remove-Item ./a.txt -Force -WhatIf` | **REJECTED_BY_POLICY**（只读预演也被误拦） |
| `cmd /c del /f a.txt` | EXECUTED（**没拦住**） |
| `cmd /c rd /s /q temp` | EXECUTED（**没拦住**） |

即：该检查器既**误拦**（`-WhatIf`），又**漏拦**（`cmd /c` 形态）。

### 2.2 审批策略层

`protocol/src/protocol.rs:986` 的 `AskForApproval`：

| 值 | 语义 |
|---|---|
| `untrusted` | 项目未受信任，除显式规则外一律要审批 |
| `on-request`（默认） | 由模型决定何时请求审批 |
| `granular` | 细分开关：`sandbox_approval` / `rules` / `skill_approval` / `request_permissions` / `mcp_elicitations`，为 `false` 时**自动拒绝而不弹窗** |
| `never` | 从不询问；失败直接返回模型 |

### 2.3 requirements（企业管控层）

`config/src/config_requirements.rs:1029` 的 `ConfigRequirementsToml`，可强制限制：
`allowed_approval_policies`、`allowed_approvals_reviewers`、`allowed_sandbox_modes`、
`allowed_permission_profiles`、`allow_browser_and_computer_use`、`allow_appshots`、
`allow_remote_control`、`rules`（execpolicy 覆盖）、`experimental_network` 等。

**本机状态：无。** 已确认以下文件均不存在：
`~/.codex/requirements.toml`、`/ProgramData/OpenAI/Codex/requirements.toml`、`~/.codex/managed_config.toml`。
所以没有外部策略在压你。

### 2.4 功能开关（`features/src/lib.rs` 的 `Feature` 枚举）

与本主题相关的默认值：

| 开关 | 默认 | 说明 |
|---|---|---|
| `network_proxy` | **false** | 沙箱会话的托管网络代理限制；默认不开，无需处理 |
| `browser_use` / `browser_use_full_cdp_access` | true | 仅能被 requirements 关闭（「requirements-only gate」） |
| `computer_use` | requirements-only gate | 需 `features.computer_use = true` + 相关环境变量 |
| `guardian_v2` | — | 启用 Guardian V2 自动审批审查（`auto_review` 的引擎） |
| `shell_tool` / `codex_hooks` | 稳定项 | 默认行为 |

### 2.5 Hook 层（本机已装，与内置策略无关）

`~/.codex/hooks.json` 中当前生效的 PreToolUse 拦截：

- `Checking disk-level operation`
- `Accidental Delete Guard (PowerShell)`

这些是用户级 Hook，可独立 deny 命令，优先级在引擎策略之外。

---

## 3. 各层拦截能力对照

| 层 | 能拦什么 | 能否配置绕过 | 需要补丁吗 |
|---|---|---|---|
| 危险命令判定 | `-Force` 删除、URL 启动等 | ❌ 无配置项 | ✅ 需补丁 |
| `approval_policy` | 决定弹窗还是硬拒 | ✅ config.toml | ❌ |
| 权限档位 | 决定 `full_access` | ✅ Desktop 档位 / `default_permissions` | ❌ |
| requirements | 企业强制策略 | ❌ 但本机没有 | ❌ |
| features | 网络代理等 | ✅ `[features]` | ❌ |
| Hook | 任意自定义规则 | ✅ hooks.json | ❌ |

**只有第 1 层需要源码补丁；其余全部可通过配置解决。**

---

## 4. 验证方式

```powershell
# 内置策略面实测（隔离 CODEX_HOME + 回环假模型，无远程推理）
python scripts\probe_policy.py <codex.exe> --approval never --sandbox danger-full-access `
  --cmd "Remove-Item -LiteralPath ./a.txt -Force" `
  --cmd "cmd /c del /f a.txt" `
  --out docs\probe-surface-original.json
```

注意 `classify()` 以**文件系统是否真的改变**为准（`a_txt_exists` / `temp_exists`），
而非仅看返回文本 —— 早期版本曾把 `REVIEW_FAILED` 误判为 `EXECUTED`。

另外：`codex exec`（无头模式）在 `exec/src/lib.rs:576` **硬编码 `approval_policy = Never`**，
只有 `approvals_reviewer = auto_review` 时才撤销该覆盖。
所以用 `codex exec` 无法验证 `on-request` 的弹窗行为 —— 那是本次实测中发现的探针局限。
