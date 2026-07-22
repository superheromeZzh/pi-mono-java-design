# Managed Agent 配置到 pi-mono Session 的创建设计

| 属性 | 值 |
|---|---|
| 文档版本 | 0.1.0 |
| 状态 | Draft，供架构评审 |
| 源码基线 | `216e672e7c9fc65682553394b74e483c0c9e47f7` |
| 基线日期 | 2026-07-22 |
| 设计范围 | Agent 配置编译、外部工具解析、权限门禁、pi-mono Session 创建与恢复 |

## 1. 结论

Agent 配置应被视为版本化的控制面对象，Session 应被视为使用某一具体 Agent 版本创建的运行时对象。

创建 Session 时需要完成以下工作：

1. 读取并固定 Agent 的具体版本，而不是持续引用 `latest`。
2. 将结构化 `system` 配置按稳定顺序编译为 pi-mono 使用的单一 system prompt。
3. 将模型列表解析为本次 Session 的具体模型。
4. 将技能引用解析为具体版本和不可变内容。
5. 根据 `type + name` 向外部工具管理器解析工具 schema 和稳定 binding。
6. 将所有已解析工具转换为 pi-mono `customTools`。
7. 在工具执行适配器中实施 `always_allow` 或 `always_ask` 权限策略。
8. 调用 pi-mono `createAgentSession()` 创建 `AgentSession`。
9. 在向调用方返回前持久化不可变 `SessionSnapshot`。

本设计不要求 pi-mono 原生理解 MCP 或工具目录。`builtin-toolset` 和 `mcp-toolset` 均由 pi-mono 外部的工具管理器负责发现、描述和调用；pi-mono 只接收统一后的自定义工具定义。

## 2. 设计边界

本文使用以下标签区分事实和方案：

- **观察到的行为**：由 Anthropic 官方文档或当前 pi-mono 源码直接支持。
- **目标设计**：为满足当前 Agent 配置和外部工具管理要求而新增的适配层。
- **产品约束**：为保证行为明确而规定的产品语义。
- **安全加固**：为避免权限绕过、版本漂移或静默降级而增加的约束。
- **架构变更**：当前 pi-mono 不具备，需要在集成层新增的组件或持久化结构。

本文不设计工具管理器内部如何连接 MCP Server，也不修改 pi-mono 核心工具协议。工具管理器只需满足本文定义的解析与调用契约。

## 3. 源码和文档证据

### 3.1 Anthropic Managed Agents

基线参考：

- [Agent setup](https://platform.claude.com/docs/en/managed-agents/agent-setup)
- [Sessions](https://platform.claude.com/docs/en/managed-agents/sessions)
- [Environments](https://platform.claude.com/docs/en/managed-agents/environments)
- [Events and streaming](https://platform.claude.com/docs/en/managed-agents/events-and-streaming)
- [Permission policies](https://platform.claude.com/docs/en/managed-agents/permission-policies)
- [Skills](https://platform.claude.com/docs/en/managed-agents/skills)

观察到的关键语义：

- Agent 是版本化配置；修改 Agent 会产生新版本。
- Session 关联 Agent 和 Environment。
- Session 创建后处于空闲状态。
- `user.message` 事件启动或恢复 agent loop。
- agent loop 可以产生多轮模型调用、工具调用和事件。
- 一轮运行结束后 Session 回到空闲状态，而不是自动销毁。

### 3.2 pi-mono

| 源码 | 关键符号 | 观察到的行为 |
|---|---|---|
| [`packages/coding-agent/src/core/sdk.ts`](../../pi-mono/packages/coding-agent/src/core/sdk.ts#L33) | `CreateAgentSessionOptions`、`createAgentSession()` | 接受模型、`customTools`、`ResourceLoader`、`SessionManager` 等运行时输入 |
| [`packages/coding-agent/src/core/sdk.ts`](../../pi-mono/packages/coding-agent/src/core/sdk.ts#L289) | `new Agent(...)` | 将解析后的 system prompt、模型和工具传入核心 Agent |
| [`packages/coding-agent/src/core/agent-session.ts`](../../pi-mono/packages/coding-agent/src/core/agent-session.ts#L356) | `AgentSession` constructor | 保存自定义工具并管理 Session 生命周期 |
| [`packages/coding-agent/src/core/agent-session.ts`](../../pi-mono/packages/coding-agent/src/core/agent-session.ts#L452) | `tool_call` hook | 扩展可以在工具调用前检查或阻止调用 |
| [`packages/coding-agent/src/core/agent-session.ts`](../../pi-mono/packages/coding-agent/src/core/agent-session.ts#L2441) | custom tool adaptation | 将 `ToolDefinition` 转换为 Agent 可调用工具 |
| [`packages/coding-agent/src/core/system-prompt.ts`](../../pi-mono/packages/coding-agent/src/core/system-prompt.ts#L28) | `buildSystemPrompt()` | 组装 system prompt、工具说明、上下文和技能信息 |
| [`packages/coding-agent/src/core/skills.ts`](../../pi-mono/packages/coding-agent/src/core/skills.ts#L387) | `loadSkills()` | 从文件系统和配置位置发现技能 |
| [`packages/coding-agent/src/core/skills.ts`](../../pi-mono/packages/coding-agent/src/core/skills.ts#L335) | `formatSkillsForPrompt()` | 将可用技能格式化到 system prompt |
| [`packages/coding-agent/src/core/session-manager.ts`](../../pi-mono/packages/coding-agent/src/core/session-manager.ts#L1441) | `SessionManager.create()` | 创建持久化 Session 管理器 |
| [`packages/coding-agent/src/core/session-manager.ts`](../../pi-mono/packages/coding-agent/src/core/session-manager.ts#L946) | `_persist()` | 按 JSONL 追加 Session 条目 |
| [`packages/agent/src/agent-loop.ts`](../../pi-mono/packages/agent/src/agent-loop.ts#L413) | `executeToolCalls()` | 执行模型产生的工具调用；可并行处理多个工具调用 |
| [`packages/coding-agent/examples/extensions/permission-gate.ts`](../../pi-mono/packages/coding-agent/examples/extensions/permission-gate.ts#L13) | `tool_call` handler | 展示基于扩展 hook 的工具调用门禁 |
| [`packages/coding-agent/README.md`](../../pi-mono/packages/coding-agent/README.md#L492) | Philosophy | 当前核心不原生提供 MCP 和权限弹窗，建议由扩展或外部环境实现 |

因此，外部 Tool Manager、AgentConfig Compiler、Permission Broker 和 SessionSnapshot Store 都属于目标适配层，不能描述成 pi-mono 当前已有能力。

## 4. Anthropic Managed Agent 的基线流程

以下伪代码描述 `create agent` 之后创建 Session 的概念流程，不代表某一种语言 SDK 的精确方法签名：

```text
function createManagedAgentSession(agentInput, environmentInput):
    agent = ManagedAgentAPI.createAgent(agentInput)
    agentVersion = agent.version

    environment = ManagedAgentAPI.createEnvironment(environmentInput)

    session = ManagedAgentAPI.createSession({
        agent_id: agent.id,
        agent_version: agentVersion,
        environment_id: environment.id
    })

    assert session.status == "idle"
    return session

function runManagedAgentSession(sessionId, userMessage):
    ManagedAgentAPI.appendEvent(sessionId, {
        type: "user.message",
        content: userMessage
    })

    for event in ManagedAgentAPI.streamEvents(sessionId):
        handle(event)

    // Agent loop stops; the durable Session returns to idle.
```

![Anthropic Managed Agent 到 Session 的基线生命周期](anthropic_managed_lifecycle.svg)

[PlantUML 源码](diagram.puml#L6)

### 4.1 与当前自定义 Agent 配置的差异

| 维度 | Anthropic 当前公开模型 | 本文目标配置 |
|---|---|---|
| `system` | 一个 system 字符串 | `role`、`objective`、`instructions` 等结构化字段 |
| `model` | 一个具体模型 | 有序模型数组 |
| 工具 | Anthropic Managed Agents 自己的工具和 MCP 配置 | 只声明工具类型和名称，由外部工具管理器解析 |
| 权限 | Managed Agents 的 permission policy | Agent 级默认值和逐工具覆盖 |
| 技能 | Managed Agent skill 引用 | `skill_id` 和可选固定版本 |
| 运行环境 | 显式 Environment | 由集成服务的请求上下文和运行环境配置提供 |

这些差异属于目标产品模型，不应通过猜测 Anthropic 内部实现来弥合。

## 5. Agent 配置的运行时解释

### 5.1 输入配置结构

本文设计针对以下 Agent 配置结构：

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

`tools[].type` 可取 `builtin-toolset` 或 `mcp-toolset`。两种类型在 Session Factory 中执行同一套配置合并逻辑，只是路由到不同的外部工具管理器。

### 5.2 控制面字段

以下字段只用于版本控制、路由、授权或审计，默认不直接进入模型上下文：

- `id`
- `type`
- `version`
- `created_at`
- `updated_at`
- `name`
- `display_name`
- `description`
- `use_cases`
- `metadata`

`use_cases` 用于 Agent 选择或意图路由。`metadata.environment` 和 `metadata.owner_id` 用于部署环境选择和授权。除非产品明确要求，否则这些字段不拼接到 system prompt。

### 5.3 system prompt 编译顺序

结构化 `system` 按以下固定顺序编译：

1. `role`
2. `objective`
3. `instructions`
4. `tool_policy`
5. `safety`
6. `completion`
7. `response_style`
8. `example`

```text
function compileSystem(system):
    sections = [
        ("Role", system.role),
        ("Objective", system.objective),
        ("Instructions", system.instructions),
        ("Tool Policy", system.tool_policy),
        ("Safety", system.safety),
        ("Completion", system.completion),
        ("Response Style", system.response_style),
        ("Example", system.example)
    ]

    return joinWithStableHeadings(removeEmpty(sections))
```

编译结果作为自定义 `ResourceLoader` 的 system prompt override。技能列表、上下文文件和工具说明继续由 pi-mono 已有 `buildSystemPrompt()` 流程拼接。

### 5.4 模型数组

**产品约束：** `model` 是按优先级排序的候选列表。

创建 Session 时：

1. 按配置顺序解析模型。
2. 选择第一个存在且具备有效认证的模型。
3. 在快照中同时记录候选列表和 `selected_model`。
4. Session 恢复时必须重新取得原 `selected_model`；不得静默切换到下一个候选模型。

模型迁移必须是显式操作，并产生新的 Session 快照或新 Session。

### 5.5 技能引用

pi-mono 当前按文件路径发现技能，并不原生理解 `skill_id + version`。因此需要外部 Skill Manager：

```text
function resolveSkills(skillRefs):
    result = []

    for ref in skillRefs:
        version = ref.version ?? SkillManager.latestVersion(ref.skill_id)
        artifact = SkillManager.get(ref.skill_id, version)

        result.append({
            pi_skill: toPiSkill(artifact),
            snapshot: {
                skill_id: ref.skill_id,
                version: artifact.version,
                content_hash: sha256(artifact.content)
            }
        })

    return result
```

省略版本只表示“在 Session 创建时解析最新版本”。解析完成后必须固定具体版本，后续恢复不能再次解释为最新版本。

## 6. 外部工具管理器

### 6.1 架构

![外部工具管理器与 pi-mono 的目标集成架构](external_tool_manager_architecture.svg)

[PlantUML 源码](diagram.puml#L46)

该架构包含三个平面：

- **Agent control plane**：保存版本化 Agent 配置和权限策略。
- **External tool plane**：根据工具类型和名称提供 schema、binding 和实际调用能力。
- **pi-mono runtime**：只接收统一 `customTools`，执行模型循环和 Session 消息持久化。

### 6.2 工具管理器契约

```text
type ToolsetType = "builtin-toolset" | "mcp-toolset"

record ToolKey:
    type: ToolsetType
    name: string

record ResolvedToolBinding:
    key: ToolKey
    model_tool_name: string
    description: string
    input_schema: JsonSchema
    binding_id: string
    descriptor_version: string
    schema_hash: string

interface ToolManager:
    resolve(type, name) -> ResolvedToolBinding
    invoke(binding_id, arguments, execution_context) -> ToolResult
```

`list(type)` 可以作为管理面能力存在，但 Session 创建的必要契约只有 `resolve` 和 `invoke`。

### 6.3 名称约束

- 工具目录的稳定主键是 `(type, name)`。
- 传给模型的 `model_tool_name` 在一个 Session 内必须全局唯一。
- 如果 `builtin-toolset` 和 `mcp-toolset` 解析出相同 `model_tool_name`，Session 创建失败。
- 本版本不自动增加前缀或重命名工具，因为静默改名会改变模型可见协议。

未来如果需要别名，必须在 Agent 配置中显式增加 `alias` 字段。

### 6.4 默认配置与逐工具覆盖

```text
function effectiveTools(toolsets):
    result = []
    seenModelNames = set()

    for toolset in toolsets:
        for item in toolset.configs:
            enabled = item.enabled ?? toolset.default_config.enabled
            permission = item.permission ?? toolset.default_config.permission

            if not enabled:
                continue

            binding = ToolManager.resolve(toolset.type, item.name)
            validateSchema(binding.input_schema)

            if binding.model_tool_name in seenModelNames:
                fail("DUPLICATE_MODEL_TOOL_NAME")

            seenModelNames.add(binding.model_tool_name)
            result.append({ binding, permission })

    return result
```

尽管当前配置中逐工具字段是必填的，解析器仍应实现明确的覆盖语义，便于未来允许省略字段。安全默认值是 `always_ask`；如果默认配置和逐工具配置都没有权限值，则配置校验失败。

### 6.5 转换为 pi customTools

```text
function toPiTool(binding, permission, sessionContext):
    return defineTool({
        name: binding.model_tool_name,
        description: binding.description,
        parameters: convertJsonSchemaToPiSchema(binding.input_schema),

        execute: async (toolCallId, arguments, signal) =>:
            validateAgainstSnapshotSchema(arguments)

            decision = await PermissionBroker.authorize({
                session_id: sessionContext.session_id,
                run_id: sessionContext.run_id,
                tool_call_id: toolCallId,
                binding_id: binding.binding_id,
                args_hash: canonicalHash(arguments),
                permission: permission,
                signal: signal
            })

            if decision != "allow":
                return structuredDeniedToolResult(decision)

            return ToolManager.invoke(
                binding.binding_id,
                arguments,
                sessionContext.execution_context
            )
    })
```

工具适配器的 `execute` 是权限实施的权威边界。pi-mono `tool_call` 扩展 hook 可以用于 UI 展示或二次保护，但不能成为唯一的服务端授权点。

## 7. 权限门禁

### 7.1 `always_allow`

1. 校验调用参数和快照 binding。
2. 写入调用审计记录。
3. 调用 `ToolManager.invoke()`。
4. 将结果转换为 pi `ToolResult`。

### 7.2 `always_ask`

1. 创建持久化 `pending approval`。
2. 记录 `session_id`、`run_id`、`tool_call_id`、`binding_id` 和 `args_hash`。
3. 暂停当前工具调用，等待审批结果。
4. 批准后重新校验调用参数哈希和 Session 快照。
5. 拒绝、超时、取消或审批存储不可用时返回结构化错误，不调用工具。

### 7.3 并行工具调用

pi agent loop 可以并行执行多个工具调用，因此 Permission Broker 必须：

- 以 `tool_call_id` 区分多个并发审批。
- 不使用 Session 级单一布尔锁表示审批状态。
- 支持某个调用被批准、另一个调用被拒绝。
- 在 Session abort 时取消所有仍未决的审批等待。

### 7.4 安全要求

- UI 返回的审批决定只是输入，服务端适配器负责最终校验。
- 审批记录必须绑定参数哈希，防止批准后替换参数。
- 恢复 Session 时未决审批必须重新验证，不能自动继承旧进程内存状态。
- 工具 binding 不可用时不能按名称重新解析最新 binding 后继续调用。
- 审批和审计存储失败时采用 fail-closed。

## 8. 基于 Agent 配置创建 pi-mono Session

### 8.1 时序

![基于修改后 Agent 配置创建 pi-mono Session](pi_session_creation.svg)

[PlantUML 源码](diagram.puml#L96)

### 8.2 主流程伪代码

```text
function createPiSession(agentId, requestedVersion, requestContext):
    // 1. Read and pin the control-plane object.
    config = AgentRepository.getExact(agentId, requestedVersion)
    validateAgentConfig(config)

    configHash = canonicalHash(config)

    // 2. Resolve all dynamic dependencies before creating AgentSession.
    modelResolution = resolveModels(config.model)
    compiledSystem = compileSystem(config.system)
    skillResolution = resolveSkills(config.skills)
    toolResolution = effectiveTools(config.tools)

    // 3. Create the external durable identity first.
    sessionId = SessionStore.reserveId()
    approvalScope = PermissionBroker.createScope(sessionId)

    customTools = []
    for resolvedTool in toolResolution:
        customTools.append(
            toPiTool(
                resolvedTool.binding,
                resolvedTool.permission,
                {
                    session_id: sessionId,
                    approval_scope: approvalScope,
                    execution_context: requestContext.tool_execution_context
                }
            )
        )

    // 4. Supply exact prompt and skills through ResourceLoader.
    resourceLoader = buildResourceLoader({
        system_prompt: compiledSystem,
        skills: skillResolution.pi_skills,
        cwd: requestContext.cwd
    })

    piSessionManager = SessionManager.create(
        requestContext.cwd,
        requestContext.pi_session_dir
    )

    // 5. Call the existing pi SDK entry point.
    result = createAgentSession({
        cwd: requestContext.cwd,
        model: modelResolution.selected_model,
        scopedModels: modelResolution.scoped_models,
        customTools: customTools,
        resourceLoader: resourceLoader,
        sessionManager: piSessionManager,
        modelRuntime: requestContext.model_runtime,
        settingsManager: requestContext.settings_manager
    })

    snapshot = buildSessionSnapshot({
        session_id: sessionId,
        pi_session_id: result.session.sessionId,
        agent_config: config,
        config_hash: configHash,
        compiled_system: compiledSystem,
        model_resolution: modelResolution,
        skill_resolution: skillResolution,
        tool_resolution: toolResolution,
        request_context: requestContext
    })

    // 6. Do not expose the Session until the snapshot is durable.
    SessionStore.commit(snapshot)

    return {
        session_id: sessionId,
        agent_id: config.id,
        agent_version: config.version,
        selected_model: modelResolution.selected_model.id,
        status: "idle",
        pi_session: result.session
    }
```

`createAgentSession()` 本身不会触发模型运行。调用方后续执行 `session.prompt(...)` 才开始 pi agent loop，这与 Anthropic “Session 先创建为空闲状态，消息再启动执行”的语义保持一致。

### 8.3 ResourceLoader 构建

```text
function buildResourceLoader(input):
    loader = DefaultResourceLoader({
        cwd: input.cwd,

        systemPromptOverride: () => input.system_prompt,

        skillsOverride: (current) => ({
            skills: input.skills,
            diagnostics: current.diagnostics
        })
    })

    loader.reload()
    return loader
```

生产实现需要避免重新发现未固定的项目技能。可以关闭默认技能发现，或在 override 中完全替换技能列表，而不是追加到 `current.skills`。

## 9. SessionSnapshot

pi `SessionManager` 负责消息树、模型切换、压缩和自定义条目。它不负责 Agent 配置版本、外部 tool binding 或审批状态。因此目标设计增加独立 `SessionStore`。

```text
record SessionSnapshotV1:
    snapshot_version: 1
    session_id: string
    pi_session_id: string
    created_at: timestamp

    agent_id: string
    agent_version: integer
    config_hash: string
    compiled_system_hash: string

    model_candidates: list<string>
    selected_model: string

    skills: list<{
        skill_id: string,
        version: string,
        content_hash: string
    }>

    tools: list<{
        type: ToolsetType,
        configured_name: string,
        model_tool_name: string,
        binding_id: string,
        descriptor_version: string,
        schema_hash: string,
        permission: "always_allow" | "always_ask"
    }>

    environment: string
    owner_id: string
```

### 9.1 持久化要求

- `SessionSnapshot` 必须在 Session 返回给调用方之前持久化。
- 快照提交失败时，创建流程失败并释放未暴露的 `AgentSession`。
- pi Session JSONL 可以写入一个镜像 custom entry 便于排查，但外部 `SessionStore` 是恢复时的权威来源。
- 快照内容使用稳定 canonical serialization 计算哈希。
- 快照版本独立于 pi Session JSONL 的格式版本。

## 10. Session 恢复

```text
function restorePiSession(sessionId, requestContext):
    snapshot = SessionStore.get(sessionId)

    config = AgentRepository.getExact(
        snapshot.agent_id,
        snapshot.agent_version
    )
    require canonicalHash(config) == snapshot.config_hash

    model = ModelResolver.getExact(snapshot.selected_model)

    skills = []
    for pinnedSkill in snapshot.skills:
        skill = SkillManager.get(pinnedSkill.skill_id, pinnedSkill.version)
        require sha256(skill.content) == pinnedSkill.content_hash
        skills.append(skill)

    tools = []
    for pinnedTool in snapshot.tools:
        binding = ToolManager.resolve(
            pinnedTool.type,
            pinnedTool.configured_name
        )
        require binding.binding_id == pinnedTool.binding_id
        require binding.descriptor_version == pinnedTool.descriptor_version
        require binding.schema_hash == pinnedTool.schema_hash
        tools.append(binding)

    piSessionManager = SessionManager.open(
        lookupPiSessionFile(snapshot.pi_session_id)
    )

    return createAgentSession({
        model: model,
        customTools: adaptPinnedTools(tools, snapshot.tools),
        resourceLoader: buildPinnedResourceLoader(config, skills),
        sessionManager: piSessionManager,
        modelRuntime: requestContext.model_runtime,
        settingsManager: requestContext.settings_manager
    })
```

恢复流程必须在调用 pi `createAgentSession()` 之前完成依赖验证，从而避免 pi 自身的模型 fallback 或默认资源发现改变 Session 行为。

## 11. 失败处理

| 场景 | 创建或恢复结果 | 原因 |
|---|---|---|
| Agent 版本不存在 | 失败 | 不能使用最新版本替代 |
| Agent config hash 不匹配 | 失败 | 相同版本内容被非法修改 |
| 没有可用模型 | 创建失败 | 无法建立可执行运行时 |
| 固定模型在恢复时不可用 | 恢复失败 | 禁止静默模型迁移 |
| 技能版本不存在或 hash 不匹配 | 失败 | 技能会改变模型行为 |
| 工具 schema 无法转换为 pi schema | 创建失败 | 模型工具协议不完整 |
| 工具模型名称冲突 | 创建失败 | 模型无法稳定寻址工具 |
| binding 或 schema 在恢复时漂移 | 恢复失败 | 禁止按名称静默升级 |
| `always_ask` 审批存储不可用 | 工具调用失败 | fail-closed |
| SessionSnapshot 提交失败 | 创建失败 | 不暴露不可恢复 Session |
| 工具运行时临时失败 | 返回结构化 ToolResult error | 保留同一 binding，不自动重解析 |

## 12. 有意差异分类

| 设计项 | 分类 | 说明 |
|---|---|---|
| 结构化 `system` 编译 | 架构变更 | pi 最终仍接收一个 system prompt 字符串 |
| 有序模型数组选取一个模型 | 产品约束 | 保持配置简洁并产生明确运行时选择 |
| Session 恢复禁止模型 fallback | 安全加固 | 防止行为和权限边界静默改变 |
| 外部 Tool Manager | 架构变更 | pi 核心当前不原生管理 MCP |
| `(type, name)` 作为工具目录主键 | 产品约束 | 允许 builtin 和 MCP 使用各自名称空间 |
| 模型可见工具名必须全局唯一 | 产品约束 | pi agent loop 按工具名查找工具 |
| binding、descriptor 和 schema hash 固定 | 安全加固 | 防止恢复时供应链漂移 |
| 权限在 custom tool adapter 中实施 | 安全加固 | 避免仅依赖 UI 或扩展 hook |
| 独立 SessionStore | 架构变更 | pi Session JSONL 不包含目标控制面快照 |
| 未指定技能版本时在创建时解析 latest | 产品约束 | 兼顾配置便利性和 Session 可恢复性 |

## 13. 建议实施顺序

### 阶段 1：稳定外部契约

- 定义 Tool Manager `resolve()` 和 `invoke()`。
- 定义 `ResolvedToolBinding` 和 schema hash 算法。
- 定义 Skill Manager 具体版本解析。
- 定义模型数组选择规则。
- 定义 canonical config hash。

### 阶段 2：实现 pi 适配层

- 实现 system prompt compiler。
- 实现 JSON Schema 到 pi tool schema 的转换。
- 实现 `customTools` adapter。
- 实现 Permission Broker 和审批持久化。
- 实现精确技能 `ResourceLoader`。
- 实现 SessionSnapshot Store。
- 实现 `createPiSession()` 和 `restorePiSession()`。

### 阶段 3：验证

- Agent 版本固定和 config hash 漂移测试。
- 工具名称冲突测试。
- binding、descriptor 和 schema 漂移测试。
- 多个并行 `always_ask` 调用测试。
- 审批拒绝、超时、取消和恢复测试。
- 固定模型不可用测试。
- 技能版本和内容 hash 漂移测试。
- pi Session JSONL 恢复与外部快照一致性测试。

## 14. 待确认事项

1. `model` 数组是否只表示创建时的优先级，还是允许运行中的自动 fallback。本文建议只用于创建时选择。
2. 工具管理器能否保证 `binding_id` 和 `descriptor_version` 在 Session 生命周期内可重新取得。
3. 工具 schema 的标准格式是否严格限定为 pi 可转换的 JSON Schema 子集。
4. SessionSnapshot 使用独立数据库，还是与现有平台 Session 表合并。
5. `always_ask` 的审批 UI 由 pi 扩展、平台 Web UI，还是独立审批服务提供。
6. 是否允许显式工具别名，以处理不同 toolset 的模型工具名冲突。

## 15. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 0.1.0 | 2026-07-22 | 首版；定义 Anthropic 基线、Agent 配置编译、外部工具管理、权限门禁、pi Session 创建与恢复 |
