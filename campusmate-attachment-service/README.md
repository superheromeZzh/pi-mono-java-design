# CampusMate Attachment Service：OBS + openGauss 设计

> 文档编号：`SR-ATTACHMENT-001`<br>
> 版本：`v1.0.0`<br>
> 日期：`2026-08-03`<br>
> 状态：目标设计（target-only）<br>
> 设计仓库基线：`ecf31bc55ca1923dd1c7f90d50ee6763963b7da9`<br>
> pi-mono 基线：`fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc`<br>
> pi-mono-java 基线：`1f7a5423219edfa4519d8719f1cc8a188ed72873`<br>
> OpenClaw 证据基线：`b015925bc30f6a8363f290b07d5f8588e21422b8`

## 1. 结论

CampusMate Attachment Service 采用“文件仓库 + 元数据账本”模型：

```text
OBS         = 文件仓库，保存 PDF、JS 等原始文件字节
openGauss   = 元数据账本，记录文件归属、位置、状态和完整性
attachment_id = 对外唯一且不透明的附件标识
```

最终边界如下：

- `mate-service` 承载 Attachment Service，对最终用户提供 HTTP 上传和状态查询；
- 原始文件只保存到共享私有 OBS Bucket，不进入 openGauss；
- openGauss 只保存 `attachment_id -> object_key` 映射、Session 归属、状态、大小、
  SHA-256 和任务租约等结构化数据；
- `agent-service` 只通过 Attachment Service 内部接口解析和读取附件，不直接访问
  openGauss、OBS 或存储凭据；
- 任意 Pod 都以共享 openGauss 和共享 OBS 为权威来源，Pod 内存只保留有界的在途
  缓冲，不保存附件；
- 不使用 Pod 本地目录、`/tmp`、临时文件或完整 `byte[]`；
- 单文件上限固定为 20 MiB，即 `20 * 1024 * 1024 = 20971520` 字节；
- 一个附件只绑定一个 `session_id`，OBS 内容创建后不可覆盖；重新上传必须生成新的
  `attachment_id`；
- PDF、JavaScript 和其他文件均视为不可信用户内容。Attachment Service、
  `mate-service` 和 `agent-service` 都不得执行脚本。

本专题只定义目标接口、数据模型和故障语义，不表示现有 pi、pi-mono-java 或
CampusMate 已经实现这些能力。

## 2. 源码证据与目标设计边界

### 2.1 固定源码观察

| 基线 | 源码证据 | 已观察行为 |
|---|---|---|
| pi-mono `fc85bdd…` | [`packages/agent/src/agent.ts#L336-L395`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/agent/src/agent.ts#L336-L395) `prompt()`；[`packages/ai/src/types.ts#L345-L349`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/ai/src/types.ts#L345-L349) `ImageContent` | Agent 可接收文本和内联 base64 图片，但没有通用 `attachment_id`、上传状态、OBS 元数据或 Attachment Service |
| pi-mono-java `1f7a542…` | [`UserMessage.java#L20-L31`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/types/UserMessage.java#L20-L31)、[`ContentBlock.java#L17-L24`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/types/ContentBlock.java#L17-L24)、[`ImageContent.java#L9-L18`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/modules/ai/src/main/java/com/campusclaw/ai/types/ImageContent.java#L9-L18) | `UserMessage` 可以包含封闭的 ContentBlock 联合，但当前只有 text/image/thinking/toolCall；图片仍以内联 base64 表示 |
| pi-mono-java `1f7a542…` | [`docs/plans/ws-chat-followups.md#L12-L37`](https://github.com/superheromeZzh/pi-mono-java/blob/1f7a5423219edfa4519d8719f1cc8a188ed72873/docs/plans/ws-chat-followups.md#L12-L37) | WebSocket 附件输入仍是待设计项，并未实现独立上传和引用协议 |

OpenClaw 基线仅用于同仓库其他 WebSocket 对比文档。本专题没有从 OpenClaw 推导
附件数据面，不把其 Gateway 行为表述为 Attachment Service 现状。

### 2.2 设计分类

| 决策 | 分类 | 原因 |
|---|---|---|
| HTTP 上传、WebSocket 只传 `attachment_id` | 产品约束 | 避免大文件占用 Chat Frame、事件缓冲和重连协议 |
| OBS 保存正文、openGauss 保存元数据 | 架构改造 | 让多 Pod 共享内容，同时避免大对象进入数据库 WAL、主备复制和备份链路 |
| 上传和读取全程流式、无本地文件 | 安全加固 | 限制堆内存和节点磁盘暴露，避免 Pod 路由及重启影响附件可用性 |
| 扫描完成前禁止 `chat.send` | 安全加固 | 模型和下游解析器只能读取经过完整性校验和安全扫描的内容 |
| JS 只读不执行 | 安全加固 | 上传内容不获得代码执行能力，也不能提升为系统指令 |
| 不使用 OBS/openGauss XA | 架构改造 | 通过状态机、条件更新、租约和对账实现可恢复的最终一致性 |

## 3. 部署与跨 Pod 边界

![OBS 与 openGauss 存储职责](./attachment_obs_opengauss_storage_split.svg)

[PlantUML 源码：`attachment_obs_opengauss_storage_split`](./diagram.puml#L106)

跨 Pod 读取不依赖上传 Pod：

```text
CampusMate client
  -> mate-service Pod A
  -> shared private OBS + shared openGauss

agent-service Pod C
  -> mate-service Attachment API Pod B
  -> same shared openGauss
  -> same shared private OBS
```

`AttachmentContentStore` 是 `mate-service` 内的存储端口，不是存储位置。端口的
OBS 适配器运行在每个 Attachment Service Pod 内，所有 Pod 使用相同的 OBS
Endpoint、私有 Bucket 和 openGauss 数据源。`attachment_id -> object_key` 映射
不得只存在 Java `Map`、进程缓存或本地文件中。

Bucket、Endpoint、AK/SK、Object Key 和内部 ETag 均为实现细节：

- AK/SK 从 Kubernetes Secret 或公司既有工作负载身份系统获取；
- 入站用户凭据不得转换为 OBS 长期凭据；
- Bucket 必须私有，通过 TLS 访问并启用服务端加密；
- Object Key 使用密码学安全随机值生成，不包含 `session_id`、文件名、用户信息或
  `attachment_id` 的可推断结构；
- 文档和公共接口不规定 Bucket Prefix 或确定性路径；
- `object_key`、ETag、Endpoint、预签名 URL 和凭据不得进入客户端响应、
  CampusAgent Prompt、WebSocket Frame 或业务日志。

## 4. 标识、归属与不可变性

### 4.1 `attachment_id`

格式固定为：

```text
^attachment_[0-9A-Za-z]{24}$
```

例如：

```text
attachment_011CZm8VpK4rNs6WtY2hDqfB
```

规则如下：

- 只能由 Attachment Service 生成；
- 总长度为 35，大小写敏感，调用方必须逐字节保留；
- openGauss 主键唯一约束是碰撞判断的最终依据；
- 发生碰撞时重新生成，不向调用方返回碰撞值；
- `DELETED` 行永久作为 tombstone 保留，删除 OBS 正文也不能释放 ID；
- ID 不是 Bearer capability。知道格式或值不等于有权读取附件。

### 4.2 Session 单绑定

每个附件在创建时绑定一个全局唯一的 `session_id`，之后不能改绑：

```text
attachment_id -> exactly one session_id -> exactly one immutable OBS object
```

`session_id` 与 CampusAgent Runtime WebSocket 使用同一契约：长度
`1..128`，匹配 `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`。Attachment Service
不扩展该字符集，因此不会接受 Runtime 无法创建或恢复的 Session ID。

本设计不保存 `tenant_id` 或 `user_id`。`mate-service` 是 Session 和最终用户授权的
权威服务；Attachment 表只记录 Runtime 所需的 `session_id`。跨 Session 使用同一
文件时必须重新上传并获得新 ID。

本版没有 `content_version`。原因是一个 `attachment_id` 只对应一次不可覆盖的
OBS 内容创建：

- 内容改变时生成新的 `attachment_id`；
- 历史以 `attachment_id + sha256` 固定原始内容；
- 不提供覆盖、回滚、跨 Session 复用或版本选择接口。

## 5. 上传接口和处理流程

### 5.1 HTTP 请求

上传接口由 `mate-service` 提供：

```http
POST /mate-service/v1/sessions/01ARZ3NDEKTSV4RRFFQ69G5FAV/attachments HTTP/1.1
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

`X-Attachment-Size` 表示单个 `file` part 的字节数，不是整个 multipart HTTP Body
的 `Content-Length`。客户端可从浏览器 `File.size` 或服务端文件元数据取得该值。
v1 不接受无法预先确定正文长度的上传流。

服务端同时执行三层校验：

1. Header 声明值必须位于 `1..20971520`；
2. OBS 流式上传使用同一 `contentLength`；
3. 计数流观察到的实际字节数必须等于声明值，且不得超过 20 MiB。

仅把声明值传给 OBS SDK 不足以证明长度一致：当客户端小报长度时，
SDK 可能只读取声明的 N 个字节就完成 PUT。因此 PUT 返回后还必须确认
`file` part 已到 EOF；可以由 multipart 框架提供精确 part 长度，或在已读
N 字节后进行有界的一字节探测。如果还有字节，必须删除已写对象并返回
`ATTACHMENT_SIZE_MISMATCH`；如果实际已超过 20 MiB，返回
`ATTACHMENT_TOO_LARGE`。流在 N 字节之前就到 EOF 同样视为长度不匹配。

HTTP `Content-Length` 包含 multipart boundary、文件名和表单头，不能替代
`X-Attachment-Size`。华为云 OBS Java SDK 官方文档说明流式上传以
`java.io.InputStream` 作为对象数据源；其进度文档同时要求流式上传配置对象
`Content-Length`，见[流式上传](https://support.huaweicloud.com/sdk-java-devg-obs/obs_21_0602.html)和
[上传进度](https://support.huaweicloud.com/eu/sdk-java-devg-obs/obs_21_0604.html)。

### 5.2 服务端处理顺序

![附件上传与扫描流程](./attachment_upload_and_scan_flow.svg)

[PlantUML 源码：`attachment_upload_and_scan_flow`](./diagram.puml#L6)

处理顺序固定为：

```text
authorize user and session
  -> validate multipart and X-Attachment-Size
  -> generate attachment_id and random object_key
  -> INSERT attachment(status=UPLOADING)
  -> stream exactly one file part to OBS
       while counting bytes and calculating SHA-256
  -> require actual bytes == X-Attachment-Size
  -> UPDATE status=PROCESSING, size_bytes, sha256, obs_etag
  -> enqueue/lease asynchronous scan
  -> return according to Prefer
```

只有 OBS 写入成功且 openGauss 已进入 `PROCESSING` 后，上传接口才可以返回
`attachment_id`。如果客户端在上传中断开，服务端停止读取，取消或清理未完成的
OBS 写入，并将数据库记录标记为 `FAILED`；不得把半个文件进入扫描队列。

扫描 Worker 从 OBS 重新流式读取，完成：

- 实际长度和 SHA-256 复核；
- 基于内容的 MIME 嗅探，不信任 multipart 声明；
- 病毒和恶意内容扫描；
- PDF、压缩格式等解析复杂度限制；
- 终态更新为 `READY`、`BLOCKED` 或 `FAILED`。

声明 MIME 和嗅探 MIME 都以解析后的无参数 `type/subtype`
表示，并用 `Locale.ROOT` 规范化为小写；声明 MIME 仍只供审计。
只有 `READY` 可以用于 CampusAgent `chat.send`。`BLOCKED` 表示内容被安全策略拒绝；
`FAILED` 表示上传、存储或扫描基础设施失败，不能被模型读取。

### 5.3 同步等待与异步返回

`Prefer` 采用 [RFC 7240](https://www.rfc-editor.org/rfc/rfc7240.html) 定义的
`respond-async` 和 `wait` 语义。v1 每次请求只接受一个偏好值：

| 请求 | 行为 |
|---|---|
| 省略 `Prefer` | OBS 写入和 `PROCESSING` 提交完成后立即返回 `202` |
| `Prefer: respond-async` | 同上，返回 `202` 和状态资源位置 |
| `Prefer: wait=N` | `N` 为最多 10 位的非负十进制秒数；服务端最多等待 `min(N, 10)` 秒 |

等待只影响 HTTP 响应时机，不改变后台状态机：

- 等待期间到达 `READY`：返回 `201 Created`；
- 等待期间到达 `BLOCKED`：返回 `422 Unprocessable Content`；
- 等待期结束仍为 `PROCESSING`：返回 `202 Accepted`；
- 扫描依赖暂时不可用时保持 `PROCESSING` 并返回 `202`，由 Worker 重试；
- 上传或存储未能建立可用状态资源，或扫描已进入终态 `FAILED`时，
  返回 `503 Service Unavailable`；如果资源已创建，同时返回 `Location`；
- `202` 必须带 `Location` 和 `Retry-After`；
- `422` 必须带 `Location`，让客户端仍可查询或删除已创建的资源；
- 服务端实际采用偏好时返回 `Preference-Applied`。

这里的“立即”是指服务端已完整接收正文、OBS 持久化成功且 openGauss 已提交
`PROCESSING` 之后立即响应，不是跳过文件上传。

客户端轮询：

```http
GET /mate-service/v1/sessions/{session_id}/attachments/{attachment_id}
```

上传请求不提供同 ID 幂等保证。调用方没有收到确定响应时重新上传，会得到新的
`attachment_id`；旧的未引用附件由 24 小时清理任务回收。

完整公共和内部 HTTP 契约见
[`attachment-api.openapi.yaml`](./attachment-api.openapi.yaml)。

## 6. 状态机

```text
UPLOADING -> PROCESSING -> READY
    |              |          +-> DELETING -> DELETED
    |              +-> BLOCKED -> DELETING -> DELETED
    |              +-> FAILED --> DELETING -> DELETED
    +-> FAILED ----------------> DELETING -> DELETED

READY -- privileged security revocation --> BLOCKED

READY(unreferenced) -> READY(referenced)
READY(referenced)   -> DELETING only through Session deletion
```

状态含义：

| 状态 | 是否可用于 `chat.send` | 说明 |
|---|---:|---|
| `UPLOADING` | 否 | 数据库记录已创建，OBS 写入尚未确认 |
| `PROCESSING` | 否 | OBS 正文已持久化，等待或正在扫描 |
| `READY` | 是 | 完整性和安全扫描通过 |
| `BLOCKED` | 否 | 恶意或策略禁止内容；正文等待安全清理 |
| `FAILED` | 否 | 上传、存储、校验或扫描失败 |
| `DELETING` | 否 | 已阻止新读取，等待删除 OBS 正文 |
| `DELETED` | 否 | 正文已删除，只保留不可复用 tombstone |

所有状态变更必须使用 `row_version` 条件更新。服务不得仅在内存中改变状态，也
不得在 OBS I/O 或安全扫描期间持有数据库事务。

常规扫描仅执行 `PROCESSING -> READY | BLOCKED | FAILED`。当病毒库、
合规策略或人工处置在事后撤销已就绪内容时，只允许受审计的特权
控制面以条件更新执行 `READY -> BLOCKED`。之后新的 resolve/content 立即
失败；尚未读取该正文的 active run 必须失败或中止。历史保留元数据快照
和撤销状态，但系统无法撤回已经交给模型的字节。已 referenced 正文的
常规单独删除仍返回 `409`，直到 Session 删除流程才进入 `DELETING`。

## 7. openGauss 元数据账本

### 7.1 为什么不把文件正文存进数据库

openGauss 官方文档确实提供 BLOB 和 BYTEA，见
[Binary Types](https://docs.opengauss.org/en/docs/7.0.0-RC3/sql_reference/binary_types.html)。
本设计仍明确不使用这些类型保存附件正文，因为 PDF、脚本等大对象进入数据库会
同时扩大：

- WAL 和主备复制流量；
- 数据库备份、恢复和容灾窗口；
- JDBC 大对象读写及连接占用；
- 热元数据查询与文件 I/O 的资源竞争。

OBS 负责大对象吞吐，openGauss 负责关系约束、状态查询、条件更新和多 Pod 任务
认领。openGauss 支持主键、唯一、`CHECK` 等约束，见
[Constraints](https://docs.opengauss.org/en/docs/latest/sql_reference/constraints.html)。

### 7.2 单表模型

完整 DDL 见 [`schema.sql`](./schema.sql)。表中不包含 `BLOB`、`BYTEA`、Base64
或任何文件正文。

| 字段 | 类型 | 作用 |
|---|---|---|
| `attachment_id` | `VARCHAR(35)` | 主键；大小写敏感的不透明 ID |
| `session_id` | `VARCHAR(128)` | 不可变的 Session 归属 |
| `object_key` | `VARCHAR(512)` | OBS 内部随机定位值；唯一且永不对外披露 |
| `status` | `VARCHAR(16)` | 上传、扫描和删除状态机 |
| `filename` | `VARCHAR(512)` | 清理后的显示名，不参与 Object Key |
| `declared_media_type` | `VARCHAR(127)` | 上传方声明，仅供审计 |
| `detected_media_type` | `VARCHAR(127)` | 扫描器基于内容识别的可信类型 |
| `expected_size_bytes` | `BIGINT` | `X-Attachment-Size` 声明值 |
| `size_bytes` | `BIGINT` | 服务端流式计数的实际值 |
| `sha256` | `CHAR(64)` | 原始内容 SHA-256 小写十六进制 |
| `obs_etag` | `VARCHAR(128)` | OBS 返回的对象标识；不能替代 SHA-256 |
| `referenced` / `referenced_at` | `BOOLEAN` / 时间 | 是否已被 Runtime 接受进消息历史 |
| `expires_at` | 时间 | 未引用附件的清理期限 |
| `attempt_count` / `next_attempt_at` | 数字 / 时间 | 扫描、删除和对账重试调度 |
| `lease_owner` / `lease_until` | 字符串 / 时间 | 多 Pod Worker 的短期任务租约 |
| `row_version` | `BIGINT` | 状态和并发更新的乐观锁 |
| `error_code` | `VARCHAR(64)` | 有界、脱敏的稳定失败码 |
| 时间字段 | `TIMESTAMPTZ(3)` | 创建、更新、就绪和删除时间 |

关键约束：

- `attachment_id` 匹配 `^attachment_[0-9A-Za-z]{24}$`；
- `object_key` 唯一；
- `expected_size_bytes` 和 `size_bytes` 均不超过 20 MiB；
- `READY` 必须同时具有实际大小、SHA-256、OBS ETag、可信 MIME 和 `ready_at`；
- `referenced=true` 必须具有 `referenced_at`；
- `referenced=true` 时 `expires_at` 必须为空，且应用层不允许再改回 `false`；
- `lease_owner` 和 `lease_until` 同时为空或同时非空；
- `DELETED` 必须具有 `deleted_at`，且 tombstone 行不再物理删除。

索引：

```text
(session_id, status)
(status, next_attempt_at)
(referenced, expires_at)
```

Attachment Service 部署使用 UTF-8、大小写敏感的比较语义；上线前必须用实际
openGauss JDBC 驱动验证 `attachment_A...` 与 `attachment_a...` 不会被错误归一化。

### 7.3 租约认领

Worker 只在短事务中认领任务：

```text
BEGIN
  select eligible row and lock it
  set lease_owner, lease_until, row_version = row_version + 1
COMMIT

read/scan/delete OBS object without a database transaction

BEGIN
  update terminal/retry state
  where attachment_id = ? and lease_owner = ? and row_version = ?
COMMIT
```

Pod 崩溃后 `lease_until` 到期，其他 Pod 可以重新认领。任务必须按
`attachment_id` 幂等，不能依赖某个 Worker 的本地状态。

## 8. OBS 内容仓库和内存边界

目标端口：

```java
interface AttachmentContentStore {
    CompletionStage<StoredObject> put(
        String objectKey,
        InputStream content,
        long contentLength);

    InputStream open(String objectKey);

    CompletionStage<ObjectMetadata> stat(String objectKey);

    CompletionStage<Void> delete(String objectKey);
}
```

`ObsAttachmentContentStore` 是目标适配器。接口中的 `objectKey` 只由 Attachment
Service Repository 从 openGauss 读取，不能由客户端或 agent-service 提供。

每个附件在 OBS 中只有一份原始内容对象。`put` 必须使用“仅创建、不覆盖”的
条件语义；如果对象已存在，服务端不能覆盖，应重新生成 attachment 和 Object
Key。文件名不能参与 Object Key。

内存和本地存储约束：

```text
HTTP multipart stream
  -> bounded mate-service buffers
  -> OBS SDK streaming PUT
  -> shared private OBS
```

- 单上传应用层在途缓冲总量不超过 1 MiB；
- 总内存预算按“最大并发上传数 × 单上传缓冲”配置并监控；
- OBS 变慢时暂停读取客户端，不能无限排队；
- SHA-256、实际大小和有限 MIME 样本在流经时增量计算；
- 扫描器从 OBS 重新流式读取，不保留上传副本；
- 禁止 `Files.createTempFile`、`FilePart.transferTo(Path)`、
  `MultipartFile.getBytes()`、`DataBufferUtils.join()`、`collectList()` 和完整
  `ByteArrayOutputStream`；
- 如果 OBS SDK、扫描器或 Model Provider 只能接受本地文件或完整字节数组，v1
  不得启用该实现或宣称支持对应格式。

允许网络栈和 SDK 短暂持有少量分块缓冲，但不能形成第二份完整、持久化的文件。

## 9. Runtime 批量解析和内容流

![跨 Pod 解析与流式读取](./attachment_cross_pod_resolution_flow.svg)

[PlantUML 源码：`attachment_cross_pod_resolution_flow`](./diagram.puml#L188)

### 9.1 批量 resolve

内部接口：

```http
POST /mate-service/internal/v1/attachments:resolve
Authorization: Bearer <agent-service-access-token>
Content-Type: application/json

{
  "session_id": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
  "attachment_ids": [
    "attachment_011CZm8VpK4rNs6WtY2hDqfB"
  ]
}
```

Attachment Service 在一个短 openGauss 事务中：

1. 按稳定顺序锁定请求中的全部记录，避免并发 resolve 死锁；
2. 校验 agent-service 的不可变服务身份；
3. 校验每项都绑定当前 `session_id`、状态为 `READY`、未删除且未过期；
4. 不存在、跨 Session、已删除、已过期、`BLOCKED` 或 `FAILED` 统一返回
   `INVALID_ATTACHMENT`；只有在已确认当前 Session 归属后，`UPLOADING/PROCESSING`
   才可以整批返回 `ATTACHMENT_NOT_READY`；任一失败都整体回滚；
5. 全部成功后原子执行 `referenced=true`、
   `referenced_at=COALESCE(referenced_at, now())`、`expires_at=NULL` 并递增
   `row_version`；`referenced` 是单向状态，不存在 release；
6. 按请求顺序返回 `attachment_id/filename/media_type/size_bytes/sha256`。

Resolve 不返回 Object Key、OBS URL、ETag、Bucket、凭据或本地路径。批量接受是
全有或全无；不得启动“少一个附件”的 run。

Resolve 与 agent-service 的 RuntimeSessionStore 不做 XA。如果 resolve 成功后
模型预检、Message 提交或 run 创建失败，该附件会保守地继续保留，直到
Session 删除；不能把 `referenced` 回滚为 `false` 而导致已经进入历史的附件
被 24 小时任务误删。这是简化单向标记的有意代价。

### 9.2 内容流

```http
GET /mate-service/internal/v1/sessions/{session_id}/attachments/{attachment_id}/content
Authorization: Bearer <agent-service-access-token>
X-Expected-Attachment-SHA256: <64-lowercase-hex>
```

Attachment Service：

1. 用服务身份、`session_id`、`attachment_id` 和期望 SHA-256 查询 openGauss；
2. 只允许读取 `READY` 且 `referenced=true` 的记录；
3. 从数据库取得内部 Object Key；
4. 从 OBS 向 agent-service 流式代理，传播取消和背压；
5. 不在内存或本地磁盘聚合完整文件。

agent-service 仍要按 resolve 快照增量校验实际字节数和 SHA-256；不应把 OBS ETag
当作内容散列。历史重放使用同一
`session_id + attachment_id + expected_sha256`，不会选择“最新版本”，因为本设计
根本不允许覆盖附件内容。

Attachment Resolver 是固定 Runtime 组件，不注册成模型可见 Tool。模型只能看到
Provider 支持的内容块，不能看到 OBS 定位值、读取 Header 或服务凭据。

## 10. 删除和保留

### 10.1 单附件删除

公共接口：

```http
DELETE /mate-service/v1/sessions/{session_id}/attachments/{attachment_id}
```

- `referenced=false`：条件更新为 `DELETING`，返回 `202`；Worker 异步删除 OBS
  正文后更新为 `DELETED`；
- `referenced=true`：返回 `409 ATTACHMENT_REFERENCED`，避免既有 Session 历史
  失去原始内容；
- 重复删除 `DELETING/DELETED`：返回当前删除状态，保持幂等；
- 单附件删除不可恢复。需要再次使用时重新上传并获得新 ID。

未引用附件从创建起最多保留 24 小时。到期任务使用
`referenced=false AND expires_at <= now()` 认领并进入 `DELETING`。

### 10.2 Session 删除

Session 是附件保留的唯一业务边界。上层删除 Session 时：

1. `mate-service` 先请求 agent-service 停止或中止该 Runtime Session；
2. Attachment Service 将该 `session_id` 下所有非 `DELETED` 记录条件更新为
   `DELETING`；
3. Worker 幂等删除对应 OBS 对象；
4. openGauss 更新为 `DELETED` 并保留 tombstone；
5. Session 删除状态只有在附件删除任务被可靠登记后才能对外完成。

本版不提供附件恢复、跨 Session claim、引用计数或合规保留模型。因为每个附件只
属于一个 Session，Session 删除就是唯一的强制清理入口。

## 11. 一致性、补偿和多 Pod 恢复

![删除与对账流程](./attachment_deletion_and_reconciliation.svg)

[PlantUML 源码：`attachment_deletion_and_reconciliation`](./diagram.puml#L271)

OBS 和 openGauss 不参加同一个 XA 事务。服务通过状态机、唯一约束、条件更新、
短租约和周期对账恢复：

| 故障点 | 可观察状态 | 补偿 |
|---|---|---|
| DB 插入成功、OBS 上传失败 | `UPLOADING` 或 `FAILED` | 标记 `FAILED`，删除可能残留的随机 Object Key |
| OBS 上传成功、DB 更新 `PROCESSING` 失败 | `UPLOADING` + OBS 对象 | 对账任务用 DB 内 Object Key 执行 `stat`；校验成功后恢复为 `PROCESSING`，否则删除对象并失败 |
| 上传响应丢失 | 客户端不知道 ID，服务端可能已 `PROCESSING` | 客户端重新上传获得新 ID；旧的未引用记录 24 小时后清理 |
| 扫描 Pod 崩溃 | `PROCESSING` 且 lease 到期 | 其他 Pod 重新认领并从 OBS 重扫 |
| DB 已 `DELETING`、OBS 删除失败 | `DELETING` | 增加 `attempt_count`、设置 `next_attempt_at` 并退避重试 |
| OBS 已删、DB 更新 `DELETED` 失败 | `DELETING`，OBS `NotFound` | 将 `NotFound` 视为幂等删除成功并更新 tombstone |
| 上传 Pod 与读取 Pod 不同 | 共享 DB 和 OBS 均可见 | 任意 Pod 通过 DB 定位并从 OBS 流式读取 |

缓存只能保存非权威元数据。缓存未命中或 Pod 重启必须回源 openGauss/OBS；缓存
命中也不能绕过 Session、状态和 SHA-256 校验。

## 12. 安全与日志边界

- 公共接口复用 CampusMate 现有用户认证，内部接口只接受 agent-service 的短期
  service-to-service access token；
- Attachment Service 根据当前认证上下文判断 Session 权限，不接受请求体自报
  tenant/user；
- 不存在、越权、跨 Session、过期或删除统一投影为 `INVALID_ATTACHMENT`；
- 上述统一投影适用于 Runtime `resolve/content` 和无权的公共请求。已通过
  Session 授权的公共状态 GET 可以返回 `DELETING/DELETED` tombstone 投影，
  便于客户端确认异步删除；
- 文件名在保存前去除控制字符和路径分隔符，UI 显示时仍需转义；
- 声明 MIME 只供审计，Runtime 使用 `detected_media_type`；
- 日志只记录 `attachment_id`、Session 的受控摘要、状态、大小、耗时和稳定错误码；
- 日志不得记录 Object Key、AK/SK、Authorization、文件正文或原始恶意载荷；
- 病毒扫描结果只保存有界状态和规则标识，不保存扫描器内部秘密；
- JavaScript、Shell、HTML 和 Office 宏等均为不可信字节，不在 mate-service 或
  agent-service 进程内执行；
- 后续若需要代码执行，必须另行设计隔离 Sandbox Tool，不得扩展附件读取路径
  获得执行权限。

## 13. 错误语义

| 错误码 | HTTP | 可重试 | 说明 |
|---|---:|---:|---|
| `INVALID_REQUEST` | 400 | 否 | multipart、Header 或参数无效 |
| `ATTACHMENT_TOO_LARGE` | 413 | 否 | 声明或实际字节数超过 20 MiB |
| `ATTACHMENT_SIZE_MISMATCH` | 400 | 否 | 实际长度与 `X-Attachment-Size` 不同 |
| `SESSION_NOT_FOUND` | 404 | 否 | 公共上传时 Session 不存在或无权访问 |
| `INVALID_ATTACHMENT` | 404 | 否 | ID 不存在、跨 Session、删除、过期或无权访问的统一投影 |
| `ATTACHMENT_NOT_READY` | 409 | 是 | 已授权附件仍为 `UPLOADING/PROCESSING` |
| `ATTACHMENT_BLOCKED` | 422 | 否 | 安全扫描拒绝内容 |
| `ATTACHMENT_REFERENCED` | 409 | 否 | 已进入 Session 消息历史，不能单独删除 |
| `ATTACHMENT_CONTENT_MISMATCH` | 409 | 否 | 内容读取期望 SHA-256 与账本不一致 |
| `ATTACHMENT_STORAGE_UNAVAILABLE` | 503 | 是 | OBS 暂时不可用 |
| `ATTACHMENT_SCAN_UNAVAILABLE` | 503 | 是 | 扫描服务暂时不可用 |

错误响应只返回有界、脱敏信息。内部存储错误、Object Key 和供应商响应正文不得
进入 `details`。

## 14. 文档制品和实施端口

本专题包含：

- [`attachment-api.openapi.yaml`](./attachment-api.openapi.yaml)：公共上传、查询、
  删除及内部 resolve/content 的 OpenAPI 3.1 契约；
- [`schema.sql`](./schema.sql)：openGauss 表、约束、索引和注释；
- [`diagram.puml`](./diagram.puml)：四个稳定命名的 PlantUML 图源；
- 四个由 PlantUML 生成的 SVG。

目标 Java 端口：

```java
interface AttachmentContentStore {
    CompletionStage<StoredObject> put(
        String objectKey,
        InputStream content,
        long contentLength);

    InputStream open(String objectKey);

    CompletionStage<ObjectMetadata> stat(String objectKey);

    CompletionStage<Void> delete(String objectKey);
}
```

Repository 和状态机是独立端口，负责 openGauss 事务、租约、条件更新及
`attachment_id -> object_key` 映射。`ObsAttachmentContentStore` 不负责用户授权
或业务状态转换。

## 15. 验收场景

### 15.1 上传和内存

- 接受 1 字节和 20 MiB 文件；拒绝 0 字节与 `20 MiB + 1 byte`；
- 声明长度大于或小于实际长度均失败，不进入 `PROCESSING`；
- 上传中断不产生可读取的半文件；
- 并发压测中，堆使用量按“并发数 × 1 MiB 上限”增长，而不是按完整文件大小增长；
- Pod 文件系统和 `/tmp` 不出现上传正文；
- OBS 降速时对 HTTP 请求施加背压。

### 15.2 状态与客户端

- 默认和 `respond-async` 返回 `202 + Location + Retry-After`；
- `wait=N` 在 10 秒上限内返回 `201`、`202`、`422` 或 `503`；返回
  `422/503` 且资源已创建时包含 `Location`；
- 轮询能观察 `PROCESSING -> READY/BLOCKED/FAILED`；
- 特权安全撤销能执行 `READY -> BLOCKED`，之后的 resolve/content 均被拒绝；
- 只有 `READY` 能被批量 resolve。

### 15.3 多 Pod 和故障恢复

- Pod A 上传、Pod B 扫描、Pod C 查询、agent-service Pod D 读取均成功；
- 删除或重启任一 Pod 不影响已 `READY` 的共享附件；
- 扫描 lease 到期可被其他 Pod 接管；
- OBS 成功/DB 失败、DB 成功/OBS 失败和删除失败均由对账恢复；
- 缓存清空后仍可仅凭共享 DB/OBS 恢复。

### 15.4 授权、完整性和删除

- 跨 Session、错误服务身份、非 READY、过期和删除记录均被拒绝；
- 批量 resolve 要么全部设置 `referenced=true`，要么全部不变；
- 内容流必须与 `size_bytes + sha256` 一致；
- 未引用附件可单独删除，已引用返回 `409`；
- 24 小时未引用附件自动清理；Session 删除不可恢复；
- PDF 和 JS 都按原始不可信字节处理，JS 从不执行。

## 16. 图表生成与验证

在专题目录执行：

```bash
plantuml -tsvg diagram.puml
```

提交前验证：

- OpenAPI 3.1 YAML 可解析，所有 `$ref` 能解析；
- `schema.sql` 只有元数据列，不包含 BLOB/BYTEA；
- `.puml` 只含 ASCII，且没有 Mermaid；
- 四个 SVG 均为有效 XML并与图源同步；
- Markdown 中每个 SVG 路径和 PlantUML 行锚存在；
- `git diff --check` 通过；
- 三份用户元数据 JSON 不进入本专题提交。

## 17. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| `v1.0.0` | 2026-08-03 | 首版目标设计；确定 OBS 正文、openGauss 元数据、20 MiB 流式上传、异步扫描、内部批量解析、跨 Pod 读取、租约和补偿边界 |
