# Talk-to-VI-IPPMS

Conversational analytics over the **Instant Graph** network-monitoring APIs.

Ask, in plain English, questions about VI-IPPMS metadata and KPIs:

> *"How many devices are in the GUJ circle?"*
> *"On APVSPGJWPAR01HNE40, interface 100GE0/3/2, what was HC In Octets between 8am and 2pm yesterday?"*
> *"Top 5 interfaces by traffic on that device right now."*
> *"Show me the spikes for HC In Octets on Eth-Trunk1 in the last 6 hours."*

There is **no SQL data warehouse**. Every fact comes from the Instant Graph REST
APIs, reached as MCP tools. All reasoning runs on a **local, airgapped** model
(mistral-7b via an on-prem GPU inference proxy) — no request leaves the network.

---

## Architecture

```
                 ┌────────────────────────────────────────────┐
  browser  ──►   │  talk_to_vi_ippms_updated_6_7_2.py  :8079  │   chat UI (Dash)
                 │  ├─ LangGraph pipeline                     │
                 │  │   router → resolve → spec → execute      │
                 │  │            → synthesize                  │
                 │  └─ MCP *client* (streamable-HTTP)          │
                 └───────┬──────────────────────┬─────────────┘
                         │                      │
              GPU proxy  │ :8071                │ :8056/mcp
       (mistral-7b, local)                      ▼
                                 ┌──────────────────────────────────┐
                                 │ instant_graph_mcp_server_v2_5.py │
                                 │  ├─ FastMCP server       :8056   │  8 ig_* tools
                                 │  └─ ops console (Dash)   :8060   │
                                 └───────┬──────────────────────────┘
                                         │ HTTPS (+ pinned SAN)
                                         ▼
                            Instant Graph REST  https://10.34.64.74:5001
                                         
                 both processes ──► Postgres 10.19.75.115 : conv_ai_db
                                    schema tt_vi_ippms_schema
```

### The two processes

| File | Listens on | Role |
|---|---|---|
| `src/instant_graph_mcp_server_v2_5.py` | `:8056/mcp` (MCP) + `:8060` (ops console) | Wraps 7 Instant Graph REST endpoints as MCP tools; manages per-user tokens; audits every tool call |
| `src/talk_to_vi_ippms_updated_6_7_2.py` | `:8079` | Chat UI + LangGraph agent. An MCP **client** of the above |

The MCP server **must be running first** — the chat app pre-lists its tools at
startup and degrades without them.

### MCP tools exposed

`ig_login` · `ig_token_status` · `ig_list_hosts` · `ig_list_components` ·
`ig_list_interfaces` · `ig_list_kpis` · `ig_resolve_items` · `ig_get_kpi_history`

`ig_login` / `ig_token_status` are hidden from the LLM; the executor injects the
per-user `session_key` on every dispatch so tokens stay isolated across users.

---

## How a question is answered

The design goal is **determinism**: the same question returns identical data
every run. The LLM is used only at the two ends — turning free text into
entities, and phrasing the final sentence. It is *never* in the retrieval path.

1. **`router_node`** — classifies into `metadata_q` / `kpi_q` / `help_q` /
   `out_of_scope` and extracts entities (circle, device, component, interface,
   KPI, aggregation, top-N, threshold, time window).
2. **`resolve_node`** — grounds entities against live data (fuzzy host matching,
   circle matching); asks for disambiguation rather than guessing.
3. **`build_spec` / `spec_node`** — compiles an explicit **QuerySpec**
   (intent · target · aggregation · filters · window).
4. **`scope_check`** — distinguishes *unrelated* from *in-scope-but-unsupported*.
5. **`execute_query_spec`** — one general, deterministic executor. No LLM.
   Multi-device questions fan out in parallel (`VI_FANOUT_MAX_WORKERS`).
   Zero-result answers trigger a self-healing recheck.
6. **`synthesize_node`** — phrases the sentence (temperature 0.0).

Genuinely unrecognized shapes fall back to a free-text ReAct tool loop
(`react_executor_node`), capped at `VI_REACT_MAX_STEPS`.

### Analytical shapes supported

- Metadata counts and listings (devices / interfaces / components / KPIs)
- KPI history with Min/Max/Avg over a window
- **Top/bottom N devices** by KPI over a window
- **Top/bottom N interfaces** by KPI "currently" — approximated as the most
  recent point within `VI_CURRENT_VALUE_LOOKBACK_SECONDS` (the API has no
  live-value endpoint)
- **Spike/dip detection** — each point scored against a *local* rolling baseline
  built from its neighbours **excluding itself**, flagged past
  `VI_SPIKE_ZSCORE_THRESHOLD` σ

---

## Auth model

There is **no app-side password gate**. The login page takes *email + employee
id*; both go straight to `ig_login`. A successful Instant Graph login **is** the
auth check. On success the app issues an opaque, memory-only browser session
token. Tokens are persisted to `ig_auth_sessions` so multiple worker processes
share auth state.

---

## Postgres

One database, one schema, shared by both processes.

**Host `10.19.75.115` · db `conv_ai_db` · schema `tt_vi_ippms_schema`**

| Table | Written by | Purpose |
|---|---|---|
| `ig_auth_sessions` | MCP server | Persisted IG tokens (cross-process) |
| `ig_auth_login_audit` | MCP server | Login attempts |
| `ig_tool_call_audit` | MCP server | Every MCP tool invocation (background writer) |
| `vi_chat_interactions` | chat app | One row per question answered |
| `vi_chat_feedback` | chat app | 👍 / 👎 votes |
| `user_feedback` | chat app | Free-text feedback |
| `vi_chat_conversations` | chat app | Sidebar conversations (7-day retention) |
| `vi_chat_messages` | chat app | Messages within a conversation |
| `vi_glossary_terms` | chat app | SME-curated domain glossary |

`ig_auth_sessions` and `ig_auth_login_audit` come from `setup_ig_auth_tables.sql`
and must **pre-exist**. Every other table is created best-effort with
`CREATE TABLE IF NOT EXISTS` at startup. All logging is non-blocking — a DB
outage degrades logging but never fails a chat turn.

---

## Required on-disk assets

These are **not** in git (they are data, and the xlsx is binary). Copy them from
the running host into `assets/` — or point the env vars elsewhere:

| Asset | Env var | Used for |
|---|---|---|
| `vi_ippms_tool_kb.md` | `VI_TOOL_KB_PATH` | Consolidated tool knowledge base |
| `vi_ippms_question_guide.xlsx` | `VI_QUESTION_GUIDE_PATH` | Local TF-IDF RAG index (sheet must be named `question_guide`) |
| `ig_selfsigned.pem` | `IG_CA_BUNDLE` | CA bundle for the Instant Graph gateway cert |

If the guide is missing the app still starts — RAG retrieval is just disabled
(a warning is logged). If the PEM is missing, **every upstream call fails**.

---

## Configuration

Everything is environment-driven. Start from the template:

```bash
cp .env.example .env
chmod 600 .env          # contains secrets
$EDITOR .env
```

Two values are **required and have no default** (the hardcoded fallbacks were
removed from source — see CHANGELOG 6.7.2-r1):

- `IG_DB_PASSWORD`
- `GPU_API_KEY`

---

## Running it

Order matters.

```bash
# 1 — MCP server (must be up first)
set -a; . ./.env; set +a
python3 src/instant_graph_mcp_server_v2_5.py

# 2 — chat app
set -a; . ./.env; set +a
python3 src/talk_to_vi_ippms_updated_6_7_2.py
```

Then browse to `http://<host>:8079/` (chat) or `http://<host>:8060/` (ops
console — the fastest way to sanity-check the API wiring end to end).

For production use the systemd units in `deploy/` instead — they handle
ordering, restart, and `EnvironmentFile` loading.

### Dependencies

```bash
pip install -r requirements.txt
```

---

## Glossary editors

Only the emails in `GLOSSARY_EDITORS` (near the top of the chat app) may add or
edit glossary terms. This is enforced **server-side on both the open and the
submit path** — a hidden button is not access control. To grant or revoke
access, edit that set and restart.

---

## Repository layout

```
.
├── README.md
├── CHANGELOG.md                       ← version-by-version history
├── .env.example                       ← copy to .env, fill in secrets
├── requirements.txt
├── src/
│   ├── talk_to_vi_ippms_updated_6_7_2.py
│   └── instant_graph_mcp_server_v2_5.py
├── assets/                            ← tool KB + question guide (gitignored)
├── deploy/
│   ├── instant-graph-mcp.service
│   └── talk-to-vi-ippms.service
└── docs/
    └── MIGRATION_10.19.75.115.md      ← FALCONPRD → 10.19.75.115 runbook
```

Filenames keep their version suffixes so existing run commands and muscle
memory still work. From here on, **git tags are the source of truth for
versions** — see `CHANGELOG.md`.
