-- SR-AGENT-DB-001 v0.10.0
-- Target: GaussDB row-store tables with PostgreSQL-compatible syntax.
-- The base DDL intentionally omits physical foreign keys so it can be used
-- with GaussDB Distributed. The service maintains logical relationships in
-- one transaction.

CREATE TABLE t_agent_definition (
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
    CONSTRAINT ck_t_agent_definition_name CHECK (name <> ''),
    CONSTRAINT ck_t_agent_definition_display_name CHECK (display_name <> ''),
    CONSTRAINT ck_t_agent_definition_use_cases CHECK (
        jsonb_typeof(use_cases) = 'array'
    )
);

COMMENT ON TABLE t_agent_definition IS 'Agent current metadata, availability, system prompt fields, and use cases';
COMMENT ON COLUMN t_agent_definition.id IS 'Stable Agent identifier mapped directly from JSON id';
COMMENT ON COLUMN t_agent_definition.type IS 'Resource type mapped from JSON type; fixed to agent';
COMMENT ON COLUMN t_agent_definition.version IS 'Current optimistic-lock version; starts at 1 and increments once per successful update';
COMMENT ON COLUMN t_agent_definition.enabled IS 'Whether the Agent accepts new runtime invocations; disabled Agents remain manageable';
COMMENT ON COLUMN t_agent_definition.name IS 'Stable internal Agent name; unique and not editable in the management UI';
COMMENT ON COLUMN t_agent_definition.display_name IS 'Human-readable Agent name; not editable in the management UI';
COMMENT ON COLUMN t_agent_definition.description IS 'Agent description';
COMMENT ON COLUMN t_agent_definition.role IS 'Agent identity, expertise, and responsibility scope';
COMMENT ON COLUMN t_agent_definition.objective IS 'Long-term objective and success criteria';
COMMENT ON COLUMN t_agent_definition.instructions IS 'General work principles, priorities, and behavior requirements';
COMMENT ON COLUMN t_agent_definition.tool_policy IS 'Rules for tool selection, result verification, and direct answers';
COMMENT ON COLUMN t_agent_definition.safety IS 'Untrusted-content handling, permission boundaries, and confirmation rules';
COMMENT ON COLUMN t_agent_definition.completion IS 'Completion conditions, self-checks, and failure reporting';
COMMENT ON COLUMN t_agent_definition.response_style IS 'Default language, length, format, and reporting style';
COMMENT ON COLUMN t_agent_definition.example IS 'Required example for consistent behavior or output';
COMMENT ON COLUMN t_agent_definition.use_cases IS 'JSON array of intent-recognition use case strings';
COMMENT ON COLUMN t_agent_definition.created_at IS 'Time when the Agent metadata was created';
COMMENT ON COLUMN t_agent_definition.updated_at IS 'Time of the latest successful Agent metadata update';

CREATE TABLE t_agent_models (
    agent_id    VARCHAR(64) NOT NULL,
    model_id    VARCHAR(64) NOT NULL,
    sort_order  INTEGER     NOT NULL,
    CONSTRAINT pk_t_agent_models PRIMARY KEY (agent_id, model_id),
    CONSTRAINT uk_t_agent_models_order UNIQUE (agent_id, sort_order),
    CONSTRAINT ck_t_agent_models_order CHECK (sort_order >= 0),
    CONSTRAINT ck_t_agent_models_id CHECK (model_id <> '')
);

COMMENT ON TABLE t_agent_models IS 'Ordered model gateway model IDs from Agent model list';
COMMENT ON COLUMN t_agent_models.agent_id IS 'Logical reference to t_agent_definition.id';
COMMENT ON COLUMN t_agent_models.model_id IS 'Model ID defined by the model gateway';
COMMENT ON COLUMN t_agent_models.sort_order IS 'Zero-based position used to reproduce the JSON array';

CREATE TABLE t_agent_binding_tools (
    agent_id     VARCHAR(64) NOT NULL,
    tool_id      VARCHAR(64) NOT NULL,
    tool_version BIGINT,
    permission   VARCHAR(8),
    CONSTRAINT pk_t_agent_binding_tools PRIMARY KEY (agent_id, tool_id),
    CONSTRAINT ck_t_agent_binding_tools_id CHECK (tool_id <> ''),
    CONSTRAINT ck_t_agent_binding_tools_version CHECK (
        tool_version IS NULL OR tool_version >= 1
    ),
    CONSTRAINT ck_t_agent_binding_tools_permission CHECK (
        permission IS NULL OR permission IN ('deny', 'ask', 'allow')
    )
);

COMMENT ON TABLE t_agent_binding_tools IS 'Tool binding and optional Agent-level permission override';
COMMENT ON COLUMN t_agent_binding_tools.agent_id IS 'Logical reference to t_agent_definition.id';
COMMENT ON COLUMN t_agent_binding_tools.tool_id IS 'Referenced Tool identifier';
COMMENT ON COLUMN t_agent_binding_tools.tool_version IS 'Pinned Tool version; NULL means resolve the latest version';
COMMENT ON COLUMN t_agent_binding_tools.permission IS 'Agent-level deny, ask, or allow; NULL means inherit the Tool permission';

CREATE TABLE t_agent_binding_skills (
    agent_id      VARCHAR(64) NOT NULL,
    skill_id      VARCHAR(64) NOT NULL,
    skill_version BIGINT,
    CONSTRAINT pk_t_agent_binding_skills PRIMARY KEY (agent_id, skill_id),
    CONSTRAINT ck_t_agent_binding_skills_id CHECK (skill_id <> ''),
    CONSTRAINT ck_t_agent_binding_skills_version CHECK (
        skill_version IS NULL OR skill_version >= 1
    )
);

COMMENT ON TABLE t_agent_binding_skills IS 'Skill references bound to an Agent';
COMMENT ON COLUMN t_agent_binding_skills.agent_id IS 'Logical reference to t_agent_definition.id';
COMMENT ON COLUMN t_agent_binding_skills.skill_id IS 'Referenced Skill identifier';
COMMENT ON COLUMN t_agent_binding_skills.skill_version IS 'Pinned Skill version; NULL means resolve the latest version';

CREATE INDEX idx_t_agent_definition_display_name
    ON t_agent_definition (display_name);

CREATE INDEX idx_t_agent_definition_updated_at
    ON t_agent_definition (updated_at DESC, id);

CREATE INDEX idx_t_agent_models_model_id
    ON t_agent_models (model_id, agent_id);

CREATE INDEX idx_t_agent_binding_tools_tool_id
    ON t_agent_binding_tools (tool_id, agent_id);

CREATE INDEX idx_t_agent_binding_tools_permission
    ON t_agent_binding_tools (permission, agent_id);

CREATE INDEX idx_t_agent_binding_skills_skill_id
    ON t_agent_binding_skills (skill_id, agent_id);

-- Optional for a verified GaussDB centralized deployment that supports foreign
-- keys. Do not enable this block on GaussDB Distributed.
--
-- ALTER TABLE t_agent_models
--     ADD CONSTRAINT fk_t_agent_models_agent
--     FOREIGN KEY (agent_id) REFERENCES t_agent_definition (id)
--     ON DELETE CASCADE;
-- ALTER TABLE t_agent_binding_tools
--     ADD CONSTRAINT fk_t_agent_binding_tools_agent
--     FOREIGN KEY (agent_id) REFERENCES t_agent_definition (id)
--     ON DELETE CASCADE;
-- ALTER TABLE t_agent_binding_skills
--     ADD CONSTRAINT fk_t_agent_binding_skills_agent
--     FOREIGN KEY (agent_id) REFERENCES t_agent_definition (id)
--     ON DELETE CASCADE;
