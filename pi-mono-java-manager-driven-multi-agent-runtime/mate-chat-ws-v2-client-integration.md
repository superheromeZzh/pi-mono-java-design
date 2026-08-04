# CampusMate 公共 Chat WebSocket v2 客户端接入指南

| 属性 | 值 |
|---|---|
| 文档版本 | 1.0.0 |
| 状态 | 目标协议接入指南，尚未实现 |
| 更新日期 | 2026-08-04 |
| Frame 协议号 | 2 |
| 公共 URL | `wss://api.example.com/mate-service/v1/ws/chat` |
| 规范性 Schema | [`mate-chat-ws-v2.asyncapi.yaml`](mate-chat-ws-v2.asyncapi.yaml)，1.0.0 |
| pi-mono-java 证据基线 | `1f7a5423219edfa4519d8719f1cc8a188ed72873` |

## 1. 这份接口解决什么问题

前端只连接 `mate-service`，不直接连接 `agent-service`：

```text
UI
  -> public WebSocket: mate-service
     -> Chat authentication, guardrails, intent and orchestration
     -> private WebSocket: agent-service
        -> Agent Runtime Session, model, tools and streaming run
```

![mate-service 与 agent-service 服务责任边界](mate_agent_service_responsibility_boundary.svg)

[PlantUML 源码：`mate_agent_service_responsibility_boundary`](diagram.puml#L89)

两项标识不要混淆：

- `chat_id` 是 mate-service 管理的业务 Chat。UI 用它展示 Chat 列表、恢复对话、
  上传附件和删除 Chat；一个用户最多拥有 50 个未删除 Chat。
- `session_id` 是 agent-service 内部 Runtime Session 标识。它由 mate-service
  生成并保存在私有映射中，永远不进入公共请求、响应或事件。

因此，公共客户端不需要先调用 REST 创建 Chat，也不生成 `chat_id` 或 Runtime
标识。第一次 WebSocket `connect(mode=create)` 完成 Chat 和 Runtime Session
的协同创建；后续使用 `connect(mode=resume, chat_id)` 恢复。

## 2. 客户端需要维护的状态

```text
physical socket
  socket_generation
  connection_id
  connection_generation
  next EventFrame.seq
  pending request map: id -> method/decoder/promise

business chat
  chat_id
  agent_id
  effective model
  effective thinking
  methods/events/capabilities

active run
  run_id
  next run_seq
  partial messages by message_id
  content blocks by content_index
  active tools by tool_call_id
```

`connection_id`、`connection_generation` 和 `seq` 都属于当前公共物理连接；重连
后重新取得。`chat_id`、`run_id`、`message_id` 和 `run_seq` 属于业务状态，
可以跨公共连接恢复。

建议状态机如下：

```text
DISCONNECTED
  -> SOCKET_CONNECTING
  -> APP_CONNECTING
  -> SYNCING
  -> READY_IDLE | READY_RUNNING
  -> RECOVERING
  -> CLOSED_FATAL
```

WebSocket `open` 只表示 HTTP opening handshake 已成功，客户端仍处于
`APP_CONNECTING`。只有 connect 成功并完成 active-run 快照同步后，才进入
`READY_IDLE` 或 `READY_RUNNING`。

## 3. 建立连接并创建 Chat

### 3.1 建立安全 WebSocket

把以下 URI 交给标准 WebSocket 客户端：

```text
wss://api.example.com/mate-service/v1/ws/chat
```

客户端库先建立 TCP/TLS 连接，再在同一连接上发送 HTTP WebSocket opening
handshake。服务端在返回 `101 Switching Protocols` 前，从现有网关认证上下文
取得用户身份并校验 Origin。不要把 token、用户 ID、Agent、Model 或 Chat 放到
URL 查询参数中。

浏览器示意代码：

```ts
const socket = new WebSocket(
  "wss://api.example.com/mate-service/v1/ws/chat",
);
```

浏览器会按 mate-service 的既有认证方案携带安全 Cookie；服务端 SDK 可以使用
既有 Gateway 客户端在 opening handshake 中建立 Bearer 身份。认证形式由现有
网关规范定义，凭据不进入 JSON Frame。

`101` 只说明 WebSocket 传输已经建立，不说明业务 Chat 已创建。收到 `open`
后，必须在五秒内发送首个 `connect` RequestFrame；connect 成功前不能发送
其他命令。

### 3.2 发送 create 首帧

```json
{
  "type": "req",
  "id": "connect-create-1",
  "method": "connect",
  "params": {
    "mode": "create",
    "min_protocol": 2,
    "max_protocol": 2,
    "agent_id": "agent_011CZkYqphY8vELVzwCUpqiQ",
    "model_id": "model_011CZq2GkV8aD4NwP7sLmXfR",
    "idempotency_key": "2ebc12d0-451a-4b9e-8b42-63c260cf5742",
    "client": {
      "id": "campusmate-web",
      "version": "1.0.0",
      "platform": "web"
    },
    "capabilities": []
  }
}
```

create 请求必须提供 `agent_id + model_id + idempotency_key`，不能提供
`chat_id`。`agent_id` 和 `model_id` 分别匹配
`^agent_[0-9A-Za-z]{24}$` 与 `^model_[0-9A-Za-z]{24}$`；它们大小写敏感且
不透明，客户端不得解析后缀或用 Provider 模型名代替 `model_id`。

connect 的 `idempotency_key` 用来处理“服务端已经创建成功，但成功响应在网络
中丢失”的情况。建立新物理连接后，使用新的 RequestFrame `id` 和完全相同的
Agent、Model、幂等键再次发送 create；mate-service 返回原 `chat_id`，不会再
占用一个 Chat 名额。相同键携带不同 Agent 或 Model 返回
`IDEMPOTENCY_CONFLICT`。

### 3.3 服务端实际完成的 13 个步骤

公共 create 不是简单转发。服务端按以下顺序完成责任：

1. mate-service 从 Upgrade 认证上下文取得用户身份。
2. mate-service 检查协议版本和封闭 Frame Schema。
3. mate-service 查询 connect 的幂等结果。
4. mate-service 检查该用户未删除 Chat 数量小于 50。
5. mate-service 校验 `agent_id` 可用且用户有权使用。
6. mate-service 校验 `model_id` 属于该 Agent 的允许集合。
7. mate-service 生成 `chat_id`。
8. mate-service 生成私有 Runtime Session 标识。
9. mate-service 保存状态为 `CREATING` 的 Chat 和私有映射。
10. mate-service 建立到 agent-service 的内部 WebSocket。
11. mate-service 发送内部 `connect(mode=create)` 和 Runtime 绑定信息。
12. agent-service 创建 Runtime Session 并返回内部成功响应。
13. mate-service 原子标记 Chat 为 `ACTIVE`、保存 connect 幂等结果，再返回公共
    connect 成功响应。

步骤 13 完成前，客户端不会收到公共成功响应。如果相同幂等请求仍在执行，
mate-service 返回可重试的 `CHAT_CREATING`；Runtime 暂时不可用时返回
`RUNTIME_UNAVAILABLE`，但不会披露内部连接或 Runtime 标识。

### 3.4 接收 create 成功响应

```json
{
  "type": "res",
  "id": "connect-create-1",
  "ok": true,
  "payload": {
    "protocol": 2,
    "connection_id": "conn-public-01",
    "connection_generation": 1,
    "chat_id": "chat_011CZy2QmR7vTf4KpN8sLxWd",
    "agent_id": "agent_011CZkYqphY8vELVzwCUpqiQ",
    "model": {
      "model_id": "model_011CZq2GkV8aD4NwP7sLmXfR",
      "name": "Model A",
      "reasoning": true,
      "input": {
        "modalities": ["text", "image", "document"],
        "attachment_media_types": [
          "image/png",
          "image/jpeg",
          "application/pdf",
          "text/plain"
        ],
        "max_attachments": 10,
        "max_attachment_bytes": 20971520,
        "max_total_attachment_bytes": 52428800
      }
    },
    "chat": {
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
      "methods": [
        "chat.send",
        "chat.steer",
        "chat.abort",
        "chat.history",
        "chat.get",
        "models.list",
        "model.set",
        "thinking.set"
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

客户端至少检查：

1. ResponseFrame `id` 与 connect RequestFrame `id` 相同；
2. `ok=true` 且 `protocol=2`；
3. `agent_id` 和 `model.model_id` 与 create 请求逐字节一致；
4. 保存服务端返回的 `chat_id`，不要自行生成或改写；
5. `features.methods` 和 `features.events` 包含准备使用的完整协议集合；
   events 是 Agent Channel 可能产生的事件类型，不表示每个请求都会产生全部事件；
6. `chat.state=idle` 当且仅当 `active_run=null`；
7. 响应中不存在 Runtime Session 标识、内部连接 ID 或内部 `seq`。

## 4. 发送消息并消费流式回答

### 4.1 发送消息

```json
{
  "type": "req",
  "id": "req-2",
  "method": "chat.send",
  "params": {
    "message": "查询订单 20260730001",
    "attachment_ids": [],
    "idempotency_key": "6f46bc26-8a14-4d63-b7b1-8f1f933a0d50"
  }
}
```

合法输入包括纯文本、纯附件和文本加附件；文本与附件不能同时为空。仅附件
请求不生成隐藏默认 Prompt。`attachment_ids` 的顺序参与幂等负载比较。

mate-service 只有在内部 Runtime 接受请求、公共幂等结果已经持久化后，才返回：

```json
{
  "type": "res",
  "id": "req-2",
  "ok": true,
  "payload": {
    "run_id": "run-01",
    "user_message_id": "message-user-01",
    "accepted": true
  }
}
```

所有改变 Chat 或 run 状态的成功 ResponseFrame 必须先于其因果 EventFrame。
例如，`chat.send` 的成功响应必须先于该 run 的 `run.started`。内部事件如果提前
到达，mate-service Bridge 会先暂存，写出公共成功响应后再按序释放。客户端
可以因此先建立 `run_id` 和权威用户消息，再归并后续事件。

### 4.2 最小文本事件流

每一行都是一个独立 WebSocket Text Message：

```jsonl
{"type":"event","event":"run.started","seq":1,"payload":{"chat_id":"chat_011CZy2QmR7vTf4KpN8sLxWd","agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","run_id":"run-01","run_seq":1,"timestamp":"2026-08-04T08:00:00Z","model_id":"model_011CZq2GkV8aD4NwP7sLmXfR","thinking":"hidden"}}
{"type":"event","event":"message.started","seq":2,"payload":{"chat_id":"chat_011CZy2QmR7vTf4KpN8sLxWd","agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","run_id":"run-01","message_id":"message-01","run_seq":2,"timestamp":"2026-08-04T08:00:00Z","role":"assistant"}}
{"type":"event","event":"message.updated","seq":3,"payload":{"chat_id":"chat_011CZy2QmR7vTf4KpN8sLxWd","agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","run_id":"run-01","message_id":"message-01","run_seq":3,"content_index":0,"timestamp":"2026-08-04T08:00:01Z","update":{"type":"text_start"}}}
{"type":"event","event":"message.updated","seq":4,"payload":{"chat_id":"chat_011CZy2QmR7vTf4KpN8sLxWd","agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","run_id":"run-01","message_id":"message-01","run_seq":4,"content_index":0,"timestamp":"2026-08-04T08:00:01Z","update":{"type":"text_delta","delta":"订单已发货"}}}
{"type":"event","event":"message.updated","seq":5,"payload":{"chat_id":"chat_011CZy2QmR7vTf4KpN8sLxWd","agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","run_id":"run-01","message_id":"message-01","run_seq":5,"content_index":0,"timestamp":"2026-08-04T08:00:02Z","update":{"type":"text_end"}}}
{"type":"event","event":"message.completed","seq":6,"payload":{"chat_id":"chat_011CZy2QmR7vTf4KpN8sLxWd","agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","run_id":"run-01","message_id":"message-01","run_seq":6,"timestamp":"2026-08-04T08:00:02Z","message":{"message_id":"message-01","role":"assistant","status":"completed","content":[{"type":"text","text":"订单已发货"}],"created_at":"2026-08-04T08:00:00Z","completed_at":"2026-08-04T08:00:02Z"}}}
{"type":"event","event":"run.completed","seq":7,"payload":{"chat_id":"chat_011CZy2QmR7vTf4KpN8sLxWd","agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","run_id":"run-01","run_seq":7,"timestamp":"2026-08-04T08:00:03Z","outcome":"done","stop_reason":"stop","usage":{"input_tokens":230,"output_tokens":48,"total_tokens":278}}}
```

`outcome=error` 必须携带普通结构化 `error`，`outcome=interrupted` 必须
携带 `code=RUN_INTERRUPTED` 的 `RunInterruptedError`；`done/aborted` 禁止携带
`error`。`RUN_INTERRUPTED` 是 run 终态原因，不是请求错误码。

`message.updated.payload.update.type` 的完整集合为：

| 类型 | 客户端动作 |
|---|---|
| `text_start` | 在 `content_index` 创建空文本块 |
| `text_delta` | 只追加本帧 `delta` |
| `text_end` | 关闭文本块 |
| `thinking_start` | 创建 hidden 或 full Thinking 块 |
| `thinking_delta` | 仅在有效 `full_thinking` 下追加原始 thinking |
| `thinking_redacted` | 只推进 `run_seq`，不创建可见正文 |
| `thinking_end` | 关闭 Thinking 块 |
| `toolcall_start` | 创建 ToolCall 参数缓冲 |
| `toolcall_delta` | 追加 JSON 文本片段，不逐帧解析 |
| `toolcall_end` | 用权威、脱敏后的 arguments 收束 |

`message.completed.payload.message` 是权威终态，客户端按 `message_id` 整体
替换本地 partial Message，不能再追加一条累计快照。`run.completed` 是该 run
的最后一个事件；看到它后清除 active run。

### 4.3 两层序列

- `EventFrame.seq` 由 mate-service 为当前公共连接生成，从 1 开始，重连后重置；
- `payload.run_seq` 属于业务 run，从 `run.started=1` 开始，跨公共和内部重连
  连续；同一 run 的 Message 和 Tool 事件共用一条序列。

任何重复、倒退或跳号都进入 `RECOVERING`，不能猜测缺失文本。hidden thinking
使用 `thinking_redacted` 占据 canonical `run_seq`，因此披露策略不会制造假缺口。

## 5. Frame dispatcher 与基础命令

公共 Frame 固定为：

```text
RequestFrame  = {type:"req", id, method, params?, traceparent?}
ResponseFrame = {type:"res", id, ok, payload? | error?}
EventFrame    = {type:"event", event, seq, payload}
```

ResponseFrame 不带 `method`。发送请求时，客户端必须在 pending map 保存
`id -> method + payload decoder`；并发 Response 可以乱序，也可以与 Event
交错。Request 超时不表示服务端没有执行；副作用请求使用新 request `id` 和原
`idempotency_key` 重试。

RequestFrame 可以携带最多 128 字符的 W3C `traceparent`。mate-service 校验后
创建服务端 span，并为内部 Runtime 调用创建子 span；客户端不能把业务身份、
凭据或任意 baggage 塞入该字段。无效 `traceparent` 返回
`INVALID_REQUEST`，且 trace 不进入 Chat 历史或 Prompt。

| method | 主要参数 | 成功 payload | 关键约束 |
|---|---|---|---|
| `chat.send` | message?、attachment_ids?、idempotency_key、thinking? | run_id、user_message_id、accepted | active run 时返回 `RUN_ACTIVE` |
| `chat.steer` | run_id、message、idempotency_key | run_id、user_message_id、accepted、idempotent | v1 只接受文本 |
| `chat.abort` | run_id、idempotency_key | run_id、accepted、idempotent | 重复调用幂等 |
| `chat.history` | cursor?、limit?、run_id?、through_history_seq? | items、next_cursor?、has_more | 权威持久历史 |
| `chat.get` | 无 | Chat、Model、active_run | 公共协议不提供 `session.get` |
| `models.list` | 无 | models、effective_model_id | 只返回当前 Agent 可用模型 |
| `model.set` | model_id | model | active run 时拒绝 |
| `thinking.set` | level | thinking | full 还需有效 capability |

当前 Chat 只允许一个主 run。active run 存在时再次 `chat.send` 返回
`RUN_ACTIVE`；`model.set` 和 `thinking.set` 也在 active run 期间拒绝。
`chat.send`、`chat.steer` 和 `chat.abort` 的同一幂等键仅能绑定一个规范化
业务负载；同 key 同负载返回原结果，同 key 不同负载返回
`IDEMPOTENCY_CONFLICT`。

| 操作 | 规范化业务负载 | 重试规则 |
|---|---|---|
| `connect(create)` | `agent_id + model_id` | 复用原 key；不会创建第二个 Chat |
| `chat.send` | `message`、有序 `attachment_ids`、`thinking` 省略状态/值 | 同负载返回原 `run_id + user_message_id` |
| `chat.steer` | `run_id + message` | 同负载返回原结果 |
| `chat.abort` | `run_id` | 同负载返回原结果 |

`RequestFrame.id`、`traceparent`、连接 ID、连接代次和 `seq` 不参与比较。
`message` 省略与空字符串等价，`attachment_ids` 省略与空数组等价，
但非空数组顺序参与比较；`thinking` 省略与显式值不等价。
接受前失败不占用 send/steer/abort 幂等键。

## 6. Thinking 披露

typed delta 是协议 2 的固定能力。可选 capability 只有 `full_thinking`。

默认 connect 省略 `capabilities` 或发送空数组，此时只使用 `hidden`：

```json
{"capabilities": []}
```

能够安全展示原始 reasoning content 的客户端可以声明：

```json
{"capabilities": ["full_thinking"]}
```

只有 connect 响应的 `features.capabilities` 也包含 `full_thinking` 时，客户端
才显示 full 选项并处理 `thinking_delta`。声明 capability 不会自动切换为 full，
还要调用：

```json
{
  "type": "req",
  "id": "thinking-1",
  "method": "thinking.set",
  "params": {"level": "full"}
}
```

第一版只有 `hidden/full`，没有 summary。hidden 块仍保留不含 `text` 的位置
占位，避免后续 `content_index` 前移。

## 7. 上传附件

文件正文通过 HTTPS/Object Storage 上传，WebSocket 只传
`attachment_ids`。公共客户端使用 `chat_id`，不需要私有 Runtime 标识：

```http
POST /mate-service/v1/chats/{chat_id}/attachments
GET /mate-service/v1/chats/{chat_id}/attachments/{attachment_id}
DELETE /mate-service/v1/chats/{chat_id}/attachments/{attachment_id}
```

上传的最短顺序是：

1. create 成功并保存 `chat_id`；
2. 使用 `POST /mate-service/v1/chats/{chat_id}/attachments` 上传一个文件；
3. 若返回 `202`，按 `Location` 轮询公共 GET；
4. 只有状态为 `READY` 时，把返回的原始 `attachment_id` 放入
   `chat.send.attachment_ids`；
5. WebSocket 不提交文件正文、URL、文件名、MIME、size、SHA-256 或 Base64。

mate-service 用 Upgrade 用户身份和 `chat_id` 校验业务 Chat，再在服务端解析
私有 Runtime 映射。`attachment_id` 格式正确不代表已经获得当前 Chat 的访问权。

## 8. 断线与恢复

WebSocket Close 不等于 Abort。公共连接断开只取消 UI 订阅，不隐式调用
`chat.abort`；已接受的 active run 可以继续在 agent-service 执行。需要停止时，
必须显式发送 `chat.abort`。

新 WebSocket 完成 Upgrade 后，用 `chat_id` 恢复：

```json
{
  "type": "req",
  "id": "connect-resume-1",
  "method": "connect",
  "params": {
    "mode": "resume",
    "min_protocol": 2,
    "max_protocol": 2,
    "chat_id": "chat_011CZy2QmR7vTf4KpN8sLxWd",
    "client": {
      "id": "campusmate-web",
      "version": "1.0.0",
      "platform": "web"
    }
  }
}
```

resume 不接受 `agent_id` 或 `model_id`。mate-service 从权威 Chat 记录读取保存的
Agent、Model 和私有 Runtime 绑定，建立新的内部 Runtime resume，再生成公共
快照。这样可以避免客户端用一个合法 `chat_id` 重新绑定其他 Agent 或 Model。

恢复算法：

1. 新公共连接的 `seq` 从 1 重新开始；connect 后先缓冲新事件；
2. 记录 `active_run.run_seq=N` 和 `history_seq=H`；
3. 调用 `chat.history(run_id, through_history_seq=H)` 读完快照水位历史；
4. 应用 `message_snapshot`、`open_contents` 和 `active_tools`；
5. 丢弃初始缓冲中 `run_seq<=N` 的重复，只从 `N+1` 顺序释放；
6. 任一序列缺口都放弃本次同步并重新 resume。

新的 resume 会递增公共 `connection_generation`，接管该 Chat 的唯一活动读写
连接，并用 `4409 CHAT_REPLACED` 关闭旧公共连接。客户端必须用本地
socket generation 忽略旧连接迟到的 callback。

内部 WebSocket 的连接 ID、generation、request id 和 `seq` 与上述公共值无关。
mate-service 遇到内部缺口时先停止公开可疑事件，使用 Runtime 快照和权威历史
对账，再继续生成公共事件；它不会把内部 Frame 原样透传给 UI。没有分布式
run owner 时，不承诺 agent-service Pod 故障后的 active run 无缝继续；权威历史
会把无法继续的旧 run 投影为 `interrupted`。

## 9. 公共和内部 WebSocket 的边界

| 语义 | 公共 UI → mate-service | 私有 mate-service → agent-service |
|---|---|---|
| 业务路由 | `chat_id` | Runtime Session 标识 |
| 身份 | 用户认证上下文 | mate-service 服务身份 |
| `connection_id` | mate-service 生成 | agent-service 独立生成 |
| RequestFrame `id` | UI 生成 | mate-service 独立生成 |
| EventFrame `seq` | mate-service 生成 | agent-service 独立生成 |
| `connection_generation` | 公共 Chat 接管代次 | Runtime 连接接管代次 |
| Ping/Pong、背压 | 公共连接独立 | 内部连接独立 |
| 业务关联 | `idempotency_key/run_id/message_id/run_seq` | 可在校验后保持业务关联 |

mate-service 的职责是协议终止和业务编排，不是透明 WebSocket 代理：

1. 解析并校验公共 Frame；
2. 从连接认证上下文执行用户和 Chat 鉴权；
3. 执行安全护栏、意图识别、会话管理和状态机；
4. 构造新的内部 RequestFrame；
5. 校验内部 Response/Event，映射稳定公共错误，移除私有字段；
6. 生成新的公共 ResponseFrame/EventFrame 和公共 `seq`。

这个入口固定为 Agent Channel。通过护栏、意图和状态机检查并被接受的
`chat.send` 一定会进入 agent-service，因此成功 payload 总有 Runtime 接受后
产生的 `run_id + user_message_id`。若状态机不选择 Agent 分支，mate-service
在接受前返回 `CHANNEL_NOT_APPLICABLE`，不发送 run/message/tool 事件；
前置阶段只能做校验、查询、路由和审计，不能产生用户可见副作用。其他 Channel 的业务响应
使用各自协议。

只有 `traceparent`、幂等键以及经过明确验证的业务 ID 可以跨跳传播。任何入站
凭据、内部 Header、Runtime 标识或内部路由信息都不能进入公共 Frame。

## 10. 错误和关闭处理

错误响应示例：

```json
{
  "type": "res",
  "id": "connect-create-2",
  "ok": false,
  "error": {
    "code": "CHAT_LIMIT_EXCEEDED",
    "message": "当前用户的未删除 Chat 数量已达到 50。",
    "retryable": false
  }
}
```

| code | 客户端动作 |
|---|---|
| `INVALID_REQUEST` | 修复 Frame 或字段，不原样热重试 |
| `UNAUTHENTICATED` | 刷新现有认证上下文后重新 opening handshake |
| `FORBIDDEN` | 停止重试并隐藏无权限功能 |
| `CHAT_NOT_FOUND` | 从 Chat 列表移除或刷新，不尝试猜测私有映射 |
| `CHAT_LIMIT_EXCEEDED` | 提示先删除旧 Chat；不要换幂等键绕过限制 |
| `CHAT_CREATING` | 使用同一 create 幂等键按 `retry_after_ms` 重试 |
| `CHANNEL_NOT_APPLICABLE` | 该请求不属于 Agent Channel；转用对应产品 Channel，不在本连接重试 |
| `IDEMPOTENCY_CONFLICT` | 同一键已经绑定其他业务负载；停止重试并修复调用方键管理 |
| `RUNTIME_UNAVAILABLE` | 保留业务负载和幂等键，退避后重试或 resume |
| `RUN_ACTIVE` | 等待终态，或 steer/abort 已知 run |
| `RUN_NOT_FOUND` | 调用 `chat.get` 或 `chat.history` 对账 |
| `INVALID_ATTACHMENT` | 移除引用并重新上传；不得探测其他 Chat 的附件 |
| `ATTACHMENT_NOT_READY` | 轮询附件状态，READY 后按原幂等负载重试 |
| `MODEL_NOT_ALLOWED` | 调用 `models.list` 后重新选择 |

公共客户端永远不处理内部 `MANAGER_AUTH_FAILED` 或 `MANAGER_UNAVAILABLE`；
mate-service 将这些错误脱敏投影为 `RUNTIME_UNAVAILABLE`。

常见 WebSocket Close：

| code | 客户端动作 |
|---|---|
| `1000` | 正常关闭，不自动重连 |
| `1001` | 服务端关闭或心跳超时，退避后 resume |
| `1002` | 协议不兼容，停止重试并升级客户端 |
| `1003` | 错误发送 Binary Message，改用 UTF-8 Text Message |
| `1007` | JSON 或 UTF-8 非法，修复编码 |
| `1008` | connect 超时或违反连接策略，修复请求或授权 |
| `1009` | 完整 Text Message 超过协商上限，缩小请求 |
| `1011` | 暂时性服务端错误，退避后 resume |
| `1013` | 消费过慢或 Bridge 暂不可恢复，退避后 resume |
| `4409` | 新连接已经接管 Chat；停止旧 socket 写入 |

一个完整 WebSocket Text Message 恰好包含一个 JSON Frame。默认完整消息上限
1 MiB、连接缓冲 4 MiB；服务端默认每 20 秒发送原生 Ping，客户端库应自动
回复 Pong。协议不定义应用层 JSON ping/pong，也不静默丢弃 delta。

## 11. 最小 TypeScript dispatcher

```ts
type PendingRequest = {
  method: string;
  decodePayload: (value: unknown) => unknown;
  resolve: (value: unknown) => void;
  reject: (error: unknown) => void;
};

const pending = new Map<string, PendingRequest>();
let socketGeneration = 0;
let expectedSeq = 1;

function onText(raw: string, generation: number) {
  if (generation !== socketGeneration) return;

  const frame = JSON.parse(raw) as { type: string };
  if (frame.type === "res") {
    const response = frame as ResponseFrame;
    const request = pending.get(response.id);
    if (!request) throw new Error("unknown response id");
    pending.delete(response.id);

    if (!response.ok) {
      request.reject(response.error);
      return;
    }
    request.resolve(request.decodePayload(response.payload));
    return;
  }

  if (frame.type === "event") {
    const event = frame as EventFrame;
    if (event.seq !== expectedSeq) throw new RecoverableGap();
    expectedSeq += 1;
    verifyRunSequence(event);
    applyTypedEvent(event);
    return;
  }

  throw new Error("server sent an unexpected frame type");
}
```

每次新物理连接都增加 `socketGeneration`、把 `expectedSeq` 重置为 1，并丢弃
旧 socket 的迟到 callback。`ResponseFrame` 不占用 `seq`。

## 12. 前端联调检查表

- 使用 `wss://api.example.com/mate-service/v1/ws/chat`，不直连 agent-service；
- opening handshake 不携带业务 query 或 URL token；
- WebSocket open 后五秒内首先发送 connect；
- create 提交 Agent、Model 和幂等键，但不提交 `chat_id` 或 Runtime 标识；
- create 成功后保存服务端生成的 `chat_id`，并确认响应没有 Runtime 私有字段；
- create 响应丢失时用新 RequestFrame.id、原 Agent/Model/幂等键重试；
- resume 只提交 `chat_id` 和客户端/协议信息，不重新声明 Agent/Model；
- pending map 用 request `id` 关联 method 和 payload decoder；
- 所有改变状态的成功 Response 先于因果 Event；
- typed delta 按 `message_id + content_index` 归并，不实现累计 Message 分支；
- `message.completed` 整体替换 partial Message；
- `seq/run_seq` 缺口触发 resume，不猜测缺失内容；
- active-run 快照先与水位历史对账，再释放缓冲事件；
- public close 不等于 abort；只有 `chat.abort` 显式停止 run；
- 只在有效 capability 回显后展示 full thinking；
- 附件公共路径使用 `/mate-service/v1/chats/{chat_id}/attachments`；
- WebSocket 只传 attachment ID，不传文件正文、URL、MIME 或 Base64；
- 能处理 `CHAT_NOT_FOUND/CHAT_LIMIT_EXCEEDED/CHAT_CREATING/IDEMPOTENCY_CONFLICT/RUNTIME_UNAVAILABLE`；
- 旧连接收到 `4409 CHAT_REPLACED` 后停止读写；
- UI 不持有、记录或展示内部连接 ID、内部 seq、Runtime 标识和内部认证信息。

## 13. 源码事实、目标设计与设计原因

pi-mono-java 固定基线的已观察行为是：

- `ServerMode` 当前从 WebSocket Upgrade query 读取 `conversation_id`：
  [`ServerMode.java#L377-L391`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ServerMode.java#L377-L391)；
- `ChatWebSocketHandler` 当前处理 v1 命令，并在断线时 abort：
  [`ChatWebSocketHandler.java#L168-L227`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ChatWebSocketHandler.java#L168-L227)；
- 当前 `message_update` 发送累计 Message，而前端用新快照替换旧快照：
  [`ChatWebSocketHandler.java#L422-L459`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ChatWebSocketHandler.java#L422-L459)、
  [`useChatWs.ts#L439-L448`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/frontend/src/composables/useChatWs.ts#L439-L448)；
- Java 内部已经提供 text/thinking/toolcall 细粒度事件，可作为 typed delta
  适配输入：
  [`AssistantMessageEvent.java#L44-L164`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/stream/AssistantMessageEvent.java#L44-L164)。

本文全部交互均为目标设计，尚未实现。与当前源码的差异分类如下：

- 产品约束：mate-service 管理用户 Chat、`chat_id` 和每用户最多 50 个未删除
  Chat；agent-service 只管理私有 Runtime Session。
- 安全加固：认证在 HTTP 101 前完成；公共 Frame 不披露 Runtime 标识、内部
  路由、凭据或内部连接状态。
- 架构改造：mate-service 终止公共协议并通过独立内部 WebSocket 调用
  agent-service；两跳的连接、请求、序列、代次、心跳和背压相互独立。

## 14. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-08-04 | 首版公共 mate-service 接入指南；定义服务端创建 Chat 的 13 步、chat_id 与私有 Runtime Session 边界、八个公共命令、Agent Channel 接受边界、typed delta、幂等负载、有界 Message/Tool/Error 投影、响应先于因果事件、附件公共路径、双 WebSocket Bridge 和断线恢复 |
