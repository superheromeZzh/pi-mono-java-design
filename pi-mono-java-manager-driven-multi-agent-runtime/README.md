# pi-mono-java Manager 驱动的多 Agent 运行设计

| 属性 | 值 |
|---|---|
| 文档版本 | 1.1.0 |
| 状态 | 目标设计，尚未实施 |
| 更新日期 | 2026-07-30 |
| pi-mono 源码基线 | `fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc` |
| pi-mono-java 源码基线 | `1f7a5423219edfa4519d8719f1cc8a188ed72873` |
| OpenClaw 源码基线 | `91dca69dae23d3bdeff5aefb8400249a04216039` |
| 运行形态 | 单 JVM、多 Agent、WebSocket 会话 |

## 1. 结论

本设计使用一个目录编译程序，把 AGENT、SKILL、TOOL 元数据投影为
pi-mono-java 可以直接读取的 Agent 运行目录。目录只承担 Prompt 和 Skill
渐进式披露，不承担模型、工具或权限的运行时权威。

每条 WebSocket v2 连接通过首帧 `connect` 固定绑定一个
`(agent_id, conversation_id)`。服务端从受控根目录解析 Agent cwd，创建该
Agent 独立的 `AgentSession` 和 `Agent`。模型由 Model Manager 调用，业务
工具由 Tool Manager 发现和执行。连接断开只取消事件订阅，不终止正在执行的
run；客户端重连后从原子快照继续消费。

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

WebSocket 流不再反复发送累计 `AssistantMessage`。实时帧只发送结构化
delta，`message.completed`、重连快照和历史接口才携带完整 Message 投影。
本专题的规范性协议文件为
[`chat-ws-v2.asyncapi.yaml`](chat-ws-v2.asyncapi.yaml)。

## 2. 范围与设计分类

本文覆盖：

- 三类元数据到 Agent 运行目录的确定性映射；
- Agent cwd、Session 隔离和 WebSocket 握手；
- Session-scoped WebSocket v2、结构化流事件、恢复和背压；
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
- 附件上传 REST API；
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
| WebSocket 生命周期 | [`ChatWebSocketHandler.java#L115-L135`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ChatWebSocketHandler.java#L115-L135)、[`#L168-L188`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ChatWebSocketHandler.java#L168-L188) | 当前一条连接捕获一个 AgentSession，连接关闭会调用 abort |
| WebSocket 命令 | [`ChatWebSocketHandler.java#L195-L227`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ChatWebSocketHandler.java#L195-L227) | 当前使用 `prompt`、`steer`、`abort`、`new_session` 等 v1 命令，没有统一 req/res/event Envelope |
| WebSocket 消息更新 | [`ChatWebSocketHandler.java#L422-L459`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ChatWebSocketHandler.java#L422-L459)、[`useChatWs.ts#L439-L448`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/frontend/src/composables/useChatWs.ts#L439-L448) | 当前 `message_update` 携带累计 Message，前端用新快照替换旧快照 |
| v1 协议文档 | [`docs/asyncapi/chat-ws.yaml#L1-L76`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/docs/asyncapi/chat-ws.yaml#L1-L76) | 当前 AsyncAPI 版本为 1.0.0，记录 query 握手、v1 命令和累计 Message 行为 |
| Agent 流事件 | [`MessageUpdateEvent.java#L17-L20`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/agent-core/src/main/java/com/campusclaw/agent/event/MessageUpdateEvent.java#L17-L20)、[`AgentLoop.java#L255-L276`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/agent-core/src/main/java/com/campusclaw/agent/loop/AgentLoop.java#L255-L276) | Java 内部事件同时保留累计 AssistantMessage 和细粒度 AssistantMessageEvent，v2 可直接映射后者 |
| Provider 扩展点 | [`ApiProvider.java#L31-L59`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/provider/ApiProvider.java#L31-L59)、[`ApiProviderRegistry.java#L54-L80`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/provider/ApiProviderRegistry.java#L54-L80) | Spring 可发现统一 ApiProvider，并按 `Api` 分发 |
| 调用元数据 | [`SimpleStreamOptions.java#L34-L45`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/types/SimpleStreamOptions.java#L34-L45) | 每次模型调用已有任意 metadata 字段可承载 Session 身份 |
| 模型流事件 | [`AssistantMessageEvent.java#L44-L164`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/stream/AssistantMessageEvent.java#L44-L164) | 已定义 start、text、thinking、toolcall、done、error 事件 |

### 3.3 OpenClaw Gateway

源码仓库：

```text
repository: https://github.com/openclaw/openclaw
commit:     91dca69dae23d3bdeff5aefb8400249a04216039
```

| 主题 | 源码证据 | 观察到的行为 |
|---|---|---|
| 握手与 Envelope | [`docs/gateway/protocol.md#L34-L50`](https://github.com/openclaw/openclaw/blob/91dca69dae23d3bdeff5aefb8400249a04216039/docs/gateway/protocol.md#L34-L50)、[`#L83-L158`](https://github.com/openclaw/openclaw/blob/91dca69dae23d3bdeff5aefb8400249a04216039/docs/gateway/protocol.md#L83-L158)、[`frames.ts#L155-L188`](https://github.com/openclaw/openclaw/blob/91dca69dae23d3bdeff5aefb8400249a04216039/packages/gateway-protocol/src/schema/frames.ts#L155-L188) | Gateway 使用 connect challenge/hello 和 req/res/event Envelope；连接是通用 Gateway 连接，不固定到单个 Agent Session |
| Chat 多路复用 | [`logs-chat.ts#L160-L240`](https://github.com/openclaw/openclaw/blob/91dca69dae23d3bdeff5aefb8400249a04216039/packages/gateway-protocol/src/schema/logs-chat.ts#L160-L240) | `chat.send` 每次携带 `sessionKey`，同一连接可承载不同 Session |
| Chat delta | [`server-chat.ts#L278-L296`](https://github.com/openclaw/openclaw/blob/91dca69dae23d3bdeff5aefb8400249a04216039/src/gateway/server-chat.ts#L278-L296)、[`#L881-L951`](https://github.com/openclaw/openclaw/blob/91dca69dae23d3bdeff5aefb8400249a04216039/src/gateway/server-chat.ts#L881-L951) | Chat delta 同时支持 `deltaText`、累计 message 和 replace 语义 |
| 客户端合并与恢复 | [`chat-gateway.ts#L72-L96`](https://github.com/openclaw/openclaw/blob/91dca69dae23d3bdeff5aefb8400249a04216039/ui/src/pages/chat/chat-gateway.ts#L72-L96)、[`gateway-store.ts#L379-L389`](https://github.com/openclaw/openclaw/blob/91dca69dae23d3bdeff5aefb8400249a04216039/ui/src/app/gateway-store.ts#L379-L389)、[`docs/gateway/clients.md#L111-L134`](https://github.com/openclaw/openclaw/blob/91dca69dae23d3bdeff5aefb8400249a04216039/docs/gateway/clients.md#L111-L134) | 客户端合并增量；发现事件序列缺口时重连，并通过权威快照/历史恢复 |
| 序列与背压 | [`server-broadcast.ts#L190-L327`](https://github.com/openclaw/openclaw/blob/91dca69dae23d3bdeff5aefb8400249a04216039/src/gateway/server-broadcast.ts#L190-L327) | 广播按客户端维护连接序列，并对慢消费者应用背压策略 |

本设计借鉴 Envelope、序列和“快照后继续增量”的恢复原则，但不复制
OpenClaw 的 Gateway 多路复用。CampusClaw 当前产品边界是 ToB 的
Session-scoped 连接：一个连接的认证、Agent 权限、Conversation、模型和
thinking 披露策略在握手后全部固定，减少跨 Agent 路由和审计歧义。这是产品
约束和安全加固，不是 WebSocket 协议本身的限制。

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
| ManagedSessionPool | `(agent_id, conversation_id)` 到 Session 和 active run 的映射 | 内存隔离、恢复、运行所有权和淘汰 |
| ManagedRunHub | active run 的 partial Message、Tool、终态和 `run_seq` | 独立于连接持续运行，并为订阅者生成原子恢复点 |
| ConnectionAuthAdapter | Cookie/Bearer 身份与 Manager audience 凭据 | 固化连接身份、校验 Origin 并避免凭据进入 Agent 数据 |
| Attachment service | REST 上传制品、所有权和租户范围 | WebSocket 只引用已上传的 `attachment_id` |
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

1. WebSocket Upgrade 建立认证上下文，首帧 connect 解析
   `agent_id`、`model_id`、`conversation_id`；
2. AgentDirectoryResolver 得到受控 `agentCwd`；
3. ManagedSessionPool 使用 `(agent_id, conversation_id)` 查找 Session；
4. 新会话校验显式 `model_id`，恢复会话校验保存的 Model；
5. ManagedAgentSessionFactory 加载当前 Agent SYSTEM 和 Skill；
6. Factory 注册三个通用 AgentTool；
7. Factory 注入不可变 Session 调用元数据；
8. 每个 Session 创建独立 Agent；
9. AgentLoop 在每轮把三个 AgentTool 投影为 `Context.tools`；
10. ManagedRunHub 原子注册连接订阅并捕获 active-run 快照，connect Response
    发出后才排出快照 cursor 之后的事件。

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

[PlantUML 源码](diagram.puml#L169)

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

[PlantUML 源码](diagram.puml#L358)

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

AgentLoop 显式取消当前模型调用时，Provider 关闭 Manager 流；WebSocket
连接取消事件订阅不会传播为模型取消。收到第一个流事件后不自动重试整个
请求，避免重复文本或重复 ToolCall。Managed 模式不回退到 Java 内置
Provider。

## 9. WebSocket 和 Session

### 9.1 协议定位

`/api/ws/chat` 直接提供版本 2，不为同一路由保留 v1 消息语义。它是一条
连接绑定一个 `(agent_id, conversation_id)` 的 Session-scoped 协议：

```text
one WebSocket connection
-> one authenticated connection context
-> one agent_id
-> one conversation_id
-> zero or one active primary run
```

不同 Conversation 通过不同连接并发。同一 Conversation 可有多个经过相同
租户、用户及 Agent 授权的观察连接；它们订阅同一个 `ManagedRunHub`，但
不会复制 run。任何有写权限的观察连接都可以在空闲时发起 `chat.send`，
或对指定 active `run_id` 执行 steer/abort。暂不设计租户级多路复用
Gateway，也不允许连接建立后切换 Agent 或 Conversation。

规范性协议为
[`chat-ws-v2.asyncapi.yaml`](chat-ws-v2.asyncapi.yaml)。本文解释架构与
取舍；字段约束、Schema 和示例以该文件为准。后续实施 Java 改造时，以该
文件替换 pi-mono-java 的 `docs/asyncapi/chat-ws.yaml`。

### 9.2 Upgrade、认证和首帧

HTTP Upgrade 目标固定为：

```text
/api/ws/chat
```

Upgrade URL 不接受 `agent_id`、`model_id`、`conversation_id`、token 或
其他业务查询参数。认证方式：

- 浏览器使用 `HttpOnly + Secure + SameSite` Session Cookie，服务端必须
  校验允许的 `Origin`；
- CLI、SDK 和服务间调用使用 `Authorization: Bearer <token>`；
- Cookie 和 Bearer 同时存在时必须解析为同一 tenant/user，否则在 Upgrade
  阶段拒绝；
- Bearer 固化在不可变 `ConnectionAuthContext`；Cookie 身份由认证适配器
  换取短期、限定 Manager audience 的 Bearer；
- 外部 Bearer 只有在 audience 被 Manager 接受时才可直接转发，否则执行
  token exchange；
- 凭据及其 hash 不进入 Prompt、JSONL、WebSocket 事件、异常详情或普通日志。

客户端必须在 Upgrade 成功后 5 秒内发送首个 JSON 帧，且该帧只能是：

```json
{
  "type": "req",
  "id": "connect-1",
  "method": "connect",
  "params": {
    "min_protocol": 2,
    "max_protocol": 2,
    "agent_id": "agent-a",
    "conversation_id": "conversation-1",
    "model_id": "model-a",
    "client": {
      "id": "campusclaw-web",
      "version": "1.0.0",
      "platform": "web"
    },
    "capabilities": ["structured_message_delta"]
  }
}
```

首帧超时或首帧不是 `connect` 时使用 1008 关闭。协议区间不包含版本 2 时，
先返回 `UNSUPPORTED_PROTOCOL`，再使用 1002 关闭。

新会话省略 `conversation_id`，必须提供 `agent_id + model_id`。服务端生成
`conversation_id`，经 `AgentDirectoryResolver` 解析 cwd，并用 Model
Manager 精确校验模型。恢复会话提供 `agent_id + conversation_id`：

- 省略 `model_id` 时读取保存的模型，并重新通过 Model Manager 校验；
- 显式提供相同 `model_id` 是幂等操作；
- 显式提供不同 `model_id` 表示切换模型；存在 active run 时返回
  `RUN_ACTIVE`，否则先校验再持久化 model change；
- 保存的 Conversation 必须属于当前 tenant/user 和 `agent_id`。

成功的 connect Response 返回：

```json
{
  "type": "res",
  "id": "connect-1",
  "ok": true,
  "result": {
    "protocol": 2,
    "connection_id": "conn-01",
    "agent_id": "agent-a",
    "conversation_id": "conversation-1",
    "model": {"id": "model-a", "name": "Model A"},
    "session": {"state": "idle", "thinking": "hidden"},
    "limits": {
      "max_frame_bytes": 1048576,
      "max_connection_buffer_bytes": 4194304,
      "heartbeat_seconds": 20,
      "connect_timeout_seconds": 5
    },
    "active_run": null
  }
}
```

恢复时 `active_run` 可包含 `run_id`、快照对应的 `run_seq`、当前
`message_snapshot` 和 `active_tools`。connect 成功后任何试图再次调用
`connect` 或更换 Agent/Conversation 的请求都返回 `INVALID_REQUEST`；
创建新 Conversation 必须建立新连接。

### 9.3 Envelope、标识符和命令

所有文本帧均使用 JSON。四类公共结构为：

```text
Request  = {type:"req", id, method, params?}
Response = {type:"res", id, ok, result? | error?}
Event    = {type:"event", event, seq, payload}
Error    = {code, message, details?, retryable?, retry_after_ms?}
```

`Request.id` 在连接内由客户端生成且用于关联唯一 Response。命令接受成功
仅代表服务端已原子接受操作，不代表 run 已完成。`Event.seq` 是连接级从 1
开始的单调序列，重连后重新开始；run 事件的 `payload.run_seq` 则在同一
run 内跨重连连续递增。

命令集固定如下：

| method | 关键参数 | 成功结果和约束 |
|---|---|---|
| `chat.send` | `message`、`attachment_ids[]`、`idempotency_key`、可选 `thinking` | 返回 `run_id + accepted`；同一 Conversation 已有主 run 时返回 `RUN_ACTIVE` |
| `chat.steer` | `run_id`、`message`、`idempotency_key` | 向指定 active run 注入 steering message，不新建主 run |
| `chat.abort` | `run_id`、`idempotency_key` | 显式终止 run；对同一 run 和 key 重复调用返回相同接受结果 |
| `chat.history` | 可选 `cursor`、`limit` | 按服务端披露策略分页返回权威历史和下一游标 |
| `session.get` | 无 | 返回 Session、有效 Model、thinking 和 active-run 状态 |
| `models.list` | 无 | 调用 `listModels(agent_id)`，只返回当前 Agent 可用模型 |
| `model.set` | `model_id` | 调用 `resolveModel(agent_id, model_id)`；active run 期间拒绝 |
| `thinking.set` | `level` | 设置 Session 默认披露级别；active run 期间拒绝 |
| `prompt_templates.list` | 可选分页参数 | 返回当前 Agent 可见的模板摘要 |
| `skills.list` | 无 | 返回当前 Agent 已物化 Skill 的 name、description、location |

协议不提供连接内 `new_session`。`idempotency_key` 在当前
tenant/user/Agent/Conversation/command 范围内判重；同 key 同负载返回原
结果，同 key 不同负载返回 `INVALID_REQUEST`。

附件必须先经 REST 上传。WebSocket 只接受 `attachment_ids`，Session 服务
在接受 `chat.send` 前校验附件属于当前 tenant/user、未过期且可供当前
Agent 使用；客户端路径、URL 和二进制内容不能替代 ID。

### 9.4 流式事件和 Message 投影

服务端事件族固定为：

```text
run.started
message.started
message.updated
tool.started
tool.updated
tool.completed
message.completed
run.completed
```

每个 run 事件都携带 `agent_id`、`conversation_id`、`run_id`、
`run_seq` 和时间戳。Message 事件增加 `message_id`；内容更新增加
`content_index`。Tool 事件增加 `tool_call_id` 和逻辑 `tool_id`。

`message.updated.payload.update` 直接映射 Java
`AssistantMessageEvent`，允许的判别类型为：

```text
text_start / text_delta / text_end
thinking_start / thinking_delta / thinking_summary / thinking_end
toolcall_start / toolcall_delta / toolcall_end
```

`*_delta` 只携带本次增量，客户端按 `message_id + content_index` 组装，
不把增量当作完整 Message 替换。`message.completed` 携带经过披露策略投影
的完整最终 Message。`run.completed` 携带 `done`、`aborted` 或 `error`
结果，以及可用的 usage、stop reason 和结构化 Error；它是 run 的唯一
终态事件。

Tool 既通过 Assistant Message 内的 `toolcall_*` 表示模型生成过程，也通过
`tool.started/updated/completed` 表示 Tool Manager 的实际执行过程。两者
使用相同 `tool_call_id` 关联，但不能混为一个事件。

### 9.5 Thinking 披露

披露级别固定为 `hidden < summary < full`：

- `hidden` 是默认值，只发送 `thinking_start` 和 `thinking_end` 状态，不发送
  原始 thinking 或摘要正文；
- `summary` 只发送 Model Manager 明确标记为安全的
  `thinking_summary`，不得由 CampusClaw 从原始 thinking 合成；
- `full` 必须同时满足 tenant 策略、Agent 策略、Model 能力、用户 scope 和
  客户端 `full_thinking` capability；
- `chat.send.thinking` 只能把当前 Session 允许级别调低，不能临时提升；
- 实时事件、connect 恢复快照、`session.get` 和 `chat.history` 使用同一个
  `ThinkingProjectionPolicy`，避免从恢复或历史旁路泄露。

策略在 run 开始时固化为该 run 的不可变投影上下文。中途权限收紧时立即按
更严格策略投影后续事件，但不重发已经披露的数据。

### 9.6 run 所有权、重连和无竞态快照

`ManagedSessionPool` 持有 AgentSession 和 active run；WebSocket 只持有
订阅。连接关闭时取消订阅，不调用 `AgentSession.abort()`。run 只在以下
情况终止：正常完成、显式 `chat.abort`、Agent/租户策略撤销、服务端有界
运行超时或进程故障。

`ManagedRunHub` 持续维护：

```text
run_id
last run_seq
partial projected Message
active tools
terminal outcome
bounded post-snapshot event buffer
```

恢复连接时，服务端在同一临界区内完成“注册订阅 + 捕获 cursor/snapshot”：

1. 为连接注册订阅并记录 Hub 当前 cursor；
2. 从同一状态版本生成 `active_run` 快照；
3. 先发送 connect Response；
4. 再按 `run_seq > snapshot.run_seq` 顺序排出订阅缓冲中的事件。

因此快照和新 delta 之间没有丢失窗口，也不会重放已包含在快照中的 delta。
若 run 在断线期间已经结束，connect 返回 `active_run: null`，客户端通过
`chat.history` 读取已持久化的 `message.completed` 等价终态。客户端发现
连接 `seq` 或单个 run 的 `run_seq` 缺口时不得猜测缺失文本，应断开并按
上述流程恢复。

### 9.7 流控、心跳和错误

服务端不得静默丢弃 delta。默认限制为：

| 限制 | 默认值 | 处理 |
|---|---:|---|
| 单 WebSocket frame | 1 MiB | 超限使用 1009 关闭 |
| 单连接待发送缓冲 | 4 MiB | 慢消费者使用 1013 关闭，客户端重连恢复 |
| 原生 Ping/Pong | 20 秒 | 连接超时只取消订阅，不终止 run |
| 首帧 `connect` | 5 秒 | 超时使用 1008 关闭 |

实际限制在 connect Response 的 `limits` 返回。业务命令失败优先使用
`res.ok=false`，不会因可恢复的请求错误关闭连接。稳定错误码至少包括：

```text
INVALID_REQUEST
UNAUTHENTICATED
FORBIDDEN
UNSUPPORTED_PROTOCOL
AGENT_NOT_FOUND
CONVERSATION_NOT_FOUND
MODEL_REQUIRED
MODEL_NOT_ALLOWED
RUN_ACTIVE
RUN_NOT_FOUND
INVALID_ATTACHMENT
MANAGER_AUTH_FAILED
MANAGER_UNAVAILABLE
```

Manager 认证失败不得把上游凭据或响应正文写入 `details`。`retryable` 和
`retry_after_ms` 只描述同一命令是否适合稍后重试；对可能产生副作用的命令，
客户端仍必须复用原 `idempotency_key`。

### 9.8 内存隔离

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

### 9.9 JSONL 路径

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

连接级 `seq`、连接 ID、认证凭据、发送缓冲和瞬时 partial Message 不写入
JSONL。run 终态和最终 Message 必须先按 Session 的持久化顺序提交，再向
订阅者发出对应完成事件。

![Managed WebSocket Session 协议](managed_websocket_session_protocol.svg)

[PlantUML 源码](diagram.puml#L247)

## 10. pi-mono-java 目标适配点

| 当前位置 | 目标改造 | 分类 |
|---|---|---|
| WebSocket Upgrade route | 不解析业务 query；校验 Cookie/Bearer/Origin，创建不可变 ConnectionAuthContext | 安全加固 |
| `ChatWebSocketHandler` | 首帧 connect、统一 req/res/event Envelope、Session-scoped 绑定、结构化 delta 和流控 | 架构改造 |
| `SessionPool` | 增加 Managed 路径；复合 key、按 Agent JSONL 路径、run 独立于连接、移除单一 cwd 假设 | 架构改造 |
| `ManagedRunHub` | 新增；维护 partial Message、active tools、终态、run_seq 和原子恢复订阅 | 架构改造 |
| `ManagedAgentSessionFactory` | 新增；按 Session 加载受控 Agent 目录并创建独立 Agent | 架构改造 |
| `AgentSession.initialize()` | Managed 路径使用精确 cwd、三个通用 Tool、Manager Model 和 Managed Prompt profile | 架构改造 |
| `SystemPromptBuilder` | 增加 Managed profile，只组合允许的 Prompt 来源和 cwd | 安全加固 |
| `AgentTool` 实现 | 保留 read，新增 get_tool_info 和 call_tool；不注册业务 Tool | 产品约束 |
| `Api` / `ApiProviderRegistry` | 增加 MODEL_MANAGER Api 和 Spring Provider | 架构改造 |
| `Agent` stream options | 合并不可变 agent_id、conversation_id metadata | 架构改造 |
| model list/set/restore | 统一经过 Agent 范围的 Model Manager catalog | 安全加固 |
| Web 前端 `useChatWs` | 按 message_id/content_index 合并 delta；序列缺口时重连并应用快照 | 架构改造 |
| REST attachment service | 上传后返回租户和用户范围的 attachment_id，供 chat.send 引用 | 安全加固 |
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

以下情况在 connect 阶段返回明确错误，不创建部分 Session：

- Upgrade 身份无效、Cookie 与 Bearer 身份冲突或浏览器 Origin 不允许；
- 首帧不是 connect、超时或协议版本不兼容；
- agent_id 非法或 Agent 目录不存在；
- SYSTEM 或 Skill 目录不可读；
- 新会话缺少 model_id；
- model_id 不属于当前 Agent；
- conversation_id 路径非法；
- 恢复记录属于其他 Agent；
- 恢复 Model 当前已禁用或解除绑定；
- active run 存在时请求切换模型。

### 11.3 运行时失败

- Tool Manager 拒绝时，把结构化错误作为 ToolResult 返回模型；
- Model Manager 在流开始前失败时可按平台 retry policy 重试；
- 流开始后失败直接结束当前 Assistant turn；
- 取消信号同时停止模型流和当前 Tool 调用；
- WebSocket 断开只取消订阅，不取消模型流或 Tool 调用；
- 慢消费者使用 1013 断开，通过重连快照恢复，不丢弃 delta；
- Manager 认证错误清除敏感上游详情后映射为 `MANAGER_AUTH_FAILED`；
- Agent 目录更新只影响后续新 Session，运行中的 Session 保持创建时快照。

### 11.4 信任边界

- 客户端只能提供 agent_id，不能提供 cwd；
- Agent 目录由部署程序写入，运行账号只读；
- read 限制在当前 Agent cwd 允许范围；
- Prompt 中的 tool_id 不构成授权；
- agent_id、conversation_id、tenant 和 user 均由服务端注入 Manager 请求；
- Upgrade URL、Prompt、JSONL、事件和日志均不保存认证凭据；
- 实时、快照和历史共用 ThinkingProjectionPolicy；
- attachment_id 必须在接受 run 前校验 tenant/user 所有权；
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
- AgentLoop 显式取消当前调用时关闭 Manager 流，WebSocket 取消订阅不关闭；
- 流开始后不自动重放请求；
- Manager 失败不回退到其他 Provider。

### 12.5 多 Agent

- 两个 Agent 使用相同 conversation_id 时内存 Session 不冲突；
- 两个 Agent 的 JSONL 路径不同；
- SYSTEM、Skill、cwd、Model 和 Tool 请求不串用；
- 并发创建 Session 不修改共享 workingDir；
- Agent A 的 Stream metadata 不会出现在 Agent B 的 Manager 请求。

### 12.6 WebSocket v2

- 新会话只接受 `agent_id + model_id`，恢复会话接受
  `agent_id + conversation_id` 并重新校验保存模型；
- Upgrade URL 中的业务 query 和 token 被拒绝，首帧 connect 的 5 秒约束
  生效；
- Cookie + 合法 Origin、Bearer 以及 Cookie/Bearer 同身份组合成功，不同
  身份组合失败；
- 两个 Conversation 使用两个连接并发执行；同一 Conversation 多个观察连接
  只共享一个 active run；
- active run 期间重复 `chat.send`、`model.set`、`thinking.set` 返回
  `RUN_ACTIVE`；
- `chat.steer` 和 `chat.abort` 只作用于指定 active `run_id`，重复 abort
  保持幂等；
- `message.updated` 只携带本次 delta，客户端可按 content_index 还原为
  `message.completed` 的最终 Message；
- 断线期间 run 继续；重连的快照和快照 cursor 之后的 delta 无丢失、无重复；
- run 在断线期间结束后，`chat.history` 返回持久化终态；
- hidden、summary、full 在实时、快照和历史中保持同一披露结果，未经 Manager
  标记的摘要不会输出；
- 跨租户、跨用户、过期或不存在的 attachment_id 返回
  `INVALID_ATTACHMENT`；
- 客户端检测 `seq` 或 `run_seq` 缺口后重连恢复，不拼接未知缺口；
- 1 MiB frame、4 MiB 缓冲、1009、1013 和 Ping/Pong 行为可重复验证；
- Manager 身份交换失败和 Manager 不可用分别返回稳定错误，且错误中无凭据。

## 13. 设计验收标准

- 文档给出完整的元数据字段、文件和运行时消费者映射；
- cwd 只由 agent_id 经受控 Resolver 产生；
- Agent 运行目录能被 pi-mono-java 原生 SYSTEM 和 Skill 路径读取；
- Agent direct Tool 与 Skill Tool 保持两级渐进披露；
- 模型实际可执行工具固定为三个；
- 通用工具 description 完整表达发现和执行协议；
- Model 和 Tool Manager 分别是调用权威；
- Session 使用 `(agent_id, conversation_id)` 隔离；
- WebSocket 首帧固定 Session，实时流使用结构化 delta；
- run 生命周期独立于连接，重连通过原子快照和 run_seq 恢复；
- 同一披露策略覆盖实时、快照和历史；
- 认证凭据不进入 Agent 数据和协议事件；
- 用户级 JSONL 路径包含 agent_id；
- Managed 和 Legacy 路径职责明确；
- 所有 Java 目标差异均标记为产品约束、安全加固或架构改造。

## 14. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.1.0 | 2026-07-30 | 定义 Session-scoped WebSocket v2、首帧 connect、Cookie/Bearer 认证、结构化 delta、run 独立生命周期、原子重连快照、thinking 披露、流控和规范性 AsyncAPI |
| 1.0.0 | 2026-07-29 | 初版；定义元数据到运行目录映射、三通用工具、Skill 渐进式披露、Model/Tool Manager 适配和单 JVM 多 Agent Session 隔离 |
