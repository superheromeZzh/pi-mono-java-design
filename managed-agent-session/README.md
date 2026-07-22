# Managed Agent 配置到 pi-mono-java Runtime 与 Session 的构建设计

| 属性 | 值 |
|---|---|
| 文档版本 | 0.4.0 |
| 状态 | Draft，供架构评审 |
| pi-mono 源码基线 | `216e672e7c9fc65682553394b74e483c0c9e47f7` |
| pi-mono-java 源码基线 | `b99871a0321b73606a8f074c42050f28f52fdfca` |
| 基线日期 | 2026-07-22 |
| 设计范围 | Agent 配置编译、Tool/Skill Manager 解析、pi-mono-java Runtime 装配、多 Session 创建、执行与恢复 |

## 1. 结论

本设计的首要目标不是直接创建 Session，而是先把一个版本化 Agent 配置装配为不可变、可复用的 `ResolvedAgentRuntime`：

```text
AgentConfig
    -> AgentRuntimeAssembler
        -> PromptCompiler
        -> ModelManager
        -> ToolManager
        -> SkillManager
    -> ResolvedAgentRuntime
    -> zero or more AgentSession instances
```

边界如下：

1. Agent 配置保持原结构，不删除 `enabled` 或 `permission`。
2. Agent Runtime 不解析 Tool 的 `enabled`、`permission` 和默认/逐项覆盖规则；完整 `tools` 配置交给 Tool Manager。
3. Agent Runtime 不解析 Skill 版本或加载 Skill 正文；完整 `skills` 引用交给 Skill Manager。
4. Tool Manager 返回模型可见的 `name`、`description`、`input_schema` 和不透明 Manifest/Binding，并负责权限判断与实际执行。
5. Skill Manager 返回模型可见的 `name`、`description`、固定版本和不透明 Manifest/Binding，并负责正文、资源的加载或激活。
6. system prompt 包含结构化 `system`、Tool 清单和 Skill 清单；Tool 清单写入 `name + description`，完整 `name + description + input_schema` 同时通过模型请求的独立 `tools` 字段发送。
7. system prompt 中的 Tool 清单和模型请求的 `tools` 必须由同一个固定 `ModelToolDescriptor` 快照生成，不维护两份可漂移的描述。
8. 容器启动后可以注册一个长期存活的 `ResolvedAgentRuntime`；每个对话仍创建独立的、有消息状态的 `AgentSession + Agent`。
9. 目标执行路径是 `ToolCallDispatcher` 把模型 tool call 直接转发给 Tool Manager；`ManagerBackedAgentTool` 只是不改造现有 `AgentLoop` 时的过渡适配。

## 2. 术语和生命周期

| 对象 | 含义 | 生命周期 | 是否共享 |
|---|---|---|---|
| `AgentConfig` | 版本化控制面配置 | 持久化 | 共享 |
| `ResolvedAgentRuntime` | 配置和各 Manager Manifest 的不可变装配结果 | Agent 版本或容器生命周期 | 共享 |
| `AgentSession` | 一个具体对话的运行时对象 | 对话生命周期 | 不共享 |
| `Agent` | pi-mono-java 底层有状态模型循环门面 | 与 Session 相同 | 不共享 |
| `Run` | 一条消息触发的一次模型/工具循环 | 单次执行 | 不共享 |

`ResolvedAgentRuntime` 是“容器启动后存在的 Agent 实例”的领域表达。它不是当前 `com.campusclaw.agent.Agent`，因为后者持有消息、队列、执行状态和取消状态。

本文使用“Tool 清单”和“Skill 清单”表示当前 Agent 版本对模型可见的固定能力集合。“目录”仅用于文件系统目录等真实层级结构，不作为 Manager Manifest 的领域术语。

## 3. 设计边界

本文使用以下标签：

- **观察到的行为**：当前 pi-mono 或 pi-mono-java 源码已经实现。
- **目标设计**：需要新增的 Managed Agent 装配能力。
- **产品约束**：为避免歧义而固定的产品语义。
- **安全加固**：用于防止版本漂移、越权调用或审批重放的约束。
- **架构变更**：当前实现需要重构或新增模块才能支持。

Tool Manager 和 Skill Manager 是独立于 Agent Runtime 的模块。本文只定义它们与装配层、Session 执行层之间的契约，不设计 Manager 内部如何连接 MCP Server、执行 builtin tool、存储 Skill Artifact 或展示审批 UI。

## 4. 源码证据

### 4.1 Anthropic Managed Agents 基线

参考：

- [Agent setup](https://platform.claude.com/docs/en/managed-agents/agent-setup)
- [Sessions](https://platform.claude.com/docs/en/managed-agents/sessions)
- [Events and streaming](https://platform.claude.com/docs/en/managed-agents/events-and-streaming)
- [Permission policies](https://platform.claude.com/docs/en/managed-agents/permission-policies)
- [Skills](https://platform.claude.com/docs/en/managed-agents/skills)

本文只采用以下抽象语义：

- Agent 是版本化配置。
- Session 固定关联一个 Agent 版本。
- 创建 Session 不等于立即执行模型。
- 用户消息触发或恢复 agent loop。
- 一轮执行完成后，Session 可以继续接收后续消息。

![Anthropic Managed Agent 到 Session 的基线生命周期](anthropic_managed_lifecycle.svg)

[PlantUML 源码](diagram.puml#L8)

### 4.2 pi-mono-java 当前行为

| 源码 | 关键符号 | 观察到的行为 |
|---|---|---|
| [`AgentSession.java`](../../pi-mono-java/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/session/AgentSession.java#L114) | `initialize(SessionConfig)` | 解析模型、刷新 Tool、加载 Skill 和上下文文件、构建 system prompt、创建 `Agent` |
| [`SystemPromptBuilder.java`](../../pi-mono-java/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/prompt/SystemPromptBuilder.java#L50) | `build()` | 拼接基础提示词、Tool 清单摘要、Skill 清单、上下文文件和环境信息 |
| [`DefaultToolCatalog.java`](../../pi-mono-java/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/tool/catalog/DefaultToolCatalog.java#L20) | `DefaultToolCatalog` | 合并 Spring、Extension 和声明式 Tool Source，输出 `AgentTool` |
| [`AgentTool.java`](../../pi-mono-java/modules/agent-core/src/main/java/com/campusclaw/agent/tool/AgentTool.java#L15) | `AgentTool` | Tool 同时携带 name、description、parameters schema 和 execute |
| [`Context.java`](../../pi-mono-java/modules/ai/src/main/java/com/campusclaw/ai/types/Context.java#L23) | `Context` | 模型请求上下文已将 system prompt、messages 和 tools 分开 |
| [`SkillLoader.java`](../../pi-mono-java/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/skill/SkillLoader.java#L30) | `SkillLoader` | 扫描本地 `SKILL.md` 并读取 name、description 和文件路径 |
| [`SkillPromptFormatter.java`](../../pi-mono-java/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/skill/SkillPromptFormatter.java#L24) | `format()` | 把 Skill 的 name、description、location 写入 system prompt |
| [`SkillExpander.java`](../../pi-mono-java/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/skill/SkillExpander.java#L76) | `expand()` | 处理 `/skill:name` 并从本地文件读取 Skill 正文 |
| [`AgentLoop.java`](../../pi-mono-java/modules/agent-core/src/main/java/com/campusclaw/agent/loop/AgentLoop.java#L212) | `new Context(...)` | 每轮向模型传递 system prompt、messages 和独立 tools 列表 |
| [`AgentLoop.java`](../../pi-mono-java/modules/agent-core/src/main/java/com/campusclaw/agent/loop/AgentLoop.java#L312) | `toLlmTools()` | 将 `AgentTool` 转为 name、description、parameters |
| [`AnthropicProvider.java`](../../pi-mono-java/modules/ai/src/main/java/com/campusclaw/ai/provider/anthropic/AnthropicProvider.java#L198) | `buildParams()` / `convertTools()` | 将 `Context.tools` 写入 Anthropic `tools`，并将 parameters 转为 `input_schema` |
| [`ToolExecutionPipeline.java`](../../pi-mono-java/modules/agent-core/src/main/java/com/campusclaw/agent/tool/ToolExecutionPipeline.java#L119) | `invokeTool()` | 校验参数后调用 `AgentTool.execute()` |
| [`SessionManager.java`](../../pi-mono-java/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/session/SessionManager.java#L160) | `loadSession()` | 从 JSONL 恢复消息 |
| [`SessionPool.java`](../../pi-mono-java/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/SessionPool.java#L186) | `getOrCreate()` | 按 conversation ID 管理多个 `AgentSession` |

当前 `com.campusclaw.codingagent.skill.SkillManager` 负责本地 Skill 的安装、链接、更新和删除，不是本文目标中的独立运行时 Skill Manager。Java 实现应使用 `SkillManagerGateway`、`ExternalSkillManagerClient` 等名称避免冲突。

### 4.3 pi-mono 对照基线

| 源码 | 关键符号 | 对照意义 |
|---|---|---|
| [`packages/coding-agent/src/core/sdk.ts`](../../pi-mono/packages/coding-agent/src/core/sdk.ts#L164) | `createAgentSession()` | 每次 Session 创建独立 `Agent` 与 `AgentSession` |
| [`packages/coding-agent/src/core/system-prompt.ts`](../../pi-mono/packages/coding-agent/src/core/system-prompt.ts#L28) | `buildSystemPrompt()` | system prompt 是装配结果，不包含消息状态 |
| [`packages/coding-agent/src/core/skills.ts`](../../pi-mono/packages/coding-agent/src/core/skills.ts#L335) | `formatSkillsForPrompt()` | Skill 清单进入 system prompt，正文按需读取 |
| [`packages/agent/src/agent.ts`](../../pi-mono/packages/agent/src/agent.ts#L171) | `Agent` | Agent 持有 transcript、queue 和 active run，不能跨 Session 共享 |

### 4.4 主流 Agent 系统的 Tool 模型可见方式

| 系统 | 官方机制 | 对本设计的含义 |
|---|---|---|
| [Anthropic Tool use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools) | 提供 `tools` 时，Anthropic 会用 Tool 定义、Tool 配置和用户 system prompt 组成模型的特殊有效 system prompt | Tool 的 name、description 和 schema 是模型上下文的一部分，但 API 协议仍通过独立 `tools` 字段提交 |
| [OpenAI Agents SDK: Tools](https://openai.github.io/openai-agents-python/tools/) 与 [Agents](https://openai.github.io/openai-agents-python/agents/) | Agent `instructions` 与 Tool 列表分离；Function Tool 包含 name、description 和 JSON Schema | 未必把 Tool 文本手工写进 instructions，但 name 和 description 必须通过 Tool 协议对模型可见 |
| [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents) 与 [Tools](https://docs.langchain.com/oss/python/langchain/tools) | v1 Agent 分离 `system_prompt` 和 `tools`；[classic ReAct](https://reference.langchain.com/python/langchain-classic/agents/react/agent/create_react_agent) 则显式要求 prompt 包含 `{tools}` 和 `{tool_names}` | Tool 清单可以由 Provider 协议或提示词渲染承载，但都应来自同一 Tool 定义 |
| [AutoGen Tools](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/components/tools.html) | system message 与模型请求中的 Tool schema 分离 | Tool 协议是模型可用能力的权威调用描述 |
| [Google Agents CLI tutorial](https://google.github.io/agents-cli/guide/hands-on-tutorial/) | Agent instruction 与 tools 分离，函数名和 docstring 用于形成 Tool 描述 | Tool 描述必须可见且应由工具定义生成 |

**调研结论**：主流系统都会让 Tool 的 `name + description` 对模型可见，差异在于它们是由 Provider 通过原生 Tool 协议注入有效上下文，还是由 Agent 框架显式渲染到 prompt。因此，不能把“客户端 system 字符串与 `tools` 字段分离”误解为“模型上下文中不包含 Tool 的 name 和 description”。

**目标决策**：Managed Agent 默认采用双通道：system prompt 显式写入 Tool 清单，模型请求 `tools` 字段写入完整 Tool Schema。这是产品约束，不是对上述框架的现有行为声称。两个通道必须从同一个不可变 Manifest 快照渲染。

## 5. pi-mono-java 当前 Session 构建流程

![pi-mono-java 当前 Session 资源加载流程](pi_mono_java_current_loading.svg)

[PlantUML 源码](diagram.puml#L50)

### 5.1 CLI 和 Server 入口

CLI 的 `CampusClawCommand.runAgentMode()` 先解析有效 Tool，再创建 `AgentSession` 和 `SessionConfig`：

```text
effectiveTools = resolveEffectiveTools(cwd, toolSelection)

session = new AgentSession(
    aiService,
    modelRegistry,
    promptBuilder,
    skillLoader,
    skillExpander,
    effectiveTools
)

session.initialize(
    SessionConfig(model, cwd, customPrompt, mode)
)
```

Server 模式创建一个 `SessionPool`。每个 conversation ID 首次访问时，`SessionPool.createSessionWithPersistence()` 创建独立 `AgentSession`；驱逐或进程重启后，可通过 JSONL 恢复消息。

### 5.2 当前 initialize 顺序

```text
function AgentSession.initialize(config):
    model = resolveModel(config.model)
    cwd = config.cwd

    refreshTools(cwd)
    loadSkills(cwd)

    contextFiles = load AGENTS.md / CLAUDE.md
    systemOverride = load SYSTEM.md
    appendSystem = load APPEND_SYSTEM.md
    promptTemplates = load prompt templates

    visibleSkills = SkillRegistry.getVisibleSkills()

    systemPrompt = SystemPromptBuilder.build({
        tools,
        visibleSkills,
        cwd,
        config.customPrompt,
        environment,
        contextFiles,
        systemOverride,
        appendSystem
    })

    agent = new Agent(aiService)
    agent.setModel(model)
    agent.setSystemPrompt(systemPrompt)
    agent.setTools(tools)
```

### 5.3 当前 system prompt 顺序

`SystemPromptBuilder.build()` 当前按以下顺序拼接：

1. 项目或全局 `SYSTEM.md`；不存在时使用硬编码 `BASE_PROMPT`。
2. 基于 Tool 名称生成的条件规则。
3. Tool 的 name 和 description 清单；目标架构保留这一可见性，但改为从固定 `ModelToolDescriptor` 快照统一渲染。
4. Skill 的 name、description、location。
5. 全局和目录层级中的 `AGENTS.md` 或 `CLAUDE.md`。
6. 硬编码园区知识库指引。
7. 日期、cwd、操作系统、Java、Shell 等环境信息。
8. `APPEND_SYSTEM.md`。
9. CLI `customPrompt`。

Tool 的 `input_schema` 不写入 system prompt。它保留在 `AgentTool.parameters()` 中，并由 `AgentLoop.toLlmTools()` 放入模型请求的独立 tools 字段。Java 中间类型使用 `parameters` 这个名称；Anthropic Provider 才在协议边界将它序列化为 `input_schema`。

### 5.4 当前 Skill 激活方式

当前 Skill 是文件系统对象：

```text
Skill:
    name
    description
    filePath
    baseDir
    source
    disableModelInvocation
```

system prompt 只列出 Skill 清单。完整正文通过两条路径进入消息上下文：

- 模型调用 `read` 读取 system prompt 中的 `location`。
- 用户输入 `/skill:name` 后，`SkillExpander` 读取 `SKILL.md` 正文并扩展用户消息。

### 5.5 每轮执行

```text
AgentSession.prompt(userInput)
    -> expand prompt template
    -> expand /skill:name
    -> Agent.prompt()
    -> AgentLoop
    -> Context(systemPrompt, messages, modelTools)
    -> Provider
    -> optional tool calls
    -> ToolExecutionPipeline
    -> AgentTool.execute()
    -> ToolResultMessage
    -> next model turn
```

## 6. 当前实现与目标配置的差距

| 维度 | 当前 pi-mono-java | 目标设计 |
|---|---|---|
| Agent 配置 | `SessionConfig(model,cwd,prompt,mode)` | 版本化完整 AgentConfig |
| system | 硬编码 Base 或本地 SYSTEM.md | 结构化 system 字段编译 |
| Tool 来源 | 进程内 ToolCatalog | 独立 Tool Manager |
| Tool 模型描述 | `AgentTool` 上的 name/description/parameters | Tool Manager 固定的 ModelToolDescriptor |
| Tool 清单与 Tool Schema | system prompt 摘要和 `Context.tools` 分别装配 | 由同一 Descriptor 快照生成两个通道 |
| Tool 执行入口 | `AgentTool.execute()` | `ToolCallDispatcher` 直接转发 `ToolManager.invoke()` |
| Tool 权限 | Runtime hook 或 Tool 自己处理 | Tool Manager 解析配置并权威执行 |
| Skill 来源 | 本地目录扫描 | 独立 Skill Manager |
| Skill 身份 | name + Path | skill_id + fixed version + binding |
| Agent Runtime | 每个 Session 临时解析 | 容器级不可变 Runtime |
| 恢复元数据 | 主要恢复消息 | 固定 Agent、Tool、Skill、Model Manifest |

因此，不能直接把 Agent 配置塞入现有 `SessionConfig.customPrompt`，也不能直接把 Manager Skill 映射为当前依赖本地 Path 的 `Skill`。

## 7. 输入 Agent 配置及字段归属

```json
{
  "id": "agent-id",
  "type": "agent",
  "version": 1,
  "created_at": "timestamp",
  "updated_at": "timestamp",
  "name": "agent-name",
  "display_name": "Agent Display Name",
  "description": "Agent description",
  "model": ["provider/model-id"],
  "system": {
    "role": "...",
    "objective": "...",
    "instructions": "...",
    "tool_policy": "...",
    "safety": "...",
    "completion": "...",
    "response_style": "...",
    "example": "..."
  },
  "use_cases": ["intent-routing-example"],
  "tools": [
    {
      "type": "builtin-toolset",
      "default_config": {
        "enabled": true,
        "permission": "always_ask"
      },
      "configs": [
        {
          "name": "tool-name",
          "enabled": true,
          "permission": "always_allow"
        }
      ]
    }
  ],
  "skills": [
    {
      "skill_id": "skill-id",
      "version": "fixed-version-or-omitted"
    }
  ],
  "metadata": {
    "environment": "prod",
    "owner_id": "admin"
  }
}
```

字段归属：

| 配置字段 | 解析组件 | Agent Runtime 是否解析 |
|---|---|---|
| `id/version` | Agent Control Plane / Runtime Assembler | 只持有固定值 |
| `system.*` | Prompt Compiler | 不在 Session 内重复解释 |
| `model[]` | Model Manager | 只持有 Manifest |
| `tools[]` 全部字段 | Tool Manager | 否 |
| `skills[]` 全部字段 | Skill Manager | 否 |
| `use_cases` | Agent Router | 否 |
| `metadata` | Control Plane / Session Context Factory | 只持有所需快照 |

`permission` 保留在 Agent 配置中，但属于 Tool Manager 的配置命名空间。Agent Runtime 不计算 effective permission。

## 8. 目标架构

![独立 Tool/Skill Manager 与 pi-mono-java Runtime 的目标架构](external_tool_manager_architecture.svg)

[PlantUML 源码](diagram.puml#L100)

### 8.1 Runtime 装配结果

```text
record ResolvedAgentRuntime:
    agent_id: string
    agent_version: integer
    config_hash: string

    compiled_system: string

    model_manifest_id: string
    model_candidates: list<ModelDescriptor>

    tool_manifest_id: string
    model_tools: list<ModelToolDescriptor>

    skill_manifest_id: string
    model_skills: list<ModelSkillDescriptor>

    use_cases: list<string>
    metadata_snapshot: map
```

`ResolvedAgentRuntime` 不保存 Tool 或 Skill 的业务实现，也不保存 Manager 内部 permission 结构。

### 8.2 Tool Manager 契约

```text
record AgentKey:
    agent_id: string
    agent_version: integer

record ToolManifest:
    manifest_id: string
    agent_key: AgentKey
    tools: list<ModelToolDescriptor>

record ModelToolDescriptor:
    binding_id: string
    model_name: string
    label: string
    description: string
    input_schema: JsonSchema
    descriptor_version: string
    schema_hash: string

interface ToolManager:
    bindAgentTools(agent_key, raw_toolsets) -> ToolManifest
    invoke(invocation_request) -> ToolInvocationResult
```

`bindAgentTools()` 内部负责：

1. 根据 `type` 路由 builtin 或 MCP Tool。
2. 合并 `default_config` 与逐 Tool 配置。
3. 过滤 disabled Tool。
4. 解析并固定 Tool descriptor、schema 和 binding。
5. 保存 `always_ask`、`always_allow` 等权限策略。
6. 检查模型可见名称冲突。
7. 返回不包含 Manager 内部权限结构的 Manifest。

`invoke()` 内部负责：

- 校验 Manifest 和 Binding。
- 根据 Agent、用户、租户、参数和环境评估权限。
- 在需要时创建并等待或返回用户审批。
- 执行实际 builtin 或 MCP Tool。
- 返回 Completed、ApprovalRequired、Denied 或 Failed。

### 8.3 Skill Manager 契约

```text
record SkillManifest:
    manifest_id: string
    agent_key: AgentKey
    skills: list<ModelSkillDescriptor>

record ModelSkillDescriptor:
    binding_id: string
    skill_id: string
    version: string
    name: string
    description: string
    descriptor_version: string
    content_hash: string

interface SkillManager:
    bindAgentSkills(agent_key, raw_skill_refs) -> SkillManifest
    activate(activation_request) -> ActivatedSkill
```

`bindAgentSkills()` 在省略版本时解析最新版本，但返回结果必须固定为具体版本。`activate()` 返回 Skill instructions、resources 和相对资源引用。Agent Runtime 不直接读取 Skill Manager 的存储。

如果某种“Skill”本身执行有副作用的业务动作，应把该动作暴露成 Tool；Skill 仍表示指令和资源，避免一个概念同时承担提示词和远程动作两种语义。

## 9. Agent Runtime 装配

```text
function assembleAgentRuntime(agentConfig):
    validateAgentEnvelope(agentConfig)

    agentKey = AgentKey(
        agentConfig.id,
        agentConfig.version
    )

    modelManifest = ModelManager.resolveAgentModels(
        agentKey,
        agentConfig.model
    )

    // Runtime Assembler does not parse enabled or permission.
    toolManifest = ToolManager.bindAgentTools(
        agentKey,
        agentConfig.tools
    )

    // Runtime Assembler does not resolve versions or load content.
    skillManifest = SkillManager.bindAgentSkills(
        agentKey,
        agentConfig.skills
    )

    compiledSystem = compileStructuredSystem(
        agentConfig.system
    )

    validateModelToolDescriptors(
        toolManifest.tools
    )
    validateSkillPromptDescriptors(
        skillManifest.skills
    )

    return ResolvedAgentRuntime({
        agent_id: agentConfig.id,
        agent_version: agentConfig.version,
        config_hash: canonicalHash(agentConfig),

        compiled_system: compiledSystem,

        model_manifest_id: modelManifest.manifest_id,
        model_candidates: modelManifest.models,

        tool_manifest_id: toolManifest.manifest_id,
        model_tools: toolManifest.tools,

        skill_manifest_id: skillManifest.manifest_id,
        model_skills: skillManifest.skills,

        use_cases: immutable(agentConfig.use_cases),
        metadata_snapshot: immutable(agentConfig.metadata)
    })
```

装配成功后，由 `AgentRuntimeRegistry` 按 `agent_id + version` 注册不可变 Runtime。配置升级创建新 Runtime，不原地修改旧版本。

## 10. system prompt 编译

### 10.1 结构化 system

```text
function compileStructuredSystem(system):
    sections = [
        ("Role", system.role),
        ("Objective", system.objective),
        ("Instructions", system.instructions),
        ("Tool Policy", system.tool_policy),
        ("Safety", system.safety),
        ("Completion", system.completion),
        ("Response Style", system.response_style),
        ("Examples", system.example)
    ]

    return joinWithStableHeadings(
        removeEmpty(sections)
    )
```

这是语言无关伪代码，不是 TypeScript 或 Java 的精确语法。

### 10.2 Tool 在模型上下文中的位置

目标设计默认采用双通道：

1. system prompt 中的 Tool 清单写入 `name + description`，用于能力导航、Tool 选择和与 `tool_policy` 的语义配合。
2. 模型请求的 `tools` 字段写入 `name + description + input_schema`，作为 Provider 调用协议。

system prompt 中不写入 `input_schema`，避免 Schema 文本膨胀。Tool 清单可以渲染为：

```text
# Available Tools

<available_tools>
  <tool>
    <name>search_documents</name>
    <description>Search documents visible to the current user.</description>
  </tool>
</available_tools>
```

模型请求使用同一份 Descriptor 快照：

```text
ModelRequest:
    system = final_system_prompt
    messages = session_messages
    tools = runtime.model_tools.map(tool -> {
        name: tool.model_name,
        description: tool.description,
        input_schema: tool.input_schema
    })
```

两个通道不是两份配置。它们必须由同一个 `runtime.model_tools` 生成：

```text
function renderToolChannels(modelTools):
    toolList = modelTools.map(tool -> {
        name: tool.model_name,
        description: tool.description
    })

    requestTools = modelTools.map(tool -> {
        name: tool.model_name,
        description: tool.description,
        input_schema: tool.input_schema
    })

    require sameNamesAndDescriptions(
        toolList,
        requestTools
    )

    return { toolList, requestTools }
```

Provider Adapter 按目标模型协议转换字段名：

| 模型协议 | 请求位置 |
|---|---|
| Anthropic Messages | `tools[].input_schema` |
| OpenAI Chat Completions | `tools[].function.parameters` |
| OpenAI Responses | `tools[].parameters` |
| Mistral Conversations | `tools[].function.parameters` |

对于原生 Tool 协议已经把描述注入有效上下文、且对 token 极度敏感的 Provider，可以显式配置 `NATIVE_ONLY` 兼容模式，省略 system prompt 中的 Tool 清单；它不是 Managed Agent 默认值。无论使用哪种模式，都不得手工维护第二份 Tool 描述或把完整 Schema 复制进 system prompt。

Tool 清单不展开 effective permission，Agent Runtime 也不把 permission 作为权威判断。`system.tool_policy` 只表达 Agent 的一般工具使用原则；某次调用是否需要审批、是否允许执行，始终以 `ToolManager.invoke()` 为准。

### 10.3 Skill 在模型上下文中的位置

system prompt 只写 Skill 清单：

```text
# Available Skills

Use a skill when the task matches its description.
Load the skill before following its instructions.

<available_skills>
  <skill>
    <id>incident-analysis</id>
    <version>3</version>
    <name>incident-analysis</name>
    <description>Analyze production incidents.</description>
  </skill>
</available_skills>
```

默认不把所有 Skill 正文写入 system prompt，以避免无关指令、上下文膨胀和版本混淆。完整正文通过 Manager-backed `load_skill` 或 `/skill:name` 激活后进入消息上下文。

### 10.4 静态和动态提示词

Runtime 装配阶段生成静态部分：

- role、objective、instructions。
- tool policy、safety、completion。
- response style、examples。
- Tool 清单：来自 `runtime.model_tools` 的 name 和 description。
- Skill 清单：来自 `runtime.model_skills` 的 name 和 description。

Session 创建阶段补充动态部分：

- 当前时间和 cwd。
- tenant、user 和环境。
- 被允许的项目上下文文件。

Managed 模式默认不允许本地 `SYSTEM.md` 覆盖 AgentConfig.system。`AGENTS.md/CLAUDE.md` 是否加载、`APPEND_SYSTEM.md` 是否允许，应成为显式产品策略。

## 11. pi-mono-java Tool Schema 传递与直接转发

### 11.1 当前 Schema 传递链

**观察到的行为**：pi-mono-java 已经把 Schema 放在模型请求的 tools 字段，不是 system prompt。内部类型将 `input_schema` 称为 `parameters`：

```text
AgentTool.parameters()
    -> AgentLoop.toLlmTools()
    -> new Tool(name, description, parameters)
    -> Context.tools
    -> Provider.convertTools()
    -> model request tools field
```

Anthropic 路径等价于：

```text
function AnthropicProvider.buildParams(context):
    if context.tools is not empty:
        request.tools = context.tools.map(tool -> {
            name: tool.name,
            description: tool.description,
            input_schema: buildInputSchema(tool.parameters)
        })
```

因此目标设计不需要改变 `Context.tools` 和 Provider 的基本分层。需要解耦的是 `AgentContext.tools(): List<AgentTool>` 把模型可见描述和本地执行实现绑在同一个接口中。

### 11.2 目标执行抽象

**架构变更**：Agent Runtime 持有模型可见的 `RuntimeToolSet` 和统一 `ToolCallDispatcher`，不再要求每个 Tool 实现 `AgentTool.execute()`。`Set` 表示当前 Agent 版本固定的 Tool 清单，避免把它误解为文件目录或用于全局发现的开放目录。

```text
record RuntimeToolSet:
    manifest_id: string
    descriptors_by_model_name:
        map<string, ModelToolDescriptor>

    asModelTools():
        return descriptors.map(descriptor -> {
            name: descriptor.model_name,
            description: descriptor.description,
            parameters: descriptor.input_schema
        })

interface ToolCallDispatcher:
    dispatch(tool_call, session_execution_context)
        -> ToolResultMessage
```

AgentLoop 目标伪代码：

```text
function invokeModel(agentContext):
    llmContext = Context(
        agentContext.system_prompt,
        convertMessages(agentContext.messages),
        agentContext.runtime_tool_set.asModelTools()
    )

    return streamFunction.stream(
        model,
        llmContext,
        streamOptions
    )

function runToolPhase(toolCalls, agentContext):
    results = []

    for toolCall in toolCalls:
        results.append(
            agentContext.tool_call_dispatcher.dispatch(
                toolCall,
                agentContext.session_execution_context
            )
        )

    append results to conversation messages
```

Tool Manager 实现的 Dispatcher：

```text
class ToolManagerToolCallDispatcher
    implements ToolCallDispatcher:

    runtime_tool_set
    tool_manager

    dispatch(toolCall, context):
        descriptor = runtime_tool_set
            .findByModelName(toolCall.name)

        if descriptor is null:
            return toolError(
                toolCall,
                "TOOL_NOT_AVAILABLE_TO_AGENT"
            )

        managerResult = tool_manager.invoke({
            manifest_id:
                runtime_tool_set.manifest_id,
            binding_id: descriptor.binding_id,

            agent_id: context.agent_id,
            agent_version: context.agent_version,
            session_id: context.session_id,
            run_id: context.run_id,
            tool_call_id: toolCall.id,

            tenant_id: context.tenant_id,
            user_id: context.user_id,
            arguments: toolCall.arguments,
            arguments_hash:
                canonicalHash(toolCall.arguments),
            execution_context:
                context.tool_execution_context
        })

        return convertToToolResultMessage(
            toolCall,
            managerResult
        )
```

Agent Runtime 只根据已固定 `RuntimeToolSet` 确认 tool name 是否属于当前 Agent，不解析 permission，也不执行 Tool。Tool Manager 使用固定 Manifest 完成 schema 校验、权限审批、实际执行和结果标准化。

不应在 Agent Runtime 和 Tool Manager 中各自维护一份可漂移的 schema 校验逻辑。Runtime 可以使用 Manifest 中的 schema hash 校验发送给模型的 Schema 没有被替换；Tool Manager 是执行前参数校验的权威边界。

### 11.3 `ManagerBackedAgentTool` 兼容方案

**有意差异：架构过渡**。如果第一阶段不修改现有 `AgentLoop`、`AgentContext` 和 `ToolExecutionPipeline`，可以用通用 `ManagerBackedAgentTool` 适配当前类型：

```text
class ManagerBackedAgentTool implements AgentTool:
    parameters():
        return descriptor.input_schema

    execute(toolCallId, arguments, signal, onUpdate):
        return ToolManager.invoke(
            pinned manifest and binding,
            session context,
            arguments
        )
```

该适配器不包含具体 Tool 实现，但它仍然保留了“每个 Tool 映射为一个 `AgentTool`”的现有类型约束。它不是目标架构的必需对象，应在 `ToolCallDispatcher` 落地后移除。

### 11.4 Anthropic Schema 完整性缺口

**观察到的行为**：当前 `AnthropicProvider.buildInputSchema()` 只显式复制顶层 `properties` 和 `required`。Tool Manager 返回的完整 JSON Schema 可能包含 `additionalProperties`、`oneOf`、`anyOf`、`allOf`、`$defs` 等关键字，当前 Anthropic 转换不保证完整传递这些顶层结构。

**目标设计**：Provider Adapter 必须尽可能无损传递 Tool Manager 固定的 Schema。如果目标 Provider 不支持某个 JSON Schema 特性，Runtime 装配应失败并报告不兼容关键字，不得静默丢弃。

需要增加契约测试：

```text
ToolManager input_schema
    -> RuntimeToolSet
    -> Context.tools.parameters
    -> Provider request tools schema

require canonicalSchemaHash(before)
    == canonicalSchemaHash(after)
```

Provider 协议强制增补的默认字段可以允许，但必须有明确的归一化规则。

### 11.5 Skill Descriptor 到当前 Skill 流程

当前 `Skill` 强依赖本地 `filePath/baseDir`，不能直接承载 Manager Skill。推荐引入与存储无关的 `RuntimeSkillDescriptor`，并让 `SkillPromptFormatter` 接收该描述。

激活路径：

```text
function loadManagedSkill(skillId, runtime, sessionContext):
    allowed = runtime.model_skills.findById(skillId)

    if allowed is null:
        fail("SKILL_NOT_AVAILABLE_TO_AGENT")

    activated = SkillManager.activate({
        manifest_id: runtime.skill_manifest_id,
        binding_id: allowed.binding_id,
        skill_id: allowed.skill_id,
        version: allowed.version,
        session_id: sessionContext.session_id,
        user_id: sessionContext.user_id
    })

    require activated.version == allowed.version
    require hash(activated.instructions)
        == allowed.content_hash

    return activated
```

两种接入方式：

1. 推荐：在 `RuntimeToolSet` 中注册一个 Manager-backed `load_skill` Tool，模型和 `/skill:name` 都通过 `ToolCallDispatcher` 激活 Skill。
2. 过渡：Skill Manager 将固定版本 Artifact 物化到只读缓存，再映射为现有 `Skill(Path)`。

### 11.6 Model 映射

当前 `AgentSession.resolveModel(String)` 支持一个字符串和模糊匹配。目标 `model[]` 应由 Model Manager 在 Runtime 或 Session 创建阶段选择具体 `Model`，然后直接调用 `agent.setModel(model)`，避免恢复时重新模糊匹配。

### 11.7 SystemPromptBuilder 映射

不应把 `compileStructuredSystem()` 的结果塞入当前 `customPrompt`。推荐增加：

```text
SystemPromptBuilder.buildManaged({
    base_prompt: runtime.compiled_system,
    tools: runtime.model_tools,
    skills: runtime.model_skills,
    session_context: sessionContext,
    project_context_policy: ...
})
```

该方法取代硬编码 `BASE_PROMPT`，但继续复用当前 Tool/Skill 清单格式、项目上下文和环境信息的装配能力。`tools` 和 `skills` 只接收 Runtime 已固定的 Descriptor 快照；Tool 清单渲染 name 和 description，而同一批 Tool 的完整 schema 由 `RuntimeToolSet.asModelTools()` 传递到 `Context.tools`。

## 12. 基于 Runtime 创建 pi-mono-java Session

![基于 ResolvedAgentRuntime 创建 pi-mono-java Session](pi_session_creation.svg)

[PlantUML 源码](diagram.puml#L176)

```text
function createManagedSession(
    agentId,
    requestedVersion,
    sessionContext
):
    runtime = AgentRuntimeRegistry.getExactOrLatest(
        agentId,
        requestedVersion
    )

    sessionId = SessionStore.reserveId()
    boundContext = sessionContext.with({
        session_id: sessionId,
        agent_id: runtime.agent_id,
        agent_version: runtime.agent_version
    })

    selectedModel = ModelManager.selectForSession(
        runtime.model_manifest_id,
        boundContext
    )

    runtimeToolSet = RuntimeToolSet.create({
        manifest_id: runtime.tool_manifest_id,
        descriptors: runtime.model_tools
    })

    toolCallDispatcher =
        ToolManagerToolCallDispatcher({
            runtime_tool_set: runtimeToolSet,
            tool_manager: ToolManager
        })

    finalSystemPrompt = SystemPromptBuilder.buildManaged({
        base_prompt: runtime.compiled_system,
        tools: runtime.model_tools,
        skills: runtime.model_skills,
        session_context: boundContext
    })

    sessionManager = SessionManager.createOrOpen(
        sessionId,
        boundContext.cwd
    )

    // Target-only overload or factory.
    session = AgentSessionFactory.createManaged({
        model: selectedModel,
        system_prompt: finalSystemPrompt,
        model_tools:
            runtimeToolSet.asModelTools(),
        tool_call_dispatcher:
            toolCallDispatcher,
        skill_manifest_id:
            runtime.skill_manifest_id,
        session_manager: sessionManager
    })

    restoredMessages = sessionManager.loadSession()
    session.getAgent().replaceMessages(
        restoredMessages
    )

    snapshot = buildSessionSnapshot(
        runtime,
        selectedModel,
        sessionId,
        boundContext
    )

    SessionStore.commit(snapshot)

    return {
        session_id: sessionId,
        agent_id: runtime.agent_id,
        agent_version: runtime.agent_version,
        status: "idle",
        session: session
    }
```

`createManagedSession()` 不调用模型。后续 `session.prompt()` 才进入支持 `model_tools + tool_call_dispatcher` 的 AgentLoop。

上述 `model_tools + tool_call_dispatcher` 是目标新接口。在过渡模式中，Session Factory 可把同一 `RuntimeToolSet` 物化为 `List<ManagerBackedAgentTool>` 传入现有 `agent.setTools()`，但不应把这个兼容形态写入 Manager 契约。

## 13. Tool 调用时序

```text
AgentLoop invokes Provider with Context.tools
    -> Provider sends name, description and input_schema
       in the model request tools field
    -> Model emits tool call(name, arguments)
    -> ToolCallDispatcher resolves the pinned descriptor
       by model name
    -> ToolManager.invoke(manifest_id, binding_id, context, args)
    -> Tool Manager validates arguments against
       the pinned input_schema
    -> Tool Manager evaluates permission
        -> allow: execute actual Tool
        -> approval: wait or return ApprovalRequired
        -> deny: return Denied
    -> Dispatcher converts result to ToolResultMessage
    -> AgentLoop continues
```

Agent Runtime 检查模型调用的名称是否存在于当前 Runtime 的 model tools 中；Tool Manager 再检查 Manifest、Binding、参数和权限。两层检查分别回答：

- 该 Agent 是否拥有这个 Tool。
- 这次调用是否允许实际执行。

## 14. SessionSnapshot 与恢复

```text
record SessionSnapshotV2:
    snapshot_version: 2
    session_id: string
    created_at: timestamp

    agent_id: string
    agent_version: integer
    config_hash: string

    compiled_system_hash: string

    model_manifest_id: string
    selected_model: string

    tool_manifest_id: string
    skill_manifest_id: string

    environment: string
    owner_id: string
```

恢复时：

```text
function restoreManagedSession(sessionId, context):
    snapshot = SessionStore.get(sessionId)

    runtime = AgentRuntimeRegistry.getExact(
        snapshot.agent_id,
        snapshot.agent_version
    )

    require runtime.config_hash
        == snapshot.config_hash
    require runtime.tool_manifest_id
        == snapshot.tool_manifest_id
    require runtime.skill_manifest_id
        == snapshot.skill_manifest_id
    require runtime.model_manifest_id
        == snapshot.model_manifest_id

    return createOrRestoreFromPinnedRuntime(
        runtime,
        snapshot,
        context
    )
```

Runtime 和 Manager 必须能够按固定 Manifest 恢复；不能按名称静默绑定到最新 Tool 或 Skill。

## 15. 失败处理

| 场景 | 结果 | 原因 |
|---|---|---|
| Agent 版本不存在 | Runtime 创建或恢复失败 | 禁止替换为 latest |
| Tool Manager 不可用 | Runtime 装配失败 | 无法形成模型工具协议 |
| Tool 配置没有 permission 且 Manager 无安全默认值 | Runtime 装配失败 | 避免未定义授权 |
| Tool 模型名称冲突 | Runtime 装配失败 | Dispatcher 按模型名称解析固定 Binding |
| input schema 非法 | Runtime 装配失败 | 无法形成模型可见的 Tool 描述 |
| Provider 不支持 Schema 特性 | Runtime 装配失败 | 禁止 Provider Adapter 静默丢弃约束 |
| Skill 版本不存在 | Runtime 装配失败 | 不能静默使用其他版本 |
| Skill 无法激活 | 当前 Skill 调用失败 | 不自动加载 latest |
| Manifest 不存在或不匹配 | Session 恢复失败 | 防止供应链漂移 |
| Tool Manager 要求审批 | Session 等待或返回 ApprovalRequired | 权限由 Manager 权威决定 |
| Tool Manager 拒绝调用 | 结构化 ToolResult error | 不执行 Tool |
| SessionSnapshot 提交失败 | Session 创建失败 | 不暴露不可恢复 Session |

## 16. 有意差异分类

| 设计项 | 分类 | 说明 |
|---|---|---|
| `ResolvedAgentRuntime` | 架构变更 | 当前 Java 在 Session.initialize 中临时解析 |
| 结构化 system 编译 | 架构变更 | 替代硬编码 Base 或本地 SYSTEM.md |
| Tool Manager 解析完整 tools 配置 | 架构变更 | Runtime 不解释 permission |
| Tool Manager 权威审批与执行 | 安全加固 | 防止 Runtime 或 UI 绕过权限 |
| `RuntimeToolSet + ToolCallDispatcher` | 架构变更 | 模型 Tool 清单与实际执行解耦 |
| Manager-backed AgentTool | 架构过渡 | 仅用于复用尚未改造的 AgentLoop 和 ToolExecutionPipeline |
| Anthropic Schema 无损传递 | 安全加固 | 防止调用约束在 Provider 边界被静默削弱 |
| Skill Manager Manifest | 架构变更 | 替代本地 Path 作为 Skill 身份 |
| Skill 正文按需激活 | 产品约束 | 控制基础上下文大小 |
| Tool 清单和 Skill 清单写入 system prompt | 产品约束 | 使模型可直接导航当前 Agent 的能力集合 |
| Tool Schema 只写入模型 `tools` 字段 | 产品约束 | 清单只包含 name 和 description，不复制完整 Schema |
| Tool 双通道共用 Descriptor 快照 | 安全加固 | 防止 prompt 清单与调用协议的 name 或 description 漂移 |
| 本地 SYSTEM.md 不覆盖 Managed system | 安全加固 | 防止 Agent 身份被工作目录替换 |
| Session 固定 Manager Manifest | 安全加固 | 防止恢复时静默升级 |

## 17. 建议实施顺序

### 阶段 1：稳定 Manager 契约

- 定义 `ToolManager.bindAgentTools()`、`invoke()`。
- 定义 Tool Manifest、Descriptor、InvocationResult。
- 定义 `SkillManager.bindAgentSkills()`、`activate()`。
- 定义 Skill Manifest、Descriptor、ActivatedSkill。
- 定义 Manifest 的版本和保留策略。

### 阶段 2：实现 Runtime 装配

- 实现 `compileStructuredSystem()`。
- 实现 `ResolvedAgentRuntime`。
- 实现 `AgentRuntimeAssembler` 和 Registry。
- 实现 Model Manager 映射。
- 实现 Runtime 和 Config 的 canonical hash。

### 阶段 3：适配 pi-mono-java

- 将模型可见 Tool 改为独立 `RuntimeToolSet`。
- 实现 `ToolCallDispatcher` 和 `ToolManagerToolCallDispatcher`。
- 改造 `AgentContext`、`AgentLoop` 和 Tool 结果事件链，使 tool call 直接转发到 Dispatcher。
- 修复 Anthropic Provider 对完整 `input_schema` 的传递，增加 Provider 兼容性检查。
- 如果需要分阶段交付，临时实现 `ManagerBackedAgentTool`。
- 为 `SystemPromptBuilder` 增加 managed 模式，由固定 Descriptor 渲染 Tool 清单和 Skill 清单。
- 将 Skill prompt 类型从本地 `Skill(Path)` 解耦。
- 实现 `load_skill` 或 Manager-backed SkillExpander。
- 增加 `AgentSessionFactory.createManaged()`。
- 将 `SessionPool` 从单一 baseConfig 扩展为按 Agent Runtime 创建 Session。
- 增加 SessionSnapshotV2。

### 阶段 4：验证

- Agent 配置到 Manager 请求的映射测试。
- Tool default/override 规则由 Tool Manager 解析的契约测试。
- permission 不进入 Runtime 的边界测试。
- Tool name/description/schema 到 `Context.tools` 和 Provider 请求的契约测试。
- system prompt Tool 清单与 `Context.tools` 的 name/description 一致性测试。
- 完整 Schema 经 Tool Manager、Runtime 和 Provider 后的归一化 hash 测试。
- ToolCallDispatcher 名称白名单、ToolManager.invoke 转发和结果转换测试。
- Skill name/description 到 system prompt 的映射测试。
- Skill 激活版本和 hash 测试。
- 多 Session 状态隔离测试。
- Session 驱逐、重启和固定 Manifest 恢复测试。
- 审批批准、拒绝、超时、取消和重放测试。

## 18. 待确认事项

1. Tool Manager 在审批时同步等待，还是返回 `ApprovalRequired` 并由 Session 状态机恢复。
2. `ToolCallDispatcher` 是采用同步、`CompletionStage` 还是 Reactor 接口。
3. Skill 激活采用 `load_skill` Tool，还是改造现有 `/skill:name`，或两者同时支持。
4. Managed 模式是否允许加载工作目录中的 `AGENTS.md/CLAUDE.md`。
5. Managed 模式是否完全禁用 `SYSTEM.md/APPEND_SYSTEM.md`。
6. Model Manager 是在 Runtime 装配时选定模型，还是在 Session 创建时根据凭据选择。
7. Tool/Skill Manifest 的保留期限是否至少覆盖所有关联 Session。
8. 现有本地 ToolCatalog 和 SkillLoader 是否作为 Manager 的一种本地后端继续保留。
9. Provider 不支持某个 JSON Schema 关键字时，是否允许经显式配置的有损降级。
10. `NATIVE_ONLY` 兼容模式是 Provider 级、Model 级还是 Agent 级配置。

## 19. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 0.4.0 | 2026-07-22 | 统一使用 Tool 清单和 Skill 清单；将目标抽象更名为 `RuntimeToolSet`；补充主流 Agent Tool 可见性调研；默认以同一 Descriptor 快照同时生成 system prompt Tool 清单和模型 `tools` 字段 |
| 0.3.0 | 2026-07-22 | 将 Tool 目标执行路径改为 `RuntimeToolCatalog + ToolCallDispatcher` 直接转发；明确 Schema 通过模型 `tools` 字段传递；将 `ManagerBackedAgentTool` 降级为过渡方案；记录 Anthropic Schema 完整性缺口 |
| 0.2.0 | 2026-07-22 | 重构为 Agent Runtime 优先；补充 pi-mono-java 当前加载链；定义独立 Tool/Skill Manager Manifest、Java 适配器、多 Session 创建和恢复 |
| 0.1.0 | 2026-07-22 | 首版；定义 Anthropic 基线、Agent 配置编译、外部工具管理、权限门禁、pi Session 创建与恢复 |
