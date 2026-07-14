# pi-mono Java Command SR 设计

> 文档编号：SR-CMD-001<br>
> 版本：v1.0<br>
> 日期：2026-07-14<br>
> 状态：设计基线<br>
> pi 源码基线：[`bb959aae017eedc8edaa91d01d0475d483ea9371`](https://github.com/badlogic/pi-mono/tree/bb959aae017eedc8edaa91d01d0475d483ea9371)

## 1. 结论

Java 版本不再区分 Built-in Command 与 Extension Command，统一设计为静态注册的 `CommandDefinition`：

- 两类命令均由内部受信任开发人员编写，安全边界一致。
- 命令在应用启动时一次性发现、校验并发布，运行期不上传、不卸载、不重载、不回滚。
- 命令名是目录内唯一身份；`extensionId`、`ownerId`、`sourceKind` 不参与任何运行时决策，因此不进入核心模型。
- TUI 与 App 使用同一个命令目录、分发器和 Handler，只提供不同的交互与输出适配器。
- `visibility` 不进入定义。ToB 产品不存在合法的隐藏彩蛋命令；能执行的命令必须进入公开目录、帮助和审计。
- `surfaces` 不进入定义。当前主流 TUI 与 App 均支持命令；只有出现真实的客户端能力差异时，才通过能力检查处理，而不是预先给命令贴界面标签。

本设计以 pi Built-in Command 的源码行为为主要基线，但不复制其集中式字符串路由。Java 版本把 pi 分散在元数据、补全、执行分支和会话控制流中的事实，收敛为一个不可变定义和一条统一执行管线。

![Source to target overview](./diagrams/command/01-source-to-target-overview.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L4) · [查看 pi Built-in 定义源码](https://github.com/badlogic/pi-mono/blob/bb959aae017eedc8edaa91d01d0475d483ea9371/packages/coding-agent/src/core/slash-commands.ts#L13-L40)

## 2. 范围与约束

### 2.1 设计范围

本设计覆盖：

- 命令定义、发现、启动校验和不可变目录发布；
- 输入解析、命令解析优先级和统一分发；
- 执行模式、并发、取消和超时；
- 参数补全、帮助和客户端适配；
- 新命令开发方式、错误模型、测试和迁移；
- Skill Command 与注册命令的边界。

本设计不覆盖具体业务服务实现、LLM Prompt Template 展开规则和 Skill 文件发现规则。

### 2.2 已确认的 Java 产品约束

| 约束 | 设计影响 |
|---|---|
| Built-in 与 Extension 都由内部人员开发 | 使用同一个 `CommandDefinition`、`CommandHandler` 和注册流程 |
| 无运行期 reload、upload、unload、rollback | 目录只在启动期发布一次，不设计生命周期状态机 |
| TUI 与 App 都支持命令 | 不设计 `surfaces` 字段，客户端通过端口适配 |
| ToB 不允许隐藏彩蛋命令 | 不设计 `visibility`；可执行命令必须公开注册 |
| pi Built-in 是主要行为基线 | 执行模式、路由顺序和补全能力必须能追溯到固定源码 |

## 3. pi 源码分析

### 3.1 Built-in 定义实际包含什么

pi 的 [`BuiltinSlashCommand`](https://github.com/badlogic/pi-mono/blob/bb959aae017eedc8edaa91d01d0475d483ea9371/packages/coding-agent/src/core/slash-commands.ts#L13-L16) 只有：

| 字段 | pi 含义 | Java 处理 |
|---|---|---|
| `name` | 不带 `/` 的调用名 | 保留为 `CommandDefinition.name` |
| `description` | 补全列表中的用户说明 | 保留为 `CommandDefinition.description` |

pi 在同一文件中公开列出 22 个 Built-in Command。它没有 Handler、执行策略或参数补全字段；这些行为在其他位置绑定。

### 3.2 元数据、补全和执行是分离的

pi 将 Built-in 元数据映射为补全 DTO，并对 `/model` 单独挂接参数补全；源码见 [`createBaseAutocompleteProvider()`](https://github.com/badlogic/pi-mono/blob/bb959aae017eedc8edaa91d01d0475d483ea9371/packages/coding-agent/src/modes/interactive/interactive-mode.ts#L499-L570)。

执行则由 [`setupEditorSubmitHandler()`](https://github.com/badlogic/pi-mono/blob/bb959aae017eedc8edaa91d01d0475d483ea9371/packages/coding-agent/src/modes/interactive/interactive-mode.ts#L2541-L2715) 中按命令名排列的分支完成。

这造成三个事实源：

1. 目录决定哪些命令出现在补全中；
2. 补全方法决定少数命令的参数建议；
3. 提交路由决定命令是否真正可执行。

Java 版本将三者合并到 `CommandDefinition`，避免“可执行但不公开”“帮助存在但无 Handler”或“参数补全与命令实现脱节”。

![Current pi command flow](./diagrams/command/02-pi-command-flow.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L33) · [查看 pi 提交路由源码](https://github.com/badlogic/pi-mono/blob/bb959aae017eedc8edaa91d01d0475d483ea9371/packages/coding-agent/src/modes/interactive/interactive-mode.ts#L2541-L2715)

### 3.3 pi 的“隐藏命令”不是目标能力

pi 提交路由中还存在 `/debug`、`/arminsayshi` 和 `/dementedelves` 分支，但它们不在 `BUILTIN_SLASH_COMMANDS` 公开目录中，见 [`interactive-mode.ts`](https://github.com/badlogic/pi-mono/blob/bb959aae017eedc8edaa91d01d0475d483ea9371/packages/coding-agent/src/modes/interactive/interactive-mode.ts#L2641-L2663)。

这是 pi 当前实现事实，不是 Java ToB 产品需要继承的设计：

- 彩蛋命令不迁移；
- 诊断命令如需保留，必须作为普通公开命令注册并出现在帮助、权限和审计中；
- 不提供 `HIDDEN`、`INTERNAL_ONLY` 等可绕过目录的可见性值。

### 3.4 pi 隐含了多种执行控制流

pi 没有显式 `executionPolicy`，但源码表现出不同执行模式：

- `/reload` 在 streaming 或 compacting 时拒绝执行，见 [`handleReloadCommand()`](https://github.com/badlogic/pi-mono/blob/bb959aae017eedc8edaa91d01d0475d483ea9371/packages/coding-agent/src/modes/interactive/interactive-mode.ts#L5063-L5071)；
- `/compact` 先断开并终止当前 Agent，再开始压缩，见 [`AgentSession.compact()`](https://github.com/badlogic/pi-mono/blob/bb959aae017eedc8edaa91d01d0475d483ea9371/packages/coding-agent/src/core/agent-session.ts#L1641-L1645)；
- `/new`、`/import`、`/resume`、`/fork`、`/clone` 会创建、导入或替换会话运行时；运行时替换中的 teardown 见 [`agent-session-runtime.ts`](https://github.com/badlogic/pi-mono/blob/bb959aae017eedc8edaa91d01d0475d483ea9371/packages/coding-agent/src/core/agent-session-runtime.ts#L167-L175)；
- `/quit` 进入终止流程；
- 其余命令直接进入交互或服务调用。

因此 Java 用枚举表达有限的执行模式是合理的。相比多个布尔值，枚举能让 `switch` 穷尽检查，并消除 `requiresIdle=true` 与 `abortAgent=true` 同时出现一类矛盾组合。

## 4. 目标架构

![Unified Java command architecture](./diagrams/command/03-target-architecture.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L61)

架构分为四层：

| 层 | 组件 | 职责 |
|---|---|---|
| 定义与启动 | `CommandContributor`、`CommandInstaller` | 声明命令，启动期收集和校验 |
| 命令核心 | `CommandCatalogSnapshot`、Parser、Dispatcher、Gate | 查询、解析、准入和统一执行 |
| 命令实现 | Handler、应用服务、交互端口 | 实现单个命令业务行为 |
| 客户端 | TUI Adapter、App Adapter | 提供输入、交互、输出和刷新适配 |

关键依赖方向为“客户端 → 命令核心 → Handler → 应用服务”。Handler 不依赖具体 TUI 或 App 类。

## 5. 统一类设计

### 5.1 类图

![Unified Java command class model](./diagrams/command/04-unified-class-model.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L114)

### 5.2 `CommandDefinition`

```java
public record CommandDefinition(
        String name,
        String description,
        CommandExecutionPolicy executionPolicy,
        Optional<CommandArgumentCompleter> argumentCompleter,
        CommandHandler handler) {

    public CommandDefinition {
        name = CommandNames.requireValid(name);
        description = Objects.requireNonNull(description, "description").strip();
        executionPolicy = Objects.requireNonNull(executionPolicy, "executionPolicy");
        argumentCompleter = Objects.requireNonNull(argumentCompleter, "argumentCompleter");
        handler = Objects.requireNonNull(handler, "handler");
    }
}
```

字段定义：

| 字段 | 必填 | 含义 | 设计原因 |
|---|---:|---|---|
| `name` | 是 | 不带 `/` 的规范命令名 | 与 pi Built-in `name` 对齐，也是目录唯一键 |
| `description` | 是 | 面向用户的简短说明 | 同时供补全、帮助和 App Command Palette 使用 |
| `executionPolicy` | 是 | 运行时准入与生命周期控制 | 将 pi 隐含控制流显式化并集中执行 |
| `argumentCompleter` | 是 | 当前命令的可选参数补全器；`Optional.empty()` 表示无参数补全 | 将 pi `/model` 的独立绑定收回定义；避免 `null` 和空实现对象 |
| `handler` | 是 | 命令业务入口 | 保证目录内每个命令都能执行 |

使用 `record` 的原因：定义是启动期值对象，要求不可变、结构化相等和低样板代码。`name` 在构造时规范化；目录发布后不允许修改。

命名约束：

- 只允许小写 ASCII 字母、数字和连字符；建议正则 `[a-z][a-z0-9-]*`；
- 不含前导 `/`；
- 区分参数与命令名，`/model gpt` 的名称是 `model`，参数原文是 `gpt`；
- 名称全局唯一，冲突直接阻止应用启动。

### 5.3 不进入定义的字段

| 字段 | 是否保留 | 原因 |
|---|---:|---|
| `id` | 否 | `name` 已是静态目录唯一键，没有第二套稳定身份消费方 |
| `extensionId` | 否 | 只在动态安装、卸载、升级、回滚、来源隔离时有价值；Java 版本无这些需求 |
| `ownerId` / `contributorId` | 否 | Spring Bean 类名足以提供启动冲突诊断，不需要业务身份 |
| `sourceKind` | 否 | Built-in 与 Extension 没有不同执行、安全或生命周期语义 |
| `visibility` | 否 | ToB 中不存在合法隐藏命令；注册即公开 |
| `surfaces` | 否 | TUI 与 App 都支持命令；客户端能力由端口和能力检查表达 |
| `enabled` | 否 | 静态集合中不注册即禁用；运行期状态会制造第二事实源 |
| `priority` | 否 | 命令名不允许覆盖；优先级会掩盖配置冲突 |

以后只有出现实际消费者，且不能由现有字段推导时，才新增字段。

### 5.4 `CommandHandler`

```java
@FunctionalInterface
public interface CommandHandler {
    CompletionStage<CommandExecutionResult> handle(
            CommandInvocation invocation,
            CommandContext context);
}
```

Handler 负责单个命令的业务流程，例如解析该命令参数、调用 `SessionService`、通过交互端口请求确认并返回刷新提示。它不负责：

- 判断当前输入是不是命令；
- 查询命令目录；
- 执行 `executionPolicy`；
- 统一超时、取消、日志、指标和异常脱敏；
- 决定 TUI 或 App 如何渲染。

### 5.5 Handler 与内部 Executor 的区别

Java 核心不向命令开发者暴露第二种 Handler。若实现中使用 `CommandExecutor` 这个内部类名，它是基础设施执行器，不是命令扩展点；本设计用 `CommandDispatcher` 与 `CommandExecutionGate` 明确拆分其职责。

| 维度 | `CommandHandler` | 内部 Executor / Dispatcher + Gate |
|---|---|---|
| 数量 | 通常每个命令一个 | 全应用一套 |
| 编写者 | 命令开发者 | 命令框架维护者 |
| 输入 | 已解析 invocation 与 context | 原始调用、目录定义、运行时状态 |
| 职责 | 业务动作 | 查找、策略准入、互斥、超时、取消、错误映射、观测 |
| 是否知道具体命令语义 | 是 | 否，只读取定义和策略 |
| 是否依赖业务服务 | 是，构造器注入 | 否 |
| 是否允许绕过策略直接调用 | 仅单元测试 | 生产调用不允许 |

分离原因是策略必须一致执行。如果每个 Handler 自己检查 busy 状态或自己实现超时，Java 会重现 pi 的分散控制流。

### 5.6 `CommandContext`

```java
public record CommandContext(
        CommandSession session,
        CommandInteraction interaction,
        CommandOutput output,
        CommandCancellation cancellation) {
}
```

Context 只保存一次调用相关、客户端相关的能力：

| 字段 | 含义 |
|---|---|
| `session` | 当前命令可见的会话身份与状态视图 |
| `interaction` | 选择、确认、文本输入等交互端口 |
| `output` | 结构化状态、警告、错误和内容输出端口 |
| `cancellation` | 本次调用的取消信号 |

应用服务不放入 Context。`ModelService`、`SessionService`、`ExportService` 等通过 Handler 构造器注入，使依赖显式、可测试，也避免 Context 退化为 Service Locator。

### 5.7 Contributor

```java
public interface CommandContributor {
    List<CommandDefinition> commands();
}
```

Contributor 只是启动期聚合边界，适合一个功能模块声明一组命令。它不代表可安装扩展，也不需要 `extensionId`。校验错误记录 Contributor Bean 类名和命令名即可定位来源。

## 6. 启动安装与目录

![One-time command installation](./diagrams/command/05-startup-installation.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L210)

`CommandInstaller` 在 Spring 启动阶段执行：

1. 按稳定顺序读取所有 `CommandContributor` Bean；
2. 在局部候选集合中规范化和校验全部定义；
3. 检查空字段、非法名称、重复名称和缺失 Handler；
4. 全部通过后，一次性发布 `CommandCatalogSnapshot`；
5. 任一失败则启动失败，并报告命令名与 Bean 类；不会发布半成品目录。

这不是运行期事务，因此不设计 rollback：发布前失败没有状态要回滚；发布后命令集合保持不变。

建议目录接口：

```java
public interface CommandRegistry {
    Optional<CommandDefinition> find(String name);
    List<CommandDefinition> list();
}
```

实现持有一个不可变快照：

```java
final class ImmutableCommandRegistry implements CommandRegistry {
    private volatile CommandCatalogSnapshot snapshot = CommandCatalogSnapshot.empty();

    void install(CommandCatalogSnapshot candidate) {
        // Guarded so installation can succeed exactly once.
    }
}
```

目录顺序使用显式稳定规则，例如 Contributor 的 Spring Order 后接定义声明顺序。该顺序只影响帮助与补全展示，不参与冲突覆盖。

## 7. 输入解析与路由

### 7.1 路由优先级

pi 在普通 prompt 之前处理 Built-in；Bash、压缩和 streaming 又有特定分支，见 [`setupEditorSubmitHandler()`](https://github.com/badlogic/pi-mono/blob/bb959aae017eedc8edaa91d01d0475d483ea9371/packages/coding-agent/src/modes/interactive/interactive-mode.ts#L2541-L2715)。Java 保留产品级优先级，但将具体命令分支替换为目录查询。

![Unified input routing](./diagrams/command/06-input-routing.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L246)

推荐顺序：

1. `/name ...` 且 `name` 在静态目录中：注册命令；
2. `!` 或 `!!`：Bash 输入；
3. `/skill:name ...`：Skill Command 动态投影；
4. Prompt Template；
5. 普通 Agent Prompt。

命中注册命令后，无论执行成功、拒绝还是失败，都不得把原始文本继续发送给 LLM。

### 7.2 Parser 规则

```java
public record CommandInvocation(
        String rawInput,
        String name,
        String arguments) {
}
```

- Parser 只解析首个命令 token，不解析命令特有参数语法；
- `rawInput` 用于审计和必要的兼容诊断，但日志必须脱敏；
- `arguments` 保留命令名之后的原始内容，并去除命令名后的首段空白；
- 空输入、单独 `/`、非法命令名返回 `NOT_A_COMMAND` 或稳定解析错误；
- 未注册 `/x` 不自动当作内部命令，可继续由 Skill/Template 路由判断。

## 8. 统一分发

![Unified command dispatch sequence](./diagrams/command/07-dispatch-sequence.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L283)

分发流程：

1. `CommandParser` 产生 `CommandInvocation`；
2. Dispatcher 在当前快照中按规范名查询；
3. Gate 根据 policy 和当前运行时状态准入；
4. 准入后创建取消/超时边界并调用 Handler；
5. Handler 返回结构化结果；
6. Dispatcher 记录指标、映射异常并返回客户端；
7. 客户端执行通用刷新提示。

建议结果模型：

```java
public record CommandExecutionResult(
        CommandOutcome outcome,
        Set<CommandRefreshHint> refreshHints) {

    public static CommandExecutionResult completed() {
        return new CommandExecutionResult(CommandOutcome.COMPLETED, Set.of());
    }
}

public enum CommandOutcome {
    COMPLETED,
    CANCELLED
}

public enum CommandRefreshHint {
    SESSION,
    MODEL,
    COMMANDS,
    TRANSCRIPT,
    SETTINGS
}
```

Dispatcher 对客户端返回的状态应至少区分：`HANDLED`、`NOT_FOUND`、`REJECTED`、`FAILED`。业务异常不把堆栈和敏感参数直接显示给用户；客户端收到稳定错误码、安全消息和 correlation ID。

## 9. Execution Policy

### 9.1 类型

```java
public record CommandExecutionPolicy(
        CommandExecutionMode mode,
        CommandConcurrency concurrency,
        boolean cancellable,
        Optional<Duration> timeout) {
}

public enum CommandExecutionMode {
    IMMEDIATE,
    REQUIRE_IDLE,
    ABORT_AGENT_AND_RUN,
    RUNTIME_TRANSITION,
    SHUTDOWN
}

public enum CommandConcurrency {
    SHARED,
    EXCLUSIVE
}
```

`mode` 表达与 Agent/会话生命周期的关系；`concurrency` 表达命令之间是否允许并行；`cancellable` 和 `timeout` 是正交的执行边界，不能继续塞进 mode 枚举。

![Execution modes derived from pi](./diagrams/command/08-execution-modes.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L325)

### 9.2 每种模式

| 模式 | Gate 行为 | 典型场景 | pi 源码依据 |
|---|---|---|---|
| `IMMEDIATE` | 不因 Agent streaming 自动拒绝或终止 Agent | 查看信息、打开设置、复制、认证交互 | Built-in 分支位于 streaming 路由之前 |
| `REQUIRE_IDLE` | Agent streaming、compacting 或运行时切换中直接拒绝 | reload、需要稳定会话快照的管理动作 | `/reload` 显式检查 streaming/compacting |
| `ABORT_AGENT_AND_RUN` | 请求终止当前 Agent，等待完成，再执行 Handler | 手动 compact | `compact()` 先 `abort()` |
| `RUNTIME_TRANSITION` | 获取独占租约，阻止新调用，安全替换会话运行时 | new、import、resume、fork、clone | RuntimeHost 执行 session replace/fork/import |
| `SHUTDOWN` | 停止接收新调用，取消或收敛进行中任务，关闭应用 | quit | `/quit` 调用 shutdown |

### 9.3 pi 22 个 Built-in 的建议映射

| 命令 | Java mode | concurrency | 说明 |
|---|---|---|---|
| `settings` | `IMMEDIATE` | `EXCLUSIVE` | 交互式设置修改 |
| `model` | `IMMEDIATE` | `EXCLUSIVE` | 选择并修改当前模型 |
| `scoped-models` | `IMMEDIATE` | `EXCLUSIVE` | 修改模型范围 |
| `export` | `IMMEDIATE` | `SHARED` | 读取会话快照并导出 |
| `import` | `RUNTIME_TRANSITION` | `EXCLUSIVE` | 替换当前会话 |
| `share` | `IMMEDIATE` | `SHARED` | 读取会话并发布 |
| `copy` | `IMMEDIATE` | `SHARED` | 读取最后消息 |
| `name` | `IMMEDIATE` | `EXCLUSIVE` | 修改会话元数据 |
| `session` | `IMMEDIATE` | `SHARED` | 读取会话统计 |
| `changelog` | `IMMEDIATE` | `SHARED` | 只读展示 |
| `hotkeys` | `IMMEDIATE` | `SHARED` | 只读展示 |
| `fork` | `RUNTIME_TRANSITION` | `EXCLUSIVE` | 创建并切换 fork 会话 |
| `clone` | `RUNTIME_TRANSITION` | `EXCLUSIVE` | 克隆并切换会话 |
| `tree` | `REQUIRE_IDLE` | `EXCLUSIVE` | Java 多客户端下收紧：导航会改写会话分支，要求稳定状态 |
| `trust` | `IMMEDIATE` | `EXCLUSIVE` | 修改项目信任设置 |
| `login` | `IMMEDIATE` | `EXCLUSIVE` | 认证交互 |
| `logout` | `IMMEDIATE` | `EXCLUSIVE` | 删除认证状态 |
| `new` | `RUNTIME_TRANSITION` | `EXCLUSIVE` | 替换为新会话 |
| `compact` | `ABORT_AGENT_AND_RUN` | `EXCLUSIVE` | 终止当前 Agent 后压缩 |
| `resume` | `RUNTIME_TRANSITION` | `EXCLUSIVE` | 替换为已有会话 |
| `reload` | `REQUIRE_IDLE` | `EXCLUSIVE` | Java 仅表示应用资源刷新；不重载命令定义 |
| `quit` | `SHUTDOWN` | `EXCLUSIVE` | 应用终止 |

`tree` 是有意的 Java 架构差异。pi 在提交路由中可直接打开树，但实际导航会修改 session branch，见 [`AgentSession.navigateTree()`](https://github.com/badlogic/pi-mono/blob/bb959aae017eedc8edaa91d01d0475d483ea9371/packages/coding-agent/src/core/agent-session.ts#L2702-L2795)。Java 同时服务 TUI 与 App，若一个客户端 streaming、另一个客户端切换分支，状态竞争更明显，因此要求 idle。

`reload` 只允许刷新按产品定义可刷新的配置或资源；命令目录本身保持启动期静态，不因沿用命令名而恢复动态 Extension 生命周期。

## 10. 补全与帮助

![Unified command completion flow](./diagrams/command/09-completion-flow.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L358) · [查看 pi `/model` 补全源码](https://github.com/badlogic/pi-mono/blob/bb959aae017eedc8edaa91d01d0475d483ea9371/packages/coding-agent/src/modes/interactive/interactive-mode.ts#L506-L533)

统一目录是以下功能的唯一事实源：

- TUI `/` 补全；
- App Command Palette；
- `/help` 命令清单；
- 启动冲突检查；
- 审计中的规范命令名。

参数补全接口：

```java
@FunctionalInterface
public interface CommandArgumentCompleter {
    CompletionStage<List<CommandCompletion>> complete(
            String prefix,
            CommandCompletionContext context);
}
```

要求：

- 补全只读，不修改会话；
- 客户端为请求分配递增版本，只展示最新请求结果；
- 补全异常返回空结果并记录诊断，不影响命令执行；
- 补全结果不得泄露无权查看的资源；
- 命令名与说明直接来自 `CommandCatalogSnapshot`，不维护第二份列表。

Skill Command 仍是资源加载后的动态投影，命名空间建议固定为 `/skill:<name>`。它进入同一个补全界面，但不安装到静态 `CommandRegistry`，也不伪装成内部注册命令。

## 11. TUI 与 App 适配

![Client-independent command execution](./diagrams/command/10-client-adaptation.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L388)

`CommandInteraction` 提供语义化交互：

```java
public interface CommandInteraction {
    CompletionStage<Boolean> confirm(ConfirmRequest request);
    CompletionStage<Optional<String>> prompt(TextPrompt request);
    <T> CompletionStage<Optional<T>> select(SelectionRequest<T> request);
}
```

`CommandOutput` 提供结构化输出：

```java
public interface CommandOutput {
    void status(String message);
    void warning(String code, String safeMessage);
    void content(CommandContent content);
}
```

TUI 可以把 `select` 渲染为终端列表，App 可以渲染为对话框。Handler 只表达“选择模型”这一意图，不构造 `SelectorComponent`、窗口或 HTTP DTO。

不使用 `surfaces` 的原因不是假设所有客户端能力永远完全相同，而是“显示在哪个客户端”不是命令身份。若某一客户端确实缺少剪贴板等能力：

1. Context 中的能力端口返回不支持；
2. Handler 返回稳定 `CAPABILITY_UNAVAILABLE`；
3. 客户端显示可操作说明；
4. 不复制命令定义或分裂 Handler。

## 12. 新命令开发示例

![New internal command development](./diagrams/command/11-new-command-development.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L420)

开发者可以直接新增命令，不需要修改中心路由。以下示例实现公开的 `/doctor` 诊断命令。

### 12.1 Handler

```java
@Component
final class DoctorCommandHandler implements CommandHandler {
    private final DiagnosticService diagnosticService;

    DoctorCommandHandler(DiagnosticService diagnosticService) {
        this.diagnosticService = diagnosticService;
    }

    @Override
    public CompletionStage<CommandExecutionResult> handle(
            CommandInvocation invocation,
            CommandContext context) {
        return diagnosticService.inspect(context.session())
                .thenApply(report -> {
                    context.output().content(CommandContent.diagnostic(report));
                    return CommandExecutionResult.completed();
                });
    }
}
```

### 12.2 Contributor

```java
@Component
final class DiagnosticCommands implements CommandContributor {
    private static final CommandExecutionPolicy POLICY =
            new CommandExecutionPolicy(
                    CommandExecutionMode.IMMEDIATE,
                    CommandConcurrency.SHARED,
                    true,
                    Optional.of(Duration.ofSeconds(30)));

    private final DoctorCommandHandler doctor;

    DiagnosticCommands(DoctorCommandHandler doctor) {
        this.doctor = doctor;
    }

    @Override
    public List<CommandDefinition> commands() {
        return List.of(new CommandDefinition(
                "doctor",
                "Inspect runtime configuration and connectivity",
                POLICY,
                Optional.empty(),
                doctor));
    }
}
```

### 12.3 必须添加的测试

- 定义测试：名称、说明、策略与 Handler 正确；
- Handler 测试：使用 fake `DiagnosticService`、Interaction 和 Output；
- 目录契约测试：`doctor` 出现在预期清单且无重复；
- 客户端集成测试：TUI 和 App 都能从同一目录发现并执行；
- 安全测试：输出不包含 token、密钥和未脱敏环境变量。

这套设计足以开发新命令：新增 Handler 与 Contributor Bean 后，启动安装器自动发现、校验，并使 TUI/App 的补全和帮助同步生效。

## 13. 注册命令与 Skill Command 的边界

| 维度 | 注册 Command | Skill Command |
|---|---|---|
| 来源 | 编译期 Java Bean | 工作区或资源目录中的 Skill 文档 |
| 集合变化 | 进程启动时固定 | 资源加载或刷新后可变化 |
| 执行 | Handler 调用应用服务 | 展开为 Agent Prompt/上下文 |
| 身份 | 全局命令名 | `skill:<name>` 命名空间 |
| 策略 | `CommandExecutionPolicy` | 普通 Agent Prompt 的队列与会话规则 |
| 失败 | 命令错误模型 | Skill 加载或 Prompt 执行错误模型 |

统一 Built-in/Extension 不等于把 Skill 也做成 Handler。Skill 的动态资源语义和 Prompt 执行模型不同，应保持明确边界。

## 14. 错误、安全与可观测性

### 14.1 稳定错误码

建议至少包含：

- `COMMAND_NOT_FOUND`
- `COMMAND_INVALID_ARGUMENT`
- `COMMAND_BUSY`
- `COMMAND_CAPABILITY_UNAVAILABLE`
- `COMMAND_CANCELLED`
- `COMMAND_TIMEOUT`
- `COMMAND_FAILED`

### 14.2 安全规则

- 注册即公开，不允许未进入目录但可执行的分支；
- 权限检查放在业务服务或明确的授权器中，不用 `visibility` 代替权限；
- `rawInput`、异常、参数和输出进入日志前脱敏；
- 分享、导出、登录、退出等命令记录动作和结果，不记录凭证内容；
- App 传入的命令名与参数必须经过同一 Parser/Dispatcher，不建立旁路接口；
- 命令冲突导致启动失败，不允许后注册覆盖前注册。

### 14.3 指标与日志

建议按规范命令名记录：

- `command.invocation.count{name,outcome}`
- `command.duration{name}`
- `command.rejected.count{name,reason}`
- `command.timeout.count{name}`

日志包含 correlation ID、命令名、策略、耗时和安全错误码；不包含未经审查的参数全文。

## 15. 包结构建议

```text
command/
  api/
    CommandDefinition.java
    CommandHandler.java
    CommandContributor.java
    CommandExecutionPolicy.java
    CommandInvocation.java
    CommandContext.java
    CommandExecutionResult.java
  core/
    CommandInstaller.java
    ImmutableCommandRegistry.java
    CommandCatalogSnapshot.java
    CommandParser.java
    CommandDispatcher.java
    CommandExecutionGate.java
    CommandCompletionService.java
  port/
    CommandInteraction.java
    CommandOutput.java
    CommandCancellation.java
  client/
    tui/
    app/
  commands/
    model/
    session/
    settings/
    diagnostics/
```

`api` 是内部开发接口，不承诺第三方插件 ABI。`core` 由框架维护，具体命令不得依赖其实现类。

## 16. 迁移方案

![Unified command migration path](./diagrams/command/12-migration-path.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L448)

建议按完整竖切片迁移：

1. 建立 Definition、Parser 和只读 Snapshot；
2. 建立 Installer、Dispatcher 和 Gate；
3. 让帮助与补全只读取统一目录；
4. 建立 Interaction、Output 和 Refresh 适配；
5. 迁移涉及运行时替换的命令；
6. 删除旧 Built-in/Extension 类型和客户端命令名分支。

每迁移一个命令，旧路径必须同时移除或明确关闭，避免同一输入执行两次。最终不保留兼容别名层，除非产品明确要求。

## 17. 测试策略

![Unified command test strategy](./diagrams/command/13-test-strategy.svg)

[查看 PlantUML 源码](./diagrams/command/diagram.puml#L474)

| 层级 | 重点 |
|---|---|
| Definition 单元测试 | 名称规范、空字段、Policy 合法性 |
| Parser 单元测试 | 空白、参数原文、非法名称、非命令输入 |
| Gate 单元测试 | 五种 mode、共享/独占、取消、超时 |
| Dispatcher 单元测试 | 查找、结果映射、异常脱敏、刷新提示 |
| Catalog 契约测试 | 精确名称集合、稳定顺序、策略、冲突失败 |
| Handler 单元测试 | fake 服务与端口，覆盖业务成功/取消/失败 |
| 客户端集成测试 | TUI 与 App 读取同一目录且无旁路 |
| 交互验收 | 补全、帮助、执行、拒绝、刷新和审计闭环 |

禁止只断言“命令数量”。契约测试应断言精确命令名和策略，否则删除一个命令并新增另一个错误命令仍可能通过。

## 18. 验收标准

- Built-in 与 Extension 只剩一个 Java 定义、Handler 和注册模型；
- 目录中不存在 `extensionId`、`visibility`、`surfaces` 或动态生命周期字段；
- 进程内目录最多成功发布一次，失败不产生部分目录；
- 每个可执行命令均出现在统一帮助和补全中；
- TUI 与 App 不按命令名实现业务分支；
- 所有生产调用经过 Dispatcher 和 ExecutionGate；
- 五种 execution mode 有穷尽测试；
- `/compact`、会话替换、`/reload` 和 `/quit` 的控制流符合策略；
- Skill Command 保持动态 Prompt 投影，不混入静态目录；
- 新增命令不需要修改中心 `if/else` 或 `switch(name)`；
- 文档设计结论可追溯到固定 pi 源码或明确标注的 Java 产品约束。

## 19. 设计决策记录

| 决策 | 结果 | 原因 |
|---|---|---|
| Built-in 与 Extension 是否统一 | 统一 | 开发者、安全边界、生命周期和客户端均无差异 |
| Extension 是否保留 `extensionId` | 不保留 | 没有动态安装、卸载、升级、回滚或隔离消费者 |
| 是否保留两个 Handler 接口 | 不保留 | 执行语义相同；差异属于业务服务而非框架 |
| 执行模式是否使用 enum | 使用 | 模式有限且互斥，可穷尽检查，避免布尔组合冲突 |
| 是否保留 `visibility` | 不保留 | ToB 禁止隐藏可执行命令 |
| 是否保留 `surfaces` | 不保留 | TUI/App 共用语义，能力差异由端口表达 |
| 是否支持运行期命令 reload | 不支持 | 已确认无需求；静态快照更简单且可验证 |
| Handler 是否获取服务容器 | 不获取 | 服务构造器注入，Context 只承载调用态能力 |
| Skill 是否进入同一 Registry | 不进入 | Skill 是动态 Prompt 投影，不是内部业务 Handler |

## 20. PlantUML 维护

所有图的唯一源文件为 [`diagrams/command/diagram.puml`](./diagrams/command/diagram.puml)，图内文字、注释和标识符必须使用英文 ASCII。

生成命令：

```bash
cd diagrams/command
plantuml -tsvg diagram.puml
```

本文档生成基线为 PlantUML 1.2026.6。提交前至少检查：

```bash
plantuml -tsvg diagram.puml
rg -n '[^\x00-\x7F]' diagram.puml
```

第二条命令必须无输出。

## 21. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-07-14 | 以 pi Built-in 源码为基线，统一 Java Built-in/Extension Command，删除动态扩展、可见性和界面标签设计 |
