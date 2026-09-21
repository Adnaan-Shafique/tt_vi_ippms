# Changelog

Version-by-version history of **Talk-to-VI-IPPMS** (chat app) and the
**Instant Graph MCP server**.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
The two components version independently — each entry names which one changed.

> **History before this repo existed** was reconstructed from the version notes
> in the source-file headers, so dates for those releases are unknown and the
> lists may be incomplete. Everything from `6.7.2-r1` onward is tracked live.

---

## [Unreleased]

Nothing yet.

---

## [6.7.2-r1] — 2026-09-21 · repo bootstrap

First commit into version control. **No behavioural change** to the agent,
the UI, or the retrieval path.

### Added
- Git repository with `README.md`, this changelog, `.env.example`,
  `requirements.txt`, systemd units in `deploy/`, and the
  FALCONPRD → 10.19.75.115 runbook in `docs/`.
- `.gitignore` covering `.env`, `*.pem`, and the binary question guide.

### Security
- **Removed hardcoded secret fallbacks from source.** Both files carried a
  comment claiming no credential was hardcoded, while the fallback was still
  present in the very next line:
  - `GPU_API_KEY` default `"secret-falcon2"` → `""` (chat app)
  - `IG_DB_PASSWORD` default `"ig_app_user_Qwer!234"` → `""` (both files)

  Both must now come from the environment. **Rotate both credentials** — they
  existed in plaintext in the distributed source.

### Changed
- Sources moved to `src/`; on-disk assets expected in `assets/`. Filenames keep
  their version suffixes so existing run commands still work.

---

## [app 6.7] — Spike/dip anomaly detection

### Added
- **Anomaly-detection shape**: *"show me the spikes/dips for KPI X on interface
  Y on device Z in the last N minutes/hours or between A and B"*
  (aggregation `spikes` / `dips` / `anomalies`).
  - Each point is scored against a **local** baseline built from its own
    neighbours **excluding the point itself**. A plain centred rolling
    mean/std that *includes* the point lets a real spike drag its own baseline
    toward itself and dilute its z-score — caught via isolated simulation
    before shipping.
  - Flagged past `SPIKE_ZSCORE_THRESHOLD` σ (default 2.5), window
    `SPIKE_ROLLING_WINDOW` (5), minimum `SPIKE_MIN_POINTS` (5).
  - Requires exactly one named interface — spike detection needs a single
    series. A missing interface, device, or KPI returns a clarification.
  - Renders a flagged-events table (Interface/KPI/Type/Value/Time/Deviation),
    adds a `Flag` column to the raw time-series table, and overlays flagged
    points as distinct markers on the line chart
    (`build_timeseries_fig` gained a `markers` param).
- `parse_time_window` now understands an explicit **"between A and B"** range —
  bare times or full date-times — not just relative phrases. A pre-existing gap
  that this feature's own examples relied on.

---

## [app 6.6] — Interface ranking

### Added
- **Interface-ranking shape**: *"top/bottom N interfaces for KPI X on device Y
  currently"*.
  - The API has **no live-value endpoint**, so "currently" is approximated as
    the most recent (`Last`) point within `CURRENT_VALUE_LOOKBACK_SECONDS`
    (default 3h) rather than a historical Min/Max/Avg.
  - Narrowly gated on a `top_n`/`bottom_n` aggregation **+** the word
    "interface(s)" **+** no explicit time phrase, so the pre-existing
    "top N *devices* by KPI over a window" shape is untouched.
  - The KPI's owning component is auto-guessed from `KPI_SYNONYMS` when not
    named, self-healing via the existing zero-result recheck if wrong.
  - Renders an Interface/KPI/Value/Time table plus a horizontal bar chart
    (`build_rank_bar_chart`).

---

## [app 6.2] — UX and boundary hardening

### Added
- Per-table **"⬇ Download CSV"** button in a header bar above every result
  table, with row/column counts. The export is rebuilt from the message store,
  so it contains **all** rows, not just the visible page. Replaces the
  easy-to-miss CSV button that sat in the feedback row.
- Native **sort + filter** on result tables.
- **🧩 Parameters** disclosure panel next to the Debug trace on every answer,
  listing what was extracted from the question (circle, device, component,
  interface, KPI, target/metric/aggregation, top-N, threshold, time window) and
  what each resolved to against live data.

### Changed
- **Enter sends**; Shift+Enter inserts a newline. The textarea auto-grows and
  the hint under the input box says so.

### Fixed
- `'dict' object has no attribute 'split'`. Two boundaries could leak
  non-string values into code typed for `str` — the router LLM emitting a
  nested object/list for a scalar entity, and `ig_list_interfaces` items
  arriving object-shaped instead of as the documented `"Interface X ::"`
  strings. Both are now coerced at the boundary (`_as_text` / `_norm_items`),
  `_iface_display` no longer assumes `str`, `execute_query_spec` catches more
  than `MCPError`, and `run_agent`'s catch-all reports type/stage/frame plus a
  traceback in the Debug panel instead of a bare message.

---

## [app 6.0] — QuerySpec engine

The structural rewrite of the retrieval path.

### Added
- **A. QuerySpec engine** (`build_spec` + `execute_query_spec`) replacing the
  closed `deterministic_metadata` / `deterministic_kpi` if/elif branches.
  Resolves both answer *consistency* and question-shape *coverage*: one
  general deterministic executor, **no LLM in the retrieval path**, so the same
  question returns identical data every run.
- **B.** A full debug object surfaced behind a UI toggle on every path.
- **C.** Scope-aware handling distinguishing *unrelated* from *unsupported*.
- **D.** One consolidated tool KB + local TF-IDF retrieval over the question
  guide, replacing scattered docstrings and hardcoded tables.
- **E.** Persistent interaction + feedback logging to Postgres.
- Persisted sidebar chat history with 7-day retention and a background
  purge sweep.
- SME glossary of domain terms, writable only by `GLOSSARY_EDITORS`
  (enforced server-side on both the open and the submit path).

### Changed
- `SYNTHESIS_DECODE` temperature `0.3` → **`0.0`**. The QuerySpec engine makes
  the retrieved *data* deterministic; 0.0 makes the *phrasing* as stable as the
  local stack allows, and structured shapes are templated anyway.

### Security
- Removed the hardcoded GPU key.
- Removed the `AUTH` / `SESSION` / `QUICKQ` / `SUBMIT` debug log lines that
  leaked secrets, full session tokens, and stack traces.

---

## [mcp 2.5] — current

Version in this repo. Changes over 2.3 were not recorded in the file header;
the observable state includes the pinned-SAN TLS adapter
(`_PinnedSSLContextAdapter`, `IG_CERT_HOSTNAME`) for the gateway whose cert SAN
is a DNS name while the base URL is a raw IP, plus `IG_CA_BUNDLE` support.

> If you know what actually shipped in 2.4 / 2.5, please fill this in.

---

## [mcp 2.3]

### Added
- Richer tool docstrings + `Field` descriptions — example calls, success
  shapes, and the `" ::"` / mixed-unit format gotchas — so the chat app's
  `build_tool_context()` surfaces more to the agent.
- Server-side `ig_tool_call_audit` table plus a **non-blocking background
  writer**, so audit logging does not become a bottleneck under multi-device
  fan-out. A second, harder-to-bypass source of truth for tool usage that
  complements the chat app's own interaction logging.

### Security
- Removed the hardcoded DB password fallback.

---

## [mcp 2.2 and earlier]

Baseline: FastMCP server wrapping the seven Instant Graph REST endpoints
(`auth/login`, `get-hosts`, `get-components`, `prefix-filter`, `get-suffixes`,
`render-table`, `get-historical-data`) over streamable-HTTP, plus a Dash ops
console in the same process. `TokenManager` caches and proactively refreshes
tokens (`TOKEN_REFRESH_BUFFER_SECONDS`), runs a watchdog thread, forces one
re-login-and-retry on a 401, and persists to `ig_auth_sessions` so several
worker processes share auth state.

---

## Conventions for future entries

- Add to **[Unreleased]** as you work; cut it into a version on release.
- Tag releases `app-v6.8`, `mcp-v2.6`, … and keep the source filenames stable.
- Note **which component** changed, and always record *why* — the reasoning in
  the 6.7 and 6.6 entries (baseline self-contamination, no live-value endpoint)
  is the part that stops a future change from undoing a deliberate decision.
