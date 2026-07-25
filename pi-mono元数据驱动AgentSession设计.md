# pi-mono 元数据驱动 AgentSession 设计

> 文档状态：目标设计（尚未实施）
>
> 文档版本：1.1
>
> 更新日期：2026-07-25
>
> pi-mono 源码基线：`fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc`

## 1. 本次修订结论

本次修订删除了“为每个 Agent 生成本地 Agent 定义文件”的设计。最终方案是：

1. AGENT、SKILL、TOOL 元数据由上层 Registry、管理服务或启动程序查询；
2. 元数据解析、版本锁定、依赖闭包和权限合并结果保存在内存对象中；
3. 不生成或读取 `AGENT.json`；
4. 不要求生成或读取 `agent-runtime.json`；
5. 不要求生成 `SYSTEM.md`，AGENT 元数据中的 `system_prompt` 在内存中渲染为字符串；
6. 开发人员只在 Agent 资源目录预置完整 `SKILL.md`；
7. TOOL 的实际执行统一委托 TOOL 管理器；
8. MODEL 的实际推理统一委托 MODEL 管理器；
9. 使用 pi 高层 `createAgentSession()` 时，SDK 会自动创建 `SessionManager`，它不是缺失模块；
10. 为确保“不使用的 pi 原生文件”连物理扫描都不发生，目标方案使用最小化的自定义 `ResourceLoader`，不使用 `DefaultResourceLoader` 的环境自动发现。

最小 Agent 资源目录因此只有：

```text
<agent-root>/
└── skills/
    └── <skill-name>/
        └── SKILL.md
```

元数据不是从这个目录读取的。`<agent-root>` 只是开发人员预置 Skill 文档的资源根目录。

## 2. 文档范围

### 2.1 目标

本文回答：

- 当前三类元数据是否足以创建一个全新 Agent；
- 为什么不需要 `AGENT.json`；
- pi 原生文件在默认模式下如何使用；
- 元数据 Agent 模式下哪些原生文件实际使用、条件使用或完全不使用；
- 如何避免被禁用资源仍被 `DefaultResourceLoader` 探测；
- 通用装配器需要承担什么职责；
- TOOL 管理器如何接管 Tool 执行；
- MODEL 管理器只有 modelId 时，如何补充 pi 必需的 `Model` 字段；
- `cwd` 和 `SessionManager` 应如何处理。

### 2.2 非目标

本文不实施：

- pi-mono 代码修改；
- TOOL 管理器或 MODEL 管理器代码修改；
- 元数据 Registry 或管理平台；
- Skill `scripts/`、`references/` 或其他附属资源；
- 运行中热更新；
- Agent 专属 extension、prompt template 或 theme；
- 本地 Agent 运行清单文件。

### 2.3 参考范围

本文只参考：

- `/Users/z/pi-mono`；
- `/Users/z/设计/pi-mono-agent-session-context`；
- `/Users/z/设计/AGENT元数据设计.json`；
- `/Users/z/设计/SKILL元数据设计.json`；
- `/Users/z/设计/TOOL元数据设计.json`。

未读取或引用 `/Users/z/设计` 下的其他设计文档。

### 2.4 事实、决策和原因的标记

| 分类 | 含义 |
|---|---|
| 当前行为 | 已由指定 pi-mono 源码确认 |
| 目标设计 | 本文建议新增的行为，pi 当前尚未实现 |
| 产品约束 | 由当前产品范围决定，例如不支持 Skill 附属资源 |
| 安全加固 | 比 pi 默认行为更严格，例如禁止环境资源自动发现 |
| 架构变化 | 新增通用装配器或管理器适配边界 |

文中的 TypeScript 接口均为目标设计示例，不代表已经存在的 pi 公共 API。

## 3. 源码基线与证据

### 3.1 源码基线

```text
repository: /Users/z/pi-mono
commit:     fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc
```

### 3.2 关键源码锚点

| 主题 | 仓库相对路径 | 符号或基线行 |
|---|---|---|
| SDK 创建入口 | `packages/coding-agent/src/core/sdk.ts` | `CreateAgentSessionOptions`、`createAgentSession()`，约 29、169 行 |
| cwd 解析 | `packages/coding-agent/src/core/sdk.ts` | `options.cwd ?? options.sessionManager?.getCwd() ?? process.cwd()`，约 170 行 |
| 自动创建 SessionManager | `packages/coding-agent/src/core/sdk.ts` | `options.sessionManager ?? SessionManager.create(...)`，约 180 行 |
| 服务创建 | `packages/coding-agent/src/core/agent-session-services.ts` | `createAgentSessionServices()`，约 134 行 |
| ResourceLoader 接口 | `packages/coding-agent/src/core/resource-loader.ts` | `ResourceLoader`，约 38 行 |
| 默认资源 reload | `packages/coding-agent/src/core/resource-loader.ts` | `DefaultResourceLoader.reload()`，约 338 行 |
| 项目指令扫描 | `packages/coding-agent/src/core/resource-loader.ts` | `loadProjectContextFiles()`，约 85 行 |
| 自动资源解析 | `packages/coding-agent/src/core/package-manager.ts` | `DefaultPackageManager.resolve()`，约 901 行 |
| 自动目录发现 | `packages/coding-agent/src/core/package-manager.ts` | `addAutoDiscoveredResources()`，约 2303 行 |
| Skill 精确加载 | `packages/coding-agent/src/core/skills.ts` | `loadSkills()`，约 387 行 |
| system prompt 构建 | `packages/coding-agent/src/core/system-prompt.ts` | `buildSystemPrompt()` |
| Tool 注册 | `packages/coding-agent/src/core/agent-session.ts` | `_refreshToolRegistry()`，约 2458 行 |
| Tool 激活 | `packages/coding-agent/src/core/agent-session.ts` | `setActiveToolsByName()`，约 926 行 |
| custom Tool 包装 | `packages/coding-agent/src/core/tools/tool-definition-wrapper.ts` | `wrapToolDefinition()` |
| Tool 串行执行 | `packages/agent/src/agent-loop.ts` | `executeToolCalls()`，约 413 行 |
| ModelRuntime 创建 | `packages/coding-agent/src/core/model-runtime.ts` | `ModelRuntime.create()`，约 133 行 |
| native Provider | `packages/coding-agent/src/core/model-runtime.ts` | `registerNativeProvider()`，约 548 行 |
| pi Model 必填字段 | `packages/ai/src/types.ts` | `Model`，约 710 行 |
| thinking clamp | `packages/ai/src/models.ts` | `clampThinkingLevel()`，约 674 行 |
| Session 默认目录 | `packages/coding-agent/src/core/session-manager.ts` | `getDefaultSessionDir()`，约 483 行 |
| Session 创建 | `packages/coding-agent/src/core/session-manager.ts` | `SessionManager.create()`，约 1519 行 |
| Session 上下文恢复 | `packages/coding-agent/src/core/session-manager.ts` | `buildSessionContext()`，约 461 行 |

### 3.3 已确认的不存在项

对当前源码执行全仓搜索后：

```text
AGENT.json         无 pi 原生读取逻辑
agent-runtime.json 无 pi 原生读取逻辑
```

因此两者都不能被描述成 pi 的既有文件格式。

## 4. `AGENT.json` 为什么应该删除

### 4.1 它不是 pi 原生文件

pi 原生的 `AGENTS.md` 与 `AGENT.json` 不是同一种概念：

| 名称 | pi 是否原生 | 作用 |
|---|---:|---|
| `AGENTS.md` | 是 | 项目或目录级自然语言指令，正文进入 system prompt |
| `AGENT.json` | 否 | pi 没有该定义，也没有对应 reader、schema 或生命周期 |

`AGENTS.md` 不能表达：

- Agent ID 和版本；
- 允许模型集合；
- 绑定 Skill 和 Tool；
- Tool 权限；
- Tool 输入输出 schema；
- TOOL/MODEL 管理器路由。

所以不能把 `AGENTS.md` 当作 AGENT 元数据文件，也没有必要另造一个 `AGENT.json` 放在 Agent 目录。

### 4.2 删除后的元数据来源

目标设计中，启动程序从上层系统获取元数据，再直接调用装配器：

```ts
const { session } = await createAgentSessionFromMetadata({
  agentMetadata,
  skillMetadataList,
  toolMetadataList,
  agentRoot: "/opt/agent-resources/java-review-agent",
  cwd: "/workspace/orders",
  toolManagerClient,
  modelManagerClient,
});
```

这里的 `agentMetadata` 是内存对象，不要求磁盘上存在同名 JSON。

如果元数据在网络上传输时使用 JSON，那只是 Registry 或 API 的传输格式，不是 pi 运行目录中的原生文件。

### 4.3 `agent-runtime.json` 同样不是必需项

旧设计使用 `agent-runtime.json` 保存解析后的依赖、权限和摘要。它可以用于离线部署或可复现构建，但不是创建 AgentSession 的必要条件。

当前目标已经具备：

- 上层程序可提供三类元数据；
- 版本可在上层 Registry 解析；
- 通用装配器可在内存中计算闭包和权限；
- Agent 版本变化后重建 AgentSession；
- 不要求离线运行包。

所以第一版不生成 `agent-runtime.json`。解析结果使用内存结构：

```ts
interface ResolvedAgentDefinition {
  agent: AgentMetadata;
  defaultModelId: string;
  allowedModelIds: readonly string[];
  skills: readonly ResolvedSkill[];
  tools: readonly ResolvedTool[];
  renderedSystemPrompt: string;
  effectivePermissions: ReadonlyMap<
    string,
    "allow" | "ask" | "deny"
  >;
}
```

若未来需要审计和可复现性，应优先把解析快照、版本和摘要写入发布数据库或审计记录，而不是把本地运行清单重新设为必需文件。

## 5. 三类元数据是否足够

### 5.1 结论

三类元数据加上开发人员预置的 `SKILL.md`，足以描述一个 Agent 的业务定义，但不足以单独完成 pi AgentSession 的技术装配。

还需要三个通用基础能力：

1. 元数据解析器；
2. AgentSession 通用装配器；
3. TOOL 和 MODEL 两个适配器。

这些能力对所有 Agent 共用，不是每个 Agent 单独开发。

### 5.2 已经足够表达的内容

| 内容 | 来源 |
|---|---|
| Agent 身份、版本、启停 | AGENT 元数据 |
| 默认模型候选 | `AGENT.models[0]` |
| 允许模型集合 | `AGENT.models` |
| Agent 稳定行为 | `AGENT.system_prompt` |
| Agent 直接绑定 Tool、Skill | AGENT 元数据 |
| Skill 依赖和 Tool 依赖 | SKILL 元数据 |
| Skill 实际工作流 | 开发人员预置的 `SKILL.md` |
| Tool 名称、描述、输入输出 schema | TOOL 元数据 |
| Tool 定位键 | `TOOL.id + TOOL.version` |
| Tool 基础权限 | `TOOL.permission` |
| Agent/Skill 收紧权限 | AGENT、SKILL permission |

### 5.3 不应塞入 AGENT 元数据的运行配置

以下信息需要补充，但更适合作为平台配置或注入依赖：

| 缺口 | 建议来源 | 原因 |
|---|---|---|
| `cwd` | Agent 部署配置或 SDK 启动参数 | 是运行位置，不是 Agent 能力定义 |
| Skill 文件路径解析 | `SkillDocumentResolver` | 元数据当前没有磁盘路径 |
| TOOL 管理器连接 | 注入的 `ToolManagerClient` | 属于部署和通信配置 |
| MODEL 管理器连接 | 注入的 `ModelManagerClient` | 属于部署和通信配置 |
| pi Model 能力字段 | 平台 `ModelDefaults` 或管理器 descriptor | AGENT 只保存 modelId |
| Session 是否持久化 | 启动选项 | 属于运行策略 |
| Session 存储目录 | 启动选项 | 属于部署隔离 |
| Tool timeout、结果大小 | 平台默认或未来 TOOL 字段 | 当前元数据未定义 |

### 5.4 当前元数据仍需明确的约束

正式实现前应把三个说明性 JSON 固化为 JSON Schema，并约束：

- `type` 固定为 `agent`、`skill`、`tool`；
- `version` 是从 1 开始的整数；
- `enabled` 使用真实 boolean；
- permission 使用固定枚举；
- 时间使用 ISO-8601；
- 引用 ID、版本和 Tool name 满足格式约束；
- 同一 permission 层的 deny、ask、allow 不能交叉；
- `input_schema`、`output_schema` 是受支持的 JSON Schema 子集；
- 未知字段采用明确的兼容策略。

## 6. 最小运行结构

### 6.1 Agent 资源目录

```text
/opt/agent-resources/
└── java-review-agent/
    └── skills/
        └── java-review/
            └── SKILL.md
```

完整 `SKILL.md` 示例：

```markdown
---
name: java-review
description: 审查 Java 变更的正确性、安全性、并发风险和测试覆盖
---

# Java Review

1. 使用 `read` 阅读变更文件和直接调用方。
2. 必要时使用 `repo-search` 查找接口实现和相似代码。
3. 检查空值、资源释放、事务、并发和权限边界。
4. 检查测试是否覆盖成功、失败和边界路径。

输出时给出文件、相关符号、触发条件和影响。
```

该目录中不需要：

```text
AGENT.json
agent-runtime.json
SYSTEM.md
metadata.json
models.json
models-store.json
trust.json
settings.json
auth.json
extensions/
prompts/
themes/
scripts/
references/
```

### 6.2 Skill 路径解析

因为 SKILL 元数据没有 `file_path`，装配器需要一个通用 resolver：

```ts
interface SkillDocumentResolver {
  resolve(input: {
    agentRoot: string;
    skillId: string;
    skillVersion: number;
    skillName: string;
  }): Promise<string>;
}
```

第一版约定：

```text
<agent-root>/skills/<skill-name>/SKILL.md
```

resolver 必须验证：

- 规范化后的路径仍在 `<agent-root>/skills` 内；
- 文件真实存在；
- 不允许指向 Agent 根目录外的符号链接；
- frontmatter `name`、`description` 与元数据一致；
- 没有 `scripts/`、`references/` 或其他未支持依赖；
- 同一 Agent 中 Skill name 唯一。

如果上层发布系统已经能按 `(skillId, version)` 返回精确文件路径，也可以注入另一种 resolver，而不修改 AgentSession 装配逻辑。

### 6.3 system prompt 不落盘

AGENT 元数据：

```json
{
  "system_prompt": {
    "role": "你是一名资深 Java 代码审查工程师。",
    "objective": "发现能够由代码证据支持的问题。",
    "instructions": "先理解调用链，再形成结论。",
    "tool_policy": "优先使用 read 获取精确代码。",
    "safety": "不执行未授权修改。",
    "completion": "覆盖目标变更、调用方和测试后结束。",
    "response_style": "使用中文，先给结论。",
    "example": "P1：空指针风险。"
  }
}
```

在内存中按固定顺序渲染：

```markdown
# Role

你是一名资深 Java 代码审查工程师。

# Objective

发现能够由代码证据支持的问题。

# Instructions

先理解调用链，再形成结论。

# Tool Policy

优先使用 read 获取精确代码。

# Safety

不执行未授权修改。

# Completion

覆盖目标变更、调用方和测试后结束。

# Response Style

使用中文，先给结论。

# Example

P1：空指针风险。
```

这个字符串通过自定义 ResourceLoader 的 `getSystemPrompt()` 返回。pi 的 `buildSystemPrompt()` 仍会追加：

1. 保留的项目 `AGENTS.md/CLAUDE.md`；
2. 可用 Skill 的名称、描述和路径；
3. 当前 `cwd`。

## 7. pi 原生文件使用排查

### 7.1 判断口径

本文区分四种状态：

| 状态 | 含义 |
|---|---|
| 使用 | 元数据 Agent 必须读取并使内容生效 |
| 条件使用 | 只在明确开启某项能力时读取 |
| 不使用 | 目标模式不读取，也不允许影响 AgentSession |
| 默认 Loader 可能探测 | 设置 `no*` 后不生效，但 `DefaultResourceLoader` 仍可能检查目录或文件是否存在 |

“不进入模型消息”不等于“不使用”。例如默认 pi 的 `settings.json` 不会原文发送给模型，但会改变运行配置，仍然属于使用。

### 7.2 完整矩阵

| pi 原生文件或目录 | pi 默认行为 | 元数据 Agent 目标状态 | 替代或原因 |
|---|---|---|---|
| `$AGENT_DIR/settings.json` | `SettingsManager.create()` 尝试读取全局设置 | 不使用 | 注入 `SettingsManager.inMemory()` |
| `$CWD/.pi/settings.json` | 项目可信时合并项目设置；直接 SDK 默认创建文件型 SettingsManager | 不使用 | 运行参数由装配器显式传入 |
| `$AGENT_DIR/trust.json` | CLI 的 `ProjectTrustStore` 保存项目资源信任 | 不使用 | 不加载项目 `.pi` 资源；保留的项目指令由最小 Loader 精确读取 |
| `$AGENT_DIR/auth.json` | 默认 `ModelRuntime` 的 credential store | 不使用 | 注入 `InMemoryCredentialStore`；认证由 MODEL 管理器负责 |
| `$AGENT_DIR/models.json` | 增加或覆盖 provider、model | 不使用 | `modelsPath: null`，Model 由 manager Provider 和平台默认字段构造 |
| `$AGENT_DIR/models-store.json` | 动态模型目录缓存 | 不使用 | `modelsPath: null` 时使用内存 models store |
| `$AGENT_DIR/AGENTS.md` 等 | `loadProjectContextFiles()` 作为全局指令加载 | 不使用 | 防止用户全局指令改变固定 Agent |
| 文件系统根至项目根之外的 `AGENTS.md/CLAUDE.md` | 默认从根一路扫描到 cwd | 不使用 | 安全加固：扫描范围收窄到最近 git root 至 cwd |
| 最近 git root 至 cwd 的 `AGENTS.md/AGENTS.MD/CLAUDE.md/CLAUDE.MD` | 默认会加载，同目录按固定优先级取一个 | 使用 | 保留项目开发约束 |
| 无 git 仓库时 cwd 自身的上述指令文件 | 默认还会扫描所有祖先 | 使用 | 目标设计只保留 cwd 自身 |
| `$AGENT_DIR/SYSTEM.md` | 可替换 pi 默认 system prompt | 不使用 | system prompt 由 AGENT 元数据在内存渲染 |
| `$CWD/.pi/SYSTEM.md` | 可信项目文件优先于全局文件 | 不使用 | 不允许项目覆盖 Agent 身份 |
| `$AGENT_DIR/APPEND_SYSTEM.md` | 追加 system prompt | 不使用 | 不允许环境追加未声明规则 |
| `$CWD/.pi/APPEND_SYSTEM.md` | 可信项目可追加 system prompt | 不使用 | 同上 |
| `$AGENT_DIR/extensions/**/*.{ts,js}` | 加载并执行 extension | 不使用 | Tool/Model 由固定适配器提供 |
| `$CWD/.pi/extensions/**/*.{ts,js}` | 可信项目可执行 extension | 不使用 | 产品约束和安全加固 |
| `$AGENT_DIR/skills/**` | 自动发现用户 Skill | 不使用 | 只加载绑定 Agent 的精确 Skill 路径 |
| `~/.agents/skills/**` | 自动发现跨 Agent Skill | 不使用 | 防止环境 Skill 混入 |
| `$CWD/.pi/skills/**` | 可信项目自动发现 Skill | 不使用 | 项目 Skill 不属于固定 Agent 定义 |
| cwd 祖先的 `.agents/skills/**` | 可信时自动发现 | 不使用 | 同上 |
| `<agent-root>/skills/<name>/SKILL.md` | 不是 pi 固定默认路径，但可作为 additional path 加载 | 使用 | 开发人员预置的完整 Skill |
| `$AGENT_DIR/prompts/*.md` | 注册 prompt template | 不使用 | 当前元数据不支持 prompts |
| `$CWD/.pi/prompts/*.md` | 注册项目 prompt template | 不使用 | 同上 |
| `$AGENT_DIR/themes/*.json` | 加载 TUI theme | 不使用 | 当前元数据不支持 themes |
| `$CWD/.pi/themes/*.json` | 加载项目 theme | 不使用 | 同上 |
| package 根 `package.json` | 解析 `pi.extensions/skills/prompts/themes` | 不使用 | 不启用 package resource discovery |
| `$AGENT_DIR/npm/**`、`$AGENT_DIR/git/**` | 用户 package 安装和资源发现 | 不使用 | 所有资源显式注入 |
| `$CWD/.pi/npm/**`、`$CWD/.pi/git/**` | 项目 package 安装和资源发现 | 不使用 | 同上 |
| `.gitignore`、`.ignore`、`.fdignore` | 自动扫描时读取 ignore pattern | 不使用 | Skill 使用精确文件路径，不扫描目录 |
| Skill `scripts/` | pi Skill 可引用并由工具间接使用 | 不使用 | 产品约束：执行逻辑统一由 TOOL 管理器承载 |
| Skill `references/` | pi Skill 可通过 read 间接读取 | 不使用 | 产品约束：第一版不支持 |
| session `*.jsonl` | `SessionManager` 保存和恢复消息树 | 条件使用 | 持久会话时使用；内存会话时不读写 |
| `.git/` 标记 | 可用于判断项目根 | 条件使用 | 只用于限定项目指令扫描边界，不注入模型 |

### 7.3 其他 pi 运维文件

下列文件或目录属于 CLI、TUI、迁移或本地辅助工具，不参与 AgentSession 的核心上下文装配：

| 文件或目录 | pi 中的用途 | 元数据 Agent 说明 |
|---|---|---|
| `$AGENT_DIR/keybindings.json` | TUI 快捷键配置 | SDK 嵌入模式不使用；若外层复用 pi TUI，可能由 TUI 使用，但不定义 Agent |
| `$AGENT_DIR/bin/` | 保存 pi 管理的 `fd`、`rg` 等辅助二进制 | manager Tool 模式不依赖；若外层 pi TUI 自行检查辅助工具，属于 UI/宿主行为 |
| `$AGENT_DIR/tools/` | 旧版辅助二进制目录，迁移到 `bin/` | 不使用 |
| `$AGENT_DIR/oauth.json` | 旧 credential 文件，CLI 迁移到 `auth.json` | 不使用；MODEL 管理器认证不走 pi credential 迁移 |
| 用户或项目 `commands/` | 旧 prompt 目录，CLI 可迁移为 `prompts/` | 不使用 |
| `$AGENT_DIR/tmp/extensions/` | extension/package 处理临时目录 | 不使用 |
| `$AGENT_DIR/*-debug.log` | pi debug 日志输出 | 不作为 Agent 输入；是否写日志由宿主运行方式决定 |

这里的“不参与”是指不参与元数据 Agent 定义、system prompt、Tool schema、Model 选择和 session 消息构建。若最终产品直接复用完整 pi CLI/TUI，宿主界面仍可能读取自己的快捷键或写调试日志，应在进程级文件访问审计中单独处理。

### 7.4 真正会读取的文件

在目标模式下，磁盘读取收敛为三类：

```text
1. <agent-root>/skills/<skill-name>/SKILL.md
2. <project-root> ... <cwd> 中每层至多一个 AGENTS/CLAUDE 文件
3. session JSONL（仅持久化、恢复、continue 或 fork 时）
```

除此之外，模型和工具执行所需数据都通过注入客户端或内存对象获得。

### 7.5 项目指令文件规则

同一目录候选优先级保持与 pi 一致：

```text
AGENTS.md
> AGENTS.MD
> CLAUDE.md
> CLAUDE.MD
```

目标扫描范围与 pi 默认行为不同：

| 场景 | pi 默认 | 目标设计 |
|---|---|---|
| cwd 在 git 仓库中 | 文件系统根至 cwd | 最近 git root 至 cwd |
| cwd 不在 git 仓库中 | 文件系统根至 cwd | 只读取 cwd |
| `$AGENT_DIR` 全局指令 | 读取 | 不读取 |

这是安全加固，不是对 pi 当前行为的描述。

项目指令示例：

```markdown
# Repository instructions

- Use Java 21.
- Keep changes inside the affected Maven module.
- Run focused tests.
- Never edit generated sources manually.
```

### 7.6 session JSONL 示例

持久会话由 pi 自动维护：

```jsonl
{"type":"session","version":3,"id":"session-example","timestamp":"2026-07-25T08:00:00.000Z","cwd":"/workspace/orders"}
{"type":"model_change","id":"a1","parentId":null,"timestamp":"2026-07-25T08:00:00.010Z","provider":"model-manager","modelId":"model-code-pro"}
{"type":"thinking_level_change","id":"a2","parentId":"a1","timestamp":"2026-07-25T08:00:00.011Z","thinkingLevel":"off"}
{"type":"message","id":"a3","parentId":"a2","timestamp":"2026-07-25T08:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"审查订单模块"}],"timestamp":1784966460000}}
```

恢复时只有当前 leaf 分支中可转换的消息进入模型上下文。session header、entry ID、父子关系和 sibling branch 不会原文发送给模型。

## 8. 为什么不能只使用 `DefaultResourceLoader + no*`

### 8.1 当前代码事实

`DefaultResourceLoader.reload()` 的顺序中：

```ts
await this.settingsManager.reload();
const resolvedPaths = await this.packageManager.resolve();
```

发生在 `noExtensions`、`noSkills`、`noPromptTemplates`、`noThemes` 对最终候选集合进行过滤之前。

`DefaultPackageManager.resolve()` 又会调用：

```ts
this.addAutoDiscoveredResources(
  accumulator,
  globalSettings,
  projectSettings,
  globalBaseDir,
  projectBaseDir,
);
```

它会检查用户级和项目级约定目录。由此得到：

- `noSkills: true` 能阻止自动发现的 Skill 生效；
- `additionalSkillPaths` 仍能显式加载；
- 但 package manager 仍可能物理探测 `$AGENT_DIR/skills`、`.pi/skills` 等目录；
- `agentsFilesOverride` 是读取之后过滤，不能阻止被过滤文件先被读取；
- `systemPrompt` 和 `appendSystemPrompt: []` 能阻止 ambient SYSTEM 内容生效，但 Default Loader 仍承担不必要的环境发现职责。

### 8.2 目标设计：最小 ResourceLoader

要让“不使用”同时表示“不读取”，通用装配器注入：

```ts
class MetadataResourceLoader implements ResourceLoader {
  constructor(private readonly input: {
    cwd: string;
    agentRoot: string;
    renderedSystemPrompt: string;
    skillFiles: readonly string[];
    preserveProjectContext: boolean;
  }) {}

  async reload(): Promise<void> {
    // 只解析 input.skillFiles 中列出的精确 SKILL.md。
    // 只扫描允许范围内的 AGENTS/CLAUDE。
    // 不调用 DefaultPackageManager.resolve()。
  }

  getExtensions() {
    return emptyExtensionsResult;
  }

  getSkills() {
    return this.loadedSkills;
  }

  getPrompts() {
    return { prompts: [], diagnostics: [] };
  }

  getThemes() {
    return { themes: [], diagnostics: [] };
  }

  getAgentsFiles() {
    return { agentsFiles: this.projectContextFiles };
  }

  getSystemPrompt() {
    return this.input.renderedSystemPrompt;
  }

  getAppendSystemPrompt() {
    return [];
  }

  extendResources(): void {
    throw new Error(
      "Dynamic resource discovery is disabled for metadata agents",
    );
  }
}
```

Skill 可复用 pi 的精确加载能力：

```ts
const loadedSkills = loadSkills({
  cwd,
  agentDir: agentRoot,
  skillPaths: exactSkillFiles,
  includeDefaults: false,
});
```

由于传入的是精确 `SKILL.md` 文件而不是目录，不需要读取 `.gitignore`、`.ignore` 或 `.fdignore`。

### 8.3 接入方式

高层 SDK 已支持：

```ts
interface CreateAgentSessionOptions {
  resourceLoader?: ResourceLoader;
}
```

所以第一版装配器可以直接调用 `createAgentSession()`，无须使用只会创建 `DefaultResourceLoader` 的 `createAgentSessionServices()`。

如果未来必须统一走 `createAgentSessionServices()`，则目标改造是给它增加可选的 `resourceLoader` 注入参数。没有必要修改 agent loop。

## 9. 元数据解析、依赖与权限

### 9.1 版本解析

规则：

1. 显式 version 必须精确存在；
2. 省略 version 时，在创建 AgentSession 前解析为当前最高可用版本；
3. 同一次装配中的解析结果固定在 `ResolvedAgentDefinition`；
4. 运行期间不重新查询 latest；
5. Agent、Skill 或 Tool 版本变化后重建 AgentSession；
6. 解析快照和摘要写审计系统，不要求写本地运行清单。

通用 Registry：

```ts
interface MetadataRegistry {
  getAgent(id: string, version: number): Promise<AgentMetadata>;
  getSkill(id: string, version: number): Promise<SkillMetadata>;
  getTool(id: string, version: number): Promise<ToolMetadata>;

  resolveLatest(
    type: "skill" | "tool",
    id: string,
  ): Promise<number>;
}
```

### 9.2 Skill 依赖闭包

```text
AGENT.binding_skills
→ SKILL.binding_skills
→ 递归展开到没有新 Skill
```

必须校验：

- 循环依赖；
- 同一个 Skill ID 被解析成不同版本；
- Skill name 冲突；
- Skill 文件存在且 frontmatter 一致；
- Skill 依赖的 Tool 可达；
- Skill 非空时存在 model-facing name 为 `read` 的 Tool。

`binding_skills` 只表示依赖和可用性，不表示 pi 会自动执行子 Skill。父 Skill 应在正文中说明何时读取另一个 Skill。

### 9.3 Tool 依赖闭包

```text
AGENT.binding_tools
+ 所有 Skill 闭包中的 binding_tools
```

必须校验：

- Tool 存在且 `enabled=true`；
- 同一个 Tool ID 不出现不同版本；
- model-facing Tool name 唯一；
- permission 引用的 Tool 位于闭包中；
- `input_schema`、`output_schema` 可被适配器支持。

### 9.4 权限合并

权限强度：

```text
allow < ask < deny
```

最终权限：

```ts
effectivePermission = mostRestrictive(
  tool.permission,
  ...applicableSkillPermissions,
  agent.permission,
);
```

即：

```text
deny > ask > allow
```

运行语义：

| 权限 | 行为 |
|---|---|
| deny | 不注册 ToolDefinition，模型看不到 |
| ask | Tool 可见，每次执行前确认 |
| allow | pi 侧无需确认，直接交给 TOOL 管理器 |

TOOL 管理器仍需执行自己的最终授权，不能只信任 pi 传入的 approved 标记。

## 10. 通用 AgentSession 装配器

### 10.1 为什么装配器确实缺失

pi 提供通用 SDK，但不知道当前产品的：

- AGENT/SKILL/TOOL 元数据格式；
- 版本解析规则；
- Skill 文件目录约定；
- 三层权限规则；
- TOOL 管理器协议；
- MODEL 管理器协议；
- 固定 cwd 策略；
- ambient 文件隔离策略。

因此缺失的是产品级通用装配器，不是 pi 的 `SessionManager`。

### 10.2 建议入口

```ts
interface CreateMetadataAgentSessionOptions {
  agentMetadata: AgentMetadata;
  skillMetadataList: readonly SkillMetadata[];
  toolMetadataList: readonly ToolMetadata[];

  agentRoot: string;
  cwd: string;

  toolManagerClient: ToolManagerClient;
  modelManagerClient: ModelManagerClient;
  skillDocumentResolver: SkillDocumentResolver;
  modelDefaults: ModelDefaults;

  sessionManager?: SessionManager;
  piAgentDir?: string;
}

async function createAgentSessionFromMetadata(
  options: CreateMetadataAgentSessionOptions,
): Promise<CreateAgentSessionResult>;
```

### 10.3 创建顺序

```text
1. 校验 Agent enabled、元数据 schema 和固定 cwd
2. 解析 Skill/Tool 固定版本
3. 展开 Skill 与 Tool 依赖闭包
4. 计算 deny > ask > allow
5. 解析精确 SKILL.md 路径并校验 frontmatter
6. 把 AGENT.system_prompt 渲染成内存字符串
7. 构造 MODEL 管理器 native Provider
8. 构造 manager ToolDefinition[]
9. 创建 MetadataResourceLoader
10. 创建内存 SettingsManager 和隔离的 ModelRuntime
11. 调用高层 createAgentSession()
12. 返回 AgentSession 和内存解析诊断
```

### 10.4 关键装配参数

```ts
const result = await createAgentSession({
  cwd: fixedCwd,
  agentDir: piAgentDir,

  modelRuntime,
  model: defaultManagerModel,
  scopedModels: allowedManagerModels.map((model) => ({ model })),

  settingsManager: SettingsManager.inMemory(),
  resourceLoader: metadataResourceLoader,

  customTools: managerToolDefinitions,
  tools: managerToolDefinitions.map((tool) => tool.name),

  // 不传时由 SDK 自动创建。
  sessionManager: options.sessionManager,
});
```

`tools` 必须是显式 allowlist。不能只使用 `noTools: "builtin"`，因为显式 allowlist 才能保证模型只看到当前 Agent 解析出的 Tool name。

## 11. TOOL 管理器接入

### 11.1 当前 pi 接管点

当前 `CreateAgentSessionOptions` 支持：

```ts
interface CreateAgentSessionOptions {
  customTools?: ToolDefinition[];
}
```

`AgentSession._refreshToolRegistry()` 会合并 builtin、extension 和 SDK custom Tool；同名 custom Tool 可以覆盖 builtin 定义。显式 `tools` 再作为激活 allowlist。

因此不需要修改 `packages/agent/src/agent-loop.ts` 的 Tool Call 主循环。

### 11.2 客户端接口

```ts
interface ToolManagerClient {
  execute(
    request: ToolManagerExecuteRequest,
    options: {
      signal?: AbortSignal;
      onUpdate?: (update: ToolManagerUpdate) => void;
    },
  ): Promise<ToolManagerResult>;
}

interface ToolManagerExecuteRequest {
  invocationId: string;
  agentId: string;
  agentVersion: number;
  sessionId: string;
  cwd: string;

  toolId: string;
  toolVersion: number;
  toolName: string;
  source: "builtin-toolset" | "mcp-toolset";

  input: Record<string, unknown>;
  authorization: {
    policy: "allow" | "ask";
    approved: boolean;
  };
}

interface ToolManagerResult {
  output: unknown;
  details?: Record<string, unknown>;
}
```

### 11.3 TOOL 元数据映射

| TOOL 元数据 | pi `ToolDefinition` |
|---|---|
| `name` | `name` |
| `display_name` | `label` |
| `description` | `description` |
| `input_schema` | 校验并转换为 `parameters` 使用的 TypeBox schema |
| 固定策略 | `executionMode: "sequential"` |
| `id/version/source/output_schema/permission` | 由 `execute()` 闭包捕获 |

第一版所有 manager Tool 都设置：

```ts
const executionMode = "sequential" as const;
```

pi 当前 agent loop 只要发现本批 Tool Call 中有一个 `executionMode="sequential"`，就按顺序执行整批 Tool Call。

### 11.4 通用代理示例

```ts
function createManagerToolDefinition(
  tool: ResolvedTool,
  client: ToolManagerClient,
): ToolDefinition {
  if (tool.effectivePermission === "deny") {
    throw new Error(`Denied tool must not be registered: ${tool.name}`);
  }
  const policy = tool.effectivePermission;

  return {
    name: tool.name,
    label: tool.displayName,
    description: tool.description,
    parameters: toTypeBoxSchema(tool.inputSchema),
    executionMode: "sequential",

    async execute(toolCallId, input, signal, onUpdate, ctx) {
      const approved =
        policy === "allow"
          ? true
          : ctx.hasUI
            ? await ctx.ui.confirm(
                `执行工具 ${tool.displayName}`,
                `是否允许本次调用 ${tool.name}？`,
              )
            : false;

      if (!approved) {
        throw new Error(`Tool permission denied: ${tool.name}`);
      }

      const result = await client.execute(
        {
          invocationId: toolCallId,
          agentId: tool.agentId,
          agentVersion: tool.agentVersion,
          sessionId: ctx.sessionManager.getSessionId(),
          cwd: ctx.cwd,
          toolId: tool.id,
          toolVersion: tool.version,
          toolName: tool.name,
          source: tool.source,
          input,
          authorization: {
            policy,
            approved: true,
          },
        },
        {
          signal,
          onUpdate: (update) =>
            onUpdate?.(toPiToolUpdate(update)),
        },
      );

      assertSchema(tool.outputSchema, result.output);

      return {
        content: [{
          type: "text",
          text: stableStringify(result.output),
        }],
        details: {
          ...result.details,
          output: result.output,
          toolId: tool.id,
          toolVersion: tool.version,
        },
      };
    },
  };
}
```

约束：

- deny Tool 不进入 `customTools`；
- ask 在无交互 UI 时默认拒绝；
- `input_schema` 在调用管理器前校验；
- `output_schema` 在管理器返回后校验；
- 最终有效结果必须进入 `content`，只放 `details` 不会成为标准模型 Tool Result 文本；
- AbortSignal 需要由 client 转成管理器 cancel；
- Tool 执行失败通过 throw/reject 交给 pi 转换为 error Tool Result。

### 11.5 Skill 的 `read`

pi 只有在 active Tool 中存在 model-facing name 为 `read` 的 Tool 时，才会把可调用 Skill 元数据写入 system prompt。

所以：

- Agent 绑定 Skill 时必须绑定一个 `name="read"` 的 TOOL；
- `read` 的最终权限不能是 deny；
- TOOL 管理器的 `read` 必须允许读取精确白名单中的 `SKILL.md`；
- 如果 TOOL 管理器与 pi 不共享文件系统，client 需要把 Skill 文件映射成受控资源 ID 或内容读取通道。

这只是 Tool name 的兼容要求，实际执行仍由 TOOL 管理器完成。

## 12. MODEL 管理器接入

### 12.1 当前缺口

AGENT 元数据只有：

```json
{
  "models": [
    "model-code-pro",
    "model-code-fast"
  ]
}
```

本文已确定：

```text
models[0] = 默认模型
models     = 当前 Agent 允许的模型集合
```

但 pi 的 `Model` 还要求 name、provider、api、reasoning、input、contextWindow、maxTokens、cost 等字段。

### 12.2 可以补默认值，但不是都“不起作用”

| pi Model 字段 | 是否会影响运行 | 作用 |
|---|---:|---|
| `id` | 是 | manager 选择和 session 恢复键 |
| `provider` | 是 | Provider 分发、认证和 session 记录 |
| `api` | 是 | Provider 内部 stream 实现分发 |
| `name` | 是 | TUI、RPC 和日志展示 |
| `baseUrl` | 对 manager Provider 通常否 | 独立 client 不直接使用 URL；但字段仍是 pi Model 必填 |
| `reasoning` | 是 | thinking level 是否可用以及 clamp |
| `thinkingLevelMap` | 是 | pi thinking level 到管理器值的映射 |
| `input` | 是 | 是否保留图片输入 |
| `contextWindow` | 是 | 自动压缩、overflow 判断和上下文占比 |
| `maxTokens` | 是 | 默认最大输出和请求限制 |
| `cost` | 有条件 | 请求前估算、展示或 fallback 计算；精确 usage/cost 应由管理器返回 |

因此，可以由平台补充默认值，但不能把这些字段全部当成无效占位符。

### 12.3 第一版保守默认值

MODEL 管理器不能提供 capability descriptor 时，建议由平台统一配置：

```ts
interface ModelDefaults {
  displayName: (modelId: string) => string;
  reasoning: false;
  input: readonly ["text"];
  contextWindow: 128_000;
  maxTokens: 16_384;
  cost: {
    input: 0;
    output: 0;
    cacheRead: 0;
    cacheWrite: 0;
  };
}
```

这里的数字是目标设计示例，不是从 modelId 推断出的事实。

原则：

- 未知 reasoning 能力按 false，避免发送不支持参数；
- 未知图片能力按 text-only，避免模型请求失败；
- `contextWindow` 和 `maxTokens` 必须由平台配置，不能使用无限大；
- cost 未知时填零并标记 diagnostic，不能伪造价格；
- 未来管理器返回 descriptor 后，以 descriptor 覆盖平台默认；
- 默认值属于 MODEL 适配配置，不复制到 AGENT 元数据。

### 12.4 客户端接口

如果当前管理器只有选择模型和执行能力，可使用：

```ts
interface ModelManagerClient {
  selectModel(modelId: string): Promise<void>;

  getDescriptor?(
    modelId: string,
  ): Promise<Partial<ExternalModelDescriptor> | undefined>;

  stream(
    request: ModelManagerRequest,
    options: { signal?: AbortSignal },
  ): AsyncIterable<ModelManagerEvent>;
}
```

`getDescriptor` 第一版可以是可选能力。缺失字段由 `ModelDefaults` 补齐。

### 12.5 映射为 pi Model

```ts
function toPiModel(
  modelId: string,
  descriptor: Partial<ExternalModelDescriptor> | undefined,
  defaults: ModelDefaults,
): Model<"model-manager"> {
  return {
    id: modelId,
    name: descriptor?.displayName ?? defaults.displayName(modelId),
    provider: "model-manager",
    api: "model-manager",
    baseUrl: "",
    reasoning: descriptor?.reasoning ?? defaults.reasoning,
    thinkingLevelMap: descriptor?.thinkingLevelMap,
    input: descriptor?.input ?? [...defaults.input],
    contextWindow:
      descriptor?.contextWindow ?? defaults.contextWindow,
    maxTokens:
      descriptor?.maxTokens ?? defaults.maxTokens,
    cost: descriptor?.cost ?? defaults.cost,
  };
}
```

### 12.6 native Provider

当前 pi 已支持：

```ts
modelRuntime.registerNativeProvider(provider);
```

目标 Provider 固定使用：

```text
provider = model-manager
api      = model-manager
```

Provider 的 `streamSimple()`：

1. 把 pi `Context` 转换为管理器请求；
2. 调用 `selectModel(model.id)` 或在每次 stream 请求中携带 modelId；
3. 调用 `ModelManagerClient.stream()`；
4. 把管理器流式事件转换为 pi `AssistantMessageEventStream`；
5. 把 AbortSignal 转成 manager cancel；
6. 保留 Tool Call、usage、stop reason 和错误；
7. 不在 MODEL 管理器中执行 Tool。

### 12.7 不读取 auth/models 文件的 ModelRuntime

```ts
const modelRuntime = await ModelRuntime.create({
  credentials: new InMemoryCredentialStore(),
  modelsPath: null,
  allowModelNetwork: false,
});

modelRuntime.registerNativeProvider(modelManagerProvider);
await modelRuntime.refresh({ allowNetwork: false });
```

关键点：

- 只设置 `modelsPath: null` 不能阻止默认 auth store；
- 必须同时注入 `InMemoryCredentialStore`，才能保证不读取或创建 `auth.json`；
- `modelsPath: null` 会使模型缓存使用内存 store，不读取 `models-store.json`；
- `ModelRuntime.create()` 仍包含 pi builtin Provider，所以还需要模型 allowlist。

### 12.8 模型 allowlist

只注册 manager Provider 不足以保证用户永远不会切换到 builtin model。

当前源码中：

- `AgentSession.setModel()` 只检查认证，没有 Agent allowlist；
- 有 scoped models 时，TUI 和 model cycle 通常使用 scope；
- RPC `set_model` 和 `get_available_models` 当前直接查询 `modelRuntime.getAvailable()`。

目标改造：

```ts
interface AgentModelPolicy {
  assertAllowed(model: Model<any>): void;
  listAllowed(): readonly Model<any>[];
}
```

统一覆盖：

- 初始 model；
- session 恢复；
- `AgentSession.setModel()`；
- cycle model；
- TUI 模型选择；
- RPC `set_model`；
- RPC `get_available_models`；
- extension 发起的模型切换。

允许键只有：

```text
model-manager/<AGENT.models[0]>
model-manager/<AGENT.models[1]>
...
```

如果恢复的 session 模型不在 allowlist：

1. 切回 `models[0]`；
2. 记录 diagnostic；
3. 写入新的 `model_change`；
4. 不回退到 pi builtin model。

## 13. cwd 与 SessionManager

### 13.1 cwd 可以由 SDK 指定

当前源码：

```ts
const cwd = resolvePath(
  options.cwd ??
  options.sessionManager?.getCwd() ??
  process.cwd(),
);
```

因此调用方可以：

```ts
await createAgentSession({
  cwd: "/workspace/orders",
});
```

目标装配器应把 Agent 部署配置中的固定 cwd 显式传入，并在启动时校验：

- cwd 存在；
- cwd 是允许的目录；
- 规范化路径与 Agent 配置一致；
- 显式 SessionManager 的 cwd 与固定 cwd 一致。

`cwd` 不需要加入 AGENT 元数据，也不需要写入 `AGENT.json`。

### 13.2 SessionManager 没有缺失

当前高层 SDK 已执行：

```ts
const sessionManager =
  options.sessionManager ??
  SessionManager.create(
    cwd,
    getDefaultSessionDir(cwd, agentDir),
  );
```

所以最简单的调用不需要显式创建：

```ts
const { session } = await createAgentSession({
  cwd,
  // 省略 sessionManager
});
```

SDK 会创建持久化 SessionManager。

### 13.3 何时显式传入

| 需求 | 方式 |
|---|---|
| 默认持久化新会话 | 省略，SDK 自动创建 |
| 完全不落盘 | `SessionManager.inMemory(cwd)` |
| 打开指定 JSONL | `SessionManager.open(...)` |
| continue 最近会话 | `SessionManager.continueRecent(...)` |
| fork 会话 | `SessionManager.forkFrom(...)` |
| 自定义 session 目录 | `SessionManager.create(cwd, sessionDir)` |
| 多 Agent 共用相同 cwd | 建议显式设置 Agent 隔离的 sessionDir |

### 13.4 多 Agent 同 cwd 的隔离

pi 默认 session 目录只按 cwd 编码，不包含 Agent ID：

```text
$AGENT_DIR/sessions/--<encoded-cwd>--/
```

如果两个不同 Agent 使用同一个 cwd，它们可能看到同一目录中的历史 session。

生产建议：

```ts
const sessionManager = SessionManager.create(
  cwd,
  join(
    sessionRoot,
    agent.id,
    String(agent.version),
    encodeCwd(cwd),
  ),
);
```

这不是因为 SessionManager 缺失，而是产品需要增加 Agent 级存储隔离。

如果部署约束保证一个 cwd 只对应一个 Agent，SDK 默认 SessionManager 已足够。

## 14. 端到端示例

### 14.1 AGENT 元数据

```json
{
  "id": "java-review-agent",
  "type": "agent",
  "version": 3,
  "created_at": "2026-07-25T08:00:00Z",
  "updated_at": "2026-07-25T08:00:00Z",
  "enabled": true,
  "name": "java-review-agent",
  "display_name": "Java 代码审查 Agent",
  "description": "审查 Java 代码的正确性、安全性和测试完整性",
  "models": [
    "model-code-pro",
    "model-code-fast"
  ],
  "system_prompt": {
    "role": "你是一名资深 Java 代码审查工程师。",
    "objective": "发现能够由代码证据支持的问题。",
    "instructions": "先理解调用链，再形成结论。",
    "tool_policy": "优先使用 read 获取精确代码。",
    "safety": "不执行未授权修改。",
    "completion": "覆盖目标变更、调用方和测试后结束。",
    "response_style": "使用中文，先给结论。",
    "example": "P1：空指针风险。"
  },
  "use_cases": [
    "Java Pull Request 审查"
  ],
  "binding_tools": [
    {
      "tool_id": "workspace-read",
      "version": 4
    }
  ],
  "binding_skills": [
    {
      "skill_id": "java-review",
      "version": 2
    }
  ],
  "permission": {
    "deny": [],
    "ask": [
      "repo-search"
    ],
    "allow": [
      "workspace-read"
    ]
  }
}
```

### 14.2 SKILL 元数据

```json
{
  "id": "java-review",
  "type": "skill",
  "version": 2,
  "created_at": "2026-07-25T08:00:00Z",
  "updated_at": "2026-07-25T08:00:00Z",
  "name": "java-review",
  "display_name": "Java 代码审查",
  "description": "审查 Java 变更的正确性、安全性、并发风险和测试覆盖",
  "use_cases": [
    "审查 Java Pull Request"
  ],
  "binding_tools": [
    {
      "tool_id": "workspace-read",
      "version": 4
    },
    {
      "tool_id": "repo-search",
      "version": 1
    }
  ],
  "binding_skills": [],
  "permission": {
    "deny": [],
    "ask": [],
    "allow": [
      "workspace-read",
      "repo-search"
    ]
  }
}
```

### 14.3 TOOL 元数据

```json
{
  "id": "workspace-read",
  "type": "tool",
  "version": 4,
  "created_at": "2026-07-25T08:00:00Z",
  "updated_at": "2026-07-25T08:00:00Z",
  "enabled": true,
  "permission": "allow",
  "name": "read",
  "display_name": "读取文件",
  "description": "读取工作区或允许的 Agent Skill 文件",
  "source": "builtin-toolset",
  "input_schema": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string"
      }
    },
    "required": [
      "path"
    ]
  },
  "output_schema": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string"
      },
      "content": {
        "type": "string"
      }
    },
    "required": [
      "path",
      "content"
    ]
  }
}
```

### 14.4 磁盘结构

```text
/opt/agent-resources/java-review-agent/
└── skills/
    └── java-review/
        └── SKILL.md

/workspace/orders/
├── AGENTS.md
└── src/
```

没有生成：

```text
AGENT.json
agent-runtime.json
SYSTEM.md
models.json
models-store.json
trust.json
extensions/
prompts/
themes/
```

### 14.5 内存解析结果

```ts
const resolved: ResolvedAgentDefinition = {
  agent: agentMetadata,
  defaultModelId: "model-code-pro",
  allowedModelIds: [
    "model-code-pro",
    "model-code-fast",
  ],
  skills: [{
    id: "java-review",
    version: 2,
    name: "java-review",
    filePath:
      "/opt/agent-resources/java-review-agent/" +
      "skills/java-review/SKILL.md",
  }],
  tools: [
    {
      id: "workspace-read",
      version: 4,
      name: "read",
      effectivePermission: "allow",
    },
    {
      id: "repo-search",
      version: 1,
      name: "repo-search",
      effectivePermission: "ask",
    },
  ],
  renderedSystemPrompt: renderSystemPrompt(
    agentMetadata.system_prompt,
  ),
  effectivePermissions: new Map([
    ["workspace-read", "allow"],
    ["repo-search", "ask"],
  ]),
};
```

### 14.6 装配示例

```ts
const settingsManager = SettingsManager.inMemory();

const modelRuntime = await ModelRuntime.create({
  credentials: new InMemoryCredentialStore(),
  modelsPath: null,
  allowModelNetwork: false,
});

const models = await Promise.all(
  resolved.allowedModelIds.map(async (modelId) => {
    const descriptor =
      await modelManagerClient.getDescriptor?.(modelId);
    return toPiModel(modelId, descriptor, modelDefaults);
  }),
);

modelRuntime.registerNativeProvider(
  createModelManagerProvider(models, modelManagerClient),
);
await modelRuntime.refresh({ allowNetwork: false });

const resourceLoader = new MetadataResourceLoader({
  cwd,
  agentRoot,
  renderedSystemPrompt: resolved.renderedSystemPrompt,
  skillFiles: resolved.skills.map((skill) => skill.filePath),
  preserveProjectContext: true,
});
await resourceLoader.reload();

const customTools = resolved.tools
  .filter((tool) => tool.effectivePermission !== "deny")
  .map((tool) =>
    createManagerToolDefinition(tool, toolManagerClient),
  );

const { session } = await createAgentSession({
  cwd,
  modelRuntime,
  model: models[0],
  scopedModels: models.map((model) => ({ model })),
  settingsManager,
  resourceLoader,
  customTools,
  tools: customTools.map((tool) => tool.name),

  // 单 Agent/单 cwd 时省略，SDK 自动创建。
  // sessionManager,
});
```

### 14.7 一次 Tool 调用

```text
MODEL 管理器返回 repo-search Tool Call
→ pi 校验 input schema
→ effective permission = ask
→ 用户确认本次调用
→ ToolDefinition.execute()
→ ToolManagerClient.execute()
→ TOOL 管理器执行 repo-search@1
→ 适配器校验 output schema
→ 结果写入 Tool Result content
→ pi 保存 Tool Result
→ 下一轮请求再次交给 MODEL 管理器
```

TOOL 管理器请求示例：

```json
{
  "invocationId": "call-001",
  "agentId": "java-review-agent",
  "agentVersion": 3,
  "sessionId": "session-example",
  "cwd": "/workspace/orders",
  "toolId": "repo-search",
  "toolVersion": 1,
  "toolName": "repo-search",
  "source": "builtin-toolset",
  "input": {
    "query": "order.getId()",
    "path": "src/main/java"
  },
  "authorization": {
    "policy": "ask",
    "approved": true
  }
}
```

该示例不包含真实凭据。

## 15. 需要修改与不需要修改的 pi 位置

### 15.1 不需要修改

| 能力 | 原因 |
|---|---|
| agent loop Tool Call 编排 | custom `ToolDefinition.execute()` 已是接管点 |
| Tool Result 回填 | pi 已支持 |
| Tool 串行执行 | `executionMode="sequential"` 已支持 |
| system prompt 最终构建 | ResourceLoader 可直接提供内存 prompt、Skill 和项目指令 |
| cwd 指定 | SDK 已支持 |
| SessionManager 默认创建 | SDK 已支持 |
| session JSONL、分支和 compaction | pi 已支持 |
| native Provider 注册 | `ModelRuntime.registerNativeProvider()` 已支持 |

### 15.2 需要新增的通用模块

| 模块 | 类型 |
|---|---|
| Metadata Registry adapter | 架构变化 |
| 版本、闭包、权限 resolver | 架构变化 |
| SkillDocumentResolver | 架构变化 |
| MetadataResourceLoader | 安全加固 |
| Metadata AgentSession assembler | 架构变化 |
| ToolManagerClient adapter | 架构变化 |
| ModelManagerClient native Provider | 架构变化 |
| Agent model allowlist policy | 安全加固 |

### 15.3 可能需要的小范围 pi 改造

严格模型隔离时需要：

1. 给 `AgentSession.setModel()` 增加可选 model policy 检查；
2. RPC `set_model` 和 `get_available_models` 使用 Agent allowlist；
3. session 恢复模型经过同一 allowlist；
4. 所有其他模型切换入口复用同一检查。

如果应用不暴露模型切换，只始终传 `model=models[0]`，第一版可以先在装配层限制；但完整设计仍应实现统一策略，避免未来 TUI、RPC 或 extension 绕过。

## 16. 风险与限制

### 16.1 Model 默认字段可能不准确

错误的 `contextWindow` 会导致过早或过晚压缩；错误的 `input` 会导致图片被错误保留或删除；错误的 `reasoning` 会改变 thinking 行为。

因此：

- 默认值必须集中配置；
- 每次使用 fallback 都记录 diagnostic；
- MODEL 管理器应逐步提供真实 descriptor；
- 不能根据 modelId 字符串猜测能力。

### 16.2 Skill 正文不是启动时全部进入模型

pi 启动时只把 Skill 的 name、description 和路径加入 system prompt。模型需要调用 manager `read`，或通过显式 Skill 命令，才能取得正文。

### 16.3 Skill 权限是 AgentSession 全局收紧

第一版不跟踪当前活跃 Skill。任何绑定 Skill 对 Tool 的 ask 或 deny 都作用于整个 AgentSession。

### 16.4 不支持 Skill 附属资源

开发人员必须把流程写入 `SKILL.md`，执行能力交给 TOOL 管理器。相对链接到 `scripts/`、`references/` 或其他本地文件应在装配校验时失败。

### 16.5 DefaultResourceLoader 不能提供“完全不读取”保证

即使设置全部 `no*`，默认 PackageManager 仍可能进行环境目录探测。需要自定义最小 ResourceLoader 才能满足本文的完整隔离矩阵。

### 16.6 多 Agent session 混用

多个 Agent 共用 cwd 时，pi 默认 session 目录不能区分 Agent ID。应使用 Agent 级 sessionDir。

### 16.7 不支持热更新

Agent、Skill、Tool、权限或允许模型变化后：

1. 重新解析元数据；
2. 重新创建 AgentSession；
3. 按 allowlist 决定旧 session 是否可以恢复；
4. 不在运行中的 AgentSession 替换定义快照。

## 17. 验收标准

### 17.1 文件隔离

- Agent 资源目录不包含 `AGENT.json`；
- 不要求 `agent-runtime.json`；
- 不要求生成 `SYSTEM.md`；
- 只读取显式绑定的 `SKILL.md`；
- 只读取允许范围的项目 `AGENTS.md/CLAUDE.md`；
- 持久 session 开启时只额外读写 session JSONL；
- 不读取 global/project settings；
- 不读取 trust、auth、models、models-store；
- 不扫描 ambient extensions、skills、prompts、themes 和 packages；
- 不读取 ignore 文件、scripts 或 references。

### 17.2 Agent 装配

- `models[0]` 是默认模型；
- Agent allowed model 只能经过 MODEL 管理器；
- 缺失 Model descriptor 时使用有诊断的集中默认值；
- 所有 ToolDefinition 都由 TOOL 管理器代理；
- deny Tool 对模型不可见；
- ask Tool 每次调用确认；
- allow Tool 可直接调用管理器；
- 所有 manager Tool 第一版串行；
- Skill 存在时 manager `read` 可读取精确 Skill 文件。

### 17.3 Session 与 cwd

- SDK 启动显式传入固定 cwd；
- 未传 SessionManager 时由高层 SDK 自动创建；
- 内存、恢复、fork 和自定义目录场景可显式注入；
- 多 Agent 共用 cwd 时 session 存储按 Agent 隔离；
- session 恢复模型必须通过 Agent model allowlist。

### 17.4 文档校验

- 明确区分当前 pi 行为和目标设计；
- 记录源码 commit、路径和符号；
- 不包含 Mermaid；
- JSON、Markdown 和 TypeScript 示例完整闭合；
- 示例不包含真实凭据；
- 不引用范围外设计文档。

## 18. 最终设计结论

当前三类元数据不需要转换成 `AGENT.json`，也不需要强制转换成 `agent-runtime.json`。

目标运行链路应当是：

```text
上层程序取得 AGENT/SKILL/TOOL 元数据
→ 内存解析固定版本、依赖闭包和权限
→ 从 Agent 资源目录解析精确 SKILL.md
→ 在内存中渲染 system prompt
→ 构造 TOOL 管理器 ToolDefinition 代理
→ 构造 MODEL 管理器 native Provider
→ 注入最小 ResourceLoader、内存 SettingsManager 和隔离 ModelRuntime
→ 调用 createAgentSession({ cwd, ... })
→ SDK 自动或按需使用显式 SessionManager
```

元数据 Agent 模式下，真正有业务意义的磁盘文件只有：

```text
绑定的 SKILL.md
保留的项目 AGENTS.md/CLAUDE.md
条件使用的 session JSONL
```

其余 pi 原生配置和资源文件全部由内存配置、管理器客户端或固定适配器替代。

## 19. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.1 | 2026-07-25 | 删除本地 Agent 定义文件和强制运行清单设计；明确元数据以内存对象传入；新增 pi 原生文件使用矩阵、最小 ResourceLoader、Model 默认参数影响、SDK 自动 SessionManager 与多 Agent session 隔离设计 |
| 1.0 | 2026-07-25 | 初版元数据驱动 AgentSession 设计 |
