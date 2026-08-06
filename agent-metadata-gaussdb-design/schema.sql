-- SR-AGENT-DB-001 v0.12.2
-- Target: GaussDB row-store tables with PostgreSQL-compatible syntax.
-- The base DDL intentionally omits physical foreign keys so it can be used
-- with GaussDB Distributed. The service maintains logical relationships in
-- one transaction.
-- Replace {dbUser} with the target database user/schema before execution.

DROP TABLE IF EXISTS "{dbUser}"."t_agent_models";
DROP TABLE IF EXISTS "{dbUser}"."t_agent_definition";
CREATE TABLE "{dbUser}"."t_agent_definition" (
    id              VARCHAR(64)  NOT NULL,
    type            VARCHAR(16)  NOT NULL DEFAULT 'agent',
    version         BIGINT       NOT NULL DEFAULT 1,
    enabled         BOOLEAN      NOT NULL DEFAULT TRUE,
    name            VARCHAR(128) NOT NULL,
    display_name    VARCHAR(128) NOT NULL,
    description     TEXT         NOT NULL,
    role            TEXT         NOT NULL,
    objective       TEXT         NOT NULL,
    instructions    TEXT         NOT NULL,
    tool_policy     TEXT         NOT NULL,
    safety          TEXT         NOT NULL,
    completion      TEXT         NOT NULL,
    response_style  TEXT         NOT NULL,
    example         TEXT         NOT NULL,
    use_cases       JSONB        NOT NULL DEFAULT '[]'::jsonb,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_t_agent_definition PRIMARY KEY (id),
    CONSTRAINT uk_t_agent_definition_name UNIQUE (name),
    CONSTRAINT ck_t_agent_definition_type CHECK (type = 'agent'),
    CONSTRAINT ck_t_agent_definition_version CHECK (version >= 1),
    CONSTRAINT ck_t_agent_definition_name CHECK (btrim(name) <> ''),
    CONSTRAINT ck_t_agent_definition_display_name CHECK (btrim(display_name) <> ''),
    CONSTRAINT ck_t_agent_definition_role CHECK (btrim(role) <> ''),
    CONSTRAINT ck_t_agent_definition_objective CHECK (btrim(objective) <> ''),
    CONSTRAINT ck_t_agent_definition_instructions CHECK (btrim(instructions) <> ''),
    CONSTRAINT ck_t_agent_definition_tool_policy CHECK (btrim(tool_policy) <> ''),
    CONSTRAINT ck_t_agent_definition_safety CHECK (btrim(safety) <> ''),
    CONSTRAINT ck_t_agent_definition_completion CHECK (btrim(completion) <> ''),
    CONSTRAINT ck_t_agent_definition_response_style CHECK (btrim(response_style) <> ''),
    CONSTRAINT ck_t_agent_definition_example CHECK (btrim(example) <> ''),
    CONSTRAINT ck_t_agent_definition_use_cases CHECK (
        jsonb_typeof(use_cases) = 'array'
    )
);

COMMENT ON TABLE "{dbUser}"."t_agent_definition" IS 'Agent 定义';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."id" IS 'Agent 标识';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."type" IS '资源类型';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."version" IS '版本号';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."enabled" IS '是否启用';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."name" IS '内部名称';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."display_name" IS '显示名称';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."description" IS '描述';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."role" IS '角色';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."objective" IS '目标';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."instructions" IS '指令';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."tool_policy" IS '工具策略';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."safety" IS '安全规则';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."completion" IS '完成条件';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."response_style" IS '响应风格';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."example" IS '示例';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."use_cases" IS '使用场景';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."created_at" IS '创建时间';
COMMENT ON COLUMN "{dbUser}"."t_agent_definition"."updated_at" IS '更新时间';

DROP TABLE IF EXISTS "{dbUser}"."t_agent_binding_models";
CREATE TABLE "{dbUser}"."t_agent_binding_models" (
    agent_id    VARCHAR(64) NOT NULL,
    model_id    VARCHAR(64) NOT NULL,
    model_order INTEGER     NOT NULL,
    CONSTRAINT pk_t_agent_binding_models PRIMARY KEY (agent_id, model_id),
    CONSTRAINT uk_t_agent_binding_models_order UNIQUE (agent_id, model_order),
    CONSTRAINT ck_t_agent_binding_models_order CHECK (model_order >= 0),
    CONSTRAINT ck_t_agent_binding_models_id CHECK (btrim(model_id) <> '')
);

COMMENT ON TABLE "{dbUser}"."t_agent_binding_models" IS 'Agent 模型绑定';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_models"."agent_id" IS 'Agent 标识';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_models"."model_id" IS '模型标识';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_models"."model_order" IS '模型排序';

DROP TABLE IF EXISTS "{dbUser}"."t_agent_binding_tools";
CREATE TABLE "{dbUser}"."t_agent_binding_tools" (
    agent_id     VARCHAR(64) NOT NULL,
    tool_id      VARCHAR(64) NOT NULL,
    tool_version BIGINT,
    permission   VARCHAR(8),
    CONSTRAINT pk_t_agent_binding_tools PRIMARY KEY (agent_id, tool_id),
    CONSTRAINT ck_t_agent_binding_tools_id CHECK (btrim(tool_id) <> ''),
    CONSTRAINT ck_t_agent_binding_tools_version CHECK (
        tool_version IS NULL OR tool_version >= 1
    ),
    CONSTRAINT ck_t_agent_binding_tools_permission CHECK (
        permission IS NULL OR permission IN ('deny', 'ask', 'allow')
    )
);

COMMENT ON TABLE "{dbUser}"."t_agent_binding_tools" IS 'Agent 工具绑定';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_tools"."agent_id" IS 'Agent 标识';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_tools"."tool_id" IS '工具标识';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_tools"."tool_version" IS '工具版本，NULL 表示最新版本';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_tools"."permission" IS '工具权限，NULL 表示继承';

DROP TABLE IF EXISTS "{dbUser}"."t_agent_binding_skills";
CREATE TABLE "{dbUser}"."t_agent_binding_skills" (
    agent_id      VARCHAR(64) NOT NULL,
    skill_id      VARCHAR(64) NOT NULL,
    skill_version BIGINT,
    CONSTRAINT pk_t_agent_binding_skills PRIMARY KEY (agent_id, skill_id),
    CONSTRAINT ck_t_agent_binding_skills_id CHECK (btrim(skill_id) <> ''),
    CONSTRAINT ck_t_agent_binding_skills_version CHECK (
        skill_version IS NULL OR skill_version >= 1
    )
);

COMMENT ON TABLE "{dbUser}"."t_agent_binding_skills" IS 'Agent 技能绑定';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_skills"."agent_id" IS 'Agent 标识';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_skills"."skill_id" IS '技能标识';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_skills"."skill_version" IS '技能版本，NULL 表示最新版本';

DROP TABLE IF EXISTS "{dbUser}"."t_agent_binding_agents";
CREATE TABLE "{dbUser}"."t_agent_binding_agents" (
    agent_id            VARCHAR(64) NOT NULL,
    bound_agent_id      VARCHAR(64) NOT NULL,
    bound_agent_version BIGINT,
    CONSTRAINT pk_t_agent_binding_agents PRIMARY KEY (agent_id, bound_agent_id),
    CONSTRAINT ck_t_agent_binding_agents_id CHECK (btrim(bound_agent_id) <> ''),
    CONSTRAINT ck_t_agent_binding_agents_version CHECK (
        bound_agent_version IS NULL OR bound_agent_version >= 1
    ),
    CONSTRAINT ck_t_agent_binding_agents_self CHECK (agent_id <> bound_agent_id)
);

COMMENT ON TABLE "{dbUser}"."t_agent_binding_agents" IS 'Agent 绑定';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_agents"."agent_id" IS 'Agent 标识';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_agents"."bound_agent_id" IS '绑定 Agent 标识';
COMMENT ON COLUMN "{dbUser}"."t_agent_binding_agents"."bound_agent_version" IS '绑定 Agent 版本，NULL 表示最新版本';

CREATE INDEX idx_t_agent_definition_display_name
    ON "{dbUser}"."t_agent_definition" (display_name);

CREATE INDEX idx_t_agent_definition_updated_at
    ON "{dbUser}"."t_agent_definition" (updated_at DESC, id);

CREATE INDEX idx_t_agent_binding_models_model_id
    ON "{dbUser}"."t_agent_binding_models" (model_id, agent_id);

CREATE INDEX idx_t_agent_binding_tools_tool_id
    ON "{dbUser}"."t_agent_binding_tools" (tool_id, agent_id);

CREATE INDEX idx_t_agent_binding_tools_permission
    ON "{dbUser}"."t_agent_binding_tools" (permission, agent_id);

CREATE INDEX idx_t_agent_binding_skills_skill_id
    ON "{dbUser}"."t_agent_binding_skills" (skill_id, agent_id);

CREATE INDEX idx_t_agent_binding_agents_bound_agent_id
    ON "{dbUser}"."t_agent_binding_agents" (bound_agent_id, agent_id);

-- Optional for a verified GaussDB centralized deployment that supports foreign
-- keys. Do not enable this block on GaussDB Distributed.
--
-- ALTER TABLE "{dbUser}"."t_agent_binding_models"
--     ADD CONSTRAINT fk_t_agent_binding_models_agent
--     FOREIGN KEY (agent_id) REFERENCES "{dbUser}"."t_agent_definition" (id)
--     ON DELETE CASCADE;
-- ALTER TABLE "{dbUser}"."t_agent_binding_tools"
--     ADD CONSTRAINT fk_t_agent_binding_tools_agent
--     FOREIGN KEY (agent_id) REFERENCES "{dbUser}"."t_agent_definition" (id)
--     ON DELETE CASCADE;
-- ALTER TABLE "{dbUser}"."t_agent_binding_skills"
--     ADD CONSTRAINT fk_t_agent_binding_skills_agent
--     FOREIGN KEY (agent_id) REFERENCES "{dbUser}"."t_agent_definition" (id)
--     ON DELETE CASCADE;
-- ALTER TABLE "{dbUser}"."t_agent_binding_agents"
--     ADD CONSTRAINT fk_t_agent_binding_agents_agent
--     FOREIGN KEY (agent_id) REFERENCES "{dbUser}"."t_agent_definition" (id)
--     ON DELETE CASCADE;
-- ALTER TABLE "{dbUser}"."t_agent_binding_agents"
--     ADD CONSTRAINT fk_t_agent_binding_agents_bound_agent
--     FOREIGN KEY (bound_agent_id) REFERENCES "{dbUser}"."t_agent_definition" (id)
--     ON DELETE CASCADE;
