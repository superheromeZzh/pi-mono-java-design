# pi-mono Java 集中式 GaussDB 会话记忆系统 SR 设计

> 文档编号：SR-MEM-001
> 版本：v0.6
> 日期：2026-08-03
> 状态：设计评审稿
> pi 源码基线：[`f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee`](https://github.com/badlogic/pi-mono/tree/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee)
> Java 源码基线：无；本文 Java 内容均为 target-only design
> 数据库约束：集中式 GaussDB，单分片高可用部署
> JDBC 约束：openGauss JDBC `6.0.0-htrunks.csi.gaussdb_kernel.opengaussjdbc.r1`

## 1. 结论

Java 版本使用集中式 GaussDB 取代 pi 当前 coding-agent 的本地 JSONL 会话文件，数据库成为会话记忆的唯一持久化事实源。当前 pi-mono SQLite backend 是数据库行为基线；openGauss/GaussDB 实现必须保留以下可观察语义：

- entry 通过 `id` 和 `parentId` 组成不可变会话树。
- 当前 leaf 决定活动分支，context 只使用 root-to-leaf 路径。
- `compaction` 和 `branch_summary` 是会话 entry，不是跨会话长期记忆。
- 新格式 compaction 使用自包含的 `retainedTail`；旧格式继续读取 `firstKeptEntryId`。
- `message`、`custom_message`、摘要 entry 和扩展 projector 决定进入模型的消息。
- 模型、思考级别和启用工具从 SQLite `readPathToRootOrCompaction()` 返回的路径推导。
- `branch_entries` 和 `branch_tips` 是可重建的 root-to-tip 缓存，`session_entries.parent_id` 始终是权威树关系。
- bounded branch query 支持 stop、type、order 和 limit，缓存损坏时回退权威 parent chain 并修复。
- 会话搜索保留当前 SQLite 的大小写不敏感子串匹配、`cwd` 过滤和删除后不可见语义。

Java 目标仍新增 operation id、request hash、revision、expected leaf、行锁和物理外键。这些只是并发、幂等和完整性强化，不得改变单线程合法请求的 SQLite 结果。

### 1.1 对齐边界

| 类型 | 对齐规则 |
|---|---|
| 事实与投影 | `sessions`、`session_entries`、sequence、materialized state、branch cache 和搜索均有 openGauss 对应 |
| 读取语义 | open、page、branch query、context、label、name、stats、fork 和 search 与当前 SQLite 同结果 |
| 写入原子性 | SQLite 同一 append 内的 entry、sequence、summary、leaf、branch cache 和 search 在 GaussDB 也必须同一事务 |
| 可接受差异 | 物理表/列名、非搜索 JSON 的 SQL 类型、索引实现、JDBC 边界、外键、revision 和幂等记录 |
| 不可隐式差异 | compaction 路径边界、leaf 目标、fork 选择、搜索命中集、损坏 entry 错误和投影统计 |

本 SR 只设计会话内记忆，不设计多租户、跨会话事实抽取、向量召回、Runtime Checkpoint、Agent 控制面或 Artifact 内容存储。pi 基线中也没有内建的跨会话记忆抽取和注入流程。

![Java centralized GaussDB memory architecture](./diagrams/memory/memory-architecture.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L1)

## 2. 范围与约束

### 2.1 本期范围

- 会话创建、打开、列出、删除和 fork。
- entry 追加、显式 leaf 移动、标签和会话名称。
- compaction、branch summary 和确定性 context rebuild。
- bounded branch query、root-to-tip 缓存、缓存校验和递归修复。
- 大小写不敏感子串搜索和 `cwd` 过滤。
- JSONL v1-v3 与当前 pi SQLite 会话库导入。
- 数据库事务、幂等重试、并发冲突、投影重建和受控 JSONL 导出。
- Java Application Service、Repository、JDBC Adapter 和 GaussDB 表边界。

### 2.2 本期不包括

- `tenant_id`、`TenantContext`、RLS、租户配额或跨租户授权。
- 跨会话长期 Memory Store、Memory Item、Embedding、抽取和召回。
- Run、Step、Pending Tool Call、Checkpoint、Checkpoint Blob 和执行恢复。
- Agent Definition、Agent Version、Environment、Tool Binding 和 Credential。
- 文件内容、文件操作独立投影及对象存储生命周期；文件摘要仍保留在 entry payload 中。
- 让数据库执行摘要生成、prompt 编排、工具调用或 LLM provider 调用。
- 用向量检索替代活动会话路径。

### 2.3 已确认产品约束

| 约束 | 设计影响 |
|---|---|
| Java GUI/API 服务 | 所有会话操作统一进入 `MemorySessionApplicationService` |
| 不考虑多租户 | 业务表只使用 `session_id` 作为会话作用域，不增加租户列 |
| 集中式 GaussDB | 使用单分片事务、外键、行锁、JSONB 和递归 CTE |
| SQL 能力基线 | 以 Centralized V2.0-3.x 官方语法设计，并在实际服务端版本复验 |
| openGauss JDBC 定制版本 | 锁定指定依赖，不回退到 PostgreSQL JDBC 或其他公开版本 |
| 数据库是最终事实源 | JSONL 只用于导入、导出和恢复，不进行长期双写 |
| 允许并发请求重试 | 写命令使用 operation id、revision 和 expected leaf |

集中式在本设计中表示一个逻辑分片及其高可用副本，不表示单机测试实例。当前不引入分布键；若未来容量超过单分片能力，按 `session_id` 迁移到分布式形态并重新设计外键和跨分片约束。

## 3. pi 源码事实

本节仅记录基线提交中观察到的行为。Java/GaussDB 尚无对应实现，后续章节均为 target-only design。

### 3.1 当前 coding-agent 仍使用 JSONL

`packages/coding-agent/src/core/session-manager.ts` 的生产会话格式版本为 v3。entry 包括 `message`、`thinking_level_change`、`model_change`、`compaction`、`branch_summary`、`custom`、`custom_message`、`label` 和 `session_info`。`_appendEntry()` 把 entry 追加到内存和 JSONL，并将 leaf 指向新 entry。

普通 `branch()` 和 `resetLeaf()` 只更新进程内 `leafId`；只有后续追加 entry 才会把新分支写入 JSONL。因此，旧 JSONL 无法恢复“移动 leaf 后尚未追加”的最终位置。

源码证据：

- [`SessionEntry` 和 JSONL v3](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/coding-agent/src/core/session-manager.ts#L30-L153)
- [`_persist()` / `_appendEntry()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/coding-agent/src/core/session-manager.ts#L1015-L1049)
- [`branch()` / `resetLeaf()` / `branchWithSummary()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/coding-agent/src/core/session-manager.ts#L1354-L1405)

### 3.2 新 harness 定义存储抽象和完整 entry 集合

`packages/agent` 的新 harness 定义 `SessionStorage` 和 `SessionRepository`，把会话语义与 JSONL、内存或 SQLite 介质分开。其 `SessionTreeEntry` 在旧 coding-agent 类型基础上增加：

- `active_tools_change`：保存活动工具名。
- `leaf`：保存显式导航的 `targetId`。
- `compaction.retainedTail`：把保留消息直接存入 compaction entry。

`Session.setLeafId()` 通过 `SessionStorage.appendEntry()` 持久化 leaf entry；`SessionRepository` 统一 create、open、list、delete 和 fork。

源码证据：

- [`SessionTreeEntry`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/src/harness/types.ts#L382-L451)
- [`SessionStorage`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/src/harness/types.ts#L558-L572) / [`SessionRepository`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/src/harness/session/repository.ts#L22-L35)
- [`Session` append 和 moveTo](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/src/harness/session/session.ts#L227-L420)

### 3.3 Context rebuild 和 compaction

新 harness 从 `readPathToRootOrCompaction()` 返回的路径推导 model、thinking level 和 active tools，再应用 context entry transform。该路径在最新 compaction 或其 `firstKeptEntryId` 处截断，不是无条件的完整 root-to-leaf 路径：

- 无 compaction 时保留活动路径。
- 最新 compaction 含 `retainedTail` 时，context 使用 compaction、其自带 retained tail 和 compaction 后续 entry。
- 旧 compaction 不含 `retainedTail` 时，使用 `firstKeptEntryId` 保留旧格式边界。
- compaction entry 投影为 summary message，并追加其 `retainedTail`。
- `custom` 默认不进入 context，只有已注册 projector 才能产生消息。

默认 compaction 设置是启用、保留 16,384 tokens 给 prompt/output、保留最近 20,000 tokens。触发条件是 `contextTokens > contextWindow - reserveTokens`。准备阶段避免从 tool result 中间切割，支持 split turn，并把近期消息物化为 `retainedTail`。

源码证据：

- [`buildSessionContext()` / `Session.getBranch()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/src/harness/session/session.ts#L41-L206)
- [`SQLite readPathToRootOrCompaction()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/index.ts#L171-L269)
- [`shouldCompact()` / `prepareCompaction()` / `compact()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/src/harness/compaction/compaction.ts)

### 3.4 pi SQLite 是数据库行为参考

`packages/storage/sqlite-node` 已实现新 harness 的数据库后端，但当前 coding-agent runtime 尚未接入它。其观察行为是：

- `sessions.active_leaf_id` 保存当前 leaf。
- `session_entries` 使用 `(session_id, id)` 主键和 session 内唯一 `entry_seq`。
- `Session.setLeafId()` 追加 `leaf` entry；leaf entry 的 `targetId` 成为当前 leaf，而 leaf marker 自身不进入目标分支的 context path。
- entry、序号、物化统计、当前 leaf 和 branch path 在一个 SQLite 事务内更新。
- `branch_entries` 缓存多条 root-to-tip 路径，`branch_tips` 保存 tip 与 branch 的一对一关系。两表都是可丢弃投影，权威 parent chain 在 `session_entries`。
- bounded branch query 优先使用 branch cache，缓存缺失或无效时从 parent chain 重建。
- malformed entry 在 read entry、page、branch 和 context 路径中返回 `invalid_entry`，不再静默跳过。
- `session_search_fts` 只在显式创建 SQLite search adapter 时建立；它对 payload 做大小写不敏感 trigram 子串搜索，并通过 trigger 与 canonical append/delete 同事务。

源码证据：

- [`001_initial.sql`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/migrations/001_initial.sql#L1-L59) / [`002_branch_tips.sql`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/migrations/002_branch_tips.sql#L1-L12)
- [`appendEntry()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/index.ts#L367-L418)
- [`branch-cache.ts`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/branch-cache.ts#L1-L326)
- [`search-backend.ts`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/search-backend.ts#L32-L124)
- [`SQLite FTS5 search parity tests`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/test/harness/sqlite-node.test.ts#L49-L164)

### 3.5 Branch summary 和 fork

branch summary 从旧 leaf 向上收集到与目标路径的最深 common ancestor，然后按时间顺序生成摘要。`moveTo()` 先持久化目标 leaf；有 summary 时再把 `branch_summary` 挂到目标 entry 一侧。

fork 的默认 position 是 `before`：目标必须是 user message，并使用其 parent 作为有效 leaf。`at` 则包含目标 entry。SQLite repo 把选定路径复制到新会话。

源码证据：

- [`collectEntriesForBranchSummary()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/src/harness/compaction/branch-summarization.ts#L70-L100)
- [`readSessionEntriesForFork()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/src/harness/session/repository.ts#L49-L71)
- [`SqliteSessionRepository.fork()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/repo.ts#L171-L194)

### 3.6 观察行为、目标选择和理由

| 主题 | 观察到的 pi 行为 | Java/GaussDB 目标 | 分类与理由 |
|---|---|---|---|
| 事实源 | coding-agent 使用 JSONL；新 harness 支持可插拔存储 | GaussDB `session_entry` | 架构改造：提供事务和并发访问 |
| leaf | 旧 runtime 只在内存移动；新 harness/SQLite 写 `leaf` entry | 采用 `leaf` entry + `agent_session.active_leaf_entry_id` | pi 新存储语义对齐 |
| compaction | 新 harness 支持 `retainedTail`，兼容 `firstKeptEntryId` | 两种格式均可读取 | 兼容约束 |
| active path | SQLite 使用 `branch_entries + branch_tips` 缓存 root-to-tip 路径 | 保留对应缓存表，递归 CTE 只用于缺失/损坏修复 | SQLite 行为对齐 |
| bounded branch query | 缓存支持 stop/type/order/limit | 提供同等 Repository 查询 | SQLite 行为对齐 |
| malformed entry | SQLite 当前读取失败并返回 `invalid_entry` | context、page 和 branch query 失败并报告 entry | SQLite 行为对齐 |
| entry payload | `session_entries.payload` 是 JSON TEXT，也是 FTS external content | 保留 SQLite-compatible JSON TEXT | 搜索输入与解码行为对齐 |
| search | 可选 FTS5 trigram adapter，支持子串和 cwd 过滤 | 可选 search projection，保证命中集和 cwd 过滤对齐 | 产品能力对齐；索引技术是架构差异 |
| 并发 | pi 主要依赖单进程顺序控制 | 行锁 + revision + expected leaf | 可靠性强化 |
| 多租户 | pi 无租户概念 | 不增加租户模型 | 产品约束 |
| 长期记忆 | pi 无内建跨会话抽取和召回 | 本 SR 不新增 | 产品范围约束 |

## 4. Java 目标行为

### 4.1 创建和打开

创建会话时，在同一事务中写入 `agent_session`、`session_sequence`、空的 `session_materialized` 和 committed create operation。初始 `active_leaf_entry_id=NULL`、`revision=0`、`next_append_seq=1`。

打开会话只读取 header/head、`session_materialized` 和 `entry_materialized`，不预加载全部 entry。context、branch query 和 append-order 分页分别通过 Repository 查询，与当前 `SqliteSessionConnection.open()` 对齐。

### 4.2 追加 entry

普通 append 在一个短事务中：

1. 识别或建立 `session_write_operation`。
2. 锁定 `agent_session`。
3. 校验 expected revision 和 expected leaf。
4. 从 `session_sequence` 分配 `next_append_seq` 并插入不可变 `session_entry`。
5. 按 SQLite projector 规则更新 `session_materialized` 和 `entry_materialized`。
6. 更新 `agent_session.active_leaf_entry_id`、revision 和 sequence。
7. 维护 `branch_entry + branch_tip`；必要时从 parent chain 修复。
8. 搜索功能启用时同事务更新 `session_search_document`。
9. 保存稳定响应并提交。

LLM、工具、网络调用和文件操作不在该事务中执行。

### 4.3 显式 leaf 移动

`moveTo(targetId)` 验证目标属于当前会话，然后追加一个 `leaf` entry：

- `leaf.parentId` 是移动前 current leaf。
- `leaf.payload.targetId` 是目标 entry，允许为 `null`。
- `agent_session.active_leaf_entry_id` 更新为目标，而不是 leaf marker。
- leaf marker 进入追加日志和审计，但不进入模型 context path。

有 branch summary 时，同一提交事务内先写 leaf marker，再写 parent 为目标 entry 的 `branch_summary`，最终 current leaf 指向 summary entry。该目标侧挂载与 pi 一致；单事务提交是 Java 可靠性强化。

### 4.4 Context rebuild

Context rebuild 获取稳定的 SQLite 等价 branch path 及 session revision：

1. 使用 `branch_entry` 查找 leaf 对应的 root-to-tip cache，并校验连续 parent chain。
2. 从最新 compaction 向前计算起点；`retainedTail` 从 compaction 开始，旧格式从 `firstKeptEntryId` 开始。
3. 缓存缺失或失效时，从 `session_entry.parent_entry_id` 递归获取权威路径，修复缓存后应用同样的 compaction trim。
4. 从返回的 trimmed path 推导 model、thinking level 和 active tools。
5. 投影 message、custom message、compaction 和 branch summary；`custom` 仅通过注册 projector 产生消息。

返回的 `ContextSnapshot` 包含 `sessionId`、`revision`、`leafEntryId`、trimmed path 标识及最终 runtime context。

### 4.5 Compaction 和 branch summary

Coordinator 从不可变 `ContextSnapshot` 准备摘要输入，在数据库事务外调用模型。提交摘要时重新锁定 `agent_session`：

- revision 和 leaf 均相同：写入摘要 entry 和投影，更新 session head。
- 任一不同：不保存过期结果，返回 `STALE_CONTEXT_SNAPSHOT`。

重试必须读取新 snapshot 并重新计算 cut point 或 common ancestor，不能复用旧的 `firstKeptEntryId`、`retainedTail` 或目标路径。

### 4.6 Fork

fork 在源 session revision 稳定时读取选定路径，再创建新 session：

- 未指定 entry 时复制源 session 的全部追加 entry，与 pi repo 行为一致。
- `before` 只接受 user message，并以其 parent 为有效 leaf。
- `at` 包含目标 entry。
- 复制 entry 保留原 entry id 和 timestamp，在新 session 中重新分配 `append_seq`。
- 新 session 的 `parent_session_id` 指向源 session。
- fork 事务写入新 header/head、entries、sequence、materialized projections、branch cache、search projection 和 operation；源 session 不变。

## 5. 目标架构和 JDBC

### 5.1 组件职责

| 组件 | 职责 |
|---|---|
| Agent Runtime | 驱动 turn、工具和 LLM，不直接访问数据库 |
| `MemorySessionApplicationService` | 编排 session、append、move、fork、context 和迁移 |
| `ContextRebuilder` | 将 SQLite 等价的 compaction-trimmed path 确定性投影为 runtime context |
| `CompactionCoordinator` | 准备 snapshot、生成摘要、提交 compaction |
| `BranchSummaryCoordinator` | 计算分支差异、生成摘要、提交目标侧 entry |
| `SessionRepository` | header/head、列表、materialized summary 和 fork 查询 |
| `EntryRepository` | entry 追加、append-order 分页、路径和 entry projection |
| `BranchCacheRepository` | root-to-tip cache、bounded branch query、校验和递归修复 |
| `SessionSearchRepository` | 子串搜索、`cwd` 过滤和 search projection |
| `WriteOperationRepository` | 幂等操作、稳定响应和冲突识别 |
| `GaussDbJdbcAdapter` | JDBC 事务、SQLState 映射、JSONB 编解码 |
| GaussDB | 会话事实源、状态与查询投影 |

![Append, move, and summary transaction](./diagrams/memory/memory-write-transaction.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L67)

### 5.2 Java 模块边界

```text
memory.api
  MemorySessionApplicationService
  command/*
  view/*

memory.domain
  SessionHeader
  SessionHead
  SessionSequence
  SessionMaterializedState
  SessionEntry
  ContextSnapshot
  MemoryError
  SessionEntryCodec

memory.application
  ContextRebuilder
  CompactionCoordinator
  BranchSummaryCoordinator
  SessionImportService

memory.infrastructure.gaussdb
  GaussDbSessionRepository
  GaussDbEntryRepository
  GaussDbBranchCacheRepository
  GaussDbSessionSearchRepository
  GaussDbWriteOperationRepository
  GaussDbTransactionManager
  JsonbJdbcCodec
  GaussDbSqlStateMapper
```

领域层和 Application Service 不导入 openGauss 类型。只有 `memory.infrastructure.gaussdb` 可以依赖驱动特有类。

### 5.3 驱动与连接契约

| 项目 | 固定选择 |
|---|---|
| Maven 坐标 | `org.opengauss:opengauss-jdbc:6.0.0-htrunks.csi.gaussdb_kernel.opengaussjdbc.r1` |
| 驱动类 | `org.opengauss.Driver` |
| URL | `jdbc:opengauss://host:port/database` |
| Java 边界 | `DataSource`、`Connection`、`PreparedStatement`、`ResultSet` |
| JSONB | 统一通过 `JsonbJdbcCodec` 绑定和读取 |
| Schema | 显式版本化迁移，不允许 ORM 自动创建或变更 |

定制版本来自内部制品仓库，不允许解析失败后自动回退到其他 openGauss JDBC 或 PostgreSQL JDBC。应用依赖树排除 `org.postgresql:postgresql`，避免同一 JVM 中的驱动冲突。

JDBC 版本不等同于 GaussDB 服务端版本。部署清单必须分别记录服务端版本、驱动 JAR 文件摘要和 Maven 坐标。

连接 URL、用户名、密码、TLS、连接超时、statement timeout、连接池大小和健康检查参数由部署配置提供，不写入领域对象或数据库 metadata。启动流程先加载驱动，再建立连接并校验 `memory_schema_version`；应用账号无 DDL 权限。

`JsonbJdbcCodec` 是唯一允许使用驱动特有 JSON/OTHER 类型的适配器。具体绑定 API必须以该定制 JAR 的实际公开类型为准，不从其他 openGauss 版本推断。

### 5.4 Schema 迁移

- 每个发布包携带顺序、不可变 SQL migration。
- 独立迁移身份执行 DDL；运行身份只执行 DML。
- `memory_schema_version` 每个 migration 一行，记录 migration id、顺序版本和 SHA-256，与 SQLite `migrations` 的逐文件记录对齐。
- 应用启动只验证版本，不自动升级。
- migration 失败必须整体回滚；不支持事务的 DDL 必须在发布脚本中明确补偿步骤。

## 6. 逻辑数据模型

| pi SQLite | openGauss/GaussDB | 对齐说明 |
|---|---|---|
| `migrations` | `memory_schema_version` | 逐 migration 记录，目标额外保存顺序版本和 SHA-256 |
| `sessions` | `agent_session` | header、nullable metadata、active leaf 一致；目标额外保存 revision |
| `session_entries` | `session_entry` | 相同复合主键、append sequence、parent、type、timestamp 和 payload |
| `session_sequences` | `session_sequence` | 每 session 一行 next sequence |
| `session_materialized` | `session_materialized` | 相同 append-log summary payload |
| `entry_materialized` | `entry_materialized` | 相同 append-order label projection |
| `branch_entries` | `branch_entry` | 相同 root-to-tip 路径成员缓存 |
| `branch_tips` | `branch_tip` | 相同 tip/branch 一对一关系 |
| `session_search_fts` | `session_search_document` | 命中集对齐；索引技术不直接复制 FTS5 |
| 无 | `session_write_operation` | openGauss 幂等和并发扩展 |

SQLite 的 metadata 和 materialized payload 虽然物理类型也是 TEXT，但公开行为是解析后的对象；目标 JSONB 以结构等价作为契约。`session_entries.payload` 是例外，因为 FTS5 直接索引原始文本，所以目标继续使用 TEXT。

### 6.1 `agent_session`

对应 SQLite `sessions`，保存会话 id、created time、cwd、parent session、nullable metadata 和 active leaf。`revision` 是 openGauss 并发扩展，与该行一起锁定；它不改变 SQLite 的业务返回。

`parent_session_id` 保留逻辑引用而不声明外键，以对齐 SQLite 删除父会话后子会话仍保留原 parent id 的可观察行为。这是对齐约束，不应自动 `SET NULL`。

### 6.2 `session_sequence`

一对一对应 SQLite `session_sequences`。`next_append_seq` 在已锁定 `agent_session` 的事务内读取和递增，不依赖 `MAX(append_seq)`。

### 6.3 `session_materialized`

一对一对应 SQLite 同名表。`payload JSONB` 保存 name、messageCount、cachedTokens、uncachedTokens、totalTokens、costTotal、currentModel 和 currentThinkingLevel。这些字段按全部 append log 累计，不是活动分支的 context 事实。

Java projector 必须复用 pi `applyEntryToMaterializedState()` 的相同规则。重建时按 `append_seq` 重放，不从活动 branch 统计。

### 6.4 `entry_materialized`

对应 SQLite 同名表，保存 append-order 的 entry-level projection。v1 只写 `projection_type='label'`，包括设置和清除 label 的历史行；open 时按 `append_seq` 重放得到当前 `labelsById`。不用仅保存当前非空值的 `session_label` 替代，避免与 SQLite 投影形态分叉。

### 6.5 `session_entry`

不可变会话事实表。固定列保存身份、树关系、类型、顺序和时间；`payload TEXT` 保存与 SQLite `encodeEntry()` 相同的 type-specific JSON 文本及未知扩展字段。读取时先解析并验证 payload，再通过固定列重建完整 `SessionTreeEntry`。

entry payload 使用 TEXT 是有意的 SQLite 对齐约束：搜索索引的 external content 正是该原始文本。Java `SessionEntryCodec` 必须输出与 `JSON.stringify(entryToPayload(entry))` 等价的 UTF-8 字符序列；SQLite 导入保留源 payload 原文。对外契约比较解码后的 JSON 结构和搜索结果，不承诺把 JSON 字段顺序或空白作为公共 API；但投影重建不得先把 payload 转成 JSONB 再序列化，因为这会改变 SQLite 的子串搜索输入。

`operation_id` 把本次写入关联到幂等命令。普通 append 写一条 entry；带摘要的 move 可在同一 operation 下写 leaf marker 和 branch summary 两条 entry。

### 6.6 `branch_entry` 和 `branch_tip`

两表对应 SQLite `branch_entries` 和 `branch_tips`：

- 每个 branch id 表示一条 root-to-tip 缓存路径，共享前缀在不同 branch 中重复存储。
- `branch_tip` 保证一个 tip 对应一个 branch，一个 branch 只有一个 tip。
- 线性 append 扩展当前 tip；从旧 parent 分叉时复制该 parent 之前的缓存前缀。
- 校验失败时删除对应 branch，通过 recursive parent query 重建。
- 两表只是投影；导入和恢复不把它们当作事实源。

### 6.7 `session_write_operation`

保存写命令的幂等键、规范化请求 SHA-256、状态和稳定响应。`started`、entry、session head、投影和最终 `committed` 在同一事务内，因此回滚后不会留下可见半完成行。

### 6.8 `session_search_document`

完整 SQLite 对齐 profile 安装 search migration 后，每个 entry 一行保存由 canonical `session_entry.payload` 派生的 FTS5-compatible normalization。append/delete 与该投影同事务；投影写失败必须回滚 canonical entry 变更。不提供 search 的精简部署可不安装该 migration，但不得标记为完整 SQLite 对齐。

当前对齐基线要求 SQLite FTS5 `trigram remove_diacritics 1` 的 quoted phrase 行为：trim 后空 query 返回空集合；`"auth"`、`"AUTH"` 和 `"uth"` 命中同一 payload；不足一个 trigram 的 query 不命中；`cwd` 过滤和删除后不可见保持一致。`SqliteFts5TrigramNormalizer` 在 Java 中统一处理 query 和 payload，并由真实 SQLite oracle 语料锁定 Unicode case fold、去重音符、引号、标点和最小长度边界。

GaussDB/openGauss `tsvector + GIN` 可用于全文索引，但其 parser 不能直接证明与 SQLite FTS5 trigram 等价。v1 对预归一化文本执行参数化子串匹配；任何 GIN 加速必须在 parity suite 通过后才可启用，并保留相同的 post-filter。

### 6.9 数据关系

![Session event plane data model](./diagrams/memory/memory-data-model.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L135)

## 7. 集中式 GaussDB DDL 草案

以下是完整 SQLite 对齐 profile 的 target-only migration v1，其中 `session_search_document` 可拆为显式 search migration。上线前必须在实际集中式 GaussDB 版本和指定 JDBC JAR 上执行兼容性测试。

```sql
CREATE TABLE memory_schema_version (
    component           VARCHAR(64)  NOT NULL,
    schema_version      INTEGER      NOT NULL,
    migration_id        VARCHAR(128) NOT NULL,
    migration_checksum  CHAR(64)     NOT NULL,
    installed_at        TIMESTAMPTZ  NOT NULL,
    PRIMARY KEY (component, schema_version),
    UNIQUE (component, migration_id),
    CHECK (schema_version > 0),
    CHECK (LENGTH(migration_checksum) = 64)
);

CREATE TABLE agent_session (
    session_id            VARCHAR(128) NOT NULL,
    created_at            TIMESTAMPTZ  NOT NULL,
    cwd                   TEXT         NOT NULL,
    parent_session_id     VARCHAR(128),
    metadata              JSONB,
    active_leaf_entry_id  VARCHAR(128),
    revision              BIGINT       NOT NULL DEFAULT 0,
    PRIMARY KEY (session_id),
    CHECK (revision >= 0)
);

CREATE TABLE session_write_operation (
    operation_id    VARCHAR(128) NOT NULL,
    session_id      VARCHAR(128) NOT NULL,
    operation_type  VARCHAR(32)  NOT NULL,
    request_hash    CHAR(64)     NOT NULL,
    status          VARCHAR(16)  NOT NULL,
    result_payload  JSONB,
    started_at      TIMESTAMPTZ  NOT NULL,
    committed_at    TIMESTAMPTZ,
    PRIMARY KEY (operation_id),
    UNIQUE (session_id, operation_id),
    CHECK (operation_type IN (
        'create', 'append', 'move', 'compaction',
        'branch_summary', 'fork', 'delete', 'import'
    )),
    CHECK (
        (status = 'started'
            AND result_payload IS NULL
            AND committed_at IS NULL)
        OR
        (status = 'committed'
            AND result_payload IS NOT NULL
            AND committed_at IS NOT NULL)
    )
);

CREATE TABLE session_entry (
    session_id       VARCHAR(128) NOT NULL,
    entry_id         VARCHAR(128) NOT NULL,
    parent_entry_id  VARCHAR(128),
    append_seq       BIGINT       NOT NULL,
    entry_type       VARCHAR(64)  NOT NULL,
    event_time       TIMESTAMPTZ  NOT NULL,
    payload          TEXT         NOT NULL,
    operation_id     VARCHAR(128) NOT NULL,
    PRIMARY KEY (session_id, entry_id),
    UNIQUE (session_id, append_seq),
    FOREIGN KEY (session_id)
        REFERENCES agent_session (session_id)
        ON DELETE CASCADE,
    FOREIGN KEY (session_id, parent_entry_id)
        REFERENCES session_entry (session_id, entry_id),
    FOREIGN KEY (session_id, operation_id)
        REFERENCES session_write_operation (session_id, operation_id),
    CHECK (append_seq > 0),
    CHECK (parent_entry_id IS NULL OR parent_entry_id <> entry_id),
    CHECK (entry_type IN (
        'message',
        'thinking_level_change',
        'model_change',
        'active_tools_change',
        'compaction',
        'branch_summary',
        'custom',
        'custom_message',
        'label',
        'session_info',
        'leaf'
    ))
);

CREATE TABLE session_sequence (
    session_id       VARCHAR(128) NOT NULL,
    next_append_seq  BIGINT       NOT NULL,
    PRIMARY KEY (session_id),
    FOREIGN KEY (session_id)
        REFERENCES agent_session (session_id)
        ON DELETE CASCADE,
    CHECK (next_append_seq > 0)
);

CREATE TABLE session_materialized (
    session_id  VARCHAR(128) NOT NULL,
    payload     JSONB        NOT NULL,
    PRIMARY KEY (session_id),
    FOREIGN KEY (session_id)
        REFERENCES agent_session (session_id)
        ON DELETE CASCADE,
    CHECK (JSONB_TYPEOF(payload) = 'object')
);

CREATE TABLE entry_materialized (
    session_id      VARCHAR(128) NOT NULL,
    append_seq      BIGINT       NOT NULL,
    projection_type VARCHAR(64)   NOT NULL,
    payload         JSONB         NOT NULL,
    PRIMARY KEY (session_id, append_seq, projection_type),
    FOREIGN KEY (session_id, append_seq)
        REFERENCES session_entry (session_id, append_seq)
        ON DELETE CASCADE,
    CHECK (projection_type IN ('label')),
    CHECK (JSONB_TYPEOF(payload) = 'object')
);

CREATE TABLE branch_entry (
    session_id  VARCHAR(128) NOT NULL,
    branch_id   VARCHAR(128) NOT NULL,
    entry_id    VARCHAR(128) NOT NULL,
    append_seq  BIGINT       NOT NULL,
    PRIMARY KEY (session_id, branch_id, entry_id),
    FOREIGN KEY (session_id, entry_id)
        REFERENCES session_entry (session_id, entry_id)
        ON DELETE CASCADE
);

CREATE TABLE branch_tip (
    session_id  VARCHAR(128) NOT NULL,
    tip_id      VARCHAR(128) NOT NULL,
    branch_id   VARCHAR(128) NOT NULL,
    PRIMARY KEY (session_id, tip_id),
    UNIQUE (session_id, branch_id),
    FOREIGN KEY (session_id, tip_id)
        REFERENCES session_entry (session_id, entry_id)
        ON DELETE CASCADE
);

CREATE TABLE session_search_document (
    session_id       VARCHAR(128) NOT NULL,
    entry_id         VARCHAR(128) NOT NULL,
    normalized_text  TEXT         NOT NULL,
    PRIMARY KEY (session_id, entry_id),
    FOREIGN KEY (session_id, entry_id)
        REFERENCES session_entry (session_id, entry_id)
        ON DELETE CASCADE
);

CREATE INDEX idx_agent_session_created
    ON agent_session (created_at DESC, session_id);

CREATE INDEX idx_agent_session_parent
    ON agent_session (parent_session_id);

CREATE INDEX idx_agent_session_cwd_created
    ON agent_session (cwd, created_at DESC, session_id);

CREATE INDEX idx_session_entry_parent
    ON session_entry (session_id, parent_entry_id);

CREATE INDEX idx_session_entry_type_seq
    ON session_entry (session_id, entry_type, append_seq);

CREATE INDEX idx_session_write_operation_session
    ON session_write_operation (session_id, started_at);

CREATE INDEX idx_entry_materialized_type_seq
    ON entry_materialized (session_id, projection_type, append_seq);

CREATE INDEX idx_branch_entry_branch_seq
    ON branch_entry (session_id, branch_id, append_seq);

CREATE INDEX idx_branch_entry_entry
    ON branch_entry (session_id, entry_id);

INSERT INTO memory_schema_version (
    component,
    schema_version,
    migration_id,
    migration_checksum,
    installed_at
) VALUES (
    'session-memory',
    1,
    '001_sqlite_alignment.sql',
    '0000000000000000000000000000000000000000000000000000000000000000',
    CURRENT_TIMESTAMP
);
```

`migration_checksum` 中的 64 个 `0` 仅是设计稿占位值。发布 migration 必须用最终 SQL 文件的实际 SHA-256 替换；启动校验不得接受占位值。

DDL 有意不包含：

- `tenant_id` 和任何多租户约束。
- `session_leaf_event`；`leaf` entry 已承担不可变导航事实。
- 独立的 `session_label` 和 `session_file_operation`；当前 SQLite 使用 generic `entry_materialized` 且不物化 file operation。
- entry payload 上的 JSONB GIN 索引；canonical payload 有意使用 TEXT，子串搜索使用专用 normalization projection。
- 分布式 `DISTRIBUTE BY`；当前数据库明确为集中式。

`session_write_operation.session_id` 有意不建立 session 外键，使 create 可以先占用幂等键，并使 delete 后仍能返回稳定结果。被 entry 引用的 operation 与 session entry 同生命周期；未被 entry 引用的 create/delete operation，以及 session 删除后成为孤立记录的 operation，按幂等保留期清理。`session_entry` 的复合外键保证 entry 与 operation 的 session 一致。

entry 的 type-specific 引用，例如 `leaf.targetId`、`label.targetId`、`compaction.firstKeptEntryId` 和 `branch_summary.fromId`，由 `SessionEntryCodec` 在写入前校验属于同一 session。entry projection、branch cache 和 search projection 另外使用数据库外键保护。`active_leaf_entry_id` 与 SQLite 一样使用逻辑引用；open/read 必须显式校验非空 leaf 存在，不建立会阻塞 session cascade delete 的循环外键。

## 8. 路径查询与 Context rebuild

### 8.1 Branch cache 优先读取

读取先获得 `agent_session.revision` 和 `active_leaf_entry_id`。leaf 为 null 时返回空路径；否则先按 `(session_id, entry_id)` 找到一个 cached branch，再按 `append_seq` 顺序读取。

Repository 必须校验：

- cache 包含请求 leaf，且 leaf sequence 与请求一致；
- 首行是 root，或者是已计算的 compaction start entry；
- 每一行 `parent_entry_id` 等于前一行 `entry_id`；
- cache 中每个 entry 在 canonical `session_entry` 中存在。

bounded branch query 在路径边界确定后再应用 `entry_type/customType` 过滤和 limit，并保留 SQLite `newestFirst` 默认、`oldestFirst`、`stopAtType` 和 `stopAtId` 语义。

### 8.2 Recursive repair

cache 缺失或校验失败时，使用权威 parent chain 修复：

```sql
WITH RECURSIVE canonical_path AS (
    SELECT
        e.session_id,
        e.entry_id,
        e.parent_entry_id,
        e.append_seq,
        e.entry_type,
        e.event_time,
        e.payload,
        0 AS depth
    FROM agent_session s
    JOIN session_entry e
      ON e.session_id = s.session_id
     AND e.entry_id = s.active_leaf_entry_id
    WHERE s.session_id = ?

    UNION ALL

    SELECT
        parent.session_id,
        parent.entry_id,
        parent.parent_entry_id,
        parent.append_seq,
        parent.entry_type,
        parent.event_time,
        parent.payload,
        child.depth + 1
    FROM canonical_path child
    JOIN session_entry parent
      ON parent.session_id = child.session_id
     AND parent.entry_id = child.parent_entry_id
)
SELECT
    session_id,
    entry_id,
    parent_entry_id,
    append_seq,
    entry_type,
    event_time,
    payload
FROM canonical_path
ORDER BY depth DESC;
```

递归结果必须检测 cycle、缺失 parent、最大深度和 statement timeout。合法结果在 savepoint 内替换旧 branch cache 并写入新 `branch_tip`；修复失败不得破坏 canonical entry。

### 8.3 Context 投影

```text
cachedPath = validatedBranchCacheOrRecursiveRepair(activeLeaf)
trimmedPath = trimPathToRootOrCompaction(cachedPath)
state = deriveModelThinkingAndTools(trimmedPath)
contextEntries = defaultContextEntryTransform(trimmedPath)
messages = project(contextEntries)
```

`trimPathToRootOrCompaction()` 和 `defaultContextEntryTransform()` 必须与 pi 同源 parity test 对齐。`project(compaction)` 输出 summary message 后紧接 stored `retainedTail`。`leaf`、label、session info、model/thinking/tools change 不直接产生模型消息。

### 8.4 Search 命中集对齐

空白 query 在 Repository 边界直接返回空集合。v1 使用参数化子串查询保证 SQLite FTS5 trigram 用例的命中集：

```sql
SELECT
    s.session_id,
    e.entry_id,
    e.event_time
FROM session_search_document d
JOIN session_entry e
  ON e.session_id = d.session_id
 AND e.entry_id = d.entry_id
JOIN agent_session s
  ON s.session_id = d.session_id
WHERE POSITION(? IN d.normalized_text) > 0
  AND (? IS NULL OR s.cwd = ?)
ORDER BY e.event_time, s.session_id, e.entry_id;
```

传入第一个参数前，Repository trim query 并调用与写路径相同的 `SqliteFts5TrigramNormalizer`；没有产生 trigram 时直接返回空集合。返回的 entry id 集合和 `cwd` 过滤必须与 SQLite 一致。SQLite BM25 与 openGauss 排序分数不作数值等价承诺；Java API 使用上述稳定 tie-break，score 可为空。如后续使用 `tsvector/GIN`，必须先用归一化子串条件做 parity post-filter。

![Database context rebuild](./diagrams/memory/memory-context-rebuild.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L265)

## 9. 事务、并发和幂等

### 9.1 通用写事务

![Write transaction sequence](./diagrams/memory/memory-write-transaction.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L67)

```text
BEGIN
  INSERT session_write_operation(status = started)
    ON CONFLICT (operation_id) DO NOTHING

  if operation already exists:
    verify session_id, operation_type, request_hash
    if committed:
      return stored result after transaction completes

  SELECT agent_session
    WHERE session_id = ?
    FOR UPDATE

  verify expected_revision
  verify expected_leaf_entry_id
  validate all referenced entries
  read and advance session_sequence
  INSERT immutable session_entry row(s)
  update session_materialized/entry_materialized
  update agent_session active leaf and revision
  extend or rebuild branch_entry/branch_tip
  update session_search_document when search is enabled
  UPDATE session_write_operation to committed
COMMIT
```

相同 operation id、相同 request hash 的 retry 返回首次成功结果。operation id 已存在但 session、type 或 request hash 不同，返回 `IDEMPOTENCY_KEY_REUSE`。唯一键冲突由数据库等待首次事务完成：首次事务回滚后 retry 可重新建立 operation。

`request_hash` 是规范化命令 JSON 的 SHA-256：包含 command type、session id、expected revision、expected leaf 和全部业务 payload；排除 operation id、trace id、认证信息及其他传输 metadata。规范化使用 UTF-8、对象 key 字典序和稳定的数字/空值编码。

### 9.2 Revision 语义

- revision 初始为 0。
- 每个成功修改会话状态的 Application Service 命令递增一次。
- 一个 branch-summary 命令即使写 leaf marker 和 summary 两条 entry，也只递增一次。
- 只读查询、列表和导出不改变 revision。
- expected revision 或 expected leaf 不匹配返回 `REVISION_CONFLICT`。
- 摘要结果提交时快照不匹配返回更具体的 `STALE_CONTEXT_SNAPSHOT`。

### 9.3 投影一致性和重建

投影与 entry 在同一事务中更新。`ProjectionRebuilder` 在维护窗口内按 `append_seq` 重放 entry 到临时表，校验计数和摘要后原子切换或覆盖 `session_materialized`、`entry_materialized`、branch cache 和 search projection。重建不改 entry、active leaf、revision 或 operation。

损坏 payload 的策略：

- 新写入在事务前由 `SessionEntryCodec` 拒绝，返回 `INVALID_ENTRY`。
- 已持久化损坏 entry 在 read、page、branch query 和 context rebuild 中返回 `INVALID_ENTRY`，不返回部分结果。
- 该行为与当前 SQLite `decodeEntryRows()` 和 `readEntry()` 对齐；不支持旧基线中的静默 skip。

## 10. Java 接口和错误

### 10.1 Application Service

```java
interface MemorySessionApplicationService {
    SessionView createSession(CreateSessionCommand command);
    SessionView openSession(String sessionId);
    List<SessionSummary> listSessions(SessionListQuery query);
    void deleteSession(DeleteSessionCommand command);
    SessionView forkSession(ForkSessionCommand command);
    AppendResult appendEntry(AppendEntryCommand command);
    MoveResult moveTo(MoveToCommand command);
    ContextSnapshot loadContext(LoadContextQuery query);
    EntryPage pageEntries(EntryPageQuery query);
    List<SessionEntryView> findEntriesOnBranch(BranchEntryQuery query);
    List<SessionSearchHit> searchSessions(SessionSearchQuery query);
}
```

这是公共领域契约，不暴露 JDBC、SQLState、JSONB driver object 或数据库行类型。

### 10.2 命令并发字段

| 命令 | operation id | expected revision | expected leaf |
|---|---:|---:|---:|
| create | 必须 | 固定为 0 | 固定为 null |
| append | 必须 | 必须 | 必须，可为 null |
| move / branch summary | 必须 | 必须 | 必须，可为 null |
| compaction commit | 必须 | snapshot revision | snapshot leaf |
| fork | 必须 | 源 session revision | 源 session leaf |
| delete | 必须 | 必须 | 必须，可为 null |
| import | 必须 | 固定为 0 | 固定为 null |

delete 对已删除 session 的同 operation retry 返回首次稳定结果；`session_write_operation` 不随 session 删除，并在幂等保留期结束后清理。

### 10.3 稳定错误

| 错误 | 触发条件 |
|---|---|
| `NOT_FOUND` | session 或目标 entry 不存在 |
| `INVALID_ENTRY` | payload、类型、引用、路径或 projection 无效 |
| `INVALID_FORK_TARGET` | before 目标不是 user message，或目标不可达 |
| `REVISION_CONFLICT` | expected revision/leaf 与 session head 不一致 |
| `IDEMPOTENCY_KEY_REUSE` | operation id 对应不同规范化请求 |
| `STALE_CONTEXT_SNAPSHOT` | 摘要生成期间 revision 或 leaf 变化 |
| `STORAGE_ERROR` | JDBC、超时、连接或无法分类的数据库错误 |

`GaussDbSqlStateMapper` 负责把唯一键、外键、锁超时、事务回滚、连接故障和 statement timeout 映射为稳定错误，不把数据库错误文本直接返回客户端。

## 11. 迁移、发布和运维

### 11.1 JSONL 导入

1. 解析 header 和 v1-v3 entry。
2. 为 header 创建 session。
3. 按文件顺序分配 `append_seq`，保留原 timestamp。
4. 把 base 字段写入固定列，其余字段写入 payload。
5. 校验 parent、firstKept、fromId、label target 和 leaf target。
6. 重建 materialized summary、label entry projection、branch cache 和 search projection。
7. current leaf 默认取最后 entry；如果文件含新 harness leaf entry，则按 leaf target 计算。
8. 生成 entry 数、内容 hash、孤儿和解析错误报告。

旧 coding-agent JSONL 不记录“最后一次只移动 leaf”的状态，导入器不得伪造该 leaf；报告中标记 `UNRECOVERABLE_LEAF_MOVE`。

### 11.2 SQLite 导入

- 以 `sessions`、`session_entries` 和 `active_leaf_id` 为事实来源。
- 按 `entry_seq` 导入，保留 entry id、parent、timestamp 和 payload。
- 导入 `leaf` 和 `retainedTail`。
- `branch_entries`、`branch_tips`、`session_materialized`、`entry_materialized` 和 `session_search_fts` 不直接复制，但必须从 canonical session/entry 重建为等价 openGauss 投影。
- 校验源 active leaf 与重放 leaf entry 得到的状态；不一致时停止该 session 导入。
- 对比源/目标 materialized payload、每条 branch tip 的 root-to-tip entry id 集合和 search 命中集。

### 11.3 导出和回滚

按 `append_seq` 重建 JSONL header 和完整 entry。数据库保持唯一写入事实源，不启用长期双写。迁移切换前保留原 JSONL/SQLite 只读副本；回滚通过受控导出或切回未被修改的源副本完成。

### 11.4 发布阶段

| 阶段 | 完成条件 |
|---|---|
| M0 | migration、权限、JDBC compatibility suite 通过 |
| M1 | 历史数据影子导入，entry/hash/context parity 通过 |
| M2 | 生产请求同时计算旧/新 read result，只返回旧结果并记录差异 |
| M3 | 切换 GaussDB 读取；写入只进入 GaussDB |
| M4 | 停止旧存储写入，保留受控导出和恢复副本 |

### 11.5 指标和告警

- append、move、compaction commit 延迟和失败率。
- revision conflict、stale snapshot 和 idempotency hit 数量。
- context path 深度、查询耗时、rebuild 耗时和输出消息数。
- branch cache hit/repair/invalid 数、每 branch 行数和分支前缀写放大。
- search 查询耗时、扫描行数、命中数和 SQLite/GaussDB 命中集差异。
- JSONB metadata/materialized payload、TEXT entry payload、session entry 数和单次 import 大小。
- projection rebuild 差异和 migration parity 失败。
- JDBC pool exhausted、连接失败、锁等待和 statement timeout。

## 12. 安全

虽然不设计多租户，仍执行以下安全强化：

- 数据库连接强制 TLS，凭据来自部署 secret，不写入 metadata、payload 或日志。
- 运行账号最小权限，禁止 DDL、用户管理和任意 schema 访问。
- payload 禁止 API key、OAuth token、cookie 和完整 authorization header。
- prompt、summary、tool result 和 file path 默认不进入普通日志；诊断日志脱敏并限制长度。
- 限制单 entry payload、retained tail、summary、路径深度、导入文件和单 session entry 数。
- JDBC 使用参数化 SQL；表名、列名和排序字段不从请求直接拼接。
- 备份、导出和临时文件使用平台加密与访问审计。

## 13. 测试与验收

### 13.1 pi parity

- 所有 11 种 entry 的编码、解码、分页和回放。
- 无 compaction、单次/重复 compaction、`retainedTail` 和旧 `firstKeptEntryId`。
- split turn、tool result 不能作为 cut point、previous summary 增量更新。
- branch common ancestor、旧路径摘要、目标侧 summary 挂载。
- custom 默认不进入 context，custom projector 和 custom message 正确投影。
- model、thinking level 和 active tools 从 SQLite 等价的 compaction-trimmed path 推导。
- fork 默认 before、显式 at、非法目标和 entry id 保留。
- bounded branch query 的 stopAtType、stopAtId、type、customType、order 和 limit 组合。
- branch cache 缺失、断链、错误 tip 和循环时的失败/修复结果。
- search 对 `auth`/`AUTH`/`uth`、不足 3 个 Unicode code point 的查询、组合/预组字符、中文、引号、标点、空查询和 `cwd` 过滤的命中集对齐。

### 13.2 数据库事务

- append 的 entry、sequence、materialized state、leaf、branch cache、search、operation 原子提交或回滚。
- move 写 leaf marker，但 `agent_session.active_leaf_entry_id` 指向 target。
- 带 summary 的 move 在一次命令中写两个 entry，只增加一次 revision。
- 同 operation 并发 retry 只产生一组 entry。
- 相同 operation id 不同 hash 返回 `IDEMPOTENCY_KEY_REUSE`。
- revision/leaf 冲突、锁等待、statement timeout 和连接中断。
- projection 重建结果与在线投影一致。
- branch/search 投影写失败时 canonical append/delete 也回滚。

### 13.3 JDBC compatibility suite

必须使用精确版本 `6.0.0-htrunks.csi.gaussdb_kernel.opengaussjdbc.r1`，不允许用其他版本代测：

- `org.opengauss.Driver` 加载和 `jdbc:opengauss:` URL。
- TLS、认证、连接池 validation query 和 failover 后重连。
- JSONB metadata/materialized state 的 insert、update、null 和读取；TEXT entry payload 的 Unicode、大对象和原文保持。
- 递归 CTE、复合外键、`SELECT ... FOR UPDATE` 和事务回滚。
- 窗口函数、savepoint 和 branch cache 前缀 batch insert。
- 大小写折叠子串匹配；`tsvector/GIN` 只做可选加速，不代替命中集 parity。
- prepared statement、batch insert、JSONB 中的 cost 数值和 TIMESTAMPTZ。
- 唯一键、外键、锁超时、statement timeout 和连接错误的 SQLState 映射。
- schema migration 的事务性及重复执行保护。

### 13.4 迁移

- JSONL v1、v2、v3、新 harness leaf 和 retained tail。
- 当前 pi SQLite session、active leaf、labels、materialized state、branch tips 和 search 命中集。
- 缺失 parent、非法 firstKept、错误 leaf target、坏 JSON 和重复 entry。
- entry 数、规范化 hash、活动路径、context messages 和最终 state parity。
- 旧 JSONL 未持久化 leaf move 的限制报告。

### 13.5 验收标准

- 相同合法活动树输入产生与 pi harness 等价的 context messages 和状态。
- 任意成功写命令后，entry、sequence、materialized state、leaf、branch cache、search 和 operation 不存在部分可见状态。
- SQLite 和 GaussDB 对同一 branch query/search corpus 产生同一 entry id 命中集；排序 score 如有差异必须单独标注且不影响稳定 tie-break。
- 服务重启后可恢复显式 leaf move。
- 并发 retry 不产生重复 entry，过期摘要不能覆盖新分支。
- 文档中所有 DDL 在目标集中式 GaussDB 和指定 JDBC JAR 上通过 compatibility suite。
- 迁移 parity 不一致的 session 不允许进入切换清单。

## 14. 设计取舍

| ID | 问题 | 选择 | 分类 |
|---|---|---|---|
| TD-MEM-01 | 持久化介质 | 集中式 GaussDB | 架构改造 |
| TD-MEM-02 | JDBC | 锁定指定 openGauss JDBC 定制版本 | 产品约束 |
| TD-MEM-03 | leaf 审计 | 使用 pi `leaf` entry，不建独立 leaf event 表 | pi 新 harness 对齐 |
| TD-MEM-04 | current state | active leaf 保存在 `agent_session`，sequence 和 materialized state 按 SQLite 拆表 | SQLite 表行为对齐 |
| TD-MEM-05 | active path | 保留 branch entry/tip cache，递归 CTE 仅用于修复 | SQLite 表行为对齐 |
| TD-MEM-06 | compaction | `retainedTail` 为主，兼容 firstKept | 兼容约束 |
| TD-MEM-07 | 并发 | session 行锁 + revision + expected leaf + idempotency | 可靠性强化 |
| TD-MEM-08 | 损坏 entry | read/page/branch/context 失败，不静默跳过 | 当前 SQLite 行为对齐 |
| TD-MEM-09 | 多租户 | 不建模 | 产品范围约束 |
| TD-MEM-10 | 跨会话记忆 | 不建模，不增加向量索引 | 产品范围约束 |
| TD-MEM-11 | 原始 payload | 固定树列 + SQLite-compatible type-specific JSON TEXT | SQLite 搜索输入对齐 |
| TD-MEM-12 | 摘要事务 | 模型调用在事务外，提交时校验 snapshot | 架构改造 |
| TD-MEM-13 | entry projection | 保留 generic append-order `entry_materialized`，v1 只投影 label | SQLite 表行为对齐 |
| TD-MEM-14 | search | 命中集对齐 trigram 子串语义，索引实现可不同 | 产品能力对齐 + 架构差异 |

## 15. 官方能力依据

- [GaussDB 实例类型：集中式与分布式](https://support.huaweicloud.com/intl/en-us/productdesc-gaussdb/gaussdb_01_013.html)
- [GaussDB Centralized V2.0-3.x `WITH RECURSIVE`](https://support.huaweicloud.com/intl/en-us/centralized-devg-v3-gaussdb/gaussdb-42-0649.html)
- [openGauss 6.0 JDBC 驱动类与兼容说明](https://docs.opengauss.org/en/docs/6.0.0/docs/DeveloperGuide/jdbc-package-driver-class-and-environment-class.html)
- [openGauss 6.0 JDBC 驱动加载](https://docs.opengauss.org/en/docs/6.0.0/docs/DeveloperGuide/loading-the-driver-jdbc.html)
- [openGauss JSON/JSONB 类型](https://docs.opengauss.org/en/docs/latest/sql_reference/json_jsonb_types.html)
- [openGauss JSON/JSONB 函数和操作符](https://docs.opengauss.org/en/docs/latest/sql_reference/json_jsonb_functions_and_operators.html)
- [openGauss 全文检索基础匹配](https://docs.opengauss.org/en/docs/6.0.0/docs/SQLReference/basic-text-matching.html)
- [openGauss 使用 GIN 创建全文索引](https://docs.opengauss.org/en/docs/latest/sql_reference/creating_index.html)
- [GaussDB Centralized V2.0-8.x 文本搜索操作符](https://support.huaweicloud.com/intl/en-us/centralized-devg-v8-gaussdb/gaussdb-42-2028.html)

这些公开文档只能证明标准产品能力。定制 JDBC 版本 `6.0.0-htrunks.csi.gaussdb_kernel.opengaussjdbc.r1` 的二进制兼容性必须由第 13.3 节测试确认。

## 16. 版本记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v0.6 | 2026-08-03 | 更新 pi 基线至 `f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee`；将 openGauss/GaussDB 目标改为当前 SQLite 行为对齐；保留 sequence、materialized projection、branch entry/tip cache、bounded branch query 和 search；entry payload 改为 SQLite-compatible JSON TEXT，搜索由 SQLite FTS5 oracle 锁定；context 改为 compaction-trimmed path 语义；保留 revision/idempotency 作为明确可靠性扩展 |
| v0.5 | 2026-07-30 | 更新 pi 基线至 `fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc`；收敛为单租户会话内记忆；采用新 harness/SQLite 的 `leaf`、`active_tools_change` 和 `retainedTail`；数据库固定为集中式 GaussDB；锁定 openGauss JDBC 定制版本；以 state、operation 和可重建投影替代旧租户及 leaf event 模型 |
| v0.4 | 2026-07-20 | 将 SR 边界收敛为 Session Event Plane；基于主流 Agent 数据库调研明确拆分控制面、Runtime Checkpoint、跨会话长期记忆和 Artifact；为 Entry、Leaf Event、Write Operation 补齐复合外键与会话 revision 顺序；修正幂等操作先建记录再写结果的事务状态模型 |
| v0.3 | 2026-07-17 | 将 pi 源码基线更新为 `216e672e7c9fc65682553394b74e483c0c9e47f7`，重新核对记忆相关实现和源码锚点；确认 model runtime facade 变更未改变记忆语义 |
| v0.2 | 2026-07-16 | 为 DDL 草案中的全部表和字段补充数据库 COMMENT；不改变表结构和行为设计 |
| v0.1 | 2026-07-15 | 以 pi commit `dcfe36c79702ec240b146c45f167ab75ecddd205` 为基线，建立 Java ToB GaussDB 持久化、租户隔离、事务一致性、幂等和迁移设计；明确 Java target-only 差异 |
