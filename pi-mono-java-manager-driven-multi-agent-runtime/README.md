# pi-mono-java Manager 驱动的多 Agent 运行设计

| 属性 | 值 |
|---|---|
| 文档版本 | 1.5.0 |
| 状态 | 目标设计，尚未实施 |
| 更新日期 | 2026-08-03 |
| pi-mono 源码基线 | `fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc` |
| pi-mono-java 源码基线 | `1f7a5423219edfa4519d8719f1cc8a188ed72873` |
| OpenClaw 源码基线 | `b015925bc30f6a8363f290b07d5f8588e21422b8` |
| 运行形态 | 单 JVM、多 Agent、WebSocket 会话 |

## 1. 结论

目录编译程序读取固定版本的 AGENT、SKILL 和 TOOL 元数据，生成 pi-mono-java
可以直接加载的 Agent 运行目录。生成结果只向模型渐进披露 Prompt 和 Skill；
Model Manager、Tool Manager 仍分别掌握模型、工具和权限的运行时权威。

上层会话服务先为一次对话分配 `session_id`，再建立 WebSocket，并在首个
`connect` Frame 中提交 Session、Agent 和 Model。服务端校验成功后，从受控
根目录解析 Agent cwd，创建或恢复该 Agent 独立的 `AgentSession` 和 `Agent`。
连接断开时，服务端只取消事件订阅，不终止正在执行的 run；客户端重连后从
原子快照继续消费。

`ChatWebSocketAdapter` 接收网络 Frame，并把强类型命令交给当前连接独占的
`ManagedSessionTransport`；Transport 返回响应并持续发布 Session 事件。
Request Frame 可以携带 W3C `traceparent`，connect Response 返回经过客户端
声明、服务能力和授权共同过滤的有效 features。

模型只直接调用以下三个通用工具：

```text
read
get_tool_info
call_tool
```

当任务需要真实业务操作时，模型先读取 Agent 或 Skill 披露的逻辑
`tool_id`，再通过 `get_tool_info` 取得当前 Schema，通过 `call_tool` 请求
执行。服务端不把真实业务工具注册为 `AgentTool`；Agent 直接绑定的工具摘要
进入 `SYSTEM.md`，Skill 绑定的工具摘要进入该 Skill 的
`references/tools.json`。

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

<runtime-data-root>/
└── sessions/
    └── <agent-id>/
        └── <session-id>.jsonl
```

`references/tools.json` 只在 Skill 存在直接有效 `binding_tools` 时生成。

模型产生流式输出时，服务端只发送本次结构化 delta，不反复发送累计
`AssistantMessage`。客户端只在 `message.completed`、重连快照和历史接口中
接收完整 Message 投影。
本专题的规范性协议文件为
[`chat-ws-v2.asyncapi.yaml`](chat-ws-v2.asyncapi.yaml)。
实现上层服务、SDK 或浏览器侧 Frame reducer 时，按
[`chat-ws-v2-client-integration.md`](chat-ws-v2-client-integration.md)
给出的连接、发送、归并、恢复和错误路径实施；浏览器仍只连接上层会话服务，
不直接持有 Runtime 服务凭据。

CampusClaw 是 Agent Runtime，不是用户会话产品。上层会话服务负责创建
`session_id`、维护用户会话列表和数量限制、发起业务删除；CampusClaw 把
`session_id` 作为不透明的持久上下文标识，负责 Agent/Model 绑定、JSONL、
消息、run 和流式恢复。本设计不再引入 `conversation_id` 或第二套
`agent_session_id`。

上层会话服务必须保证 `session_id` 在一个 CampusClaw Runtime 部署范围内
全局唯一，推荐使用 UUIDv7 或 ULID，并且删除后不得复用。Runtime 不接收、
不保存，也不使用业务 `tenant_id` 或 `user_id` 作为 Session 身份；调用方的
最终用户鉴权、会话归属和配额判断必须在进入 Runtime 前完成。Runtime 只认证
调用服务，`ManagedSessionPool` 的唯一 key 是 `session_id`。

## 2. 范围与设计分类

本文定义元数据发布、Session 建立、Context 组装、Manager 调用和 WebSocket
恢复的完整 Runtime 边界；它覆盖：

- 三类元数据到 Agent 运行目录的确定性映射；
- Agent cwd、Session 隔离和 WebSocket 握手；
- Session-scoped WebSocket v2、Frame、可选能力协商、追踪、结构化流事件、恢复和背压；
- 服务端 SessionTransport 端口与 WebSocket Adapter 的依赖倒置；
- Managed Prompt 与 pi-mono-java `Context` 的组装；
- Tool Manager 的逻辑工具发现和执行；
- Model Manager Provider 的模型选择和流式事件适配；
- 单 JVM 内多个 Agent 的隔离边界；
- 对 pi-mono-java 的目标适配点和验收要求。

本文只规定目标行为和适配边界，不交付以下实现：

- pi-mono-java Java 代码；
- 元数据管理服务；
- Tool Manager 或 Model Manager；
- WebSocket 客户端；
- 附件上传 REST API；
- 数据库表和管理界面。

用户“最多 50 个会话”等产品配额由上层会话服务执行，不是 CampusClaw
Runtime 的固定协议规则。上层删除会话时必须通过独立的 Session 生命周期
控制接口通知 Runtime 清理或归档；该控制接口不属于本 WebSocket 协议范围。

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

在固定基线 `fc85bdd…` 中，pi 将 systemPrompt、messages 和 tools 分开组装，
并通过摘要与 `read` 渐进加载 Skill；下表列出直接源码证据。

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

在固定基线 `1f7a542…` 中，pi-mono-java 按单一 cwd 创建 Session、加载
Prompt/Skill/Tool，并在 WebSocket 断开时 abort；下表列出直接源码证据。

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
| WebSocket 命令 | [`ChatWebSocketHandler.java#L195-L227`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ChatWebSocketHandler.java#L195-L227) | 当前使用 `prompt`、`steer`、`abort`、`new_session` 等 v1 命令，没有统一 req/res/event Frame |
| WebSocket 消息更新 | [`ChatWebSocketHandler.java#L422-L459`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ChatWebSocketHandler.java#L422-L459)、[`useChatWs.ts#L439-L448`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/frontend/src/composables/useChatWs.ts#L439-L448) | 当前 `message_update` 携带累计 Message，前端用新快照替换旧快照 |
| v1 协议文档 | [`docs/asyncapi/chat-ws.yaml#L1-L76`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/docs/asyncapi/chat-ws.yaml#L1-L76) | 当前 AsyncAPI 版本为 1.0.0，记录 query 握手、v1 命令和累计 Message 行为 |
| Agent 流事件 | [`MessageUpdateEvent.java#L17-L20`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/agent-core/src/main/java/com/campusclaw/agent/event/MessageUpdateEvent.java#L17-L20)、[`AgentLoop.java#L255-L276`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/agent-core/src/main/java/com/campusclaw/agent/loop/AgentLoop.java#L255-L276) | Java 内部事件同时保留累计 AssistantMessage 和细粒度 AssistantMessageEvent，v2 可直接映射后者 |
| Provider 扩展点 | [`ApiProvider.java#L31-L59`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/provider/ApiProvider.java#L31-L59)、[`ApiProviderRegistry.java#L54-L80`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/provider/ApiProviderRegistry.java#L54-L80) | Spring 可发现统一 ApiProvider，并按 `Api` 分发 |
| 调用元数据 | [`SimpleStreamOptions.java#L34-L45`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/types/SimpleStreamOptions.java#L34-L45) | 每次模型调用已有任意 metadata 字段可承载 Session 身份 |
| 模型流事件 | [`AssistantMessageEvent.java#L44-L164`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/stream/AssistantMessageEvent.java#L44-L164) | 已定义 start、text、thinking、toolcall、done、error 事件 |

### 3.3 OpenClaw Gateway

在固定基线 `b015925…` 中，OpenClaw Gateway Protocol v4 使用统一 Frame、
Gateway 多路复用、双层序列和权威恢复；下表列出本设计借鉴或明确不采用的
源码行为。

源码仓库：

```text
repository: https://github.com/openclaw/openclaw
commit:     b015925bc30f6a8363f290b07d5f8588e21422b8
```

| 主题 | 源码证据 | 观察到的行为 |
|---|---|---|
| 握手与 Frame | [`docs/gateway/protocol.md#L83-L168`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/docs/gateway/protocol.md#L83-L168)、[`frames.ts#L12-L198`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/packages/gateway-protocol/src/schema/frames.ts#L12-L198) | Gateway Protocol v4 使用 challenge/connect/hello；源码明确把 req/res/event 定义为 WebSocket envelope contracts，Request Frame 支持 `traceparent` |
| Chat 多路复用和精确订阅 | [`logs-chat.ts#L112-L168`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/packages/gateway-protocol/src/schema/logs-chat.ts#L112-L168)、[`protocol.md#L583-L588`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/docs/gateway/protocol.md#L583-L588) | `chat.send` 每次携带 `sessionKey`；同一 Gateway 连接可承载多个 Session，并可为一个 Session 精确订阅消息事件 |
| Chat delta | [`logs-chat.ts#L188-L252`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/packages/gateway-protocol/src/schema/logs-chat.ts#L188-L252)、[`server-chat.ts#L278-L296`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/src/gateway/server-chat.ts#L278-L296)、[`#L922-L944`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/src/gateway/server-chat.ts#L922-L944) | Protocol v4 的 Chat delta 同时支持 `deltaText`、可选累计 message 和 replace 语义 |
| 客户端恢复 | [`docs/gateway/clients.md#L111-L130`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/docs/gateway/clients.md#L111-L130) | 重连后恢复 Session 订阅、读取 `chat.history`、采用 `inFlightRun`，并按连接序列和 run 序列发现缺口 |
| 客户端 Transport | [`types.ts#L20-L33`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/packages/sdk/src/types.ts#L20-L33)、[`transport.ts#L73-L174`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/packages/sdk/src/transport.ts#L73-L174)、[`client.ts#L342-L438`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/packages/sdk/src/client.ts#L342-L438) | SDK 依赖 `OpenClawTransport.request/events/close`，WebSocket `GatewayClientTransport` 是可替换实现 |
| 服务端耦合和背压 | [`shared-types.ts#L110-L116`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/src/gateway/server-methods/shared-types.ts#L110-L116)、[`#L337-L353`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/src/gateway/server-methods/shared-types.ts#L337-L353)、[`ws-types.ts#L23-L26`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/src/gateway/server/ws-types.ts#L23-L26)、[`server-broadcast.ts#L293-L327`](https://github.com/openclaw/openclaw/blob/b015925bc30f6a8363f290b07d5f8588e21422b8/src/gateway/server-broadcast.ts#L293-L327) | Request Handler 已不接收 WebSocket，但服务器广播仍直接读取 `socket.bufferedAmount` 并调用 `socket.send/close` |

本设计借鉴 Frame、`traceparent`、有效能力声明、序列和权威恢复原则，但不复制
OpenClaw 的 Gateway 多路复用。CampusClaw 当前产品边界是 ToB 的
Session-scoped 连接：一个连接的认证、Agent 权限、Runtime Session、模型和
thinking 披露策略在握手后全部固定，减少跨 Agent 路由和审计歧义。这是产品
约束和安全加固，不是 WebSocket 协议本身的限制。OpenClaw 的
`OpenClawTransport` 是客户端端口；CampusClaw 的 `SessionTransport` 是
服务端逻辑会话通道，属于借鉴依赖倒置思想后的架构改造，不宣称为同一接口。

## 4. 目标组件与权威边界

上层服务创建或恢复 Session 时，Resolver 选择目录，Factory 组装 Agent，
Manager 执行模型与工具，Pool、Hub 和 Store 保存运行状态；下表明确每项数据
由谁掌握。

| 组件 | 权威数据 | 主要职责 |
|---|---|---|
| Agent 元数据服务 | Agent 定义、models、Skill/Tool 绑定和 Agent 权限 | 为目录编译、模型授权和工具授权提供 Agent 视角 |
| Skill 元数据或制品服务 | Skill 版本、name、description、content 或完整 `SKILL.md` | 提供可物化的 Skill 文档 |
| Tool Manager | Tool 描述、Schema、状态、source、permission、执行实现 | 发现、授权、校验并执行逻辑工具 |
| Model Manager | Model descriptor、状态、实际 Provider 路由和模型调用 | 校验 Agent-model 绑定并流式执行 |
| Runtime bundle compiler | 固定版本、展开依赖、验证并生成 Agent 目录 | 把元数据投影为 pi-mono-java 资源 |
| AgentDirectoryResolver | `agent_id` 到受控 cwd 的映射 | 阻止客户端选择任意工作目录 |
| ManagedAgentSessionFactory | 当前 Agent 的 Prompt、Skill、Model、Tool 和 Session 装配 | 每个 Session 创建独立 Agent |
| SessionTransportFactory | 不可变连接认证上下文 | 为每条物理连接创建独立的逻辑 Session 通道 |
| ManagedSessionTransport | connect 状态、Session 绑定、强类型请求和事件订阅 | 实现 `connect/request/events/close`，隔离应用语义与网络实现 |
| ChatWebSocketAdapter | WebSocket Frame、连接序列和网络流控 | 映射 Frame 与 Session 类型，处理首帧、Ping/Pong、1009 和 1013 |
| ManagedSessionPool | 全局唯一 `session_id` 到 Session 和 active run 的映射 | 内存隔离、恢复、Agent 绑定、运行所有权和淘汰 |
| ManagedRunHub | active run 的 partial Message、Tool、终态和 `run_seq` | 独立于连接持续维护恢复投影与游标，并为订阅者生成原子恢复点 |
| ConnectionAuthAdapter | 调用服务身份与 Manager audience 凭据 | 校验服务间 Bearer 或 mTLS 身份并避免凭据进入 Agent 数据 |
| Attachment service | REST 上传制品、Session 绑定和短期访问能力 | WebSocket 只引用上层已授权的 `attachment_id` |
| Runtime Session Store | JSONL 消息、Agent/Model 绑定和删除状态 | 按全局 `session_id` 持久化会话，不保存用户或租户身份 |

运行目录是 Manager 数据的模型披露投影，不是授权数据库。目录中的
`tool_id` 只告诉模型“可能使用什么”；Tool Manager 仍在每次发现和执行时
读取当前 Agent 绑定与权限。

![元数据到 Agent 运行目录映射](metadata_runtime_directory_mapping.svg)

[PlantUML 源码](diagram.puml#L1)

## 5. 元数据到运行目录映射

### 5.1 总体映射

目录编译器读取三类固定版本元数据，只把模型需要阅读的信息写入 Agent 目录，
并把 Schema、权限和运行状态留在 Manager；具体映射如下。

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

在选择 Agent 目录时，调用方只提交 `agent_id`，不提交 cwd；
`AgentDirectoryResolver` 将它验证为安全的单路径段并解析到受控根目录，
解析失败时拒绝当前 connect 或目录解析请求。编译器对 `skill.name` 执行相同
约束，不把任一标识的内容解释为路径，并至少执行：

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

编译器把 Agent 的业务指令写入 `<agent_instructions>`，把直接绑定的工具摘要
写入 `<agent_tools>`；模型因此只在初始 Prompt 中看到 Agent 级工具。文件按
以下固定结构生成：

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

Skill 服务可以提供结构化字段或完整 `SKILL.md` 制品；编译器每次只接受一种
输入，并把两种输入规范化为同一文件格式。

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

模型读取某个 Skill 后，只有在需要外部操作时才读取该 Skill 的
`references/tools.json`。编译器只把该 Skill 直接绑定的逻辑工具写入文件，
且读取结果不授予执行权限。文件格式固定为：

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

编译器从 `AGENT.binding_skills` 递归展开依赖，解析并校验所有版本后，再为
每个 Skill 独立生成目录。依赖展开路径为：

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

AgentLoop 每次调用模型时都构造一个原生 `Context`；在 Managed 模式下，它只
加入当前 Agent 的 SYSTEM、三个通用工具、Skill 摘要、cwd 和当前 Session
消息。结构仍为：

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
  = 当前 session_id 对应 JSONL 恢复的有效消息

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

Managed Prompt profile 只从当前 Agent 和当前 Session 的四个来源收集
Prompt，不遍历进程级、祖先级或其他 Agent 的上下文。当前 Java
`SystemPromptBuilder` 会追加默认园区文档和日期、OS、Java、Shell 等环境
信息，因此目标 profile 只允许：

1. 当前 Agent 的 `.campusclaw/SYSTEM.md`；
2. 当前 Session 的三个 AgentTool；
3. 当前 Agent 目录下的 Skill 摘要；
4. 当前 Agent cwd。

Managed profile 不追加进程环境明细。Legacy CLI 保持原有行为。

### 6.3 Session 创建和 Context

调用方完成 Upgrade 并发送 `connect` 后，服务端依次解析 Agent 目录、创建或
恢复 Session、加载 Context 来源并创建 Agent，再原子捕获 active-run 恢复点；
AgentLoop 在每轮模型调用时才构造最终 Context。connect 成功响应写出后，
客户端先收到其中的可选快照，再按顺序收到快照 cursor 之后的事件。

![Managed Session 与 Context 组装](managed_session_context_assembly.svg)

[PlantUML 源码](diagram.puml#L77)

创建顺序：

1. WebSocket Upgrade 建立不可变 `ConnectionAuthContext`；
2. `SessionTransportFactory.open(authContext)` 为当前连接创建
   `ManagedSessionTransport`；
3. `ChatWebSocketAdapter` 校验 Request Frame 和 `traceparent`，把首帧
   connect 映射为 `SessionConnectCommand`；
4. AgentDirectoryResolver 得到受控 `agentCwd`；
5. ManagedSessionPool 直接使用调用方提供的全局唯一 `session_id` 查找
   Session；服务认证上下文只参与连接授权和审计，不参与 Session key；
6. `mode=create` 校验上层提供的新 `session_id + agent_id + model_id` 并幂等
   建立绑定；`mode=resume` 校验已有 Session 的 Agent 和保存 Model；
7. ManagedAgentSessionFactory 加载当前 Agent SYSTEM 和 Skill，注册三个
   通用 AgentTool，并创建独立 Agent；
8. AgentLoop 在每轮把三个 AgentTool 投影为 `Context.tools`；
9. `connect()` 原子注册逻辑订阅、捕获 active-run 快照和事件 cursor；
10. Adapter 先发送 connect Response Frame，再订阅 `events()`；Publisher
    先排出 cursor 之后的暂存事件，再进入实时事件流。

## 7. Tool Manager 适配

### 7.1 通用工具接口

模型需要业务工具时，先把 `tool_id` 交给 `get_tool_info` 获取当前 Schema，
再把 `tool_id + parameters` 交给 `call_tool` 请求执行。模型可调用的 Schema
固定为：

```text
get_tool_info:
  input:
    tool_id: string

call_tool:
  input:
    tool_id: string
    parameters: object
```

`agent_id`、`session_id` 和调用服务身份来自服务端 SessionContext；其中
`session_id` 由 connect 接收后固化，Agent 与 Model 绑定来自已校验的
Managed Session。模型不能在 Tool 参数中指定或覆盖这些值。Runtime 不在
SessionContext 中建立 `tenant_id` 或 `user_id`；若 Tool Manager 需要调用方
下放的业务授权，只传递不可由模型修改的短期委托凭据或能力句柄，并由
Tool Manager 解释和执行。
`InvocationContext` 还携带从 `SessionInvocationMetadata` 继承的已校验
Trace Context，Tool Manager 调用创建子 span；该上下文不改变授权结果。

Java 侧逻辑接口：

```java
ToolDescriptor getToolInfo(
        String agentId,
        String toolId,
        InvocationContext context);

ToolExecutionResult callTool(
        String agentId,
        String sessionId,
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

两个通用 AgentTool 的 description 直接告诉模型如何发现和执行逻辑工具，
因此每个 Agent 不需要重复编写这套协议。

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

模型使用 Agent 直接工具时，可以立即根据 SYSTEM 中的 `tool_id` 查询 Schema；
模型使用 Skill 工具时，必须先读取 Skill 和对应的 `tools.json`，再发起查询和
执行。

![Tool 渐进式发现与执行](progressive_tool_discovery_execution.svg)

[PlantUML 源码](diagram.puml#L185)

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

Tool Manager 收到发现或执行请求后，先重新校验共同的授权前置条件：

1. Agent 存在且启用；
2. tool_id 当前绑定到该 Agent 或其可用 Skill；
3. Tool 存在且启用；
4. Agent、Skill、Tool 权限允许当前操作；
5. 调用服务及可选的短期委托能力满足执行策略；

`call_tool` 通过上述校验后，按执行边界完成两次 Schema 校验：

1. 调用工具前，校验 parameters 符合当前 input schema；
2. 工具返回后，校验执行结果符合 output schema。

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

Runtime 创建或恢复 Session 时调用 `resolveModel` 校验模型；每轮模型执行时
调用 `invoke`，Model Manager 再根据 Agent 绑定和模型状态选择真实 Provider。
逻辑接口为：

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

`ManagedAgentSessionFactory` 根据 Model Manager 返回的 descriptor 构造 Java
`Model`；AgentLoop 调用模型时，Provider 从本次 metadata 读取 Agent、Session
和 Trace Context 并转发请求。目标增加：

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
  "session_id": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
  "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
}
```

单例 Provider 不保存当前 Agent 身份，不使用 ThreadLocal，也不依赖
`SettingsManager.workingDir`。`traceparent` 必须来自 Adapter 已校验的
`SessionInvocationMetadata`；Provider 为 Model Manager 调用创建子 span，
不得从未校验的 Frame 字符串重建上下文。

### 8.3 流式事件

Model Manager 持续返回文本、thinking、ToolCall 和终态事件；Provider 将它们
一对一映射为 Java `AssistantMessageEvent`，AgentLoop 再执行返回的 ToolCall。

![Model Manager 流式调用](model_manager_streaming_flow.svg)

[PlantUML 源码](diagram.puml#L485)

具体映射如下：

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

调用方建立 WebSocket 时，每条连接只绑定一个 Session；不同 Session 使用不同
连接。首个 `connect` Frame 固定 `session_id + agent_id`，连接内同一时刻最多
执行一个主 run。

`/api/ws/chat` 直接提供版本 2，不为同一路由保留 v1 消息语义。连接关系为：

```text
one WebSocket connection
-> one authenticated connection context
-> one caller-provided session_id
-> one agent_id
-> zero or one active primary run
```

不同 Session 通过不同连接并发。同一 Session 可有多个经过相同
调用服务及 Agent 授权的观察连接；它们订阅同一个 `ManagedRunHub`，但
不会复制 run。任何有写权限的观察连接都可以在空闲时发起 `chat.send`，
或对指定 active `run_id` 执行 steer/abort。暂不设计多 Session 复用
Gateway，也不允许连接建立后切换 Agent 或 Session。

规范性协议为
[`chat-ws-v2.asyncapi.yaml`](chat-ws-v2.asyncapi.yaml)。本文解释架构与
取舍；字段约束、Schema 和示例以该文件为准。后续实施 Java 改造时，以该
文件替换 pi-mono-java 的 `docs/asyncapi/chat-ws.yaml`。

客户端实现顺序、完整 Happy Path、TypeScript dispatcher、Message reducer、
thinking、历史、断线恢复和错误动作矩阵集中在
[`Chat WebSocket v2 客户端接入指南`](chat-ws-v2-client-integration.md)。
直接连接 Runtime 的客户端是上层会话服务、服务端 SDK 或 CLI。浏览器原生
`WebSocket` 不能自由设置服务 Bearer Header，也不应获得 mTLS 私钥，因此浏览器
连接上层会话服务；上层服务若透传相同 Frame，浏览器可以复用指南中的 reducer，
但其 URL 和认证不属于本 Runtime 协议。

### 9.2 HTTP Upgrade、服务认证和首帧

调用方交给 WebSocket 客户端库的 URI 固定为：

```text
wss://api.example.com/api/ws/chat
```

调用方使用 `wss://api.example.com/api/ws/chat` 请求建立安全 WebSocket。
客户端库先建立 TCP/TLS 连接，再通过 HTTP opening handshake 协商切换协议；
服务端返回 `101` 后，WebSocket 才正式建立。

这里的 `connect("wss://...")` 是请求客户端库开始上述建连过程，不表示
WebSocket 已经建立，也不存在“先建立 WebSocket，再使用 HTTP Upgrade 升级”
的阶段。`wss` URI 向客户端库声明：目标 host 是
`api.example.com`、默认端口是 `443`、需要 TLS、握手 path 是
`/api/ws/chat`、最终目标协议是 WebSocket。

客户端库自动执行的真实顺序为：

```text
parse wss URI
  -> DNS resolve api.example.com
  -> open one TCP connection to port 443
  -> complete TLS or mTLS handshake
  -> send HTTP WebSocket Upgrade on that TLS connection
  -> receive HTTP 101 Switching Protocols
  -> WebSocket connection is established
  -> exchange WebSocket Frames on the same TCP/TLS connection
```

因此，WebSocket 连接真正成立的边界是收到 HTTP `101`，不是调用客户端库的
`connect(...)` 方法。HTTP opening handshake 使用同一 host、port 和 path，
所以可以把其 HTTP/TLS 目标理解为：

```text
https://api.example.com/api/ws/chat
```

但这只是同一地址的 HTTP/TLS 握手视角，不是第二个接口，也不是一个可用普通
GET/POST 调用的 RESTful 资源。调用方只需把 `wss://...` 交给 WebSocket
客户端库，由库完成 TCP、TLS、HTTP Upgrade 和后续协议切换；不能先调用一个
REST API，也不需要建立第二条连接。

以下是使用 Bearer 认证的 HTTP/1.1 握手请求示例；使用 mTLS 的部署在 TLS
握手阶段完成证书认证，可以不发送 `Authorization`：

```http
GET /api/ws/chat HTTP/1.1
Host: api.example.com
Authorization: Bearer ***
Connection: Upgrade
Upgrade: websocket
Sec-WebSocket-Version: 13
Sec-WebSocket-Key: <random-base64-key>
```

其中 `Connection`、`Upgrade`、`Sec-WebSocket-Version` 和
`Sec-WebSocket-Key` 属于 WebSocket opening handshake；示例中的
`Authorization` 属于 CampusClaw Bearer 服务认证。mTLS 在发送这些 HTTP
headers 之前的 TLS 握手中完成。普通 HTTP GET 即使 host 和 path 相同，只要
没有合法 Upgrade headers，也不得创建 Runtime Session。

Upgrade 成功时服务端返回：

```http
HTTP/1.1 101 Switching Protocols
Connection: Upgrade
Upgrade: websocket
Sec-WebSocket-Accept: <derived-value>
```

`101` 是协议边界：在它之前，通信仍是 HTTP，认证、路由或 Upgrade 校验失败
分别使用 `400`、`401`、`403` 或 `426` 等 HTTP 状态，不发送
`ResponseFrame` 或 WebSocket close code；在它之后，同一 TCP/TLS 连接只传输
WebSocket Text/Binary/Ping/Pong/Close Frames，业务失败使用
`ResponseFrame.error`，连接级失败使用 WebSocket close code。

WebSocket 使用 HTTP opening handshake，而不是另起一套裸协议握手，主要是
为了：

- 复用 `443`、TLS 证书、反向代理、负载均衡、防火墙和 API Gateway；
- 在 WebSocket 占用长连接之前，使用 HTTP Host、path、按配置提供的 Bearer
  或此前完成的 mTLS 以及状态码完成路由、认证、授权、限流及拒绝；
- 让客户端、服务端和中间代理通过 Upgrade/101 明确确认后续字节按 WebSocket
  Frame 解释，避免普通 HTTP 请求被误判；
- 在同一条 TCP/TLS 连接上从 HTTP opening handshake 切换到 WebSocket，避免
  再次建连。

三个阶段不能混淆：

| 阶段 | 线协议 | 负责内容 | 成功结果 |
|---|---|---|---|
| 传输握手 | TLS + HTTP WebSocket Upgrade | mTLS/Bearer、路由、Upgrade headers | HTTP `101` |
| 应用握手 | 第一个 WebSocket Text Frame：`connect` RequestFrame | 协议版本、可选 capability、session_id、Agent、Model | `connect` ResponseFrame |
| Session 交互 | 后续 WebSocket Frames | `chat.send`、事件、恢复和流控 | ResponseFrame/EventFrame |

所以 HTTP `Connection: Upgrade` 与 CampusClaw `method: "connect"` 没有字段或
生命周期上的继承关系：前者建立 WebSocket 传输，后者在已经建立的传输上绑定
Runtime Session。本文示例以常见的 HTTP/1.1 Upgrade 为规范表达；若入口使用
HTTP/2 extended CONNECT 并在代理层桥接，外部握手形式可以不同，但传输建立
后的 WebSocket Frame 和 CampusClaw 应用协议语义不得改变。

Upgrade URL 不接受 `agent_id`、`model_id`、`session_id`、token 或
其他业务查询参数。该端点是内部服务接口，不直接接受浏览器终端连接；浏览器
先连接上层会话服务，再由上层服务调用 Runtime。认证方式：

- 调用服务按部署配置使用 `Authorization: Bearer <token>` 或 mTLS；同时启用
  两者的部署可以执行更严格的双重校验；
- Bearer 或 mTLS 解析出的服务身份固化在不可变
  `ConnectionAuthContext`，业务 `tenant_id/user_id` 不进入该上下文；
- 外部 Bearer 只有在 Runtime audience 和 scope 均有效时才接受；调用
  Model/Tool Manager 时使用独立的 Manager audience 凭据或 token exchange；
- 凭据及其 hash 不进入 Prompt、JSONL、WebSocket 事件、异常详情或普通日志。

规范性 AsyncAPI 的 `server.security` 同时列出 Bearer 和 mTLS，表示部署可以
选择其中一种替代方案，而不是要求两者同时满足；要求双重校验的部署属于更
严格的入口策略。该口径遵循
[AsyncAPI 3.1 Server Object](https://www.asyncapi.com/docs/reference/specification/v3.1.0#server-object)
对 `security` 数组的定义。

客户端必须在收到 `101`、WebSocket 协议生效后的 5 秒内发送首个 JSON Text
Frame，且该 Frame 只能是：

```json
{
  "type": "req",
  "id": "connect-1",
  "method": "connect",
  "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  "params": {
    "mode": "create",
    "min_protocol": 2,
    "max_protocol": 2,
    "agent_id": "agent-a",
    "session_id": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
    "model_id": "model-a",
    "client": {
      "id": "campusclaw-session-service",
      "version": "1.0.0",
      "platform": "service"
    }
  }
}
```

这些错误发生在 `101` 之后，因此首帧超时或首帧不是 `connect` 时使用 1008
关闭。协议区间不包含版本 2 时，先返回 `UNSUPPORTED_PROTOCOL`，再使用
1002 关闭。

协议 2 固定使用 typed structured delta；它不是 capability，也不存在成功
连接后降级为累计 Message 或 `replace` 的路径。`capabilities` 可以省略，省略
等价于空数组。当前已知的可选增强只有 `full_thinking`；未知能力名允许携带，
但服务端忽略且不回显。客户端声明 `full_thinking` 不构成授权，也不会自动把
Session 设置为 full，仍需通过调用服务 scope、Agent、Model 和可选委托披露
上限的全部策略。

`session_id` 始终由上层会话服务提供，CampusClaw 不生成第二套 Runtime
Session ID。`mode=create` 必须提供 `session_id + agent_id + model_id`；
`session_id` 必须在 Runtime 部署范围内全局唯一。服务端幂等建立 Session，
固定 Agent 绑定，经
`AgentDirectoryResolver` 解析 cwd，并用 Model Manager 精确校验模型。
`mode=resume` 必须提供 `session_id + agent_id`：

- Session 不存在或已删除时返回 `SESSION_NOT_FOUND`，不得隐式重建；
- 省略 `model_id` 时读取保存的模型，并重新通过 Model Manager 校验；
- 显式提供相同 `model_id` 是幂等操作；
- 显式提供不同 `model_id` 表示切换模型；存在 active run 时返回
  `RUN_ACTIVE`，否则先校验再持久化 model change；
- 保存的 Session 固定 Agent 绑定必须与 `agent_id` 一致；不一致时以
  `FORBIDDEN` 拒绝，避免泄露 Session 是否绑定到其他 Agent。

`mode=create` 的重试对相同 `session_id`、`agent_id` 和 `model_id` 保持
幂等；create Response 在网络中丢失时，调用方在新连接上使用完全相同的
三个标识重试 `mode=create`，不直接改用可能返回 `SESSION_NOT_FOUND`
的 resume。同一 `session_id` 请求不同 Agent 绑定时拒绝。上层业务删除后，Runtime
记录删除状态，该 `session_id` 不得重新用于 `mode=create`。

成功的 connect Response 返回：

```json
{
  "type": "res",
  "id": "connect-1",
  "ok": true,
  "payload": {
    "protocol": 2,
    "connection_id": "conn-01",
    "agent_id": "agent-a",
    "session_id": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
    "model": {"model_id": "model-a", "name": "Model A"},
    "session": {"state": "idle", "thinking": "hidden"},
    "limits": {
      "max_message_bytes": 1048576,
      "max_connection_buffer_bytes": 4194304,
      "heartbeat_seconds": 20,
      "pong_timeout_seconds": 10,
      "connect_timeout_seconds": 5
    },
    "features": {
      "methods": [
        "chat.send",
        "chat.steer",
        "chat.abort",
        "chat.history",
        "session.get",
        "models.list",
        "model.set",
        "thinking.set",
        "prompt_templates.list",
        "skills.list"
      ],
      "events": [
        "run.started",
        "message.started",
        "message.updated",
        "tool.started",
        "tool.updated",
        "tool.completed",
        "message.completed",
        "run.completed"
      ],
      "capabilities": []
    },
    "active_run": null
  }
}
```

`features.methods` 由服务能力、调用服务授权和 Agent 配置共同过滤，但
`chat.history` 是快照恢复必备方法，每个成功 connect 的列表都必须包含；
调用服务无权读取投影历史时直接拒绝 connect。
`features.events` 必须按固定顺序返回上述全部八类 Chat 事件，不允许
缺少 `message.completed` 或 `run.completed` 等终态事件。
`features.capabilities` 只返回可选增强能力，合法结果可以是 `[]` 或
`["full_thinking"]`。这些列表用于发现和降级，不构成调用授权；动态
active-run 状态、附件归属以及 Model/Tool 权限仍在每次请求或执行时校验。

恢复时 `active_run` 包含 `run_id`、快照对应的 `run_seq/history_seq`、
冻结的 `model_id/thinking`、可为 null 的当前 `message_snapshot`、以
`content_index` 字符串为 key 的 `open_contents` 对象和 `active_tools`。
connect 成功后任何
试图再次调用 `connect` 或更换 Agent/Session 的请求都返回
`INVALID_REQUEST`；创建新
Session 必须由上层服务分配新的 `session_id` 并建立新连接。

### 9.3 Frame、追踪、标识符和命令

客户端使用 RequestFrame 发送命令；服务端为每个请求返回一个 ResponseFrame，
并通过 EventFrame 主动推送 run、消息和工具事件。所有文本帧均使用 JSON，
四类公共结构为：

```text
RequestFrame  = {type:"req", id, method, params?, traceparent?}
ResponseFrame = {type:"res", id, ok, payload? | error?}
EventFrame    = {type:"event", event, seq, payload}
Error         = {code, message, details?, retryable?, retry_after_ms?}
```

所有 Frame 都是封闭对象，未知顶层字段在进入 SessionTransport 前被拒绝。
`RequestFrame.id` 在物理连接的整个生命周期内唯一。客户端发送请求时保存
`id -> method + 成功 payload decoder`；connect 成功后可以并发多个请求，
Response 可以乱序并与 Event 交错。AsyncAPI 的 `x-method-contracts` 是 method
到成功 payload Schema 的规范映射。命令接受成功仅代表服务端已原子接受操作，
不代表 run 已完成。

一个完整 WebSocket UTF-8 Text Message 恰好承载一个 JSON Frame。允许底层
WebSocket fragmentation，但大小在解压和重组后按完整 JSON 的 UTF-8 字节数
计算；Binary Message 使用 1003 关闭，非法 UTF-8 或 JSON 使用 1007 关闭。

`EventFrame.seq` 在新连接第一条 EventFrame 上为 1，之后每成功写出一条事件
恰好加 1；ResponseFrame 不占用 seq，重连后重新从 1 开始。run 事件的
`payload.run_seq` 从 `run.started=1` 开始，由同一 run 的所有 Message 和 Tool
事件共同逐一递增，并跨重连连续。实时流上重复、倒退或跳号都触发恢复，客户端
不得猜测并继续归并。

connect Response 必须先于新连接上的任何 EventFrame。对发起 `chat.send` 的
连接，成功 Response 必须先于该 run 的 `run.started`；其他观察连接不受这个
局部排序约束。
本协议不增加 OpenClaw Gateway 全局快照使用的 `stateVersion`：Session-scoped
Chat 没有需要同步的全局 presence/health 状态，恢复以连接 `seq`、run
`run_seq`、active-run 快照和权威 Session 历史完成。

`traceparent` 是可选的 W3C Trace Context，最长 128 字符。Adapter 使用标准
解析器校验 version、trace-id、parent-id 和 flags；非法值返回
`INVALID_REQUEST`。合法上下文经不可变 `SessionInvocationMetadata` 传给
ManagedSessionTransport，并作为 Model Manager、Tool Manager span 的父上下文。
缺失时由服务端创建新 trace。该字段不进入 Prompt、JSONL、业务事件或普通
业务日志，也不接受 `tracestate` 或 `baggage` Frame 字段。

CampusClaw 的六类核心标识固定为：

| 标识 | 所有者 | 生命周期与职责 |
|---|---|---|
| `connection_id` | ChatWebSocketAdapter | 当前物理连接；重连后变化，不持有 Session 或 run |
| `session_id` | 上层会话服务 | Runtime 部署内全局唯一的持久上下文；跨连接和多个 run 保持，删除后不复用 |
| `agent_id` | Agent Manager | Session 创建时固定绑定，恢复时必须一致 |
| `model_id` | Model Manager | Session 保存当前值，每个 run 固化实际使用值 |
| `message_id` | CampusClaw | 一条持久化消息；完整 Message 统一使用该字段，不使用裸 `id` |
| `run_id` | CampusClaw | 一次模型和工具执行；断线期间及重连后保持 |

路由关系为：

```text
session_id
  -> immutable agent_id
  -> current model_id
  -> messages identified by message_id
  -> zero or one active run_id
  -> zero or more connection_id subscribers
```

`RequestFrame.id` 只是连接内 req/res 关联标识；`tool_call_id` 只关联一个 run
内的模型 ToolCall 与 Tool Manager 执行事件；`tool_id`、`attachment_id` 和
模板 ID 属于各 Manager 或资源服务。它们不扩展 Session 路由模型。

命令集固定如下：

| method | 关键参数 | 成功 payload 和约束 |
|---|---|---|
| `chat.send` | `message`、`attachment_ids[]`、`idempotency_key`、可选 `thinking` | 返回 `run_id + user_message_id + accepted`；同一 Session 已有主 run 时返回 `RUN_ACTIVE` |
| `chat.steer` | `run_id`、`message`、`idempotency_key` | 返回 `run_id + user_message_id + accepted + idempotent`，向指定 active run 注入消息，不新建主 run |
| `chat.abort` | `run_id`、`idempotency_key` | 显式终止 run；对同一 run 和 key 重复调用返回相同接受结果 |
| `chat.history` | 可选 `cursor`、`limit`、`run_id`、`through_history_seq` | 按服务端披露策略返回按 `history_seq` 排序的 Message/RunRecord 和下一游标；run/水位过滤用于 active-run 恢复 |
| `session.get` | 无 | 返回 Session、有效 Model、thinking 和 active-run 状态 |
| `models.list` | 无 | 调用 `listModels(agent_id)`，只返回当前 Agent 可用模型 |
| `model.set` | `model_id` | 调用 `resolveModel(agent_id, model_id)`；active run 期间拒绝 |
| `thinking.set` | `level` | 设置 Session 默认披露级别；active run 期间拒绝 |
| `prompt_templates.list` | 可选分页参数 | 返回当前 Agent 可见的模板摘要 |
| `skills.list` | 无 | 返回当前 Agent 已物化 Skill 的 name、description、location |

协议不提供连接内 `new_session`。`idempotency_key` 在当前
session_id/command 范围内判重；同 key 同负载返回原
结果，同 key 不同负载返回 `INVALID_REQUEST`。

`chat.send accepted=true` 的提交边界包含：用户消息已持久化、run_id 已分配、
active-run 占位已建立，run 所有权已经独立于 WebSocket。调用方可先用临时 ID
乐观展示用户消息，随后用 `user_message_id` 对齐权威历史。同一
idempotency_key 的等价重试必须返回同一 `run_id + user_message_id`，即使原
run 当前仍 active，也不能先返回 `RUN_ACTIVE`。Request 超时不证明服务端没有
执行；重试使用新的 RequestFrame id 和原 idempotency_key。

附件必须先经上层服务的 REST 接口上传。上层服务完成 tenant/user 归属、
扫描和业务授权，再把绑定当前 `session_id` 的 `attachment_ids` 交给 Runtime。
Runtime 在接受 `chat.send` 前只校验附件存在、未过期、与当前 `session_id`
绑定且可供当前 Agent 使用，不解析 tenant/user；客户端路径、URL 和二进制
内容不能替代 ID。

### 9.4 服务端 SessionTransport

HTTP Upgrade 成功后，`ChatWebSocketAdapter` 为该物理连接创建一个
`ManagedSessionTransport`。Adapter 负责网络，Transport 负责 Session 的
连接、请求、事件和关闭语义；目标接口为：

```java
interface SessionTransportFactory {
    SessionTransport open(ConnectionAuthContext authContext);
}

interface SessionTransport {
    CompletionStage<SessionConnectResult> connect(
            SessionConnectCommand command,
            SessionInvocationMetadata metadata);

    CompletionStage<SessionResponse> request(
            SessionRequest request,
            SessionInvocationMetadata metadata);

    Flow.Publisher<SessionEvent> events();

    CompletionStage<Void> close();
}
```

`SessionTransport` 是每条物理连接独占的服务端逻辑通道，状态机固定为：

```text
NEW -> CONNECTING -> CONNECTED -> CLOSED
```

- `SessionTransportFactory.open()` 只接收 Upgrade 产生的不可变认证上下文；
- `connect()` 只能成功一次，绑定 Agent/Session 并原子捕获恢复点；
- `request()` 只接受强类型 `SessionRequest`，在 connect 前或 close 后调用
  返回稳定状态错误；
- `events()` 是单订阅、有序且支持背压的 `Flow.Publisher<SessionEvent>`；
- `close()` 幂等，只解除连接订阅和有界缓冲，不 abort run。

`ManagedSessionTransport` 实现该接口并依赖 ManagedSessionPool、ManagedRunHub
和各 Manager。`ChatWebSocketAdapter` 消费接口，不实现接口：它负责 Upgrade
后的首帧计时、JSON Frame 编解码、请求 ID 关联、连接 `seq`、Ping/Pong、
完整 Text Message 大小限制、发送缓冲以及 close code。应用核心和
`SessionTransport` 类型中
不得出现 Spring `WebSocketSession`、`TextMessage` 或 WebSocket close code。

连接恢复时，`connect()` 在同一临界区内注册逻辑订阅、捕获 snapshot/cursor
并开始暂存后续事件。Adapter 成功写出 connect Response Frame 后才订阅
`events()`；Publisher 先重放 cursor 后的暂存事件，再进入实时流。该顺序在
不增加 `activate()` 方法的前提下消除快照与 delta 的竞态。

未来 REST + SSE 可以复用同一强类型 Session 契约并提供新的 Adapter，但本
版本只规范 WebSocket，不定义 SSE 端点、恢复 token 或 OpenAPI。

![服务端 SessionTransport 依赖倒置](managed_session_transport_dependency_inversion.svg)

[PlantUML 源码](diagram.puml#L424)

### 9.5 流式事件和 Message 投影

模型开始执行后，服务端按 run、Message 和 Tool 三条生命周期发送事件；实时
更新只携带本次 delta，完成事件才携带完整投影。事件族固定为：

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

这套 typed structured delta 是协议 2 的固有行为，不通过 capability 开启。
所有 v2 客户端都必须实现该事件模型；服务端不发送累计 AssistantMessage，
也不提供 OpenClaw 式 `replace` 分支。

每个 run 事件都携带 `agent_id`、`session_id`、`run_id`、
`run_seq` 和时间戳。Message 事件增加 `message_id`；内容更新增加
`content_index`。Tool 事件增加 `tool_call_id` 和逻辑 `tool_id`。

`message.updated.payload.update` 直接映射 Java
`AssistantMessageEvent`，允许的判别类型为：

```text
text_start / text_delta / text_end
thinking_start / thinking_delta / thinking_summary / thinking_redacted / thinking_end
toolcall_start / toolcall_delta / toolcall_end
```

`*_delta` 只携带本次增量，客户端按 `message_id + content_index` 组装，
不把增量当作完整 Message 替换。`message.completed` 携带经过披露策略投影
的完整最终 Message。`run.completed` 携带 `done`、`aborted` 或 `error`
结果，以及可用的 usage、stop reason 和结构化 Error；它是 run 的唯一
终态事件。

客户端归并规则固定为：

1. `message.started` 先按 `message_id` 创建 streaming Message；
2. 每个 `content_index` 独立遵循匹配类型的 `start -> delta* -> end`，不同
   index 可以交错；
3. `text_delta` 直接追加；`toolcall_delta` 是可能尚不合法的 JSON 文本片段，
   只累计不解析，最终以 `toolcall_end.arguments` 完整对象为准；
4. hidden thinking 在最终 Message 中保留不含正文的占位块，使后续
   `content_index` 不前移；`thinking_summary` 每块最多一次，是 Manager
   明确提供的完整安全摘要，客户端替换而不追加；
5. canonical thinking delta/summary 被当前连接抑制时，仍在相同
   `run_seq` 位置发送不含内容的 `thinking_redacted`，客户端只推进
   序列；
6. `message.completed.message` 按相同 message_id 整体替换本地 partial
   Message，不另插一条；
7. 一个 run 可以包含多个 Assistant Message 和多个 Tool 周期；每个已开始的
   Message 恰好有一个终态 `message.completed`；
8. 每个已发送 `tool.started` 的 Tool 在 `run.completed` 前恰好发送一次
   `tool.completed`，run 中止时未完成 Tool 使用 `status=aborted`；
9. `run.completed` 每个 run 恰好一次，必须最后发送，此后不再产生该 run 的
   事件。

Tool 既通过 Assistant Message 内的 `toolcall_*` 表示模型生成过程，也通过
`tool.started/updated/completed` 表示 Tool Manager 的实际执行过程。两者
使用相同 `tool_call_id` 关联，但不能混为一个事件。

完整客户端 reducer 和线协议示例见
[`客户端接入指南`](chat-ws-v2-client-integration.md#5-message-reducer)。

### 9.6 Thinking 披露

服务端在 run 开始时确定 thinking 披露级别，默认隐藏正文；调用方只能降低
已允许的级别，不能通过单次请求提升权限。披露级别固定为
`hidden < summary < full`：

- `hidden` 是默认值，不发送原始 thinking 或摘要正文；除
  `thinking_start/end` 外，被抑制的 canonical 内容更新使用不含正文的
  `thinking_redacted` 保持 `run_seq` 连续；
- `summary` 只发送 Model Manager 明确标记为安全的
  `thinking_summary`，每块最多一次且按完整值替换，不得由 CampusClaw
  从原始 thinking 合成；
- `full` 必须同时满足调用服务 scope、Agent 策略、Model 能力、可选委托披露
  上限和客户端 `full_thinking` capability；
- `full_thinking` 只是可选客户端能力声明，不自动把 Session 设置为 full；
- `thinking.set(full)` 在有效 capabilities 不包含 `full_thinking` 时返回
  `FORBIDDEN`，不得静默降级；
- `chat.send.thinking` 省略时继承当前连接看到的 Session 默认级别，只能把该
  级别调低，不能临时提升；高于允许级别同样返回 `FORBIDDEN`；
- 实时事件、connect 恢复快照、`session.get` 和 `chat.history` 使用同一个
  `ThinkingProjectionPolicy`，避免从恢复或历史旁路泄露。

请求的 thinking 级别在 run 开始时固化；每条观察连接再按其有效
capability 做只降低的投影。active-run 快照返回当前连接对该冻结级别的
有效结果。run 中途不允许 `thinking.set`；若服务授权或 Agent 策略在
执行中被紧急撤销，服务端终止 run 并按 error/aborted 收束，而不在同一
连接上无事件地切换投影。

### 9.7 run 所有权、重连和无竞态快照

WebSocket 断开时，Adapter 只取消当前订阅；AgentSession 和 AgentLoop 继续
执行 active run，`ManagedRunHub` 继续维护 partial Message、active tools、
`run_seq` 和恢复缓冲。调用方重连后从原子快照和后续 delta 恢复。

`ManagedSessionPool` 持有 AgentSession 和 active run，WebSocket 不持有 run；
连接关闭时不调用 `AgentSession.abort()`。run 只在以下
情况终止：正常完成、显式 `chat.abort`、Agent 或调用服务授权撤销、服务端有界
运行超时或进程故障。

`ManagedRunHub` 持续维护：

```text
run_id
last run_seq
persisted history_seq watermark
frozen model and thinking projection
partial projected Message or null
open content states
active tools
terminal outcome
bounded post-snapshot event buffer
```

恢复连接时，服务端在同一临界区内完成“注册订阅 + 捕获 cursor/snapshot”：

1. 为连接注册订阅并记录 Hub 当前 cursor；
2. 从同一状态版本生成 `active_run` 快照；快照同时固定已持久化的
   `history_seq`、run 的 Model 和当前连接有效 thinking 投影；run 已开始但
   Assistant Message 尚未
   开始时 `message_snapshot=null`，`open_contents` 记录已经 start、尚未 end
   的 text/thinking/toolcall 块；
3. 先发送 connect Response；
4. 再按 `run_seq > snapshot.run_seq` 顺序排出订阅缓冲中的事件。

因此快照和新 delta 之间没有丢失窗口，也不会重放已包含在快照中的 delta。
客户端收到 connect Response 后先缓冲新 EventFrame，调用
`chat.history(run_id=snapshot.run_id, through_history_seq=snapshot.history_seq)` 并读完
该过滤历史，恢复用户消息、先前完成的 Assistant Message 和 ToolResult；
然后应用 partial Message、open_contents 和 active_tools，最后按 `run_seq`
释放缓冲事件。
若 run 在断线期间已经结束，connect 返回 `active_run: null`，客户端通过
`chat.history` 读取按 `history_seq` 排列的终态 Message 和 RunRecord，对账
outcome、usage、stop reason 与 Error。初始排流忽略
`run_seq <= snapshot.run_seq`，只接受下一连续
值。客户端发现连接 `seq` 或单个 run 的 `run_seq` 重复、倒退或缺口时不得
猜测缺失文本，应停止归并并按上述流程恢复。

### 9.8 流控、心跳和错误

Adapter 只有在上一帧发送成功后才请求下一条事件；如果待发送数据超过预算，
它使用 `1013` 关闭 WebSocket 连接并取消该订阅，而 active run 继续执行。
服务端不得静默丢弃 delta，默认限制为：

| 限制 | 默认值 | 处理 |
|---|---:|---|
| 解压、重组后的单个 UTF-8 JSON Text Message | 1 MiB | 超限使用 1009 关闭 |
| 单连接待发送缓冲 | 4 MiB | 慢消费者使用 1013 关闭，客户端重连恢复 |
| 原生 Ping 间隔 / Pong 超时 | 20 秒 / 10 秒 | 超时关闭连接，只取消订阅，不终止 run |
| 首帧 `connect` | 5 秒 | 超时使用 1008 关闭 |

实际限制在 connect Response 的 `limits` 返回。业务命令失败优先使用
`res.ok=false`，不会因可恢复的请求错误关闭连接。稳定错误码至少包括：

```text
INVALID_REQUEST
UNAUTHENTICATED
FORBIDDEN
UNSUPPORTED_PROTOCOL
AGENT_NOT_FOUND
SESSION_NOT_FOUND
MODEL_REQUIRED
MODEL_NOT_ALLOWED
RUN_ACTIVE
RUN_NOT_FOUND
INVALID_ATTACHMENT
MANAGER_AUTH_FAILED
MANAGER_UNAVAILABLE
```

WebSocket Adapter 只在上一帧异步写入成功后向 `events()` Publisher 请求下一
条事件，使网络发送能力沿 Reactive Streams demand 反向形成背压。Publisher
和 Adapter 的待发送数据都必须计入同一个连接缓冲预算；预算耗尽时终止该
订阅并映射为 1013，不推进一个未成功发送的连接 `seq`。

Manager 认证失败不得把上游凭据或响应正文写入 `details`。`retryable` 和
`retry_after_ms` 只描述同一命令是否适合稍后重试；对可能产生副作用的命令，
客户端仍必须复用原 `idempotency_key`。

客户端按以下边界处理关闭：1000 默认不自动恢复；1002 停止重试并升级协议；
1003/1007/1008/1009 先修复消息、编码、策略或大小；1001、1011、1013 以及本地
观察到的异常断开 1006 使用带抖动的指数退避后 `mode=resume`。1006 不能作为
线上 Close Frame 发送。无论何种 Close，都不等于 `chat.abort`。

### 9.9 内存隔离

Runtime 只用全局唯一的 `session_id` 查找 `ManagedSession`；`agent_id` 是创建
后不可变的属性，不是第二个主键。ManagedSessionPool 的 key 为：

```text
session_id
```

`session_id` 由上层服务生成，在一个 Runtime 部署范围内全局唯一且删除后
不复用。`agent_id` 是 Session 创建后不可变的绑定属性，不是第二个 Session
主键：

```text
01ARZ3NDEKTSV4RRFFQ69G5FAV -> agent-a
01BX5ZZKBKACTAV9WEVGEMMVRZ -> agent-b
```

它们对应不同 AgentSession、Agent、cwd、Prompt、Skill、Model 和 Tool
调用上下文。Runtime 不接受仅在某个 tenant 或 user 内唯一的短 ID；服务身份
仍用于连接授权和审计，但不参与 Session key。若多个互不信任的上层服务共享
Runtime，应在入口或独立授权服务校验 `service_principal + session_id` 访问权，
而不是把业务 tenant/user 放回 SessionPool key。

### 9.10 JSONL 路径

Runtime 创建或恢复 Session 时，Session Store 按全局 `session_id` 定位记录，
并把 JSONL 物理存放在对应 Agent 子目录。存储结构为：

```text
<runtime-data-root>/
└── sessions/
    └── <agent-id>/
        └── <session-id>.jsonl
```

默认：

```text
<runtime-data-root> = ~/.campusclaw/agent
```

Session header 中的 cwd 写入当前 `agentCwd`。路径解析对 `agent_id` 和
`session_id` 使用相同的单路径段约束。`<agent-id>` 子目录只用于物理组织和
cwd 隔离，不参与 Session 主键；Session Store 必须按全局 `session_id` 查找
并校验保存的不可变 `agent_id`，不能通过遍历调用方提供的路径完成路由。

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

[PlantUML 源码](diagram.puml#L263)

## 10. pi-mono-java 目标适配点

实现 Managed WebSocket v2 时，Java 先把网络 Adapter 与 Session 逻辑拆开，
再按 Session 隔离 cwd、Agent、Model、Tool 和 run；下表列出各源码位置的目标
改造。

| 当前位置 | 目标改造 | 分类 |
|---|---|---|
| WebSocket Upgrade route | 不解析业务 query；校验服务间 Bearer 或 mTLS，创建不可变 ConnectionAuthContext；浏览器由上层服务承接 | 安全加固 |
| `ChatWebSocketHandler` | 拆为 `ChatWebSocketAdapter`；处理首帧、Frame、traceparent、连接 seq、Ping/Pong、完整 Message 大小限制和 close code | 架构改造 |
| `SessionTransportFactory` / `SessionTransport` | 新增服务端逻辑会话端口；每连接创建 `ManagedSessionTransport`，暴露 connect/request/events/close | 架构改造 |
| Frame DTO / validator | 以 AsyncAPI 2.4.0 生成或复用封闭 DTO；成功 Response 使用 payload，connect 返回有效 features | 架构改造 |
| `SessionPool` | 增加 Managed 路径；以全局唯一 session_id 为唯一 key、固定 Agent 绑定、按 Agent 组织 JSONL、run 独立于连接、移除单一 cwd 假设 | 架构改造 |
| `ManagedRunHub` | 新增；维护 partial Message、active tools、终态、run_seq 和原子恢复订阅 | 架构改造 |
| `ManagedAgentSessionFactory` | 新增；按 Session 加载受控 Agent 目录并创建独立 Agent | 架构改造 |
| `AgentSession.initialize()` | Managed 路径使用精确 cwd、三个通用 Tool、Manager Model 和 Managed Prompt profile | 架构改造 |
| `SystemPromptBuilder` | 增加 Managed profile，只组合允许的 Prompt 来源和 cwd | 安全加固 |
| `AgentTool` 实现 | 保留 read，新增 get_tool_info 和 call_tool；不注册业务 Tool | 产品约束 |
| `Api` / `ApiProviderRegistry` | 增加 MODEL_MANAGER Api 和 Spring Provider | 架构改造 |
| `Agent` stream options | 合并不可变 agent_id、session_id 和解析后的 Trace Context metadata | 架构改造 |
| model list/set/restore | 统一经过 Agent 范围的 Model Manager catalog | 安全加固 |
| Runtime WebSocket 客户端/SDK | 按客户端接入指南实现 connect、pending request、typed delta reducer、幂等与恢复 | 架构改造 |
| 浏览器 Web 前端 | 连接上层会话服务而非 Runtime；若上层透传相同 Frame，可复用 message_id/content_index reducer，但不得获得 Runtime 服务凭据 | 安全加固 |
| REST attachment service | 由上层服务完成用户归属和扫描，返回绑定 session_id 的 attachment_id 供 chat.send 引用 | 安全加固 |
| Legacy CLI | 保持原来的本地 Provider、Tool、Settings 和资源发现路径 | 兼容要求 |

Managed 路径不得修改共享 `SettingsManager.workingDir` 来表示当前 Agent。
Agent 身份必须来自不可变 SessionContext，避免并发 Session 互相覆盖。

## 11. 失败处理与安全边界

### 11.1 发布失败

编译器遇到以下任一问题时立即停止发布，并保留当前可运行目录不变：

- Agent、Skill 或 Tool 元数据 Schema 无效；
- Agent 未启用；
- 显式版本不存在，或省略版本无法唯一解析；
- Skill 依赖循环或 name 冲突；
- Skill 文档输入模式不唯一；
- frontmatter 与元数据不一致；
- 路径越界或符号链接越界；
- 绑定对象缺失、未启用、版本冲突或有效权限为 deny；
- Tool 摘要缺少 tool_id、name 或 description。

编译器始终在临时目录完成生成，只有全量校验成功后才原子替换当前目录。

### 11.2 建 Session 失败

服务端只有在 Upgrade、`connect`、Agent、Session 和 Model 全部校验成功后才
创建 Session；以下任一校验失败都返回明确错误，不留下部分状态：

- Upgrade 调用服务身份无效、Bearer audience/scope 不允许或 mTLS 校验失败；
- 首帧不是 connect、超时或协议版本不兼容；
- agent_id 非法或 Agent 目录不存在；
- SYSTEM 或 Skill 目录不可读；
- `mode=create` 缺少上层分配的 session_id、agent_id 或 model_id；
- `mode=resume` 的 Session 不存在或已删除；
- model_id 不属于当前 Agent；
- session_id 路径非法；
- Session 已绑定其他 Agent；
- 恢复 Model 当前已禁用或解除绑定；
- active run 存在时请求切换模型。

### 11.3 运行时失败

运行期间发生故障时，拥有该资源的组件负责终止或恢复：Tool Manager 返回
工具错误，Model Provider 结束模型流，WebSocket Adapter 只处理订阅和连接。

- Tool Manager 拒绝时，把结构化错误作为 ToolResult 返回模型；
- Model Manager 在流开始前失败时可按平台 retry policy 重试；
- 流开始后失败直接结束当前 Assistant turn；
- 取消信号同时停止模型流和当前 Tool 调用；
- WebSocket 断开只取消订阅，不取消模型流或 Tool 调用；
- 慢消费者使用 1013 断开，通过重连快照恢复，不丢弃 delta；
- Manager 认证错误清除敏感上游详情后映射为 `MANAGER_AUTH_FAILED`；
- Agent 目录更新只影响后续新 Session，运行中的 Session 保持创建时快照。

### 11.4 信任边界

调用方在 connect 阶段只能用 Session、Agent 和 Model 标识完成 Runtime
Session 绑定，不能提交 cwd；后续命令仍按各自 Schema 提交消息、附件等业务
参数。Runtime 负责解析目录、注入 Manager 上下文并限制文件和凭据边界。
具体约束为：

- connect 只能提供 session_id、agent_id 和 model_id，不能提供 cwd；
- session_id 由上层会话服务管理，必须在 Runtime 部署范围内全局唯一且删除后
  不复用；CampusClaw 只校验已有 Agent 绑定，不维护 tenant/user 归属；
- Agent 目录由部署程序写入，运行账号只读；
- read 限制在当前 Agent cwd 允许范围；
- Prompt 中的 tool_id 不构成授权；
- agent_id、session_id 和调用服务身份均由服务端注入 Manager 请求；可选业务
  委托授权以不可变短期凭据传递，不能由模型参数提供；
- Upgrade URL、Prompt、JSONL、事件和日志均不保存认证凭据；
- 实时、快照和历史共用 ThinkingProjectionPolicy；
- attachment_id 的 tenant/user 所有权由上层服务校验；Runtime 只校验其
  session_id 绑定、状态和 Agent 可用性；
- Tool Manager 和 Model Manager 是每次调用的最终权限执行点。

## 12. 测试与验收

实现必须通过目录、Context、Manager、多 Agent 和 WebSocket 五层验证；以下
用例共同证明可观察行为与本设计一致。

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
- 跨 Agent tool_id、未绑定、禁用、deny 和委托能力不足的调用被拒绝；
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

- `session_id` 在 Runtime 部署范围内全局唯一，重复 ID 不会因调用服务或业务
  用户不同而创建第二个 Session；
- 同一 `session_id` 只能绑定一个 Agent，跨 Agent 重绑定被拒绝；
- 两个 Agent 的 JSONL 路径不同；
- SYSTEM、Skill、cwd、Model 和 Tool 请求不串用；
- 并发创建 Session 不修改共享 workingDir；
- Agent A 的 Stream metadata 不会出现在 Agent B 的 Manager 请求。

### 12.6 WebSocket v2

- `wss://api.example.com/api/ws/chat` 经 HTTP/1.1 Upgrade 到同一 host/path，
  合法请求返回 `101`；缺少 Upgrade headers 的普通 HTTP GET 不创建 Session；
- `101` 前的认证或握手失败只返回 HTTP 状态，`101` 后的协议错误只返回 Frame
  error 或 WebSocket close code，二者不混用；
- HTTP Upgrade 成功不等于 CampusClaw connect 成功；服务端在收到首个
  `connect` RequestFrame 前不得创建或恢复 Runtime Session；
- `RequestFrame/ResponseFrame/EventFrame` 拒绝未知顶层字段，成功响应只允许
  `payload`，错误响应只允许 `error`；
- 缺失 `traceparent` 时创建新 trace；合法值传播到 Model/Tool Manager，
  非法值返回 `INVALID_REQUEST`，且任何 trace 字段不进入 Prompt 或 JSONL；
- 省略 capabilities、空数组和未知能力名都可以完成 connect；typed structured
  delta 始终生效且不出现在 capability 列表，未知值被忽略；
- `full_thinking` 只在客户端声明和全部授权同时满足时出现在有效 features；
  未生效时 `thinking.set(full)` 返回 FORBIDDEN 而不静默降级；
- connect 返回的 methods/capabilities 顺序稳定、无重复且按粗粒度
  授权过滤，但 methods 必须包含 `chat.history`；events 必须是顺序稳定、
  无重复的八类完整集合；列表披露不会
  绕过逐请求授权；
- `mode=create` 只接受上层提供的 `session_id + agent_id + model_id`，相同
  绑定重试幂等，create Response 丢失时在新连接上重试 create 而不是
  resume；不同 Agent 重绑定和已删除 ID 复用被拒绝；
- `mode=resume` 接受 `session_id + agent_id`，缺失 Session 返回
  `SESSION_NOT_FOUND`，并重新校验保存模型；
- Upgrade URL 中的业务 query 和 token 被拒绝，首帧 connect 的 5 秒约束
  生效；
- 合法服务 Bearer 或 mTLS 成功，无效 audience/scope、过期凭据和直接浏览器
  访问失败；
- 两个 Session 使用两个连接并发执行；同一 Session 多个观察连接
  只共享一个 active run；
- active run 期间重复 `chat.send`、`model.set`、`thinking.set` 返回
  `RUN_ACTIVE`；
- `chat.steer` 和 `chat.abort` 只作用于指定 active `run_id`，重复 abort
  保持幂等；
- `chat.send` 原子返回同一幂等结果的 `run_id + user_message_id`，发起连接先
  收到成功 Response 再收到 run 事件；Response 丢失后用新 request id 和原
  idempotency_key 能取得相同结果；
- `message.updated` 只携带本次 delta，不携带 OpenClaw 式累计 message 或
  replace；客户端可按 content_index 还原为
  `message.completed` 的最终 Message；
- text/thinking/toolcall 的 start/update/end 状态机、summary 完整替换、hidden
  占位块和 `thinking_redacted` 序列占位均可由 reducer 重现；
- 每个 `tool.started` 在 run 终态前恰好收到一次
  `tool.completed(done|error|aborted)`；一个 run 多 Message 和
  `message.completed` 权威替换均可对账；
- `SessionTransport` 状态机拒绝重复 connect、connect 前 request 和 close 后
  request；`events()` 只允许一个订阅者，`close()` 幂等；
- 使用假的 `SessionTransport` 可独立测试 WebSocket Frame 映射；使用假的
  Manager/Pool/Hub 可在不创建 WebSocket 的情况下测试
  `ManagedSessionTransport`；
- ManagedSessionPool、ManagedRunHub、AgentSession 和 SessionTransport
  不引用 Spring WebSocket 类型、`TextMessage` 或 close code；
- 断线期间 run 继续；冻结 Model/Thinking、history 水位、null
  message_snapshot、开放 text/thinking/toolcall 和 active tools 组成可恢复快照；
  客户端缓冲 post-snapshot 事件、读完水位历史后再释放，无丢失、无重复；
- run 在断线期间结束后，`chat.history` 返回带 history_seq 的终态 Message 和
  RunRecord，能够恢复 outcome、usage、stop reason 和 Error；
- history `has_more=true` 必须返回 next_cursor，false 时不返回；run/水位过滤在
  所有 cursor 页保持不变；
- hidden、summary、full 在实时、快照和历史中保持同一披露结果，未经 Manager
  标记的摘要不会输出；不同投影用 redacted 占位看到连续且可比的
  canonical run_seq；
- 未绑定当前 session_id、过期或不存在的 attachment_id 返回
  `INVALID_ATTACHMENT`；用户归属测试在上层会话服务完成；
- 客户端检测 `seq` 或 `run_seq` 重复、倒退或缺口后重连恢复，不拼接未知缺口；
- 一个 UTF-8 Text Message 对应一个 JSON Frame；Binary、非法 UTF-8/JSON、
  1 MiB 重组后 Message、4 MiB 缓冲、1003/1007/1009/1013 和 Ping/Pong
  行为可重复验证；
- Manager 身份交换失败和 Manager 不可用分别返回稳定错误，且错误中无凭据。

## 13. 设计验收标准

只有以下结果全部可以从实现和测试中观察到时，本设计才通过验收：

- 文档给出完整的元数据字段、文件和运行时消费者映射；
- cwd 只由 agent_id 经受控 Resolver 产生；
- Agent 运行目录能被 pi-mono-java 原生 SYSTEM 和 Skill 路径读取；
- Agent direct Tool 与 Skill Tool 保持两级渐进披露；
- 模型实际可执行工具固定为三个；
- 通用工具 description 完整表达发现和执行协议；
- Model 和 Tool Manager 分别是调用权威；
- Session 使用全局唯一 `session_id` 隔离，`agent_id` 是不可变绑定属性；
- Runtime 不维护 tenant_id/user_id；调用服务负责最终用户鉴权、Session 归属、
  配额和业务删除，服务身份不参与 Session key；
- 核心标识限定为 connection/session/agent/model/message/run 六类，并明确
  Request Frame `id`、`tool_call_id` 只是局部关联标识；
- WebSocket 首帧固定 Session，所有命令和事件使用封闭 Frame，成功响应使用
  `payload`，协议 2 固有使用结构化纯 delta，不依赖 capability 协商；
- 客户端接入指南能独立说明调用方角色、Happy Path、请求关联、typed delta
  reducer、thinking、历史、断线恢复、关闭码和重试动作；
- chat.send 的 user_message_id、Response/Event 顺序、seq/run_seq、开放内容快照
  和 RunRecord 历史形成可实现、可恢复的客户端契约；
- SessionTransport 以 connect/request/events/close 隔离 Session 应用语义和
  WebSocket 网络实现；
- traceparent 只进入遥测和下游 Manager 调用，有效 features 可发现但不构成授权；
- run 生命周期独立于连接，重连通过原子快照和 run_seq 恢复；
- 同一披露策略覆盖实时、快照和历史；
- 认证凭据不进入 Agent 数据和协议事件；
- Runtime JSONL 路径包含 agent_id，但物理目录不改变 session_id 唯一主键；
- Managed 和 Legacy 路径职责明确；
- 所有 Java 目标差异均标记为产品约束、安全加固或架构改造。

## 14. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.5.0 | 2026-08-03 | 新增客户端接入指南和客户端交互图；将 typed structured delta 固化为协议 2 语义，仅保留 full_thinking 可选能力；补齐 user_message_id、Response/Event 顺序、固定事件集、redacted thinking 序列占位、历史水位快照、Message/Tool reducer、RunRecord 历史、线协议大小与关闭恢复规则，并同步 AsyncAPI 2.4.0 |
| 1.4.3 | 2026-08-03 | 全文统一为“调用方或组件动作、服务端处理、可观察结果、约束与原因”的行为先行表述；统一既有 Bearer/mTLS 替代认证口径，保持 Frame、Schema 和源码证据不变，并同步 AsyncAPI 2.3.3 |
| 1.4.2 | 2026-08-03 | 明确 wss URI 是客户端建连指令而不是已建立的 WebSocket；补充 TCP、TLS、HTTP Upgrade、101 和 WebSocket Frame 的真实顺序及复用 HTTP 基础设施的原因；保留完整握手示例并同步 AsyncAPI 2.3.2 |
| 1.4.1 | 2026-08-03 | 明确 wss URI、HTTP/TLS 握手目标、HTTP/1.1 Upgrade headers、101 协议边界和首个 connect RequestFrame 的分层关系；同步 AsyncAPI 2.3.1 |
| 1.4.0 | 2026-08-02 | 收紧 Agent Runtime 边界：删除 tenant_id/user_id SessionScope 和直接浏览器认证，以全局唯一 session_id 作为唯一隔离键；调用服务负责用户归属与配额，Runtime 只做服务认证、Agent 绑定和 Session 执行；同步 AsyncAPI 2.3.0 |
| 1.3.0 | 2026-08-02 | 明确 CampusClaw 的 Agent Runtime 边界；以调用方管理的 session_id 替代目标协议中的 conversation_id，定义 create/resume、SessionScope 和 connection/session/agent/model/message/run 六类核心标识；同步 AsyncAPI 2.2.0 |
| 1.2.0 | 2026-07-31 | 以 OpenClaw Protocol v4 最新基线优化 WebSocket v2；统一 Frame/payload、增加 traceparent 与有效 features，并定义服务端 SessionTransport 依赖倒置 |
| 1.1.0 | 2026-07-30 | 定义 Session-scoped WebSocket v2、首帧 connect、Cookie/Bearer 认证、结构化 delta、run 独立生命周期、原子重连快照、thinking 披露、流控和规范性 AsyncAPI |
| 1.0.0 | 2026-07-29 | 初版；定义元数据到运行目录映射、三通用工具、Skill 渐进式披露、Model/Tool Manager 适配和单 JVM 多 Agent Session 隔离 |
