# 内置策略绕过验证报告

**结论：在 `approval_policy = "never"` 下，内置策略已 100% 绕过 —— 51/51 条规则全部失效，且没有误伤。**

验证日期：2026-10-04 ｜ 目标版本：codex 0.160.0

---

## 1. 结论速览

| 验证维度 | 原版 | 补丁版 |
|---|---|---|
| 规则语料命中 | **51 / 51** | **0 / 51** |
| 端到端实测（`never` + danger-full-access） | 3 条被硬拒 | **7 / 7 全执行** |
| 应放行命令是否被误拦 | 0 | **0**（无误伤） |

补丁封堵的是危险命令判定的**两个公开入口**，因此绕过是**全规则面**的，不是只绕过 `-Force` 删除这一类。

---

## 2. 四条独立证据线

### 证据线 A：原版自带测试套件（最权威）

在**补丁源码树**上运行 `cargo test -p codex-shell-command`：

```
test result: FAILED. 167 passed; 6 failed
```

失败的 6 个测试**正是断言「危险命令应被识别」的测试** —— 它们就是被绕过的规则清单：

| 失败测试 | 覆盖的规则 |
|---|---|
| `rm_rf_is_dangerous` | `rm -rf /` |
| `rm_f_is_dangerous` | `rm -f /` |
| `forced_rm_variants_are_dangerous` | `/bin/rm -fr`、`rm -r -f`、`rm --force`、`rm x -f`、`sudo rm -rf`、`env VAR=x rm -rf` |
| `forced_rm_in_complex_shell_syntax_is_dangerous` | `bash -lc` 内 8 种复杂语法（管道/if/引号/for/子shell/嵌套 bash/trap/真实循环） |
| `deeply_nested_command_wrappers_fail_closed` | `env` 嵌套 8 层与 9 层（fail-closed 深度保护） |
| `direct_powershell_words_return_other_match_on_windows` | PowerShell cmdlet 词表入口 |

> 注：`windows_dangerous_commands.rs` 内另有约 40 个测试**直调内部函数**，绕过了补丁点，所以它们仍然通过。这说明必须用入口级测试才能证明全规则面覆盖（见证据线 B）。

### 证据线 B：入口级全规则语料对照（覆盖最全）

建了一个直连 crate 的 A/B 测试台 `shell-command/examples/policy_matrix.rs`，把**从原版测试套件逐条提取的 63 条语料**（51 应拦 + 12 应放行）同时喂给两个入口：

```
语料总数: 63  (应拦 dangerous=51, 应放行 safe=12)

原版   : 判定危险 51/51     ← 全中，零漏判零误判
补丁版 : 判定危险  0/51     ← 全放行
```

**被绕过的 51 条规则明细：**

| 类别 | 数量 | 平台 |
|---|---|---|
| `ForcedRm`（POSIX 强制删除及包装） | 17 | posix |
| `Other`（Windows PS/cmd/URL 规则） | 34 | windows |
| 合计 | **51** | posix 18 + windows 33 |

补丁版两个入口命中数均为 **0**：

```
dangerous_command_match_for_platform 命中: 0
dangerous_powershell_words_match     命中: 0
```

**同时确认零误伤**：12 条应放行命令（`rm` 无 `-f`、`ls`、`rm -- -f`、`Remove-Item` 无 `-Force`、`Start-Process notepad.exe`、`cmd /c del` 无 `/f`、`cmd /c rd /s` 无 `/q`、`explorer.exe .`、`Get-ChildItem -Force; Remove-Item` 等）在补丁版**全部正确放行**，原版也全部正确放行。

### 证据线 C：端到端实测（引擎级，真实执行）

用隔离 `CODEX_HOME` + 本地回环假模型运行 `codex exec`，**以文件系统是否真的改变为准**判定：

| 命令 | 原版 | 补丁版 | 文件系统证据 |
|---|---|---|---|
| `Remove-Item ./a.txt -Force` | **REJECTED_BY_POLICY** | EXECUTED | a.txt True→**False** |
| `Remove-Item ./temp -Recurse -Force` | **REJECTED_BY_POLICY** | EXECUTED | temp True→**False** |
| `ri ./a.txt -Force`（别名） | **REJECTED_BY_POLICY** | EXECUTED | a.txt True→**False** |
| `Remove-Item ./a.txt -Force -WhatIf` | **REJECTED_BY_POLICY** | EXECUTED | a.txt 保持 True（预演正确） |
| `cmd /c del /f a.txt` | EXECUTED | EXECUTED | a.txt True→False |
| `bash -lc "rm -f ./a.txt"` | EXECUTED | EXECUTED | a.txt True→False |
| `Get-Location`（对照） | EXECUTED | EXECUTED | 无变化 |

原版被拒的 3 条，补丁版全部真实执行并产生预期文件变更。

### 证据线 D：独立原版交叉验证

用**另一个未打补丁的 0.160.0 二进制**（npm 全局包，独立于 Desktop）跑同一组命令：

```
[NPM-0.160.0] Remove-Item -Force            -> REJECTED_BY_POLICY
[NPM-0.160.0] Remove-Item -Recurse -Force   -> REJECTED_BY_POLICY
[NPM-0.160.0] ri -Force                     -> REJECTED_BY_POLICY
[NPM-0.160.0] Remove-Item -Force -WhatIf    -> REJECTED_BY_POLICY
[NPM-0.160.0] Get-Location                  -> EXECUTED
```

与 Desktop 原版行为完全一致，排除「版本差异」这一混淆因素。

---

## 3. 附带发现：原版自身的两个真实缺口

这两条**与补丁无关**，是原版就存在的问题：

| 命令 | 原版结果 | 原因 |
|---|---|---|
| `cmd /c del /f a.txt` | **未拦住** | 模型发的是 PowerShell 命令串，经 `parse_powershell_command_into_plain_commands` 解析后 `origin` 变为 **PowerShell**，只走 `dangerous_powershell_words_match` 入口。该入口只认 PowerShell 风格的 `-Force`，**不认 cmd 风格的 `/f`**。`cmd` 规则只在 argv 直传（`origin=Generic`）时才生效。 |
| `bash -lc "rm -f ./a.txt"` | **未拦住** | 同上，非 PowerShell 的 shell 字符串未走 argv 直传路径。 |

另一侧的**误拦**：`Remove-Item ./a.txt -Force -WhatIf`（纯只读预演，什么都不删）在原版下也被硬拒。

即：该检查器既误拦预演，又漏拦 cmd 形态 —— 绕过它并没有「失去原本可靠的保护」。

---

## 4. 补丁为什么是全规则面覆盖

补丁封堵的是**两个公开入口**，所有规则都必经它们：

```
core/src/exec_policy.rs:718  dangerous_command_match_for_origin()
    ├── origin=Generic    → dangerous_command_match_for_platform()   ← 补丁点 1
    │                          └── dangerous_command_match_with_depth()
    │                                ├── dangerous_command_match_for_exec()   rm/sudo/env/trap
    │                                ├── parse_shell_lc_literal_commands()    shell -c 内字面量
    │                                └── is_dangerous_command_windows()       Windows PS/cmd/GUI
    └── origin=PowerShell → dangerous_powershell_words_match()       ← 补丁点 2
                               └── is_dangerous_powershell_words()   PS cmdlet + URL 启动
```

两个入口都返回 `None` 后，`exec_policy.rs:799` 的
`if dangerous_command_match.is_some() || windows_managed_fs_restrictions_without_sandbox_backend`
判定不再成立，`AskForApproval::Never => Decision::Forbidden` 这条分支**永远不会命中**。

**原判定逻辑完整保留**（未删除，仅不可达），便于审计与还原。

---

## 5. 其他内置拦截面核查

确认在 `never` + `danger-full-access` 下，危险命令判定是**唯一**的硬拦截面：

| 层 | 是否会硬拦 | 依据 |
|---|---|---|
| 危险命令判定 | **是**（已绕过） | `exec_policy.rs:799-803` |
| `sandboxing.rs:217` 的 Forbidden | 否 | 仅对 `AskForApproval::Granular` 生效 |
| `network_proxy` | 否 | 默认 false；且无沙箱网络限制时是 no-op（`config_tests.rs:1770`） |
| `unix_escalation.rs:333` | 否 | 仅 zsh fork 路径（Windows 不适用） |
| `requirements` 企业层 | 否 | 本机不存在 requirements.toml / managed_config.toml |
| `has_full_access` | 已满足 | `never` + `PermissionProfile::Disabled` → `true` → guardian 直接 Approved（`routing.rs:81`） |

---

## 6. 复现方式

```powershell
# 证据线 A：原版测试套件（预期 167 passed; 6 failed）
cargo test -p codex-shell-command

# 证据线 B：入口级全规则语料对照
cargo build -p codex-shell-command --example policy_matrix
.\policy_matrix.exe corpus.json

# 证据线 C：端到端实测
python scripts\probe_policy.py <codex.exe> --approval never --sandbox danger-full-access `
  --cmd "Remove-Item -LiteralPath ./a.txt -Force" --out docs\probe-e2e.json
```

产物：
- `E:\codex-build\corpus.json` — 63 条规则语料
- `E:\codex-build\matrix_out_original.json` / `matrix_out_patched.json` — 入口级对照结果
- `docs/probe-e2e-original.json` / `probe-e2e-patched.json` / `probe-e2e-npm-original.json` — 端到端结果
- `E:\codex-build\codex-0.160.0\codex-rs\shell-command\examples\policy_matrix.rs` — 测试台源码

---

## 7. 注意事项

1. **绕过是完全的**：删除、URL 启动、递归删除等全部不再有任何引擎级拦截。用户级 Hook（`~/.codex/hooks.json` 中的 `Accidental Delete Guard`）仍可独立拦截，建议保留作为唯一兜底。
2. **URL 类规则不要用真实执行来测**：`mshta.exe <url>`、`Start-Process <url>` 会真的拉起浏览器/HTA 进程并可能挂住。这类规则用测试台（证据线 B）直测入口即可。本次实测中 `mshta about:blank` 曾残留进程，已清理。
3. **`codex exec` 硬编码 `approval_policy = Never`**（`exec/src/lib.rs:576`），仅当 `approvals_reviewer = auto_review` 时撤销该覆盖。因此无法用 `codex exec` 验证 `on-request` 的弹窗行为。
