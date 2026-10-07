# 故障复盘 3：构建 OOM —— 页面文件不足导致链接失败

**症状**：构建 0.162.0-alpha.2 时反复失败，`cargo build` 退出码 101，日志中出现：

```
rustc-LLVM ERROR: out of memory
Allocation failed
error: could not compile `codex-cli` (bin "codex")
```

**结论**：**不是代码问题，是机器的提交内存（commit limit）不足。**
32 GB 物理内存 + 20 GB 页面文件 = 51 GB 提交上限，其中约 44 GB 已被系统占用，
只剩不到 7 GB，而最终 `codex-cli` 的 thin-LTO 链接需要更多。

---

## 1. 为什么被误判为「假错误 ICE」

这个项目早先记录过一个已知现象：在默认并行度下 rustc 会偶发假错误
（`E0463 can't find crate`、`E0786 invalid metadata`），单独重编译出错的 crate 往往就通过。

**但这次不是那个问题。** 日志里明确写着 `rustc-LLVM ERROR: out of memory`，
是真实的内存耗尽。我一开始套用了旧结论，写了个「解析失败 crate 名 → 单独重编译」
的重试脚本，结果：

1. 打不中要害（内存问题不会因为单独编译就消失）；
2. 解析逻辑还写错了（`findstr` 提取到字面词 `compile` 而非真实 crate 名），
   每轮都在执行 `cargo -p compile`，纯空转。

**教训：先读日志里的确切错误串，再套用历史结论。**
`STATUS_STACK_BUFFER_OVERRUN` 这个退出码会同时出现在两种完全不同的原因里
（假错误 ICE / LLVM OOM），不能只看退出码。

## 2. 真实原因

| 项 | 值 |
|---|---|
| 物理内存 | 32 GB |
| 页面文件 | 20 GB，**固定在 F:** |
| 提交上限 | **51.4 GB** |
| 已用 | **44.6 GB** |
| 空闲 | **约 7 GB** |
| 可见进程私有内存合计 | 仅约 7 GB |

大量提交内存被内核、驱动、内存压缩占用，不可见但真实存在。
最终 `codex-cli` 的 thin-LTO 链接步骤需要超过这 7 GB，于是 OOM。

**关键约束**：页面文件在 F:，而 **F: 只剩 9.9 GB 空间，无法扩容**。
但 **E: 有 78 GB 空闲**。

## 3. 走过的弯路（都已撤销）

| 尝试 | 结果 | 为什么错 |
|---|---|---|
| 解析失败 crate 名并单独重编 | 空转 | 内存问题，不是假错误；且解析逻辑有 bug |
| `-j 2` / `-j 1` 降低并行度 | 仍 OOM | 单进程链接峰值就超了剩余额度 |
| `cargo rustc ... -C lto=off -C debuginfo=0 -C codegen-units=16` | **引入新问题** | 改 `-C` 参数导致 cargo **全量重编所有依赖**，并触发假错误（`gix` 报 2417 个错，单独编译 2 秒通过） |

第三条尤其值得记：**不要用改 `-C` 标志的方式去解决 OOM** —— 它会作废整个增量缓存。

## 4. 修复

在 E: 增加第二个页面文件（32 GB），提交上限 51.4 → **83.4 GB**：

```powershell
wmic pagefileset create name="E:\pagefile.sys",InitialSize=32768,MaximumSize=32768
```

之后构建**一次通过**，OOM 次数为 0，耗时 38 分 29 秒。

验证：
- 产物 `codex.exe` 335,736,320 字节
- `--version` → `codex-cli 0.162.0-alpha.2`
- 能打开官方 0.162.0-alpha.2 创建的数据库（**迁移校验和兼容性通过**）
- 策略绕过实测 4/4 `EXECUTED`

## 5. 排查清单

遇到 `rustc-LLVM ERROR: out of memory` 时，按此顺序：

```powershell
# 1) 确认是 OOM 而不是假错误 ICE —— 看日志里的确切字符串
Select-String -Path build.log -Pattern 'out of memory'

# 2) 检查提交内存预算
Get-CimInstance Win32_OperatingSystem |
  Select-Object @{n='LimitGB';e={[math]::Round($_.TotalVirtualMemorySize/1MB,1)}},
                @{n='FreeGB'; e={[math]::Round($_.FreeVirtualMemory/1MB,1)}}

# 3) 若 FreeGB 偏小，找有空闲空间的盘加页面文件
Get-CimInstance Win32_PageFileSetting | Select-Object Name,InitialSize,MaximumSize
```

**判定要点**：
- 日志含 `out of memory` → 内存预算问题，**加页面文件**，不要动编译参数
- 日志含 `can't find crate` / `invalid metadata` 且无 OOM → 假错误 ICE，单独重编该 crate
- 两者都不满足 → 再看其他原因

## 6. 关于改编译参数的风险

改 `-C lto` / `-C codegen-units` / `-C debuginfo` 会让 cargo 认为 profile 变了，
**全量重编所有依赖**（本机约 25–40 分钟），而且在高负载下容易触发假错误 ICE。
除非确有把握，否则优先解决资源问题，保持编译参数与官方 release 一致。

## 7. 版本信息

- 目标版本：`rust-v0.162.0-alpha.2`
- Rust 工具链：1.95.0（与上游 `rust-toolchain.toml` 一致）
- rusty_v8：150.4.0 / profile `ptrcomp_sandbox_release`（与 0.160.0 相同，产物可复用）
- 补丁点：`is_dangerous_command.rs` 两个入口函数**与 0.160.0 逐字节相同**，补丁可直接复用
- 迁移文件：0.162.0-alpha.2 的 74 个 `.sql` 仍需转 CRLF（校验和 4/4 与官方匹配）
