# CampusAgent Runtime WebSocket v2 开发者接入指南

> 本文是 `chat-ws-v2.asyncapi.yaml` 的简化接入说明，面向需要连接 CampusAgent Runtime 的内部服务客户端。
> 完整字段、约束和错误码以 [AsyncAPI 规范](chat-ws-v2.asyncapi.yaml) 为准。

| 属性 | 值 |
|---|---|
| 文档版本 | 1.1.0 |
| 更新日期 | 2026-08-05 |
| 协议号 | 2 |
| AsyncAPI 版本 | 2.12.0 |
| pi-mono-java 基线 | `1f7a5423219edfa4519d8719f1cc8a188ed72873` |

如果希望像 Swagger UI 一样先看 JSON、再展开字段约束，请直接打开
[`chat-ws-v2-docs/index.html`](chat-ws-v2-docs/index.html)。该页面由 AsyncAPI
自动生成，JSON 示例默认展开，Payload 和 Schemas 保留完整约束。

## 1. 适用范围

本文描述 `mate-service Runtime bridge` 或获授权的内部 SDK 如何连接 CampusAgent Runtime。

浏览器和最终用户不直接连接此接口。公共 Chat WebSocket 使用另一份协议，由 `mate-service` 负责将公共 `chat_id` 映射为内部 `session_id`。

当前 v2 是目标协议；pi-mono-java 当前基线尚未实现完整 v2。

## 2. 连接地址

生产环境：

```text
wss://agent-service.internal/agent-service/internal/v1/ws/chat
```

本地开发：

```text
ws://localhost:3000/agent-service/internal/v1/ws/chat
```

连接前使用公司现有的内部网关客户端完成服务身份认证。不要把身份、Session 信息或密钥放入 URL 查询参数。

HTTP `101 Switching Protocols` 只表示 WebSocket 传输建立，不表示 Runtime Session 已创建或恢复。

## 3. 最小客户端流程

```text
建立 WebSocket
  -> 发送 connect
  -> 等待 connect Response
  -> 发送业务 Request
  -> 关联 Response 和 Event
  -> 断线后使用 resume 恢复
```

客户端至少需要维护：

- 待处理请求表：`request id -> method`
- 当前 `session_id`、`agent_id` 和 `model_id`
- 当前 `connection_generation`
- 最近的事件 `seq`
- active run 的 `run_id`、`run_seq` 和局部消息状态

## 4. 首帧：创建或恢复 Session

WebSocket 打开后五秒内发送唯一的首个 `connect` RequestFrame。收到成功响应前，不要发送其他请求。

### 创建 Session

```json
{
  "type": "req",
  "id": "connect-1",
  "method": "connect",
  "params": {
    "mode": "create",
    "min_protocol": 2,
    "max_protocol": 2,
    "session_id": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
    "agent_id": "agent_011CZkYqphY8vELVzwCUpqiQ",
    "model_id": "model_011CZq2GkV8aD4NwP7sLmXfR",
    "client": {
      "id": "mate-service",
      "version": "1.0.0",
      "platform": "service"
    }
  }
}
```

`mode=create` 必须提供 `session_id`、`agent_id` 和 `model_id`。`session_id` 由上层服务生成，推荐使用 UUIDv7 或 ULID，并且删除后不得复用。

### 恢复 Session

```json
{
  "type": "req",
  "id": "connect-2",
  "method": "connect",
  "params": {
    "mode": "resume",
    "min_protocol": 2,
    "max_protocol": 2,
    "session_id": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
    "agent_id": "agent_011CZkYqphY8vELVzwCUpqiQ",
    "client": {
      "id": "mate-service",
      "version": "1.0.0",
      "platform": "service"
    }
  }
}
```

`resume` 只能恢复已存在的 Session；不存在时返回 `SESSION_NOT_FOUND`。如果同一 Session 已有活动连接，新连接会接管 Session，旧连接收到关闭码 `4409 SESSION_REPLACED`。

## 5. 最小 connect 响应

```json
{
  "type": "res",
  "id": "connect-1",
  "ok": true,
  "payload": {
    "protocol": 2,
    "connection_id": "conn-01",
    "connection_generation": 1,
    "agent_id": "agent_011CZkYqphY8vELVzwCUpqiQ",
    "session_id": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
    "model": {
      "model_id": "model_011CZq2GkV8aD4NwP7sLmXfR",
      "name": "模型 A",
      "input": {
        "modalities": ["text"],
        "attachment_media_types": [],
        "max_attachments": 0,
        "max_attachment_bytes": 0,
        "max_total_attachment_bytes": 0
      }
    },
    "session": {
      "state": "idle",
      "thinking": "hidden"
    },
    "limits": {
      "max_message_bytes": 1048576,
      "max_connection_buffer_bytes": 4194304,
      "heartbeat_seconds": 20,
      "pong_timeout_seconds": 10,
      "connect_timeout_seconds": 5
    },
    "features": {
      "methods": ["chat.send", "chat.history", "chat.abort"],
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

客户端应检查：

1. 响应 `id` 与请求一致。
2. `ok` 为 `true`。
3. `protocol` 为 `2`。
4. `agent_id` 和 `session_id` 与请求完全一致。
5. `features.methods` 包含要调用的方法。
6. `features.events` 包含完整八类事件。
7. `session.state` 与 `active_run` 一致：`idle` 对应 `null`，`running` 对应非空快照。

## 6. 发送文本消息

每次发送都生成新的 RequestFrame `id`，并生成一个可跨断线重试的 `idempotency_key`。

```json
{
  "type": "req",
  "id": "send-1",
  "method": "chat.send",
  "params": {
    "message": "查询订单 20260730001",
    "idempotency_key": "send-key-001"
  }
}
```

成功响应：

```json
{
  "type": "res",
  "id": "send-1",
  "ok": true,
  "payload": {
    "run_id": "run-01",
    "user_message_id": "message-user-01",
    "accepted": true
  }
}
```

`accepted=true` 表示用户消息已经持久化，并且 Run 已被接受。之后连接断开不会自动取消该 Run。

## 7. 发送附件消息

附件必须先由 Attachment Service 上传并获得 `attachment_id`。WebSocket 只提交引用：

```json
{
  "type": "req",
  "id": "send-attachment-1",
  "method": "chat.send",
  "params": {
    "message": "分析这个订单文件",
    "attachment_ids": ["attachment_011CZm8VpK4rNs6WtY2hDqfB"],
    "idempotency_key": "send-key-002"
  }
}
```

不要提交 URL、文件名、MIME、文件大小、Base64 或 OBS Object Key。纯附件消息可以省略 `message`，但 `attachment_ids` 必须非空。

## 8. 处理事件

典型事件顺序如下：

```json
{"type":"event","event":"run.started","seq":1,"payload":{"agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","run_id":"run-01","run_seq":1,"timestamp":"2026-07-30T08:00:00Z","model_id":"model_011CZq2GkV8aD4NwP7sLmXfR","thinking":"hidden"}}
{"type":"event","event":"message.started","seq":2,"payload":{"agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","run_id":"run-01","message_id":"message-01","run_seq":2,"timestamp":"2026-07-30T08:00:00Z","role":"assistant"}}
{"type":"event","event":"message.updated","seq":3,"payload":{"agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","run_id":"run-01","message_id":"message-01","run_seq":3,"content_index":0,"timestamp":"2026-07-30T08:00:01Z","update":{"type":"text_delta","delta":"订单已发货"}}}
{"type":"event","event":"message.completed","seq":4,"payload":{"agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","run_id":"run-01","message_id":"message-01","run_seq":4,"timestamp":"2026-07-30T08:00:02Z","message":{"message_id":"message-01","role":"assistant","status":"completed","content":[{"type":"text","text":"订单已发货"}],"created_at":"2026-07-30T08:00:00Z","completed_at":"2026-07-30T08:00:02Z"}}}
{"type":"event","event":"run.completed","seq":5,"payload":{"agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","run_id":"run-01","run_seq":5,"timestamp":"2026-07-30T08:00:03Z","outcome":"done"}}
```

实际 `message.completed` 会携带完整的权威 Message，实际 `run.completed` 会携带完整的 RunRecord。

客户端应：

- 按 `seq` 检查连接级事件是否跳号。
- 按 `run_seq` 检查当前 Run 是否跳号。
- 按 `message_id` 合并消息。
- 按 `content_index` 维护文本、thinking 和工具内容块。
- 以 `message.completed` 和 `run.completed` 作为权威终态。

## 9. 断线恢复

重连后发送 `connect(mode=resume)`。如果响应中的 `active_run` 不为空：

1. 暂存 connect 响应之后收到的新事件。
2. 使用快照中的 `run_id` 和 `history_seq` 调用 `chat.history`。
3. 应用历史中的已持久化消息和工具结果。
4. 应用 `message_snapshot`、`open_contents` 和 `active_tools`。
5. 只应用 `run_seq` 大于快照值的新事件。

历史请求示例：

```json
{
  "type": "req",
  "id": "history-1",
  "method": "chat.history",
  "params": {
    "run_id": "run-01",
    "through_history_seq": 41,
    "limit": 200
  }
}
```

如果 Pod 重启导致旧 Run 无法继续，历史会将其标记为 `interrupted`，错误码为 `RUN_INTERRUPTED`。客户端不要把它当作成功完成。

## 10. 常见错误处理

| 错误 | 含义 | 建议动作 |
|---|---|---|
| `UNSUPPORTED_PROTOCOL` | 双方没有共同协议版本 | 停止自动重试并升级客户端 |
| `SESSION_NOT_FOUND` | resume 目标不存在 | 检查 Session 映射，不要自动 create |
| `RUN_ACTIVE` | 当前 Session 已有活动 Run | 等待终态，或使用 steer/abort |
| `IDEMPOTENCY_CONFLICT` | 同一幂等键对应不同业务负载 | 生成新幂等键并检查调用逻辑 |
| `ATTACHMENT_NOT_READY` | 附件还未就绪 | 按 `retry_after_ms` 重试 |
| `ATTACHMENT_NOT_SUPPORTED` | 不符合模型输入策略 | 修改附件或切换支持该附件的模型 |
| `FORBIDDEN` | 当前身份或 capability 不允许 | 不要静默降级，修复权限或请求参数 |
| `RUN_INTERRUPTED` | Runtime 重启后 Run 无法继续 | 按中断终态展示，并由业务决定是否重新发送 |

请求超时或连接断开时：

- 使用新的 RequestFrame `id`。
- 对同一个业务操作复用原 `idempotency_key`。
- 不要因为看不到响应就立即创建第二个业务 Run。

## 11. 方法速查

| 方法 | 用途 |
|---|---|
| `connect` | 创建或恢复 Runtime Session，必须是首帧 |
| `chat.send` | 提交新的用户消息并创建 Run |
| `chat.history` | 读取权威持久历史，也用于恢复 |
| `chat.steer` | 向当前活动 Run 追加文本指导 |
| `chat.abort` | 请求停止当前活动 Run |
| `session.get` | 获取当前 Session 状态 |
| `models.list` | 获取可用模型摘要 |
| `model.set` | 在没有 active run 时切换模型 |
| `thinking.set` | 在没有 active run 时修改默认 thinking 披露级别 |

## 12. 规范来源

- [完整 AsyncAPI 规范](chat-ws-v2.asyncapi.yaml)
- [详细客户端接入指南](chat-ws-v2-client-integration.md)
- [Runtime Manager 设计说明](README.md)

## 13. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.1.0 | 2026-08-05 | 增加 AsyncAPI 2.12.0 元数据和生成 HTML 入口；JSON 示例默认展开，字段约束通过 Payload/Schemas 查看 |
| 1.0.0 | 2026-08-05 | 首版；提供连接、请求、事件、恢复和错误处理的最小接入路径 |
