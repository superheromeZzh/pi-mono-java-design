# 研发预置 Agent 元数据数据库与管理面 API 设计

> 文档编号：`SR-AGENT-DB-001`<br>
> 版本：`v0.1.0`<br>
> 日期：`2026-07-28`<br>
> 状态：目标设计（target-only）<br>
> 仓库基线：`a3cbc53e32194c03b6a9ddbadae7be37b7822226`<br>
> Java 实现基线：无；仓库中不存在对应数据库或管理面实现

## 1. 结论

本设计建议把“研发预置的 Agent”实现为三个层次，而不是让管理面直接覆盖一行 JSON：

1. `Preset Revision`：研发发布的不可变原始配置。
2. `Admin Override Revision`：管理面只拥有 `display_name` 与 `models` 两个字段的稀疏覆盖。
3. `Agent Version`：Preset 与 Override 合并后的不可变有效快照，供查询、编译和 Session 固定引用。

管理面 V1 提供列表、详情、版本历史、更新、恢复、审计和模型选项查询；不提供创建、删除、归档，也不能修改 `name`、系统提示、Tool/Skill 绑定或权限。

每次产生实际有效变化时，`version` 加一。更新必须携带 `If-Match`，并使用 `Idempotency-Key` 防止重试重复写入。无实际变化时返回当前版本，不制造空版本。

`models` 在 V1 中定义为“该 Agent 可使用的模型 ID 集合”，不是隐式 fallback 顺序。运行时选择的 `model_id` 必须属于该集合；如后续需要默认模型或降级路线，应增加独立的 `default_model_id` / `routing_policy`，不能借用数组顺序表达。

## 2. 需求边界

### 2.1 本轮范围

- 研发通过发布流程预置或升级 Agent 元数据。
- 管理面按权限分页查询 Agent。
- 管理面仅更新 `display_name` 和 `models`。
- 保存完整版本历史，支持查看和恢复可管理字段。
- 提供乐观并发、幂等、审计、缓存失效和模型网关校验。
- 保存 Tool、Skill 与权限的版本化引用，供运行时编译有效计划。

### 2.2 不在本轮范围

- 管理面创建自定义 Agent。
- 管理面修改 `system_prompt`、`use_cases`、Tool/Skill 绑定或 Permission。
- Secret、模型网关凭据、MCP 凭据或运行环境 Binding。
- Session、Thread、Message、Checkpoint 与长期 Memory。
- Tool、Skill、Model Gateway 自身的表结构。
- Session 级 Agent 覆盖。

这些对象具有不同生命周期，不应放进 Agent 元数据表。

## 3. 证据、观察与目标设计

### 3.1 本地输入基线

本设计完整分析了工作区当前的 [`AGENT元数据设计.json`](../AGENT元数据设计.json)。该文件相对仓库基线存在用户未提交修改，因此同时记录内容摘要：

- 工作区文件 SHA-256：`7c7ef5ada3bd5ef4e33c411b323392ee7032ba2f54de8cece401e9c47501b05a`。
- `id`、`type`、`version`、时间字段：[第 2–6 行](../AGENT元数据设计.json#L2)。
- 稳定名称、展示名称、描述和模型列表：[第 7–10 行](../AGENT元数据设计.json#L7)。
- 分段系统提示：[第 11–20 行](../AGENT元数据设计.json#L11)。
- 使用场景、Tool/Skill 绑定与权限：[第 21–46 行](../AGENT元数据设计.json#L21)。

相关引用还对照了：

- [`TOOL元数据设计.json`](../TOOL元数据设计.json)：Tool 有独立 ID、版本、来源、Schema 与默认权限。
- [`SKILL元数据设计.json`](../SKILL元数据设计.json)：Skill 有独立 ID、版本、Tool/Skill 绑定和权限。
- [`anthropic-managed-agents-public-model/README.md`](../anthropic-managed-agents-public-model/README.md)：Anthropic Agent、版本、Session 快照及 Tool/Skill 公开契约。
- [`agent-database-patterns/README.md`](../agent-database-patterns/README.md)：控制面、会话面、Checkpoint、长期记忆和治理面的拆分边界。

### 3.2 Anthropic Managed Agents 官方契约

核对日期为 `2026-07-28`。Anthropic 是托管服务，没有公开数据库或服务端源码；下面只把官方 HTTP 契约作为 API 设计参考，不推断其内部表结构：

| 官方能力 | 官方接口 | 可观察行为 | 本设计取舍 |
|---|---|---|---|
| 创建 Agent | [`POST /v1/agents`](https://platform.claude.com/docs/en/api/beta/agents/create) | 创建版本化 Agent，服务端返回 ID、版本和时间 | 管理面不开放；改为内部 Preset Provisioning API |
| 列表 | [`GET /v1/agents`](https://platform.claude.com/docs/en/api/beta/agents/list) | Cursor 分页，默认 20、最大 100，可按创建时间过滤 | 采用 Cursor 分页，并增加管理面需要的名称与模型过滤 |
| 详情 | [`GET /v1/agents/{agent_id}`](https://platform.claude.com/docs/en/api/beta/agents/retrieve) | 返回当前完整 Agent | 采用；按 RBAC 区分摘要和敏感详情 |
| 更新 | [`POST /v1/agents/{agent_id}`](https://platform.claude.com/docs/en/api/beta/agents/update) | 字段省略表示保留；数组整体替换；`version` 可选，传入不匹配时并发失败 | 采用整体替换和版本语义；安全加固为 `PATCH` + 强制 `If-Match` |
| 版本历史 | [`GET /v1/agents/{agent_id}/versions`](https://platform.claude.com/docs/en/api/beta/agents/versions/list) | 分页返回历史版本 | 采用，并补充单版本详情和受控恢复 |
| 归档 | [`POST /v1/agents/{agent_id}/archive`](https://platform.claude.com/docs/en/api/beta/agents/archive) | 不可逆归档；旧 Session 继续，新 Session 不可引用 | 管理面 V1 不开放；生命周期由研发发布流程管理 |

### 3.3 观察行为、目标决定与原因

| 分类 | 内容 |
|---|---|
| 观察到的本地定义 | Agent 有稳定 ID、递增版本、`display_name`、`models`、系统提示、使用场景、版本化 Tool/Skill 引用和三态权限。 |
| 观察到的 Anthropic 契约 | Agent 是版本化资源；更新支持乐观并发；数组按完整字段替换；可查询版本历史；Session 可固定具体 Agent 版本。 |
| 目标产品约束 | 管理面只能读，以及更新 `display_name` / `models`；创建和其他字段更新属于研发预置流程。 |
| 安全强化 | 强制乐观锁、租户作用域、字段 allowlist、Model Gateway 校验、不可变审计和日志脱敏。 |
| 架构改造 | 将研发 Preset、管理员 Override 与有效 Agent Version 分开；使用事务 Outbox 通知运行时。 |
| 设计原因 | 字段所有权分离后，研发升级系统提示或绑定不会覆盖管理员配置；有效快照又保证历史 Session 可重放。 |

## 4. 资源与字段所有权

### 4.1 字段矩阵

| 字段 | 来源 | 管理面可见 | 管理面可更新 | 版本行为 |
|---|---|---:|---:|---|
| `id` | 服务端 | 是 | 否 | 永不变化 |
| `type` | 服务端固定 `agent` | 是 | 否 | 永不变化 |
| `name` | 研发 Preset | 是 | 否 | 稳定业务键；发布后不可改名 |
| `display_name` | Preset 默认值 + Admin Override | 是 | 是 | 有效值变化时新版本 |
| `description` | 研发 Preset | 是 | 否 | Preset 升级时可产生新版本 |
| `models` | Preset 默认集合 + Admin Override | 是 | 是 | 集合变化时新版本 |
| `system_prompt` | 研发 Preset | 详情可见 | 否 | Preset 升级时可产生新版本 |
| `use_cases` | 研发 Preset | 详情可见 | 否 | Preset 升级时可产生新版本 |
| `binding_tools` | 研发 Preset | 详情可见 | 否 | Preset 升级时可产生新版本 |
| `binding_skills` | 研发 Preset | 详情可见 | 否 | Preset 升级时可产生新版本 |
| `permission` | 研发 Preset | 详情可见 | 否 | Preset 升级时可产生新版本 |
| `version` | 服务端 | 是 | 否 | 有效内容发生变化时递增 |
| `created_at` / `updated_at` | 服务端 | 是 | 否 | RFC 3339 UTC |

### 4.2 `models` 的准确语义

V1 约束如下：

- 是非空、无重复的 Model Gateway `model_id` 集合。
- 不表示优先级、默认值或 fallback 次序。
- 请求和哈希前按 `model_id` 进行规范化排序，因此仅调整数组顺序不会生成新版本。
- 运行时显式选择模型；选择值必须在有效 Agent Version 的集合内。
- Model Gateway 中已下线的模型不会从历史版本中删除；管理详情通过 `availability` 投影显示其当前状态。
- 如果所有模型都不可用，Agent 仍保留历史定义，但新 Session 创建应返回机器可读的 `AGENT_HAS_NO_AVAILABLE_MODEL`。

这解决了当前 JSON 只声明复数 `models`、但没有声明路由策略的问题。把数组第一项解释为默认模型会形成未经需求确认的隐藏行为，因此本设计不这样做。

### 4.3 Tool/Skill 版本引用

`binding_tools[].version` 和 `binding_skills[].version` 省略时表示 `LATEST`，不是数据库写入时自动改写成当前数字。Agent Version 保存：

- `resolution_mode = PINNED` 与明确 `requested_version`；或
- `resolution_mode = LATEST` 与空 `requested_version`。

Runtime 在创建不可变 `ResolvedAgentPlan` 或 Session Snapshot 时，把 `LATEST` 解析为具体版本并固定。这样既忠实保留研发声明，也能保证一次运行不会随 Tool/Skill 后续发布漂移。

### 4.4 Permission 合并

一个 Tool ID 在同一 Agent Version 中最多出现一次，三态优先级固定为：

```text
DENY > ASK > ALLOW
```

Preset Validator 应拒绝同一个 `tool_id` 同时出现在多个数组，不能依靠运行时临时猜测。运行时还要与 Tool 自身权限及环境策略合并，最终结果只能比 Agent 声明更严格。

## 5. 数据库设计

![Agent 元数据存储模型](./agent_metadata_storage_model.svg)

PlantUML：[查看源码](./diagram.puml#L6)

### 5.1 总体原则

- 所有主键、外键和唯一约束都包含 `tenant_id`；租户来自认证上下文，不接受调用方任意指定。
- `agent_definition` 是稳定身份、当前指针和行锁边界。
- Preset、Override 与有效 Version 均为追加式不可变数据。
- `agent_version` 及其子表是运行时和历史查询的有效事实源。
- 只把需要编辑、过滤、约束或独立引用的数组规范化；原始 Preset JSON 额外保留用于来源审计和重放。
- 所有时间使用 `TIMESTAMPTZ` 和 UTC。
- 不用数据库自增值作为跨租户公开 ID；公开 `agent_id` 使用不可枚举 ID。
- Secret 和凭据不得进入任何 Agent 表。

### 5.2 核心表

#### `agent_definition`

稳定资源和当前 Head：

| 列 | 类型 | 约束/用途 |
|---|---|---|
| `tenant_id` | `VARCHAR(64)` | PK；认证作用域 |
| `agent_id` | `VARCHAR(64)` | PK；公开不可枚举 ID |
| `name` | `VARCHAR(128)` | `UNIQUE(tenant_id, name)`；研发稳定键 |
| `lifecycle_status` | `VARCHAR(16)` | `ACTIVE` / `RETIRED`；只由发布流程改变 |
| `current_preset_revision` | `BIGINT` | 当前研发基线 |
| `current_override_revision` | `BIGINT NULL` | 当前管理覆盖；空表示完全继承 |
| `current_version` | `BIGINT` | 当前有效 Agent Version |
| `created_at` | `TIMESTAMPTZ` | 创建时间 |
| `updated_at` | `TIMESTAMPTZ` | Head 最近变化时间 |

更新时先以 `(tenant_id, agent_id)` 锁定本行，再比较 `current_version`。它是 CAS 和单 Agent 写串行化边界。

Head 到当前 Preset、Override、Version 的外键应声明为可延迟校验，在事务提交时确认完整，便于首次创建时原子插入相互引用的 Root 和 Revision；事务外永远不能观察到半成品 Head。

#### `agent_preset_revision`

研发发布的不可变原始输入：

| 列 | 类型 | 约束/用途 |
|---|---|---|
| `tenant_id, agent_id, preset_revision` | 复合 PK | Agent 内从 1 递增 |
| `source_kind` | `VARCHAR(32)` | `DATABASE_SEED` / `RELEASE_BUNDLE` |
| `source_revision` | `VARCHAR(128)` | 发布版本、Git commit 或制品 digest |
| `manifest_json` | `JSONB` | 通过 Schema 校验后的完整研发 Preset |
| `manifest_sha256` | `CHAR(64)` | 规范化 JSON 摘要 |
| `created_by` | `VARCHAR(128)` | 发布主体 |
| `created_at` | `TIMESTAMPTZ` | 写入时间 |

唯一约束：

```text
UNIQUE (tenant_id, agent_id, source_kind, source_revision)
```

另对 `(tenant_id, agent_id, manifest_sha256)` 建普通索引。相同来源版本和内容重复提交是幂等成功；相同来源版本但摘要不同必须冲突，避免重写发布历史。不同发布版本允许携带相同内容，以完整记录研发来源历史。

#### `agent_override_revision`

管理员可控字段的完整覆盖状态，不保存 Patch 增量：

| 列 | 类型 | 约束/用途 |
|---|---|---|
| `tenant_id, agent_id, override_revision` | 复合 PK | Agent 内从 1 递增 |
| `display_name_override` | `VARCHAR(160) NULL` | 空表示继承当前 Preset |
| `models_override_enabled` | `BOOLEAN` | `false` 表示继承 Preset；`true` 表示使用子表集合 |
| `created_by` | `VARCHAR(128)` | 管理员主体 |
| `reason` | `VARCHAR(512) NULL` | 可选变更原因 |
| `created_at` | `TIMESTAMPTZ` | 写入时间 |

`agent_override_model` 以 `(tenant_id, agent_id, override_revision, model_id)` 为主键。只在 `models_override_enabled = true` 时存在，且至少一行。该跨表不变量由同一事务中的领域服务保证。

#### `agent_version`

Preset 与 Override 合并后的不可变有效版本：

| 列 | 类型 | 约束/用途 |
|---|---|---|
| `tenant_id, agent_id, version` | 复合 PK | 对外 `version` |
| `preset_revision` | `BIGINT` | 产生此版本的研发输入 |
| `override_revision` | `BIGINT NULL` | 产生此版本的管理覆盖 |
| `display_name` | `VARCHAR(160)` | 有效展示名；列表索引 |
| `description` | `VARCHAR(4096)` | 有效描述；列表投影 |
| `system_prompt` | `JSONB` | 分段系统提示 |
| `content_sha256` | `CHAR(64)` | 全部有效字段的规范化摘要 |
| `runtime_sha256` | `CHAR(64)` | 排除纯展示字段后的运行配置摘要 |
| `change_origin` | `VARCHAR(16)` | `PRESET` / `ADMIN` / `RESTORE` |
| `created_by` | `VARCHAR(128)` | 变更主体 |
| `created_at` | `TIMESTAMPTZ` | 版本创建时间 |

`display_name` 修改会增加 `version`，但不会改变 `runtime_sha256`。Compiler 可据此避免无意义地重新编译运行计划。

`agent_version` 的结构化子表：

| 表 | 关键列 | 约束 |
|---|---|---|
| `agent_version_model` | `version, model_id` | 至少一行；模型集合；无顺序 |
| `agent_version_use_case` | `version, position, use_case` | `position` 唯一；保留研发顺序 |
| `agent_version_tool_binding` | `version, position, tool_id, resolution_mode, requested_version` | Tool ID 唯一；`PINNED` 时版本必填 |
| `agent_version_skill_binding` | `version, position, skill_id, resolution_mode, requested_version` | Skill ID 唯一；`PINNED` 时版本必填 |
| `agent_version_permission` | `version, tool_id, effect` | Tool ID 唯一；effect 为 `DENY/ASK/ALLOW` |

所有子表对 `(tenant_id, agent_id, version)` 建复合外键，防止跨租户引用。

### 5.3 操作治理表

#### `agent_write_operation`

用于 `Idempotency-Key`：

```text
PK (tenant_id, actor_id, idempotency_key)
request_sha256
status: STARTED | SUCCEEDED | FAILED
http_status
response_json
agent_id
agent_version
created_at
expires_at
```

同一个 Key 携带相同请求摘要时重放既有结果；携带不同摘要时返回 `409 IDEMPOTENCY_KEY_REUSED`。建议保留 24 小时，失败是否可重试由机器可读错误码决定。

`STARTED` 记录必须带租约截止时间。服务实例在主事务提交前崩溃时，同一请求可在租约过期后接管；成功响应与 Agent Head、Audit、Outbox 在同一主事务完成，避免“Agent 已更新但幂等结果未保存”。

#### `agent_audit_event`

追加式审计记录：

```text
tenant_id, event_id, agent_id, agent_version, action,
actor_id, request_id, before_sha256, after_sha256,
changed_fields, reason, source_ip_hash, created_at
```

`changed_fields` 只记录字段名、旧值/新值摘要和非敏感模型 ID。系统提示完整内容不复制进审计事件。

#### `agent_outbox_event`

与 Head 更新在同一事务提交，异步发布：

- `AgentVersionChanged`
- `AgentPresetReconciled`
- `AgentRetired`

消费者包括 Runtime Cache、Agent Compiler、检索索引和监控。事件至少包含 `tenant_id`、`agent_id`、`version`、`content_sha256`、`runtime_sha256`，不包含完整系统提示。

### 5.4 关键索引

```sql
CREATE UNIQUE INDEX uk_agent_name
    ON agent_definition (tenant_id, name);

CREATE INDEX idx_agent_active_updated
    ON agent_definition (tenant_id, lifecycle_status, updated_at DESC, agent_id);

CREATE INDEX idx_agent_version_display_name
    ON agent_version (tenant_id, display_name, agent_id, version);

CREATE INDEX idx_agent_name_ci
    ON agent_definition (tenant_id, LOWER(name));

CREATE INDEX idx_agent_display_name_ci
    ON agent_version (tenant_id, LOWER(display_name), agent_id, version);

CREATE INDEX idx_agent_current_model
    ON agent_version_model (tenant_id, model_id, agent_id, version);

CREATE INDEX idx_agent_version_history
    ON agent_version (tenant_id, agent_id, version DESC);

CREATE INDEX idx_agent_preset_hash
    ON agent_preset_revision (tenant_id, agent_id, manifest_sha256);

CREATE INDEX idx_agent_audit_time
    ON agent_audit_event (tenant_id, agent_id, created_at DESC, event_id);

CREATE INDEX idx_agent_outbox_pending
    ON agent_outbox_event (published_at, created_at)
    WHERE published_at IS NULL;
```

列表查询必须把 `agent_definition.current_version = agent_version.version` 放进 Join 条件；按模型过滤时，模型子表也必须绑定同一 `current_version`，不能误命中历史版本。

### 5.5 不采用“单表一个 JSON”的原因

单表 JSON 虽然写入简单，但会导致：

- `models` 过滤依赖 JSON 扫描或脆弱的表达式索引。
- 不能用唯一约束阻止重复模型或重复权限。
- Preset 升级和管理员更新互相覆盖。
- 当前状态与历史版本混在一起，Session 无法稳定固定版本。
- 版本比较、审计和恢复只能依赖整块 JSON Diff。

本设计仍保留 `agent_preset_revision.manifest_json`，但它是来源证据；运行时有效事实来自 `agent_version` 及其子表。

## 6. 管理面 API

### 6.1 通用约定

基础路径：

```text
/management/v1
```

公共 Header：

| Header | 适用接口 | 语义 |
|---|---|---|
| `Authorization` | 全部 | 身份与租户作用域 |
| `X-Request-Id` | 全部 | 链路追踪；缺省时服务端生成 |
| `If-Match` | 所有写接口 | 强制当前 Agent ETag |
| `Idempotency-Key` | 所有写接口 | 防止客户端超时重试重复写 |
| `ETag` | 详情和写响应 | `"agent:{agent_id}:v{version}"` |

时间统一为 RFC 3339 UTC。列表采用 opaque cursor，调用方不能解析或拼装 cursor。

### 6.2 API 总表

| 方法与路径 | 用途 | 权限 |
|---|---|---|
| `GET /agents` | 查询当前 Agent 摘要 | `agent:read` |
| `GET /agents/{agent_id}` | 查询当前完整元数据 | `agent:read_detail` |
| `PATCH /agents/{agent_id}` | 更新或重置 `display_name` / `models` Override | 按字段拆分写权限 |
| `GET /agents/{agent_id}/versions` | 查询版本历史摘要 | `agent:read_history` |
| `GET /agents/{agent_id}/versions/{version}` | 查询一个完整历史版本 | `agent:read_history_detail` |
| `POST /agents/{agent_id}/versions/{version}:restore` | 把历史可管理字段恢复成一个新版本 | `agent:restore` |
| `GET /agents/{agent_id}/audit-events` | 查询审计事件 | `agent:audit_read` |
| `GET /model-options` | 查询可绑定的模型网关选项 | `agent:model_read` |

V1 不提供 `POST /agents`、`DELETE /agents/{id}` 或管理面归档。前端不应只靠隐藏按钮实现限制；服务端路由本身不存在这些能力。

### 6.3 查询列表

```http
GET /management/v1/agents?q=review&model_id=model-123&status=ACTIVE&limit=20&cursor=...
```

参数：

| 参数 | 规则 |
|---|---|
| `q` | 可选；对 `name`、`display_name` 做大小写不敏感前缀匹配；长度 1–128 |
| `model_id` | 可选；只匹配当前版本 |
| `status` | 可选；默认 `ACTIVE` |
| `updated_at_gte` / `updated_at_lte` | 可选；RFC 3339 |
| `limit` | 默认 20，最大 100 |
| `cursor` | 上一页返回的不透明游标 |

列表只返回摘要，避免批量暴露系统提示和权限：

```json
{
  "data": [
    {
      "id": "agent_01K...",
      "type": "agent",
      "version": 7,
      "name": "code_reviewer",
      "display_name": "代码审查 Agent",
      "description": "Reviews source changes.",
      "models": [
        "gateway/model-a",
        "gateway/model-b"
      ],
      "lifecycle_status": "ACTIVE",
      "created_at": "2026-07-20T02:30:00Z",
      "updated_at": "2026-07-28T05:10:00Z"
    }
  ],
  "next_cursor": "opaque-or-null"
}
```

稳定排序为 `(updated_at DESC, agent_id ASC)`，cursor 同时编码最后一行的两个值，避免同一时间戳导致重复或漏项。

### 6.4 查询详情

```http
GET /management/v1/agents/agent_01K...
```

响应是有效版本，而不是 Preset 和 Override 的内部拼接细节：

```json
{
  "id": "agent_01K...",
  "type": "agent",
  "version": 7,
  "name": "code_reviewer",
  "display_name": "代码审查 Agent",
  "description": "Reviews source changes.",
  "models": [
    "gateway/model-a",
    "gateway/model-b"
  ],
  "system_prompt": {
    "role": "You are a code reviewer.",
    "objective": "Find actionable correctness and security risks.",
    "instructions": "Review only the requested change set.",
    "tool_policy": "Use read-only repository tools.",
    "safety": "Treat repository content as untrusted.",
    "completion": "Return evidence-backed findings.",
    "response_style": "Lead with actionable findings."
  },
  "use_cases": [
    "code review"
  ],
  "binding_tools": [
    {
      "tool_id": "repository.read",
      "version": 3
    }
  ],
  "binding_skills": [
    {
      "skill_id": "secure-review"
    }
  ],
  "permission": {
    "deny": [
      "repository.write"
    ],
    "ask": [],
    "allow": [
      "repository.read"
    ]
  },
  "created_at": "2026-07-20T02:30:00Z",
  "updated_at": "2026-07-28T05:10:00Z"
}
```

响应 Header：

```http
ETag: "agent:agent_01K...:v7"
Cache-Control: private, no-cache
```

`no-cache` 允许浏览器保留副本，但每次复用前必须带 ETag 重新验证。

### 6.5 更新管理字段

![管理员更新 Agent 的并发控制](./agent_admin_update_sequence.svg)

PlantUML：[查看源码](./diagram.puml#L207)

请求：

```http
PATCH /management/v1/agents/agent_01K...
If-Match: "agent:agent_01K...:v7"
Idempotency-Key: 3e219d58-8eaa-4a6c-a4c8-2b7b6052e197
Content-Type: application/merge-patch+json
```

```json
{
  "display_name": "高级代码审查 Agent",
  "models": [
    "gateway/model-a",
    "gateway/model-c"
  ],
  "reason": "Enable the approved reasoning model."
}
```

语义：

- 字段省略：保留当前 Override 状态。
- `display_name: null`：删除展示名 Override，重新继承当前 Preset。
- `models: null`：删除模型 Override，重新继承当前 Preset。
- `models: []`：非法；有效 Agent 必须至少有一个模型。
- 数组是完整集合替换，不是增量增加/删除。
- `reason` 是操作元数据，不进入 Agent Version 内容摘要。
- 出现 `system_prompt`、`name` 或其他字段时返回 `400 IMMUTABLE_FIELD`；不能静默忽略。
- 规范化后与当前有效内容相同，返回 `200` 和当前 ETag，不增加版本。

字段校验建议：

| 字段 | 约束 |
|---|---|
| `display_name` | 去除首尾空白后 1–160 字符；禁止控制字符 |
| `models` | 1–16 个唯一 `model_id`；每项 1–256 字符 |
| `reason` | 可选，最大 512 字符 |

Model Gateway 校验至少确认：

- Model ID 存在且调用方租户可见。
- 模型处于可选状态。
- 模型支持 Agent Runtime 所需能力；例如 Tool Use 或所需上下文长度。
- 不把网关凭据或供应商 Secret 返回给管理面。

成功响应返回完整当前 Agent，`version` 为 8，并返回新 ETag。

### 6.6 版本历史与恢复

版本列表：

```http
GET /management/v1/agents/{agent_id}/versions?limit=20&cursor=...
```

摘要至少包含：

```json
{
  "version": 8,
  "change_origin": "ADMIN",
  "changed_fields": [
    "display_name",
    "models"
  ],
  "created_by": "user_123",
  "created_at": "2026-07-28T05:10:00Z",
  "content_sha256": "..."
}
```

恢复接口：

```http
POST /management/v1/agents/{agent_id}/versions/5:restore
If-Match: "agent:agent_01K...:v8"
Idempotency-Key: ...
```

```json
{
  "fields": [
    "display_name",
    "models"
  ],
  "reason": "Rollback an invalid model selection."
}
```

恢复不是把 Head 指针倒退到版本 5，也不恢复研发拥有的字段。服务端读取版本 5 的可管理字段，生成新的 Override Revision 和版本 9。历史始终单调追加。

如果版本 5 的模型在当前 Model Gateway 中已不可用，恢复返回 `422 MODEL_NOT_SELECTABLE`，并列出不可用 ID；历史详情仍可读取。

### 6.7 模型选项

管理 UI 不应硬编码模型 ID：

```http
GET /management/v1/model-options?capability=agent&limit=100&cursor=...
```

Agent Admin Service 调用 Model Gateway 的目录 API，并只返回展示所需字段：

```json
{
  "data": [
    {
      "id": "gateway/model-a",
      "display_name": "Reasoning Model A",
      "provider": "configured-provider",
      "capabilities": [
        "tool_use",
        "structured_output"
      ],
      "availability": "AVAILABLE"
    }
  ],
  "next_cursor": null
}
```

这是实时目录，不写入 Agent 事务。更新接口仍必须重新校验，不能信任 UI 曾经加载的选项。

### 6.8 错误契约

统一错误：

```json
{
  "error": {
    "code": "VERSION_MISMATCH",
    "message": "The agent was updated by another request.",
    "request_id": "req_...",
    "details": {
      "current_version": 8,
      "current_etag": "\"agent:agent_01K...:v8\""
    }
  }
}
```

| HTTP | code | 场景 |
|---:|---|---|
| 400 | `INVALID_ARGUMENT` | 格式、长度或空模型集合非法 |
| 400 | `IMMUTABLE_FIELD` | 尝试更新非管理字段 |
| 401 | `UNAUTHENTICATED` | 未认证 |
| 403 | `PERMISSION_DENIED` | 无 Agent 或字段级权限 |
| 404 | `AGENT_NOT_FOUND` | 当前租户不可见；避免泄漏其他租户资源 |
| 409 | `IDEMPOTENCY_KEY_REUSED` | Key 与不同请求摘要复用 |
| 412 | `VERSION_MISMATCH` | ETag 与当前版本不一致 |
| 422 | `MODEL_NOT_SELECTABLE` | Model 不存在、不可用或能力不兼容 |
| 428 | `PRECONDITION_REQUIRED` | 写请求缺少 `If-Match` |
| 429 | `RATE_LIMITED` | 管理写限流 |
| 503 | `MODEL_CATALOG_UNAVAILABLE` | Model Gateway 暂不可用，更新未发生 |

## 7. 研发预置与升级 API

![研发 Preset 对账流程](./agent_preset_reconcile_sequence.svg)

PlantUML：[查看源码](./diagram.puml#L305)

管理面没有创建接口，但研发发布需要一个受控入口：

```http
PUT /internal/v1/agent-presets/{name}
Authorization: workload identity
Idempotency-Key: release-artifact-digest
```

```json
{
  "source_kind": "RELEASE_BUNDLE",
  "source_revision": "agent-catalog-2026.07.28.1",
  "manifest": {
    "name": "code_reviewer",
    "display_name": "Code Reviewer",
    "description": "Reviews source changes.",
    "models": [
      "gateway/model-a"
    ],
    "system_prompt": {},
    "use_cases": [],
    "binding_tools": [],
    "binding_skills": [],
    "permission": {
      "deny": [],
      "ask": [],
      "allow": []
    }
  }
}
```

对账规则：

1. 以认证上下文中的 `tenant_id` 与 path `name` 查找稳定 Agent。
2. 对完整 Manifest、Tool/Skill 引用、权限冲突和模型 ID 执行校验。
3. 新 Agent 创建 Preset Revision 1 和 Agent Version 1。
4. 已存在 Agent 写入新的 Preset Revision，再叠加当前完整 Admin Override。
5. 合并后的有效内容有变化才创建下一个 Agent Version。
6. Preset 默认 `display_name` / `models` 变化时，已有 Override 继续生效；未 Override 的字段自动采用新默认。
7. 同一 `source_revision` 与摘要重复提交返回幂等成功。
8. 同一 `source_revision` 携带不同摘要返回冲突，不能覆写不可变发布记录。

研发预置不应由应用启动时的普通 `INSERT ... ON CONFLICT DO UPDATE` 完成，因为该方式无法安全保留管理员字段所有权和版本历史。

## 8. 更新事务与并发

### 8.1 管理更新算法

1. 从认证上下文确定 `tenant_id` 与 actor。
2. 校验 JSON 只包含 allowlist 字段。
3. 用 `(tenant_id, actor_id, Idempotency-Key)` 创建或重放写操作。
4. 在事务外调用 Model Gateway 校验请求中的模型集合。
5. 开启数据库事务并锁定 `agent_definition`。
6. 强制校验 `If-Match == current_version`；不匹配立即回滚。
7. 读取当前 Preset 和完整 Override 状态，应用 Merge Patch。
8. 把 Preset 与新 Override 合并成规范化有效内容并计算摘要。
9. 若 `content_sha256` 未变化，直接返回当前版本。
10. 插入下一 Override Revision、Agent Version 与全部子表。
11. 以旧 `current_version` 为条件更新 Head；受影响行必须为 1。
12. 同事务插入 Audit 与 Outbox。
13. 提交后记录幂等响应；Relay 异步失效缓存。

Model Gateway 校验后到事务提交前，模型状态可能变化。这不会破坏数据库一致性；Runtime 在创建 Session 时还要检查模型当前可用性。若产品要求“提交瞬间强一致”，需要 Model Gateway 提供可锁定的目录 Revision，而不是跨服务分布式事务。

### 8.2 并发示例

- 管理员 A 与 B 都读取版本 7。
- A 成功更新为版本 8。
- B 仍携带版本 7，收到 `412 VERSION_MISMATCH`。
- UI 拉取版本 8，展示字段级差异，再由 B 决定是否重新提交。

服务端不自动把 B 的模型数组合并进版本 8，因为数组是完整集合替换，自动合并可能重新引入 A 刚删除的模型。

### 8.3 无实际变化

以下请求不增加版本：

- `display_name` 与当前有效值相同。
- `models` 只改变输入顺序，规范化集合相同。
- 清除一个不存在的 Override，且继承值不变。
- Preset 发生来源版本变化，但合并后的有效内容摘要相同。

Preset Revision 仍可增加，因为它记录研发来源历史；Agent Version 只记录有效行为和展示状态的变化。

## 9. 查询、缓存与运行时边界

### 9.1 查询路径

列表查询：

```text
agent_definition
  JOIN agent_version
    ON tenant_id + agent_id + current_version
  LEFT JOIN agent_version_model
    ON tenant_id + agent_id + current_version
```

详情按 `(tenant_id, agent_id, current_version)` 读取 Version 及子表。版本历史只读取 `agent_version`，必要时再按选中版本加载完整子表，避免列表 N+1。

### 9.2 缓存键

```text
agent:{tenant_id}:{agent_id}:v{version}
agent-head:{tenant_id}:{agent_id}
```

Version 内容不可变，可使用长 TTL；Head 使用短 TTL 并由 Outbox 事件主动失效。缓存内容不得跨 tenant 共享。

### 9.3 Runtime 读取

Runtime 不应只保存 `agent_id` 并在每轮读取最新配置。推荐流程：

1. Session 创建时解析 Agent Head。
2. 读取具体 `agent_version`。
3. 把 `LATEST` Tool/Skill 引用解析为具体版本。
4. 校验请求选择的 `model_id` 属于 `agent_version_model`。
5. 生成不可变 `ResolvedAgentPlan`，保存 Agent ID、Agent Version、Tool/Skill 具体版本和摘要。
6. Session 后续运行始终使用该计划。

这是对 Anthropic“Session 固定已解析 Agent 版本”思路的采用，不是对其内部实现的复刻。

## 10. 权限、安全与审计

### 10.1 RBAC

建议拆分权限：

```text
agent:read
agent:read_detail
agent:update_display_name
agent:update_models
agent:read_history
agent:read_history_detail
agent:restore
agent:audit_read
agent:preset_write
```

只拥有展示名权限的管理员提交 `models` 时，整个请求返回 `403`；不做部分成功。

### 10.2 安全规则

- 租户作用域只从认证 Token 或 Workload Identity 推导。
- 列表和详情返回前再次做对象级授权。
- 管理面没有通用 JSON Patch 路径，避免 `/system_prompt` 等路径绕过 allowlist。
- 系统提示按敏感配置处理：不写访问日志，不进入错误详情，不进入 Outbox。
- 日志记录 `agent_id`、版本、字段名、摘要和 request ID，不记录完整 Prompt。
- Model Gateway 错误必须规范化，不能透出供应商凭据或内部 URL。
- 历史版本不可物理修改；合规删除需独立治理流程并保留删除墓碑。
- 数据库角色分离：读 API、写 API、Preset Provisioner、Outbox Relay 使用不同最小权限账号。

### 10.3 审计事件

至少记录：

- `AGENT_PRESET_CREATED`
- `AGENT_PRESET_UPDATED`
- `AGENT_ADMIN_UPDATED`
- `AGENT_ADMIN_OVERRIDE_RESET`
- `AGENT_ADMIN_RESTORED`
- `AGENT_RETIRED`
- `AGENT_UPDATE_REJECTED` 可进入外部安全审计系统，但不必写入版本审计表

拒绝操作记录 actor、目标、字段名、原因码和 request ID，不记录被拒绝的完整字段值。

## 11. 校验与不变量

发布和管理更新都必须保证：

1. `name` 在 tenant 内唯一且发布后不变。
2. 当前 Head 指向存在的 Preset、Override 和 Agent Version。
3. Agent Version 至少绑定一个模型。
4. 模型集合无重复，数组顺序不影响内容摘要。
5. `PINNED` Tool/Skill 引用必须有正整数版本；`LATEST` 不得带版本。
6. 同一版本 Tool ID、Skill ID 各自唯一。
7. 同一 Tool ID 只能有一个 Permission effect。
8. Permission 引用的 Tool 必须存在于直接或 Skill 展开的有效 Tool 集；若展开只能在编译期完成，则 Preset 状态先标记为不可发布。
9. `content_sha256` 由所有有效字段生成；`runtime_sha256` 排除 `display_name`。
10. 所有当前版本 Join、递归解析和历史读取都绑定 `tenant_id`。
11. 旧 Agent Version 和其子表只追加、不更新、不删除。
12. Head、Version、Audit 和 Outbox 必须在同一事务提交。

## 12. 管理页面建议

### 12.1 列表页

展示：

- `display_name`
- 稳定 `name`
- 描述
- 当前模型标签
- 版本
- 最后更新时间
- 生命周期状态

支持按名称、展示名和 Model ID 过滤。默认不加载系统提示。

### 12.2 详情页

分区展示：

- 基本信息：只有 `display_name` 可编辑。
- 模型：多选 Model Gateway 选项，至少一个。
- System Prompt、Use Cases、Tool/Skill、Permission：只读，并标注“由研发预置”。
- 版本历史：变更来源、操作者、时间和字段级差异。
- 审计：需要更高权限，默认脱敏。

页面开始编辑时保存 ETag；提交冲突时不覆盖用户输入，而是展示“当前版本”和“你的修改”差异。

### 12.3 重置交互

`display_name` 与 `models` 分别提供“恢复研发默认值”。UI 发送对应字段 `null`，服务端删除该字段 Override。不能把当前 Preset 值写成新的 Override，否则后续 Preset 默认值升级将无法自动生效。

## 13. 发布与迁移建议

### 13.1 首次导入

1. 校验当前 Agent JSON。
2. 为每个 Agent 分配稳定不可枚举 `agent_id`。
3. 创建 `agent_definition`、Preset Revision 1 和 Agent Version 1。
4. 不创建 Override Revision。
5. 校验有效模型均存在于 Model Gateway。
6. 对 Tool/Skill 省略版本的引用保存为 `LATEST`。
7. 生成内容摘要和 Runtime 摘要。
8. 发布 Outbox 事件，预热只读缓存。

### 13.2 灰度

- 先开放列表和详情。
- 再开放展示名更新。
- 然后开放模型更新，并监控 Model Gateway 校验失败率。
- 最后开放恢复和审计页面。

### 13.3 监控指标

```text
agent_admin_read_latency
agent_admin_update_latency
agent_admin_update_conflict_total
agent_admin_update_noop_total
agent_model_validation_failure_total
agent_preset_reconcile_total
agent_outbox_publish_lag
agent_version_build_failure_total
```

告警重点是 Outbox 积压、Head 指针不一致、模型目录长期不可用和异常高的版本冲突率。

## 14. 与 Anthropic 的一致点和差异

| 主题 | Anthropic 公开契约 | 本设计 |
|---|---|---|
| Agent 版本 | 修改产生递增版本 | 有效内容变化产生递增版本 |
| 更新并发 | `version` 可选；传入时校验 | `If-Match` 强制；禁止 last-write-wins |
| 数组更新 | Tool/Skill 等完整替换 | `models` 完整集合替换 |
| 版本历史 | 分页 List Versions | 分页历史 + 单版本详情 + 新版本式恢复 |
| 创建 | 公共 Create Agent | 仅内部 Preset Provisioning |
| 归档 | 公共不可逆 Archive | V1 管理面不开放；研发控制生命周期 |
| 模型字段 | 单一 `model` 配置 | `models` 是允许集合；路由另建字段 |
| 字段所有权 | API 调用方可更新公开配置 | 研发与管理员字段所有权分离 |
| Session | 可固定 Agent 版本 | Runtime 必须固定 Agent Version 和解析后的依赖 |

差异分类：

- “仅查询并更新两个字段”是产品约束。
- 强制 ETag、租户复合键、字段 allowlist 与脱敏是安全强化。
- Preset/Override/Effective Version 三层模型和事务 Outbox 是架构改造。
- `models` Allowlist 是对本地复数字段的目标语义，不是 Anthropic 单模型字段的既有行为。

## 15. 待确认但不阻塞 V1 的问题

1. 管理员修改是平台全局生效，还是 tenant 各自覆盖？本设计按 tenant 隔离实现；全局 Agent 可落在受控平台 tenant。
2. 运行时是否需要默认模型？如果需要，应新增 `default_model_id`，并要求属于 `models`。
3. 是否需要自动 fallback？如果需要，应新增版本化 `routing_policy`，明确触发条件、顺序与审计。
4. 研发移除一个已被管理员 Override 选中的模型时，是保留 Override 并标红，还是拒绝 Preset 发布？建议保留 Override；模型有效性由 Model Gateway 决定。
5. Tool/Skill 的 `LATEST` 是否允许进入生产？若强调完全可重放，可在发布门禁中要求生产 Preset 全部固定版本。

## 16. 图表生成与验证

本主题所有图统一维护在 [`diagram.puml`](./diagram.puml)，图源只使用英文和 ASCII，SVG 不手工修改。

生成命令：

```bash
cd agent-metadata-admin-design
plantuml -tsvg diagram.puml
```

## 17. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| `v0.1.0` | 2026-07-28 | 基于当前 Agent 元数据与 Anthropic Managed Agents 官方 API，设计研发 Preset、管理 Override、有效版本、数据库表、管理 API、并发、幂等、审计、模型网关校验和运行时固定边界 |
