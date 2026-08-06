# CampusAgent Runtime HTTP API 设计

| 属性 | 值 |
|---|---|
| 文档版本 | 1.1.0 |
| 状态 | 目标设计，尚未实施 |
| OpenAPI | [`chat-http-v1.openapi.yaml`](chat-http-v1.openapi.yaml)，1.1.0 |
| WebSocket 语义基线 | [`chat-ws-v2.asyncapi.yaml`](chat-ws-v2.asyncapi.yaml)，2.12.0 |
| pi-mono-java 源码基线 | `1f7a5423219edfa4519d8719f1cc8a188ed72873` |
| 更新日期 | 2026-08-06 |

## 1. 结论

HTTP 版不是把全部命令收进一个 `/chat` 接口，也不是让调用方继续提交
WebSocket 的 `method + params` Frame。它是一组以 Session、Run、History、Event
和 Model 为资源边界的内部 API，共 13 个 operation。

调用方仍是 `mate-service` Runtime bridge 或明确获授权的内部服务端 SDK。
浏览器不直连 Runtime；公共 `chat_id` 仍由 mate-service 映射为内部
`session_id`。附件正文继续由 Attachment Service 承载，Runtime HTTP API
只接受 `attachment_ids`。

## 2. 接口分组

基础路径为 `/agent-service/internal/v1`。

### 2.1 Session 生命周期

| Method | Path | 语义 |
|---|---|---|
| `PUT` | `/sessions/{session_id}` | 使用调用方分配的 ID 幂等创建 Session |
| `GET` | `/sessions/{session_id}` | 读取 Session、当前模型及 active-run 快照 |
| `DELETE` | `/sessions/{session_id}` | 幂等请求删除 Session；停止新请求并异步清理 |

HTTP 没有 `connect(mode=resume)`。每个请求独立认证和定位 Session；网络恢复只需
重新读取 Session、Run 或 History。相同 `session_id + agent_id + 初始 model_id`
的 `PUT` 重试返回原 Session，不同不可变绑定返回 `409 SESSION_BINDING_CONFLICT`。
删除后的 `session_id` 永久禁止复用。

### 2.2 消息与 Run

| Method | Path | 语义 |
|---|---|---|
| `POST` | `/sessions/{session_id}/runs` | 提交用户文本/附件并创建异步 Run |
| `GET` | `/sessions/{session_id}/runs` | 分页列出 Run |
| `GET` | `/sessions/{session_id}/runs/{run_id}` | 读取 active 快照或权威终态 |
| `POST` | `/sessions/{session_id}/runs/{run_id}/steers` | 向 active Run 追加文本指导 |
| `POST` | `/sessions/{session_id}/runs/{run_id}/abort` | 幂等请求终止 Run |

`POST /runs` 原子持久化用户 Message、分配 `run_id` 并占用 active-run；成功返回
`202 Accepted`、`Location`、`run_id` 和 `user_message_id`。响应表示已接受，不表示
模型执行完成。`POST /runs`、Steer、Abort 和 Session 删除都必须携带
`Idempotency-Key`；相同键和相同规范化负载返回原结果，相同键不同负载返回
`409 IDEMPOTENCY_CONFLICT`。

### 2.3 事件与历史

| Method | Path | 语义 |
|---|---|---|
| `GET` | `/sessions/{session_id}/runs/{run_id}/events` | 读取 Run 的有序事件；支持 SSE 和 JSON 分页 |
| `GET` | `/sessions/{session_id}/history` | 按 `history_seq` 分页读取权威 Message/RunRecord |

事件接口按 `Accept` 提供两种同义视图：

- `text/event-stream`：实时消费；SSE `id` 等于 `run_seq`，断线后使用
  `Last-Event-ID` 恢复；
- `application/json`：使用 `after_run_seq` 分页补拉、批处理或对账。

HTTP 版不保留连接级 `seq`。`run_seq` 成为一个 Run 内唯一的权威事件游标；
为支持跨请求补拉，Runtime 必须持久化有界 Run Event Journal。这是相对现有
WebSocket 设计的架构改造。终态 Message 和 RunRecord 仍写入权威 History，
客户端不能仅依赖事件缓存恢复长期历史。

### 2.4 模型与 Session 配置

| Method | Path | 语义 |
|---|---|---|
| `GET` | `/sessions/{session_id}/models` | 列出当前 Agent 和调用身份可用模型 |
| `PUT` | `/sessions/{session_id}/model` | 切换 Session 当前模型 |
| `PUT` | `/sessions/{session_id}/thinking` | 修改默认 thinking 披露级别 |

模型列表使用 Session scope，而不是公开 `/agents/{agent_id}/models`，避免调用方
绕过 Session 绑定查询其他 Agent。Model/Thinking 变更只允许在没有 active Run
时执行，并要求 `If-Match` 携带最近一次 Session `ETag`；并发版本不一致返回
`412 PRECONDITION_FAILED`。

## 3. WebSocket 到 HTTP 的语义映射

| WebSocket v2 | HTTP v1 |
|---|---|
| `connect(mode=create)` | `PUT /sessions/{session_id}` |
| `connect(mode=resume)` | 无对应命令；重新 `GET` Session/Run/History |
| `chat.send` | `POST /sessions/{session_id}/runs` |
| `chat.steer` | `POST .../runs/{run_id}/steers` |
| `chat.abort` | `POST .../runs/{run_id}/abort` |
| `chat.history` | `GET /sessions/{session_id}/history` |
| `session.get` | `GET /sessions/{session_id}` |
| `models.list` | `GET /sessions/{session_id}/models` |
| `model.set` | `PUT /sessions/{session_id}/model` |
| `thinking.set` | `PUT /sessions/{session_id}/thinking` |
| EventFrame | SSE 或 JSON Run Event Journal |
| RequestFrame `id` | HTTP request ID/trace context，不参与业务幂等 |
| connection generation/close code | 删除；改用 HTTP 状态、ETag 和幂等键 |

## 4. 状态、并发与恢复

- 每个 Session 同一时刻只允许一个 active Run；冲突返回 `409 RUN_ACTIVE`。
- Run 接受后不依赖发起 HTTP 连接存活；连接关闭不等于 Abort。
- `GET Run` 返回 running 快照或 `done/aborted/error/interrupted` 终态。
- Pod 重启且原 Run 无法继续时，Message 和 RunRecord 对账为 `interrupted`，
  错误码为 `RUN_INTERRUPTED`。
- SSE 断线优先以 `Last-Event-ID` 继续；Event Journal 已过保留水位时返回
  `410 EVENT_CURSOR_EXPIRED`，客户端改用 Run 快照和 History 恢复。
- Session 读取响应返回 `ETag`；配置写入使用 `If-Match`，Run 副作用写入使用
  `Idempotency-Key`，两类机制职责不混用。

## 5. HTTP 状态与错误体

错误统一使用 `application/problem+json`，并增加稳定 `code`、`retryable`、
`retry_after_ms` 和有界 `details`。主要映射如下：

| HTTP | 典型 code |
|---|---|
| `400` | `INVALID_REQUEST` |
| `401` | `UNAUTHENTICATED` |
| `403` | `FORBIDDEN`、`MODEL_NOT_ALLOWED` |
| `404` | `SESSION_NOT_FOUND`、`RUN_NOT_FOUND` |
| `409` | `RUN_ACTIVE`、`IDEMPOTENCY_CONFLICT`、`SESSION_BINDING_CONFLICT` |
| `410` | `EVENT_CURSOR_EXPIRED` |
| `412` | `PRECONDITION_FAILED` |
| `413` | `REQUEST_TOO_LARGE`、`ATTACHMENT_NOT_SUPPORTED` |
| `422` | `INVALID_ATTACHMENT`、`ATTACHMENT_NOT_READY` |
| `429` | `RATE_LIMITED` |
| `503` | `MANAGER_UNAVAILABLE` |

错误不得包含凭据、内部 Header、私有 claim、Prompt、原始 thinking、OBS 地址、
Bucket、预签名 URL 或内部堆栈。

## 6. 安全与附件边界

- 内部 Gateway 在每个 HTTP 请求上建立不可变调用服务身份；`session_id` 不是凭据。
- Runtime 对每个请求重新校验 Session、Agent、Model 和动作权限。
- `traceparent` 使用标准 HTTP Header，不进入请求 JSON、Prompt 或数据库业务字段。
- `agent_id`、`model_id` 和 `attachment_id` 均大小写敏感且不透明。
- `POST /runs` 只接受文本、附件 ID 和 thinking；禁止 URL、MIME、文件名、
  Base64、OBS Object Key、tenant/user 字段。
- Runtime 仍通过 Attachment Service 的内部 resolve/content API 获取可信元数据
  和有界字节流，不直连 OBS。

## 7. 源码证据与差异分类

规范来源为仓库相对路径
`pi-mono-java-manager-driven-multi-agent-runtime/chat-ws-v2.asyncapi.yaml`，其声明的
pi-mono-java 基线为 `1f7a5423219edfa4519d8719f1cc8a188ed72873`。

| 分类 | 证据或决策 |
|---|---|
| 观察到的行为 | `modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ServerMode.java` 基线 377-391：当前使用 WebSocket Upgrade |
| 观察到的行为 | `modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ChatWebSocketHandler.java` 基线 115-227、422-459：v1 命令、断线生命周期和累计消息更新 |
| 观察到的行为 | `modules/ai/src/main/java/com/campusclaw/ai/stream/AssistantMessageEvent.java` 基线 44-164：结构化 provider 流事件 |
| 产品约束 | Session/Run/Message、附件引用、单 active Run、Manager 权威保持不变 |
| 安全加固 | 逐请求认证、Session-scoped 模型查询、附件只传 ID、统一脱敏 Problem |
| 架构改造 | 一组 HTTP 资源接口、ETag 并发控制、SSE/JSON Event Journal、异步 Session 删除 |

本文全部 HTTP 行为均为 target-only design，不得表述为现有 pi-mono-java 实现。

## 8. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.1.0 | 2026-08-06 | 将 HTTP 版重构为 Session、Run、事件/历史、模型配置四组共 13 个 operation；删除 connect/resume 与连接级状态，增加 SSE/JSON Event Journal、ETag 和 Session 删除语义 |
| 1.0.0 | 2026-08-05 | 初版 HTTP 映射草稿 |
