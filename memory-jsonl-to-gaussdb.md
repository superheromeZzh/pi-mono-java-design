# pi-mono Java 集中式 GaussDB 会话记忆系统 SR 设计

> 文档编号：SR-MEM-001
> 版本：v0.5
> 日期：2026-07-30
> 状态：设计评审稿
> pi 源码基线：[`fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc`](https://github.com/badlogic/pi-mono/tree/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc)
> Java 源码基线：无；本文 Java 内容均为 target-only design
> 数据库约束：集中式 GaussDB，单分片高可用部署
> JDBC 约束：openGauss JDBC `6.0.0-htrunks.csi.gaussdb_kernel.opengaussjdbc.r1`

## 1. 结论

Java 版本使用集中式 GaussDB 取代 pi 当前 coding-agent 的本地 JSONL 会话文件，数据库成为会话记忆的唯一持久化事实源。设计保留以下 pi 语义：

- entry 通过 `id` 和 `parentId` 组成不可变会话树。
- 当前 leaf 决定活动分支，context 只使用 root-to-leaf 路径。
- `compaction` 和 `branch_summary` 是会话 entry，不是跨会话长期记忆。
- 新格式 compaction 使用自包含的 `retainedTail`；旧格式继续读取 `firstKeptEntryId`。
- `message`、`custom_message`、摘要 entry 和扩展 projector 决定进入模型的消息。
- 模型、思考级别和启用工具从完整活动路径推导。

Java 目标新增数据库事务、幂等操作、乐观版本和查询投影。这些是架构改造及可靠性强化，不是 pi JSONL 的既有行为。

本 SR 只设计会话内记忆，不设计多租户、跨会话事实抽取、向量召回、Runtime Checkpoint、Agent 控制面或 Artifact 内容存储。pi 基线中也没有内建的跨会话记忆抽取和注入流程。

![Java centralized GaussDB memory architecture](./diagrams/memory/memory-architecture.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L1)

## 2. 范围与约束

### 2.1 本期范围

- 会话创建、打开、列出、删除和 fork。
- entry 追加、显式 leaf 移动、标签和会话名称。
- compaction、branch summary 和确定性 context rebuild。
- JSONL v1-v3 与当前 pi SQLite 会话库导入。
- 数据库事务、幂等重试、并发冲突、投影重建和受控 JSONL 导出。
- Java Application Service、Repository、JDBC Adapter 和 GaussDB 表边界。

### 2.2 本期不包括

- `tenant_id`、`TenantContext`、RLS、租户配额或跨租户授权。
- 跨会话长期 Memory Store、Memory Item、Embedding、抽取和召回。
- Run、Step、Pending Tool Call、Checkpoint、Checkpoint Blob 和执行恢复。
- Agent Definition、Agent Version、Environment、Tool Binding 和 Credential。
- 文件内容及对象存储生命周期；仅保存摘要 entry 派生的文件操作投影。
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

- [`SessionEntry` 和 JSONL v3](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/session-manager.ts#L30-L153)
- [`_persist()` / `_appendEntry()`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/session-manager.ts#L1015-L1049)
- [`branch()` / `resetLeaf()` / `branchWithSummary()`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/session-manager.ts#L1354-L1405)

### 3.2 新 harness 定义存储抽象和完整 entry 集合

`packages/agent` 的新 harness 定义 `SessionStorage` 和 `SessionRepo`，把会话语义与 JSONL、内存或 SQLite 介质分开。其 `SessionTreeEntry` 在旧 coding-agent 类型基础上增加：

- `active_tools_change`：保存活动工具名。
- `leaf`：保存显式导航的 `targetId`。
- `compaction.retainedTail`：把保留消息直接存入 compaction entry。

`SessionStorage.setLeafId()` 的契约要求持久化 leaf entry；`SessionRepo` 统一 create、open、list、delete 和 fork。

源码证据：

- [`SessionTreeEntry`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/agent/src/harness/types.ts#L375-L464)
- [`SessionStorage` / `SessionRepo`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/agent/src/harness/types.ts#L498-L537)
- [`Session` append 和 moveTo](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/agent/src/harness/session/session.ts#L214-L357)

### 3.3 Context rebuild 和 compaction

新 harness 先从完整活动路径推导 model、thinking level 和 active tools，再应用 context entry transform：

- 无 compaction 时保留活动路径。
- 最新 compaction 含 `retainedTail` 时，context 使用 compaction、其自带 retained tail 和 compaction 后续 entry。
- 旧 compaction 不含 `retainedTail` 时，使用 `firstKeptEntryId` 保留旧格式边界。
- compaction entry 投影为 summary message，并追加其 `retainedTail`。
- `custom` 默认不进入 context，只有已注册 projector 才能产生消息。

默认 compaction 设置是启用、保留 16,384 tokens 给 prompt/output、保留最近 20,000 tokens。触发条件是 `contextTokens > contextWindow - reserveTokens`。准备阶段避免从 tool result 中间切割，支持 split turn，并把近期消息物化为 `retainedTail`。

源码证据：

- [`defaultContextEntryTransform()` / `sessionEntryToContextMessages()`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/agent/src/harness/session/session.ts#L45-L147)
- [`shouldCompact()`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/agent/src/harness/compaction/compaction.ts#L250-L253)
- [`prepareCompaction()` / `compact()`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/agent/src/harness/compaction/compaction.ts#L605-L813)

### 3.4 pi SQLite 是数据库行为参考

`packages/storage/sqlite-node` 已实现新 harness 的数据库后端，但当前 coding-agent runtime 尚未接入它。其观察行为是：

- `sessions.active_leaf_id` 保存当前 leaf。
- `session_entries` 使用 `(session_id, id)` 主键和 session 内唯一 `entry_seq`。
- `setLeafId()` 追加 `leaf` entry；leaf entry 的 `targetId` 成为当前 leaf，而 leaf marker 自身不进入 context path。
- entry、序号、物化统计、当前 leaf 和 branch path 在一个 SQLite 事务内更新。
- `branch_entries` 物化活动路径，以换取读取性能。
- malformed entry 在若干读取路径被跳过，保持 JSONL 式宽松恢复。

源码证据：

- [`001_initial.sql`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/storage/sqlite-node/src/sqlite/migrations/001_initial.sql#L1-L59)
- [`setLeafId()` / `appendEntry()`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/storage/sqlite-node/src/sqlite/storage/index.ts#L266-L346)
- [`leafIdAfterEntry()`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/storage/sqlite-node/src/sqlite/storage/shared.ts#L27-L29)
- [`getPathToRootOrCompaction()`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/storage/sqlite-node/src/sqlite/storage/index.ts#L125-L183)

### 3.5 Branch summary 和 fork

branch summary 从旧 leaf 向上收集到与目标路径的最深 common ancestor，然后按时间顺序生成摘要。`moveTo()` 先持久化目标 leaf；有 summary 时再把 `branch_summary` 挂到目标 entry 一侧。

fork 的默认 position 是 `before`：目标必须是 user message，并使用其 parent 作为有效 leaf。`at` 则包含目标 entry。SQLite repo 把选定路径复制到新会话。

源码证据：

- [`collectEntriesForBranchSummary()`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/agent/src/harness/compaction/branch-summarization.ts#L70-L100)
- [`getEntriesToFork()`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/agent/src/harness/session/repo-utils.ts#L32-L50)
- [`SqliteSessionRepo.fork()`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/storage/sqlite-node/src/sqlite/repo.ts#L163-L191)

### 3.6 观察行为、目标选择和理由

| 主题 | 观察到的 pi 行为 | Java/GaussDB 目标 | 分类与理由 |
|---|---|---|---|
| 事实源 | coding-agent 使用 JSONL；新 harness 支持可插拔存储 | GaussDB `session_entry` | 架构改造：提供事务和并发访问 |
| leaf | 旧 runtime 只在内存移动；新 harness/SQLite 写 `leaf` entry | 采用 `leaf` entry + state current leaf | pi 新存储语义对齐 |
| compaction | 新 harness 支持 `retainedTail`，兼容 `firstKeptEntryId` | 两种格式均可读取 | 兼容约束 |
| active path | SQLite 使用 `branch_entries` 物化 | v1 使用递归 CTE | 架构选择：避免路径写放大 |
| malformed entry | SQLite 部分读取会跳过 | context rebuild 失败并报告 entry | 安全强化：禁止静默丢失上下文 |
| 并发 | pi 主要依赖单进程顺序控制 | 行锁 + revision + expected leaf | 可靠性强化 |
| 多租户 | pi 无租户概念 | 不增加租户模型 | 产品约束 |
| 长期记忆 | pi 无内建跨会话抽取和召回 | 本 SR 不新增 | 产品范围约束 |

## 4. Java 目标行为

### 4.1 创建和打开

创建会话时，在同一事务中写入 `agent_session`、空的 `agent_session_state` 和 committed create operation。初始 `current_leaf_entry_id=NULL`、`revision=0`、`next_append_seq=1`。

打开会话只读取 header、state 和必要投影，不预加载全部 entry。context、tree 和分页分别通过 Repository 查询。

### 4.2 追加 entry

普通 append 在一个短事务中：

1. 识别或建立 `session_write_operation`。
2. 锁定 `agent_session_state`。
3. 校验 expected revision 和 expected leaf。
4. 使用 `next_append_seq` 插入不可变 `session_entry`。
5. 更新标签、名称、统计和文件操作投影。
6. 把 current leaf 设为新 entry，递增 revision 和 sequence。
7. 保存稳定响应并提交。

LLM、工具、网络调用和文件操作不在该事务中执行。

### 4.3 显式 leaf 移动

`moveTo(targetId)` 验证目标属于当前会话，然后追加一个 `leaf` entry：

- `leaf.parentId` 是移动前 current leaf。
- `leaf.payload.targetId` 是目标 entry，允许为 `null`。
- `agent_session_state.current_leaf_entry_id` 更新为目标，而不是 leaf marker。
- leaf marker 进入追加日志和审计，但不进入模型 context path。

有 branch summary 时，同一提交事务内先写 leaf marker，再写 parent 为目标 entry 的 `branch_summary`，最终 current leaf 指向 summary entry。该目标侧挂载与 pi 一致；单事务提交是 Java 可靠性强化。

### 4.4 Context rebuild

Context rebuild 获取稳定的 root-to-leaf 完整路径及 state revision：

1. 从完整路径推导最后生效的 model、thinking level 和 active tools。
2. 找到最新 compaction。
3. 有 `retainedTail` 时输出 compaction summary、retained tail 和 compaction 后续 entry。
4. 旧格式使用 `firstKeptEntryId` 选择保留 entry。
5. 投影 message、custom message、compaction 和 branch summary。
6. `custom` 仅通过注册的 projector 产生消息。

返回的 `ContextSnapshot` 包含 `sessionId`、`revision`、`leafEntryId`、完整活动路径标识及最终 runtime context。

### 4.5 Compaction 和 branch summary

Coordinator 从不可变 `ContextSnapshot` 准备摘要输入，在数据库事务外调用模型。提交摘要时重新锁定 state：

- revision 和 leaf 均相同：写入摘要 entry 和投影，更新 state。
- 任一不同：不保存过期结果，返回 `STALE_CONTEXT_SNAPSHOT`。

重试必须读取新 snapshot 并重新计算 cut point 或 common ancestor，不能复用旧的 `firstKeptEntryId`、`retainedTail` 或目标路径。

### 4.6 Fork

fork 在源 session revision 稳定时读取选定路径，再创建新 session：

- 未指定 entry 时复制源 session 的全部追加 entry，与 pi repo 行为一致。
- `before` 只接受 user message，并以其 parent 为有效 leaf。
- `at` 包含目标 entry。
- 复制 entry 保留原 entry id 和 timestamp，在新 session 中重新分配 `append_seq`。
- 新 session 的 `parent_session_id` 指向源 session。
- fork 事务写入新 header、entries、projections、state 和 operation；源 session 不变。

## 5. 目标架构和 JDBC

### 5.1 组件职责

| 组件 | 职责 |
|---|---|
| Agent Runtime | 驱动 turn、工具和 LLM，不直接访问数据库 |
| `MemorySessionApplicationService` | 编排 session、append、move、fork、context 和迁移 |
| `ContextRebuilder` | 将完整活动路径确定性投影为 runtime context |
| `CompactionCoordinator` | 准备 snapshot、生成摘要、提交 compaction |
| `BranchSummaryCoordinator` | 计算分支差异、生成摘要、提交目标侧 entry |
| `SessionRepository` | header、state、列表、树和 fork 查询 |
| `EntryRepository` | entry 追加、分页、路径和投影 |
| `WriteOperationRepository` | 幂等操作、稳定响应和冲突识别 |
| `GaussDbJdbcAdapter` | JDBC 事务、SQLState 映射、JSONB 编解码 |
| GaussDB | 会话事实源、状态与查询投影 |

![Append, move, and summary transaction](./diagrams/memory/memory-write-transaction.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L57)

### 5.2 Java 模块边界

```text
memory.api
  MemorySessionApplicationService
  command/*
  view/*

memory.domain
  SessionHeader
  SessionState
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
- `memory_schema_version` 记录已安装版本。
- 应用启动只验证版本，不自动升级。
- migration 失败必须整体回滚；不支持事务的 DDL 必须在发布脚本中明确补偿步骤。

## 6. 逻辑数据模型

### 6.1 `agent_session`

保存稳定 header：会话 id、格式版本、cwd、父会话、metadata 和创建时间。当前 leaf、revision 和统计不与 header 混放。

### 6.2 `agent_session_state`

每个 session 恰好一行：

- `current_leaf_entry_id` 是活动路径 leaf，可为空。
- `revision` 是命令级乐观版本，每个成功修改命令递增一次。
- `next_append_seq` 在 state 行锁内分配。
- session name、消息数、token 和 cost 是可重建投影。

模型、思考级别和 active tools 不保存在 state，因为它们随活动分支变化，必须从完整路径推导。

### 6.3 `session_entry`

不可变会话事实表。固定列保存身份、树关系、类型、顺序和时间；`payload JSONB` 保存 type-specific 字段及未知扩展字段。读取时通过固定列和 payload 重建完整 `SessionTreeEntry`。

`operation_id` 把本次写入关联到幂等命令。普通 append 写一条 entry；带摘要的 move 可在同一 operation 下写 leaf marker 和 branch summary 两条 entry。

### 6.4 `session_write_operation`

保存写命令的幂等键、规范化请求 SHA-256、状态和稳定响应。`started`、entry、state 和最终 `committed` 在同一事务内，因此回滚后不会留下可见半完成行。

### 6.5 `session_label`

保存每个 target entry 当前生效的非空 label。label entry 仍是事实；该表只是按目标查询的投影。清除 label 时删除投影行。

### 6.6 `session_file_operation`

从 pi 生成的 compaction 或 branch summary `details.readFiles`、`details.modifiedFiles` 展开。该表不参与 context rebuild，可从 entry 重建。

### 6.7 数据关系

![Session event plane data model](./diagrams/memory/memory-data-model.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L120)

## 7. 集中式 GaussDB DDL 草案

以下是 target-only migration v1。上线前必须在实际集中式 GaussDB 版本和指定 JDBC JAR 上执行兼容性测试。

```sql
CREATE TABLE memory_schema_version (
    component       VARCHAR(64) NOT NULL,
    schema_version  INTEGER     NOT NULL,
    installed_at    TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (component)
);

CREATE TABLE agent_session (
    session_id              VARCHAR(128) NOT NULL,
    session_format_version  INTEGER      NOT NULL DEFAULT 3,
    cwd                     TEXT         NOT NULL,
    parent_session_id       VARCHAR(128),
    metadata                JSONB        NOT NULL DEFAULT '{}'::jsonb,
    created_at              TIMESTAMPTZ  NOT NULL,
    updated_at              TIMESTAMPTZ  NOT NULL,
    PRIMARY KEY (session_id),
    FOREIGN KEY (parent_session_id)
        REFERENCES agent_session (session_id)
        ON DELETE SET NULL,
    CHECK (session_format_version > 0)
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
    payload          JSONB        NOT NULL,
    operation_id     VARCHAR(128) NOT NULL,
    created_at       TIMESTAMPTZ  NOT NULL,
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

CREATE TABLE agent_session_state (
    session_id             VARCHAR(128) NOT NULL,
    current_leaf_entry_id  VARCHAR(128),
    revision               BIGINT       NOT NULL DEFAULT 0,
    next_append_seq        BIGINT       NOT NULL DEFAULT 1,
    session_name           TEXT,
    message_count          BIGINT       NOT NULL DEFAULT 0,
    cached_tokens          BIGINT       NOT NULL DEFAULT 0,
    uncached_tokens        BIGINT       NOT NULL DEFAULT 0,
    total_tokens           BIGINT       NOT NULL DEFAULT 0,
    cost_total             NUMERIC(20, 8) NOT NULL DEFAULT 0,
    updated_at             TIMESTAMPTZ  NOT NULL,
    PRIMARY KEY (session_id),
    FOREIGN KEY (session_id)
        REFERENCES agent_session (session_id)
        ON DELETE CASCADE,
    FOREIGN KEY (session_id, current_leaf_entry_id)
        REFERENCES session_entry (session_id, entry_id),
    CHECK (revision >= 0),
    CHECK (next_append_seq > 0),
    CHECK (
        message_count >= 0
        AND cached_tokens >= 0
        AND uncached_tokens >= 0
        AND total_tokens >= 0
        AND cost_total >= 0
    )
);

CREATE TABLE session_label (
    session_id            VARCHAR(128) NOT NULL,
    target_entry_id       VARCHAR(128) NOT NULL,
    source_label_entry_id VARCHAR(128) NOT NULL,
    label                 TEXT         NOT NULL,
    updated_at            TIMESTAMPTZ  NOT NULL,
    PRIMARY KEY (session_id, target_entry_id),
    FOREIGN KEY (session_id, target_entry_id)
        REFERENCES session_entry (session_id, entry_id)
        ON DELETE CASCADE,
    FOREIGN KEY (session_id, source_label_entry_id)
        REFERENCES session_entry (session_id, entry_id)
        ON DELETE CASCADE,
    CHECK (LENGTH(TRIM(label)) > 0)
);

CREATE TABLE session_file_operation (
    session_id       VARCHAR(128) NOT NULL,
    source_entry_id  VARCHAR(128) NOT NULL,
    operation_type   VARCHAR(16)  NOT NULL,
    file_path        TEXT         NOT NULL,
    created_at       TIMESTAMPTZ  NOT NULL,
    PRIMARY KEY (
        session_id,
        source_entry_id,
        operation_type,
        file_path
    ),
    FOREIGN KEY (session_id, source_entry_id)
        REFERENCES session_entry (session_id, entry_id)
        ON DELETE CASCADE,
    CHECK (operation_type IN ('read', 'modified')),
    CHECK (LENGTH(file_path) > 0)
);

CREATE INDEX idx_agent_session_created
    ON agent_session (created_at DESC, session_id);

CREATE INDEX idx_agent_session_parent
    ON agent_session (parent_session_id);

CREATE INDEX idx_session_entry_parent
    ON session_entry (session_id, parent_entry_id);

CREATE INDEX idx_session_entry_type_seq
    ON session_entry (session_id, entry_type, append_seq);

CREATE INDEX idx_session_write_operation_session
    ON session_write_operation (session_id, started_at);

CREATE INDEX idx_session_label_source
    ON session_label (session_id, source_label_entry_id);

CREATE INDEX idx_session_file_operation_path
    ON session_file_operation (file_path);

INSERT INTO memory_schema_version (
    component,
    schema_version,
    installed_at
) VALUES (
    'session-memory',
    1,
    CURRENT_TIMESTAMP
);
```

DDL 有意不包含：

- `tenant_id` 和任何多租户约束。
- `session_leaf_event`；`leaf` entry 已承担不可变导航事实。
- SQLite `branch_entries`；集中式 v1 通过递归 CTE读取路径。
- payload 通用 GIN 索引；当前查询不按任意 JSON 字段过滤，避免无依据的写放大。
- 分布式 `DISTRIBUTE BY`；当前数据库明确为集中式。

`session_write_operation.session_id` 有意不建立 session 外键，使 create 可以先占用幂等键，并使 delete 后仍能返回稳定结果。被 entry 引用的 operation 与 session entry 同生命周期；未被 entry 引用的 create/delete operation，以及 session 删除后成为孤立记录的 operation，按幂等保留期清理。`session_entry` 的复合外键保证 entry 与 operation 的 session 一致。

entry 的 type-specific 引用，例如 `leaf.targetId`、`label.targetId`、`compaction.firstKeptEntryId` 和 `branch_summary.fromId`，由 `SessionEntryCodec` 在写入前校验属于同一 session。current leaf 和 label 投影另外使用数据库外键保护。

## 8. 路径查询与 Context rebuild

### 8.1 完整活动路径

读取先获得 state 的 `revision` 和 `current_leaf_entry_id`，再在同一只读事务快照中执行递归查询：

```sql
WITH RECURSIVE active_path AS (
    SELECT
        e.session_id,
        e.entry_id,
        e.parent_entry_id,
        e.append_seq,
        e.entry_type,
        e.event_time,
        e.payload,
        0 AS depth
    FROM agent_session_state s
    JOIN session_entry e
      ON e.session_id = s.session_id
     AND e.entry_id = s.current_leaf_entry_id
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
    FROM active_path child
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
FROM active_path
ORDER BY depth DESC;
```

空 session 的 current leaf 为 null，直接返回空路径。Repository 设置最大允许深度和 statement timeout；超限返回 `INVALID_ENTRY`，不返回部分路径。

SQL 始终读取完整活动路径，Java 再应用 compaction。这样 model、thinking level 和 active tools 不会因为数据库提前截断 compaction 之前的状态 entry 而丢失。

### 8.2 Context 投影

```text
fullPath = recursivePath(currentLeaf)
state = deriveModelThinkingAndTools(fullPath)
latestCompaction = last compaction in fullPath

if no compaction:
  contextEntries = fullPath
else if latestCompaction.retainedTail exists:
  contextEntries = [latestCompaction] + entriesAfterCompaction
else:
  contextEntries =
    [latestCompaction]
    + entriesFromFirstKeptBeforeCompaction
    + entriesAfterCompaction

messages = project(contextEntries)
```

`project(compaction)` 输出 summary message 后紧接 stored `retainedTail`。`leaf`、label、session info、model/thinking/tools change 不直接产生模型消息。

![Database context rebuild](./diagrams/memory/memory-context-rebuild.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L219)

## 9. 事务、并发和幂等

### 9.1 通用写事务

![Write transaction sequence](./diagrams/memory/memory-write-transaction.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L57)

```text
BEGIN
  INSERT session_write_operation(status = started)
    ON CONFLICT (operation_id) DO NOTHING

  if operation already exists:
    verify session_id, operation_type, request_hash
    if committed:
      return stored result after transaction completes

  SELECT agent_session_state
    WHERE session_id = ?
    FOR UPDATE

  verify expected_revision
  verify expected_leaf_entry_id
  validate all referenced entries
  allocate append_seq values
  INSERT immutable session_entry row(s)
  update session_label/session_file_operation projections
  UPDATE agent_session_state
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

投影与 entry 在同一事务中更新。`ProjectionRebuilder` 在维护窗口内按 `append_seq` 重放 entry 到临时表，校验计数和摘要后原子切换或覆盖目标投影。重建不改 entry、current leaf、revision 或 operation。

损坏 payload 的策略：

- 新写入在事务前由 `SessionEntryCodec` 拒绝，返回 `INVALID_ENTRY`。
- 已持久化损坏 entry 在分页管理接口中标记错误，在 context rebuild 中使整个 snapshot 失败。
- 不复制 SQLite 的静默 skip 行为，避免模型接收不完整且未告警的上下文。

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
| `REVISION_CONFLICT` | expected revision/leaf 与 state 不一致 |
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
6. 重建标签、名称、统计和文件操作投影。
7. current leaf 默认取最后 entry；如果文件含新 harness leaf entry，则按 leaf target 计算。
8. 生成 entry 数、内容 hash、孤儿和解析错误报告。

旧 coding-agent JSONL 不记录“最后一次只移动 leaf”的状态，导入器不得伪造该 leaf；报告中标记 `UNRECOVERABLE_LEAF_MOVE`。

### 11.2 SQLite 导入

- 以 `sessions`、`session_entries` 和 `active_leaf_id` 为事实来源。
- 按 `entry_seq` 导入，保留 entry id、parent、timestamp 和 payload。
- 导入 `leaf` 和 `retainedTail`。
- `branch_entries`、`session_materialized` 和 `entry_materialized` 不直接复制，目标投影统一重建。
- 校验源 active leaf 与重放 leaf entry 得到的状态；不一致时停止该 session 导入。

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
- JSONB payload 大小、session entry 数和单次 import 大小。
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
- model、thinking level 和 active tools 从完整活动路径推导。
- fork 默认 before、显式 at、非法目标和 entry id 保留。

### 13.2 数据库事务

- append 的 entry、state、operation 和投影原子提交或回滚。
- move 写 leaf marker，但 state 指向 target。
- 带 summary 的 move 在一次命令中写两个 entry，只增加一次 revision。
- 同 operation 并发 retry 只产生一组 entry。
- 相同 operation id 不同 hash 返回 `IDEMPOTENCY_KEY_REUSE`。
- revision/leaf 冲突、锁等待、statement timeout 和连接中断。
- projection 重建结果与在线投影一致。

### 13.3 JDBC compatibility suite

必须使用精确版本 `6.0.0-htrunks.csi.gaussdb_kernel.opengaussjdbc.r1`，不允许用其他版本代测：

- `org.opengauss.Driver` 加载和 `jdbc:opengauss:` URL。
- TLS、认证、连接池 validation query 和 failover 后重连。
- JSONB insert、update、null、Unicode、大 payload 和读取。
- 递归 CTE、复合外键、`SELECT ... FOR UPDATE` 和事务回滚。
- prepared statement、batch insert、NUMERIC cost 和 TIMESTAMPTZ。
- 唯一键、外键、锁超时、statement timeout 和连接错误的 SQLState 映射。
- schema migration 的事务性及重复执行保护。

### 13.4 迁移

- JSONL v1、v2、v3、新 harness leaf 和 retained tail。
- 当前 pi SQLite session、active leaf、labels 和 materialized state。
- 缺失 parent、非法 firstKept、错误 leaf target、坏 JSON 和重复 entry。
- entry 数、规范化 hash、活动路径、context messages 和最终 state parity。
- 旧 JSONL 未持久化 leaf move 的限制报告。

### 13.5 验收标准

- 相同合法活动树输入产生与 pi harness 等价的 context messages 和状态。
- 任意成功写命令后，entry、state、operation 和投影不存在部分可见状态。
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
| TD-MEM-04 | current state | header 与 `agent_session_state` 分表 | 架构选择 |
| TD-MEM-05 | active path | 递归 CTE，不复制 SQLite branch materialization | 架构选择 |
| TD-MEM-06 | compaction | `retainedTail` 为主，兼容 firstKept | 兼容约束 |
| TD-MEM-07 | 并发 | state 行锁 + revision + expected leaf + idempotency | 可靠性强化 |
| TD-MEM-08 | 损坏 entry | context 失败，不静默跳过 | 安全强化 |
| TD-MEM-09 | 多租户 | 不建模 | 产品范围约束 |
| TD-MEM-10 | 跨会话记忆 | 不建模，不增加向量索引 | 产品范围约束 |
| TD-MEM-11 | 原始 payload | 固定树列 + type-specific JSONB | Java 实现选择 |
| TD-MEM-12 | 摘要事务 | 模型调用在事务外，提交时校验 snapshot | 架构改造 |

## 15. 官方能力依据

- [GaussDB 实例类型：集中式与分布式](https://support.huaweicloud.com/intl/en-us/productdesc-gaussdb/gaussdb_01_013.html)
- [GaussDB Centralized V2.0-3.x `WITH RECURSIVE`](https://support.huaweicloud.com/intl/en-us/centralized-devg-v3-gaussdb/gaussdb-42-0649.html)
- [openGauss 6.0 JDBC 驱动类与兼容说明](https://docs.opengauss.org/en/docs/6.0.0/docs/DeveloperGuide/jdbc-package-driver-class-and-environment-class.html)
- [openGauss 6.0 JDBC 驱动加载](https://docs.opengauss.org/en/docs/6.0.0/docs/DeveloperGuide/loading-the-driver-jdbc.html)

这些公开文档只能证明标准产品能力。定制 JDBC 版本 `6.0.0-htrunks.csi.gaussdb_kernel.opengaussjdbc.r1` 的二进制兼容性必须由第 13.3 节测试确认。

## 16. 版本记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v0.5 | 2026-07-30 | 更新 pi 基线至 `fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc`；收敛为单租户会话内记忆；采用新 harness/SQLite 的 `leaf`、`active_tools_change` 和 `retainedTail`；数据库固定为集中式 GaussDB；锁定 openGauss JDBC 定制版本；以 state、operation 和可重建投影替代旧租户及 leaf event 模型 |
| v0.4 | 2026-07-20 | 将 SR 边界收敛为 Session Event Plane；基于主流 Agent 数据库调研明确拆分控制面、Runtime Checkpoint、跨会话长期记忆和 Artifact；为 Entry、Leaf Event、Write Operation 补齐复合外键与会话 revision 顺序；修正幂等操作先建记录再写结果的事务状态模型 |
| v0.3 | 2026-07-17 | 将 pi 源码基线更新为 `216e672e7c9fc65682553394b74e483c0c9e47f7`，重新核对记忆相关实现和源码锚点；确认 model runtime facade 变更未改变记忆语义 |
| v0.2 | 2026-07-16 | 为 DDL 草案中的全部表和字段补充数据库 COMMENT；不改变表结构和行为设计 |
| v0.1 | 2026-07-15 | 以 pi commit `dcfe36c79702ec240b146c45f167ab75ecddd205` 为基线，建立 Java ToB GaussDB 持久化、租户隔离、事务一致性、幂等和迁移设计；明确 Java target-only 差异 |
