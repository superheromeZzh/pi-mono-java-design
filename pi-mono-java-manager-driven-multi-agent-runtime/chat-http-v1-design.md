# CampusAgent Runtime HTTP API 设计

| 属性 | 值 |
|---|---|
| 文档版本 | 1.0.0 |
| 状态 | 目标设计，尚未实施 |
| OpenAPI | [`chat-http-v1.openapi.yaml`](chat-http-v1.openapi.yaml) |
| WebSocket 基线 | [`chat-ws-v2.asyncapi.yaml`](chat-ws-v2.asyncapi.yaml)，2.12.0 |
| pi-mono-java 源码基线 | `1f7a5423219edfa4519d8719f1cc8a188ed72873` |

## 1. 目标与边界

本文将现有内部 Runtime WebSocket v2 的能力改写为 HTTP API。它仍然只供
`mate-service` Runtime bridge 或获得授权的内部服务端 SDK 使用；浏览器继续连接
`mate-service` 公共协议，不直接访问 Runtime。

HTTP 请求是无状态的，`session_id` 放在资源路径中，认证由现有内部网关完成。
HTTP API 不暴露 WebSocket 的 `connection_id`、connection generation、Frame
`id` 或 close code，也不提供 URL token、业务查询参数身份和原始附件内容传输。

这是目标设计，不是现有 pi-mono-java 行为。现有基线在
`modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ServerMode.java`
（WebSocket 握手，基线 377-391）和 `ChatWebSocketHandler.java`（连接生命周期及
v1 命令，基线 115-227）中采用 WebSocket；本设计的 HTTP 资源模型属于架构改造。

## 2. HTTP 化决策

| WebSocket 语义 | HTTP 设计 |
|---|---|
| `connect` | `PUT /sessions/{session_id}`，以 `If-None-Match` 区分创建与恢复 |
| `chat.send` | `POST /sessions/{session_id}/runs`，返回 `202` 和 `run_id` |
| `chat.steer` / `chat.abort` | `POST /sessions/{session_id}/runs/{run_id}/steers` / `abort` |
| `chat.history` / `session.get` | `GET /sessions/{session_id}/history` / session |
| `models.list` | `GET /agents/{agent_id}/models` |
| EventFrame 流 | `GET /sessions/{session_id}/runs/{run_id}/events`，按 `after_seq` 轮询 |

`POST /runs` 只接受 `Idempotency-Key`。服务端允许模型调用和工具执行在客户端断线
后继续；客户端通过 Run、事件或历史接口恢复。建议事件轮询间隔 250-1000ms，并
使用 `ETag`/`Retry-After` 降低空轮询成本。

## 3. 一致性与安全

- Session 的 `agent_id` 和初始 `model_id` 形成不可变绑定；所有配置变更重新鉴权。
- 重复 `Idempotency-Key` 返回同一结果；相同键不同请求体返回 `409`。
- 不上传附件正文；`chat.send` 只提交 Attachment Service 签发的 `attachment_ids`。
- 认证沿用现有内部网关，本文不定义私有 Header、JWT claim 或密钥格式。
- 同一 Session 的并发写操作以 `expected_version` 或等价条件检查串行化。

主要状态码：`400` 参数非法，`401` 认证失败，`403` 无权访问，`404` 不存在，
`409` 绑定/幂等冲突，`412` ETag 失败，`413` 过大，`429` 限流，`503` 暂不可用。

## 4. 源码证据与差异分类

来源为 `pi-mono-java-manager-driven-multi-agent-runtime/chat-ws-v2.asyncapi.yaml`，
pi-mono-java 基线为 `1f7a5423219edfa4519d8719f1cc8a188ed72873`，相关源码路径为：

- `modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ServerMode.java`：握手边界；
- `modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ChatWebSocketHandler.java`：命令与连接生命周期；
- `modules/ai/src/main/java/com/campusclaw/ai/stream/AssistantMessageEvent.java`：结构化流事件。

保留 Session、Message、Run、附件引用和结构化增量，是产品约束与协议兼容性要求；
使用 HTTP 资源、`202`、游标事件查询和幂等键，是架构改造；认证细节不公开及禁止
直传附件，是安全加固。
