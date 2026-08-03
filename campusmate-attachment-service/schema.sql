-- SR-ATTACHMENT-001 v1.0.0
-- Target-only openGauss metadata ledger for CampusMate Attachment Service.
-- File bodies are stored only in private OBS. This table must never contain
-- binary large-object columns, encoded file content, credentials, or URLs.

CREATE TABLE attachment (
    attachment_id          VARCHAR(35)    NOT NULL,
    session_id             VARCHAR(128)   NOT NULL,
    object_key             VARCHAR(512)   NOT NULL,
    status                 VARCHAR(16)    NOT NULL,
    filename               VARCHAR(512)   NOT NULL,
    declared_media_type    VARCHAR(127),
    detected_media_type    VARCHAR(127),
    expected_size_bytes    BIGINT         NOT NULL,
    size_bytes             BIGINT,
    sha256                 CHAR(64),
    obs_etag               VARCHAR(128),
    referenced             BOOLEAN        NOT NULL DEFAULT FALSE,
    referenced_at          TIMESTAMPTZ(3),
    expires_at             TIMESTAMPTZ(3),
    attempt_count          INTEGER        NOT NULL DEFAULT 0,
    next_attempt_at        TIMESTAMPTZ(3),
    lease_owner            VARCHAR(128),
    lease_until            TIMESTAMPTZ(3),
    row_version            BIGINT         NOT NULL DEFAULT 0,
    error_code             VARCHAR(64),
    created_at             TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at             TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ready_at               TIMESTAMPTZ(3),
    deleted_at             TIMESTAMPTZ(3),

    CONSTRAINT pk_attachment PRIMARY KEY (attachment_id),
    CONSTRAINT uk_attachment_object_key UNIQUE (object_key),

    CONSTRAINT ck_attachment_id CHECK (
        attachment_id ~ '^attachment_[0-9A-Za-z]{24}$'
    ),
    CONSTRAINT ck_attachment_session_id CHECK (
        session_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
    ),
    CONSTRAINT ck_attachment_object_key CHECK (object_key <> ''),
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
    CONSTRAINT ck_attachment_filename CHECK (filename <> ''),
    CONSTRAINT ck_attachment_expected_size CHECK (
        expected_size_bytes BETWEEN 1 AND 20971520
    ),
    CONSTRAINT ck_attachment_actual_size CHECK (
        size_bytes IS NULL OR size_bytes BETWEEN 1 AND 20971520
    ),
    CONSTRAINT ck_attachment_size_match CHECK (
        size_bytes IS NULL OR size_bytes = expected_size_bytes
    ),
    CONSTRAINT ck_attachment_sha256 CHECK (
        sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT ck_attachment_declared_media_type CHECK (
        declared_media_type IS NULL
        OR declared_media_type ~ '^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$'
    ),
    CONSTRAINT ck_attachment_detected_media_type CHECK (
        detected_media_type IS NULL
        OR detected_media_type ~ '^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$'
    ),
    CONSTRAINT ck_attachment_referenced_at CHECK (
        (referenced = FALSE AND referenced_at IS NULL)
        OR (referenced = TRUE AND referenced_at IS NOT NULL)
    ),
    CONSTRAINT ck_attachment_reference_expiry CHECK (
        referenced = FALSE OR expires_at IS NULL
    ),
    CONSTRAINT ck_attachment_attempt_count CHECK (attempt_count >= 0),
    CONSTRAINT ck_attachment_lease_pair CHECK (
        (lease_owner IS NULL AND lease_until IS NULL)
        OR (lease_owner IS NOT NULL AND lease_until IS NOT NULL)
    ),
    CONSTRAINT ck_attachment_row_version CHECK (row_version >= 0),
    CONSTRAINT ck_attachment_error_code CHECK (
        error_code IS NULL OR error_code ~ '^[A-Z][A-Z0-9_]{0,63}$'
    ),
    CONSTRAINT ck_attachment_ready_fields CHECK (
        status <> 'READY'
        OR (
            size_bytes IS NOT NULL
            AND sha256 IS NOT NULL
            AND obs_etag IS NOT NULL
            AND detected_media_type IS NOT NULL
            AND ready_at IS NOT NULL
        )
    ),
    CONSTRAINT ck_attachment_deleted_at CHECK (
        (status = 'DELETED' AND deleted_at IS NOT NULL)
        OR (status <> 'DELETED' AND deleted_at IS NULL)
    )
);

COMMENT ON TABLE attachment IS
    'CampusMate attachment metadata ledger; original file bytes are stored only in private OBS';
COMMENT ON COLUMN attachment.attachment_id IS
    'Opaque case-sensitive public ID; attachment_ plus 24 alphanumeric characters; never reused';
COMMENT ON COLUMN attachment.session_id IS
    'Immutable globally unique Runtime Session binding using the CampusAgent SessionId grammar';
COMMENT ON COLUMN attachment.object_key IS
    'Internal random OBS object locator; never exposed to clients, Runtime, prompts, or business logs';
COMMENT ON COLUMN attachment.status IS
    'UPLOADING, PROCESSING, READY, BLOCKED, FAILED, DELETING, or DELETED';
COMMENT ON COLUMN attachment.filename IS
    'Sanitized display name; never used to construct the OBS object key';
COMMENT ON COLUMN attachment.declared_media_type IS
    'Untrusted multipart media type parsed without parameters and normalized to lowercase for audit only';
COMMENT ON COLUMN attachment.detected_media_type IS
    'Trusted parameter-free lowercase media type produced by content sniffing and security processing';
COMMENT ON COLUMN attachment.expected_size_bytes IS
    'Validated X-Attachment-Size value, from 1 through 20 MiB';
COMMENT ON COLUMN attachment.size_bytes IS
    'Actual byte count observed while streaming to OBS';
COMMENT ON COLUMN attachment.sha256 IS
    'Lowercase SHA-256 of the immutable original file bytes';
COMMENT ON COLUMN attachment.obs_etag IS
    'OBS object identifier for diagnostics and conditional operations; not a content digest';
COMMENT ON COLUMN attachment.referenced IS
    'Whether agent-service atomically accepted this attachment into Session message history';
COMMENT ON COLUMN attachment.referenced_at IS
    'First successful Runtime resolve time';
COMMENT ON COLUMN attachment.expires_at IS
    'Cleanup deadline for an unreferenced attachment; set to NULL when referenced becomes true';
COMMENT ON COLUMN attachment.attempt_count IS
    'Number of scan, delete, or reconciliation attempts';
COMMENT ON COLUMN attachment.next_attempt_at IS
    'Earliest time at which a worker may retry the current background operation';
COMMENT ON COLUMN attachment.lease_owner IS
    'Ephemeral worker identity; ownership is valid only until lease_until';
COMMENT ON COLUMN attachment.lease_until IS
    'Lease expiry that permits another Pod to recover the task';
COMMENT ON COLUMN attachment.row_version IS
    'Optimistic-lock value incremented by every conditional state update';
COMMENT ON COLUMN attachment.error_code IS
    'Bounded redacted stable error code; never stores provider response bodies or secrets';
COMMENT ON COLUMN attachment.ready_at IS
    'Time at which integrity and security processing reached READY';
COMMENT ON COLUMN attachment.deleted_at IS
    'Time at which OBS deletion completed; the row remains as a permanent ID tombstone';

CREATE INDEX idx_attachment_session_status
    ON attachment (session_id, status);

CREATE INDEX idx_attachment_status_next_attempt
    ON attachment (status, next_attempt_at);

CREATE INDEX idx_attachment_referenced_expires
    ON attachment (referenced, expires_at);

-- Application transaction rules that cannot be expressed as row CHECKs:
-- 1. session_id, object_key, expected_size_bytes, and file identity are immutable.
-- 2. READY content can never be overwritten or rebound to another attachment_id.
-- 3. Resolve locks all requested rows in stable attachment_id order, validates
--    the complete batch, and atomically sets referenced = TRUE,
--    referenced_at = COALESCE(referenced_at, now()), and expires_at = NULL.
--    referenced is one-way and must never transition from TRUE to FALSE.
-- 4. State updates use WHERE attachment_id = ? AND row_version = ?.
-- 5. Workers claim a short lease in a database transaction, commit, and only
--    then perform OBS I/O or security scanning without holding a DB transaction.
-- 6. DELETED rows are permanent tombstones and are never physically removed.
-- 7. The deployment must use UTF-8 and case-sensitive identifier comparison;
--    verify this behavior with the production openGauss JDBC driver.
-- 8. Creation sets expires_at to created_at + 24 hours while unreferenced;
--    every conditional state update also advances updated_at.
-- 9. Normal scanning permits PROCESSING -> READY, BLOCKED, or FAILED. Only an
--    audited privileged security-revocation path may perform READY -> BLOCKED;
--    after revocation, new resolve/content operations must fail immediately.
