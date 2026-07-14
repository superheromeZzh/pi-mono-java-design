# pi-mono-java Extension Command SR 设计

## 文档信息

| 项目 | 内容 |
|---|---|
| SR 编号 | SR-EXT-CMD-001 |
| SR 名称 | Java Extension Command 注册、发现与执行能力 |
| 适用项目 | `/Users/z/pi-mono-java` |
| 状态 | Draft |
| 日期 | 2026-07-13 |
| 版本 | v1.17 |
| 对齐基线 | pi TypeScript `ExtensionAPI.registerCommand()` |
| pi 源码提交 | `bb959aae017eedc8edaa91d01d0475d483ea9371` |

---

## 1. 设计目标

![Extension Command 设计目标](./diagrams/extension-command/01-extension-command-overview.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L4)

目标结论：

```text
Extension 元数据 = id
Command 公开接口 = name + description + argumentCompleter + handler
框架内部模型     = Command 公开接口 + ownerId
sourceInfo        = 不进入 Java Extension Command 设计
```

### 1.1 范围

| 本期包含 | 本期不包含 |
|---|---|
| Extension Command 注册 API | 外部 JAR 下载和安装 |
| 命令解析、发现、执行 | ClassLoader/ModuleLayer 隔离 |
| 名称与参数补全 | Prompt Template/Skill 内容重构 |
| 冲突、reload、unload | Extension 覆盖内置命令 |
| TUI 和 `/help` 接入 | Web 前端 Slash Command 重构 |
| 内置命令统一迁移 | 首版 RPC/Server 命令调用 |

前置条件：Extension 实例已由 Spring、`ServiceLoader`、测试代码或未来的 Extension Loader 加载。

### 1.2 PlantUML 图表源码

本 SR 的 20 个设计图统一由 [`diagrams/extension-command/diagram.puml`](./diagrams/extension-command/diagram.puml) 生成。每张图下方的源码链接直接定位到对应命名的 `@startuml`；Markdown 只引用生成后的 SVG，不复制维护第二份图形定义。

```bash
cd diagrams/extension-command
plantuml -tsvg diagram.puml
```

图源显式使用 PlantUML 内置 Smetana 布局，不依赖外部 Graphviz。SVG 是生成物，不得手工修改。本次使用 PlantUML `1.2026.6` 完成语法和 SVG 生成校验。

PlantUML 图源中的所有可读内容必须使用英文，包括 `title`、元素名称、关系标签、分支/循环标签、`note` 和源码注释；技术标识必须使用 ASCII，图源不得包含任何非 ASCII 字符。Markdown 正文、章节标题和 SVG 图注可以继续使用中文。生成 SVG 前执行以下检查，命令必须无输出：

```bash
rg -n '[^\x00-\x7F]' diagram.puml
```

---

## 2. 当前问题

### 2.1 当前调用关系

![Java 当前 Extension Command 调用关系](./diagrams/extension-command/02-current-call-relationship.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L57)

### 2.2 缺口矩阵

| 编号 | 当前实现 | 问题 |
|---|---|---|
| GAP-01 | `Extension.commands()` 聚合命令 | 未接入执行注册表 |
| GAP-02 | `commands.put(name, command)` | 同名命令静默覆盖 |
| GAP-03 | `SlashCommand.execute()` 同步返回 | 不适合异步 Extension 操作 |
| GAP-04 | `EditorContainer` 遇到空格关闭补全 | 无法补全参数 |
| GAP-05 | `InteractiveMode` 按命令字符串处理副作用 | 存在第二套命令行为 |
| GAP-06 | Registry 同时解析、存储和执行 | 职责耦合，难以扩展 RPC |

---

## 3. 目标架构

### 3.1 组件图

![Extension Command 目标组件架构](./diagrams/extension-command/03-target-architecture.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L84)

### 3.2 核心职责

| 组件 | 唯一职责 |
|---|---|
| `ExtensionApi` | 接收 Extension 注册声明 |
| `Registration Staging` | 收集并整体校验单个 Extension 的命令 |
| `SlashCommandRegistry` | 发布和查询有效命令快照 |
| `SlashCommandParser` | 将原始文本解析为 invocation |
| `SlashCommandDispatcher` | 查找命令并调用 Handler |
| `CommandCompletionService` | 路由名称补全和参数补全 |
| `InteractiveMode` | 输入编排和 TUI 渲染，不实现具体命令逻辑 |

---

## 4. 公开接口设计

### 4.1 API 类图

![Extension Command 公开 API 类图](./diagrams/extension-command/04-public-api-class.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L129)

`SlashCommandContext` 通过 Handler/Completer 方法签名和显式依赖线展示，不使用隐藏连线参与排版。

关系图例：

| 表示 | 含义 | 示例 |
|---|---|---|
| `..>` 虚线空心箭头 | 依赖：方法参数或返回类型 | `uses`、`returns` |
| `o--` 实线空心菱形 | 聚合：Options 持有外部提供的对象引用 | `contains` |
| 无连线 | 仅补充展示类结构 | `SlashCommandContext` |

### 4.2 Extension 与注册 API

```java
public interface Extension {
    String id();

    void initialize(ExtensionApi api);

    default void onLoad() {}

    default void onUnload() {}
}
```

Extension 只保留稳定机器身份 `id`。当前 Registry、所有权、日志和错误诊断均可使用 `id`，因此不预留没有实际消费者的 `name()`。如果未来出现 Extension 管理界面或本地化展示需求，再通过明确的 `displayName` 元数据扩展。

#### 4.2.1 Extension ID 约束

`id` 是 Extension 在 Registry 中的稳定机器身份，并用于派生内部 `ownerId`。开发者直接提供 `id`，框架不根据路径生成，也不进行 trim、大小写转换或其他隐式规范化。

| 约束项 | 规则 |
|---|---|
| 长度 | 1～64 个 ASCII 字符，包含边界 |
| 允许字符 | 小写英文字母 `a-z`、数字 `0-9`、连字符 `-` |
| 起始字符 | 必须是小写英文字母 |
| 结束字符 | 必须是小写英文字母或数字 |
| 连字符 | 不能出现在开头、结尾或连续出现 |
| 大小写 | 不允许大写字母 |
| 保留名称 | 禁止 `builtin`、`system`、`internal` |
| 保留前缀 | 禁止 `builtin-`、`system-`、`internal-` |
| 稳定性 | ID 发布后不得修改；修改 ID 视为删除旧 Extension 并注册新 Extension |
| 唯一性 | 在 Extension Registry 中全局唯一；冲突时注册失败，不得静默替换 |

语法正则：

```regex
^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$
```

Java 使用严格输入边界，并单独检查长度和保留名称，以便返回明确的校验错误：

```java
private static final Pattern EXTENSION_ID_PATTERN = Pattern.compile(
        "\\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\\z");

private static final Set<String> RESERVED_EXTENSION_IDS = Set.of(
        "builtin", "system", "internal");

private static final List<String> RESERVED_EXTENSION_ID_PREFIXES = List.of(
        "builtin-", "system-", "internal-");

public static boolean isValidExtensionId(String id) {
    if (id == null || id.length() < 1 || id.length() > 64) {
        return false;
    }
    if (!EXTENSION_ID_PATTERN.matcher(id).matches()) {
        return false;
    }
    if (RESERVED_EXTENSION_IDS.contains(id)) {
        return false;
    }
    return RESERVED_EXTENSION_ID_PREFIXES.stream()
            .noneMatch(id::startsWith);
}
```

正确示例：

```text
a
deploy
space-deploy
space-memory2
campusagent-coding-git-tools
```

长度下限 1 只定义语法边界。开发者仍应选择能够表达功能或领域的 ID，不应为了缩短名称而使用无意义的单字符 ID。

错误示例：

| ID | 错误原因 |
|---|---|
| 空字符串 | 少于 1 个字符 |
| 65 个连续的 `a` | 超过 64 个字符 |
| `12345` | 首字符不是字母 |
| `Campusagent-space` | 包含大写字母 |
| `-campusagent-space` | 以连字符开头 |
| `campusagent-space-` | 以连字符结尾 |
| `campusagent--space` | 包含连续连字符 |
| `campusagent.space.deploy` | 包含点号 |
| `campusagent_space_deploy` | 包含下划线 |
| `campusagent space` | 包含空格 |
| `campusagent/space` | 包含斜杠 |
| `部署命令` | 包含非 ASCII 字符 |
| `builtin-deploy` | 使用宿主保留前缀 |

不强制 ID 包含连字符或具有固定段数。唯一性由 Registry 保证，段数不承担命名空间或冲突检测职责。

#### 4.2.2 注册 API

```java
public interface ExtensionApi {
    void registerCommand(
            String name,
            SlashCommandOptions options);
}
```

`name` 是用户调用的 Slash Command 名称。例如，`name` 为 `deploy` 时，用户通过 `/deploy` 调用。它是 `registerCommand` 的方法参数，不是 Extension 元数据。

通用正则：

```regex
^(?=.{1,64}$)[a-z][a-z0-9]*(?:-[a-z0-9]+)*$
```

Java 使用严格输入边界：

```java
private static final Pattern COMMAND_NAME_PATTERN = Pattern.compile(
        "\\A(?=.{1,64}\\z)[a-z][a-z0-9]*(?:-[a-z0-9]+)*\\z");
```

| 约束项 | 规则 |
|---|---|
| 长度 | 1～64 个 ASCII 字符，长度由正则限定 |
| 起始字符 | 必须是小写英文字母 |
| 允许字符 | 小写英文字母 `a-z`、数字 `0-9`、连字符 `-` |
| 连字符 | 不能出现在开头、结尾或连续出现 |
| Slash | `name` 不包含调用前缀 `/` |
| 归一化 | 不进行 trim 或大小写转换 |

| 允许 | 拒绝 | 原因 |
|---|---|---|
| `deploy` | `/deploy` | 名称不包含 `/` |
| `scoped-models` | `Deploy` | 不隐式转换大小写 |
| `review2` | `skill:review` | 不允许冒号 |
| `git-status` | `git status` | 不允许空白 |
| `a` | `deploy-` | 不允许结尾连字符 |
| `deploy-prod` | `deploy--prod` | 不允许连续连字符 |
| 64 个连续的 `a` | 65 个连续的 `a` | 超过长度上限 |

### 4.3 Command Options

`description` 的正则应用于 `strip()` 处理后的文本。

通用形式（正则引擎需支持 Unicode General Category）：

```regex
^(?=.{1,1024}$)[^\p{Cc}\p{Zl}\p{Zp}]+$
```

Java 使用严格输入边界：

```java
public record SlashCommandOptions(
        String description,
        SlashCommandArgumentCompleter argumentCompleter,
        SlashCommandHandler handler) {

    private static final Pattern COMMAND_DESCRIPTION_PATTERN = Pattern.compile(
            "\\A(?=.{1,1024}\\z)[^\\p{Cc}\\p{Zl}\\p{Zp}]+\\z");

    public SlashCommandOptions {
        Objects.requireNonNull(description, "description");
        description = description.strip();
        int descriptionLength = description.codePointCount(
                0,
                description.length());
        if (descriptionLength < 1 || descriptionLength > 1024) {
            throw new IllegalArgumentException(
                    "description must contain 1 to 1024 Unicode code points");
        }
        if (!COMMAND_DESCRIPTION_PATTERN.matcher(description).matches()) {
            throw new IllegalArgumentException(
                    "description must be single-line text without control characters");
        }
        argumentCompleter = argumentCompleter == null
                ? SlashCommandArgumentCompleter.none()
                : argumentCompleter;
        Objects.requireNonNull(handler, "handler");
    }
}
```

`description` 用于 `/help` 和命令补全展示，不参与命令身份或冲突判断。

| 约束项 | 规则 |
|---|---|
| 必填性 | 必填，不允许 `null` |
| 归一化 | 校验前使用 `strip()` 删除首尾 Unicode 空白 |
| 长度 | 归一化后 1～1024 个 Unicode 码点，正则包含长度断言，`codePointCount()` 负责精确校验 |
| 字符 | 允许 Unicode；正则排除控制字符 `Cc`、行分隔符 `Zl` 和段落分隔符 `Zp`，因此同时拒绝换行和 ANSI ESC |
| 稳定性 | 允许修改，不影响 Command 身份 |

### 4.4 Handler 与 Completer

```java
@FunctionalInterface
public interface SlashCommandHandler {
    CompletionStage<Void> handle(
            String arguments,
            SlashCommandContext context);
}
```

```java
@FunctionalInterface
public interface SlashCommandArgumentCompleter {
    CompletionStage<List<SlashCommandCompletion>> complete(
            String argumentPrefix,
            SlashCommandContext context);

    static SlashCommandArgumentCompleter none() {
        return (prefix, context) ->
                CompletableFuture.completedFuture(List.of());
    }
}
```

```java
public record SlashCommandCompletion(
        String value,
        String label,
        String description) {}
```

### 4.5 与 pi TypeScript 映射

| pi TypeScript | Java 设计 |
|---|---|
| Extension factory | `Extension.initialize(ExtensionApi)` |
| `pi.registerCommand(name, options)` | `api.registerCommand(name, options)` |
| options object | `SlashCommandOptions` record |
| `getArgumentCompletions(prefix)` | `argumentCompleter.complete(prefix, context)` |
| `async handler(args, ctx)` | `CompletionStage<Void> handle(args, context)` |
| loader 注入 `sourceInfo` | Registry 内部绑定 `extensionId` |

---

## 5. 内部数据模型

### 5.1 模型图

![Extension Command 内部数据模型](./diagrams/extension-command/05-internal-data-model.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L179)

```java
record RegisteredSlashCommand(
        String ownerId,
        String name,
        String description,
        SlashCommandArgumentCompleter argumentCompleter,
        SlashCommandHandler handler) {}
```

### 5.2 所有权

| 命令来源 | `ownerId` 示例 | 开发者是否提供 |
|---|---|---|
| 内置命令 | `builtin` | 否 |
| Extension | `extension:space-deploy` | 否，由 scoped API 根据 Extension ID 绑定 |

`RegisteredSlashCommand`、`ownerId` 和 Registry Snapshot 均为内部实现，不属于 Extension SDK。

---

## 6. 注册与生命周期

### 6.1 首次注册时序

![Extension Command 首次注册](./diagrams/extension-command/06-initial-registration.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L220)

### 6.2 Reload 时序

![Extension Command Reload](./diagrams/extension-command/07-reload.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L256)

### 6.3 生命周期状态图

![Extension Command 生命周期](./diagrams/extension-command/08-lifecycle-state.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L291)

### 6.4 生命周期规则

| 编号 | 规则 |
|---|---|
| LIFE-01 | 单个 Extension 的全部命令先暂存、后整体提交 |
| LIFE-02 | 校验失败不得改变现有 Registry Snapshot |
| LIFE-03 | 同一 owner reload 只能看到旧集合或新集合 |
| LIFE-04 | unload 必须删除 owner 的全部命令 |
| LIFE-05 | 正在执行的 Handler 使用执行开始时取得的旧命令实例 |

---

## 7. 冲突与校验

### 7.1 注册决策图

![Extension Command 注册决策](./diagrams/extension-command/09-registration-decision.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L314)

### 7.2 冲突策略

| 场景 | 结果 |
|---|---|
| Extension 与 Built-in 同名 | Extension 注册失败 |
| 两个 Extension 同名 | 后注册 Extension 失败 |
| 同一 Extension 重复注册 | 本次 Extension 初始化失败 |
| 同 owner reload 同名 | 允许原子替换 |
| Alias | 首版注册为独立命令名 |

禁止使用静默覆盖或自动生成 `/review:1`、`/review:2`。

---

## 8. 命令执行设计

### 8.1 输入优先级

![Extension Command 输入优先级](./diagrams/extension-command/10-input-priority.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L363)

### 8.2 执行时序

![Extension Command 执行时序](./diagrams/extension-command/11-execution-sequence.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L394)

### 8.3 解析结果

```java
public record SlashCommandInvocation(
        String name,
        String arguments) {}
```

| 输入 | 状态/Invocation |
|---|---|
| `hello` | `NOT_COMMAND` |
| `/` | `NOT_FOUND` |
| `/deploy` | `deploy`, `""` |
| `/deploy staging` | `deploy`, `"staging"` |
| `/unknown x` | `NOT_FOUND` |

### 8.4 Dispatch 结果

```java
public enum SlashCommandDispatchStatus {
    NOT_COMMAND,
    NOT_FOUND,
    HANDLED,
    FAILED
}
```

```java
public record SlashCommandDispatchResult(
        SlashCommandDispatchStatus status,
        String name,
        String errorMessage) {}
```

未知 `/name` 是否继续作为普通 Prompt，由上层输入策略决定；Dispatcher 只返回 `NOT_FOUND`。

---

## 9. 自动补全设计

### 9.1 补全路由

![Extension Command 补全路由](./diagrams/extension-command/12-completion-routing.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L433)

### 9.2 参数补全时序

![Extension Command 参数补全](./diagrams/extension-command/13-argument-completion.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L472)

### 9.3 首版边界

| 能力 | 首版 |
|---|---|
| 命令名补全 | 支持 |
| 行尾参数补全 | 支持 |
| 异步 Completer | 支持 |
| 过期结果丢弃 | 支持 |
| 默认超时 | 1000 ms |
| 光标位于参数中间 | 后续 |
| Replace Range | 后续 |

---

## 10. Extension 开发示例

以下是目标 API 示例，不是当前仓库已存在接口。

| 元数据 | 示例 | 含义 |
|---|---|---|
| Extension ID | `space-deploy` | 稳定 Registry 身份，框架派生 `extension:space-deploy` |
| Command name | `deploy` | `registerCommand` 的 `name`，用户通过 `/deploy` 调用 |

```java
public final class DeployExtension implements Extension {

    @Override
    public String id() {
        return "space-deploy";
    }

    @Override
    public void initialize(ExtensionApi api) {
        api.registerCommand(
                "deploy",
                new SlashCommandOptions(
                        "Deploy to an environment",
                        this::completeEnvironment,
                        this::deploy));
    }

    private CompletionStage<List<SlashCommandCompletion>> completeEnvironment(
            String prefix,
            SlashCommandContext context) {
        var items = List.of("dev", "staging", "prod").stream()
                .filter(value -> value.startsWith(prefix))
                .map(value -> new SlashCommandCompletion(
                        value,
                        value,
                        "Deploy to " + value))
                .toList();

        return CompletableFuture.completedFuture(items);
    }

    private CompletionStage<Void> deploy(
            String arguments,
            SlashCommandContext context) {
        String environment = arguments.trim();
        if (environment.isEmpty()) {
            context.output().println("Usage: /deploy <environment>");
            return CompletableFuture.completedFuture(null);
        }

        context.output().println("Deploying to " + environment);
        return CompletableFuture.completedFuture(null);
    }
}
```

![Deploy Extension 开发示例](./diagrams/extension-command/14-development-example.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L502)

---

## 11. 功能需求

| ID | 需求 | 验证方式 |
|---|---|---|
| FR-001 | Extension 通过 `initialize(ExtensionApi)` 注册命令 | API 单测 |
| FR-002 | `registerCommand` 只接收 `name` 和 `options` | 编译检查 |
| FR-003 | 公开 Command API 不包含 `sourceInfo`、`ownerId` | API 审查 |
| FR-004 | Command `name`、`description`、`handler` 必填；completer 可选 | 校验单测 |
| FR-005 | Command name 必须符合 `^(?=.{1,64}$)[a-z][a-z0-9]*(?:-[a-z0-9]+)*$` | 参数化测试 |
| FR-006 | Built-in 名称对 Extension 保留 | 冲突测试 |
| FR-007 | 同名命令不得静默覆盖 | 冲突测试 |
| FR-008 | Extension 命令以 owner 为单位原子提交 | Snapshot 测试 |
| FR-009 | Reload 失败保留旧命令集合 | Reload 测试 |
| FR-010 | Unload 删除 owner 的全部命令 | 生命周期测试 |
| FR-011 | Handler 返回 `CompletionStage<Void>` | API 单测 |
| FR-012 | Handler 异常转换为 `FAILED`，不终止宿主 | 故障测试 |
| FR-013 | Handler 返回 null 时产生明确诊断 | 故障测试 |
| FR-014 | Dispatcher 返回结构化状态 | Dispatcher 测试 |
| FR-015 | Extension Command 执行后不进入 LLM Prompt | 集成测试 |
| FR-016 | 未知命令返回 `NOT_FOUND` | Parser/Dispatcher 测试 |
| FR-017 | `/help` 使用统一 Registry | Help 测试 |
| FR-018 | TUI 名称补全使用统一 Registry | TUI 测试 |
| FR-019 | TUI 支持 `/command args` 参数补全 | TUI 测试 |
| FR-020 | Completer 异常、超时、null 按空列表处理 | 补全测试 |
| FR-021 | 内置与 Extension 命令使用同一 Dispatcher | 集成测试 |
| FR-022 | `InteractiveMode` 不按具体命令名实现副作用 | 代码审查 |
| FR-023 | 命令快照顺序稳定 | Registry 测试 |
| FR-024 | Context 每次执行创建，Extension 不缓存 | 生命周期测试/文档 |
| FR-025 | 核心层不依赖 TUI，预留 RPC 复用 | 依赖检查 |
| FR-026 | Extension ID 长度为 1～64，且符合 `^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$` | 参数化测试 |
| FR-027 | Extension ID 禁止宿主保留名称和前缀 | 参数化测试 |
| FR-028 | Extension ID 全局唯一，冲突时注册失败，不静默替换 | Registry 测试 |
| FR-029 | Command description 经 `strip()` 后必须匹配 `^(?=.{1,1024}$)[^\p{Cc}\p{Zl}\p{Zp}]+$`，并通过 1～1024 个 Unicode 码点精确校验 | 参数化测试 |

---

## 12. 非功能需求

| ID | 类别 | 需求 |
|---|---|---|
| NFR-001 | 性能 | 命令按名称查询平均 O(1) |
| NFR-002 | 性能 | 1000 个命令名称过滤在普通开发机上不超过 20 ms |
| NFR-003 | 响应性 | Handler 和 Completer 不在 TUI 输入线程阻塞等待 |
| NFR-004 | 并发 | 查询与 reload 并发时不出现部分更新或并发修改异常 |
| NFR-005 | 一致性 | Registry 使用不可变快照或 copy-on-write 等价机制 |
| NFR-006 | 可靠性 | 单个 Extension 失败不影响其他命令和当前会话 |
| NFR-007 | 日志 | INFO 不记录完整命令参数 |
| NFR-008 | 诊断 | 日志使用 `ownerId/name` 标识命令 |
| NFR-009 | 安全 | 文档明确 Extension Command 拥有宿主进程权限 |
| NFR-010 | 测试 | Parser、Registry、Dispatcher 可脱离 Spring/TUI 单测 |

---

## 13. 模块落点

```text
modules/coding-agent-cli/src/main/java/com/campusclaw/codingagent/
├── command/
│   ├── SlashCommandOptions.java
│   ├── SlashCommandHandler.java
│   ├── SlashCommandArgumentCompleter.java
│   ├── SlashCommandCompletion.java
│   ├── SlashCommandContext.java
│   ├── SlashCommandInvocation.java
│   ├── SlashCommandParser.java
│   ├── SlashCommandDispatcher.java
│   ├── SlashCommandDispatchResult.java
│   ├── SlashCommandDispatchStatus.java
│   ├── SlashCommandRegistry.java
│   ├── DefaultSlashCommandRegistry.java
│   ├── internal/
│   │   ├── RegisteredSlashCommand.java
│   │   └── CommandRegistrySnapshot.java
│   └── builtin/
├── extension/
│   ├── Extension.java
│   ├── ExtensionApi.java
│   ├── DefaultExtensionApi.java
│   └── ExtensionRegistry.java
└── mode/tui/
    └── EditorContainer.java
```

依赖方向：

![Extension Command 依赖方向](./diagrams/extension-command/15-dependency-direction.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L528)

---

## 14. 迁移设计

### 14.1 迁移路径

![Extension Command 迁移路径](./diagrams/extension-command/16-migration-path.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L551)

### 14.2 现有类型迁移

| 当前类型/逻辑 | 目标 |
|---|---|
| `Extension.commands()` | 删除，改为 `initialize(ExtensionApi)` |
| `ExtensionRegistry.getAllCommands()` | 删除，注册阶段直接提交 Registry |
| `SlashCommand` 实现类 | 临时 Adapter，最终迁移为统一 Handler |
| `SlashCommandRegistry.execute()` | 拆为 Parser + Dispatcher |
| `Map.put()` 静默覆盖 | 原子校验 + 显式冲突 |
| `EditorContainer.CommandSuggestion` | 由 Completion Service 提供 |
| `handleSlashCommandWithSideEffects()` | Handler/Command Event |

### 14.3 回滚边界

![Extension Command 回滚边界](./diagrams/extension-command/17-rollback-boundary.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L576)

---

## 15. 测试设计

### 15.1 测试金字塔

![Extension Command 测试金字塔](./diagrams/extension-command/18-test-pyramid.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L604)

### 15.2 测试矩阵

| 测试类 | 核心场景 |
|---|---|
| `SlashCommandParserTest` | 非命令、空命令、参数拆分、未知命令 |
| `SlashCommandRegistryTest` | 合法注册、非法名称、稳定顺序、冲突 |
| `SlashCommandOptionsTest` | description 空值、空白、长度边界、控制字符和 Unicode 码点 |
| `SlashCommandRegistryReloadTest` | 原子替换、失败保留、卸载清理 |
| `SlashCommandDispatcherTest` | 四种状态、异步成功和失败 |
| `SlashCommandArgumentCompleterTest` | 候选、异常、超时、过期结果 |
| `DefaultExtensionApiTest` | owner 绑定、禁止伪造 owner |
| `ExtensionRegistryCommandTest` | 注册、替换、卸载完整生命周期 |
| `HelpCommandTest` | 内置和 Extension 统一展示 |
| `EditorContainerCommandCompletionTest` | 名称和参数补全 |

禁止使用真实模型、真实 Provider 或真实外部网络验证 Extension Command。

---

## 16. 验收场景

![Extension Command 验收时序](./diagrams/extension-command/19-acceptance-sequence.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L622)

| AC | 验收项 | 通过条件 |
|---|---|---|
| AC-01 | 公开接口 | Extension 通过 `registerCommand` 注册；无 `sourceInfo` |
| AC-02 | 生产执行 | Extension Command 在 TUI 中真实执行 |
| AC-03 | 统一发现 | `/help` 和名称补全同时可见 |
| AC-04 | 参数补全 | `/deploy st` 可补全 `staging` |
| AC-05 | 不进入模型 | Handler 执行后不产生普通 Prompt |
| AC-06 | 冲突安全 | 同名注册失败，旧 Snapshot 不变 |
| AC-07 | 生命周期 | reload 原子替换，unload 完整清理 |
| AC-08 | 故障隔离 | Handler/Completer 失败后宿主仍可用 |
| AC-09 | 架构统一 | Built-in 与 Extension 使用同一 Registry/Dispatcher |
| AC-10 | 无旁路 | `InteractiveMode` 不按具体命令名处理副作用 |
| AC-11 | 测试 | 新增单元和集成测试全部通过 |
| AC-12 | Extension ID | ID 校验符合约束；重复 ID 不改变现有 Registry |
| AC-13 | Command 元数据 | name 长度与格式、description 长度与字符校验符合约束 |

---

## 17. 开放问题

| 编号 | 问题 | 本期决策 |
|---|---|---|
| OQ-01 | 外部 Extension 如何发现和隔离 | 由独立 Extension Loader SR 决定 |
| OQ-02 | `onLoad()` 失败如何整体回滚 | 由 Extension 生命周期 SR 决定 |
| OQ-03 | RPC 何时支持 `get_commands` | 后续增强 |
| OQ-04 | `AgentSession` 是否改为稳定 Facade | 后续 SDK 稳定化 |
| OQ-05 | 是否支持参数中间位置补全 | 首版不支持 |
| OQ-06 | 是否增加 Alias | 首版注册独立命令名 |

---

## 18. 结论

![Extension Command 结论](./diagrams/extension-command/20-conclusion.svg)

PlantUML：[查看源码](./diagrams/extension-command/diagram.puml#L651)

Java Extension Command 采用 pi 语义一致的注册模型：

```text
Extension.initialize(ExtensionApi)
  → registerCommand(name, SlashCommandOptions)
  → Registry 内部绑定 extensionId
  → 原子发布命令快照
  → 统一帮助、补全、执行和卸载
```
