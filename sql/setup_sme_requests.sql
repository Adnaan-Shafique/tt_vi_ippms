-- ════════════════════════════════════════════════════════════════════════════
--  vi_sme_requests — SME access applications and grants
--
--  The application creates this table itself at startup (best-effort
--  CREATE TABLE IF NOT EXISTS, see SECTION 4B-4 of the chat app), so you do
--  NOT have to run this file. It is here for two reasons:
--
--    1. To review the shape before it appears in your database.
--    2. To create it up front in an environment where the app user is not
--       the schema owner and cannot create tables at runtime.
--
--  Run it as a role that can create tables in the target schema, then make
--  sure the application user can read and write it (see the GRANTs at the
--  bottom — no-ops when the app user already owns the schema).
--
--  Set the schema for the environment you are targeting:
--      test  ->  tt_vi_ippms_schema_test
--      prod  ->  tt_vi_ippms_schema
-- ════════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on
\set schema tt_vi_ippms_schema_test
\set app_user ig_app_user

SET search_path TO :schema;

-- ── The table ───────────────────────────────────────────────────────────────
--  One row per application. An approved row IS the grant: role resolution in
--  the app reads `WHERE status = 'approved'` and unions that with the SMEs
--  seeded in config/roles.yaml.
--
--  Rows are never deleted. Revoking flips status to 'revoked' rather than
--  removing the row, so "who had access in March, and who granted it?" stays
--  answerable. That audit trail is the whole reason grants live here and not
--  in the YAML file.

CREATE TABLE IF NOT EXISTS vi_sme_requests (
    id            BIGSERIAL PRIMARY KEY,
    email         TEXT        NOT NULL,
    requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    justification TEXT        NOT NULL,
    status        TEXT        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','approved','rejected','revoked')),
    decided_by    TEXT,           -- admin email; NULL while pending
    decided_at    TIMESTAMPTZ,    -- NULL while pending
    decision_note TEXT            -- shown to the applicant when rejected
);

-- ── Constraints that matter ─────────────────────────────────────────────────
--  Partial unique indexes, not application-side checks: two rapid clicks on
--  Submit are two concurrent transactions, and only the database can settle
--  that race. Verified with 8 concurrent inserts — 1 succeeds, 7 are rejected.
--
--  Both exclude 'rejected' and 'revoked' rows, which is exactly what allows
--  someone to reapply after being turned down.

-- At most one open application per person.
CREATE UNIQUE INDEX IF NOT EXISTS ux_vi_sme_requests_pending
    ON vi_sme_requests (lower(email)) WHERE status = 'pending';

-- At most one live grant per person.
CREATE UNIQUE INDEX IF NOT EXISTS ux_vi_sme_requests_granted
    ON vi_sme_requests (lower(email)) WHERE status = 'approved';

-- Drives the admin queue (newest first, filtered by status).
CREATE INDEX IF NOT EXISTS ix_vi_sme_requests_status
    ON vi_sme_requests (status, requested_at DESC);

-- ── Grants ──────────────────────────────────────────────────────────────────
--  No-ops if the application user already owns the schema.

GRANT SELECT, INSERT, UPDATE ON vi_sme_requests TO :app_user;
GRANT USAGE, SELECT ON SEQUENCE vi_sme_requests_id_seq TO :app_user;

-- ── Seeding an SME without the web UI ───────────────────────────────────────
--  Prefer config/roles.yaml for people who should always have access; use this
--  only to record a grant that was agreed out of band, so the audit trail
--  still shows who authorised it.
--
--  INSERT INTO vi_sme_requests (email, justification, status, decided_by, decided_at)
--  VALUES ('someone@vodafoneidea.com', 'Agreed in the 12 Sep planning call.',
--          'approved', 'mohammed.shafique@vodafoneidea.com', now());

-- ── Useful queries ──────────────────────────────────────────────────────────
--  Who currently has a runtime grant:
--    SELECT email, decided_by, decided_at FROM vi_sme_requests
--     WHERE status = 'approved' ORDER BY decided_at DESC;
--
--  Full history for one person:
--    SELECT status, requested_at, decided_by, decided_at, decision_note
--      FROM vi_sme_requests WHERE lower(email) = lower('someone@vodafoneidea.com')
--     ORDER BY requested_at;
