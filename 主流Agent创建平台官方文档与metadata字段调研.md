# 主流 Agent 创建平台官方文档与 `metadata` 字段调研

- 文档版本：1.0.0
- 调研日期：2026-07-21
- 证据范围：代表性的国内外 Agent 平台官方 API、SDK 与产品文档
- 仓库基线：`a39d340912729f174be193ed767752bd04290afb`
- 结论属性：外部公开契约调研；第 6、7 节为目标设计建议，不代表任何平台的既有统一标准

## 1. 结论

创建 Agent 时的 `metadata` 通常是附着在持久化 Agent、Assistant 或 Agent Version 资源上的**业务自定义辅助信息**。它主要用于检索、筛选、归属、环境标记、审计关联和外部系统映射，一般不直接改变模型行为。

主流平台没有统一的 `metadata` 标准：

- Anthropic Managed Agents、阿里云百炼、Microsoft Foundry 和 LangSmith Assistant 在创建接口上直接提供 `metadata`。
- 腾讯云 ADP 和 Coze 的创建契约没有通用 `metadata` 字段，业务信息需要使用平台明确提供的字段或由调用方另行管理。
- Google Agent Platform 使用 `labels`，AWS Bedrock Agents Classic 使用 `tags`；两者语义接近资源标签，但字段名和约束不同。
- OpenAI 当前推荐的 Agents SDK 使用代码定义 `Agent`，不是创建持久化 Agent 资源的 `POST /agents` 接口；旧 Assistants API 虽有 `metadata`，但已弃用并计划于 2026-08-26 停止服务。
- Dify 和百度千帆当前公开主流程以控制台创建/发布应用、API 调用已发布应用为主，不能把运行时 API 误写成通用的“创建 Agent 管理 API”。

因此，跨平台设计时不应假设所有供应商都接受同一个 `metadata`。内部可以定义统一的业务元数据，再由适配层分别映射到 `metadata`、`labels`、`tags`，或保存在自有控制面。

## 2. 范围与判定口径

本文只比较以下三类公开入口：

1. 创建持久化 Agent、Assistant、Agent Version 或 Reasoning Engine 的 API/SDK；
2. 代码定义 Agent 的官方 SDK；
3. 只提供控制台创建、公开 API 负责运行已发布应用的平台。

本文不会把以下对象混为同一层：

- Agent 定义：模型、指令、工具、知识库、技能、工作流和安全策略；
- 业务元数据：团队、环境、外部 ID、租户和成本归属等辅助标签；
- 运行时数据：会话、消息、checkpoint、memory 内容和执行状态；
- 服务端字段：资源 ID、版本、创建时间、更新时间和创建者等平台生成属性。

证据等级如下：

| 等级 | 含义 |
|---|---|
| API 契约 | 官方 REST/API Reference 明确给出创建入口及字段 |
| SDK 契约 | 官方 SDK 文档或官方 SDK 源码明确给出创建方法及字段 |
| 产品流程 | 官方文档只能确认控制台创建、发布或运行流程，不能反推出不存在公开的管理 API |
| 目标设计 | 本文给出的跨平台归一化建议，不是平台现有行为 |

## 3. 直接创建接口对比

| 平台 | 创建对象与入口 | 创建时的 `metadata` 或等价字段 | 官方文档 | 证据等级 |
|---|---|---|---|---|
| Anthropic Managed Agents Beta | 持久化、版本化 Agent；`POST /v1/agents` | `metadata: map<string,string>`；最多 16 对，键最长 64 字符，值最长 512 字符；用于自有跟踪 | [Create Agent API](https://platform.claude.com/docs/en/api/beta/agents/create)、[Define your agent](https://platform.claude.com/docs/en/managed-agents/agent-setup) | API 契约 |
| 阿里云百炼 Model Studio | 持久化、版本化 Agent；`POST /agents` | `metadata: object`；官方定义为业务自定义键值对，并明确不影响模型行为 | [Create Agent](https://help.aliyun.com/en/model-studio/agent-create) | API 契约 |
| Microsoft Foundry Agent Service | Agent Version；Python `project.agents.create_version(...)`，REST `POST .../agents?api-version=v1` | `metadata: dict<string,string>`；最多 16 对，键最长 64 字符，值最长 512 字符；可通过 API 或控制台查询 | [Prompt agent quickstart](https://learn.microsoft.com/en-us/azure/foundry/agents/quickstarts/prompt-agent)、[Python `AgentsOperations.create_version`](https://learn.microsoft.com/en-us/python/api/azure-ai-projects/azure.ai.projects.operations.agentsoperations?view=azure-python) | API/SDK 契约 |
| 腾讯云智能体开发平台 ADP | Agent；RPC Action `CreateAgent`，API Version `2026-05-20` | `AgentSpec` 公开字段包括 Profile、Instructions、Model、ToolList、PluginList、SkillList 和 AdvancedConfig；未提供通用 `metadata` | [创建 Agent](https://cloud.tencent.com/document/api/1759/132576)、[数据结构](https://cloud.tencent.com/document/api/1759/132545) | API 契约 |
| LangGraph/LangSmith Agent Server | Assistant；`POST /assistants` | `metadata: object`；官方描述为添加到 Assistant 的元数据，创建页未规定 16/64/512 一类限制 | [Create Assistant](https://docs.langchain.com/langsmith/agent-server-api/assistants/create-assistant)、[Assistants 概念](https://docs.langchain.com/langsmith/assistants)、[Search Assistants](https://docs.langchain.com/langsmith/agent-server-api/assistants/search-assistants) | API 契约 |
| Coze / 扣子 | Bot；`POST /v1/bot/create` | 官方创建方法公开的参数包括 space、名称、描述、图标、prompt、开场白、模型、插件和工作流等；没有通用 `metadata` | [创建 Bot](https://www.coze.cn/open/docs/developer_guides/create_bot)、[官方 Python SDK `bots.create`](https://github.com/coze-dev/coze-py/blob/main/cozepy/bots/__init__.py#L412) | API/SDK 契约 |
| Google Gemini Enterprise Agent Platform | `ReasoningEngine`；`projects.locations.reasoningEngines.create` | 没有通用 `metadata`；资源提供 `labels: map<string,string>` | [Agent Platform 概览](https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale)、[Create ReasoningEngine](https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1/projects.locations.reasoningEngines/create)、[ReasoningEngine resource](https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1/projects.locations.reasoningEngines) | API 契约 |
| AWS Bedrock Agents Classic | Agent；`CreateAgent` | 没有通用 `metadata`；使用 `tags: map<string,string>`，键 1–128 字符，值 0–256 字符 | [CreateAgent API](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateAgent.html)、[Agents Classic maintenance mode](https://docs.aws.amazon.com/bedrock/latest/userguide/agents-classic-maintenance-mode.html) | API 契约 |
| OpenAI Agents SDK | 代码内 `Agent(...)`，由 `Runner` 执行；不是持久化 Agent 创建 API | `Agent` 基础配置没有资源级 `metadata`；运行追踪等其他对象可以有自己的 metadata，但不是“创建 Agent 的 metadata” | [Agents SDK quickstart](https://openai.github.io/openai-agents-python/quickstart/)、[Agent configuration](https://openai.github.io/openai-agents-python/agents/) | SDK 契约 |

### 3.1 平台状态说明

- Anthropic Managed Agents 当前要求 `managed-agents-2026-04-01` beta header，不能忽略 Beta 状态。
- AWS 已将原 Bedrock Agents 更名为 Bedrock Agents Classic，并宣布从 2026-07-30 起不再向新客户开放；新项目应同时评估 [Amazon Bedrock AgentCore](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-get-started-cli.html)。
- Google 文档中的旧 `Vertex AI Agent Engine`/`Reasoning Engine` 路径已逐步归入 Gemini Enterprise Agent Platform；比较时应以当前 `ReasoningEngine` REST 资源为准。

## 4. OpenAI 旧 Assistants API 的特殊情况

OpenAI 旧 Assistants API 提供持久化 Assistant 创建接口：

- 创建入口：`POST /v1/assistants`；
- `metadata`：最多 16 个键值对；键最长 64 字符，值最长 512 字符；可用于结构化附加信息和查询；
- 官方文档：[Create assistant](https://developers.openai.com/api/reference/resources/beta/subresources/assistants/methods/create/)。

但它不能再作为新系统的主流基线：

- OpenAI 已弃用 Assistants API，计划在 2026-08-26 停止服务；迁移目标是 Responses API，见 [Assistants migration guide](https://developers.openai.com/api/docs/assistants/migration)。
- Agent Builder 已于 2026-06-03 宣布弃用，计划于 2026-11-30 停止服务，见 [OpenAI deprecations](https://developers.openai.com/api/docs/deprecations#2026-06-03-agent-builder)。
- 当前 Agent 编排入口是 Agents SDK 的代码定义对象；持久化配置、会话与运行状态应按当前 Responses、Conversation 和 SDK 契约重新建模。

这属于产品迁移约束，不表示 `metadata` 概念本身失效，而是表示旧 Assistant 资源不能继续充当跨平台 Agent 资源模型。

## 5. 控制台创建或运行时 API 平台

### 5.1 Dify

Dify 的公开主流程是在 Studio 中创建和编排应用，发布后使用 App API 调用。当前 [New Agent API](https://docs.dify.ai/en/api-reference/guides/agent) 覆盖消息流、会话、文件和已发布应用配置读取，不是创建 Agent 管理接口；应用搭建流程见 [Dify quick start](https://docs.dify.ai/en/quick-start)。

因此，不能从 Dify 的 `Get App Meta` 或知识库 metadata 推导出“创建 Agent 的 metadata”。如需统一管理 Dify 应用，应在自有控制面保存业务元数据，并关联 Dify app ID。

### 5.2 百度千帆 Agent 开发平台 / AppBuilder

百度千帆当前应用文档以控制台配置、发布后通过 app ID 调用为主；示例明确先在控制台创建并发布应用，再用 `AppBuilderClient(app_id)` 创建会话和运行，见 [Agent 应用](https://cloud.baidu.com/doc/qianfan-docs/s/bm98cr9ds) 和 [千帆平台文档](https://cloud.baidu.com/doc/qianfan/s/dmh4sts2a)。

百度官方开源 AppBuilder SDK 还存在另一套 Assistant 资源模型，其 `AssistantCreateRequest` 包含 `metadata: dict` 且最多 16 项，见 [`assistant_type.py`](https://github.com/baidubce/app-builder/blob/master/python/core/assistant/type/assistant_type.py#L77)。该对象与当前千帆控制台 Agent 应用主流程不是同一个可直接等价的公开契约，集成前必须确认所用产品版本和服务端端点。

## 6. 一般应放哪些 `metadata`

下面是适合放入创建 Agent `metadata` 的常见信息。它们是**目标设计建议**，不是所有平台的强制字段。

| 类别 | 推荐键示例 | 用途 |
|---|---|---|
| 环境 | `environment`、`region` | 区分 development、staging、production 和部署区域 |
| 组织归属 | `team`、`owner_id`、`cost_center` | 负责人、团队和成本归集 |
| 业务分类 | `business_domain`、`agent_type`、`scenario` | 客服、数据分析、研发审核等分类 |
| 租户与项目 | `tenant_id`、`project_id` | 多租户或项目级筛选；只放非敏感标识 |
| 外部映射 | `external_id`、`source`、`source_version` | 关联 CMDB、CRM、Git 仓库或配置来源 |
| 生命周期 | `lifecycle`、`release_channel` | experimental、active、deprecated 等治理状态 |
| 治理 | `data_classification`、`compliance_scope` | 标记数据等级或合规范围；真正授权仍由策略系统执行 |
| Schema | `metadata_schema_version` | 便于元数据演进和迁移 |

示例：

```json
{
  "environment": "production",
  "team": "data-platform",
  "business_domain": "analytics",
  "tenant_id": "tenant_123",
  "external_id": "cmdb-agent-42",
  "source": "agent-registry",
  "metadata_schema_version": "1"
}
```

### 6.1 不应放入 `metadata` 的内容

- API key、access token、密码、私钥或其他明文凭据；
- 完整用户输入、对话历史、长期记忆正文或个人敏感信息；
- 模型、system prompt、工具、MCP server、知识库、权限策略等会改变 Agent 行为的正式配置；
- 高频变化的运行状态、心跳、锁、重试次数和 checkpoint；
- 平台已经生成的 `id`、`created_at`、`updated_at` 等服务端字段；
- 依赖 metadata 直接做授权的决定。metadata 可以作为策略输入，但不应替代独立的 IAM、RBAC、Policy 或审批机制。

## 7. 跨平台统一建议

### 7.1 内部模型

内部控制面可以把业务元数据定义为字符串键值对，并将最严格的公共约束设为：

- 最多 16 对；
- key 最长 64 字符；
- value 最长 512 字符；
- key 使用稳定的 `snake_case`；
- value 不包含 secret 或高敏感数据。

采用 16/64/512 是为了兼容 Anthropic、Microsoft Foundry 和 OpenAI 旧 Assistant 的共同约束。这是兼容性选择，不是行业标准。

### 7.2 适配规则

| 供应商字段 | 建议映射 |
|---|---|
| `metadata` | 在约束允许时直接映射字符串键值对 |
| `labels` | 只映射满足供应商 label 命名和值约束的子集 |
| `tags` | 映射资源治理标签；保留供应商长度和字符限制 |
| 无通用字段 | 保存到自有 Agent Registry，以供应商 resource ID 建立关联 |

业务配置和供应商原始响应应分别保存：统一 metadata 负责跨平台治理，provider-specific extension 负责无法归一化的字段，原始响应负责审计和问题排查。

## 8. 证据基线与设计边界

本次在仓库 commit `a39d340912729f174be193ed767752bd04290afb` 上分析了以下已有资料：

- `AGENT元数据设计.json`
- `anthropic-managed-agents-public-model/README.md`
- `config-to-tool-agent-research/README.md`
- `config-to-tool-agent-research/metadata-v1.md`

外部官方资料访问日期为 2026-07-21。本文没有以 pi 或 pi-mono 实现作为行为基线，也没有对应实现代码变更；第 6、7 节明确属于 target-only 设计建议。平台字段及状态是观察到的公开契约，跨平台统一模型是架构建议，两者不能互相替代。

本文不增加流程图：当前主题是字段与官方资料索引，表格能够完整表达映射关系，不需要额外 PlantUML 图。

## 9. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-07-21 | 建立国内外主流 Agent 创建入口、`metadata`/`labels`/`tags` 对比与官方文档基线；区分直接创建 API、代码定义 Agent、控制台创建和已弃用接口 |
