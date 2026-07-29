-- SR-AGENT-DB-001 v0.2.0
-- Target: GaussDB row-store tables with PostgreSQL-compatible syntax.
-- The base DDL intentionally omits physical foreign keys so it can be used
-- with GaussDB Distributed. The service must maintain the documented logical
-- relationships in one transaction.

CREATE TABLE agent_metadata (
    agent_id               VARCHAR(64)  NOT NULL,
    resource_type          VARCHAR(16)  NOT NULL DEFAULT 'agent',
    version                BIGINT       NOT NULL DEFAULT 1,
    name                   VARCHAR(128) NOT NULL,
    display_name           VARCHAR(160) NOT NULL,
    description            TEXT         NOT NULL,
    system_role            TEXT         NOT NULL,
    system_objective       TEXT         NOT NULL,
    system_instructions    TEXT         NOT NULL,
    system_tool_policy     TEXT         NOT NULL,
    system_safety          TEXT         NOT NULL,
    system_completion      TEXT         NOT NULL,
    system_response_style  TEXT         NOT NULL,
    system_example         TEXT,
    created_at             TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at             TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_agent_metadata PRIMARY KEY (agent_id),
    CONSTRAINT uk_agent_metadata_name UNIQUE (name),
    CONSTRAINT ck_agent_metadata_type CHECK (resource_type = 'agent'),
    CONSTRAINT ck_agent_metadata_version CHECK (version >= 1),
    CONSTRAINT ck_agent_metadata_name CHECK (name <> ''),
    CONSTRAINT ck_agent_metadata_display_name CHECK (display_name <> '')
);

COMMENT ON TABLE agent_metadata IS 'Agent current metadata and fixed system prompt fields';
COMMENT ON COLUMN agent_metadata.agent_id IS 'Stable Agent identifier mapped from JSON id';
COMMENT ON COLUMN agent_metadata.resource_type IS 'Resource type mapped from JSON type; fixed to agent';
COMMENT ON COLUMN agent_metadata.version IS 'Current optimistic-lock version; starts at 1 and increments once per successful update';
COMMENT ON COLUMN agent_metadata.name IS 'Stable internal Agent name; unique and not editable in the management UI';
COMMENT ON COLUMN agent_metadata.display_name IS 'Human-readable Agent name; editable in the management UI';
COMMENT ON COLUMN agent_metadata.description IS 'Agent description';
COMMENT ON COLUMN agent_metadata.system_role IS 'Agent identity, expertise, and responsibility scope';
COMMENT ON COLUMN agent_metadata.system_objective IS 'Long-term objective and success criteria';
COMMENT ON COLUMN agent_metadata.system_instructions IS 'General work principles, priorities, and behavior requirements';
COMMENT ON COLUMN agent_metadata.system_tool_policy IS 'Rules for tool selection, result verification, and direct answers';
COMMENT ON COLUMN agent_metadata.system_safety IS 'Untrusted-content handling, permission boundaries, and confirmation rules';
COMMENT ON COLUMN agent_metadata.system_completion IS 'Completion conditions, self-checks, and failure reporting';
COMMENT ON COLUMN agent_metadata.system_response_style IS 'Default language, length, format, and reporting style';
COMMENT ON COLUMN agent_metadata.system_example IS 'Optional example for highly consistent behavior or output';
COMMENT ON COLUMN agent_metadata.created_at IS 'Database creation time';
COMMENT ON COLUMN agent_metadata.updated_at IS 'Time of the latest successful Agent metadata update';

CREATE TABLE agent_model (
    agent_id    VARCHAR(64)  NOT NULL,
    model_id    VARCHAR(256) NOT NULL,
    sort_order  INTEGER      NOT NULL,
    CONSTRAINT pk_agent_model PRIMARY KEY (agent_id, model_id),
    CONSTRAINT uk_agent_model_order UNIQUE (agent_id, sort_order),
    CONSTRAINT ck_agent_model_order CHECK (sort_order >= 0),
    CONSTRAINT ck_agent_model_id CHECK (model_id <> '')
);

COMMENT ON TABLE agent_model IS 'Ordered model gateway model IDs from Agent models';
COMMENT ON COLUMN agent_model.agent_id IS 'Logical reference to agent_metadata.agent_id';
COMMENT ON COLUMN agent_model.model_id IS 'Model ID defined by the model gateway';
COMMENT ON COLUMN agent_model.sort_order IS 'Zero-based position used to reproduce the JSON array';

CREATE TABLE agent_use_case (
    agent_id    VARCHAR(64) NOT NULL,
    sort_order  INTEGER     NOT NULL,
    use_case    TEXT        NOT NULL,
    CONSTRAINT pk_agent_use_case PRIMARY KEY (agent_id, sort_order),
    CONSTRAINT ck_agent_use_case_order CHECK (sort_order >= 0),
    CONSTRAINT ck_agent_use_case_value CHECK (use_case <> '')
);

COMMENT ON TABLE agent_use_case IS 'Ordered Agent use cases used by intent recognition';
COMMENT ON COLUMN agent_use_case.agent_id IS 'Logical reference to agent_metadata.agent_id';
COMMENT ON COLUMN agent_use_case.sort_order IS 'Zero-based position used to reproduce the JSON array';
COMMENT ON COLUMN agent_use_case.use_case IS 'One intent-recognition use case';

CREATE TABLE agent_tool_binding (
    agent_id     VARCHAR(64)  NOT NULL,
    tool_id      VARCHAR(128) NOT NULL,
    tool_version BIGINT,
    sort_order   INTEGER      NOT NULL,
    CONSTRAINT pk_agent_tool_binding PRIMARY KEY (agent_id, tool_id),
    CONSTRAINT uk_agent_tool_binding_order UNIQUE (agent_id, sort_order),
    CONSTRAINT ck_agent_tool_binding_order CHECK (sort_order >= 0),
    CONSTRAINT ck_agent_tool_binding_id CHECK (tool_id <> ''),
    CONSTRAINT ck_agent_tool_binding_version CHECK (
        tool_version IS NULL OR tool_version >= 1
    )
);

COMMENT ON TABLE agent_tool_binding IS 'Ordered Tool references bound to an Agent';
COMMENT ON COLUMN agent_tool_binding.agent_id IS 'Logical reference to agent_metadata.agent_id';
COMMENT ON COLUMN agent_tool_binding.tool_id IS 'Referenced Tool identifier';
COMMENT ON COLUMN agent_tool_binding.tool_version IS 'Pinned Tool version; NULL means resolve the latest version';
COMMENT ON COLUMN agent_tool_binding.sort_order IS 'Zero-based position used to reproduce the JSON array';

CREATE TABLE agent_skill_binding (
    agent_id      VARCHAR(64)  NOT NULL,
    skill_id      VARCHAR(128) NOT NULL,
    skill_version BIGINT,
    sort_order    INTEGER      NOT NULL,
    CONSTRAINT pk_agent_skill_binding PRIMARY KEY (agent_id, skill_id),
    CONSTRAINT uk_agent_skill_binding_order UNIQUE (agent_id, sort_order),
    CONSTRAINT ck_agent_skill_binding_order CHECK (sort_order >= 0),
    CONSTRAINT ck_agent_skill_binding_id CHECK (skill_id <> ''),
    CONSTRAINT ck_agent_skill_binding_version CHECK (
        skill_version IS NULL OR skill_version >= 1
    )
);

COMMENT ON TABLE agent_skill_binding IS 'Ordered Skill references bound to an Agent';
COMMENT ON COLUMN agent_skill_binding.agent_id IS 'Logical reference to agent_metadata.agent_id';
COMMENT ON COLUMN agent_skill_binding.skill_id IS 'Referenced Skill identifier';
COMMENT ON COLUMN agent_skill_binding.skill_version IS 'Pinned Skill version; NULL means resolve the latest version';
COMMENT ON COLUMN agent_skill_binding.sort_order IS 'Zero-based position used to reproduce the JSON array';

CREATE TABLE agent_tool_permission (
    agent_id          VARCHAR(64)  NOT NULL,
    tool_id           VARCHAR(128) NOT NULL,
    permission_effect VARCHAR(8)   NOT NULL,
    CONSTRAINT pk_agent_tool_permission PRIMARY KEY (agent_id, tool_id),
    CONSTRAINT ck_agent_tool_permission_id CHECK (tool_id <> ''),
    CONSTRAINT ck_agent_tool_permission_effect CHECK (
        permission_effect IN ('deny', 'ask', 'allow')
    )
);

COMMENT ON TABLE agent_tool_permission IS 'Flattened deny, ask, and allow Tool permission lists';
COMMENT ON COLUMN agent_tool_permission.agent_id IS 'Logical reference to agent_metadata.agent_id';
COMMENT ON COLUMN agent_tool_permission.tool_id IS 'Tool identifier governed by this Agent permission';
COMMENT ON COLUMN agent_tool_permission.permission_effect IS 'One of deny, ask, or allow';

CREATE INDEX idx_agent_metadata_display_name
    ON agent_metadata (display_name);

CREATE INDEX idx_agent_metadata_updated_at
    ON agent_metadata (updated_at DESC, agent_id);

CREATE INDEX idx_agent_model_model_id
    ON agent_model (model_id, agent_id);

CREATE INDEX idx_agent_tool_binding_tool_id
    ON agent_tool_binding (tool_id, agent_id);

CREATE INDEX idx_agent_skill_binding_skill_id
    ON agent_skill_binding (skill_id, agent_id);

CREATE INDEX idx_agent_tool_permission_effect
    ON agent_tool_permission (permission_effect, agent_id);

-- Optional for a verified GaussDB centralized deployment that supports foreign
-- keys. Do not enable this block on GaussDB Distributed.
--
-- ALTER TABLE agent_model
--     ADD CONSTRAINT fk_agent_model_agent
--     FOREIGN KEY (agent_id) REFERENCES agent_metadata (agent_id)
--     ON DELETE CASCADE;
-- ALTER TABLE agent_use_case
--     ADD CONSTRAINT fk_agent_use_case_agent
--     FOREIGN KEY (agent_id) REFERENCES agent_metadata (agent_id)
--     ON DELETE CASCADE;
-- ALTER TABLE agent_tool_binding
--     ADD CONSTRAINT fk_agent_tool_binding_agent
--     FOREIGN KEY (agent_id) REFERENCES agent_metadata (agent_id)
--     ON DELETE CASCADE;
-- ALTER TABLE agent_skill_binding
--     ADD CONSTRAINT fk_agent_skill_binding_agent
--     FOREIGN KEY (agent_id) REFERENCES agent_metadata (agent_id)
--     ON DELETE CASCADE;
-- ALTER TABLE agent_tool_permission
--     ADD CONSTRAINT fk_agent_tool_permission_agent
--     FOREIGN KEY (agent_id) REFERENCES agent_metadata (agent_id)
--     ON DELETE CASCADE;
