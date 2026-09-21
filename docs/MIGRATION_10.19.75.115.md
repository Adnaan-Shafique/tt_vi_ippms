# Migration runbook — FALCONPRD `10.19.71.246` → `10.19.75.115`

**Target:** move both processes onto `10.19.75.115` with no data loss and a
fast rollback path.

---

## 0. The single most important fact

> **`10.19.75.115` is already your Postgres host.**

Both files already point their DB config at it (`IG_DB_HOST` /
`VI_DB_HOST` default to `10.19.75.115`). So this is **not** a database
migration at all — the data never moves.

What you are actually doing is **moving the two application processes onto the
box that already holds their database.** That makes this far easier and lower
risk than it sounds, and it has a nice side effect: the DB hop stops crossing
the network and becomes a loopback connection.

Concretely:

| | Today | After |
|---|---|---|
| Chat app `:8079` | 10.19.71.246 | **10.19.75.115** |
| MCP server `:8056` / `:8060` | 10.19.71.246 | **10.19.75.115** |
| Postgres `:5432` | 10.19.75.115 | 10.19.75.115 *(unchanged)* |
| GPU proxy `:8071` | 10.19.71.246 | **decide — see §1** |
| Instant Graph API | 10.34.64.74:5001 | *(unchanged)* |

**Nothing needs to be dumped, restored, or re-pointed in Postgres.** Do not run
`pg_dump`/`pg_restore` as part of this migration — it would only create a
second copy of data that is already in the right place.

---

## 1. The one decision you must make first: the GPU proxy

This is the only genuine unknown, and it determines everything else.

The chat app reasons against a local inference proxy at
`GPU_PROXY_URL=http://127.0.0.1:8071/v1/infer`. That `127.0.0.1` means it is
**currently running on FALCONPRD itself**. Pick one:

### Option A — the GPU stays on FALCONPRD
Simplest and fastest. The chat app on `.115` calls across to `.246`:

```bash
GPU_PROXY_URL=http://10.19.71.246:8071/v1/infer
```

- ✅ No GPU/driver/model work at all.
- ⚠️ You keep a hard dependency on FALCONPRD — it **cannot be decommissioned**.
- ⚠️ Every LLM call now crosses the network. Bump `GPU_TIMEOUT` if you see
  timeouts, and confirm the proxy binds `0.0.0.0` rather than `127.0.0.1`
  (if it binds loopback-only today, it will refuse the remote connection).
- ⚠️ Firewall: `.115 → .246:8071` must be open.

### Option B — move the GPU proxy too
The clean end state, but it is a **separate project**: `.115` needs a suitable
GPU, NVIDIA drivers + CUDA, the mistral-7b weights, and the proxy service.
Verify the hardware exists *before* committing to this — if `.115` has no GPU,
Option B is off the table.

> **Recommendation:** migrate with **Option A** and treat the GPU move as a
> follow-up. It keeps this migration to "copy two Python processes", which is a
> one-evening job with a trivial rollback. Chasing both at once turns a safe
> move into a risky one.

Verify whichever you choose (§5.2) before going live.

---

## 2. Pre-flight checks — run these on `10.19.75.115` first

Do not skip. Each one has bitten a migration like this.

```bash
# --- 2.1 Python + OS ---
python3 --version                 # match FALCONPRD's minor version
free -h && df -h /srv && nproc

# --- 2.2 Postgres is local now — confirm you can reach it ---
psql -h 127.0.0.1 -U ig_app_user -d conv_ai_db -c '\dn'      # expect tt_vi_ippms_schema
psql -h 127.0.0.1 -U ig_app_user -d conv_ai_db -c '\dt tt_vi_ippms_schema.*'

# --- 2.3 The upstream Instant Graph gateway must be reachable FROM .115 ---
#     This is the #1 thing that silently differs between subnets.
curl -sv --max-time 10 https://10.34.64.74:5001/api/api/v5/auth/login 2>&1 | tail -20
nc -vz 10.34.64.74 5001

# --- 2.4 If GPU stays on FALCONPRD (Option A) ---
nc -vz 10.19.71.246 8071

# --- 2.5 Target ports must be free ---
ss -lntp | grep -E ':(8056|8060|8079)\b'      # expect no output
```

**If 2.3 fails, stop.** `.115` sitting in a different network zone than `.246`
is the most likely way this migration fails, and it fails *after* you have
moved everything. Get the firewall rule raised before you go further.

### 2.6 `pg_hba.conf` — the loopback trap

The app used to connect from `.246`, so `pg_hba.conf` on `.115` has a rule for
that source address. Connecting from **the box itself** is a *different* source
address, and may not be covered. Check before you cut over:

```bash
sudo grep -vE '^\s*#|^\s*$' /var/lib/pgsql/data/pg_hba.conf   # path varies
```

Ensure a line covers local/loopback for `ig_app_user` + `conv_ai_db`, e.g.

```
host    conv_ai_db    ig_app_user    127.0.0.1/32    scram-sha-256
```

Then `sudo systemctl reload postgresql`. **Keep the existing `.246` rule** until
after you have decommissioned — it is what makes rollback work.

---

## 3. Capture the exact environment from FALCONPRD

Do this **on `10.19.71.246`, before you touch anything.** The running host is
the only authoritative record of what actually works.

```bash
# 3.1 Exact dependency versions — do not rely on "latest" resolving the same way
pip freeze > /tmp/falconprd-freeze.txt

# 3.2 The real runtime environment of the live processes.
#     Env vars set in a shell/unit file are invisible in the source.
for svc in <chat-pid> <mcp-pid>; do sudo tr '\0' '\n' < /proc/$svc/environ; done
#   or, if under systemd:
systemctl cat talk-to-vi-ippms instant-graph-mcp 2>/dev/null

# 3.3 The on-disk assets — NOT in git, and the app degrades or dies without them
ls -la vi_ippms_tool_kb.md vi_ippms_question_guide.xlsx
ls -la /srv/ippms-assistant/ig_selfsigned.pem

# 3.4 How it's currently started (cron? nohup? systemd? tmux?)
crontab -l; ls /etc/systemd/system/ | grep -iE 'ippms|vi|mcp'
```

Save all of this. §3.2 in particular: a value overridden in the live
environment but left at its source default in git is a classic post-migration
mystery.

---

## 4. Migration steps

### 4.1 Prepare the target

```bash
# on 10.19.75.115
sudo useradd -r -m -d /srv/ippms-assistant -s /usr/sbin/nologin ippms
sudo mkdir -p /srv/ippms-assistant/{assets,logs}
sudo chown -R ippms:ippms /srv/ippms-assistant
```

### 4.2 Get the code there

```bash
sudo -u ippms git clone <repo-url> /srv/ippms-assistant
# air-gapped? rsync the repo across instead:
#   rsync -avz --exclude '.env' /srv/ippms-assistant/ ippms@10.19.75.115:/srv/ippms-assistant/
```

### 4.3 Copy the assets git does not carry

These are deliberately gitignored (secrets + binary data). Copy them **from
FALCONPRD**:

```bash
# from 10.19.71.246
scp vi_ippms_tool_kb.md          ippms@10.19.75.115:/srv/ippms-assistant/assets/
scp vi_ippms_question_guide.xlsx ippms@10.19.75.115:/srv/ippms-assistant/assets/
scp /srv/ippms-assistant/ig_selfsigned.pem ippms@10.19.75.115:/srv/ippms-assistant/
```

```bash
# on .115 — the PEM must not be world-readable
sudo chown ippms:ippms /srv/ippms-assistant/ig_selfsigned.pem
sudo chmod 640 /srv/ippms-assistant/ig_selfsigned.pem
```

> **Missing-asset behaviour differs, and it matters:**
> - Missing **question guide** → app still starts, RAG retrieval silently
>   disabled, answer quality quietly drops. Easy to miss. Check the startup log
>   line says `question guide loaded: N rows`, not `MISSING`.
> - Missing **PEM** → **every upstream Instant Graph call fails** cert
>   verification. Loud and immediate.

### 4.4 Python environment

```bash
sudo -u ippms python3 -m venv /srv/ippms-assistant/.venv
sudo -u ippms /srv/ippms-assistant/.venv/bin/pip install --upgrade pip

# Prefer the exact versions captured in §3.1:
sudo -u ippms /srv/ippms-assistant/.venv/bin/pip install -r /tmp/falconprd-freeze.txt
# Otherwise:
sudo -u ippms /srv/ippms-assistant/.venv/bin/pip install -r /srv/ippms-assistant/requirements.txt
```

> `pandas.read_excel()` needs **`openpyxl`**. It is a transitive dependency that
> is easy to lose when rebuilding an environment, and losing it disables RAG
> *silently* (see §4.3).

### 4.5 Write `.env`

```bash
sudo -u ippms cp /srv/ippms-assistant/.env.example /srv/ippms-assistant/.env
sudo -u ippms chmod 600 /srv/ippms-assistant/.env
sudo -u ippms vi /srv/ippms-assistant/.env
```

Set at minimum:

```bash
IG_DB_HOST=127.0.0.1                  # now loopback — the app lives on the DB box
IG_DB_PASSWORD=<real password>        # ►► no longer has a source fallback
GPU_API_KEY=<real key>                # ►► no longer has a source fallback

# §1 Option A (GPU stays on FALCONPRD):
GPU_PROXY_URL=http://10.19.71.246:8071/v1/infer
# §1 Option B (GPU moved to .115): leave as 127.0.0.1

MCP_SERVER_URL=http://127.0.0.1:8056/mcp     # both processes are co-located
IG_CA_BUNDLE=/srv/ippms-assistant/ig_selfsigned.pem
IG_CERT_HOSTNAME=ippms.vodafoneidea.com
VI_TOOL_KB_PATH=/srv/ippms-assistant/assets/vi_ippms_tool_kb.md
VI_QUESTION_GUIDE_PATH=/srv/ippms-assistant/assets/vi_ippms_question_guide.xlsx
```

> **`IG_DB_PASSWORD` and `GPU_API_KEY` now have no fallback in source** — the
> hardcoded values were removed when this repo was created (CHANGELOG 6.7.2-r1).
> If you forget them the DB and LLM calls fail. **Rotate both credentials** as
> part of this migration; they were sitting in plaintext in the old source.

### 4.6 Firewall

```bash
sudo firewall-cmd --permanent --add-port=8079/tcp   # chat UI
sudo firewall-cmd --permanent --add-port=8060/tcp   # ops console
sudo firewall-cmd --reload
```

Leave **`8056` closed to the outside** — the MCP server only ever needs to be
reachable from `127.0.0.1` now that both processes share a host. It exposes the
Instant Graph tool surface, so do not publish it.

---

## 5. Validate before cutting over

Run both processes **in the foreground** first. Do not install the services
until a manual run works — a foreground failure is readable, a systemd one is a
journal hunt.

### 5.1 MCP server

```bash
cd /srv/ippms-assistant
set -a; . ./.env; set +a
sudo -u ippms -E .venv/bin/python src/instant_graph_mcp_server_v2_5.py
```

Expect the banner, and `Connected to Postgres token store at 127.0.0.1:5432/conv_ai_db`.
Then, in another shell:

```bash
curl -s http://127.0.0.1:8060/ -o /dev/null -w '%{http_code}\n'   # ops console → 200
```

Open `http://10.19.75.115:8060/`, log in with your email + employee id, and walk
the explorer: **host → component → interface → KPI → historical data**. This is
the fastest full-path check that the upstream API, the TLS pinning, and the
token manager all work from this host. If the data renders, the hard part is done.

### 5.2 Verify the GPU proxy reachability (§1)

```bash
curl -s -X POST "$GPU_PROXY_URL" \
  -H "Content-Type: application/json" -H "X-API-Key: $GPU_API_KEY" \
  -d '{"model":"mistral","prompt":"SYSTEM:\nreply OK\n\nUSER:\nping\n\nASSISTANT:\n","max_new_tokens":8}'
```

A JSON body with a `text` field means you are good. **Do this explicitly** —
`GPULLMClient.infer()` never raises, it returns `""` on failure. A dead proxy
therefore does **not** crash the app; it degrades into wrong-looking routing and
empty answers, which is much harder to diagnose later.

### 5.3 Chat app

```bash
cd /srv/ippms-assistant
set -a; . ./.env; set +a
sudo -u ippms -E .venv/bin/python src/talk_to_vi_ippms_updated_6_7_2.py
```

The startup line is your checklist — read every field:

```
[STARTUP] Discovered 8 MCP tools.
[STARTUP] question guide loaded: N rows indexed for retrieval.
[STARTUP] tool KB loaded, question guide N rows, logging ready,
          user_feedback ready, chat_history ready, glossary ready.
```

Anything reading `MISSING` or `disabled` means an asset or the DB did not come
across. **Do not go live on a degraded startup line** — every one of those
failures is silent at runtime.

### 5.4 Functional smoke test

Browse to `http://10.19.75.115:8079/`, log in, and run one question of each
shape — they exercise different code paths:

| # | Question | Exercises |
|---|---|---|
| 1 | "How many devices are in the GUJ circle?" | metadata route, circle matching |
| 2 | "How many interfaces on `<device>`?" | host resolution, fan-out |
| 3 | "On `<device>`, interface `<if>`, HC In Octets between 8am and 2pm yesterday" | KPI route, `between` parsing, charts |
| 4 | "Top 5 interfaces by HC In Octets on `<device>` currently" | 6.6 ranking shape, bar chart |
| 5 | "Show me the spikes for HC In Octets on `<if>` on `<device>` in the last 6 hours" | 6.7 anomaly shape |
| 6 | Anything nonsense — "what's the weather" | out-of-scope gate |

Then confirm the side effects landed:

```sql
-- against conv_ai_db
SELECT count(*), max(created_at) FROM tt_vi_ippms_schema.vi_chat_interactions;
SELECT count(*), max(created_at) FROM tt_vi_ippms_schema.ig_tool_call_audit;
```

Both counts must be **rising**. Also: open the sidebar and confirm your old
conversations are there. They will be — the DB never moved — and seeing them is
the clearest proof that history survived the migration.

Finally, click **👍** on an answer and re-check `vi_chat_feedback`, and download
a CSV from a result table.

### 5.5 Install the services

Only once 5.1–5.4 pass:

```bash
sudo cp /srv/ippms-assistant/deploy/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now instant-graph-mcp
sleep 10                                   # let the MCP server bind before the client starts
sudo systemctl enable --now talk-to-vi-ippms
systemctl status instant-graph-mcp talk-to-vi-ippms --no-pager
```

Then **reboot the box once** and confirm both come back on their own. A
migration that only survives while you are watching is not finished.

---

## 6. Cutover

1. Announce a short window to the ops team.
2. **Stop the FALCONPRD processes** — do not leave both running. Both write to
   the same tables and both hold Instant Graph tokens under the same
   `ig_auth_sessions` keys; two live copies will fight over token refresh and
   produce confusing auth failures.
   ```bash
   # on 10.19.71.246
   sudo systemctl stop talk-to-vi-ippms instant-graph-mcp    # or kill the processes
   sudo systemctl disable talk-to-vi-ippms instant-graph-mcp
   ```
3. Repoint whatever users actually type — DNS record, reverse proxy, or the
   bookmark you circulate — from `10.19.71.246:8079` to `10.19.75.115:8079`.
   Updating DNS rather than asking people to learn a new IP is worth the effort.
4. Watch for 30 minutes:
   ```bash
   journalctl -u talk-to-vi-ippms -u instant-graph-mcp -f
   ```
5. **Leave FALCONPRD intact for ~1 week.** It is your rollback.

---

## 7. Rollback

Because the database never moved and nothing was destructively changed,
rollback is genuinely trivial:

```bash
# on .115
sudo systemctl stop talk-to-vi-ippms instant-graph-mcp
# on .246
sudo systemctl start instant-graph-mcp && sleep 10 && sudo systemctl start talk-to-vi-ippms
# revert DNS / proxy
```

No data reconciliation is needed — both hosts were always writing to the same
Postgres. Anything answered on `.115` is already visible from `.246`.

This is exactly why §6 step 5 says keep FALCONPRD for a week: the cost of
keeping it is near zero and it buys you a 60-second rollback.

---

## 8. Post-migration cleanup

Once you are confident (a week of clean running):

- [ ] **Rotate `IG_DB_PASSWORD` and `GPU_API_KEY`** — both were plaintext in the
      old source files. Update `.env`, restart both services.
- [ ] Remove the now-unused `.246` rule from `pg_hba.conf` and reload Postgres.
- [ ] Scrub the credentials and the assets from FALCONPRD before reclaiming it.
- [ ] Close port `8056` externally if it was ever opened.
- [ ] Decide on §1 Option B (move the GPU proxy) and schedule it — until then,
      FALCONPRD stays up and this migration is not fully complete.
- [ ] Add a `mcp 2.4 / 2.5` entry to `CHANGELOG.md` if anyone remembers what
      shipped.

---

## 9. Quick reference

| What | Value |
|---|---|
| Source host | `10.19.71.246` (FALCONPRD) |
| Target host | `10.19.75.115` (also the Postgres host) |
| Install path | `/srv/ippms-assistant` |
| Service user | `ippms` |
| Chat UI | `:8079` — publish |
| Ops console | `:8060` — publish |
| MCP endpoint | `:8056/mcp` — **keep internal** |
| Postgres | `conv_ai_db` / `tt_vi_ippms_schema` — **does not move** |
| Instant Graph API | `https://10.34.64.74:5001/api/api` |
| GPU proxy | `:8071` — **see §1** |
| Services | `instant-graph-mcp` → `talk-to-vi-ippms` (in that order) |
