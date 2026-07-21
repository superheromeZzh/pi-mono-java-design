# pi-mono-java Design

本仓库用于管理 `pi-mono-java` 的设计文档。

## 文档

- [Command SR 设计](./pi-mono-java-command-SR设计.md)
- [Skill Command SR 设计](./pi-mono-java-skill-command-SR设计.md)
- [主流 Agent Tool/Agent 元数据机制调研与统一设计](./config-to-tool-agent-research/README.md)
- [主流 Agent 平台 Agent、Tool 与 Skill 创建官方文档](./主流Agent平台Agent-Tool-Skill创建官方文档.md)
- [Anthropic Managed Agents 公开模型](./anthropic-managed-agents-public-model/README.md)
- [主流 Agent 数据库模式拆解与 pi-mono Java 采纳边界](./agent-database-patterns/README.md)
- [pi-mono Java ToB 记忆系统 SR 设计](./memory-jsonl-to-gaussdb.md)

## 约定

- Markdown 是设计文档的唯一源文件。
- 类图使用标准 UML 关系线表达真实语义。
- 排版辅助关系不得显示为设计语义。
- 新建或修改的设计图使用 PlantUML 源码并提交生成后的 SVG；Markdown 引用 SVG，不复制维护第二份图形定义。
- 每组 PlantUML 图统一使用 `diagram.puml`，在图源目录执行 `plantuml -tsvg diagram.puml`；SVG 不得手工修改。
- PlantUML 图源中的标题、元素名称、关系标签、分支/循环标签、注释和源码注释必须只使用英文，技术标识必须使用 ASCII；图源不得包含任何非 ASCII 字符。Markdown 正文和图注可以使用中文。
- 文档变更通过版本号记录。
- 每项源自 pi 的设计必须给出指向固定 commit 的可点击源码链接，并标明仓库相对路径、符号或行号，说明从源码观察到的行为。
- 文档信息必须记录分析时使用的 pi commit；行号只对该基线负责。
- Java 目标设计必须同时说明设计原因；与 pi 不一致时必须明确标注为产品约束、安全强化或架构改造，不得写成 pi 原生行为。
- 核心行为先用简洁的自然语言说明“什么时候可以执行、会发生什么”；框架组件、状态机和并发控制等实现细节放在行为说明之后。禁止性约束应同时说明负责组件和替代路径，不得用否定句代替能力定义。
