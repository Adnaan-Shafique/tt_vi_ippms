-- ════════════════════════════════════════════════════════════════════════════
--  ig_auth_sessions + ig_auth_login_audit
--
--  These two tables are the ONLY ones the application does not create for
--  itself — every other table is created best-effort with CREATE TABLE IF NOT
--  EXISTS at startup. They must pre-exist or login fails.
--
--  ⚠ RECONSTRUCTED from the INSERT/SELECT statements in
--    instant_graph_mcp_server_v2_5.py (TokenManager._load_from_db,
--    _save_to_db, _clear_db, _audit_login). Column names and types are
--    derived from actual usage and are correct for the code as written, but
--    diff this against your original setup_ig_auth_tables.sql from FALCONPRD
--    before trusting it for production.
--
--  Usage — stand up a new schema (e.g. the test environment):
--    psql -h 127.0.0.1 -U ig_app_user -d conv_ai_db \
--         -v schema=tt_vi_ippms_schema_test -f sql/setup_ig_auth_tables.sql
-- ════════════════════════════════════════════════════════════════════════════

\set schema :schema
\if :{?schema}
\else
  \set schema tt_vi_ippms_schema
\endif

CREATE SCHEMA IF NOT EXISTS :"schema";

-- ── Persisted Instant Graph tokens (shared across worker processes) ─────────
CREATE TABLE IF NOT EXISTS :"schema".ig_auth_sessions (
    session_key    TEXT PRIMARY KEY,      -- ON CONFLICT (session_key) requires this
    email          TEXT,
    eid            TEXT,
    access_token   TEXT,
    ig_session_id  TEXT,
    expires_at     TIMESTAMPTZ,           -- read back tz-aware; must NOT be plain TIMESTAMP
    last_login_at  TIMESTAMPTZ DEFAULT now()
);

-- ── Login attempt audit ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS :"schema".ig_auth_login_audit (
    id             BIGSERIAL PRIMARY KEY,
    session_key    TEXT,
    email          TEXT,
    eid            TEXT,
    success        BOOLEAN,
    error_message  TEXT,
    source_host    TEXT,                  -- "<hostname>:<pid>" of the writer
    created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ig_auth_login_audit_created_idx
    ON :"schema".ig_auth_login_audit (created_at DESC);

-- ── Grants ──────────────────────────────────────────────────────────────────
GRANT USAGE ON SCHEMA :"schema" TO ig_app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA :"schema" TO ig_app_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :"schema" TO ig_app_user;

-- The app auto-creates its remaining tables at startup, so grant on future
-- objects too or those CREATEs succeed while later writes fail.
ALTER DEFAULT PRIVILEGES IN SCHEMA :"schema"
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ig_app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA :"schema"
    GRANT USAGE, SELECT ON SEQUENCES TO ig_app_user;
