# Changelog

History of **Talk-to-VI-IPPMS** — the chat application and the Instant Graph
MCP server, which are released together from this repository.

Format follows [Keep a Changelog](https://keepachangelog.com/);
versioning follows [Semantic Versioning](https://semver.org/).

## Versioning

**Version history starts fresh at `v1.0.0`.** The pre-repository version
numbers (chat app `6.7.2`, MCP server `2.5`) were tracked only in file-header
comments, were not reliably recorded, and diverged between the two components.
They are retired.

From `v1.0.0` onward there is **one version number for the whole repository**,
carried by a git tag. Both components ship at the same version, because they
are deployed together and the chat app is an MCP client of the server — a
version pair is a lie waiting to happen.

- **MAJOR** — breaking config/schema change, or a migration step is required
- **MINOR** — new analytical shape, new tool, new UI capability
- **PATCH** — bug fix, doc change, dependency bump

Tag a release, run it in **test**, then `deploy/promote.sh <tag>` to prod.
The tag is what gets deployed — see `docs/ENVIRONMENTS.md`.

---

## [Unreleased]

Work towards **roles, an SME approval workflow and an admin analytics
dashboard**. Being built and tested on the `test` environment only; prod on
`:8079` is untouched.

### Added
- `config/roles.yaml` — admins and seed SMEs. Three roles now exist: `admin`
  (glossary + approvals + dashboard), `sme` (glossary), `user` (default).
  Admins are listed **only** in this file and cannot be granted through the
  web UI: if they could, compromising one admin account would be enough to
  make the compromise permanent.
- `config/content.yaml` — user-facing copy that changes for wording reasons
  rather than code reasons: welcome screen, capability cards, starter chips,
  help text, and the SME-application wording.
- `src/ippms_config.py` — loads and validates both files. A malformed edit
  keeps the previously loaded config in force and logs the reason, so a typo
  cannot take the assistant down or silently revoke everyone's access. Every
  content key is optional and falls back to a built-in default.
- Config is read per call rather than captured into module constants at
  import, so an edit applies on reload without restarting the service.

### Changed
- The hardcoded `GLOSSARY_EDITORS` set is gone; `can_edit_glossary()` now
  resolves through `role_for()`. **No one lost access** — the nine addresses in
  that set are the six admins plus three seed SMEs in `roles.yaml`.
- `HELP_TEXT` and `QUICK_QS` constants became the `help_text()` and
  `quick_questions()` accessors; `welcome()` and the topbar brand read from
  config. No wording changed.

### Added — SME access requests
- `vi_sme_requests` table: a normal user applies with a justification, an admin
  approves, rejects or later revokes. An approved row **is** the grant, so
  `role_for()` reads it alongside `roles.yaml`. Created best-effort at startup
  like the other tables; `sql/setup_sme_requests.sql` is there for environments
  where the app user cannot create tables.
- Rows are never deleted — revoking flips the status — so "who had access in
  March, and who granted it?" stays answerable.
- Two partial unique indexes enforce one open application and one live grant
  per person, in the database rather than in Python: two rapid clicks on Submit
  are two concurrent transactions and only Postgres can settle that race.
  Verified with 8 concurrent inserts (1 accepted, 7 rejected). Both indexes
  exclude rejected and revoked rows, which is what lets someone reapply.
- Sidebar now shows "Apply for SME access" to normal users, disabled while an
  application is pending. A rejected applicant sees the admin's note, so they
  do not reapply with the same justification.
- Admin panel (🛡️ in the sidebar): the pending queue with per-row approve and
  reject, live grants with revoke, the roles.yaml roster, and a **Reload
  config** button that re-reads both YAML files without restarting the service.
- Grant lookups are cached for 30s, invalidated immediately on any decision, so
  a newly approved SME sees the glossary button on their next page load.

### Added — admin dashboard
- Two more tabs on the admin panel: **Usage** and **Painpoints**, over a
  7/30/90-day or all-time window, with CSV export per table.
- Usage: headline stat tiles (questions, people, downvote rate, fallback rate,
  empty-answer rate, p95 latency), questions per day, how they were answered,
  most-asked questions and who is using it.
- Painpoints, worst-signal first: downvoted answers with the user's free text,
  questions that fell back to the ReAct loop, empty or incomplete answers,
  slowest questions, failing MCP tool calls, and errored answers.
- `notice` column added to `vi_chat_interactions`. The value ('empty' /
  'incomplete') was already computed for the UI's helper chips but never
  persisted, which left two painpoint views unanswerable. Added with
  `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, which does not rewrite the table.
- Nothing else new is instrumented: every other number comes from data the app
  already wrote. If a metric is missing it is because it was never recorded.

### Notes — dashboard design
- No categorical palette is used. The app's existing `PAL` fails colourblind
  separation against this surface (`#38bdf8`↔`#a78bfa` ΔE 5.2 deutan, and
  `#34d399`↔`#22d3ee` ΔE 12.1 even with normal vision), so the dashboard was
  designed not to need one: headline numbers are stat tiles, volume is a single
  line, and `answered_via` is a one-hue bar where length alone carries the
  message. `PAL` itself is untouched — the KPI charts users rely on are out of
  scope here, but it is worth re-stepping before any new multi-series chart.
- Painpoint tables show 12 rows with an honest "showing 12 of 26" count; the
  CSV exports the whole window. Six sections at sixty rows each made the tab
  ten thousand pixels tall, which is a log file, not a dashboard.

### Added — glossary now changes answers
- Glossary terms are matched against each question and their definitions are
  injected into the router and synthesis prompts. The capture half has existed
  since before this repo; this is the half that makes an SME's contribution
  actually affect an answer.
- **The question text is never rewritten.** Substituting `GJW` with
  `Gujarat West` before parsing would corrupt the identifiers the executor
  matches on — `APVSPGJWPAR01HNE40` contains `GJW`, and "matching PAR01" is a
  plausible glossary term. Definitions ride alongside the original question.
- Matching is word-boundary anchored, so an entry cannot fire on a substring of
  a hostname; verified that `GJW` matches "devices in GJW" and does not match
  "components on APVSPGJWPAR01HNE40".
- A shorter term nested inside a longer match is suppressed, so a question
  about `HC In Octets` is not also handed a generic `octets` definition.
- Injection is capped at 6 definitions per question: the glossary is unbounded
  and the local model's context is not, so a question that happens to contain
  many known terms must not crowd out the retrieved data.
- Matched once per run and reused by every node, so the router and the
  synthesiser cannot see different definitions if an SME saves mid-run.
- Saving a term drops the read cache, so an SME can add a definition and
  immediately ask the question it applies to.

### Changed — determinism
- Identical questions can now legitimately differ over time, because the
  glossary changed in between. This is the point of the feature, but it is
  recorded rather than left mysterious: `glossary_version` and `glossary_terms`
  columns on `vi_chat_interactions` make "why did this answer change?" a query.
  Questions with no glossary match store NULL and `[]`.

### Fixed
- The 🛡️ Admin button did nothing. Open and Close were one callback with two
  Inputs, and Dash will not fire a callback whose plain-id Input is absent from
  the current layout — `admin-close-btn` only exists once the panel is
  rendered, so the callback could never fire: the panel could not open because
  Close did not exist, and Close could not exist until the panel opened. Split
  into separate open and close callbacks. Confirmed with a minimal Dash app:
  combined never fires, split works.

### Security
- Every admin and glossary callback re-checks the role server-side against the
  session. Hiding a button is presentation; the callbacks are reachable by
  hand. `decide_sme_request()` re-asserts admin even though its callers already
  check, because it is the function that actually changes who can write.
- A database outage degrades runtime grants to "not currently SME" and is
  logged; admins and seed SMEs come from YAML and are never affected.
- CSV export re-checks admin and maps the button to a fixed set of queries
  rather than dispatching on the component id — a download of the full question
  history is exactly what should not be reachable by guessing an id.

### Notes
- `CIRCLE_TOKENS` and `KPI_SYNONYMS` were deliberately **not** moved to YAML.
  They look like configuration but are matching logic the executor runs
  against — editing them changes which devices an answer covers, so they stay
  in code where they get reviewed as code.
- New dependency: **PyYAML**.

---

## [1.0.0] — 2026-09-21

**Baseline release.** The first version under source control, and the version
migrated from FALCONPRD (`10.19.71.246`) to `10.19.75.115`.

Functionally this is the code that was running in production as chat app
`6.7.2` + MCP server `2.5`, with no behavioural change to the agent, the
retrieval path, or the UI. Everything below is packaging, deployment and
security work around that unchanged core.

### Added — repository
- `README.md` — architecture, the LangGraph/QuerySpec answer path, the MCP
  tool surface, auth model, and the Postgres schema.
- `.env.example` — every environment variable both processes read, in one
  place, annotated.
- `requirements.txt`, `.gitignore`.

### Added — deployment
- Templated systemd units `ippms-mcp@.service` and `ippms-app@.service`,
  derived from the existing FALCONPRD units and instantiated per environment
  (`@prod`, `@test`). Keeps their `StartLimitIntervalSec=0` (systemd's default
  rate limit is the usual reason a service that should self-heal is found dead
  the next morning), `Restart=always`, and `Wants=` rather than `Requires=` on
  the MCP dependency so the chat UI stays up when the MCP server is down.
- Secrets moved to `/etc/ippms-assistant/ippms-<env>.env`, outside the
  deployment directory, so a redeploy, rsync or `git clean` cannot touch them.
- `docs/ENVIRONMENTS.md` — the prod/test layout and the promotion workflow.
- `docs/STAGING_ON_FALCONPRD.md` — standing the repo up as the `test`
  instance beside the existing live deployment on FALCONPRD, which validates
  the units and env layout on a host where the networking already works.
- `deploy/promote.sh` — deploys an existing, tested git tag to prod and
  restarts it in dependency order, with automatic rollback if either service
  fails to come up.
- `deploy/preflight.sh` — read-only verification of every external dependency
  (secrets, assets, Postgres, gateway relay, GPU proxy, ports). Written
  because three of those dependencies fail *silently* at runtime.

### Added — network relay
`10.19.75.115` has no route to the Instant Graph gateway (`10.34.64.74:5001`)
and has no GPU, so both must be reached through FALCONPRD:
- `deploy/relay/squid-ig-relay.conf` — a CONNECT-only forward proxy for the
  gateway. Squid never decrypts: TLS stays end-to-end, so the self-signed
  cert, `IG_CA_BUNDLE` trust and `IG_CERT_HOSTNAME` SAN pinning all keep
  working with **no code change**. This works only because
  `_PinnedSSLContextAdapter` overrides `proxy_manager_for` as well as
  `init_poolmanager` — had it overridden only the latter, the pinned SSL
  context would have been silently dropped on proxied connections.
- `deploy/relay/autossh-ig-tunnel.service` — port-forward fallback.

### Added — database
- `sql/setup_ig_auth_tables.sql` — DDL for `ig_auth_sessions` and
  `ig_auth_login_audit`, the only two tables the application does **not**
  create for itself. Needed to stand up the test schema. Reconstructed from
  the queries in `TokenManager`; diff against the FALCONPRD original.

### Security
- **Removed hardcoded secret fallbacks from source.** Both files carried a
  comment claiming no credential was hardcoded while the fallback sat on the
  very next line:
  - `GPU_API_KEY` — hardcoded default removed, now `""`
  - `IG_DB_PASSWORD` — hardcoded default removed, now `""`

  (The removed values are deliberately not reproduced here — writing them
  into the changelog would put them straight back into the repository.)

  Both now come from the environment only. **Rotate both credentials** — they
  existed in plaintext in the distributed source.
- `MCP_HOST` and `DASH_HOST` now default to `127.0.0.1` rather than
  `0.0.0.0`, matching the FALCONPRD deployment. The MCP endpoint is an
  unauthenticated tool surface and the ops console is an admin surface;
  neither belongs on a public interface. Only the chat UI is published.

### Migration notes
- The application moved hosts; **Postgres did not**. `10.19.75.115` was
  already the database host, so the DB connection became a loopback
  connection and no data was migrated. Chat history and audit rows carried
  over untouched.
- Test and prod use **separate schemas** (`tt_vi_ippms_schema` /
  `tt_vi_ippms_schema_test`) so test traffic never pollutes production chat
  logs, feedback, or tool-call audit.

---

## Appendix — pre-`1.0.0` history

Retained from the source-file headers for reference only. Dates unknown,
lists likely incomplete, and these version numbers are **retired** — nothing
below corresponds to a git tag.

<details>
<summary>chat app 6.7 — spike/dip anomaly detection</summary>

- Anomaly shape: *"show me the spikes/dips for KPI X on interface Y on device
  Z…"* (aggregation `spikes`/`dips`/`anomalies`). Each point is scored against
  a local baseline built from its neighbours **excluding itself** — a centred
  rolling mean/std that *includes* the point lets a real spike drag its own
  baseline toward itself and dilute its z-score, caught via isolated
  simulation before shipping. Flagged past 2.5σ. Requires exactly one named
  interface.
- `parse_time_window` learned explicit **"between A and B"** ranges.
</details>

<details>
<summary>chat app 6.6 — interface ranking</summary>

- *"Top/bottom N interfaces for KPI X on device Y currently"*. The API has no
  live-value endpoint, so "currently" is the most recent point within a 3h
  lookback, not a Min/Max/Avg. Narrowly gated so the pre-existing top-N
  *devices* shape is untouched. Adds `build_rank_bar_chart`.
</details>

<details>
<summary>chat app 6.2 — UX and boundary hardening</summary>

- Per-table CSV download rebuilt from the message store (all rows, not just
  the visible page); native sort/filter; 🧩 Parameters panel; Enter-to-send.
- Fixed `'dict' object has no attribute 'split'` — the router LLM emitting a
  nested object for a scalar entity, and `ig_list_interfaces` returning
  object-shaped items. Both coerced at the boundary.
</details>

<details>
<summary>chat app 6.0 — QuerySpec engine</summary>

- `build_spec` + `execute_query_spec` replaced the closed
  `deterministic_metadata`/`deterministic_kpi` branches: one general
  deterministic executor with **no LLM in the retrieval path**.
- Debug object on every path; scope gate separating *unrelated* from
  *unsupported*; consolidated tool KB + local TF-IDF RAG; Postgres interaction
  and feedback logging; persisted chat history; SME glossary.
- Synthesis temperature 0.3 → 0.0.
- Removed the hardcoded GPU key and the log lines leaking tokens and stack
  traces.
</details>

<details>
<summary>MCP server 2.3</summary>

- Richer tool docstrings and `Field` descriptions so `build_tool_context()`
  surfaces more to the agent.
- `ig_tool_call_audit` table with a non-blocking background writer, so audit
  logging is not a bottleneck under multi-device fan-out.
</details>

<details>
<summary>MCP server 2.2 and earlier</summary>

- FastMCP server over the seven Instant Graph REST endpoints, plus a Dash ops
  console in-process. `TokenManager` caches and proactively refreshes tokens,
  runs a watchdog, forces one re-login-and-retry on 401, and persists to
  `ig_auth_sessions` so worker processes share auth state.
</details>

> MCP server **2.4 / 2.5** were never documented and their contents are
> unknown. The observable state at baseline includes the pinned-SAN TLS
> adapter and `IG_CA_BUNDLE` support. Folded into `1.0.0`.
