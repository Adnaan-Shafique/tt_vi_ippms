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

Nothing yet.

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
- Templated systemd units `instant-graph-mcp@.service` and
  `talk-to-vi-ippms@.service`, instantiated per environment (`@prod`, `@test`).
  Replaces running the scripts under `nohup`.
- `docs/ENVIRONMENTS.md` — the prod/test layout and the promotion workflow.
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
- The MCP endpoint now binds `127.0.0.1` by default rather than `0.0.0.0`. It
  exposes the whole Instant Graph tool surface unauthenticated and only ever
  needs to be reachable by the co-located chat app.

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
