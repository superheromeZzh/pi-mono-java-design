# CampusClaw Java 集中式 GaussDB Session 存储 SR 设计

> 文档编号：SR-MEM-001
> 版本：v0.13
> 日期：2026-08-06
> 状态：设计评审稿
> pi 源码基线：[`f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee`](https://github.com/badlogic/pi-mono/tree/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee)
> GaussDB 设计参考基线：本仓库 `7c63ff80551de1b87b35b3edcc3e75dcc03223d8`；[`agent-metadata-gaussdb-design/schema.sql`](./agent-metadata-gaussdb-design/schema.sql) 和 [`chat-ws-v2.asyncapi.yaml`](./pi-mono-java-manager-driven-multi-agent-runtime/chat-ws-v2.asyncapi.yaml)
> CampusClaw Java 源码基线：无；本文 Java/GaussDB 和数据库发布机制均为 target-only design
> 数据库约束：集中式 GaussDB
> JDBC 约束：openGauss JDBC `6.0.0-htrunks.csi.gaussdb_kernel.opengaussjdbc.r1`

## 1. 结论

CampusClaw GaussDB 对齐 pi-mono 当前 SQLite 的 Session 存储语义、字段语义、键模型、事务顺序和 Context 重建行为，但不照搬面向嵌入式 SQLite 的自研数据库升级机制。

源码事实、目标决策和设计原因分开如下：

- **观察到的 pi 行为**：pi 的 SQLite backend 使用七张 Session 数据表，并由 `applyMigrations()`、`migrations` 表、`001_initial.sql` 和 `002_branch_tips.sql` 在应用侧管理本地数据库文件升级。
- **CampusClaw 目标设计**：GaussDB 只定义 `t_sessions`、`t_session_entries`、`t_session_sequences`、`t_branch_entries`、`t_branch_tips`、`t_session_materialized` 和 `t_entry_materialized` 七张 Session 表。
- **产品命名约束**：目标表使用小写 snake_case 和 `t_` 前缀；源表与目标表显式映射，不再声称表名物理一致。
- **架构变更**：AgentService 和 Session 应用 Schema 不创建 `migrations` 或 `t_migrations`，不实现 `GaussDbMigrationRunner`，AgentService 启动时不执行 DDL；CampusClaw 数据库发布平台是唯一升级权威，由它编排一次性数据库变更任务执行 Schema 初始化和增量升级。
- **设计原因**：集中式共享 GaussDB 的 Schema 生命周期属于发布和运维边界，不属于每个 AgentService 实例的 Session 运行边界；这样可避免多实例启动时竞争执行 DDL，也无需给运行账号 DDL 权限。
- 七张目标表保留源 Session 表的列语义、可空性、主键、唯一键、索引列顺序和事务内写入顺序。
- 只删除 SQLite 专属的 `WITHOUT ROWID`；sequence 使用 `BIGINT`，时间使用 `TIMESTAMPTZ(3)`，JSON document 使用 `JSONB`。
- session、entry、branch 和 tip 标识及引用使用 `VARCHAR(128)`，entry type 使用 `VARCHAR(64)`，`cwd` 使用 `VARCHAR(512)`；不把字符串 ID 强行改为 UUID。
- 使用 `COMMENT ON COLUMN` 为七张 Session 表的 28 个字段提供中文注释；注释只是 GaussDB catalog 中的维护性元数据。
- 不增加 revision、operation、request hash、expected leaf、幂等表、额外搜索表、外键、CHECK、触发器或其他 GaussDB 专属结构。
- 事务内的 SQL 顺序、active leaf、materialized projection 和 branch cache 行为与 SQLite 一致。

这意味着 CampusClaw 对齐的是 Session 数据行为，不是 pi 的数据库发布实现。目标表增加 `t_` 前缀，pi 的 `migrations` 不映射；其余差异限于 GaussDB 语法、原生类型、已批准的显式长度和列注释。时间按同一 Instant 对齐，JSON 按解码后的结构对齐。

![CampusClaw GaussDB Session architecture](./diagrams/memory/memory-architecture.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L1)

## 2. 范围与非目标

### 2.1 本期范围

- 给出七张 CampusClaw Session 表的目标最终态 GaussDB DDL。
- 保持 SessionStorage 和 SessionRepository 的 create、open、list、delete、fork、append、branch query 和 context 行为。
- 保持 entry sequence、materialized state、label projection、active leaf 和 branch cache 的事务一致性。
- 支持 JSONL/SQLite 数据导入和受控导出。
- 使用指定 openGauss JDBC 驱动访问集中式 GaussDB。
- 明确 CampusClaw 数据库发布平台编排的一次性数据库变更任务先于 AgentService 版本部署 Schema。

### 2.2 本期不包括

- revision、乐观锁、expected leaf 或 stale snapshot 协议。
- operation id、request hash、持久化幂等结果或写操作审计表。
- SQLite Schema 中不存在的外键、CHECK、级联删除、触发器或投影表。
- 多租户、RLS、向量检索、跨会话长期记忆和 Runtime Checkpoint。
- 用 GaussDB 全文检索结构替代 SQLite FTS5；该问题不能仅靠语法或类型适配解决。
- 分布式分片键或 `DISTRIBUTE BY`。
- 选择具体数据库变更产品、定义其内部历史表、锁表或 checksum Schema；这些由 CampusClaw 数据库发布平台设计负责。

### 2.3 运行约束

SQLite backend 使用一个进程内 `SerialOperationQueue` 串行化数据库操作。目标 Java 适配器保留相同的单写入者语义，不在数据库层新增并发协议。

如果未来需要多个服务实例并发写同一 session，必须另立设计版本；不能在本版本中隐式增加 revision、行锁协议或幂等表。

数据库兼容模式必须保留空字符串，不得把空字符串转换为 NULL；数据库编码使用 UTF-8，文本比较和索引排序使用与 SQLite 默认 `BINARY` 接近的大小写敏感二进制 collation。连接池初始化每个数据库会话为 UTC，JDBC 使用 typed parameter，不依赖 `DateStyle` 或隐式字符串转换。这些是部署前提，不增加表、列或索引。

应用和导入器必须在 JDBC 写入前按字段检查 128、64 和 512 字符上限，超长值返回稳定校验错误，不得截断后写入。PG-compatible 模式下 `VARCHAR(n)` 的 `n` 按字符计算；中文、emoji 等 UTF-8 多字节值仍必须通过目标服务端和定制 JDBC 组合验证。

AgentService 启动时只建立连接并访问既有 Schema，不创建、修改或删除表、索引和注释。数据库变更身份与 AgentService 运行身份分离；目标版本依赖的 DDL 必须在应用部署前完成。

原生类型会比 SQLite TEXT 更早拒绝非法值。导入前必须确认 `t_sessions.created_at` 和每个 `t_session_entries.timestamp` 可解析为时间点，四个 JSON 列均为合法 JSON。`TIMESTAMPTZ(3)` 只保留毫秒精度；`JSONB` 不保留空白、对象键顺序或重复键。

## 3. pi SQLite 源码事实

本节只记录基线提交中观察到的实现。后续 GaussDB 内容是 CampusClaw 的 target-only 语义映射；尤其不把本节的 SQLite migration 机制描述为 CampusClaw 现状。

### 3.1 Migration 和核心表

SQLite `applyMigrations()` 先建立 `migrations(id, applied_at)`，再按顺序执行：

1. `001_initial.sql`
2. `002_branch_tips.sql`

`001_initial.sql` 建立：

- `sessions`
- `session_entries`
- `session_sequences`
- `branch_entries`
- `session_materialized`
- `entry_materialized`

`002_branch_tips.sql` 建立 `branch_tips`，清空旧 branch cache，并删除已冗余的 `idx_branch_entries_session_branch`。

这是面向嵌入式 SQLite 文件的观察行为。CampusClaw 目标设计不移植 `applyMigrations()`、`migrations` 表或应用启动升级；只将两份脚本执行后的七张 Session 数据表作为语义与结构证据。

源码证据：

- [`migrations.ts`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/migrations.ts#L1-L55)
- [`001_initial.sql`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/migrations/001_initial.sql#L1-L59)
- [`002_branch_tips.sql`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/migrations/002_branch_tips.sql#L1-L12)

### 3.2 Session、entry 和 sequence

`sessions.active_leaf_id` 保存当前 leaf。`session_entries` 以 `(session_id, id)` 为主键，并以 `(session_id, entry_seq)` 保证 append 顺序唯一。`session_sequences` 为每个 session 保存下一条 sequence。

entry payload 在 SQLite 中是 type-specific JSON TEXT。base 字段 `id`、`parentId`、`timestamp` 和 `type` 分别保存在固定列中，读取时重新组合为 `SessionTreeEntry`。目标 GaussDB 把该 JSON TEXT 适配为 `JSONB`，所以行为对齐比较解码结构，不比较 JSON 原文。

默认 session id 是 UUIDv7，但 `SessionCreateOptions.id` 允许调用方提供任意字符串；常规 entry id 还是 UUIDv7 的末 8 位，底层校验只要求非空字符串。因此 ID 列不能统一改成 `UUID`。本文的显式 `VARCHAR(n)` 是 GaussDB 目标产品约束，不是 pi SQLite 源码已有的长度保证。

源码证据：

- [`session-entries.ts`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/session-entries.ts#L1-L217)
- [`session-sequences.ts`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/session-sequences.ts#L1-L16)
- [`sessions.ts`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/sessions.ts#L1-L40)
- [`createSessionId()` / `createTimestamp()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/src/harness/session/repository.ts#L14-L20)
- [`Session.createEntryId()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/src/harness/session/session.ts#L229-L245)

### 3.3 Append transaction

SQLite `appendEntry()` 在同一事务中：

1. 读取下一 sequence。
2. 插入 `session_entries`。
3. 更新 `session_sequences`。
4. 更新 `session_materialized`。
5. 插入需要的 `entry_materialized` 行。
6. 更新 `sessions.active_leaf_id`。
7. 更新 `branch_entries` 和 `branch_tips`。

任一步失败，整个 append 回滚。

源码证据：

- [`SqliteSessionConnection.appendEntry()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/index.ts#L367-L418)
- [`appendEntryToBranchCache()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/branch-cache.ts#L265-L326)

### 3.4 Materialized projection

`session_materialized.payload` 保存 append-log summary，包括 name、messageCount、tokens、cost、currentModel 和 currentThinkingLevel。`entry_materialized` 当前只保存 label projection，并保留 label 设置和清除的 append 顺序。

源码证据：

- [`session-materialized.ts`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/session-materialized.ts#L1-L355)

### 3.5 Branch cache 和 Context

`branch_entries` 和 `branch_tips` 是可重建的 root-to-tip 缓存；`session_entries.parent_id` 是权威 parent chain。缓存缺失或损坏时，从 canonical parent links 重建。

`readPathToRootOrCompaction()` 返回 compaction-trimmed path。model、thinking level、active tools 和 context messages 都从该路径推导。

源码证据：

- [`branch-cache.ts`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/branch-cache.ts#L1-L326)
- [`readPathToRootOrCompaction()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/index.ts#L171-L276)
- [`buildSessionContext()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/src/harness/session/session.ts#L41-L150)

### 3.6 Optional SQLite FTS5

`session_search_fts` 不属于 `001` 或 `002` migration。只有显式创建 SQLite search adapter 时，`ensureSearchSchema()` 才建立 FTS5 virtual table 和三个 trigger。

该 virtual table 依赖 SQLite FTS5、external content 和 SQLite rowid。GaussDB 没有可以通过表名、语法或字段类型直接等价替换的结构。因此本版本不在 GaussDB Schema 中创建 `session_search_fts` 或其他搜索表，也不声称完成 FTS5 物理设计对齐。

如产品需要无额外表的搜索，可组合 pi 已有的 scanning search；这不改变本 SR 的数据库 Schema，但也不声称复制 FTS5 的 trigram、短查询和 BM25 排序语义。

源码证据：

- [`ensureSearchSchema()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/search-backend.ts#L32-L59)
- [`createScanningSessionSearch()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/agent/src/harness/session/search.ts#L11-L48)

## 4. 源码到目标 Schema 映射

| pi SQLite 表 | CampusClaw GaussDB 表 | 保留的语义 | 目标适配 |
|---|---|---|---|
| `sessions` | `t_sessions` | 列、可空性、主键和 session 主记录语义 | `t_` 命名；ID、cwd、time、JSON 使用目标类型 |
| `session_entries` | `t_session_entries` | append log、父链、顺序唯一性和索引列顺序 | `t_` 命名；ID、type、sequence、time、JSON 使用目标类型 |
| `session_sequences` | `t_session_sequences` | 每个 session 的下一 sequence | `t_` 命名；ID 和 sequence 使用目标类型 |
| `branch_entries` | `t_branch_entries` | root-to-tip 路径成员缓存及索引列顺序 | `t_` 命名；ID 和 sequence 使用目标类型 |
| `branch_tips` | `t_branch_tips` | branch tip 缓存及两组唯一性 | `t_` 命名；ID 使用目标类型 |
| `session_materialized` | `t_session_materialized` | 每个 session 的 summary 投影 | `t_` 命名；ID 和 JSON 使用目标类型 |
| `entry_materialized` | `t_entry_materialized` | 按 append 顺序保存的 label 事件投影 | `t_` 命名；ID、type、sequence、JSON 使用目标类型 |
| `migrations` | 不映射 | 仅是 pi SQLite 自研升级器的基础设施状态 | 不创建 `t_migrations`；升级元数据由 CampusClaw 数据库发布平台管理 |

目标 Session 应用 Schema 只定义七张 `t_` 表。CampusClaw 数据库发布平台可以调用经 GaussDB 验证的标准迁移工具，但版本、checksum 和锁元数据只能由该平台管理，并存放在 Session 应用 Schema 之外；不得形成第二套应用内升级账本。

### 4.1 每张目标表的作用

| 目标表 | pi 源码证据 | 作用 | 关键内容和关系 | 数据性质 |
|---|---|---|---|---|
| `t_sessions` | [`sessions`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/index.ts#L294-L365) | 保存每个 session 的主记录，用于 create、open、list、fork、head 读取和 delete。 | 保存创建时间、`cwd`、可选父 session 和 metadata；`active_leaf_id` 逻辑上指向同 session 的 `t_session_entries.id`。 | session 存在性、基本元数据和当前 head 的权威记录。 |
| `t_session_entries` | [`session_entries`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/index.ts#L367-L459) | 保存完整 append log 和树形 entry 历史，支持读取、分页、分支查询和 context 重建。 | `entry_seq` 确定追加顺序；`parent_id` 是同 session 父链；`type` 和 `payload` 组合恢复 `SessionTreeEntry`。 | 权威 append log；`parent_id` 是分支树事实源。 |
| `t_session_sequences` | [`session_sequences`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/session-sequences.ts#L1-L16) | 为每个 session 保存下一个可分配的 `entry_seq`。 | create 写入 `next_seq = 1`；append 读取当前值，成功写入 entry 后在同一事务内递增。 | 每个 session 一行的序号分配状态；缺行表示非法 session。 |
| `t_branch_entries` | [`branch_entries`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/branch-cache.ts#L18-L197) | 保存每个 branch 从 root 到 tip 的 entry 成员及顺序，避免每次递归遍历父链。 | `branch_id` 识别缓存路径；`entry_id` 和 `entry_seq` 来自 `t_session_entries`；共享前缀可出现在多条路径中。 | 可重建的派生缓存，不是树结构事实源。 |
| `t_branch_tips` | [`branch_tips`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/branch-cache.ts#L199-L326) | 保存每条缓存 branch 的 tip，使 append 快速判断线性扩展或建立新分支。 | `(session_id, tip_id)` 定位 branch；`(session_id, branch_id)` 唯一；通过 `branch_id` 与 `t_branch_entries` 建立逻辑关系。 | 可重建的派生缓存；不等同于 `t_sessions.active_leaf_id`。 |
| `t_session_materialized` | [`session_materialized`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/session-materialized.ts#L28-L221) | 保存每个 session 的累积 summary，避免 open、`getName()` 和 `getStats()` 时重放全部 entry。 | `payload` 包含 name、message/token/cost 统计、current model 和 current thinking level；每次 append 在同一事务更新。 | 可重建的派生物化投影，不代替权威 entry 历史。 |
| `t_entry_materialized` | [`entry_materialized`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/session-materialized.ts#L224-L355) | 保存需要按 append 顺序重放的 entry 投影；当前只物化 label 设置和清除事件。 | `(session_id, entry_seq, type)` 保留事件顺序；open 时按序重放为 `labelsById`，不是每个目标当前 label 的最终快照。 | 可由 `t_session_entries` 重放生成的派生物化投影。 |

所有表间关系均由应用在事务内维护，不使用物理外键。会话树以 `t_session_entries.parent_id` 为事实源；`t_branch_entries` 和 `t_branch_tips` 是可重建查询缓存；`t_session_materialized` 和 `t_entry_materialized` 是读优化投影。

### 4.2 类型映射

| SQLite 语义 | GaussDB 声明 | 对齐口径与理由 |
|---|---|---|
| session/entry/branch/tip 标识及引用 `TEXT` | `VARCHAR(128)` | 15 个同类列统一长度；与现有 CampusAgent `Identifier` / `SessionId` 的 128 字符上限一致 |
| entry/materialized type `TEXT` | `VARCHAR(64)` | 当前最长 entry type 为 21 字符；64 保留 discriminator 扩展空间，不改为 ENUM |
| sequence `INTEGER` | `BIGINT` | 保留 SQLite INTEGER 的 64 位范围 |
| ISO timestamp `TEXT` | `TIMESTAMPTZ(3)` | 两个 Session 时间字段比较同一 Instant；对外统一输出 UTC 三位毫秒格式 |
| JSON document `TEXT` | `JSONB` | 比较解码结构；接受 JSONB 规范化，不比较原文字节 |
| nullable metadata `TEXT` | nullable `JSONB` | SQL `NULL` 表示没有 metadata；不得与 JSON `null` 混淆 |
| cwd `TEXT` | `VARCHAR(512)` | Managed Agent 的 `cwd` 由服务端解析为受控规范绝对路径；512 是目标路径上限 |

`JSONB` 而不是 `JSON` 是本版本明确选择的 GaussDB 原生类型。它在写入时验证 JSON，并以规范化结构保存；因此会移除无语义空白、重排对象键并只保留重复键的最后一个值。若产品要求 JSON 原文字节可逆，应另行把该映射改为 GaussDB `JSON`，不能在不增加原文列的情况下同时获得 JSONB 规范化和字节保真。

[`agent-metadata-gaussdb-design/schema.sql`](./agent-metadata-gaussdb-design/schema.sql#L7) 中 Agent ID、resource type 和 name 分别使用明确的 `VARCHAR(64)`、`VARCHAR(16)` 和 `VARCHAR(128)`。Memory 复用的是“有界字段显式声明长度、同一逻辑域保持同型”这一规则，不盲目复制具体数字：Memory `session_id` 复用 [Identifier 的 128 字符协议上限](./pi-mono-java-manager-driven-multi-agent-runtime/chat-ws-v2.asyncapi.yaml#L1464)，而 `thinking_level_change` 已超过 16 字符。

上述 `VARCHAR(n)` 会缩小 SQLite `TEXT` 的可接受值域，因此它们是用户批准的 target-only 产品约束，不得表述为 pi 源码事实。目标实现不增加独立长度 `CHECK`，但 API、Java validator、importer 和 DDL 必须使用同一上限。

`cwd` 存在完整列索引 `idx_t_sessions_cwd`，因此不使用未经验证的超长路径上限。`VARCHAR(512)` 是受控 Managed Agent 路径的目标上限；第 9.5 节必须使用 512 字符的最大 UTF-8 值实测该索引。

### 4.3 差异分类

| 差异 | 分类 | 结构影响 |
|---|---|---|
| 源表名增加 `t_` 前缀 | CampusClaw 产品命名约束 | 七张目标表改名；显式索引按 `idx_` + 目标表名 + 用途命名；列语义不变 |
| 不映射 `migrations`，不实现应用内 Runner | CampusClaw 目标架构变更 | Session Schema 少一张 pi 基础设施表；升级责任外置 |
| 删除 `WITHOUT ROWID` | GaussDB 语法适配 | 不改变 Session 数据模型 |
| 标识及引用 `TEXT` → `VARCHAR(128)` | 用户批准的产品约束 | 超过 128 字符的值被拒绝 |
| type `TEXT` → `VARCHAR(64)` | 用户批准的产品约束 | 超过 64 字符的值被拒绝 |
| cwd `TEXT` → `VARCHAR(512)` | 用户批准的产品约束 | 受控规范路径不得超过 512 字符 |
| `INTEGER` → `BIGINT` | GaussDB 类型适配 | 不改变 64 位 sequence 语义 |
| ISO timestamp `TEXT` → `TIMESTAMPTZ(3)` | 用户批准的 GaussDB 原生类型适配 | 改变值校验、表示和排序口径 |
| JSON document `TEXT` → `JSONB` | 用户批准的 GaussDB 原生类型适配 | 改变值校验和规范化口径 |
| 28 个 `COMMENT ON COLUMN` | 用户要求的维护性元数据 | 不改变表、列、键、数据或运行行为 |

`t_` 命名是产品约束，数据库升级责任外置是架构变更；二者均为 target-only，不是 pi 源码事实。运行账号与发布身份分离属于安全强化。其余差异分别是语法适配、原生类型适配或维护性元数据。

### 4.4 明确不采用的 Session Schema 结构

- `migrations`、`t_migrations` 或 AgentService 自维护的 Schema 升级账本
- `memory_schema_version`
- `agent_session`
- `session_entry`
- `session_sequence`
- `branch_entry`
- `branch_tip`
- `session_write_operation`
- `session_search_document`
- `revision`
- `operation_id`
- SQLite Session Schema 中不存在的外键、CHECK、cascade 和 trigger

CampusClaw 数据库发布平台拥有的版本、checksum 和锁元数据不在上述禁止范围内，但必须位于 Session 应用 Schema 之外，且不得由 AgentService Mapper 或 Session Service 读写。

![CampusClaw GaussDB Session data model](./diagrams/memory/memory-data-model.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L128)

## 5. Java、MyBatis 和 JDBC 边界

### 5.1 Java 接口

Java 继续实现 pi 的 `SessionStorage` 和 `SessionRepository` 契约，不增加数据库专属命令字段。

```java
interface MemorySessionApplicationService {
    SessionDTO createSession(CreateSessionDTO dto);
    SessionDTO openSession(String sessionId);
    List<SessionSummaryDTO> listSessions(SessionListQueryDTO queryDTO);
    void deleteSession(String sessionId);
    SessionDTO forkSession(ForkSessionDTO dto);
    AppendResultDTO appendEntry(AppendEntryDTO dto);
    MoveResultDTO moveTo(MoveToDTO dto);
    ContextSnapshotDTO loadContext(LoadContextDTO dto);
    EntryPageDTO pageEntries(EntryPageQueryDTO queryDTO);
    List<SessionEntryDTO> findEntriesOnBranch(BranchEntryQueryDTO queryDTO);
}
```

这是内部 Application Service 接口，因此数据对象统一使用 DTO，不引入 PO、DO 或 Entity。DTO 不包含 operation id、expected revision 或 expected leaf；并发模型与 SQLite 一样由 Repository 串行队列约束。

如果后续通过 Controller 或对外 API 暴露这些能力，请求对象使用 `*RequestVO`，响应对象使用 `*ResponseVO`，不得复用同一个 VO 表示两个方向。请求 VO 使用 Jakarta Bean Validation，嵌套请求对象加 `@Valid`；响应 VO 不添加请求校验。Controller 只收发 VO，Service 负责 VO/DTO 转换和业务规则，Mapper 只收发 DTO。必填和格式校验放在请求 VO，跨记录、状态迁移和唯一性校验放在 Service，数据库约束作为最终完整性保障。

### 5.2 模块职责

| 组件 | 职责 |
|---|---|
| `MemorySessionApplicationService` | 编排 session 操作、执行业务校验并协调 VO/DTO 转换，不直接拼 SQL |
| `GaussDbSessionRepository` | create、open、list、delete、fork |
| `GaussDbSessionStorage` | entry、head、projection、branch query |
| MyBatis Mapper 接口 | 访问七张 `t_` 表；参数和返回值只使用 DTO，不引入 PO、DO 或 Entity |
| `GaussDbTransactionManager` | 使用 Spring Transaction Manager 提供与 SQLite transaction callback 等价的事务边界；MyBatis Mapper 参与该 Spring 事务，不创建 MyBatis 专用事务管理器 |

CampusClaw 数据库发布平台是 AgentService 之外的唯一升级权威，由它编排一次性数据库变更任务；二者不属于上述 Java 模块。当前没有 CampusClaw 实现源码或已选定工具，因此本 SR 只规定责任边界，不把某个具体发布产品描述为既有实现。

### 5.3 MyBatis 和 JDBC 约束

| 项目 | 固定选择 |
|---|---|
| MyBatis Starter | `org.mybatis.spring.boot:mybatis-spring-boot-starter:3.0.4` |
| Maven 坐标 | `org.opengauss:opengauss-jdbc:6.0.0-htrunks.csi.gaussdb_kernel.opengaussjdbc.r1` |
| 驱动类 | `org.opengauss.Driver` |
| URL | `jdbc:opengauss://host:port/database` |
| Java API | MyBatis Mapper、`SqlSession` 和 Spring 事务；Mapper 参数与返回值均为 DTO |
| VARCHAR(n) | `setString` / `getString`；写入前分别校验 128、64 和 512 字符上限，超长值返回 validation error，不依赖数据库截断 |
| BIGINT | `setLong` / `getLong`；读取 nullable 值时同时检查 `wasNull()` |
| TIMESTAMPTZ(3) | 以 UTC `OffsetDateTime` 表示 Instant，并通过 JDBC 4.2 typed binding 读写；对外规范化为 UTC 三位毫秒 ISO 字符串 |
| JSONB | 写入使用 JSON String 加 `CAST(? AS JSONB)`；读取使用 `getString()` 后交给统一 JSON codec，不依赖输出键顺序 |

AgentService 运行账号只执行 DML，不具备建表、改表、删表、建索引或 `COMMENT` 权限；CampusClaw 数据库发布平台使用独立数据库变更身份执行 DDL，并必须是表所有者或具备相应权限。Mapper SQL 对 JSONB 使用显式 cast，必要的 TypeHandler 只使用标准 JDBC 4.2 类型，不依赖驱动私有 object。定制 JDBC 对 `OffsetDateTime`、`Instant`、JSONB 和大值的实际行为必须通过 compatibility suite 验证，不能从其他 openGauss JDBC 版本推断。

## 6. CampusClaw GaussDB 最终态 DDL

本节定义七张 Session 表的目标最终状态，不定义应用启动迁移脚本。每张表的 `COMMENT ON COLUMN` 紧跟建表语句，直接说明存储内容、空值条件和关键关系，不使用未解释的抽象术语，也不得包含凭据、实际 payload、内部地址或其他敏感信息。

### 6.1 七张 Session 表

```sql
CREATE TABLE t_sessions (
    id                 VARCHAR(128)   PRIMARY KEY,
    created_at         TIMESTAMPTZ(3) NOT NULL,
    cwd                VARCHAR(512)   NOT NULL,
    parent_session_id  VARCHAR(128),
    metadata           JSONB,
    active_leaf_id     VARCHAR(128)
);

COMMENT ON COLUMN t_sessions.id IS '会话的唯一 ID，用于关联该会话的 entry（历史记录）、序号、分支和汇总数据';
COMMENT ON COLUMN t_sessions.created_at IS '创建这个会话的时间';
COMMENT ON COLUMN t_sessions.cwd IS '创建会话时使用的工作目录；可用于按工作目录筛选会话';
COMMENT ON COLUMN t_sessions.parent_session_id IS '当前会话来源于哪个父会话；未指定时为空，fork 时通常为来源会话的 ID';
COMMENT ON COLUMN t_sessions.metadata IS '创建会话时由调用方提供的附加信息 JSON 对象；未提供时为 SQL NULL';
COMMENT ON COLUMN t_sessions.active_leaf_id IS '当前选中的 entry（历史记录）ID，系统从它向前还原会话上下文；新建会话或 leaf.targetId 为 null 时为空；写入 leaf 事件时保存 targetId，不保存 leaf 事件自身 ID';

CREATE INDEX idx_t_sessions_created_at
    ON t_sessions (created_at DESC);

CREATE INDEX idx_t_sessions_cwd
    ON t_sessions (cwd);

CREATE INDEX idx_t_sessions_parent
    ON t_sessions (parent_session_id);

CREATE TABLE t_session_entries (
    session_id  VARCHAR(128)   NOT NULL,
    id          VARCHAR(128)   NOT NULL,
    entry_seq   BIGINT         NOT NULL,
    parent_id   VARCHAR(128),
    type        VARCHAR(64)    NOT NULL,
    timestamp   TIMESTAMPTZ(3) NOT NULL,
    payload     JSONB          NOT NULL,
    PRIMARY KEY (session_id, id)
);

COMMENT ON COLUMN t_session_entries.session_id IS '这条 entry（历史记录）属于哪个会话；对应 t_sessions.id';
COMMENT ON COLUMN t_session_entries.id IS '这条 entry（历史记录）的 ID；在同一个会话内唯一';
COMMENT ON COLUMN t_session_entries.entry_seq IS '这条 entry 在会话中的写入顺序号；从 1 开始，每次成功追加后递增';
COMMENT ON COLUMN t_session_entries.parent_id IS '这条 entry 的直接父 entry ID；会话的第一条 entry 为空，系统据此还原各条会话分支';
COMMENT ON COLUMN t_session_entries.type IS '这条 entry 的种类，例如 message、model_change 或 label；系统据此解释 payload';
COMMENT ON COLUMN t_session_entries.timestamp IS '这条 entry 产生时携带的事件时间；不是数据库保存这行数据的时间';
COMMENT ON COLUMN t_session_entries.payload IS '这条 entry 的具体内容 JSON；ID、父 entry、事件时间和类型已分别保存在其他字段中';

CREATE UNIQUE INDEX idx_t_session_entries_session_seq
    ON t_session_entries (session_id, entry_seq);

CREATE INDEX idx_t_session_entries_session_parent
    ON t_session_entries (session_id, parent_id);

CREATE INDEX idx_t_session_entries_session_type
    ON t_session_entries (session_id, type);

CREATE TABLE t_session_sequences (
    session_id  VARCHAR(128) PRIMARY KEY,
    next_seq    BIGINT       NOT NULL
);

COMMENT ON COLUMN t_session_sequences.session_id IS '这行序号记录属于哪个会话；对应 t_sessions.id，每个会话一行';
COMMENT ON COLUMN t_session_sequences.next_seq IS '下一条新 entry 要使用的 entry_seq；新建会话时为 1，每次成功追加后加 1';

CREATE TABLE t_branch_entries (
    session_id  VARCHAR(128) NOT NULL,
    branch_id   VARCHAR(128) NOT NULL,
    entry_id    VARCHAR(128) NOT NULL,
    entry_seq   BIGINT       NOT NULL,
    PRIMARY KEY (session_id, branch_id, entry_id)
);

COMMENT ON COLUMN t_branch_entries.session_id IS '这条缓存的分支成员记录属于哪个会话；对应 t_sessions.id';
COMMENT ON COLUMN t_branch_entries.branch_id IS '缓存路径的 ID；相同 ID 的多行按 entry_seq 排列后组成从会话起点到分支末端的一条路径，并与 t_branch_tips.branch_id 对应；缓存可根据 t_session_entries 重新生成';
COMMENT ON COLUMN t_branch_entries.entry_id IS '这条缓存路径中包含的 entry ID；对应同一会话的 t_session_entries.id，同一 entry 可出现在多条缓存路径中';
COMMENT ON COLUMN t_branch_entries.entry_seq IS '该 entry 在整个会话中的写入顺序号；从 t_session_entries 复制，用于按原顺序排列路径中的 entry，不是分支内重新编号';

CREATE INDEX idx_t_branch_entries_session_branch_seq
    ON t_branch_entries (session_id, branch_id, entry_seq);

CREATE INDEX idx_t_branch_entries_session_entry
    ON t_branch_entries (session_id, entry_id);

CREATE TABLE t_branch_tips (
    session_id  VARCHAR(128) NOT NULL,
    tip_id      VARCHAR(128) NOT NULL,
    branch_id   VARCHAR(128) NOT NULL,
    PRIMARY KEY (session_id, tip_id),
    UNIQUE (session_id, branch_id)
);

COMMENT ON COLUMN t_branch_tips.session_id IS '这条分支末端记录属于哪个会话；对应 t_sessions.id';
COMMENT ON COLUMN t_branch_tips.tip_id IS '该缓存路径最后一个 entry 的 ID；对应同一会话的 t_session_entries.id，但不一定等于 t_sessions.active_leaf_id';
COMMENT ON COLUMN t_branch_tips.branch_id IS 'tip_id 所在缓存路径的 ID；对应 t_branch_entries.branch_id，同一会话内每条路径只有一条末端记录';

CREATE TABLE t_session_materialized (
    session_id  VARCHAR(128) PRIMARY KEY,
    payload     JSONB        NOT NULL
);

COMMENT ON COLUMN t_session_materialized.session_id IS '这份会话汇总属于哪个会话；对应 t_sessions.id，每个会话一行';
COMMENT ON COLUMN t_session_materialized.payload IS '为快速打开会话而保存的汇总信息 JSON，包含会话名称、消息数、Token 和费用统计、当前模型及思考级别；不包含完整 entry，可根据 t_session_entries 重新计算';

CREATE TABLE t_entry_materialized (
    session_id  VARCHAR(128) NOT NULL,
    entry_seq   BIGINT       NOT NULL,
    type        VARCHAR(64)  NOT NULL,
    payload     JSONB        NOT NULL,
    PRIMARY KEY (session_id, entry_seq, type)
);

COMMENT ON COLUMN t_entry_materialized.session_id IS '这条标签变更记录属于哪个会话；对应 t_sessions.id，完整 entry 仍保存在 t_session_entries';
COMMENT ON COLUMN t_entry_materialized.entry_seq IS '这条记录来自哪一条 entry 的写入顺序号；对应 t_session_entries.entry_seq，读取时按此顺序处理标签变更';
COMMENT ON COLUMN t_entry_materialized.type IS '这条记录的内容种类；当前实现只写入 label，表示设置、修改或删除标签';
COMMENT ON COLUMN t_entry_materialized.payload IS '一次标签设置、修改或删除的内容 JSON，保存 targetId 和 label；label 为 null、空字符串或只含空白时表示删除该 targetId 的标签；该行不是 targetId 的最终标签快照';

CREATE INDEX idx_t_entry_materialized_session_type_seq
    ON t_entry_materialized (session_id, type, entry_seq);
```

目标 DDL 直接表达 pi `001` 和 `002` 执行后的最终 Session Schema，因此直接创建 `t_branch_tips`，不创建随后再删除的冗余 branch index，也不在新库执行 `DELETE` 或 `DROP INDEX`。这是数据库交付方式的架构变化，不改变 branch cache 的运行语义。

### 6.2 发布执行边界

- 新环境由 CampusClaw 数据库发布平台编排一次性数据库变更任务，执行目标最终态 DDL。
- 已有环境由同一发布平台编排有序增量变更达到目标最终状态；具体工具、文件命名、历史表、checksum 和锁协议由该平台选型决定。
- 变更任务失败时，不得部署依赖新 Schema 的 AgentService 版本；不能由应用启动逻辑补执行。
- AgentService 可在启动时进行只读兼容性检查并 fail fast，但不得执行 DDL 或写发布历史。
- 如果某个环境曾按旧稿创建无前缀表，不得并行新建 `t_` 表形成两套权威数据；必须通过一次性发布变更完成表的重命名或数据迁移、显式索引及必要约束名称的同步处理、校验与切换。
- 同一目标 GaussDB 只接受数据库发布平台的一套权威升级记录，并把相关元数据放在 Session 应用 Schema 之外；不得同时维护 pi 风格 `migrations` 和另一套平台历史表。

## 7. 查询与事务对齐

### 7.1 Create

一个 create transaction 依次插入：

1. `t_sessions`
2. `t_session_sequences(next_seq = 1)`
3. `t_session_materialized` 空 summary

不插入额外的 operation、state 或 audit row。

### 7.2 Append

![CampusClaw GaussDB append transaction](./diagrams/memory/memory-write-transaction.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L70)

```text
BEGIN
  SELECT next_seq FROM t_session_sequences WHERE session_id = ?
  INSERT t_session_entries
  UPDATE t_session_sequences SET next_seq = next_seq + 1
  UPDATE t_session_materialized
  INSERT t_entry_materialized rows when required
  UPDATE t_sessions SET active_leaf_id = ?
  update t_branch_entries and t_branch_tips
COMMIT
```

SQL 顺序与 SQLite `appendEntry()` 一致。GaussDB 实现不得在这条路径中插入 revision、operation 或 search projection。

### 7.3 Leaf

`leaf` 是普通 `t_session_entries` row。append 后：

- leaf marker 保留在 append log。
- `t_sessions.active_leaf_id` 设置为 `leaf.targetId`，而不是 leaf marker id。
- `targetId = null` 时 active leaf 为 null。

源码证据：[`leafIdAfterEntry()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/shared.ts#L15-L17)

### 7.4 Branch cache

GaussDB 直接使用 `t_branch_entries` 和 `t_branch_tips`：

- root append 建立新 branch 和 tip。
- 线性 append 扩展 tip。
- 从旧 parent 分叉时复制共享前缀。
- 缓存缺失或无效时，从 `t_session_entries.parent_id` 递归重建。
- 修复使用 savepoint，但不引入额外表或状态列。

### 7.5 Context

![CampusClaw GaussDB context rebuild](./diagrams/memory/memory-context-rebuild.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L231)

```text
leaf = t_sessions.active_leaf_id
fullPath = validatedBranchCacheOrParentChain(leaf)
path = trimPathToRootOrCompaction(fullPath)
state = deriveModelThinkingAndTools(path)
messages = project(defaultContextEntryTransform(path))
```

GaussDB 不改变 compaction、`retainedTail`、`firstKeptEntryId` 或 custom projector 语义。

### 7.6 Delete

SQLite 没有外键或 cascade，Repository 按以下顺序删除：

1. `t_branch_tips`
2. `t_branch_entries`
3. `t_session_entries`
4. `t_entry_materialized`
5. `t_session_materialized`
6. `t_session_sequences`
7. `t_sessions`

GaussDB 保持相同的显式删除顺序，不使用 `ON DELETE CASCADE` 替代。

源码证据：[`SqliteSessionBackend.delete()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/repo.ts#L153-L168)

## 8. 数据迁移

### 8.1 SQLite 到 GaussDB

迁移按第 4 节的显式源表→目标表映射执行，并按目标原生类型转换列值：

1. `sessions` → `t_sessions`。
2. `session_entries` → `t_session_entries`，保持 `entry_seq`，把 timestamp 转为同一 Instant，把 payload 解析后写入 JSONB。
3. `session_sequences` → `t_session_sequences`。
4. `session_materialized` → `t_session_materialized`，`entry_materialized` → `t_entry_materialized`。
5. `branch_entries` → `t_branch_entries`，`branch_tips` → `t_branch_tips`；缓存也可以从父链重建。
6. 不复制源 `migrations`；CampusClaw 数据库发布平台必须在业务数据导入前完成七张目标表的 Schema 部署。

列转换规则：

- session/entry/branch/tip 标识及引用在写入前校验不超过 128 字符，type 不超过 64 字符，`cwd` 不超过 512 字符。
- sequence 以 64 位有符号整数复制。
- `created_at` 和 `timestamp` 必须解析为 Instant，再以 `TIMESTAMPTZ(3)` 写入；迁移只接受毫秒精度，禁止静默截断或舍入更高精度。
- metadata 和三个 payload 列必须先解析为 JSON，再以 JSONB 写入。
- 超长字符串不得截断；迁移错误报告必须包含表、列、主键、实际字符数和允许上限。
- 非法 timestamp、非法 JSON、超长字符串或其他不可表示值进入迁移错误报告；对应 session 不进入目标库。

必须校验：

- 每表行数。
- `(session_id, id)` 和 `(session_id, entry_seq)` 集合。
- active leaf。
- `created_at` 和每个 entry timestamp 表示与源值相同的 Instant，接口输出为 UTC 三位毫秒 ISO 字符串。
- metadata 和所有 payload 的解析后 JSON 结构；不比较空白、对象键顺序或原文字节。
- 每个 tip 的 root-to-tip entry id 顺序。
- context messages 和 Session state。

### 8.2 JSONL 导入

JSONL importer 只向上述七张 `t_` Session 表写入，不创建额外状态、审计表或升级账本。导入后按相同 projector 重建 materialized rows 和 branch cache。

### 8.3 回滚

切换前保留 SQLite 只读副本。GaussDB 可按第 4 节反向映射导出逻辑上 SQLite-compatible 的七张 Session 数据表：timestamp 输出为 UTC 三位毫秒 ISO 字符串，JSONB 输出为合法 JSON。导出不生成 pi `migrations` 行，不承诺恢复源 SQLite JSON 的空白、键顺序、重复键或原始时间偏移文本，也不启用长期双写。

## 9. 测试与验收

### 9.1 Schema 语义映射

- 目标 Session 表集合严格等于第 4 节的七张 `t_` 表。
- 七组映射的列名、可空性、列顺序、主键、唯一键和索引列顺序与 pi Session 数据语义一致；目标表名为 `t_*`，显式索引名为 `idx_` + 目标表名 + 用途。
- 类型差异严格等于：15 个标识或引用列为 `VARCHAR(128)`，2 个 type 列为 `VARCHAR(64)`，`t_sessions.cwd` 为 `VARCHAR(512)`，4 个 sequence 列为 `BIGINT`，2 个时间列为 `TIMESTAMPTZ(3)`，4 个 JSON document 列为 `JSONB`。
- 七张表的 28 个字段均有非空且与本文字段语义一致的列注释；注释直接说明存储内容、空值条件和关键关系，不以抽象设计术语代替字段含义。
- 最终 Schema 不存在 pi `002` 删除的冗余 branch index。
- 目标 Session Schema 不存在 `migrations`、`t_migrations`、revision、operation、search document 或其他额外表/列。

### 9.2 行为 parity

- create、open、list、delete、fork。
- 所有 11 种 entry 的 append、读取和分页。
- sequence 分配与唯一冲突。
- materialized name、label、stats、model 和 thinking state。
- leaf move、branch fork、branch cache repair。
- bounded branch query 的 stop、filter、order 和 limit。
- compaction、retainedTail、legacy firstKept 和 context messages。
- malformed entry 的错误行为。

### 9.3 Transaction parity

- append 任一步失败时所有 7 类写入一起回滚。
- branch cache repair savepoint 失败时不破坏旧 cache。
- delete 任一步失败时整个 delete 回滚。

### 9.4 数据库发布边界

- AgentService 启动测试证明不会执行 `CREATE`、`ALTER`、`DROP`、`COMMENT` 或写入升级历史。
- AgentService 运行账号执行 DDL 必须被数据库拒绝，正常 Session DML 必须成功。
- 数据库发布平台的独立变更身份可以执行目标 DDL 和 28 条列注释；任一变更失败时，发布流程不得继续部署依赖新 Schema 的应用版本。
- 并发启动多个 AgentService 实例不会触发 Schema 竞争，因为数据库变更只由 CampusClaw 数据库发布平台编排的一次性任务执行。
- 数据库发布平台只维护一套权威升级记录，并将元数据置于 Session 应用 Schema 之外；具体工具选定后，必须另外验证版本顺序、checksum、并发锁和失败恢复。
- 若已有无前缀旧稿 Schema，一次性迁移必须同步处理表名、显式索引及必要约束名称，并验证七张表的行数、键集合、投影、branch path 和 Context 后再切换，不得留下双写或双份权威表。

### 9.5 JDBC compatibility suite

必须使用指定定制 JDBC JAR 验证：

- 驱动加载、URL、TLS、认证和连接池。
- 通过指定 JDBC JAR 执行本文最终态 `CREATE TABLE`、`CREATE INDEX` 和 `COMMENT` 的语法与事务行为；发布工具的集成验证归入第 9.4 节。
- 28 条 `COMMENT ON COLUMN`、中文 UTF-8 注释，以及通过 `col_description` 读取的注释完整性。
- `VARCHAR(128)`、`VARCHAR(64)` 和 `VARCHAR(512)` 的 `n-1`、`n`、`n+1` 字符边界，以及中文、emoji、空字符串和禁止静默截断。
- 最大长度值用于 primary key、复合 primary key、composite unique index 和 `idx_t_sessions_cwd` 时的写入、查询与二进制等价排序。
- BIGINT sequence 的绑定与读取。
- TIMESTAMPTZ(3) 的 UTC、非 UTC offset、毫秒精度、排序和 JDBC typed binding。
- JSONB 的 object、array、scalar、JSON null、Unicode、转义、大 payload 和数值往返。
- SQL `NULL` 与 JSON `null` 不混淆；JSONB 按解码结构比较，不比较键顺序或原文。
- 非法 timestamp 和非法 JSON 在写入或迁移阶段稳定失败。
- recursive CTE、window function、savepoint 和 transaction rollback。
- SQLState 到稳定 storage error 的映射。

### 9.6 验收标准

- 最终 Session Schema 的结构差异只包含七张目标表的 `t_` 命名、显式索引的 `idx_` + 目标表名 + 用途命名、pi `migrations` 不映射、`WITHOUT ROWID` 删除、已批准的 `VARCHAR(128)`、`VARCHAR(64)`、`VARCHAR(512)`、`BIGINT`、`TIMESTAMPTZ(3)`、`JSONB` 类型映射，以及 28 个列注释元数据；发布方式和最终态 DDL 交付属于另行列明的架构变化。
- 符合目标长度上限的相同数据产生相同的 session metadata、entry、active leaf、projection、branch query 和 context；timestamp 按 Instant 等价，JSON 按解码结构等价，其余字符串完全相等。
- GaussDB Session Schema 中没有第 4 节映射之外的业务表、列、约束、索引或 trigger。
- AgentService 不包含 `GaussDbMigrationRunner`，启动时不执行 DDL，运行账号没有 DDL 权限。
- 所有 DDL 在目标集中式 GaussDB 和指定 JDBC JAR 上通过 compatibility suite。

## 10. 安全与运维

安全与运维边界如下：

- JDBC 强制 TLS，凭据来自部署 secret。
- AgentService 运行账号最小权限且只执行 DML；数据库发布身份单独管理并执行 DDL。
- SQL 全部参数化。
- payload 和 metadata 默认不写普通日志。
- 列注释对可连接数据库的用户可见，只描述稳定字段语义，不写凭据、实际 payload、内部地址或其他敏感信息。
- 限制单 entry payload、单 session entry 数和递归路径深度。
- 监控事务失败、锁等待、连接失败、branch cache repair 和发布数据库变更失败。
- DDL 必须先于依赖新 Schema 的 AgentService 版本部署；不允许以应用启动时自动补表作为恢复手段。
- 应用回滚必须与当时 Schema 兼容；若 DDL 不可逆，应采用兼容窗口或前向修复，而不是长期双写。

## 11. 设计决策

| ID | 决策 | 分类 |
|---|---|---|
| TD-MEM-01 | 对齐 pi 的七张 Session 数据表语义；CampusClaw 目标表统一使用 `t_` 前缀 | Session 语义对齐 + 产品命名约束 |
| TD-MEM-02 | 删除 `WITHOUT ROWID` | GaussDB 语法适配 |
| TD-MEM-03 | sequence `INTEGER` 映射为 `BIGINT` | GaussDB 原生类型适配 |
| TD-MEM-04 | ISO timestamp `TEXT` 映射为 `TIMESTAMPTZ(3)` | GaussDB 原生类型适配；按 Instant 对齐 |
| TD-MEM-05 | JSON document `TEXT` 映射为 `JSONB` | GaussDB 原生类型适配；按解码结构对齐 |
| TD-MEM-06 | 不增加外键、CHECK、cascade 或 trigger | 禁止额外设计 |
| TD-MEM-07 | 不增加 revision 或幂等 operation | 禁止额外设计 |
| TD-MEM-08 | 不建立 GaussDB 搜索投影表 | FTS5 无直接语法/类型映射 |
| TD-MEM-09 | Repository 保持 SQLite 串行写模型 | SQLite 运行行为对齐 |
| TD-MEM-10 | 15 个标识及引用列使用 `VARCHAR(128)`，2 个 type 列使用 `VARCHAR(64)`，`cwd` 使用 `VARCHAR(512)` | 用户批准的 target-only 产品约束；不使用 UUID 或 ENUM |
| TD-MEM-11 | 为七张目标表的 28 个字段添加中文 `COMMENT ON COLUMN` | 用户要求的维护性元数据；不改变 Session 数据行为 |
| TD-MEM-12 | 不映射 pi `migrations`，不实现 `GaussDbMigrationRunner`，AgentService 启动时不执行 DDL | 用户批准的 target-only 架构变更 |
| TD-MEM-13 | CampusClaw 数据库发布平台是唯一升级权威，由它编排一次性数据库变更任务，并在 Session 应用 Schema 外只保留一套升级记录 | 用户批准的 target-only 架构变更 |
| TD-MEM-14 | Java 持久层使用 MyBatis Spring Boot Starter 3.0.4；Controller/API 使用方向独立的 VO，Service 负责转换，Mapper 只收发 DTO | Java 实现规范 |

## 12. 官方能力依据

- [GaussDB 实例类型：集中式与分布式](https://support.huaweicloud.com/intl/en-us/productdesc-gaussdb/gaussdb_01_013.html)
- [SQLite `WITHOUT ROWID`](https://www.sqlite.org/withoutrowid.html)
- [SQLite 数据类型](https://www.sqlite.org/datatype3.html)
- [SQLite FTS5](https://www.sqlite.org/fts5.html)
- [GaussDB `CREATE TABLE`](https://support.huaweicloud.com/intl/en-us/centralized-devg-v8-gaussdb/gaussdb-42-0573.html)
- [GaussDB 数值类型](https://support.huaweicloud.com/intl/en-us/centralized-devg-v3-gaussdb/gaussdb-42-0329.html)
- [GaussDB 字符类型](https://support.huaweicloud.com/intl/en-us/centralized-devg-v8-gaussdb/gaussdb-42-0335.html)
- [GaussDB 日期/时间类型](https://support.huaweicloud.com/eu/centralized-devg-v8-gaussdb/gaussdb-42-0337.html)
- [GaussDB JSON/JSONB 类型](https://support.huaweicloud.com/intl/en-us/centralized-devg-v8-gaussdb/gaussdb-42-0343.html)
- [GaussDB `CREATE INDEX`](https://support.huaweicloud.com/centralized-devg-v8-gaussdb/gaussdb-42-0552.html)
- [GaussDB `DROP INDEX`](https://support.huaweicloud.com/intl/en-us/centralized-devg-v8-gaussdb/gaussdb-42-0607.html)
- [GaussDB `COMMENT`](https://support.huaweicloud.com/intl/en-us/distributed-devg-v8-gaussdb/gaussdb-12-0528.html)
- [GaussDB 集中式字段设计规范](https://support.huaweicloud.com/centralized-devg-v8-gaussdb/gaussdb-42-2075.html)
- [GaussDB 事务控制](https://support.huaweicloud.com/intl/en-us/centralized-devg-v8-gaussdb/gaussdb-42-0468.html)
- [GaussDB Centralized V2.0-3.x `WITH RECURSIVE`](https://support.huaweicloud.com/intl/en-us/centralized-devg-v3-gaussdb/gaussdb-42-0649.html)
- [openGauss 6.0 JDBC 驱动类与兼容说明](https://docs.opengauss.org/en/docs/6.0.0/docs/DeveloperGuide/jdbc-package-driver-class-and-environment-class.html)
- [openGauss 6.0 JDBC 驱动加载](https://docs.opengauss.org/en/docs/6.0.0/docs/DeveloperGuide/loading-the-driver-jdbc.html)
- [MyBatis Spring Boot Starter 3.0.4 release](https://github.com/mybatis/spring-boot-starter/releases/tag/mybatis-spring-boot-3.0.4)
- [MyBatis-Spring transaction management](https://mybatis.org/spring/transactions.html)

公开文档只能证明标准能力。定制 JDBC 版本和实际服务端仍必须通过第 9.5 节测试。数据库发布工具尚未选型，其兼容性不得从本文推断。

## 13. 版本记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v0.13 | 2026-08-06 | 根据用户确认将目标从 SQLite 物理 Schema 对齐改为 pi Session 存储语义对齐；七张目标表采用 `t_` 前缀；不映射 pi `migrations`，删除应用内 `GaussDbMigrationRunner` 和启动时 DDL；CampusClaw 数据库发布平台成为唯一升级权威并编排一次性变更任务；目标 DDL 合并为最终状态，字段注释调整为七表 28 条；Java 边界统一使用 DTO/VO 并采用 MyBatis Spring Boot Starter 3.0.4 |
| v0.12 | 2026-08-03 | 将 30 条中文列注释改为直接说明“存什么、何时为空、如何关联”的表述；去除“稀疏投影”、“权威父链”和 `root-to-tip` 等不加解释的抽象术语；补充缓存可重建、同一 entry 可出现在多条路径、label 变更顺序与非最终快照说明；不改变 DDL 结构 |
| v0.11 | 2026-08-03 | 使用 GaussDB `COMMENT ON COLUMN` 为 8 张表的 30 个字段增加中文注释；明确注释的 migration 事务、权限、敏感信息、旧稿已执行数据库和验收规则；不增加表、列、键或索引 |
| v0.10 | 2026-08-03 | 参照 Agent 元数据 GaussDB 的显式长度规则，将 16 个标识及引用列改为 `VARCHAR(128)`、2 个 type 列改为 `VARCHAR(64)`、`cwd` 改为 `VARCHAR(512)`；增加应用和迁移长度预检、边界测试和禁止截断规则；将 `migrations` 重写为数据库升级“已完成清单”并补充示例 |
| v0.9 | 2026-08-03 | 补充 8 张 SQLite/GaussDB 对齐表的集中职责说明，明确 session 主记录、权威 append log、sequence 运行状态、可重建 branch cache、派生 materialized projection 和 migration 账本的边界；不改变 Schema 或运行行为 |
| v0.8 | 2026-08-03 | 在不改变表、列、列顺序、可空性、主键、唯一约束和索引的前提下使用 GaussDB 原生语义类型：任意字符串改为无长度 `VARCHAR`，时间字段改为 `TIMESTAMPTZ(3)`，JSON document 改为 `JSONB`，sequence 改为 `BIGINT`；迁移和验收改为按字符串、Instant 与解码后 JSON 结构比较 |
| v0.7 | 2026-08-03 | 将 GaussDB 从“SQLite 行为对齐 + 可靠性扩展”收敛为 SQLite 物理 Schema 对齐；表名、列名、主键、索引和 migration id 与 SQLite 一致；删除 revision、operation、checksum、额外搜索投影、外键和 CHECK；仅删除 `WITHOUT ROWID` 并把 sequence `INTEGER` 映射为 `BIGINT` |
| v0.6 | 2026-08-03 | 更新 pi 基线至 `f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee`；对齐 sequence、materialized projection、branch cache、bounded branch query、search 和 compaction-trimmed context；保留 revision/idempotency 扩展 |
| v0.5 | 2026-07-30 | 更新 pi 基线至 `fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc`；采用新 harness leaf、active tools 和 retainedTail；数据库固定为集中式 GaussDB |
| v0.4 | 2026-07-20 | 将 SR 边界收敛为 Session Event Plane，拆分控制面、Runtime Checkpoint、长期记忆和 Artifact |
| v0.3 | 2026-07-17 | 更新 pi 源码基线并核对记忆实现 |
| v0.2 | 2026-07-16 | 为 DDL 表和字段补充数据库说明 |
| v0.1 | 2026-07-15 | 建立 Java ToB GaussDB 持久化、事务和迁移设计 |
