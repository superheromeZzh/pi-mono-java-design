# agent-service 内部 Runtime WebSocket v2 客户端接入指南

| 属性 | 值 |
|---|---|
| 文档版本 | 1.8.0 |
| 状态 | 目标协议接入指南，Java 尚未实现 |
| 更新日期 | 2026-08-05 |
| 协议号 | 2 |
| 规范性 Schema | [`chat-ws-v2.asyncapi.yaml`](chat-ws-v2.asyncapi.yaml)，2.12.0 |
| 快速接入 | [`chat-ws-v2-developer-guide.md`](chat-ws-v2-developer-guide.md) |
| 可浏览 HTML | [`chat-ws-v2-docs/index.html`](chat-ws-v2-docs/index.html) |
| Manager 设计 | [`README.md`](README.md)，1.13.1 |
| pi-mono-java 基线 | `1f7a5423219edfa4519d8719f1cc8a188ed72873` |

## 1. 先确定谁连接 Runtime

CampusAgent 是 Agent Runtime。直接连接
`wss://agent-service.internal/agent-service/internal/v1/ws/chat` 的客户端是
`mate-service` 的 Runtime bridge 或明确获授权的内部服务端 SDK，不是最终
用户浏览器，也不是普通业务前端。

```text
Agent UI
  -> mate-service public Chat WebSocket (chat_id)
     -> agent-service internal Runtime WebSocket (session_id)
```

opening handshake 在返回 `101` 前使用公司既有内部网关私钥/JWT
认证能力。本文只规定可观察行为，不复制私有 Header 或 claim；调用方
必须使用公司现有网关客户端生成认证上下文，不得传输私钥原文。
浏览器与 `mate-service` 之间使用独立公共协议，见
[`mate-chat-ws-v2.asyncapi.yaml`](mate-chat-ws-v2.asyncapi.yaml) 和
[`mate-chat-ws-v2-client-integration.md`](mate-chat-ws-v2-client-integration.md)。

mate-service 必须解析、授权、编排并重建 Frame，不能原样透传。公共协议只出现
`chat_id`；本内部协议只出现 `session_id`。两条连接的 `connection_id`、Request
`id`、Event `seq`、Ping/Pong、背压和 close code 都相互独立。

本文后续把直接连接 Runtime 的上层服务或 SDK 统一称为“客户端”。

## 2. 客户端需要实现什么

一个可用的 v2 客户端至少维护以下状态：

```text
connection
  local socket generation
  connection_id
  server connection_generation
  next expected EventFrame.seq
  pending RequestFrame map: id -> method/decoder/promise

session
  session_id
  agent_id
  effective model
  effective thinking level
  methods/events/capabilities

active run
  run_id
  next expected run_seq
  partial messages by message_id
  content blocks by content_index
  active tools by tool_call_id
```

客户端状态机为：

```text
DISCONNECTED
  -> SOCKET_CONNECTING
  -> APP_CONNECTING
  -> SYNCING
  -> READY_IDLE | READY_RUNNING
  -> RECOVERING
  -> CLOSED_FATAL
```

- WebSocket `open` 只进入 `APP_CONNECTING`，还不能发送 Chat 命令；
- `connect` 成功响应写出后进入 `SYNCING`；active run 存在时，先缓冲
  post-snapshot 事件，按快照 `history_seq` 同步已持久化历史，再应用
  partial Message/open contents/active tools，最后释放缓冲事件；
- 快照应用完成后，根据 `active_run` 进入 `READY_IDLE` 或 `READY_RUNNING`；
- 可恢复断线进入 `RECOVERING`；认证永久失败或协议不兼容进入
  `CLOSED_FATAL`；
- 每次新建物理连接都增加本地 socket generation，旧连接迟到的 callback
  必须忽略。

![客户端接入与恢复流程](frontend_websocket_client_integration.svg)

[PlantUML 源码：`frontend_websocket_client_integration`](diagram.puml#L663)

## 3. 最短可运行流程

### 3.1 建立安全 WebSocket

客户端把以下 URI 交给公司现有内部网关 WebSocket 客户端：

```text
wss://agent-service.internal/agent-service/internal/v1/ws/chat
```

其中 `/agent-service` 是 Gateway 路由前缀，`/v1` 是服务 API 版本，
`/ws/chat` 是 Chat WebSocket 通道。这与首帧协商的 Frame
`protocol: 2` 不是同一个版本号。

以下为行为级伪代码。`internalGateway` 代表公司已有客户端，不是本文
新定义的 SDK：

```ts
const socket = await internalGateway.openWebSocket({
  url: "wss://agent-service.internal/agent-service/internal/v1/ws/chat",
  audience: "agent-service",
});
```

客户端库建立 TCP/TLS 连接并执行 HTTP WebSocket opening handshake。服务端
返回 HTTP `101 Switching Protocols` 后，WebSocket 才正式建立。`101` 只表示
传输建立，不表示 Runtime Session 已经创建或恢复。

握手失败发生在 `101` 之前，使用 HTTP 状态表达：

| HTTP 状态 | 含义 | 客户端动作 |
|---|---|---|
| `400` | opening handshake 或 URL 不合法 | 修复请求，不自动热重试 |
| `401` | 内部网关认证上下文无效或过期 | 按既有网关客户端流程刷新后重试 |
| `403` | 调用服务无权访问 `agent-service` | 停止重试并修复授权 |
| `426` | 请求不是受支持的 WebSocket Upgrade | 修复代理或客户端配置 |

### 3.2 首帧创建 Session

收到 WebSocket `open` 后五秒内发送一个 UTF-8 Text Message，其中只包含以下
JSON RequestFrame：

```json
{
  "type": "req",
  "id": "req-1",
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

`session_id` 由上层会话服务提前生成，推荐 UUIDv7 或 ULID。`mode=create` 必须
提供 `session_id + agent_id + model_id`。结构化 typed delta 是协议 2 的固定
消息语义，客户端无需为 typed delta 声明 capability。
内部 connect 不携带 `idempotency_key`；它依靠 `session_id` 定位资源，
并以 `agent_id + 初始 model_id` 作为不可变绑定实现资源幂等。

`agent_id` 必须匹配 `^agent_[0-9A-Za-z]{24}$`，`model_id` 必须匹配
`^model_[0-9A-Za-z]{24}$`；两者均为大小写敏感、总长 30 的不透明
资源 ID。调用方应保留 Agent 元数据服务和 CampusModel/model-service
返回的原值，不自行生成、转小写、解析后缀或依赖排序特征。
`model_id` 是 CampusModel 资源 ID，不是 `claude-sonnet-4-6` 等
Provider 模型名；两者的映射由 Model Manager 保存。

连接成功响应为：

```json
{
  "type": "res",
  "id": "req-1",
  "ok": true,
  "payload": {
    "protocol": 2,
    "connection_id": "conn-01",
    "connection_generation": 1,
    "agent_id": "agent_011CZkYqphY8vELVzwCUpqiQ",
    "session_id": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
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
      "methods": [
        "chat.send",
        "chat.steer",
        "chat.abort",
        "chat.history",
        "session.get",
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

客户端必须检查：

1. ResponseFrame `id` 等于 `req-1`；
2. `ok=true`；
3. `protocol=2`；
4. 返回的 `agent_id/session_id` 与请求按原始大小写完全一致；`mode=create` 或
   resume 显式请求切换 Model 时，`model.model_id` 也必须与请求完全一致；
   resume 省略 `model_id` 时，接受服务端保存且通过 Schema 的有效值并更新本地状态；
5. `features.methods` 包含准备调用的方法，并且必须包含恢复所需的
   `chat.history`；
6. `features.events` 按规范顺序包含全部八类 Chat 事件；它是不可拆分的
   协议集合，缺少 `message.completed` 或 `run.completed` 时必须终止连接；
7. `model.input` 至少包含 text；上传前按 MIME、数量、单文件和总字节上限
   预检，但不把客户端预检当作 Runtime 授权；
8. `session.state=idle` 当且仅当 `active_run=null`。

connect 成功前不得发送其他 RequestFrame。connect 失败后，这条未绑定连接会
关闭；客户端不能继续复用它。

### 3.3 发送用户消息

创建一个新的 RequestFrame `id` 和一个可跨重连复用的 `idempotency_key`：

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

另外两种合法形态是仅附件和文字加附件：

```json
{
  "type": "req",
  "id": "send-attachments-only-1",
  "method": "chat.send",
  "params": {
    "attachment_ids": ["attachment_011CZm8VpK4rNs6WtY2hDqfB"],
    "idempotency_key": "b6f3c75f-6c66-4b30-830b-98094365cf84"
  }
}
```

```json
{
  "type": "req",
  "id": "send-text-attachments-1",
  "method": "chat.send",
  "params": {
    "message": "分析附件中的订单数据",
    "attachment_ids": ["attachment_011CZm8VpK4rNs6WtY2hDqfB"],
    "idempotency_key": "78230de7-7f45-454e-955a-61009bc207e0"
  }
}
```

`message` 省略或为空字符串时，`attachment_ids` 必须非空；二者同时为空
返回 `INVALID_REQUEST`。仅附件消息不生成隐藏默认 Prompt。

服务端原子完成“持久化用户消息、分配 run、占用 active-run”后，先向发起连接
发送成功 ResponseFrame：

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

客户端可以先用临时 ID 乐观展示用户消息，收到响应后必须用
`user_message_id` 替换临时 ID。同一 `idempotency_key` 的等价重试返回相同
`run_id + user_message_id`。

`chat.send` 成功 ResponseFrame 保证先于该 run 的 `run.started`。同样，
所有会改变 Session/run 状态的成功 ResponseFrame 都先于由该请求引起的
EventFrame。同 Pod 中一个 Session 只有一个活动读写连接，没有观察
连接的排序例外。

### 3.4 消费一次完整文本回答

最小无工具回答的事件顺序如下。每一行都是一个独立 WebSocket Text Message：

```jsonl
{"type":"event","event":"run.started","seq":1,"payload":{"agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","run_id":"run-01","run_seq":1,"timestamp":"2026-07-30T08:00:00Z","model_id":"model_011CZq2GkV8aD4NwP7sLmXfR","thinking":"hidden"}}
{"type":"event","event":"message.started","seq":2,"payload":{"agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","run_id":"run-01","message_id":"message-01","run_seq":2,"timestamp":"2026-07-30T08:00:00Z","role":"assistant"}}
{"type":"event","event":"message.updated","seq":3,"payload":{"agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","run_id":"run-01","message_id":"message-01","run_seq":3,"content_index":0,"timestamp":"2026-07-30T08:00:01Z","update":{"type":"text_start"}}}
{"type":"event","event":"message.updated","seq":4,"payload":{"agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","run_id":"run-01","message_id":"message-01","run_seq":4,"content_index":0,"timestamp":"2026-07-30T08:00:01Z","update":{"type":"text_delta","delta":"订单已发货"}}}
{"type":"event","event":"message.updated","seq":5,"payload":{"agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","run_id":"run-01","message_id":"message-01","run_seq":5,"content_index":0,"timestamp":"2026-07-30T08:00:02Z","update":{"type":"text_end"}}}
{"type":"event","event":"message.completed","seq":6,"payload":{"agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","run_id":"run-01","message_id":"message-01","run_seq":6,"timestamp":"2026-07-30T08:00:02Z","message":{"message_id":"message-01","role":"assistant","status":"completed","content":[{"type":"text","text":"订单已发货"}],"created_at":"2026-07-30T08:00:00Z","completed_at":"2026-07-30T08:00:02Z"}}}
{"type":"event","event":"run.completed","seq":7,"payload":{"agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","run_id":"run-01","run_seq":7,"timestamp":"2026-07-30T08:00:03Z","outcome":"done","stop_reason":"stop","usage":{"input_tokens":230,"output_tokens":48,"total_tokens":278}}}
```

客户端看到 `run.completed` 后清除 active run，并进入 `READY_IDLE`。

## 4. Frame dispatcher

三类 Frame 的职责固定：

```text
RequestFrame  = {type:"req", id, method, params?}
ResponseFrame = {type:"res", id, ok, payload? | error?}
EventFrame    = {type:"event", event, seq, payload}
```

`params` 的结构由 `method` 决定，客户端应按 AsyncAPI 中的对应 Schema 编码和
校验。所有参数对象都是封闭对象，未知字段返回 `INVALID_REQUEST`。

| method | params | 关键字段 |
|---|---|---|
| `connect` | `ConnectParams` | `mode`、协议范围、Session/Agent/Model 标识、`client` |
| `chat.send` | `ChatSendParams` | `message`、`attachment_ids`、`thinking`、`idempotency_key` |
| `chat.steer` | `ChatSteerParams` | `run_id`、`message`、`idempotency_key` |
| `chat.abort` | `ChatAbortParams` | `run_id`、`idempotency_key` |
| `chat.history` | `ChatHistoryParams` | `run_id`、历史水位、`limit`、`cursor` |
| `session.get` / `models.list` | 空对象 `{}` | 无额外参数 |
| `model.set` | `ModelSetParams` | `model_id` |
| `thinking.set` | `ThinkingSetParams` | `thinking` |

完整 RequestFrame 示例：

```json
{"type":"req","id":"req-1","method":"connect","params":{"mode":"create","min_protocol":2,"max_protocol":2,"session_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","agent_id":"agent_011CZkYqphY8vELVzwCUpqiQ","model_id":"model_011CZq2GkV8aD4NwP7sLmXfR","client":{"id":"mate-service","version":"1.0.0","platform":"service"}}}
{"type":"req","id":"req-2","method":"chat.send","params":{"message":"查询订单状态","idempotency_key":"send-key-001"}}
{"type":"req","id":"req-3","method":"chat.steer","params":{"run_id":"run-01","message":"优先给出物流状态","idempotency_key":"steer-key-001"}}
{"type":"req","id":"req-4","method":"chat.abort","params":{"run_id":"run-01","idempotency_key":"abort-key-001"}}
{"type":"req","id":"req-5","method":"chat.history","params":{"run_id":"run-01","through_history_seq":41,"limit":50}}
{"type":"req","id":"req-6","method":"session.get","params":{}}
{"type":"req","id":"req-7","method":"models.list","params":{}}
{"type":"req","id":"req-8","method":"model.set","params":{"model_id":"model_011CZq2GkV8aD4NwP7sLmXfR"}}
{"type":"req","id":"req-9","method":"thinking.set","params":{"thinking":"full"}}
```

参数结构速查：

```json
{
  "connect": {"mode":"create|resume", "min_protocol":2, "max_protocol":2, "session_id":"...", "agent_id":"agent_...", "model_id":"model_...", "client":{"id":"...","version":"...","platform":"..."}},
  "chat.send": {"message":"...?", "attachment_ids":["attachment_..."], "thinking":"hidden|full", "idempotency_key":"...?"},
  "chat.steer": {"run_id":"...", "message":"...", "idempotency_key":"...?"},
  "chat.abort": {"run_id":"...", "idempotency_key":"...?"},
  "chat.history": {"run_id":"...?", "through_history_seq":0, "limit":50, "cursor":"...?"},
  "session.get": {}, "models.list": {},
  "model.set": {"model_id":"model_..."},
  "thinking.set": {"thinking":"hidden|full"}
}
```

这是结构速查，不是一个可发送的联合请求；字段的完整约束以
[`chat-ws-v2.asyncapi.yaml`](chat-ws-v2.asyncapi.yaml) 的 `*Params` Schema 为准。

ResponseFrame 没有 `method`。客户端发送请求时，必须把 method 和预期 payload
decoder 保存到 pending map，再根据响应 `id` 找回：

```ts
type PendingRequest = {
  method: string;
  decodePayload: (value: unknown) => unknown;
  resolve: (value: unknown) => void;
  reject: (error: unknown) => void;
};

const pending = new Map<string, PendingRequest>();

function onTextMessage(raw: string, socketGeneration: number) {
  if (socketGeneration !== currentSocketGeneration) return;

  const frame = JSON.parse(raw) as { type: string };
  if (frame.type === "res") {
    const response = frame as ResponseFrame;
    const request = pending.get(response.id);
    if (!request) return protocolFailure("unknown response id");
    pending.delete(response.id);

    if (!response.ok) {
      request.reject(response.error);
      return;
    }
    request.resolve(request.decodePayload(response.payload));
    return;
  }

  if (frame.type === "event") {
    applyEventFrame(frame as EventFrame);
    return;
  }

  protocolFailure("server sent an unexpected frame type");
}
```

约束：

- RequestFrame `id` 在一个物理连接的整个生命周期内唯一；
- connect 成功后可以并发发送多个普通请求；
- ResponseFrame 可以乱序，也可以与 EventFrame 交错；
- ResponseFrame 不占用 `seq`；
- Request 超时不等于服务端没有执行；有副作用请求必须用新 request `id` 和原
  `idempotency_key` 重试。

AsyncAPI 的 `x-method-contracts` 给出 method 到成功 payload Schema 的规范映射。
这是 CampusAgent 扩展：通用 AsyncAPI 生成器只能生成 Frame `oneOf`，要生成
强类型 request 方法，必须使用理解该扩展的模板，或在 SDK 中手工保留
method -> decoder 映射。

## 5. Message reducer

### 5.1 顺序检查必须先于内容归并

连接级 `seq`：

- 新连接第一条 EventFrame 从 `1` 开始；
- 每成功写出一条 EventFrame 恰好增加 `1`；
- 重连后重新从 `1` 开始。

Run 级 `run_seq`：

- `run.started` 从 `1` 开始；
- 同一 run 的 Message 和 Tool 事件共用一条连续序列；
- 跨重连继续，不重新开始；
- 序列属于 canonical run 事件，不因当前连接的 thinking 投影而变化；
- 某条 canonical thinking 更新被当前连接抑制时，服务端在同一
  `run_seq` 位置发送 `thinking_redacted`，不让 hidden 投影出现假缺口。

同一实时连接出现重复、倒退或缺口时，客户端必须停止应用事件并进入
`RECOVERING`，不能猜测缺失文本。恢复快照已经包含 `run_seq=N` 时，初始排流
阶段忽略 `run_seq<=N`，只接受 `N+1`；进入实时阶段后继续要求逐一递增。

```ts
function verifyOrder(event: EventFrame) {
  if (event.seq !== expectedConnectionSeq) throw new RecoverableGap();
  expectedConnectionSeq += 1;

  const runId = event.payload.run_id;
  const expected = expectedRunSeq.get(runId) ?? 1;
  if (event.payload.run_seq !== expected) throw new RecoverableGap();
  expectedRunSeq.set(runId, expected + 1);
}
```

### 5.2 `content_index` 归并规则

`content_index` 是最终 `message.content[]` 的位置。不同位置可以交错更新；每个
位置必须独立遵循对应生命周期：

| update.type | 客户端动作 |
|---|---|
| `text_start` | 在 `content_index` 创建 `{type:"text", text:""}` |
| `text_delta` | 把本帧 `delta` 追加到该文本块 |
| `text_end` | 把该文本块标记为 closed |
| `thinking_start` | 按 `disclosure` 创建 Thinking 块并记录活动状态；hidden 只创建无 `text` 占位，不创建正文 |
| `thinking_delta` | 只在有效 `full_thinking` 下追加原始 thinking |
| `thinking_redacted` | 只推进序列，不创建或更改可见正文 |
| `thinking_end` | 结束 thinking 活动状态 |
| `toolcall_start` | 创建 ToolCall 块和空的参数文本缓冲 |
| `toolcall_delta` | 追加 JSON 文本片段，不逐帧解析 |
| `toolcall_end` | 以 `arguments` 的脱敏投影收束；`truncated=false` 时用 `value` 完整对象覆盖参数片段，`truncated=true` 时只展示 preview/size/ref |

`message.completed.payload.message` 是权威终态。客户端必须按 `message_id`
整体替换本地 partial Message，而不是再追加一条消息。外层
`payload.message_id` 必须等于内层 `message.message_id`。
为保持 `content_index` 稳定，hidden thinking 在完整 Message 中保留
`{"type":"thinking","disclosure":"hidden"}` 占位块，但绝不包含 `text`；
后续可见文本不会因投影而从 index 1 前移到 index 0。

一个 run 可以产生多个 Assistant Message，例如模型生成 ToolCall、工具执行、
模型继续生成最终回答。每个 Message 都有独立的
`message.started -> message.updated* -> message.completed` 生命周期；
`run.completed` 只出现一次，并且是整个 run 的最后一个事件。

### 5.3 ToolCall 与工具执行不是同一事件

Assistant Message 中的 `toolcall_*` 表示模型正在生成调用参数；
`tool.started/updated/completed` 表示 Tool Manager 实际执行。两条流使用相同
`tool_call_id` 关联：

```text
toolcall_start
  -> toolcall_delta*
  -> toolcall_end
  -> tool.started
  -> tool.updated*
  -> tool.completed
```

客户端用 `tool_call_id` 更新同一张工具卡片。`tool.completed` 的 result/error
负责执行状态；最终 `message.completed` 负责 Assistant Message 对账。
每个已收到 `tool.started` 的 `tool_call_id` 在 `run.completed` 前必须恰好
收到一次 `tool.completed`；run 中止时，尚在运行的 Tool 以
`status="aborted"` 收束，客户端不得在 run 结束后保留 running 工具卡。

Tool 事件返回脱敏后的业务 `parameters/progress/result`，不包含凭据、
内部 Header 或执行器秘密。若完整 result 超过 Frame 预算，客户端收到
截断预览、原始大小、`truncated=true` 和不透明 `result_ref`。v1 没有
读取 `result_ref` 的命令，因此 UI 只能将它作为审计/支持标识展示，
不得拼接为下载 URL。

## 6. 推理内容可见性

结构化 delta 是 v2 基线，不是 capability。当前唯一已知的可选 capability 是
`full_thinking`。这里的 thinking 只控制 reasoning content 是否对客户端可见，
不控制模型是否推理或推理强度。第一版只支持 `hidden` 和 `full`。

普通客户端省略 `capabilities` 或发送空数组：

```json
{"capabilities": []}
```

能够安全展示原始 thinking 的客户端在 connect 中声明：

```json
{"capabilities": ["full_thinking"]}
```

随后必须检查 connect 响应：

```json
{"features": {"capabilities": ["full_thinking"]}}
```

只有服务端有效结果包含该值时，客户端才可以展示 `full` 选项或处理
`thinking_delta`。声明 capability 不会自动把 Session 级别设为 `full`；还需
通过 `thinking.set` 设置，并同时满足调用服务 scope、Agent、Model 和委托上限。

```json
{
  "type": "req",
  "id": "thinking-1",
  "method": "thinking.set",
  "params": {"level": "full"}
}
```

如果有效 capability 不包含 `full_thinking`，该请求返回 `FORBIDDEN`，服务端
不静默降级。`chat.send.params.thinking` 省略时继承当前 Session 默认值；显式
值只能降低，不能提升。

每个 Thinking 块的客户端状态机固定为：

```text
hidden:  thinking_start(hidden)  -> thinking_redacted* -> thinking_end
full:    thinking_start(full)    -> thinking_delta*    -> thinking_end
```

`thinking_redacted` 仅保留 canonical 事件的 `run_seq` 位置，不携带
原始 thinking。协议不定义 `summary` 级别或 `thinking_summary` 事件；需要
向用户说明依据时，客户端展示 Assistant 正常 `text` 回答，不从 reasoning
content 自行生成摘要。
请求级别在 run 开始时冻结，当前唯一连接只能按有效 capability 继续降低；
恢复快照的 `thinking` 是当前连接应当使用的权威投影。

## 7. 其他基础命令

| method | 主要参数 | 成功 payload | 关键状态约束 |
|---|---|---|---|
| `chat.send` | message?、attachment_ids?、idempotency_key、thinking? | run_id、user_message_id、accepted | 文字/附件不能同时为空；active run 存在时返回 `RUN_ACTIVE` |
| `chat.steer` | run_id、非空文本 message、idempotency_key | run_id、user_message_id、accepted、idempotent | v1 不接受附件；只操作当前 active run |
| `chat.abort` | run_id、idempotency_key | run_id、accepted、idempotent | 显式停止；重复调用幂等 |
| `chat.history` | cursor?、limit?、run_id?、through_history_seq? | items、next_cursor?、has_more | 返回权威持久历史；run/水位过滤用于恢复 |
| `session.get` | 无 | Session、Model、active_run | 读取当前权威状态 |
| `models.list` | 无 | models、effective_model_id | 只返回当前 Agent 可用模型 |
| `model.set` | model_id | model | active run 期间拒绝；目标模型不兼容当前有效 transcript 的附件 plan 时返回 ATTACHMENT_NOT_SUPPORTED 并保持原模型 |
| `thinking.set` | level | thinking | active run 期间拒绝；full 还需 capability |

`chat.send`、`chat.steer` 和 `chat.abort` 的同一 `idempotency_key` 只能绑定一个
规范化业务负载；同 key 同负载返回原结果，同 key 不同负载返回
`IDEMPOTENCY_CONFLICT`。RequestFrame `id` 与 `traceparent` 不参与等价比较。

| 命令 | 规范化业务负载 | 接受前失败 |
|---|---|---|
| `chat.send` | `message`、有序 `attachment_ids`、`thinking` 省略状态/值 | 不占用幂等键 |
| `chat.steer` | `run_id + message` | 不占用幂等键 |
| `chat.abort` | `run_id` | 不占用幂等键 |

`message` 省略与空字符串等价，`attachment_ids` 省略与空数组等价，
但非空数组顺序参与比较；`thinking` 省略与显式值不等价。

Chat Frame 不提供 `prompt_templates.list` 或 `skills.list`。Skill 展示信息由
`mate-service`/元数据 REST 提供；`chat.send.message` 中的 `/skill:<name>`
仍由 AgentSession 展开。

Steer 示例：

```jsonl
{"type":"req","id":"req-3","method":"chat.steer","params":{"run_id":"run-01","message":"优先给出物流状态","idempotency_key":"steer-6f46bc26"}}
{"type":"res","id":"req-3","ok":true,"payload":{"run_id":"run-01","user_message_id":"message-user-02","accepted":true,"idempotent":false}}
```

Abort 示例：

```jsonl
{"type":"req","id":"req-4","method":"chat.abort","params":{"run_id":"run-01","idempotency_key":"abort-6f46bc26"}}
{"type":"res","id":"req-4","ok":true,"payload":{"run_id":"run-01","accepted":true,"idempotent":false}}
```

成功 Response 只表示命令已经接受。run 的最终结果仍以
`run.completed(outcome=done|aborted|error|interrupted)` 为准。`interrupted` 表示
Pod 重启等进程故障已使原 run 无法继续，不是可在同一 run 上重试的状态。

## 8. 权威历史

不带 cursor 的 `chat.history` 返回查询时刻最新一页：

```json
{"type":"req","id":"req-5","method":"chat.history","params":{"limit":50}}
```

响应中的 `items` 是 `RuntimeSessionStore` 数据库权威投影，同时包含
Message 和 run 终态，并按 `history_seq` 从旧到新排列：

```json
{
  "type": "res",
  "id": "req-5",
  "ok": true,
  "payload": {
    "items": [
      {
        "type": "message",
        "history_seq": 21,
        "run_id": "run-01",
        "message": {
          "message_id": "message-01",
          "role": "assistant",
          "status": "completed",
          "content": [{"type": "text", "text": "订单已发货"}],
          "created_at": "2026-07-30T08:00:00Z",
          "completed_at": "2026-07-30T08:00:02Z"
        }
      },
      {
        "type": "run",
        "history_seq": 22,
        "run": {
          "run_id": "run-01",
          "outcome": "done",
          "completed_at": "2026-07-30T08:00:03Z"
        }
      }
    ],
    "has_more": false
  }
}
```

- `has_more=true` 时必须携带不透明 `next_cursor`；`has_more=false` 时不得
  携带 cursor；
- cursor 固定首次查询的上界，并发新增记录不会使已开始的分页重叠或漏项；
- 首页可用 `run_id` 只读取一个 run，用 `through_history_seq` 设置包含性
  持久化上界；后续页仅传服务端返回的 cursor；
- 每页内部从旧到新；不同页合并时仍按 `history_seq` 排序；
- Message 按 `message_id` 去重，run 记录按 `run_id` 去重，较新的权威投影覆盖
  本地状态。
- Message `status` 和 RunRecord `outcome` 可为 `interrupted`；这是 Pod 重启后
  的权威终态，客户端应标记“回答被中断”并允许用户新建 `chat.send`，
  不要把它改写为 completed。

## 9. 断线恢复

WebSocket Close 不等于 Abort。普通网络断开时，同 Pod 内 Runtime 只取消
当前连接订阅，active run 继续。若希望停止 run，客户端必须先调用
`chat.abort` 并等待接受响应。

### 9.1 恢复连接

新连接完成 Upgrade 后发送：

```json
{
  "type": "req",
  "id": "connect-resume-1",
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

客户端不提交旧连接的 `seq` 或 `run_seq`。同 Pod 服务端原子递增
`connection_generation`、接管该 Session 唯一读写连接并捕获恢复点。
connect 响应中返回新 generation 与 active-run 快照：

```json
{
  "connection_generation": 2,
  "active_run": {
    "run_id": "run-01",
    "run_seq": 14,
    "history_seq": 41,
    "model_id": "model_011CZq2GkV8aD4NwP7sLmXfR",
    "thinking": "hidden",
    "message_snapshot": {
      "message_id": "message-01",
      "role": "assistant",
      "status": "streaming",
      "content": [{"type": "text", "text": "订单当前状态为"}],
      "created_at": "2026-07-30T08:00:00Z"
    },
    "open_contents": {
      "0": {"type": "text"}
    },
    "active_tools": []
  }
}
```

新 connect Response 成功后，旧 generation 会收到私有关闭语义
`4409 SESSION_REPLACED`。旧 socket 必须停止发送；本地以 socket generation 拒绝它的
迟到 callback。本协议不支持多观察连接。

恢复算法：

1. 清空旧连接的 connection `seq`，新连接期待 `seq=1`；connect Response
   之后可能立即到达 EventFrame，先校验其 connection seq 并放入同步缓冲，
   不立即归并 UI；
2. 记录快照的 `run_seq=N`、`history_seq=H`、`model_id` 和有效
   `thinking`；
3. 发送 `chat.history` 首页：

   ```json
   {"type":"req","id":"history-sync-1","method":"chat.history","params":{"run_id":"run-01","through_history_seq":41,"limit":200}}
   ```

   按 cursor 读完该过滤历史，用其恢复用户消息、已完成 Assistant Message
   和 ToolResult；
4. 用 `message_snapshot` 整体替换当前 active Message；它可以为 `null`，
   表示 run 已开始但 Assistant Message 尚未开始；
5. `open_contents` 是以十进制 `content_index` 字符串为 key 的对象；用它
   初始化已 start、尚未 end 的内容块。开放 ToolCall 的
   `arguments_delta` 只是累计文本，不能提前解析；
6. 用 `active_tools` 整体替换工具执行状态；
7. 历史、partial Message、开放块和 active tools 都应用完成后，再按
   `run_seq` 释放同步缓冲；忽略 `run_seq<=N` 的初始重复，只接受
   `N+1`，后续逐一递增；
8. 发现任何缺口，丢弃本次同步结果并再次恢复。

若 `active_run=null`，但本地此前认为 run 未终止，立即调用 `chat.history`，用
数据库权威 Message 和 RunRecord 对账。不要凭 `active_run=null` 推断旧
run 一定成功，因为它也可能 aborted、error 或 `interrupted`。
其中 Pod 重启中断使用 `RunRecord.outcome=interrupted` 和
`RunRecord.error.code=RUN_INTERRUPTED` 投影。`RUN_INTERRUPTED` 是 history 中的
结构化终态原因，不是 RequestFrame 的 `Error.code`，客户端不应重试
原 `run_id`。

多副本 v1 不使用 Redis、跨 Pod run 转发或分布式 owner。内部网关使用由
mate-service 在认证后生成的受信 Session 亲和路由元数据，尽量把相同
`session_id` 路由回原 Pod；该提示不构成所有权。路由到其他 Pod 或 Pod 重启后，
active run 不能跨 Pod 继续。Runtime
从数据库重建 Session/Agent，旧 active RunRecord 和已持久完整内容块以
`interrupted` 对外可见；未到 `text_end` 等 end 边界的尾部不承诺保存。

### 9.2 `connect mode=create` 响应丢失

若物理连接在发送 create 后、收到 connect Response 前断开，客户端不知道
Session 是否已经提交。客户端必须建立新连接，用新 RequestFrame `id`
和完全相同的 `session_id + agent_id + model_id` 重试 `mode=create`。
服务端对相同绑定返回同一 Session；不同绑定拒绝。不要直接改用
`mode=resume`，因为原 create 若尚未提交，resume 会正常返回
`SESSION_NOT_FOUND`。
这是 Session binding 的资源幂等，不是 `idempotency_key` 幂等；同一
`session_id` 使用不同 immutable binding 时返回 `INVALID_REQUEST`，不返回
`IDEMPOTENCY_CONFLICT`。

### 9.3 `chat.send` 响应丢失

若连接在发送请求后、收到 Response 前断开：

1. 先用 `mode=resume` 恢复 Session；
2. 使用新的 RequestFrame `id`；
3. 使用原 `idempotency_key` 和完全相同的业务负载重新发送；
4. 服务端返回原 `run_id + user_message_id`，即使原 run 当前仍 active，也不
   返回 `RUN_ACTIVE`。

`traceparent` 和 RequestFrame `id` 不参与幂等负载比较；message、附件 ID 的
顺序和值、thinking 是否省略及其值都参与。

## 10. 错误与关闭处理

业务请求校验失败使用 `ok=false`：

```json
{
  "type": "res",
  "id": "req-2",
  "ok": false,
  "error": {
    "code": "RUN_ACTIVE",
    "message": "当前 Session 已存在 active run。",
    "retryable": true
  }
}
```

- `ok=false` 表示该请求没有创建新的 run；
- 请求已接受后的模型或工具失败通过
  `run.completed(outcome="error")` 表达，不再补发失败 Response；
- `retryable` 省略等价于 `false`；
- `retry_after_ms` 只在 `retryable=true` 时有效；
- 客户端必须为未知 `error.code` 保留通用分支。
- `error.details` 是脱敏且有界的诊断投影；不得按固定内部 Header、凭据
  或 Manager 原始响应结构解析。

常见业务错误处理：

| code | 客户端动作 |
|---|---|
| `INVALID_REQUEST` | 修复字段或状态，不原样重试 |
| `IDEMPOTENCY_CONFLICT` | 同一幂等键已绑定其他负载；停止重试并修复键管理 |
| `FORBIDDEN` | 隐藏无权限功能并修复授权 |
| `RUN_ACTIVE` | 等待终态，或对返回/已知 run 执行 steer/abort |
| `RUN_NOT_FOUND` | 调用 `session.get` 或 `chat.history` 对账 |
| `INVALID_ATTACHMENT` | 移除引用并重新上传；不探测资源是否属于其他 Session |
| `ATTACHMENT_NOT_READY` | 通过 CampusMate Attachment Service 状态端点轮询，READY 后再以相同业务负载重试 |
| `ATTACHMENT_NOT_SUPPORTED` | 按当前 ModelSummary.input 更换附件或 Model |
| `MODEL_NOT_ALLOWED` | 调用 `models.list` 后重新选择 |
| `MANAGER_UNAVAILABLE` | 仅在 retryable 时按 retry_after_ms 重试 |

WebSocket Close 处理：

| close code | 客户端动作 |
|---|---|
| `1000` | 正常关闭，默认不自动重连 |
| `1001` | 服务端关闭或心跳超时，退避后 resume |
| `1002` | 协议不兼容，停止重试并升级客户端 |
| `1003` | 客户端错误发送 Binary Message，改为 Text Message |
| `1007` | UTF-8 或 JSON 不合法，修复编码 |
| `1008` | connect 超时或策略错误，修复请求/授权 |
| `1009` | 完整 Message 超过上限，缩小请求 |
| `1011` | 暂时性服务端错误，退避后 resume |
| `1013` | 客户端消费过慢，退避后 resume 并应用快照 |
| 本地观察到 `1006` | 异常断开，退避后 resume；该值不会在线上发送 |
| `4409 SESSION_REPLACED` | 新 generation 已接管；立即停止旧 socket 写入并忽略迟到 callback |

推荐可恢复断线从 500ms 开始做带抖动的指数退避，上限 30s；这是客户端重连
策略，不改变 Session/run 语义。

## 11. Wire、大小和心跳

- 一个完整 WebSocket Text Message 恰好包含一个 JSON Frame；
- 文本编码固定为 UTF-8；Binary Message 使用 `1003` 关闭；
- 非法 UTF-8 或 JSON 使用 `1007` 关闭，此时通常没有可关联 request `id`，
  服务端不发送 ErrorResponseFrame；
- WebSocket fragmentation 允许由协议库透明处理；大小在解压并重组完整 Text
  Message 后按 UTF-8 JSON 字节计算；
- 客户端在发送前应测量 `JSON.stringify(frame)` 的 UTF-8 字节数，并遵守
  `limits.max_message_bytes`；Schema 的字符长度不是最终字节限制；
- 服务端默认每 20 秒发送原生 WebSocket Ping，客户端库应自动回复 Pong；10
  秒内未收到 Pong 时服务端关闭连接，run 继续；
- 不发送应用层 JSON `ping/pong`。

服务端不静默丢弃 `message.updated`。连接缓冲达到上限时使用 `1013` 关闭当前
订阅，客户端通过快照恢复。

## 12. 附件

### 12.1 先走 HTTP 上传，WebSocket 只传 ID

CampusAgent Runtime WebSocket 不上传文件正文。附件数据面固定由
`mate-service` 中的 CampusMate Attachment Service 承载：

```text
browser or CampusMate client
  -> HTTPS multipart POST to mate-service
  -> mate-service streams bytes to shared private OBS
  -> scanner marks openGauss metadata READY
  -> mate-service sends attachment_ids over CampusAgent WebSocket
  -> agent-service resolves and streams content through mate-service internal APIs
```

![附件上传、引用与模型输入流程](managed_attachment_reference_lifecycle.svg)

[PlantUML 源码：`managed_attachment_reference_lifecycle`](diagram.puml#L781)

`agent-service` 不提供上传端点，不直连 OBS 或 openGauss。v1 也不给
浏览器发放 OBS Bucket、地址、凭据或预签名 URL。OBS Object Key 精确等于
`attachment_id`，但这个值只是 WebSocket 中的附件引用，不是可直连 OBS 的
Bearer capability；文件名、MIME、大小、摘要和 Base64 都不进入
`chat.send`，WebSocket 只携带有序 `attachment_ids`。
完整 HTTP Schema 见
[`campusmate-attachment-service/attachment-api.openapi.yaml`](../campusmate-attachment-service/attachment-api.openapi.yaml)。

### 12.2 上传与等待扫描

上层客户端通过一次 multipart 请求上传一个文件：

```http
POST /mate-service/v1/chats/chat_011CZkYqphY8vELVzwCUpqiQ/attachments HTTP/1.1
Host: api.example.com
Authorization: Bearer <campusmate-access-token>
Content-Type: multipart/form-data; boundary=...
X-Attachment-Size: 182734
Prefer: respond-async

--...
Content-Disposition: form-data; name="file"; filename="orders.pdf"
Content-Type: application/pdf

<file bytes>
--...--
```

`X-Attachment-Size` 是单个 `file` part 的实际字节数，不是包含
multipart boundary 和表单头的 HTTP `Content-Length`。它必须位于
`1..20971520`（20 MiB）；声明大于或小于实际值都会失败。服务端在
OBS SDK 读取声明长度后还会确认 `file` part 已到 EOF，不允许小报长度时
尾部字节被忽略。客户端不得
为“方便重试”自行生成 `attachment_id`。

`file` part 必须带非空 `filename`。Attachment Service 进行 Unicode NFC
规范化并移除控制字符和 `/`、`\`，结果必须为 `1..512` 个 code point；
缺失、清理后为空或过长返回 `400`。客户端只把返回的 filename 当作需要转义的
显示文本，不能假设它参与 MIME 判断或 OBS 定位。

服务端先授权公共 `chat_id` 并解析其内部 `session_id`，再生成
`^attachment_[0-9A-Za-z]{24}$` 格式的大小写敏感、不透明 ID，将原始
字节流式写入 OBS，再进入安全扫描。上传请求不保证“重试返回同一 ID”；
没有收到确定响应时重新上传会获得新 ID，遗留且未引用的附件最多保留
24 小时。

极低概率下，OBS create-only PUT 发现同名对象。服务端不会覆盖、删除来源不明
对象或复用当前不可重放的请求流；当前 ID 进入受审计 `FAILED`，调用方按有界
503 响应重新发起上传并取得新 ID，而不是重用失败 ID。

`Prefer` 的最小客户端处理如下：

| 请求 | 响应行为 |
|---|---|
| 省略 `Prefer` | OBS 写入并提交 `PROCESSING` 后返回 `202 + Location + Retry-After` |
| `Prefer: respond-async` | 同上，返回 `202 + Location + Retry-After` |
| `Prefer: wait=N` | 最多等待 `min(N, 10)` 秒；期间进入 `READY` 返回 `201`，仍在处理返回 `202` |

`wait=N` 窗口内进入 `BLOCKED` 或终态 `FAILED` 时，返回规范性
OpenAPI 中的 `422` 或 `503` 错误，不伪装成仍在处理的 `202`。
扫描依赖只是暂时不可用时，服务端保持 `PROCESSING`，客户端继续按
`Retry-After` 轮询。

`202` 不表示文件已经可供模型使用。客户端根据 `Location` 调用：

```http
GET /mate-service/v1/chats/{chat_id}/attachments/{attachment_id}
```

只有上传响应或状态查询返回 `status=READY` 后才能提交
`chat.send`。`PROCESSING` 继续按 `Retry-After` 轮询；`BLOCKED`、
`FAILED`、`DELETING` 或
`DELETED` 都不可发送。客户端必须原样保留 Attachment Service 返回的
ID，不转换大小写、解析后缀或依赖其排序特征。
安全策略可在事后将 `READY` 撤销为 `BLOCKED`；客户端不得把早先的
`READY` 作为永久授权，Runtime 在每次接受新消息时仍会重新 resolve。

### 12.3 OBS 正文与 openGauss 账本的边界

Attachment Service 使用“文件仓库 + 元数据账本”：

- 共享私有 OBS Bucket 保存 PDF、JS 等原始文件字节，Object Key 精确等于
  大小写敏感的 `attachment_id`，不使用文件名、Session 路径或第二个随机定位值；
- 共享 openGauss 的永久 `t_attachment` 主表只保存
  `attachment_id/session_id/status/created_at/deleted_at`；每个非 `DELETED`
  主表行都有 `t_attachment_active_detail` 保存校验、引用、清理和 Worker 执行数据，
  不保存 BLOB/BYTEA 正文或 Object Key 映射；
- Pod 内存只保留单上传不超过 1 MiB 的在途流式缓冲，不使用 Pod 本地目录、
  `/tmp`、临时文件或完整 `byte[]`；
- 一个 `attachment_id` 只绑定一个 `session_id` 和一份不可覆盖的 OBS
  内容；内容变化必须重新上传并生成新 ID；
- PDF、JavaScript 和其他文件均是不可信内容。`mate-service`、
  `agent-service` 和 Provider 适配路径都不得执行 JS。

活动明细字段对客户端虽然大多不可写，但决定状态和 Runtime 能否安全使用：

| 字段 | Attachment Service 为什么需要 |
|---|---|
| `filename` | 经过清理的显示名；仅供 UI 和 Provider 使用，不能当路径 |
| `detected_media_type` | 从正文嗅探并规范化的小写 MIME；用于安全策略和 Model 输入校验，客户端 `File.type` 不参与授权 |
| `expected_size_bytes` | 上传前已校验的声明长度；提供 OBS 流式 PUT 长度和 20 MiB 门禁 |
| `size_bytes` | 服务端实际流式计数；必须与声明值一致，并参与单文件/总量限制 |
| `sha256` | 不可变正文的完整性摘要；扫描、跨 Pod 读取和 Runtime 重放都要复核 |
| `referenced_at` | 首次 resolve 成功时间；非空表示已进入 Session 历史，禁止单项和 24 小时清理 |
| `expires_at` | 未引用附件的清理截止时间；创建时为 24 小时后，引用时清空 |
| `error_code` | 有界且脱敏的稳定失败分类；不包含 OBS/扫描器原始响应或秘密 |
| Worker lease/retry | `attempt_count/next_attempt_at` 控制退避，`lease_owner/lease_until` 允许 Pod 崩溃后接管，`row_version` 防止并发覆盖 |

当 OBS 对象删除成功，Attachment Service 删除活动明细，只在永久主表保留
`attachment_id`、`session_id`、`status=DELETED`、`created_at` 和
`deleted_at`。因此 tombstone 能防止 ID 复用并保留最小审计事实，但不长期
保存文件名、MIME、大小、摘要、错误或 Worker 状态。

因为 openGauss 和 OBS 在所有 Pod 间共享，文件在 Pod A 上传后，Pod B
可以查询状态，agent-service Pod C 也可以通过 Attachment Service 读取。
任何进程缓存都不是权威来源，缓存未命中必须回源 openGauss/OBS。

### 12.4 发送时的批量解析与内容读取

上传前可以根据 `ModelSummary.input` 预检 MIME、数量、单文件和总字节
上限，但这只是 UI 体验优化。浏览器 `File.type` 和扩展名都不可信；
Runtime 仍使用 Attachment Service 返回的检测 MIME 和完整性数据校验。
该预检应同时考虑仍会进入 Context 的历史附件和本次新附件。如果目标
Model 不兼容当前有效历史，`model.set` 返回
`ATTACHMENT_NOT_SUPPORTED` 并保持原模型；Runtime 不会静默丢弃历史附件。

附件进入 `READY` 后，发送字符串 `message`、有序 ID 或两者：

```json
{
  "type": "req",
  "id": "send-attachment-1",
  "method": "chat.send",
  "params": {
    "message": "分析附件中的订单数据",
    "attachment_ids": ["attachment_011CZm8VpK4rNs6WtY2hDqfB"],
    "idempotency_key": "6f46bc26-8a14-4d63-b7b1-8f1f933a0d50"
  }
}
```

`attachment_ids` 省略等价于空数组；非空数组的顺序会成为用户 Message
中的附件块顺序，并参与幂等负载比较。附件引用是协议 2 的标准可选字段，
不需要声明 capability。当前版本只有 `chat.send` 接受附件，
`chat.steer` 不接受。仅附件时省略 `message` 或传空字符串；Runtime
不会为模型补隐藏文本。

`agent-service` 会以服务身份调用：

```http
POST /mate-service/internal/v1/attachments:resolve
Content-Type: application/json

{
  "session_id": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
  "attachment_ids": ["attachment_011CZm8VpK4rNs6WtY2hDqfB"]
}
```

Attachment Service 在一个短 openGauss 事务中校验全部记录都属于当前
Session、处于 `READY`、未删除且未过期。任一项失败则整批回滚；全部成功
后原子设置
`referenced_at=COALESCE(referenced_at, now())`、`expires_at=NULL`，并按请求顺序返回
`attachment_id/filename/media_type/size_bytes/sha256`。`referenced_at` 是单向的；
如果之后 RuntimeSessionStore 提交失败，附件会偏保守地保留到 Session
删除，不会因为提早回收而使已接受历史缺失正文。

全部解析成功后，Runtime 才持久化用户 Message、分配 run 并返回：

```json
{
  "type": "res",
  "id": "send-attachment-1",
  "ok": true,
  "payload": {
    "run_id": "run-01",
    "user_message_id": "message-user-01",
    "accepted": true
  }
}
```

任一附件失败都不会建立部分 run。运行期读取使用固定内部端点：

```http
GET /mate-service/internal/v1/sessions/{session_id}/attachments/{attachment_id}/content
X-Expected-Attachment-SHA256: <sha256 returned by resolve>
```

Attachment Service 重新校验主表和活动明细，再以 `attachment_id` 为
Object Key 从私有 OBS 向 `agent-service` 流式代理原始字节。Runtime 在流经时
重新校验字节数和 SHA-256；它不会获得 Bucket、OBS URL、ETag 或存储凭据，
知道附件 ID 也不能绕过内部 content API。

若 `chat.send` Response 丢失，建立新连接恢复后，使用新 RequestFrame
`id`、原 `idempotency_key` 和完全相同的 message、附件 ID 顺序、
thinking 重新发送。已接受结果返回原 `run_id/user_message_id`。

### 12.5 错误、历史和删除

| code | UI/调用方动作 |
|---|---|
| `INVALID_ATTACHMENT` | 不区分不存在、无权、跨 Session、删除、过期、`BLOCKED` 或 `FAILED`；移除引用并重新上传，不能探测 ID 或安全状态 |
| `ATTACHMENT_NOT_READY` | 保留选择，通过公共 GET 状态端点轮询；只有 READY 后重试 `chat.send` |
| `ATTACHMENT_NOT_SUPPORTED` | 根据当前 ModelSummary 提示 MIME/数量/大小不支持；更换附件或 Model |
| `MANAGER_UNAVAILABLE` | 仅在 `retryable=true` 时退避；不得改为把 URL/Base64 内联发送 |

Runtime 已接受后若内容读取或 Provider 转换失败，不再返回请求错误；客户端
会收到 `run.completed(outcome="error")`，用户消息和附件历史仍保留。

`chat.history` 的 role=user Message 会返回接受时的公共元数据快照：

```json
{
  "message_id": "message-user-01",
  "role": "user",
  "status": "completed",
  "content": [
    {"type": "text", "text": "分析附件中的订单数据"},
    {
      "type": "attachment",
      "attachment_id": "attachment_011CZm8VpK4rNs6WtY2hDqfB",
      "filename": "orders.pdf",
      "media_type": "application/pdf",
      "size_bytes": 182734,
      "sha256": "3b6f75a86ac2f94c6b20252a66f4d71a7b37b1f48e325ef1698025c813b31c5f"
    }
  ],
  "created_at": "2026-07-30T07:59:59Z",
  "completed_at": "2026-07-30T07:59:59Z"
}
```

用户 Message 的 `content` 只有三种形态：

```text
[TextContent]
[AttachmentContent, ...]
[TextContent, AttachmentContent, ...]
```

文本若存在必须是第一块且非空；附件块顺序与接受时
`attachment_ids` 一致。纯附件历史不包含空 TextContent。快照字段固定为
`attachment_id/filename/media_type/size_bytes/sha256`；
RuntimeSessionStore 不保存文件正文、OBS Bucket、ETag、OBS URL 或凭据。
客户端只把 filename 当作经过转义的显示文本，不能当作本地路径。v1
不定义公共附件下载接口，历史也不返回下载 URL。

未被 Message 引用且不处于 `OBJECT_KEY_CONFLICT` 存储隔离的附件可调用：

```http
DELETE /mate-service/v1/chats/{chat_id}/attachments/{attachment_id}
```

Attachment Service 将其标记为 `DELETING`，异步删除 OBS 对象后进入
`DELETED`，同时删除 `t_attachment_active_detail`。已引用附件的单独删除返回
`409 ATTACHMENT_REFERENCED`；它们只在上层删除整个 Session 时一并清理。
create-only 冲突行的公共 DELETE 返回有界 503，不删除来源不明对象；即使上层
删除 Session，Runtime 使用会停止且 Session 对用户不可见，但存储清理保持
pending/quarantined，直到受审计对账确认安全删除或 OBS `NotFound`。
删除不可恢复，重新使用必须重新上传并获得新 ID；`DELETED` 记录作为永久
ID tombstone 保留；墓碑只含 ID、Session、状态、创建和删除时间，删除后也不复用 ID。

## 13. 实现检查表

客户端交付前至少验证：

- WebSocket `open` 后先 connect，connect 成功前没有其他请求；
- `features.events` 不缺少任何一类基础 Chat 事件；
- `features.methods` 只包含规范的八个 Chat/Session/Model 方法，客户端不调用
  `prompt_templates.list` 或 `skills.list`；
- 发送 connect 前可本地校验 `agent_`/`model_` 加 24 位大小写字母
  数字；错误前缀、长度、标点或空格不发送；
- 客户端把 Agent/Model ID 作为不透明原值缓存和比较，不改写大小写，不用
  Provider 模型名替换 `model_id`；
- pending map 用 RequestFrame `id` 关联 method 和 payload decoder；
- 并发响应乱序和 EventFrame 插入不会破坏请求关联；
- `chat.send` 响应先建立 `run_id/user_message_id`，再处理 run 事件；所有改变
  Session/run 状态的成功 Response 均先于其因果 Event；
- 纯文字、纯附件、文字加附件三种 `chat.send` 均可发送，二者同空被
  本地阻止；`chat.steer` 只发送非空文本；
- typed delta 无需 capability，客户端没有累计 Message/replace 分支；
- `text/thinking/toolcall` 按 `message_id + content_index` 正确归并；
- hidden Thinking 保留无文本占位，被抑制更新只用
  `thinking_redacted` 推进 canonical `run_seq`；
- ToolCall 生成和 Tool 执行按 `tool_call_id` 对账；
- 每个 `tool.started` 在 run 终态前恰好收到一次 `tool.completed`；
- Tool 业务 parameters/result 按投影展示，不渲染凭据/内部 Header；
  `truncated=true` 时显示预览和大小，不尝试读取 `result_ref`；
- `message.completed` 权威替换 partial Message；
- `run.completed` 后清理 active run，且不接受该 run 的后续事件；
- `seq/run_seq` 重复、倒退和缺口都会触发恢复；
- snapshot 为 null、存在开放文本、开放 hidden thinking、开放 ToolCall 和 active
  Tool 的情况都能恢复；Model/Thinking 从快照获取，无需猜测；
- active snapshot 后先缓冲事件，用 `run_id + history_seq` 读完水位历史，
  再应用 partial 快照和释放缓冲；
- `active_run=null` 时能用 history 的 Message/RunRecord 对账；
- 新 resume 的 `connection_generation` 接管后，旧 socket 收到 `4409 SESSION_REPLACED`
  即停止写入，迟到 callback 被本地 generation 忽略；
- Pod 重启后能展示 `interrupted` Message/RunRecord，不假设未完整内容块尾部
  可恢复；客户端不假设 IP 粘性等于跨 Pod run owner；
- Request 超时使用新 request ID 和原 idempotency key；
- 使用 `POST /mate-service/v1/chats/{chat_id}/attachments` 上传唯一
  `file` part，`X-Attachment-Size` 为 `1..20971520` 且精确等于文件字节数；
  SDK 读满声明长度后仍校验 file-part EOF，小报长度不能被截断接受；
- filename 必填，NFC 规范化和安全清理后为 `1..512` 个 code point；
  create-only 冲突不覆盖未知对象，客户端通过新请求获取新 attachment_id；
- 能处理默认/`respond-async` 的 `202`、`wait=N` 的最多 10 秒等待，
  并通过 `Location` 指向的 GET 端点轮询到终态；
- 上传状态未到 READY 时不发送；只接受 Attachment Service 返回且匹配
  `^attachment_[0-9A-Za-z]{24}$` 的 ID，按原始大小写保存和比较，不自行生成、
  解析或规范化；按 ModelSummary.input 预检 MIME、数量和字节，WebSocket 只
  提交 attachment_ids，不提交 URL、MIME、文件名、size 或 Base64；
- 验证 OBS Object Key 与 `attachment_id` 完全相同且写入使用 create-only；
  openGauss 不保存 Object Key 映射，知道 ID 的 Runtime 仍不能直连私有 Bucket；
- 验证活动明细的 MIME/大小/SHA-256、referenced_at/expires_at 和 Worker
  lease/retry/row_version 分别驱动校验、引用保护、24 小时清理和故障接管；
  OBS 删除完成后明细消失，主表只留下五字段 DELETED tombstone；
- 带附件 send 的任一引用失败时不乐观显示为已接受；成功后按
  user_message_id 对齐带 AttachmentContent 的权威历史；
- `INVALID_ATTACHMENT` 不用于探测资源存在性，`ATTACHMENT_NOT_READY` 按建议
  间隔重试，`ATTACHMENT_NOT_SUPPORTED` 要求更换附件或 Model；
- model.set 遇到历史附件不兼容时保持原模型；chat.send 的预检包含有效历史与
  新附件，客户端不假设 Runtime 会为适配模型静默丢弃历史内容；
- 已接受附件的 Response 丢失时用原 ID 顺序和原幂等键重试，不重新上传或改写
  业务负载；历史只保留 `attachment_id/filename/media_type/size_bytes/sha256`，
  filename 只作显示；v1 不定义公共下载接口；
- 普通未引用附件可在 24 小时后清理；`OBJECT_KEY_CONFLICT` 被公共 DELETE、
  定时清理和普通 Session 删除排除，UI 可以显示存储清理 pending，但不能把它
  当作正文已删除；
- create connect 响应丢失时用相同 Session/Agent/Model 重试 create，不改用
  resume；
- `full_thinking` 只有在有效 capability 回显后才进入 UI；
- 1001/1006/1011/1013 退避恢复，1002 停止重试；
- 浏览器只连接 `mate-service`；调用方使用既有内部网关客户端，
  任何凭据或私钥原文不进入 Frame、Prompt、数据库或日志。

## 14. 源码事实与目标设计

pi-mono-java 固定基线的当前行为是：

- `ServerMode` 从 Upgrade query 读取 `conversation_id`：
  [`ServerMode.java#L377-L391`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ServerMode.java#L377-L391)；
- `ChatWebSocketHandler` 使用 v1 命令并在断线时 abort：
  [`ChatWebSocketHandler.java#L168-L227`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ChatWebSocketHandler.java#L168-L227)；
- `message_update` 发送累计 Message，现有前端用新快照替换旧快照：
  [`ChatWebSocketHandler.java#L422-L459`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/mode/server/ChatWebSocketHandler.java#L422-L459)、
  [`useChatWs.ts#L439-L448`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/frontend/src/composables/useChatWs.ts#L439-L448)；
- Java 内部已经提供 text/thinking/toolcall 细粒度事件：
  [`AssistantMessageEvent.java#L44-L164`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/stream/AssistantMessageEvent.java#L44-L164)；
- 当前 UserMessage 虽接受 ContentBlock 列表，但联合类型只有
  text/image/thinking/toolCall，ImageContent 保存 base64；固定基线没有通用
  attachment ID、上传状态或外部内容读取适配：
  [`UserMessage.java#L20-L31`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/types/UserMessage.java#L20-L31)、
  [`ContentBlock.java#L17-L24`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/types/ContentBlock.java#L17-L24)、
  [`ImageContent.java#L9-L18`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/types/ImageContent.java#L9-L18)；
- 固定基线的 follow-up 文档把 WebSocket attachment input 列为待设计项：
  [`ws-chat-followups.md#L12-L37`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/docs/plans/ws-chat-followups.md#L12-L37)。

本文全部 v2 交互都是目标设计，尚未实现。typed delta、`user_message_id`、
Session-scoped connect、run 独立生命周期、原子快照、历史 RunRecord、附件
批量解析/流式输入装配属于架构改造；服务认证、凭据隔离、thinking 投影和附件
控制面/数据面边界属于安全加固。

## 15. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.8.0 | 2026-08-05 | 同步内部 AsyncAPI 2.12.0：按 method 拆分具名请求和成功响应、以标准 reply 关联共享错误响应，并将八类事件分别暴露给文档工具；增加默认展开 JSON 示例的生成 HTML 和简化开发者指南；修正 `ModelInputPolicy(max_attachments=0)` 误要求无关 `completed_at` 字段的问题；同步 Manager 1.13.1 |
| 1.7.0 | 2026-08-04 | 将本文明确为 mate-service 到 agent-service 的内部 Runtime 客户端指南；内部 URL 改为 `/agent-service/internal/v1/ws/chat`，保留 session_id 契约；链接独立的公共 Chat AsyncAPI/指南，明确两跳连接、请求、序列、心跳、背压和关闭互不复用；用受信 Session 亲和元数据替代最终用户 IP 假设，并将公共附件路径改为 chat_id；同步内部 AsyncAPI 2.11.0 和 Manager 1.13.0 |
| 1.6.0 | 2026-08-03 | 将 thinking 配置明确为 reasoning content 可见性；第一版仅保留 hidden/full，删除 summary 级别、thinking_summary 事件和客户端摘要归并分支；同步 AsyncAPI 2.10.0 和 Manager 1.12.0 |
| 1.5.1 | 2026-08-03 | 同步 Attachment Service 1.1.0：OBS Object Key 固定为 `attachment_id`，openGauss 拆分永久五字段主表与活动明细；解释 filename、检测 MIME、声明/实际大小、SHA-256、引用/过期、失败码和 Worker lease/retry 字段；冻结 filename 与 create-only 冲突 quarantine 门禁，并明确删除正文后只保留最小 tombstone；同步 AsyncAPI 2.9.1 和 Manager 1.11.1 |
| 1.5.0 | 2026-08-03 | 固定 CampusMate Attachment Service 单 multipart 上传、`X-Attachment-Size`、`Prefer` 异步/限时等待和 GET 轮询契约；明确 OBS 正文、openGauss 元数据、无本地文件的跨 Pod 边界；将 Runtime 收敛为内部批量 resolve/content 流式读取和五字段历史快照，不向 Runtime 披露 Object Key 或 OBS 凭据；同步 AsyncAPI 2.9.0 和 Manager 1.11.0 |
| 1.4.0 | 2026-08-03 | 将 `attachment_id` 收敛为 `^attachment_[0-9A-Za-z]{24}$`（总长 35），明确 ID 只能由 Attachment Service 签发、大小写敏感且不透明，客户端必须原样保存、不得自行生成或解析，删除后不复用，且格式合法不代表获得 Session 授权；同步 AsyncAPI 2.8.0 和 Manager 1.10.0 |
| 1.3.0 | 2026-08-03 | 将 `agent_id` 收敛为 `^agent_[0-9A-Za-z]{24}$`、`model_id` 收敛为 `^model_[0-9A-Za-z]{24}$`；明确资源 ID 大小写敏感、不透明、由各自管理服务生成，客户端不解析后缀或用 Provider 模型名代替，并按 create/resume 语义核对响应 ID；同步 AsyncAPI 2.7.0 和 Manager 1.9.0 |
| 1.2.0 | 2026-08-03 | 统一 CampusAgent / agent-service 及规范 URL；将直连边界收窄为 mate-service/已授权服务端，认证复用既有内部网关；将方法集收敛为八个，补齐纯附件、text-only steer、Tool 脱敏/截断、Response-before-Event、单连接 generation 接管、数据库权威历史、IP 粘性限制和 Pod 重启 interrupted 恢复；同步 AsyncAPI 2.6.0 和 Manager 1.8.0 |
| 1.1.0 | 2026-08-03 | 增加可直接实施的附件上传状态机、完整 AttachmentContextPlan/Model 切换预检、仅 ID 的 chat.send、批量原子接受、错误动作、幂等重试、AttachmentContent 历史、source digest 与 Session 保留/删除说明；同步 AsyncAPI 2.5.0 和 Manager 1.7.0 |
| 1.0.0 | 2026-08-03 | 首版；给出客户端角色、建连、connect、chat.send、typed delta reducer、redacted thinking、命令、水位历史、快照恢复、错误、关闭码和 TypeScript dispatcher 的完整接入路径 |
