# CampusAgent Runtime WebSocket v2 HTML 文档

本目录的 [`index.html`](index.html) 是从上级目录的
[`chat-ws-v2.asyncapi.yaml`](../chat-ws-v2.asyncapi.yaml) 生成的开发者浏览版。

页面采用以下展示策略：

- 以 `connect`、`chat.send` 等 Operation 作为主要导航；
- 默认展开最小 JSON Message 示例；
- Payload 区域展示字段类型、必填项、枚举、长度和组合约束；
- Schemas 区域保留完整复用模型；
- 隐藏冗长的总体介绍和独立 Message 总表，避免与 Operation 内容重复；
- 保留 Server、Operation 和 Schema 导航，便于在连接信息、JSON 和约束间切换。

重新生成：

```bash
./generate-chat-ws-v2-docs.sh
```

生成工具固定为 `@asyncapi/cli@6.0.2` 和
`@asyncapi/html-template@3.5.6`。不要手工修改 `index.html`；应先修改规范源文件，
通过校验后重新生成。
