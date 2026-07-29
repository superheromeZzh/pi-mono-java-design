# Agent 元数据 GaussDB 表设计

> 文档编号：`SR-AGENT-DB-001`<br>
> 版本：`v0.2.0`<br>
> 日期：`2026-07-29`<br>
> 状态：目标设计（target-only）<br>
> 仓库基线：`0f1a1a384a35bd70d60bdfba81b7f584b5aa2e69`<br>
> Java / 数据库实现基线：无

## 1. 结论

基于当前 [`AGENT元数据设计.json`](../AGENT元数据设计.json)，使用 6 张表即可完整保存 Agent 当前态：

1. `agent_metadata`：基本字段和固定结构的 `system_prompt`。
2. `agent_model`：`models[]`。
3. `agent_use_case`：`use_cases[]`。
4. `agent_tool_binding`：`binding_tools[]`。
5. `agent_skill_binding`：`binding_skills[]`。
6. `agent_tool_permission`：把 `permission.deny/ask/allow` 合并成逐 Tool 的权限行。

本版不再设计 Preset、Override、历史版本、审计、Outbox 等额外表。JSON 中的 `version` 直接保存在主表，作为当前记录的乐观锁；如以后明确需要查询历史版本，再单独增加历史表。

完整 DDL：[`schema.sql`](./schema.sql)。

## 2. 输入基线与设计边界

当前工作区 JSON 的 SHA-256 为：

```text
7c7ef5ada3bd5ef4e33c411b323392ee7032ba2f54de8cece401e9c47501b05a
```

字段来源：

- `id`、`type`、`version`、时间字段：[第 2–6 行](../AGENT元数据设计.json#L2)。
- `name`、`display_name`、`description`、`models`：[第 7–10 行](../AGENT元数据设计.json#L7)。
- `system_prompt` 固定字段：[第 11–20 行](../AGENT元数据设计.json#L11)。
- `use_cases`、Tool/Skill 绑定、权限：[第 21–46 行](../AGENT元数据设计.json#L21)。

本文只设计这些现有字段，不加入：

- 多租户字段。
- Agent 历史版本。
- 管理 API、审批、审计和幂等表。
- Session、Memory、Checkpoint。
- Model、Tool、Skill 自身的表。

这是相对 `v0.1.0` 的范围收敛，不表示这些能力永远不需要。

## 3. 表关系

![Agent 元数据 GaussDB 表关系](./agent_metadata_gaussdb_model.svg)

PlantUML：[查看源码](./diagram.puml#L6)

主表保存一条 Agent 当前记录；五张子表保存 JSON 数组。所有子表通过 `agent_id` 逻辑关联主表。

### 3.1 为什么不用一张 JSONB 表

当前字段结构已经稳定，直接使用关系字段更合适：

- `display_name`、`model_id` 可以直接过滤和索引。
- 唯一约束可防止重复模型、重复绑定和同一 Tool 出现多个权限。
- `sort_order` 可以还原原 JSON 数组顺序。
- Tool/Skill 的可选版本可以用 `BIGINT NULL` 准确表达。
- 固定的 System Prompt 字段无需每次做 JSON 路径解析。

### 3.2 为什么不是每个 System Prompt 字段一张表

`system_prompt` 的 8 个属性都与 Agent 一对一，读取时通常一起使用，而且当前结构固定，因此直接展开为主表的 `system_*` 列最简单。

## 4. 字段映射

### 4.1 主表 `agent_metadata`

| JSON 字段 | 数据库字段 | 类型 | 是否为空 | 说明 |
|---|---|---|---:|---|
| `id` | `agent_id` | `VARCHAR(64)` | 否 | 主键；稳定 Agent 标识 |
| `type` | `resource_type` | `VARCHAR(16)` | 否 | 固定为 `agent` |
| `version` | `version` | `BIGINT` | 否 | 从 1 开始；更新成功后加 1 |
| `name` | `name` | `VARCHAR(128)` | 否 | 内部稳定名称；唯一 |
| `display_name` | `display_name` | `VARCHAR(160)` | 否 | 管理面展示名称 |
| `description` | `description` | `TEXT` | 否 | Agent 描述 |
| `system_prompt.role` | `system_role` | `TEXT` | 否 | 身份、专业能力和责任范围 |
| `system_prompt.objective` | `system_objective` | `TEXT` | 否 | 长期目标和成功条件 |
| `system_prompt.instructions` | `system_instructions` | `TEXT` | 否 | 工作原则和行为要求 |
| `system_prompt.tool_policy` | `system_tool_policy` | `TEXT` | 否 | Tool 使用和结果校验规则 |
| `system_prompt.safety` | `system_safety` | `TEXT` | 否 | 安全与确认边界 |
| `system_prompt.completion` | `system_completion` | `TEXT` | 否 | 完成与自检要求 |
| `system_prompt.response_style` | `system_response_style` | `TEXT` | 否 | 默认输出风格 |
| `system_prompt.example` | `system_example` | `TEXT` | 是 | 可选示例 |
| `created_at` | `created_at` | `TIMESTAMPTZ` | 否 | 数据库创建时间 |
| `updated_at` | `updated_at` | `TIMESTAMPTZ` | 否 | 最后更新时间 |

说明：

- 数据库列使用 `agent_id` 和 `resource_type`，比裸 `id` / `type` 更容易在 Join 和 SQL 中识别。
- Prompt、描述和使用场景可能较长，使用 `TEXT`，不设置任意的小长度上限。
- 时间使用 `TIMESTAMPTZ`，应用统一以 UTC 写入和返回。
- `updated_at` 由应用在更新语句中显式设置，不依赖数据库 Trigger。

### 4.2 模型表 `agent_model`

| 字段 | 类型 | 约束 |
|---|---|---|
| `agent_id` | `VARCHAR(64)` | 逻辑关联 Agent |
| `model_id` | `VARCHAR(256)` | 模型网关 Model ID |
| `sort_order` | `INTEGER` | 从 0 开始；还原数组顺序 |

约束：

```text
PRIMARY KEY (agent_id, model_id)
UNIQUE (agent_id, sort_order)
```

一个 Agent 至少需要一个模型。该“至少一行”的跨表约束由应用在同一事务中校验。

`sort_order` 只用于保存 JSON 顺序；当前元数据没有定义默认模型或 fallback 语义，数据库不额外推断。

### 4.3 使用场景表 `agent_use_case`

| 字段 | 类型 | 约束 |
|---|---|---|
| `agent_id` | `VARCHAR(64)` | 逻辑关联 Agent |
| `sort_order` | `INTEGER` | 主键的一部分 |
| `use_case` | `TEXT` | 非空场景文本 |

主键为 `(agent_id, sort_order)`。V1 不为长文本创建普通 B-tree 索引；意图识别由应用加载场景后处理。

### 4.4 Tool 绑定表 `agent_tool_binding`

| JSON 字段 | 数据库字段 | 类型 | 说明 |
|---|---|---|---|
| `tool_id` | `tool_id` | `VARCHAR(128)` | Tool 标识 |
| `version` | `tool_version` | `BIGINT NULL` | 固定版本；`NULL` 表示最新版本 |
| 数组位置 | `sort_order` | `INTEGER` | 从 0 开始 |

主键 `(agent_id, tool_id)` 防止重复绑定同一个 Tool。

### 4.5 Skill 绑定表 `agent_skill_binding`

与 Tool 绑定相同：

- `skill_id VARCHAR(128)`。
- `skill_version BIGINT NULL`；`NULL` 表示最新版本。
- `sort_order INTEGER`。
- 主键为 `(agent_id, skill_id)`。

### 4.6 权限表 `agent_tool_permission`

JSON 使用三个数组：

```json
{
  "permission": {
    "deny": ["tool-a"],
    "ask": ["tool-b"],
    "allow": ["tool-c"]
  }
}
```

数据库不需要三张表，也不需要三个数组字段，而是保存为：

| `agent_id` | `tool_id` | `permission_effect` |
|---|---|---|
| Agent ID | `tool-a` | `deny` |
| Agent ID | `tool-b` | `ask` |
| Agent ID | `tool-c` | `allow` |

主键 `(agent_id, tool_id)` 保证同一个 Agent 下，一个 Tool 只能有一个最终权限。`CHECK` 把权限限定为 `deny`、`ask`、`allow`。

## 5. GaussDB 兼容性

DDL 使用行存表、`VARCHAR`、`TEXT`、`BIGINT`、`INTEGER`、`TIMESTAMPTZ`、主键、唯一约束、`CHECK` 和普通索引。

GaussDB 部署形态存在差异：

- openGauss / GaussDB 集中式的 `CREATE TABLE` 语法支持主键、唯一、`CHECK` 和外键等表约束，见 [openGauss CREATE TABLE](https://docs.opengauss.org/en/docs/latest/sql_reference/create_table.html)。
- 华为官方迁移文档明确说明 GaussDB Distributed 不支持外键约束，见 [UGO GaussDB Distributed 外键限制](https://support.huaweicloud.com/intl/en-us/usermanual-ugo/intl-usermanual-ugo.pdf)。

因此 [`schema.sql`](./schema.sql) 的基础 DDL不声明物理外键，适用于更宽的 GaussDB 部署范围。服务必须在同一事务内：

1. 确认 `agent_metadata` 存在。
2. 写入或替换子表数据。
3. 更新主表 `version` 和 `updated_at`。
4. 任一步失败时整体回滚。

如果最终确定使用支持外键的集中式 GaussDB，可启用 `schema.sql` 末尾的可选外键，获得数据库级级联删除；不要在 GaussDB Distributed 上启用。

## 6. 初始化与更新

### 6.1 研发初始化

一个 Agent 的主表与全部子表必须在一个事务中插入：

```text
BEGIN
  INSERT agent_metadata
  INSERT agent_model
  INSERT agent_use_case
  INSERT agent_tool_binding
  INSERT agent_skill_binding
  INSERT agent_tool_permission
COMMIT
```

初始化校验：

- `version = 1`。
- `resource_type = 'agent'`。
- `name` 唯一。
- 至少一个 `models` 条目。
- Tool/Skill 版本为空或大于等于 1。
- 同一个 Tool 不得同时属于多个权限数组。

### 6.2 更新 `display_name`

使用 JSON 中的 `version` 做乐观锁：

```sql
UPDATE agent_metadata
SET display_name = :display_name,
    version = version + 1,
    updated_at = CURRENT_TIMESTAMP
WHERE agent_id = :agent_id
  AND version = :expected_version;
```

受影响行数：

- `1`：更新成功，返回新版本。
- `0`：Agent 不存在或版本冲突；应用先按 `agent_id` 查询后区分错误。

### 6.3 更新 `models`

模型数组采用完整替换，在一个事务中执行：

```text
BEGIN
  SELECT agent_id, version
  FROM agent_metadata
  WHERE agent_id = :agent_id
  FOR UPDATE

  verify version = expected_version
  verify new models is not empty and model IDs are unique

  DELETE FROM agent_model WHERE agent_id = :agent_id
  INSERT every model with zero-based sort_order

  UPDATE agent_metadata
  SET version = version + 1,
      updated_at = CURRENT_TIMESTAMP
  WHERE agent_id = :agent_id
COMMIT
```

若一次请求同时修改 `display_name` 与 `models`，只在事务结束前把主表 `version` 增加一次。

## 7. 查询建议

### 7.1 管理列表

列表页只查主表：

```sql
SELECT agent_id,
       resource_type,
       version,
       name,
       display_name,
       description,
       created_at,
       updated_at
FROM agent_metadata
ORDER BY updated_at DESC, agent_id
LIMIT :limit;
```

### 7.2 按模型筛选

```sql
SELECT a.agent_id,
       a.version,
       a.name,
       a.display_name,
       a.description,
       a.updated_at
FROM agent_metadata a
JOIN agent_model m
  ON m.agent_id = a.agent_id
WHERE m.model_id = :model_id
ORDER BY a.updated_at DESC, a.agent_id;
```

### 7.3 查询完整 Agent

按 `agent_id` 分别查询主表和五张子表，子表按 `sort_order` 排序后由 Java 组装为原 JSON。权限表按 `permission_effect` 分组，重新生成 `deny`、`ask`、`allow` 三个数组。

不建议用一个六表 Join 返回完整 Agent，因为多个一对多表相互 Join 会产生笛卡尔放大。

## 8. 表和索引清单

| 对象 | 用途 |
|---|---|
| `agent_metadata` | Agent 当前标量字段和 System Prompt |
| `uk_agent_metadata_name` | 保证 `name` 唯一 |
| `idx_agent_metadata_display_name` | 展示名查询 |
| `idx_agent_metadata_updated_at` | 管理列表时间排序 |
| `agent_model` | 模型列表 |
| `idx_agent_model_model_id` | 按模型反查 Agent |
| `agent_use_case` | 有序使用场景 |
| `agent_tool_binding` | 有序 Tool 绑定 |
| `idx_agent_tool_binding_tool_id` | 按 Tool 反查 Agent |
| `agent_skill_binding` | 有序 Skill 绑定 |
| `idx_agent_skill_binding_skill_id` | 按 Skill 反查 Agent |
| `agent_tool_permission` | Tool 权限 |
| `idx_agent_tool_permission_effect` | 按权限类型查询 |

## 9. 明确不做的复杂化

- 不保存每个 Agent 版本的完整历史。
- 不拆 Preset、Override 和 Effective Version。
- 不使用 JSONB 保存已经固定的字段结构。
- 不增加审计、幂等、Outbox 和缓存表。
- 不为当前 JSON 中不存在的默认模型、模型 fallback、状态或租户字段建列。
- 不在数据库中自动解析 Tool/Skill 的最新版本。

当上述需求真正出现时再扩展，当前表结构先准确服务已有字段。

## 10. 图表生成与验证

本主题图源维护在 [`diagram.puml`](./diagram.puml)，内容只使用英文和 ASCII。生成命令：

```bash
cd agent-metadata-gaussdb-design
plantuml -tsvg diagram.puml
```

SVG 是生成物，不手工修改。

## 11. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| `v0.2.0` | 2026-07-29 | 按当前 Agent JSON 收敛为 1 张主表和 5 张数组子表；移除 Preset/Override、版本历史、治理和管理 API 设计；增加 GaussDB 可执行 DDL |
| `v0.1.0` | 2026-07-28 | 初版包含研发 Preset、管理 Override、有效版本、管理 API、审计与 Outbox 等扩展设计 |
