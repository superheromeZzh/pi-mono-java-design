# 主流 Agent 平台 Agent、Tool 与 Skill 创建官方文档

> 文档版本：2.0.1
>
> 调研日期：2026-07-21
>
> 文档性质：官方文档索引与创建形态梳理
>
> 仓库基线：`7585c56d4f573a6c5a9897bb7a855c8e305aa051`

## 1. 目的与范围

本文汇总国内外主流 Agent 平台中与以下三类动作直接相关的官方文档：

1. 创建或定义 Agent；
2. 创建、定义或接入 Tool；
3. 创建、上传或装载 Skill。

本文只采用平台官方文档、官方 API Reference、官方 SDK 文档或官方开源仓库。它是一份代表性入口清单，不承诺覆盖所有 Agent 产品，也不把名称相近但语义不同的对象强行对齐。

本版已移除 `metadata` 字段调研。文档不讨论字段设计、统一数据模型或兼容层方案。

## 2. 阅读口径

不同平台所说的“创建”并不是同一种操作。本文使用以下口径标注：

| 创建形态 | 含义 |
| --- | --- |
| 独立资源 API | 服务端持久化资源，有单独的 create/list/get/update/delete 生命周期 |
| 随 Agent 配置 | Tool 或 Skill 作为 Agent 创建/更新请求的一部分，没有独立资源生命周期 |
| 代码定义 | 通过类、函数、装饰器或配置文件定义，运行时由 SDK 装载 |
| 控制台创建 | 主要在可视化控制台完成创建和发布，公开 API 偏向调用已发布对象 |
| 注册表资源 | 将 Agent、Tool 或 Skill 描述注册到目录，注册记录不一定等于运行时对象 |
| 未见同层级公开文档 | 截至调研日期，官方公开资料中未发现同层级的独立创建入口；不等于平台绝对不支持 |

Tool 常见的创建方式包括函数定义、OpenAPI、MCP Server、插件和 Action Group。Skill 常见的创建方式包括 `SKILL.md` 目录、压缩包上传、代码对象或注册表记录。两者不能仅因“都扩展 Agent 能力”而视为同一资源。

## 3. 官方文档总览

| 平台 | Agent 创建/定义 | Tool 创建/接入 | Skill 创建/装载 | 主要形态 |
| --- | --- | --- | --- | --- |
| OpenAI | [Agents SDK Quickstart](https://developers.openai.com/api/docs/guides/agents/quickstart)、[Agent definitions](https://developers.openai.com/api/docs/guides/agents/define-agents) | [Function calling](https://developers.openai.com/api/docs/guides/function-calling) | [Skills](https://developers.openai.com/api/docs/guides/tools-skills)、[Codex Build skills](https://learn.chatgpt.com/docs/build-skills) | Agent/Tool 代码定义；Skill 可创建并用于工具工作流或 Codex |
| Anthropic Claude Platform | [Create Agent API](https://platform.claude.com/docs/en/api/beta/agents/create) | [Define tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools)、[Managed Agents Tools](https://platform.claude.com/docs/en/managed-agents/tools) | [Create Skill API](https://platform.claude.com/docs/en/api/beta/skills/create)、[Agent Skills](https://platform.claude.com/docs/en/managed-agents/skills) | Agent、Skill 为独立资源；Tool 先定义契约，再随请求或 Agent 配置使用 |
| Microsoft Foundry | [Prompt agent quickstart](https://learn.microsoft.com/en-us/azure/foundry/agents/quickstarts/prompt-agent) | [Agent tools overview](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/tool-catalog)、[Build and register MCP server](https://learn.microsoft.com/en-us/azure/foundry/mcp/build-your-own-mcp-server) | [Use skills with Responses API](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/skills)、[Agent Framework Skills](https://learn.microsoft.com/en-us/agent-framework/agents/skills) | Prompt Agent 为托管资源；Tool 可配置/注册；Skill 可上传或代码定义 |
| Google Agent Platform / ADK | [ADK Agents](https://adk.dev/agents/)、[ReasoningEngine create API](https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1/projects.locations.reasoningEngines/create) | [Custom Tools](https://adk.dev/tools-custom/) | [Skills for ADK agents](https://adk.dev/skills/) | Agent、Tool、Skill 主要代码定义；部署后形成云资源 |
| Amazon Bedrock AgentCore | [AgentCore quickstart](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-get-started-cli.html) | [Harness Tools](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/harness-tools.html) | [Agent Registry quickstart](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/registry-get-started.html) | CLI/配置创建 Agent；Tool 随 Harness 配置；Skill 可登记为注册表资源 |
| LangChain / LangGraph / LangSmith | [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents)、[Create Assistant API](https://docs.langchain.com/langsmith/agent-server-api/assistants/create-assistant) | [LangChain Tools](https://docs.langchain.com/oss/python/langchain/tools) | [LangChain Skills architecture](https://docs.langchain.com/oss/python/langchain/multi-agent/skills)、[Deep Agents Skills](https://docs.langchain.com/oss/python/deepagents/skills) | OSS 侧代码定义；LangSmith Assistant 为托管资源 |
| 阿里云百炼 / Model Studio | [Create Agent API](https://help.aliyun.com/en/model-studio/agent-create) | [Plugins](https://help.aliyun.com/en/model-studio/plugins)、[Custom MCP services](https://help.aliyun.com/en/model-studio/custom-mcp) | [Create Skill API](https://help.aliyun.com/en/model-studio/skill-create)、[Skill overview](https://help.aliyun.com/en/model-studio/introduction-to-skill) | Agent、Skill 为独立资源；Tool 主要通过插件/MCP 接入 |
| 腾讯云智能体开发平台 ADP | [CreateAgent API](https://cloud.tencent.com/document/api/1759/132576) | [CreatePlugin API](https://cloud.tencent.com/document/api/1759/133501)、[使用工具](https://cloud.tencent.com/document/product/1759/117856) | [CreateSkill API](https://cloud.tencent.com/document/api/1759/133496) | Agent、Plugin、Skill 均有管理 API；Plugin 内包含 Tool |
| Coze / Coze Studio | [Create Bot API](https://www.coze.cn/open/docs/developer_guides/create_bot) | [Coze Studio 插件配置](https://github.com/coze-dev/coze-studio/wiki/4.-%E6%8F%92%E4%BB%B6%E9%85%8D%E7%BD%AE) | 未见与 Agent API 同层级的独立 Skill 创建文档 | Agent 可通过 OpenAPI 创建；Tool 主要通过插件接入 |
| Dify | [应用创建 Quickstart](https://docs.dify.ai/en/guides/application-orchestrate/creating-an-application)、[Agent runtime API](https://docs.dify.ai/en/api-reference/guides/agent) | [Tool Plugin](https://docs.dify.ai/en/develop-plugin/dev-guides-and-walkthroughs/tool-plugin) | 未见独立 Skill 资源；[Agent Strategy Plugin](https://docs.dify.ai/en/develop-plugin/dev-guides-and-walkthroughs/agent-strategy-plugin) 是策略插件，不等同于 Skill | Agent 应用以控制台创建为主；扩展能力以插件为主 |
| 百度千帆 AppBuilder | [Agent 应用创建](https://cloud.baidu.com/doc/qianfan-docs/s/tm983fszw)、[快速搭建应用](https://cloud.baidu.com/doc/qianfan/s/hmh4stph5) | [创建 MCP 服务](https://cloud.baidu.com/doc/qianfan/s/zmh4stqex) | 未见与 Agent 应用同层级的独立 Skill 创建文档 | Agent 以控制台创建/发布为主；Tool 以组件和 MCP 为主 |

## 4. 国外平台详表

### 4.1 OpenAI

#### Agent

- [Agents SDK Quickstart](https://developers.openai.com/api/docs/guides/agents/quickstart)：使用 TypeScript 或 Python 定义并运行 Agent，逐步添加 Tool 和 specialist Agent。
- [Agent definitions](https://developers.openai.com/api/docs/guides/agents/define-agents)：Agent 的名称、指令、模型、Tool、Handoff 等定义入口。

OpenAI 当前主路径是 Agents SDK 的代码定义，而不是把 Agent 当作必须先通过通用 REST 管理 API 创建的持久化对象。

#### Tool

- [Function calling](https://developers.openai.com/api/docs/guides/function-calling)：通过函数名称、描述和 JSON Schema 定义自有 Tool，并由应用执行函数调用。
- [MCP and Connectors](https://developers.openai.com/api/docs/guides/tools-connectors-mcp)：通过远程 MCP Server 或 Connector 暴露外部能力。

Tool 多数是请求内或 SDK 内定义的能力，不对应统一的独立 `/tools` 创建资源。

#### Skill

- [Skills](https://developers.openai.com/api/docs/guides/tools-skills)：API 工具工作流中的 Skill 创建、装载与使用说明。
- [Codex Build skills](https://learn.chatgpt.com/docs/build-skills)：Codex 的 `SKILL.md` 目录结构、创建和复用方式。

这两类 Skill 均采用可复用指令与资源包的思路，但运行载体不同：前者面向 API Tool workflow，后者面向 Codex。

### 4.2 Anthropic Claude Platform

#### Agent

- [Create Agent API](https://platform.claude.com/docs/en/api/beta/agents/create)：Managed Agents Beta 的服务端创建接口。
- [Agent setup](https://platform.claude.com/docs/en/managed-agents/agent-setup)：说明 Agent 的模型、指令、工具集、环境与权限配置。

#### Tool

- [Define tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools)：定义客户端 Tool 的 `name`、`description`、`input_schema`、`input_examples` 和调用控制，是 Tool 创建/定义的主入口。
- [Managed Agents Tools](https://platform.claude.com/docs/en/managed-agents/tools)：把内置工具集、custom tool 或 MCP Connector 配置给 Managed Agent，是 Agent 绑定与运行层的补充入口。

Claude API 中的客户端 Tool 是请求内的工具契约，由调用方应用实际执行；Managed Agents 还允许将 custom tool 契约随 Agent 配置保存；MCP Tool 则由连接的 MCP Server 提供。Anthropic 没有面向这些客户端 Tool 的统一独立 CRUD 资源。

#### Skill

- [Create Skill API](https://platform.claude.com/docs/en/api/beta/skills/create)：创建独立 Skill 资源。
- [Agent Skills](https://platform.claude.com/docs/en/managed-agents/skills)：组织 `SKILL.md` 和附属文件、上传及绑定 Skill 的完整流程。

### 4.3 Microsoft Foundry

#### Agent

- [What is Foundry Agent Service](https://learn.microsoft.com/en-us/azure/foundry/agents/overview)：区分 Prompt Agent 与 Hosted Agent。
- [Prompt agent quickstart](https://learn.microsoft.com/en-us/azure/foundry/agents/quickstarts/prompt-agent)：通过 portal、SDK 或 REST 创建版本化 Prompt Agent。

#### Tool

- [Agent tools overview](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/tool-catalog)：内置 Tool、MCP、OpenAPI、A2A、Toolbox 与认证方式。
- [Build and register an MCP server](https://learn.microsoft.com/en-us/azure/foundry/mcp/build-your-own-mcp-server)：创建远程 MCP Server、注册到私有目录并连接 Agent。

#### Skill

- [Use skills with the Responses API](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/skills)：上传包含 `SKILL.md` 的目录或 ZIP，获得 `skill_id` 并挂载到 shell environment。
- [Agent Framework Skills](https://learn.microsoft.com/en-us/agent-framework/agents/skills)：文件型、代码型、类型和 MCP 型 Skill 的定义与 Provider 装载方式。

Microsoft 还有面向编码助手的 [Azure Agent Skills](https://learn.microsoft.com/en-us/training/support/agent-skills)。它属于开发知识包，不等同于 Foundry Agent Service 的运行时 Agent 资源。

### 4.4 Google Agent Platform / ADK

#### Agent

- [ADK Agents](https://adk.dev/agents/)：通过 `LlmAgent` 等类定义 Agent。
- [ReasoningEngine create API](https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1/projects.locations.reasoningEngines/create)：将 Agent 部署为云端 Reasoning Engine 资源。

#### Tool

- [Custom Tools](https://adk.dev/tools-custom/)：函数 Tool、Agent-as-a-Tool、长任务 Tool、OpenAPI 与 MCP Toolset。
- [Function Tools](https://adk.dev/tools/function-tools/)：把函数或方法包装为 Tool 的具体示例。

#### Skill

- [Skills for ADK agents](https://adk.dev/skills/)：从文件系统或代码定义 Skill，并通过 `SkillToolset` 装载；官方标注为 Experimental。

Google ADK Skill 是运行时可加载能力包，不应与 A2A Agent Card 中仅用于能力发现的 `skills` 描述混为一谈。

### 4.5 Amazon Bedrock AgentCore

#### Agent

- [AgentCore quickstart](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-get-started-cli.html)：使用 `agentcore create` 创建 Harness 或代码型 Agent 项目并部署。
- [AgentCore interfaces](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/develop-agents.html)：CLI、Python SDK、MCP Server、AWS SDK 与控制台的适用边界。

#### Tool

- [Harness Tools](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/harness-tools.html)：声明 MCP、Gateway、Browser、Code Interpreter 和 inline function Tool。
- [Creating a Code Interpreter](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/code-interpreter-create.html)：通过控制台、CLI 或 SDK 创建托管 Tool 资源。

#### Skill

- [Agent Registry quickstart](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/registry-get-started.html)：注册 Agent、Tool、Agent Skill 或自定义资源记录。

这里的 Agent Skill 文档重点是注册与发现；注册记录并不自动等价于 Agent Runtime 已安装并可执行的 Skill。

#### 旧版 Bedrock Agents 补充

- [CreateAgent](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateAgent.html)：Bedrock Agents Classic 的 Agent 创建 API。
- [CreateAgentActionGroup](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateAgentActionGroup.html)：为 Classic Agent 创建 Action Group，可视为该产品中的 Tool 能力集合。
- [Agents Classic maintenance mode](https://docs.aws.amazon.com/bedrock/latest/userguide/agents-classic-maintenance-mode.html)：官方维护状态与迁移提示。

新项目应先按官方现行建议评估 AgentCore，不应只因 Classic API 更像传统 CRUD 而把它作为默认基线。

### 4.6 LangChain / LangGraph / LangSmith

#### Agent

- [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents)：使用 `create_agent` 创建基于 LangGraph 的运行时 Agent。
- [Create Assistant API](https://docs.langchain.com/langsmith/agent-server-api/assistants/create-assistant)：在 LangSmith Deployment 中创建绑定既有 graph 的版本化 Assistant。

OSS Agent 是代码对象；LangSmith Assistant 是部署后的持久化配置资源，两者不应混作同一层级。

#### Tool

- [LangChain Tools](https://docs.langchain.com/oss/python/langchain/tools)：使用 `@tool`、结构化 schema、ToolNode 与动态 Tool 注册。

#### Skill

- [Skills architecture](https://docs.langchain.com/oss/python/langchain/multi-agent/skills)：把专业 prompt、知识与资源按需加载为 Skill 的架构模式。
- [Deep Agents Skills](https://docs.langchain.com/oss/python/deepagents/skills)：基于 `SKILL.md` 的发现和渐进式加载机制。

## 5. 国产平台详表

### 5.1 阿里云百炼 / Model Studio

#### Agent

- [Create Agent API](https://help.aliyun.com/en/model-studio/agent-create)：`POST /agents` 创建托管 Agent，并可引用 Tool 和 Skill。
- [Managed Agent definition](https://help.aliyun.com/en/model-studio/managed-agents-agent-definition)：Agent 定义和配置说明。

#### Tool

- [Plugins](https://help.aliyun.com/en/model-studio/plugins)：通过 OpenAPI 形式创建和使用插件能力。
- [Custom MCP services](https://help.aliyun.com/en/model-studio/custom-mcp)：接入自定义 MCP Server。

百炼的自定义 Tool 主要通过插件或 MCP 服务形成，不是统一的独立 `/tools` 管理资源。

#### Skill

- [Create Skill API](https://help.aliyun.com/en/model-studio/skill-create)：`POST /skills` 创建独立 Skill 资源，上传包以 `SKILL.md` 为入口。
- [Skill overview](https://help.aliyun.com/en/model-studio/introduction-to-skill)：控制台创建、结构和使用场景。

### 5.2 腾讯云智能体开发平台 ADP

#### Agent

- [CreateAgent API](https://cloud.tencent.com/document/api/1759/132576)：API 版本 `2026-05-20`，支持配置端和用户态 Agent。
- [API 接入概览](https://cloud.tencent.com/document/product/1759/133868)：说明应用、Agent、Plugin、Tool、Skill 的关系与完整开发链路。

#### Tool

- [CreatePlugin API](https://cloud.tencent.com/document/api/1759/133501)：创建包含一个或多个 Tool 的插件资源。
- [使用工具](https://cloud.tencent.com/document/product/1759/117856)：在智能工作台、Claw/Multi-Agent 和工作流中绑定 Tool。

腾讯 ADP 公开模型是“创建 Plugin，再显式绑定 Plugin 下的 Tool 到 Agent”，因此 CreatePlugin 是 Tool 创建链路的核心入口，而不是 CreateTool。

#### Skill

- [CreateSkill API](https://cloud.tencent.com/document/api/1759/133496)：创建独立 Skill。
- [API 概览](https://cloud.tencent.com/document/product/1759/132555)：列出 Skill 创建、修改、删除、共享、收藏和上架等完整管理接口。

### 5.3 Coze / Coze Studio

#### Agent

- [Create Bot API](https://www.coze.cn/open/docs/developer_guides/create_bot)：通过 OpenAPI 创建 Bot/Agent。
- [Coze Python SDK](https://github.com/coze-dev/coze-py)：官方 SDK 和 Bot、Chat、Workflow、Plugin 相关示例入口。

#### Tool

- [Coze Studio 插件配置](https://github.com/coze-dev/coze-studio/wiki/4.-%E6%8F%92%E4%BB%B6%E9%85%8D%E7%BD%AE)：官方开源版中内置插件、自定义插件和商业版插件的接入方式。

#### Skill

截至调研日期，未在 Coze OpenAPI 或 Coze Studio 官方公开文档中找到与 Bot、Plugin 同层级的独立 Skill 创建资源。应以平台后续正式 API Reference 为准，不把 Workflow、Plugin 或快捷指令改名为 Skill。

### 5.4 Dify

#### Agent

- [应用创建 Quickstart](https://docs.dify.ai/en/guides/application-orchestrate/creating-an-application)：在 Studio 中从空白应用创建并发布应用的完整流程。
- [Agent runtime API](https://docs.dify.ai/en/api-reference/guides/agent)：调用已发布 Agent 应用的运行时接口。

Dify 官方公开 API 以运行已发布应用为主；创建和编排 Agent 应用主要通过 Studio 控制台完成。

#### Tool

- [Tool Plugin](https://docs.dify.ai/en/develop-plugin/dev-guides-and-walkthroughs/tool-plugin)：使用 Dify CLI 初始化、实现、调试和打包 Tool Plugin。
- [Plugin type selection](https://docs.dify.ai/en/develop-plugin/getting-started/choose-plugin-type)：区分 Tool、Model、Agent Strategy、Extension、Datasource 与 Trigger 插件。

#### Skill

截至调研日期，Dify 官方公开文档未把 Skill 作为独立资源。`Agent Strategy Plugin` 用于实现 ReAct、Function Calling 等推理循环，职责是 Agent 运行策略，不等同于 `SKILL.md` 能力包。

### 5.5 百度千帆 AppBuilder

#### Agent

- [Agent 应用创建](https://cloud.baidu.com/doc/qianfan-docs/s/tm983fszw)：创建自主规划 Agent 或工作流 Agent、配置、调试和发布。
- [快速搭建应用](https://cloud.baidu.com/doc/qianfan/s/hmh4stph5)：对话式创建或自动生成 Agent 应用配置。
- [Agent API 概览](https://cloud.baidu.com/doc/qianfan/s/Xmhj1l82y)：公开 API 主要用于查询已发布 Agent、创建会话和执行任务。

#### Tool

- [创建 MCP 服务](https://cloud.baidu.com/doc/qianfan/s/zmh4stqex)：通过工作流组件或云函数创建 MCP Server，并接入自主规划 Agent。
- [平台概述](https://cloud.baidu.com/doc/qianfan-docs/s/0m8r1domp)：说明通过工作流创建、发布和上架组件的产品路径。

#### Skill

截至调研日期，百度千帆官方公开文档中的主要扩展对象是组件、MCP 和工作流，未见与 Agent 应用同层级的独立 Skill 创建资源。

## 6. 可直接用于接口选型的结论

### 6.1 Agent 创建存在三条主线

1. 托管资源 API：Anthropic、Microsoft Foundry、阿里云、腾讯云、Coze OpenAPI、LangSmith Assistant；
2. SDK/代码定义：OpenAI Agents SDK、Google ADK、LangChain、Hosted Agent；
3. 控制台优先：Dify、百度千帆，以及部分 Coze 低代码场景。

对接前应先确认所需的是“可版本化的服务端 Agent 资源”，还是“应用进程内的 Agent 定义”。两者都会被官方文档称作 create agent，但生命周期完全不同。

### 6.2 Tool 通常不是统一 CRUD 资源

主流实现集中在四类：

1. 函数/Schema：OpenAI、LangChain、Google ADK；
2. 随 Agent 配置的 custom tool：Anthropic；
3. 插件/OpenAPI/MCP：Microsoft、阿里云、腾讯云、Coze、Dify、百度；
4. 托管工具资源：AWS Code Interpreter 等少数产品。

因此，在跨平台设计中预设所有厂商都有 `POST /tools` 会造成错误抽象。

### 6.3 Skill 已成为独立概念，但成熟度不一致

- 有独立上传或创建链路：OpenAI API、Anthropic、Microsoft Azure OpenAI、阿里云、腾讯云；
- 以 SDK/文件系统装载为主：Google ADK、LangChain Deep Agents、Microsoft Agent Framework、Codex；
- 以注册与发现为主：AWS Agent Registry；
- 未见同层级公开创建资源：Coze、Dify、百度千帆。

Skill 的最常见可移植结构是一个带 YAML front matter 的 `SKILL.md` 加可选脚本、模板和参考资料，但具体上传协议、执行沙箱、版本管理和权限模型仍由各平台决定。

## 7. 证据边界与维护规则

### 7.1 已观察事实

- 表格和详表中的创建方式均来自 2026-07-21 可访问的官方资料。
- “未见同层级公开文档”仅表示本次官方资料核验结果，不是对厂商内部能力或未来路线的断言。
- 对 Skill、Plugin、MCP、Action Group 和 Agent Strategy 的区分按各平台原始术语保留。

### 7.2 本文不包含的设计决策

本文不是统一 Agent API 设计稿，不提出跨厂商资源模型，也不决定 pi-mono Java 或其他实现应采纳哪个字段或接口。若后续据此做 API 设计，需要重新读取目标代码、记录源代码 commit、路径和符号，并把观察行为、目标设计和差异原因分别写明。

### 7.3 更新建议

- 每季度复核一次 beta、preview、experimental 与 maintenance 状态；
- 优先保留 API Reference 或长期稳定的产品文档链接；
- 厂商更名或产品迁移时，同时保留迁移说明，避免旧 CRUD 接口被误认为当前首选路径；
- 新增平台时必须同时检查 Agent、Tool、Skill 三列，缺失项明确写“未见同层级公开文档”。

## 8. 版本历史

| 版本 | 日期 | 变更 |
| --- | --- | --- |
| 2.0.1 | 2026-07-21 | 将 Anthropic `Define tools` 设为 Tool 创建/定义主入口，保留 Managed Agents Tools 作为绑定与运行补充 |
| 2.0.0 | 2026-07-21 | 移除 metadata 字段调研；改为主流平台 Agent、Tool、Skill 创建官方文档索引；补充创建形态、证据边界和官方入口 |
| 1.0.0 | 2026-07-21 | 初始版本，整理 Agent 创建 API 与 metadata 字段 |

## 9. 图表说明

本文是链接索引与文字分类，没有需要通过关系图才能准确表达的复杂流程，因此本版不新增 PlantUML 图，也没有生成 SVG 文件。
