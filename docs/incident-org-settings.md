# 故障复盘：桌面端「无法加载组织设置」

**症状**：修改 `~/.codex/config.toml` 后 Codex Desktop 弹出阻断性对话框
「无法加载组织设置 / Organization settings could not be loaded」，无法进入应用。

**结论**：**与 config.toml 改动无关**。真正原因是补丁版 `codex.exe` 存在缺陷 ——
它无法打开由官方 CLI 创建的 SQLite 数据库。修复方式是重建补丁版，并把
「迁移文件换行符」这一步固化进构建脚本。

---

## 1. 为什么看起来像 config 的锅

改动时间与故障出现时间吻合，很容易归因到配置。但证据推翻了它：

| 实验 | 结果 |
|---|---|
| 补丁版 CLI + 真实 CODEX_HOME 跑 `doctor` | 正常，退出码 0 |
| 补丁版 CLI + 真实 CODEX_HOME 跑 `app-server` | **退出码 1**：`failed to initialize sqlite state runtime` |
| **原版** CLI + **同一份** state_5.sqlite | **成功** |
| 补丁版 + **不含 config.toml** 的同一批数据 | **仍然失败** |

第 4 条是决定性的：**去掉 config.toml 照样失败**，所以配置不是原因。

同时 `codex doctor` 能过、`app-server` 过不了，说明失败发生在 app-server
独有的初始化路径上 —— Desktop 正是通过 app-server 启动的，进程一退出就弹出
「组织设置无法加载」。

## 2. 根因

**sqlx 的迁移校验和基于迁移文件的原始字节，而官方发布的迁移文件是 CRLF，
我的源码检出却是 LF。**

完整链条：

1. `codex-rs/state/*_migrations/*.sql` 在官方仓库里是 **CRLF** 换行。
2. 本机 Git 全局配置 `core.autocrlf = true`，检出时把 `.sql` 改写成 **LF**。
3. `sqlx::migrate!()` 编译期把迁移 SQL 内联进二进制，并对其**原始字节**算
   SHA-384 校验和。换行符变了，校验和就变了。
4. 官方 CLI 建库时写入的是 **CRLF 校验和**；补丁版内嵌的是 **LF 校验和**。
5. 打开数据库时校验和不匹配 → 迁移校验失败 → app-server 启动失败。

### 证据

对同一个迁移文件算 SHA-384：

```
goals_migrations/0001_thread_goals.sql (495B)
   sha384(当前工作区/LF) = 8ce6280244a0b4b39c7c37c7f67aff1670ec963d…  <== 匹配补丁版记录的校验和
   sha384(转为 CRLF)     = 9d4af4ba7688052dd22a508b567b977e6d79ba20…  <== 匹配官方记录的校验和

logs_migrations/0001_logs.sql (730B)
   sha384(当前工作区/LF) = 009639eafe599be97d49d1d712e51671bf1be1c6…  <== 匹配补丁版
   sha384(转为 CRLF)     = f477e6056db490de009f392c16761f4719b17ba3…  <== 匹配官方
```

并且**双向交叉读取都失败**（原版读不了补丁版建的库，反之亦然），
确认是校验和不匹配，而非单向数据损坏。

**注意**：迁移文件的**内容与官方逐字节一致**（与 `rust-v0.160.0` 的 raw 文件
对比 sha256 相同）。差异只在换行符，所以肉眼看 diff 是看不出来的。

## 3. 修复

1. 把 73 个迁移文件从 LF 转回 CRLF。
2. 验证 4 个已知校验和与官方**全部匹配**。
3. 重新构建补丁版。
4. 部署并回归验证。

```
=== 校验和验证 ===
  0001_thread_goals.sql     MATCH
  0001_logs.sql             MATCH
  0001_memories.sql         MATCH
  0001_queued_items.sql     MATCH
验证通过 4/4
```

修复后：

| 测试 | 结果 |
|---|---|
| 新补丁版读官方建的数据库 | **成功** |
| 新补丁版读真实 `.codex` | **成功** |
| `app-server` 真实 CODEX_HOME | **正常返回** |
| 策略绕过回归（`-Force` 删除等 4 条） | **全部 EXECUTED**，补丁功能完好 |

新产物：`sha256 eb2d3b13161ceeb94edd28c10d4f0f51…`，329436672 字节。

## 4. 已固化进构建流程

- `scripts/fix-migrations-crlf.py` —— 幂等的换行符规范化脚本，构建后自校验。
- `scripts/build-patched-codex.cmd` —— 在 `git apply` 之后、`cargo build` 之前
  调用它，并附上原因注释。

**这样下次重建不会重蹈覆辙。**

## 5. 排查方法记录（可复用）

判断「补丁版是否因数据库校验和而不兼容」的最小复现：

```powershell
# 1) 用官方 CLI 在空目录建库
$env:CODEX_HOME = "$env:TEMP\probe_orig"
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"t","title":"t","version":"1"}}}' `
  | & "$origCodex" app-server | Select-Object -First 1

# 2) 用补丁版读同一个目录 —— 若报 sqlite state runtime 失败即为该校验和问题
$env:CODEX_HOME = "$env:TEMP\probe_orig"
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"t","title":"t","version":"1"}}}' `
  | & "$patchedCodex" app-server | Select-Object -First 1

# 3) 对比两者 _sqlx_migrations 表里的 checksum
#    （用 dump_migrations.py 之类的脚本读 *.sqlite）
```

判定要点：
- 若**只有补丁版失败**、原版成功 → 二进制差异问题，不是数据损坏。
- 若**去掉 config.toml 仍失败** → 与配置无关。
- 若两者记录的 checksum 不同但 SQL 内容相同 → **换行符**问题。

## 6. 一个必须注意的坑

`sqlite3` 直接读 `state_5.sqlite` 可能报「没有任何表」或
`no such column: version` —— 这是**正常现象**，因为数据在 `-wal` 文件里。
不要据此判断数据库损坏。判断完整性请用 `PRAGMA integrity_check`（本次三个
主要数据库均返回 `ok`），或让 codex 自己打开。
