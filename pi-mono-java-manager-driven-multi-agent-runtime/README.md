# pi-mono-java Manager 驱动的多 Agent 运行设计

| 属性 | 值 |
|---|---|
| 文档版本 | 1.0.0 |
| 状态 | 目标设计，尚未实施 |
| 更新日期 | 2026-07-29 |
| pi-mono 源码基线 | `fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc` |
| pi-mono-java 源码基线 | `1f7a5423219edfa4519d8719f1cc8a188ed72873` |
| 运行形态 | 单 JVM、多 Agent、WebSocket 会话 |

## 1. 结论

本设计使用一个目录编译程序，把 AGENT、SKILL、TOOL 元数据投影为
pi-mono-java 可以直接读取的 Agent 运行目录。目录只承担 Prompt 和 Skill
渐进式披露，不承担模型、工具或权限的运行时权威。

每个 WebSocket 会话携带 `agent_id`。服务端从受控根目录解析 Agent cwd，
创建该 Agent 独立的 `AgentSession` 和 `Agent`。模型由 Model Manager 调用，
业务工具由 Tool Manager 发现和执行。

模型实际可执行的工具固定为：

```text
read
get_tool_info
call_tool
```

真实业务工具不注册为 `AgentTool`。Agent 直接绑定的工具摘要进入
`SYSTEM.md`；Skill 绑定的工具摘要进入该 Skill 的
`references/tools.json`。模型先看到逻辑工具的 `tool_id`，再通过
`get_tool_info` 取得当前 Schema，通过 `call_tool` 执行。

最终运行目录为：

```text
<agent-runtime-root>/
└── <agent-id>/
    └── .campusclaw/
        ├── SYSTEM.md
        └── skills/
            └── <skill-name>/
                ├── SKILL.md
                └── references/
                    └── tools.json

<user-agent-dir>/
└── sessions/
    └── <agent-id>/
        └── <conversation-id>.jsonl
```

`references/tools.json` 只在 Skill 存在直接有效 `binding_tools` 时生成。

## 2. 范围与设计分类

本文覆盖：

- 三类元数据到 Agent 运行目录的确定性映射；
- Agent cwd、Session 隔离和 WebSocket 握手；
- Managed Prompt 与 pi-mono-java `Context` 的组装；
- Tool Manager 的逻辑工具发现和执行；
- Model Manager Provider 的模型选择和流式事件适配；
- 单 JVM 内多个 Agent 的隔离边界；
- 对 pi-mono-java 的目标适配点和验收要求。

本文不实现：

- pi-mono-java Java 代码；
- 元数据管理服务；
- Tool Manager 或 Model Manager；
- WebSocket 客户端；
- 数据库表和管理界面。

文中使用以下分类：

| 分类 | 含义 |
|---|---|
| 观察到的行为 | 已由指定源码基线确认的 pi 或 pi-mono-java 行为 |
| 目标设计 | 本文定义、当前 Java 尚未实现的行为 |
| 产品约束 | 单 JVM、多 Agent、Manager 权威和固定通用工具等产品选择 |
| 安全加固 | 服务端 cwd、路径约束、每次调用重新鉴权等加强措施 |
| 架构改造 | 新增目录编译器、Managed Session Factory 或 Manager Provider |

## 3. 源码基线与事实

### 3.1 pi-mono

源码仓库：

```text
repository: https://github.com/badlogic/pi-mono
commit:     fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc
```

| 主题 | 源码证据 | 观察到的行为 |
|---|---|---|
| LLM Context | [`packages/ai/src/types.ts#L448-L458`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/ai/src/types.ts#L448-L458) `Tool`、`Context` | `systemPrompt`、`messages`、`tools` 是分离字段；Tool 包含 name、description、parameters |
| 自定义 SYSTEM | [`packages/coding-agent/src/core/system-prompt.ts#L28-L71`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/system-prompt.ts#L28-L71) `buildSystemPrompt()` | custom prompt 替换默认主体，之后仍组装上下文、Skill 和 cwd |
| Skill 摘要 | [`packages/coding-agent/src/core/skills.ts#L335-L360`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/skills.ts#L335-L360) `formatSkillsForPrompt()` | Prompt 只披露 Skill 的 name、description、location，并要求使用 read 加载文件 |
| Skill 文件 | [`packages/coding-agent/src/core/skills.ts#L277-L319`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/skills.ts#L277-L319) `loadSkillFromFile()` | 从 `SKILL.md` frontmatter 读取 name 和 description，正文不直接进入初始 Prompt |
| 显式 Skill 调用 | [`packages/coding-agent/src/core/agent-session.ts#L1296-L1325`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/agent-session.ts#L1296-L1325) `_expandSkillCommand()` | `/skill:name` 读取 Skill 文件正文并加入当前会话 |
| Tool 注册 | [`packages/coding-agent/src/core/agent-session.ts#L2458-L2491`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/agent-session.ts#L2458-L2491) `_refreshToolRegistry()` | 内置、Extension 和 SDK Tool 最终形成真实可执行 Tool Registry |

pi 的这些行为是本设计保留“Context 分层”和“Skill 渐进式加载”的依据。
Tool Manager 代理模式属于架构改造，不是 pi 已有的动态逻辑工具协议。

### 3.2 pi-mono-java

源码仓库：

```text
repository: https://github.com/superheromeZzh/pi-mono-java
commit:     1f7a5423219edfa4519d8719f1cc8a188ed72873
```

| 主题 | 源码证据 | 观察到的行为 |
|---|---|---|
| Session 初始化 | [`AgentSession.java#L114-L161`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/session/AgentSession.java#L114-L161) `initialize()` | 当前 Session 解析 Model、加载 Tool/Skill/上下文文件、构建 Prompt，再创建 Agent |
| SYSTEM 位置 | [`ContextFileLoader.java#L84-L103`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/context/ContextFileLoader.java#L84-L103) `loadSystemPrompt()` | 优先读取 `<cwd>/.campusclaw/SYSTEM.md` |
| 项目 Skill | [`AgentSession.java#L545-L560`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/session/AgentSession.java#L545-L560) `loadSkills()` | 从 `<cwd>/.campusclaw/skills` 加载项目 Skill |
| Prompt 组装 | [`SystemPromptBuilder.java#L59-L125`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/prompt/SystemPromptBuilder.java#L59-L125) `build()` | SYSTEM override 后继续追加真实 Tool、Skill、上下文、默认文档和环境信息 |
| Skill 摘要 | [`SkillPromptFormatter.java#L24-L49`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/skill/SkillPromptFormatter.java#L24-L49) `format()` | 把 name、description、location 放入 Prompt，并要求使用 read |
| AgentTool | [`AgentTool.java#L17-L37`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/agent-core/src/main/java/com/campusclaw/agent/tool/AgentTool.java#L17-L37) `AgentTool` | Tool 同时包含模型描述、Schema 和本地 execute |
| LLM Tool 投影 | [`AgentLoop.java#L209-L219`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/agent-core/src/main/java/com/campusclaw/agent/loop/AgentLoop.java#L209-L219) `invokeModel()`、[`AgentLoop.java#L312-L320`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/agent-core/src/main/java/com/campusclaw/agent/loop/AgentLoop.java#L312-L320) `toLlmTools()` | 每轮把 AgentTool 转为 name、description、parameters，再与 systemPrompt、messages 组成 Context |
| 当前 SessionPool | [`SessionPool.java#L61-L69`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/SessionPool.java#L61-L69)、[`SessionPool.java#L176-L202`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/SessionPool.java#L176-L202) | 当前只有一个 baseConfig/serverCwd，并按 conversation ID 保存内存 Session |
| 当前 JSONL 路径 | [`SessionPool.java#L345-L377`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/SessionPool.java#L345-L377) | 当前按进程 cwd 编码 Session 目录 |
| WebSocket 握手 | [`ServerMode.java#L377-L391`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ServerMode.java#L377-L391) | 当前只提取 `conversation_id` |
| Provider 扩展点 | [`ApiProvider.java#L31-L59`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/provider/ApiProvider.java#L31-L59)、[`ApiProviderRegistry.java#L54-L80`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/provider/ApiProviderRegistry.java#L54-L80) | Spring 可发现统一 ApiProvider，并按 `Api` 分发 |
| 调用元数据 | [`SimpleStreamOptions.java#L34-L45`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/types/SimpleStreamOptions.java#L34-L45) | 每次模型调用已有任意 metadata 字段可承载 Session 身份 |
| 模型流事件 | [`AssistantMessageEvent.java#L44-L164`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/stream/AssistantMessageEvent.java#L44-L164) | 已定义 start、text、thinking、toolcall、done、error 事件 |

## 4. 目标组件与权威边界

| 组件 | 权威数据 | 主要职责 |
|---|---|---|
| Agent 元数据服务 | Agent 定义、models、Skill/Tool 绑定和 Agent 权限 | 为目录编译、模型授权和工具授权提供 Agent 视角 |
| Skill 元数据或制品服务 | Skill 版本、name、description、content 或完整 `SKILL.md` | 提供可物化的 Skill 文档 |
| Tool Manager | Tool 描述、Schema、状态、source、permission、执行实现 | 发现、授权、校验并执行逻辑工具 |
| Model Manager | Model descriptor、状态、实际 Provider 路由和模型调用 | 校验 Agent-model 绑定并流式执行 |
| Runtime bundle compiler | 固定版本、展开依赖、验证并生成 Agent 目录 | 把元数据投影为 pi-mono-java 资源 |
| AgentDirectoryResolver | `agent_id` 到受控 cwd 的映射 | 阻止客户端选择任意工作目录 |
| ManagedAgentSessionFactory | 当前 Agent 的 Prompt、Skill、Model、Tool 和 Session 装配 | 每个 Session 创建独立 Agent |
| ManagedSessionPool | `(agent_id, conversation_id)` 到 Session 的映射 | 内存隔离、恢复和淘汰 |
| 用户级 Session Store | JSONL 消息和模型变更 | 持久化会话，不保存 Agent 定义 |

运行目录是 Manager 数据的模型披露投影，不是授权数据库。目录中的
`tool_id` 只告诉模型“可能使用什么”；Tool Manager 仍在每次发现和执行时
读取当前 Agent 绑定与权限。

![元数据到 Agent 运行目录映射](metadata_runtime_directory_mapping.svg)

[PlantUML 源码](diagram.puml#L1)

## 5. 元数据到运行目录映射

### 5.1 总体映射

| 元数据字段 | 运行目录或运行时目标 | 消费者 | 规则 |
|---|---|---|---|
| `AGENT.id` | `<agent-runtime-root>/<agent-id>` | AgentDirectoryResolver、Manager、SessionPool | 作为不透明 ID；目录解析必须限制在受控根目录 |
| `AGENT.version` | 发布校验与审计 | Runtime bundle compiler、元数据服务 | 部署时固定；目录层级不增加版本目录 |
| `AGENT.enabled` | 发布与建 Session 校验 | 编译器、ManagedSessionPool | 非启用 Agent 不发布或拒绝建 Session |
| `AGENT.system_prompt` | `.campusclaw/SYSTEM.md` 的 `<agent_instructions>` | SystemPromptBuilder | 按固定字段顺序渲染 |
| `AGENT.models` | Agent 模型允许集合 | Model Manager | 不投影为本地文件；每次选择和调用重新校验 |
| `AGENT.binding_tools` | SYSTEM 的 `<agent_tools>` | 模型 | 只写 Agent 直接绑定的 tool_id、name、description |
| `AGENT.binding_skills` | `.campusclaw/skills/<skill-name>` 集合 | SkillLoader、模型 | 展开完整 Skill 依赖闭包并逐个物化 |
| `AGENT.permission` | Agent Tool 策略 | Tool Manager | 参与发布校验和运行时最终授权 |
| `SKILL.id/version/enabled` | Skill 解析和发布校验 | 编译器、元数据服务 | 固定版本、启用检查和冲突检查 |
| `SKILL.name` | Skill 目录名和 `SKILL.md` frontmatter | SkillLoader、SkillPromptFormatter | 当前 Agent 内唯一，且必须是安全单路径段 |
| `SKILL.description` | `SKILL.md` frontmatter | SkillLoader、模型 | 初始 Prompt 只披露该摘要 |
| `SKILL.content` | `SKILL.md` 正文 | read | 使用 Markdown 正文输入模式时原样保留 |
| 完整 `SKILL.md` 制品 | 规范化后的 `SKILL.md` | 编译器、read | 与结构化输入二选一；frontmatter 必须匹配元数据 |
| `SKILL.binding_tools` | `references/tools.json` | read、模型 | 只写该 Skill 的直接有效 Tool |
| `SKILL.binding_skills` | 子 Skill 目录 | SkillLoader、模型 | 递归物化，子 Skill Tool 不合并到父文件 |
| `SKILL.permission` | Skill Tool 策略 | Tool Manager | 与 Agent、Tool 权限共同决定最终授权 |
| `TOOL.id/name/description` | SYSTEM 或 `references/tools.json` 摘要 | 模型 | 按绑定所属层投影 |
| `TOOL.input_schema/output_schema` | `get_tool_info` 结果 | Tool Manager、模型 | 使用时按 tool_id 获取当前值 |
| `TOOL.source/permission/enabled` | Tool Manager | Tool Manager | 不进入 Prompt 投影 |
| created/updated/display/use_cases | 管理面、路由或审计 | 管理服务 | 不参与本地 Context 组装 |

### 5.2 路径解析

`agent_id` 和 `skill.name` 均按不透明标识处理，不把其内容解释为路径。
Resolver 和编译器至少执行：

1. 拒绝空值、NUL、`/`、`\`、`.` 和 `..`；
2. 确保标识只形成一个路径段；
3. 对目标路径规范化，并验证仍位于配置的根目录内；
4. 拒绝指向根目录外的符号链接；
5. 使用受控根目录内的临时同级目录生成；
6. 全量校验成功后原子替换 `<agent-id>` 目录。

WebSocket 不接收 cwd。服务端只执行：

```text
agentCwd = AgentDirectoryResolver.resolve(agent_id)
```

并验证：

```text
<agentCwd>/.campusclaw/SYSTEM.md
<agentCwd>/.campusclaw/skills/
```

### 5.3 `SYSTEM.md`

编译器按固定结构生成：

```markdown
<agent_instructions>

# Role

...

# Objective

...

# Instructions

...

# Tool Policy

...

# Safety

...

# Completion

...

# Response Style

...

# Example

...

</agent_instructions>

<agent_tools>

- tool_id: order-query
  name: query_order
  description: 查询订单详细信息

</agent_tools>
```

`<agent_instructions>` 内按以下顺序渲染非空字段：

```text
role
objective
instructions
tool_policy
safety
completion
response_style
example
```

`<agent_tools>` 只包含 `AGENT.binding_tools` 的直接绑定。Skill 的工具不提前
放入此处，否则 Skill 工具会失去渐进式披露边界。

Tool 摘要从固定版本 TOOL 元数据解析。以下情况拒绝发布：

- Tool 不存在；
- Tool 未启用；
- 绑定版本冲突；
- 权限解析结果为 deny；
- 同一 Agent 的两个直接绑定解析出冲突的 tool_id；
- name 或 description 缺失。

### 5.4 `SKILL.md`

编译器接受两种互斥输入。

结构化输入：

```text
SKILL.name
SKILL.description
SKILL.content
```

生成：

```markdown
---
name: refund-handling
description: 判断退款条件并指导退款流程
---

<content 原文>
```

完整制品输入：

```text
SkillDocumentArtifact(skill_id, version, SKILL.md)
```

编译器解析制品 frontmatter，校验 name、description 与元数据一致，再使用
同一规范化流程重写 frontmatter 和正文。一次输入必须且只能选择一种模式；
两种模式同时存在或同时缺失均拒绝发布。

若 Skill 存在直接有效 `binding_tools`，编译器在正文末尾追加一次标准说明：

```markdown
## Managed tool resources

When this skill needs an external operation, read `references/tools.json`
to discover its logical tools. Follow the `get_tool_info` and `call_tool`
tool descriptions for discovery and execution.
```

Skill 自有正文不得预先包含同名保留章节，避免不同输入模式产生重复协议。

### 5.5 `references/tools.json`

格式固定为：

```json
{
  "tools": [
    {
      "tool_id": "order-query",
      "name": "query_order",
      "description": "查询订单信息"
    }
  ]
}
```

规则：

- 只包含当前 Skill 的直接 `binding_tools`；
- 不包含 `binding_skills` 所绑定 Skill 的工具；
- 不包含版本、Schema、source、permission 或 Manager 连接信息；
- 按 `tool_id` 排序，确保同一输入得到相同文件；
- `binding_tools` 为空时不生成 `references` 目录；
- 缺失、未启用、版本冲突或有效权限为 deny 时拒绝发布。

`references/tools.json` 是信息披露索引，不是 Tool 激活状态。读取该文件不会
修改 Runtime 权限，Tool Manager 也不依赖“已读取”状态。

### 5.6 Skill 依赖闭包

从 `AGENT.binding_skills` 开始递归展开：

```text
AGENT.binding_skills
  -> SKILL.binding_skills
     -> SKILL.binding_skills
```

编译器固定所有省略的版本，检查：

- 循环依赖；
- 同一 Skill ID 解析到多个版本；
- Skill name 冲突；
- 缺失或未启用 Skill；
- content/制品输入不完整；
- frontmatter 不一致；
- Tool 绑定无效。

每个 Skill 独立生成自己的 `SKILL.md` 和直接工具索引，不把父子 Skill
合成一个文件。

## 6. Managed Context 组装

### 6.1 最终 Context

pi-mono-java 每次模型调用仍使用原生 `Context`：

```text
Context
  systemPrompt
  messages
  tools
```

Managed 模式下：

```text
systemPrompt
  = Agent SYSTEM.md
  + read/get_tool_info/call_tool 的 name 和 description
  + 原生 Skill name/description/location 摘要
  + 当前 Agent cwd

messages
  = 当前 (agent_id, conversation_id) JSONL 恢复的有效消息

tools
  = [
      read schema,
      get_tool_info schema,
      call_tool schema
    ]
```

模型可见的 `Context.tools` 必须恰好为三个通用工具。真实业务工具的 Schema
不在 Session 初始化时注册。

### 6.2 Managed Prompt profile

当前 Java `SystemPromptBuilder` 会追加默认园区文档和日期、OS、Java、Shell
等环境信息。目标新增 Managed Prompt profile，只允许：

1. 当前 Agent 的 `.campusclaw/SYSTEM.md`；
2. 当前 Session 的三个 AgentTool；
3. 当前 Agent 目录下的 Skill 摘要；
4. 当前 Agent cwd。

Managed profile 不遍历全局或祖先上下文，不加载其他 Agent Skill，也不追加
进程环境明细。Legacy CLI 保持原有行为。

### 6.3 Session 创建和 Context

![Managed Session 与 Context 组装](managed_session_context_assembly.svg)

[PlantUML 源码](diagram.puml#L77)

创建顺序：

1. WebSocket 解析 `agent_id`、`model_id`、`conversation_id`；
2. AgentDirectoryResolver 得到受控 `agentCwd`；
3. ManagedSessionPool 使用 `(agent_id, conversation_id)` 查找 Session；
4. 新会话校验显式 `model_id`，恢复会话校验保存的 Model；
5. ManagedAgentSessionFactory 加载当前 Agent SYSTEM 和 Skill；
6. Factory 注册三个通用 AgentTool；
7. Factory 注入不可变 Session 调用元数据；
8. 每个 Session 创建独立 Agent；
9. AgentLoop 在每轮把三个 AgentTool 投影为 `Context.tools`。

## 7. Tool Manager 适配

### 7.1 通用工具接口

模型可调用的 Schema：

```text
get_tool_info:
  input:
    tool_id: string

call_tool:
  input:
    tool_id: string
    parameters: object
```

`agent_id`、`conversation_id`、用户和租户身份来自服务端 SessionContext，
不允许模型在参数中指定或覆盖。

Java 侧逻辑接口：

```java
ToolDescriptor getToolInfo(
        String agentId,
        String toolId,
        InvocationContext context);

ToolExecutionResult callTool(
        String agentId,
        String conversationId,
        String toolId,
        Map<String, Object> parameters,
        InvocationContext context);
```

`ToolDescriptor` 至少返回：

```text
tool_id
name
description
input_schema
output_schema
```

### 7.2 Tool description

通用调用协议由两个真实 AgentTool 的 description 承载。

`get_tool_info`：

```text
Get the current description and input schema for one logical business tool.
Use only tool_id values disclosed in the Agent tool list or an activated
Skill's references/tools.json. Call this tool before call_tool when the
current schema has not yet been loaded. This tool does not execute the
business operation.
```

`call_tool`：

```text
Execute one logical business tool through Tool Manager. Use only a tool_id
disclosed in the Agent tool list or an activated Skill. Obtain its current
schema with get_tool_info, then construct parameters according to that
schema. Tool Manager performs final binding, permission, status and schema
validation.
```

这两段 description 同时进入 Java 最终 systemPrompt 的可用工具列表和
`Context.tools`，无需把协议复制到每个 Agent 的业务指令。

### 7.3 发现和执行

![Tool 渐进式发现与执行](progressive_tool_discovery_execution.svg)

[PlantUML 源码](diagram.puml#L155)

Agent 直接工具路径：

```text
SYSTEM.md 中看到 tool_id/name/description
-> get_tool_info(tool_id)
-> call_tool(tool_id, parameters)
```

Skill 工具路径：

```text
Skill 摘要匹配任务
-> read(SKILL.md)
-> Skill 需要外部操作
-> read(references/tools.json)
-> get_tool_info(tool_id)
-> call_tool(tool_id, parameters)
```

Tool Manager 在 `get_tool_info` 和 `call_tool` 中都校验：

1. Agent 存在且启用；
2. tool_id 当前绑定到该 Agent 或其可用 Skill；
3. Tool 存在且启用；
4. Agent、Skill、Tool 权限允许当前操作；
5. 当前用户、租户和环境满足执行策略；
6. `call_tool` 参数符合当前 input schema；
7. 执行结果符合 output schema。

推荐的稳定错误码：

```text
AGENT_NOT_FOUND
TOOL_NOT_BOUND
TOOL_DISABLED
TOOL_FORBIDDEN
INVALID_PARAMETERS
TOOL_EXECUTION_FAILED
INVALID_TOOL_RESULT
```

Runtime 不缓存 permission 作为安全依据。Session 内可缓存 ToolDescriptor
减少重复查询，但 Tool Manager 在每次执行时仍必须重新授权。

## 8. Model Manager 适配

### 8.1 接口

逻辑接口：

```java
List<ModelDescriptor> listModels(String agentId);

ModelDescriptor resolveModel(
        String agentId,
        String modelId);

ModelEventStream invoke(
        String agentId,
        String modelId,
        Context context,
        ModelInvocationOptions options);
```

`listModels` 根据 `AGENT.models` 返回当前可用集合；`resolveModel` 精确校验
`agent_id + model_id`；`invoke` 每轮重新校验 Agent 绑定和 Model 状态。

`ModelDescriptor` 至少提供 Java 构造 `Model` 所需的公开能力：

```text
id
name
reasoning
input modalities
context window
max output tokens
```

真实 Provider、凭据、base URL、header 和路由留在 Model Manager。

### 8.2 Java Provider

目标增加：

```text
Api.MODEL_MANAGER("model-manager")
ModelManagerApiProvider
ModelManagerClient
```

Java 为 Manager model 构造运行时 `Model`：

```text
id       = ModelDescriptor.id
name     = ModelDescriptor.name
api      = MODEL_MANAGER
provider = CUSTOM
capability fields = ModelDescriptor
```

Provider 从 `SimpleStreamOptions.metadata` 读取不可变：

```json
{
  "agent_id": "agent-a",
  "conversation_id": "conversation-1"
}
```

单例 Provider 不保存当前 Agent 身份，不使用 ThreadLocal，也不依赖
`SettingsManager.workingDir`。

### 8.3 流式事件

![Model Manager 流式调用](model_manager_streaming_flow.svg)

[PlantUML 源码](diagram.puml#L233)

Model Manager 事件一对一映射为 Java `AssistantMessageEvent`：

| Manager 事件 | Java 事件 |
|---|---|
| stream start | `StartEvent` |
| text start/delta/end | `TextStartEvent` / `TextDeltaEvent` / `TextEndEvent` |
| thinking start/delta/end | 对应 Thinking 事件 |
| tool call start/delta/end | 对应 ToolCall 事件 |
| successful completion | `DoneEvent` |
| error or abort | `ErrorEvent` |

Provider 只负责请求和事件映射。ToolCall 回到 AgentLoop，由
`get_tool_info` 或 `call_tool` 的 `AgentTool.execute()` 进入 Tool Manager。

取消订阅时关闭 Manager 流。收到第一个流事件后不自动重试整个请求，避免
重复文本或重复 ToolCall。Managed 模式不回退到 Java 内置 Provider。

## 9. WebSocket 和 Session

### 9.1 握手

目标地址：

```text
/api/ws/chat
  ?agent_id=<required>
  &model_id=<required-for-new-session>
  &conversation_id=<optional>
  &token=<deployment-dependent>
```

新会话：

- `agent_id` 必填；
- `model_id` 必填并由 Model Manager 精确校验；
- `conversation_id` 省略时由服务端生成；
- Session cwd 由 `agent_id` 唯一解析。

恢复会话：

- `agent_id` 和 `conversation_id` 必填；
- `model_id` 可省略；
- 省略时读取 JSONL 保存的 Model，再由 Model Manager 重新校验；
- 显式传入不同 `model_id` 表示模型切换，校验成功后写入 model change；
- 不允许通过恢复会话切换 Agent。

`list_models` 使用 `listModels(agent_id)`；`set_model` 使用
`resolveModel(agent_id, model_id)`。

### 9.2 内存隔离

ManagedSessionPool 的 key 为：

```text
SessionKey(agent_id, conversation_id)
```

因此两个 Agent 可以拥有同名 conversation：

```text
(agent-a, conversation-1)
(agent-b, conversation-1)
```

它们对应不同 AgentSession、Agent、cwd、Prompt、Skill、Model 和 Tool
调用上下文。

### 9.3 JSONL 路径

用户级 Session 存储：

```text
<user-agent-dir>/
└── sessions/
    └── <agent-id>/
        └── <conversation-id>.jsonl
```

默认：

```text
<user-agent-dir> = ~/.campusclaw/agent
```

Session header 中的 cwd 写入当前 `agentCwd`。路径解析对 `agent_id` 和
`conversation_id` 使用相同的单路径段约束。

持久化至少覆盖：

- session header；
- user、assistant 和 tool result 消息；
- model change；
- thinking level change；
- 分支和 compaction 所需的现有 Session entry。

## 10. pi-mono-java 目标适配点

| 当前位置 | 目标改造 | 分类 |
|---|---|---|
| WebSocket route | 解析 agent_id、model_id、conversation_id，并调用 AgentDirectoryResolver | 架构改造 |
| `SessionPool` | 增加 Managed 路径；复合 key、按 Agent JSONL 路径、移除单一 cwd 假设 | 架构改造 |
| `ManagedAgentSessionFactory` | 新增；按 Session 加载受控 Agent 目录并创建独立 Agent | 架构改造 |
| `AgentSession.initialize()` | Managed 路径使用精确 cwd、三个通用 Tool、Manager Model 和 Managed Prompt profile | 架构改造 |
| `SystemPromptBuilder` | 增加 Managed profile，只组合允许的 Prompt 来源和 cwd | 安全加固 |
| `AgentTool` 实现 | 保留 read，新增 get_tool_info 和 call_tool；不注册业务 Tool | 产品约束 |
| `Api` / `ApiProviderRegistry` | 增加 MODEL_MANAGER Api 和 Spring Provider | 架构改造 |
| `Agent` stream options | 合并不可变 agent_id、conversation_id metadata | 架构改造 |
| model list/set/restore | 统一经过 Agent 范围的 Model Manager catalog | 安全加固 |
| Legacy CLI | 保持原来的本地 Provider、Tool、Settings 和资源发现路径 | 兼容要求 |

Managed 路径不得修改共享 `SettingsManager.workingDir` 来表示当前 Agent。
Agent 身份必须来自不可变 SessionContext，避免并发 Session 互相覆盖。

## 11. 失败处理与安全边界

### 11.1 发布失败

以下任一情况不发布 Agent 目录：

- Agent、Skill 或 Tool 元数据 Schema 无效；
- Agent 未启用；
- 显式版本不存在，或省略版本无法唯一解析；
- Skill 依赖循环或 name 冲突；
- Skill 文档输入模式不唯一；
- frontmatter 与元数据不一致；
- 路径越界或符号链接越界；
- 绑定对象缺失、未启用、版本冲突或有效权限为 deny；
- Tool 摘要缺少 tool_id、name 或 description。

生成过程在临时目录完成，失败时不改变当前可运行 Agent 目录。

### 11.2 建 Session 失败

以下情况在握手阶段返回明确错误，不创建部分 Session：

- agent_id 非法或 Agent 目录不存在；
- SYSTEM 或 Skill 目录不可读；
- 新会话缺少 model_id；
- model_id 不属于当前 Agent；
- conversation_id 路径非法；
- 恢复记录属于其他 Agent；
- 恢复 Model 当前已禁用或解除绑定。

### 11.3 运行时失败

- Tool Manager 拒绝时，把结构化错误作为 ToolResult 返回模型；
- Model Manager 在流开始前失败时可按平台 retry policy 重试；
- 流开始后失败直接结束当前 Assistant turn；
- 取消信号同时停止模型流和当前 Tool 调用；
- Agent 目录更新只影响后续新 Session，运行中的 Session 保持创建时快照。

### 11.4 信任边界

- 客户端只能提供 agent_id，不能提供 cwd；
- Agent 目录由部署程序写入，运行账号只读；
- read 限制在当前 Agent cwd 允许范围；
- Prompt 中的 tool_id 不构成授权；
- agent_id、conversation_id、tenant 和 user 均由服务端注入 Manager 请求；
- Tool Manager 和 Model Manager 是每次调用的最终权限执行点。

## 12. 测试与验收

### 12.1 目录编译器

- 同一输入重复编译得到字节一致的 SYSTEM、SKILL 和 tools.json；
- 结构化 content 与等价完整 SKILL.md 生成一致的规范文件；
- Agent SYSTEM 只包含 Agent 直接 Tool；
- Skill tools.json 只包含该 Skill 直接 Tool；
- 空 binding_tools 不生成 references；
- 递归 Skill 正确物化，子 Tool 不向父文件传播；
- 路径穿越、符号链接越界、循环依赖、name 冲突全部失败；
- 失败编译不破坏当前发布目录。

### 12.2 Prompt 和 Context

- systemPrompt 只包含 Agent SYSTEM、三个通用 Tool、Skill 摘要和 cwd；
- `Context.tools` 恰好是 read、get_tool_info、call_tool；
- 业务 Tool Schema 不在初始化 Context；
- Skill 正文只在 read 后进入消息上下文；
- Skill Tool 只在读取 references/tools.json 后披露；
- 环境中的其他 Agent 资源不影响当前 Session。

### 12.3 Tool Manager

- Agent 直接 tool_id 可发现和执行；
- Skill tool_id 在读取 Skill 资源后可发现和执行；
- 跨 Agent tool_id、未绑定、禁用、deny 和无用户权限调用被拒绝；
- 过期或错误 parameters 被当前 Schema 拒绝；
- Tool Descriptor 缓存不绕过执行时重新鉴权；
- Manager 输出不符合 output schema 时返回稳定错误。

### 12.4 Model Manager

- 新 Session 必须精确校验 model_id；
- 恢复 Session 必须重新校验保存模型；
- list/set model 只暴露当前 Agent 允许集合；
- start、text、thinking、toolcall、done、error 事件映射正确；
- 取消关闭 Manager 流；
- 流开始后不自动重放请求；
- Manager 失败不回退到其他 Provider。

### 12.5 多 Agent

- 两个 Agent 使用相同 conversation_id 时内存 Session 不冲突；
- 两个 Agent 的 JSONL 路径不同；
- SYSTEM、Skill、cwd、Model 和 Tool 请求不串用；
- 并发创建 Session 不修改共享 workingDir；
- Agent A 的 Stream metadata 不会出现在 Agent B 的 Manager 请求。

## 13. 设计验收标准

- 文档给出完整的元数据字段、文件和运行时消费者映射；
- cwd 只由 agent_id 经受控 Resolver 产生；
- Agent 运行目录能被 pi-mono-java 原生 SYSTEM 和 Skill 路径读取；
- Agent direct Tool 与 Skill Tool 保持两级渐进披露；
- 模型实际可执行工具固定为三个；
- 通用工具 description 完整表达发现和执行协议；
- Model 和 Tool Manager 分别是调用权威；
- Session 使用 `(agent_id, conversation_id)` 隔离；
- 用户级 JSONL 路径包含 agent_id；
- Managed 和 Legacy 路径职责明确；
- 所有 Java 目标差异均标记为产品约束、安全加固或架构改造。

## 14. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-07-29 | 初版；定义元数据到运行目录映射、三通用工具、Skill 渐进式披露、Model/Tool Manager 适配和单 JVM 多 Agent Session 隔离 |
