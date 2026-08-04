-- SR-ATTACHMENT-001 v2.0.0
-- Target-only openGauss metadata ledger for CampusMate Attachment Service.
-- File bodies are stored only in private OBS under an Object Key exactly equal
-- to attachment_id. These tables never contain file bytes, credentials, URLs,
-- a separate object_key mapping column, ETags, or untrusted declared media types.
-- Public chat_id authorization and chat_id-to-session_id resolution happen in
-- Mate Chat Store before these tables are accessed. The mapping is not copied
-- here; t_attachment retains only the internal Runtime session_id binding.

CREATE TABLE t_attachment (
    attachment_id VARCHAR(35)    NOT NULL,
    session_id    VARCHAR(128)   NOT NULL,
    status        VARCHAR(16)    NOT NULL DEFAULT 'UPLOADING',
    created_at    TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at    TIMESTAMPTZ(3),

    CONSTRAINT pk_attachment PRIMARY KEY (attachment_id),
    CONSTRAINT ck_attachment_id CHECK (
        attachment_id ~ '^attachment_[0-9A-Za-z]{24}$'
    ),
    CONSTRAINT ck_attachment_session_id CHECK (
        session_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
    ),
    CONSTRAINT ck_attachment_status CHECK (
        status IN (
            'UPLOADING',
            'PROCESSING',
            'READY',
            'BLOCKED',
            'FAILED',
            'DELETING',
            'DELETED'
        )
    ),
    CONSTRAINT ck_attachment_deleted_at CHECK (
        (status = 'DELETED' AND deleted_at IS NOT NULL)
        OR (status <> 'DELETED' AND deleted_at IS NULL)
    ),
    CONSTRAINT ck_attachment_time_order CHECK (
        deleted_at IS NULL OR deleted_at >= created_at
    )
);

CREATE TABLE t_attachment_active_detail (
    attachment_id       VARCHAR(35)    NOT NULL,
    filename            VARCHAR(512)   NOT NULL,
    detected_media_type VARCHAR(127),
    expected_size_bytes BIGINT         NOT NULL,
    size_bytes          BIGINT,
    sha256              CHAR(64),
    referenced_at       TIMESTAMPTZ(3),
    expires_at          TIMESTAMPTZ(3),
    error_code          VARCHAR(64),
    attempt_count       INTEGER        NOT NULL DEFAULT 0,
    next_attempt_at     TIMESTAMPTZ(3),
    lease_owner         VARCHAR(128),
    lease_until         TIMESTAMPTZ(3),
    row_version         BIGINT         NOT NULL DEFAULT 0,

    CONSTRAINT pk_attachment_active_detail PRIMARY KEY (attachment_id),
    CONSTRAINT fk_attachment_active_detail_attachment FOREIGN KEY (attachment_id)
        REFERENCES t_attachment (attachment_id) ON DELETE RESTRICT,
    CONSTRAINT ck_attachment_active_filename CHECK (filename <> ''),
    CONSTRAINT ck_attachment_active_detected_media_type CHECK (
        detected_media_type IS NULL
        OR detected_media_type ~ '^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$'
    ),
    CONSTRAINT ck_attachment_active_expected_size CHECK (
        expected_size_bytes BETWEEN 1 AND 20971520
    ),
    CONSTRAINT ck_attachment_active_actual_size CHECK (
        size_bytes IS NULL OR size_bytes BETWEEN 1 AND 20971520
    ),
    CONSTRAINT ck_attachment_active_size_match CHECK (
        size_bytes IS NULL OR size_bytes = expected_size_bytes
    ),
    CONSTRAINT ck_attachment_active_sha256 CHECK (
        sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT ck_attachment_active_reference_lifecycle CHECK (
        (referenced_at IS NULL AND expires_at IS NOT NULL)
        OR (referenced_at IS NOT NULL AND expires_at IS NULL)
    ),
    CONSTRAINT ck_attachment_active_attempt_count CHECK (attempt_count >= 0),
    CONSTRAINT ck_attachment_active_lease_pair CHECK (
        (lease_owner IS NULL AND lease_until IS NULL)
        OR (lease_owner IS NOT NULL AND lease_until IS NOT NULL)
    ),
    CONSTRAINT ck_attachment_active_row_version CHECK (row_version >= 0),
    CONSTRAINT ck_attachment_active_error_code CHECK (
        error_code IS NULL OR error_code ~ '^[A-Z][A-Z0-9_]{0,63}$'
    )
);

COMMENT ON TABLE t_attachment IS
    'Permanent attachment identity and lifecycle status; DELETED rows remain as non-reusable ID tombstones';
COMMENT ON COLUMN t_attachment.attachment_id IS
    'Opaque case-sensitive public ID and exact private OBS Object Key; never reused';
COMMENT ON COLUMN t_attachment.session_id IS
    'Immutable globally unique Runtime Session binding using the CampusAgent SessionId grammar';
COMMENT ON COLUMN t_attachment.status IS
    'UPLOADING, PROCESSING, READY, BLOCKED, FAILED, DELETING, or DELETED';
COMMENT ON COLUMN t_attachment.created_at IS
    'Time at which the permanent identity row was created';
COMMENT ON COLUMN t_attachment.deleted_at IS
    'Time at which OBS deletion completed; required only for a DELETED tombstone';

COMMENT ON TABLE t_attachment_active_detail IS
    'One-to-one operational metadata for every non-DELETED identity, including upload, failure, reconciliation, and deletion states';
COMMENT ON COLUMN t_attachment_active_detail.attachment_id IS
    'Primary and foreign key joining the active detail to its permanent identity row';
COMMENT ON COLUMN t_attachment_active_detail.filename IS
    'Sanitized display name; never used to construct the OBS Object Key';
COMMENT ON COLUMN t_attachment_active_detail.detected_media_type IS
    'Trusted parameter-free lowercase MIME type produced by content sniffing and security processing';
COMMENT ON COLUMN t_attachment_active_detail.expected_size_bytes IS
    'Validated X-Attachment-Size used for admission and exact upload-length verification';
COMMENT ON COLUMN t_attachment_active_detail.size_bytes IS
    'Actual byte count observed while streaming and checked against the declared size';
COMMENT ON COLUMN t_attachment_active_detail.sha256 IS
    'Lowercase SHA-256 used to verify immutable content during scan, resolve, and Runtime reads';
COMMENT ON COLUMN t_attachment_active_detail.referenced_at IS
    'First successful Runtime resolve time; non-NULL means the attachment is referenced';
COMMENT ON COLUMN t_attachment_active_detail.expires_at IS
    'Cleanup deadline for an unreferenced attachment; becomes NULL on first reference';
COMMENT ON COLUMN t_attachment_active_detail.error_code IS
    'Bounded redacted stable failure code; never contains provider payloads or secrets';
COMMENT ON COLUMN t_attachment_active_detail.attempt_count IS
    'Attempt count for the current scan, delete, or reconciliation phase';
COMMENT ON COLUMN t_attachment_active_detail.next_attempt_at IS
    'Earliest time at which a worker may retry the current background phase';
COMMENT ON COLUMN t_attachment_active_detail.lease_owner IS
    'Ephemeral worker identity; ownership is valid only until lease_until';
COMMENT ON COLUMN t_attachment_active_detail.lease_until IS
    'Lease expiry after which another Pod may recover the task';
COMMENT ON COLUMN t_attachment_active_detail.row_version IS
    'Optimistic-lock value incremented by every conditional operational update';

CREATE INDEX idx_attachment_session_status
    ON t_attachment (session_id, status);

CREATE INDEX idx_attachment_status
    ON t_attachment (status);

CREATE INDEX idx_attachment_deleted_at
    ON t_attachment (deleted_at);

CREATE INDEX idx_attachment_active_next_attempt
    ON t_attachment_active_detail (next_attempt_at);

CREATE INDEX idx_attachment_active_expires
    ON t_attachment_active_detail (expires_at);

-- Application transaction rules that cannot be expressed as single-row CHECKs:
-- 1. Insert t_attachment and t_attachment_active_detail in one transaction. Every
--    non-DELETED identity has exactly one detail row; a DELETED identity has none.
-- 2. session_id, attachment_id, expected_size_bytes, and file identity are immutable.
--    The exact OBS Object Key is attachment_id and is therefore not stored in a column.
-- 3. READY requires detected_media_type, size_bytes, and sha256 to be non-NULL.
-- 4. Resolve locks requested IDs in stable order and atomically sets
--    referenced_at = COALESCE(referenced_at, now()) and expires_at = NULL.
--    A non-NULL referenced_at is one-way and there is no release operation.
-- 5. State transitions lock t_attachment first and its detail second, then use
--    WHERE attachment_id = ? AND row_version = ? for the operational update.
-- 6. Workers claim a short lease in a database transaction, commit, and only
--    then perform OBS I/O or security scanning without holding a DB transaction.
-- 7. When work moves to a new phase, reset attempt_count, next_attempt_at,
--    lease_owner, lease_until, and error_code for that phase as appropriate.
-- 8. After OBS DELETE succeeds or returns NotFound, one transaction deletes the
--    detail row and changes t_attachment to DELETED with deleted_at = now().
-- 9. DELETED identity rows are permanent tombstones and are never removed.
-- 10. Creation sets expires_at to created_at + 24 hours. Normal scanning permits
--     PROCESSING -> READY, BLOCKED, or FAILED. Only an audited privileged path
--     may perform READY -> BLOCKED.
-- 11. The deployment must use UTF-8 and case-sensitive identifier comparison;
--     verify this behavior with the production openGauss JDBC driver.
-- 12. Public delete, 24-hour cleanup, Session delete, and ordinary worker claims
--     must exclude status = FAILED with error_code = OBJECT_KEY_CONFLICT. Only
--     audited reconciliation may move that row to DELETING after proving object
--     ownership, or finish DELETED after OBS reports NotFound.
