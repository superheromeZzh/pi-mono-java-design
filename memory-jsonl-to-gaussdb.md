# pi-mono Java 集中式 GaussDB 会话存储 SR 设计

> 文档编号：SR-MEM-001
> 版本：v0.7
> 日期：2026-08-03
> 状态：设计评审稿
> pi 源码基线：[`f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee`](https://github.com/badlogic/pi-mono/tree/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee)
> Java 源码基线：无；本文 Java/GaussDB 内容均为 target-only design
> 数据库约束：集中式 GaussDB
> JDBC 约束：openGauss JDBC `6.0.0-htrunks.csi.gaussdb_kernel.opengaussjdbc.r1`

## 1. 结论

GaussDB Schema 以 pi-mono 当前 SQLite Schema 为唯一基线，执行物理对齐，而不再采用“业务语义对齐、数据库结构另行设计”的方式。

对齐规则如下：

- 表名与 SQLite 完全一致。
- 列名、可空性、主键、唯一索引、普通索引和 migration 顺序完全一致。
- `sessions`、`session_entries`、`session_sequences`、`branch_entries`、`branch_tips`、`session_materialized`、`entry_materialized` 和 `migrations` 均一对一保留。
- 只允许删除 SQLite 专属的 `WITHOUT ROWID`，并把 SQLite `INTEGER` sequence 映射为 GaussDB `BIGINT`。
- timestamp、metadata 和 JSON payload 继续保存为 TEXT，避免改变序列化、排序和搜索输入。
- 不增加 revision、operation、request hash、expected leaf、幂等表、额外搜索表、外键、CHECK、触发器或其他 GaussDB 专属结构。
- 事务内的 SQL 顺序、active leaf、materialized projection 和 branch cache 行为与 SQLite 一致。

这意味着 GaussDB 只替换存储引擎，不改变 SQLite Schema 所表达的数据模型。

![SQLite-aligned GaussDB architecture](./diagrams/memory/memory-architecture.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L1)

## 2. 范围与非目标

### 2.1 本期范围

- 按 SQLite migration `001_initial.sql` 和 `002_branch_tips.sql` 建立 GaussDB Schema。
- 保持 SessionStorage 和 SessionRepository 的 create、open、list、delete、fork、append、branch query 和 context 行为。
- 保持 entry sequence、materialized state、label projection、active leaf 和 branch cache 的事务一致性。
- 支持 JSONL/SQLite 数据导入和受控导出。
- 使用指定 openGauss JDBC 驱动访问集中式 GaussDB。

### 2.2 本期不包括

- revision、乐观锁、expected leaf 或 stale snapshot 协议。
- operation id、request hash、持久化幂等结果或写操作审计表。
- SQLite Schema 中不存在的外键、CHECK、级联删除、触发器或投影表。
- 多租户、RLS、向量检索、跨会话长期记忆和 Runtime Checkpoint。
- 用 GaussDB 全文检索结构替代 SQLite FTS5；该问题不能仅靠语法或类型适配解决。
- 分布式分片键或 `DISTRIBUTE BY`。

### 2.3 运行约束

SQLite backend 使用一个进程内 `SerialOperationQueue` 串行化数据库操作。目标 Java 适配器保留相同的单写入者语义，不在数据库层新增并发协议。

如果未来需要多个服务实例并发写同一 session，必须另立设计版本；不能在本版本中隐式增加 revision、行锁协议或幂等表。

数据库兼容模式必须保留空字符串，不得把空字符串转换为 NULL；文本比较和索引排序必须使用与 SQLite 默认 `BINARY` 接近的大小写敏感二进制 collation。这些是部署前提，不增加表、列或索引。

## 3. pi SQLite 源码事实

本节只记录基线提交中观察到的实现。后续 GaussDB 内容是对该实现的直接移植。

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

源码证据：

- [`migrations.ts`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/migrations.ts#L1-L55)
- [`001_initial.sql`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/migrations/001_initial.sql#L1-L59)
- [`002_branch_tips.sql`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/migrations/002_branch_tips.sql#L1-L12)

### 3.2 Session、entry 和 sequence

`sessions.active_leaf_id` 保存当前 leaf。`session_entries` 以 `(session_id, id)` 为主键，并以 `(session_id, entry_seq)` 保证 append 顺序唯一。`session_sequences` 为每个 session 保存下一条 sequence。

entry payload 是 type-specific JSON TEXT。base 字段 `id`、`parentId`、`timestamp` 和 `type` 分别保存在固定列中，读取时重新组合为 `SessionTreeEntry`。

源码证据：

- [`session-entries.ts`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/session-entries.ts#L1-L217)
- [`session-sequences.ts`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/session-sequences.ts#L1-L16)
- [`sessions.ts`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/storage/sessions.ts#L1-L40)

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

## 4. Schema 一对一映射

| SQLite 表 | GaussDB 表 | 列对齐 | 允许的适配 |
|---|---|---|---|
| `migrations` | `migrations` | `id`, `applied_at` | 无类型变化 |
| `sessions` | `sessions` | `id`, `created_at`, `cwd`, `parent_session_id`, `metadata`, `active_leaf_id` | 无类型变化 |
| `session_entries` | `session_entries` | `session_id`, `id`, `entry_seq`, `parent_id`, `type`, `timestamp`, `payload` | sequence 使用 `BIGINT` |
| `session_sequences` | `session_sequences` | `session_id`, `next_seq` | sequence 使用 `BIGINT` |
| `branch_entries` | `branch_entries` | `session_id`, `branch_id`, `entry_id`, `entry_seq` | sequence 使用 `BIGINT` |
| `branch_tips` | `branch_tips` | `session_id`, `tip_id`, `branch_id` | 无类型变化 |
| `session_materialized` | `session_materialized` | `session_id`, `payload` | payload 保持 TEXT |
| `entry_materialized` | `entry_materialized` | `session_id`, `entry_seq`, `type`, `payload` | sequence 使用 `BIGINT` |

目标 Schema 不包含任何第九张业务表。

### 4.1 类型映射

| SQLite 声明 | GaussDB 声明 | 理由 |
|---|---|---|
| 标识符 `TEXT` | `TEXT` | 不增加 SQLite 没有的长度约束 |
| entry/materialized type `TEXT` | `TEXT` | 保留原始字符串语义 |
| sequence `INTEGER` | `BIGINT` | 保留 SQLite INTEGER 的 64 位范围 |
| timestamp `TEXT` | `TEXT` | 保留 ISO 字符串原值和词法排序 |
| metadata/payload `TEXT` | `TEXT` | 保留 JSON 原文和解码行为 |
| cwd `TEXT` | `TEXT` | 保留路径原文 |

### 4.2 明确禁止的结构

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
- migration checksum
- SQLite Schema 中不存在的外键、CHECK、cascade 和 trigger

![SQLite-aligned data model](./diagrams/memory/memory-data-model.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L113)

## 5. Java 和 JDBC 边界

### 5.1 Java 接口

Java 继续实现 pi 的 `SessionStorage` 和 `SessionRepository` 契约，不增加数据库专属命令字段。

```java
interface MemorySessionApplicationService {
    SessionView createSession(CreateSessionCommand command);
    SessionView openSession(String sessionId);
    List<SessionSummary> listSessions(SessionListQuery query);
    void deleteSession(String sessionId);
    SessionView forkSession(ForkSessionCommand command);
    AppendResult appendEntry(AppendEntryCommand command);
    MoveResult moveTo(MoveToCommand command);
    ContextSnapshot loadContext(LoadContextQuery query);
    EntryPage pageEntries(EntryPageQuery query);
    List<SessionEntryView> findEntriesOnBranch(BranchEntryQuery query);
}
```

command 不包含 operation id、expected revision 或 expected leaf。并发模型与 SQLite 一样由 Repository 串行队列约束。

### 5.2 模块职责

| 组件 | 职责 |
|---|---|
| `MemorySessionApplicationService` | 编排 session 操作，不直接拼 SQL |
| `GaussDbSessionRepository` | create、open、list、delete、fork |
| `GaussDbSessionStorage` | entry、head、projection、branch query |
| `GaussDbMigrationRunner` | 按 SQLite migration id 和顺序执行适配后的 SQL |
| `GaussDbTransactionManager` | 提供与 SQLite transaction callback 等价的事务边界 |

### 5.3 JDBC 约束

| 项目 | 固定选择 |
|---|---|
| Maven 坐标 | `org.opengauss:opengauss-jdbc:6.0.0-htrunks.csi.gaussdb_kernel.opengaussjdbc.r1` |
| 驱动类 | `org.opengauss.Driver` |
| URL | `jdbc:opengauss://host:port/database` |
| Java API | `DataSource`, `Connection`, `PreparedStatement`, `ResultSet` |
| JSON | 作为 String 绑定和读取，不使用驱动特有 JSONB object |

应用账号执行 DML；migration 身份执行 DDL。定制 JDBC 的实际行为必须通过 compatibility suite 验证，不能从其他 openGauss JDBC 版本推断。

## 6. GaussDB DDL

DDL 分为 bootstrap、`001_initial.sql` 和 `002_branch_tips.sql`。migration id 与 SQLite 完全一致。

### 6.1 Bootstrap：`migrations`

```sql
CREATE TABLE IF NOT EXISTS migrations (
    id          TEXT PRIMARY KEY,
    applied_at  TEXT NOT NULL
);
```

应用仍按 `SELECT id FROM migrations ORDER BY applied_at, id` 判断已执行 migration。每个 migration 和对应 `migrations` insert 在同一事务中完成。

### 6.2 `001_initial.sql`

```sql
CREATE TABLE IF NOT EXISTS sessions (
    id                 TEXT PRIMARY KEY,
    created_at         TEXT NOT NULL,
    cwd                TEXT NOT NULL,
    parent_session_id  TEXT,
    metadata           TEXT,
    active_leaf_id     TEXT
);

CREATE INDEX IF NOT EXISTS idx_sessions_created_at
    ON sessions (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_sessions_cwd
    ON sessions (cwd);

CREATE INDEX IF NOT EXISTS idx_sessions_parent
    ON sessions (parent_session_id);

CREATE TABLE IF NOT EXISTS session_entries (
    session_id  TEXT   NOT NULL,
    id          TEXT   NOT NULL,
    entry_seq   BIGINT NOT NULL,
    parent_id   TEXT,
    type        TEXT   NOT NULL,
    timestamp   TEXT   NOT NULL,
    payload     TEXT   NOT NULL,
    PRIMARY KEY (session_id, id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_session_entries_session_seq
    ON session_entries (session_id, entry_seq);

CREATE INDEX IF NOT EXISTS idx_session_entries_session_parent
    ON session_entries (session_id, parent_id);

CREATE INDEX IF NOT EXISTS idx_session_entries_session_type
    ON session_entries (session_id, type);

CREATE TABLE IF NOT EXISTS session_sequences (
    session_id  TEXT PRIMARY KEY,
    next_seq    BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS branch_entries (
    session_id  TEXT   NOT NULL,
    branch_id   TEXT   NOT NULL,
    entry_id    TEXT   NOT NULL,
    entry_seq   BIGINT NOT NULL,
    PRIMARY KEY (session_id, branch_id, entry_id)
);

CREATE INDEX IF NOT EXISTS idx_branch_entries_session_branch
    ON branch_entries (session_id, branch_id);

CREATE INDEX IF NOT EXISTS idx_branch_entries_session_branch_seq
    ON branch_entries (session_id, branch_id, entry_seq);

CREATE INDEX IF NOT EXISTS idx_branch_entries_session_entry
    ON branch_entries (session_id, entry_id);

CREATE TABLE IF NOT EXISTS session_materialized (
    session_id  TEXT PRIMARY KEY,
    payload     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS entry_materialized (
    session_id  TEXT   NOT NULL,
    entry_seq   BIGINT NOT NULL,
    type        TEXT   NOT NULL,
    payload     TEXT   NOT NULL,
    PRIMARY KEY (session_id, entry_seq, type)
);

CREATE INDEX IF NOT EXISTS idx_entry_materialized_session_type_seq
    ON entry_materialized (session_id, type, entry_seq);
```

与 SQLite `001_initial.sql` 相比只做两类调整：删除 `WITHOUT ROWID`，sequence 使用 `BIGINT`。

### 6.3 `002_branch_tips.sql`

```sql
CREATE TABLE IF NOT EXISTS branch_tips (
    session_id  TEXT NOT NULL,
    tip_id      TEXT NOT NULL,
    branch_id   TEXT NOT NULL,
    PRIMARY KEY (session_id, tip_id),
    UNIQUE (session_id, branch_id)
);

DELETE FROM branch_tips;
DELETE FROM branch_entries;

DROP INDEX IF EXISTS idx_branch_entries_session_branch;
```

该 migration 与 SQLite 保持相同的清空和 drop 顺序，不把 branch cache 当作迁移事实源。

## 7. 查询与事务对齐

### 7.1 Create

一个 create transaction 依次插入：

1. `sessions`
2. `session_sequences(next_seq = 1)`
3. `session_materialized` 空 summary

不插入额外的 operation、state 或 audit row。

### 7.2 Append

![SQLite-aligned append transaction](./diagrams/memory/memory-write-transaction.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L57)

```text
BEGIN
  SELECT next_seq FROM session_sequences WHERE session_id = ?
  INSERT session_entries
  UPDATE session_sequences SET next_seq = next_seq + 1
  UPDATE session_materialized
  INSERT entry_materialized rows when required
  UPDATE sessions SET active_leaf_id = ?
  update branch_entries and branch_tips
COMMIT
```

SQL 顺序与 SQLite `appendEntry()` 一致。GaussDB 实现不得在这条路径中插入 revision、operation 或 search projection。

### 7.3 Leaf

`leaf` 是普通 `session_entries` row。append 后：

- leaf marker 保留在 append log。
- `sessions.active_leaf_id` 设置为 `leaf.targetId`，而不是 leaf marker id。
- `targetId = null` 时 active leaf 为 null。

### 7.4 Branch cache

GaussDB 直接使用 `branch_entries` 和 `branch_tips`：

- root append 建立新 branch 和 tip。
- 线性 append 扩展 tip。
- 从旧 parent 分叉时复制共享前缀。
- 缓存缺失或无效时，从 `session_entries.parent_id` 递归重建。
- 修复使用 savepoint，但不引入额外表或状态列。

### 7.5 Context

![SQLite-aligned context rebuild](./diagrams/memory/memory-context-rebuild.svg)

[查看 PlantUML 源码](./diagrams/memory/diagram.puml#L222)

```text
leaf = sessions.active_leaf_id
fullPath = validatedBranchCacheOrParentChain(leaf)
path = trimPathToRootOrCompaction(fullPath)
state = deriveModelThinkingAndTools(path)
messages = project(defaultContextEntryTransform(path))
```

GaussDB 不改变 compaction、`retainedTail`、`firstKeptEntryId` 或 custom projector 语义。

### 7.6 Delete

SQLite 没有外键或 cascade，Repository 按以下顺序删除：

1. `branch_tips`
2. `branch_entries`
3. `session_entries`
4. `entry_materialized`
5. `session_materialized`
6. `session_sequences`
7. `sessions`

GaussDB 保持相同的显式删除顺序，不使用 `ON DELETE CASCADE` 替代。

源码证据：[`SqliteSessionBackend.delete()`](https://github.com/badlogic/pi-mono/blob/f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee/packages/storage/sqlite-node/src/sqlite/repo.ts#L153-L168)

## 8. 数据迁移

### 8.1 SQLite 到 GaussDB

由于表名和列名一致，迁移按表直接复制：

1. 复制 `sessions`。
2. 复制 `session_entries`，保持 `entry_seq`、timestamp 和 payload 原文。
3. 复制 `session_sequences`。
4. 复制 `session_materialized` 和 `entry_materialized`。
5. 复制或重建 `branch_entries` 和 `branch_tips`。
6. 不复制源 `migrations` 行；由目标 migration runner 在实际执行适配后的 `001_initial.sql` 和 `002_branch_tips.sql` 时写入同名 id。

必须校验：

- 每表行数。
- `(session_id, id)` 和 `(session_id, entry_seq)` 集合。
- active leaf。
- materialized payload 原文或解析后结构。
- 每个 tip 的 root-to-tip entry id 顺序。
- context messages 和 Session state。

### 8.2 JSONL 导入

JSONL importer 只向上述 SQLite 对齐表写入，不创建额外状态或审计表。导入后按相同 projector 重建 materialized rows 和 branch cache。

### 8.3 回滚

切换前保留 SQLite 只读副本。GaussDB 可按相同表和列导出回 SQLite-compatible 数据集；不启用长期双写。

## 9. 测试与验收

### 9.1 Schema parity

- 表名集合严格等于 8 张 SQLite 核心表。
- 每张表列名、可空性和列顺序一致。
- 主键、唯一索引、普通索引名称及列顺序一致。
- `002_branch_tips.sql` 执行后删除 `idx_branch_entries_session_branch`。
- 不存在 revision、operation、search document 或其他额外表/列。

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
- migration SQL 和 `migrations` insert 同事务。

### 9.4 JDBC compatibility suite

必须使用指定定制 JDBC JAR 验证：

- 驱动加载、URL、TLS、认证和连接池。
- `CREATE TABLE/INDEX IF NOT EXISTS`、`DROP INDEX IF EXISTS`。
- TEXT primary key、复合 primary key 和 composite unique index。
- BIGINT sequence 的绑定与读取。
- Unicode、大 payload 和 JSON TEXT 原文保持。
- recursive CTE、window function、savepoint 和 transaction rollback。
- SQLState 到稳定 storage error 的映射。

### 9.5 验收标准

- SQLite 和 GaussDB Schema diff 只包含已批准的类型差异及 `WITHOUT ROWID` 删除。
- 相同数据产生相同的 session metadata、entry、active leaf、projection、branch query 和 context。
- GaussDB Schema 中没有 SQLite 基线之外的业务表、列、约束、索引或 trigger。
- 所有 DDL 在目标集中式 GaussDB 和指定 JDBC JAR 上通过 compatibility suite。

## 10. 安全与运维

安全措施不改变 Schema：

- JDBC 强制 TLS，凭据来自部署 secret。
- 运行账号最小权限，migration 账号和 DML 账号分离。
- SQL 全部参数化。
- payload 和 metadata 默认不写普通日志。
- 限制单 entry payload、单 session entry 数和递归路径深度。
- 监控事务失败、锁等待、连接失败、branch cache repair 和 migration 失败。

## 11. 设计决策

| ID | 决策 | 分类 |
|---|---|---|
| TD-MEM-01 | 表名和列名完全使用 SQLite Schema | SQLite 物理对齐 |
| TD-MEM-02 | 删除 `WITHOUT ROWID` | GaussDB 语法适配 |
| TD-MEM-03 | sequence `INTEGER` 映射为 `BIGINT` | GaussDB 类型适配 |
| TD-MEM-04 | 所有 SQLite TEXT 列继续使用 TEXT | SQLite 类型语义对齐 |
| TD-MEM-05 | timestamp、metadata、payload 保持 TEXT | SQLite 值语义对齐 |
| TD-MEM-06 | 不增加外键、CHECK、cascade 或 trigger | 禁止额外设计 |
| TD-MEM-07 | 不增加 revision 或幂等 operation | 禁止额外设计 |
| TD-MEM-08 | 不建立 GaussDB 搜索投影表 | FTS5 无直接语法/类型映射 |
| TD-MEM-09 | Repository 保持 SQLite 串行写模型 | SQLite 运行行为对齐 |

## 12. 官方能力依据

- [GaussDB 实例类型：集中式与分布式](https://support.huaweicloud.com/intl/en-us/productdesc-gaussdb/gaussdb_01_013.html)
- [SQLite `WITHOUT ROWID`](https://www.sqlite.org/withoutrowid.html)
- [SQLite 数据类型](https://www.sqlite.org/datatype3.html)
- [SQLite FTS5](https://www.sqlite.org/fts5.html)
- [GaussDB `CREATE TABLE`](https://support.huaweicloud.com/intl/en-us/centralized-devg-v8-gaussdb/gaussdb-42-0573.html)
- [GaussDB 数值类型](https://support.huaweicloud.com/intl/en-us/centralized-devg-v3-gaussdb/gaussdb-42-0329.html)
- [GaussDB 字符类型](https://support.huaweicloud.com/intl/en-us/centralized-devg-v8-gaussdb/gaussdb-42-0335.html)
- [GaussDB `CREATE INDEX`](https://support.huaweicloud.com/centralized-devg-v8-gaussdb/gaussdb-42-0552.html)
- [GaussDB `DROP INDEX`](https://support.huaweicloud.com/intl/en-us/centralized-devg-v8-gaussdb/gaussdb-42-0607.html)
- [GaussDB 事务控制](https://support.huaweicloud.com/intl/en-us/centralized-devg-v8-gaussdb/gaussdb-42-0468.html)
- [GaussDB Centralized V2.0-3.x `WITH RECURSIVE`](https://support.huaweicloud.com/intl/en-us/centralized-devg-v3-gaussdb/gaussdb-42-0649.html)
- [openGauss 6.0 JDBC 驱动类与兼容说明](https://docs.opengauss.org/en/docs/6.0.0/docs/DeveloperGuide/jdbc-package-driver-class-and-environment-class.html)
- [openGauss 6.0 JDBC 驱动加载](https://docs.opengauss.org/en/docs/6.0.0/docs/DeveloperGuide/loading-the-driver-jdbc.html)

公开文档只能证明标准能力。定制 JDBC 版本和实际服务端仍必须通过第 9.4 节测试。

## 13. 版本记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v0.7 | 2026-08-03 | 将 GaussDB 从“SQLite 行为对齐 + 可靠性扩展”收敛为 SQLite 物理 Schema 对齐；表名、列名、主键、索引和 migration id 与 SQLite 一致；删除 revision、operation、checksum、额外搜索投影、外键和 CHECK；仅删除 `WITHOUT ROWID` 并把 sequence `INTEGER` 映射为 `BIGINT` |
| v0.6 | 2026-08-03 | 更新 pi 基线至 `f0deb8dd8e9611e89b5bc4145ca92c03ae6ed4ee`；对齐 sequence、materialized projection、branch cache、bounded branch query、search 和 compaction-trimmed context；保留 revision/idempotency 扩展 |
| v0.5 | 2026-07-30 | 更新 pi 基线至 `fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc`；采用新 harness leaf、active tools 和 retainedTail；数据库固定为集中式 GaussDB |
| v0.4 | 2026-07-20 | 将 SR 边界收敛为 Session Event Plane，拆分控制面、Runtime Checkpoint、长期记忆和 Artifact |
| v0.3 | 2026-07-17 | 更新 pi 源码基线并核对记忆实现 |
| v0.2 | 2026-07-16 | 为 DDL 表和字段补充数据库说明 |
| v0.1 | 2026-07-15 | 建立 Java ToB GaussDB 持久化、事务和迁移设计 |
