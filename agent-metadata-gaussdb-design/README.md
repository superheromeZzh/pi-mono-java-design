# Agent 元数据 GaussDB 表设计

> 文档编号：`SR-AGENT-DB-001`<br>
> 版本：`v0.3.0`<br>
> 日期：`2026-07-29`<br>
> 状态：目标设计（target-only）<br>
> 仓库基线：`c75db250c51f7159789a7638d6cf955c18608890`<br>
> Java / 数据库实现基线：无

## 1. 结论

基于当前 [`AGENT元数据设计.json`](../AGENT元数据设计.json)，最终使用 4 张表：

1. `agent_metadata`：基本字段、System Prompt 字段和 JSONB `use_cases`。
2. `agent_model`：`models[]`，保留数组顺序。
3. `agent_tool_binding`：合并 `binding_tools[]` 与 `permission`。
4. `agent_skill_binding`：`binding_skills[]`，不保存数组顺序。

本版采用以下字段规则：

- 主表主键使用 `id`，与元数据顶层 `id` 对齐。
- `name`、`display_name` 都使用 `VARCHAR(128)`。
- System Prompt 展开列去掉 `system_` 前缀，使用 `role`、`objective`、`instructions` 等名称。
- `model_id`、`tool_id`、`skill_id` 统一使用 `VARCHAR(64)`。
- `use_cases` 使用主表 `JSONB`。
- 只有模型表保留 `sort_order`。
- Tool 绑定和权限合并为一行。

完整 DDL：[`schema.sql`](./schema.sql)。

## 2. 输入基线与设计边界

当前工作区 JSON 的 SHA-256：

```text
7c7ef5ada3bd5ef4e33c411b323392ee7032ba2f54de8cece401e9c47501b05a
```

字段来源：

- `id`、`type`、`version`、时间字段：[第 2–6 行](../AGENT元数据设计.json#L2)。
- `name`、`display_name`、`description`、`models`：[第 7–10 行](../AGENT元数据设计.json#L7)。
- `system_prompt`：[第 11–20 行](../AGENT元数据设计.json#L11)。
- `use_cases`、Tool/Skill 绑定与权限：[第 21–46 行](../AGENT元数据设计.json#L21)。

本文只保存当前 JSON 中的字段，不增加多租户、历史版本、审计、Outbox、Session 或 Memory 表。

## 3. 表关系

![Agent 元数据 GaussDB 表关系](./agent_metadata_gaussdb_model.svg)

PlantUML：[查看源码](./diagram.puml#L6)

所有子表通过 `agent_id` 逻辑关联 `agent_metadata.id`。

## 4. 主表 `agent_metadata`

### 4.1 字段映射

| JSON 字段 | 数据库字段 | 类型 | 可空 | 说明 |
|---|---|---|---:|---|
| `id` | `id` | `VARCHAR(64)` | 否 | 主键；与元数据对齐 |
| `type` | `resource_type` | `VARCHAR(16)` | 否 | 固定为 `agent` |
| `version` | `version` | `BIGINT` | 否 | 从 1 开始的乐观锁版本 |
| `name` | `name` | `VARCHAR(128)` | 否 | 内部稳定名称；唯一 |
| `display_name` | `display_name` | `VARCHAR(128)` | 否 | 与 `name` 类型一致 |
| `description` | `description` | `TEXT` | 否 | Agent 描述 |
| `system_prompt.role` | `role` | `TEXT` | 否 | 身份、能力与责任范围 |
| `system_prompt.objective` | `objective` | `TEXT` | 否 | 长期目标和成功条件 |
| `system_prompt.instructions` | `instructions` | `TEXT` | 否 | 工作原则和行为要求 |
| `system_prompt.tool_policy` | `tool_policy` | `TEXT` | 否 | Tool 使用与结果验证规则 |
| `system_prompt.safety` | `safety` | `TEXT` | 否 | 安全边界 |
| `system_prompt.completion` | `completion` | `TEXT` | 否 | 完成与自检要求 |
| `system_prompt.response_style` | `response_style` | `TEXT` | 否 | 默认输出风格 |
| `system_prompt.example` | `example` | `TEXT` | 是 | 可选示例 |
| `use_cases` | `use_cases` | `JSONB` | 否 | 使用场景字符串数组 |
| `created_at` | `created_at` | `TIMESTAMPTZ` | 否 | 创建时间 |
| `updated_at` | `updated_at` | `TIMESTAMPTZ` | 否 | 最后更新时间 |

### 4.2 `use_cases` JSONB

保存形式与元数据一致：

```json
[
  "代码审查",
  "安全风险分析",
  "技术方案设计"
]
```

数据库约束：

```sql
use_cases JSONB NOT NULL DEFAULT '[]'::jsonb,
CONSTRAINT ck_agent_metadata_use_cases
    CHECK (jsonb_typeof(use_cases) = 'array')
```

应用层继续校验：

- 每个元素必须为非空字符串。
- 元素不能重复。
- 限制数组数量和单项长度。

`use_cases` 通常随 Agent 整体读取，当前也没有按单个场景执行关系查询的需求，因此不再单独建表。

## 5. 模型表 `agent_model`

| 字段 | 类型 | 约束 |
|---|---|---|
| `agent_id` | `VARCHAR(64)` | 逻辑关联 `agent_metadata.id` |
| `model_id` | `VARCHAR(64)` | 模型网关 Model ID |
| `sort_order` | `INTEGER` | 从 0 开始 |

约束：

```text
PRIMARY KEY (agent_id, model_id)
UNIQUE (agent_id, sort_order)
```

模型是唯一保留顺序的子表。`sort_order` 用于还原 `models[]`，但当前元数据没有定义数组顺序是默认模型或 fallback 顺序，Runtime 不应自行推断。

一个 Agent 至少需要一个模型。该跨表约束由应用在同一事务中校验。

## 6. Tool 绑定与权限表 `agent_tool_binding`

### 6.1 合并结构

`binding_tools[]` 和 `permission.deny/ask/allow` 合并为：

| 字段 | 类型 | 可空 | 说明 |
|---|---|---:|---|
| `agent_id` | `VARCHAR(64)` | 否 | 逻辑关联 `agent_metadata.id` |
| `tool_id` | `VARCHAR(64)` | 否 | Tool ID |
| `tool_version` | `BIGINT` | 是 | 固定版本；`NULL` 表示最新版本 |
| `permission` | `VARCHAR(8)` | 是 | `deny` / `ask` / `allow`；`NULL` 表示继承 Tool 权限 |

主键：

```text
PRIMARY KEY (agent_id, tool_id)
```

不保存 `sort_order`。查询并重建 `binding_tools[]` 时按 `tool_id` 稳定排序。

### 6.2 JSON 到数据库的转换

元数据示例：

```json
{
  "binding_tools": [
    {
      "tool_id": "repository.read",
      "version": 3
    },
    {
      "tool_id": "repository.write"
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
  }
}
```

转换结果：

| `tool_id` | `tool_version` | `permission` |
|---|---:|---|
| `repository.read` | `3` | `allow` |
| `repository.write` | `NULL` | `deny` |

导入规则：

1. 先按 `binding_tools` 创建 Tool 行。
2. 再把 `deny`、`ask`、`allow` 写入对应行的 `permission`。
3. 同一个 Tool 只能出现在一个权限数组中。
4. 权限数组中的 Tool 必须已经存在于 `binding_tools`；否则拒绝元数据。
5. 没有出现在任何权限数组的已绑定 Tool，`permission = NULL`，运行时继承 Tool 元数据的权限。

合并后的设计不能保存“未绑定但预先声明权限”的 Tool；这是本版明确约束。

### 6.3 数据库约束

```sql
CHECK (tool_version IS NULL OR tool_version >= 1)
CHECK (permission IS NULL OR permission IN ('deny', 'ask', 'allow'))
```

## 7. Skill 绑定表 `agent_skill_binding`

| 字段 | 类型 | 可空 | 说明 |
|---|---|---:|---|
| `agent_id` | `VARCHAR(64)` | 否 | 逻辑关联 `agent_metadata.id` |
| `skill_id` | `VARCHAR(64)` | 否 | Skill ID |
| `skill_version` | `BIGINT` | 是 | 固定版本；`NULL` 表示最新版本 |

主键为 `(agent_id, skill_id)`，不保存 `sort_order`。输出 `binding_skills[]` 时按 `skill_id` 稳定排序。

## 8. GaussDB 兼容性

DDL 使用行存表、`VARCHAR`、`TEXT`、`JSONB`、`BIGINT`、`INTEGER`、`TIMESTAMPTZ`、主键、唯一约束、`CHECK` 和普通索引。

- openGauss 支持 JSONB 类型、操作符和索引，见 [openGauss JSONB](https://docs.opengauss.org/en/docs/latest-lite/sql_reference/json-jsonb-functions-and-operators.html)。
- openGauss / GaussDB 集中式的 `CREATE TABLE` 语法支持主键、唯一、`CHECK` 和外键等表约束，见 [openGauss CREATE TABLE](https://docs.opengauss.org/en/docs/latest/sql_reference/create_table.html)。
- 华为官方迁移文档说明 GaussDB Distributed 不支持外键约束，见 [UGO GaussDB Distributed 外键限制](https://support.huaweicloud.com/intl/en-us/usermanual-ugo/intl-usermanual-ugo.pdf)。

因此 [`schema.sql`](./schema.sql) 的基础 DDL 不声明物理外键。服务必须在同一事务内维护：

```text
agent_model.agent_id         -> agent_metadata.id
agent_tool_binding.agent_id  -> agent_metadata.id
agent_skill_binding.agent_id -> agent_metadata.id
```

如果最终使用支持外键的集中式 GaussDB，可启用 DDL 末尾的可选外键。

## 9. 初始化和更新

### 9.1 初始化

```text
BEGIN
  INSERT agent_metadata
  INSERT agent_model
  INSERT agent_tool_binding
  INSERT agent_skill_binding
COMMIT
```

初始化校验：

- `version = 1`。
- `resource_type = 'agent'`。
- `name` 唯一。
- 至少一个模型。
- Tool/Skill 版本为空或大于等于 1。
- Tool 权限只引用已绑定 Tool。

### 9.2 更新 `display_name`

```sql
UPDATE agent_metadata
SET display_name = :display_name,
    version = version + 1,
    updated_at = CURRENT_TIMESTAMP
WHERE id = :id
  AND version = :expected_version;
```

受影响一行表示成功；零行表示 Agent 不存在或版本冲突。

### 9.3 更新 `models`

```text
BEGIN
  SELECT id, version
  FROM agent_metadata
  WHERE id = :id
  FOR UPDATE

  verify version = expected_version
  verify models is not empty and model IDs are unique

  DELETE FROM agent_model WHERE agent_id = :id
  INSERT every model with zero-based sort_order

  UPDATE agent_metadata
  SET version = version + 1,
      updated_at = CURRENT_TIMESTAMP
  WHERE id = :id
COMMIT
```

一次请求同时修改展示名和模型时，`version` 只增加一次。

## 10. 查询完整 Agent

查询步骤：

1. 按 `agent_metadata.id` 查询主表。
2. 查询 `agent_model`，按 `sort_order` 还原 `models[]`。
3. 查询 `agent_tool_binding`，按 `tool_id` 排序并生成 `binding_tools[]`。
4. 按非空 `permission` 分组，生成 `deny`、`ask`、`allow`。
5. 查询 `agent_skill_binding`，按 `skill_id` 排序生成 `binding_skills[]`。
6. `use_cases` 直接读取主表 JSONB。
7. 把 `role` 等列重新组装为 `system_prompt`。

不建议把三个一对多子表放进同一个 Join，否则会产生行数相乘。

## 11. 表和索引清单

| 对象 | 用途 |
|---|---|
| `agent_metadata` | Agent 当前标量字段、System Prompt 和 Use Cases |
| `uk_agent_metadata_name` | 保证 `name` 唯一 |
| `idx_agent_metadata_display_name` | 展示名查询 |
| `idx_agent_metadata_updated_at` | 管理列表排序 |
| `agent_model` | 有序模型列表 |
| `idx_agent_model_model_id` | 按模型反查 Agent |
| `agent_tool_binding` | Tool 绑定与权限 |
| `idx_agent_tool_binding_tool_id` | 按 Tool 反查 Agent |
| `idx_agent_tool_binding_permission` | 按权限反查 Agent |
| `agent_skill_binding` | Skill 绑定 |
| `idx_agent_skill_binding_skill_id` | 按 Skill 反查 Agent |

## 12. 图表生成与验证

图源维护在 [`diagram.puml`](./diagram.puml#L6)，内容只使用英文和 ASCII：

```bash
cd agent-metadata-gaussdb-design
plantuml -tsvg diagram.puml
```

SVG 是生成物，不手工修改。

## 13. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| `v0.3.0` | 2026-07-29 | 主表 ID 对齐元数据；`display_name` 改为 `VARCHAR(128)`；System Prompt 列去掉 `system_` 前缀；Model/Tool/Skill ID 统一为 `VARCHAR(64)`；`use_cases` 改为主表 JSONB；仅 Model 保留顺序；合并 Tool 绑定与权限 |
| `v0.2.0` | 2026-07-29 | 按当前 Agent JSON 收敛为 1 张主表和 5 张数组子表；增加 GaussDB DDL |
| `v0.1.0` | 2026-07-28 | 初版包含研发 Preset、管理 Override、有效版本、管理 API、审计与 Outbox 等扩展设计 |
