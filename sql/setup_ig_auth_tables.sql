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
--  ⚠ TWO STEPS — the schema itself needs a PRIVILEGED role.
--
--  The application user deliberately has no CREATE on the database, so it
--  cannot create a schema. Postgres also checks that privilege BEFORE it
--  checks existence, so `CREATE SCHEMA IF NOT EXISTS` still fails with
--  "permission denied for database" rather than quietly doing nothing.
--
--  1. As an admin/superuser, once per environment:
--
--       psql -h <db-host> -U <admin> -d conv_ai_db -c \
--         'CREATE SCHEMA IF NOT EXISTS tt_vi_ippms_schema_test AUTHORIZATION ig_app_user;'
--
--     AUTHORIZATION makes the app user the schema owner, so everything
--     below — and the app's own CREATE TABLE IF NOT EXISTS at first
--     startup — works without needing the admin again. (FALCONPRD's prod
--     schema is instead owned by `postgres` with ig_app_user granted UC;
--     either arrangement works, so match whichever your site uses.)
--
--  2. As ig_app_user, this file:
--
--       psql -h <db-host> -U ig_app_user -d conv_ai_db \
--            -v schema=tt_vi_ippms_schema_test -f sql/setup_ig_auth_tables.sql
-- ════════════════════════════════════════════════════════════════════════════

\set schema :schema
\if :{?schema}
\else
  \set schema tt_vi_ippms_schema
\endif

-- The schema is created by the admin step above, NOT here: this file is meant
-- to run as the unprivileged application user.

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
