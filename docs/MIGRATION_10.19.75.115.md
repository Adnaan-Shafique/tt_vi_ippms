# Migration runbook — FALCONPRD `10.19.71.246` → `10.19.75.115`

Move both processes to `10.19.75.115`, running under systemd as separate
**prod** and **test** deployments, with no data loss and a fast rollback.

---

## 1. What is actually moving

> **`10.19.75.115` is already your Postgres host.** Both files already default
> their DB config to it.

So this is **not a database migration** — the data never moves. You are moving
two Python processes onto the box that already holds their database, which
turns the DB hop into a loopback connection. Your chat history, feedback and
audit rows are all still there afterwards because they were never touched.

**Do not run `pg_dump`/`pg_restore`.** It would only create a second copy of
data that is already in the right place.

| | Today | After |
|---|---|---|
| Chat app `:8079` | 10.19.71.246 | **10.19.75.115** (+ test on `:8179`) |
| MCP server `:8056` / `:8060` | 10.19.71.246 | **10.19.75.115** |
| Postgres `:5432` | 10.19.75.115 | 10.19.75.115 *(unchanged)* |
| GPU proxy `:8071` | 10.19.71.246 | **stays on FALCONPRD** |
| Instant Graph API | direct from `.246` | **relayed through `.246`** |
| Process manager | `nohup` | **systemd** |

### FALCONPRD is not being decommissioned

`.115` has no GPU and no route to the Instant Graph gateway. Both of those
dependencies stay on `.246` permanently, so **FALCONPRD remains a hard runtime
dependency** after this migration. Plan for it: if `.246` goes down, `.115`
cannot answer a single question.

That is the main architectural consequence of this move, and it is worth
saying out loud to whoever owns the FALCONPRD host so it does not get
reclaimed as "the old server".

---

## 2. The network relay (do this first)

`.115` cannot reach `10.34.64.74:5001`. Everything else in this runbook is
routine; this is the part that needs care, because the gateway's TLS is
pinned.

### 2.1 Why a CONNECT proxy, and not TLS termination

The MCP server verifies the gateway's self-signed cert against `IG_CA_BUNDLE`
and pins the SAN `ippms.vodafoneidea.com` via `assert_hostname` (it dials a raw
IP, so normal hostname verification cannot work). **Any relay that terminates
TLS breaks that** — the app would see the relay's cert, not the gateway's.

A **CONNECT forward proxy** does not decrypt: it opens a TCP tunnel and gets
out of the way. TLS stays end-to-end between `.115` and the gateway, so the CA
bundle and the SAN pinning keep working **with no code change at all**.

This works because `_PinnedSSLContextAdapter` overrides **both**
`init_poolmanager` *and* `proxy_manager_for` (`instant_graph_mcp_server_v2_5.py:742`).
Had it overridden only the former — the common way to write that class — the
pinned SSL context would be silently dropped on proxied connections and every
call would fail cert verification. You are lucky here; do not "simplify" that
adapter later.

`requests` picks up `HTTPS_PROXY` from the environment automatically
(`Session.trust_env` is true and `_call` passes no explicit `proxies=`), so
enabling the relay is purely a `.env` change.

### 2.2 Install the relay on FALCONPRD

```bash
# on 10.19.71.246
sudo dnf install -y squid                     # or: apt install squid
sudo cp deploy/relay/squid-ig-relay.conf /etc/squid/conf.d/ig-relay.conf
sudo squid -k parse                           # must print no errors
sudo systemctl enable --now squid
sudo firewall-cmd --permanent --add-port=3128/tcp && sudo firewall-cmd --reload
```

The config allows exactly one source (`10.19.75.115`) to CONNECT to exactly one
destination (`10.34.64.74:5001`) and denies everything else. It is a
purpose-built relay, not an open proxy — keep it that way.

> Squid refuses `CONNECT` to non-standard ports by default. The config
> whitelists `5001` in `SSL_ports`/`Safe_ports`; without that you get a blunt
> `403 Forbidden` from squid that looks nothing like a TLS problem.

### 2.3 Open the GPU proxy to `.115`

```bash
# on 10.19.71.246
sudo firewall-cmd --permanent --add-port=8071/tcp && sudo firewall-cmd --reload
```

Then confirm the proxy binds `0.0.0.0` and not `127.0.0.1` — it has only ever
served localhost, so a loopback-only bind is likely and will refuse `.115`:

```bash
ss -lntp | grep 8071        # want 0.0.0.0:8071 or *:8071, NOT 127.0.0.1:8071
```

If it is loopback-only, change its bind address and restart it.

### 2.4 Verify from `.115` before going further

```bash
# on 10.19.75.115
curl -sv --max-time 10 --proxy http://10.19.71.246:3128 \
     https://10.34.64.74:5001/api/api/v3/get-hosts 2>&1 | grep -E 'CONNECT|SSL|subject|HTTP/'
nc -vz 10.19.71.246 8071
```

You want to see the CONNECT tunnel establish and the TLS handshake complete.
A `401` from the gateway is **expected and fine** — you have no token. What you
are proving is that the tunnel opens and the cert verifies.

**If this fails, stop here.** Get the firewall rules raised before moving
anything. Discovering this after cutover is the expensive path.

### 2.5 Fallback: autossh tunnel

If you cannot install squid on FALCONPRD, use
`deploy/relay/autossh-ig-tunnel.service` on `.115` instead, and set
`INSTANT_GRAPH_BASE_URL=https://127.0.0.1:5001/api/api` with `HTTPS_PROXY`
unset. Cert pinning still works — `assert_hostname` checks the SAN, not the
address you dialled. Prefer squid: one less daemon and one less keypair.

### 2.6 `NO_PROXY` matters

The GPU proxy is **plain HTTP on `.246:8071`** and is directly reachable. It
must not go through the relay. `.env.example` sets:

```bash
NO_PROXY=127.0.0.1,localhost,10.19.71.246:8071,10.19.75.115
```

Also only set `HTTPS_PROXY`, never `HTTP_PROXY` — setting the latter would
push GPU inference and the loopback MCP calls through squid, which denies
them.

---

## 3. Pre-flight checks on `10.19.75.115`

```bash
python3 --version                 # match FALCONPRD's minor version
free -h && df -h /srv && nproc

# Postgres is local now
psql -h 127.0.0.1 -U ig_app_user -d conv_ai_db -c '\dn'
psql -h 127.0.0.1 -U ig_app_user -d conv_ai_db -c '\dt tt_vi_ippms_schema.*'

# Ports free (prod + test)
ss -lntp | grep -E ':(8056|8060|8079|8156|8160|8179)\b'
```

### 3.1 `pg_hba.conf` — the loopback trap

The app used to connect from `.246`, so `pg_hba.conf` has a rule for **that**
source address. Connecting from the box itself is a different source address
and may not be covered:

```bash
sudo grep -vE '^\s*#|^\s*$' /var/lib/pgsql/data/pg_hba.conf   # path varies
```

Ensure a loopback rule exists:

```
host    conv_ai_db    ig_app_user    127.0.0.1/32    scram-sha-256
```

`sudo systemctl reload postgresql`. **Keep the existing `.246` rule** until
after decommissioning — it is what makes rollback work.

---

## 4. Capture the current environment from FALCONPRD

Do this **on `.246`, before touching anything.** The running host is the only
authoritative record of what actually works.

```bash
# Exact dependency versions — "latest" may not resolve the same way today
pip freeze > /tmp/falconprd-freeze.txt

# The REAL runtime env of the live processes. Since you run under nohup, any
# variable exported in that shell is invisible in both the source AND in any
# unit file — /proc is the only place it still exists. Capture it before the
# processes are stopped, or it is gone.
pgrep -af 'talk_to_vi_ippms|instant_graph_mcp'
for pid in $(pgrep -f 'talk_to_vi_ippms|instant_graph_mcp'); do
    echo "--- $pid ---"; sudo tr '\0' '\n' < /proc/$pid/environ
done

# Assets not in git
ls -la vi_ippms_tool_kb.md vi_ippms_question_guide.xlsx /srv/ippms-assistant/ig_selfsigned.pem
```

The `/proc/<pid>/environ` step is the one to be careful about. A value
overridden in your nohup shell but left at its source default in git is a
classic post-migration mystery, and stopping the process destroys the
evidence.

---

## 5. Build the two environments

Follow **`docs/ENVIRONMENTS.md`** for the full prod/test setup — checkouts,
venvs, schemas, ports, systemd units. Summary:

```bash
sudo useradd -r -m -d /srv/ippms-assistant -s /usr/sbin/nologin ippms
sudo mkdir -p /srv/ippms-assistant/{prod,test,backups}
sudo chown -R ippms:ippms /srv/ippms-assistant

sudo -u ippms git clone <repo-url> /srv/ippms-assistant/prod
sudo -u ippms git clone <repo-url> /srv/ippms-assistant/test
sudo -u ippms git -C /srv/ippms-assistant/prod checkout --detach v1.0.0
```

### 5.1 Copy the assets git does not carry

Gitignored deliberately — binary data and a credential:

```bash
# from 10.19.71.246, into BOTH environments
for e in prod test; do
  scp vi_ippms_tool_kb.md          ippms@10.19.75.115:/srv/ippms-assistant/$e/assets/
  scp vi_ippms_question_guide.xlsx ippms@10.19.75.115:/srv/ippms-assistant/$e/assets/
  scp /srv/ippms-assistant/ig_selfsigned.pem ippms@10.19.75.115:/srv/ippms-assistant/$e/
done
```

```bash
# on .115 — the PEM must not be world-readable
sudo chmod 640 /srv/ippms-assistant/{prod,test}/ig_selfsigned.pem
sudo chown ippms:ippms /srv/ippms-assistant/{prod,test}/ig_selfsigned.pem
```

> **Missing-asset behaviour differs, and it matters:**
> - Missing **question guide** → app still starts, RAG silently disabled,
>   answer quality quietly drops. Easy to miss for weeks.
> - Missing **PEM** → every upstream call fails cert verification. Loud.

### 5.2 Virtualenvs

```bash
for e in prod test; do
  sudo -u ippms python3 -m venv /srv/ippms-assistant/$e/.venv
  sudo -u ippms /srv/ippms-assistant/$e/.venv/bin/pip install -r /tmp/falconprd-freeze.txt
done
```

> `pandas.read_excel()` needs **`openpyxl`** — a transitive dependency easy to
> lose when rebuilding an environment, and losing it disables RAG *silently*.

### 5.3 Test schema

```bash
psql -h 127.0.0.1 -U ig_app_user -d conv_ai_db \
     -v schema=tt_vi_ippms_schema_test -f /srv/ippms-assistant/test/sql/setup_ig_auth_tables.sql
```

### 5.4 `.env` per environment

```bash
for e in prod test; do
  sudo -u ippms cp /srv/ippms-assistant/$e/.env.example /srv/ippms-assistant/$e/.env
  sudo -u ippms chmod 600 /srv/ippms-assistant/$e/.env
done
```

Prod values:

```bash
IG_DB_HOST=127.0.0.1
IG_DB_PASSWORD=<real>                          # ►► no source fallback any more
GPU_API_KEY=<real>                             # ►► no source fallback any more
HTTPS_PROXY=http://10.19.71.246:3128
NO_PROXY=127.0.0.1,localhost,10.19.71.246:8071,10.19.75.115
GPU_PROXY_URL=http://10.19.71.246:8071/v1/infer
IG_CA_BUNDLE=/srv/ippms-assistant/prod/ig_selfsigned.pem
IG_CERT_HOSTNAME=ippms.vodafoneidea.com
VI_TOOL_KB_PATH=/srv/ippms-assistant/prod/assets/vi_ippms_tool_kb.md
VI_QUESTION_GUIDE_PATH=/srv/ippms-assistant/prod/assets/vi_ippms_question_guide.xlsx
```

For `test/.env` change **all five** of `IG_DB_SCHEMA`, `IG_DB_SESSION_KEY`,
`MCP_PORT`, `MCP_SERVER_URL`, `DASH_PORT`, `VI_APP_PORT` — and note that
`MCP_SERVER_URL` is the one people forget, which silently points the test chat
app at the **production** MCP server. See `docs/ENVIRONMENTS.md`.

> **`IG_DB_PASSWORD` and `GPU_API_KEY` no longer have fallbacks in source** —
> the hardcoded values were removed when this repo was created (CHANGELOG
> 1.0.0). **Rotate both** as part of this migration; they sat in plaintext in
> the old source files.

### 5.5 Firewall on `.115`

```bash
sudo firewall-cmd --permanent --add-port=8079/tcp   # prod chat UI
sudo firewall-cmd --permanent --add-port=8060/tcp   # prod ops console
sudo firewall-cmd --permanent --add-port=8179/tcp   # test chat UI
sudo firewall-cmd --permanent --add-port=8160/tcp   # test ops console
sudo firewall-cmd --reload
```

Leave `8056`/`8156` **closed** — the MCP servers bind `127.0.0.1` and expose
the whole Instant Graph tool surface unauthenticated.

---

## 6. Validate

### 6.1 Automated preflight

```bash
deploy/preflight.sh /srv/ippms-assistant/prod/.env
```

Checks secrets, assets, Postgres, auth tables, the relay, the GPU proxy and
the ports. Fix every `✗` before continuing.

### 6.2 Run in the foreground first

Do not install the services until a manual run works — a foreground failure is
readable, a systemd one is a journal hunt.

```bash
cd /srv/ippms-assistant/prod
set -a; . ./.env; set +a
sudo -u ippms -E .venv/bin/python src/instant_graph_mcp_server_v2_5.py
```

Expect the banner and
`Connected to Postgres token store at 127.0.0.1:5432/conv_ai_db`.

Then open `http://10.19.75.115:8060/`, log in with email + employee id, and
walk the explorer: **host → component → interface → KPI → historical data**.
This is the fastest end-to-end proof that the relay, the TLS pinning and the
token manager all work from this host. If data renders, the hard part is done.

### 6.3 GPU proxy

```bash
curl -s --noproxy '*' -X POST "$GPU_PROXY_URL" \
  -H "Content-Type: application/json" -H "X-API-Key: $GPU_API_KEY" \
  -d '{"model":"mistral","prompt":"SYSTEM:\nreply OK\n\nUSER:\nping\n\nASSISTANT:\n","max_new_tokens":8}'
```

**Do this explicitly.** `GPULLMClient.infer()` never raises — it returns `""`
on failure. A dead or unreachable proxy therefore does **not** crash the app;
it degrades into wrong-looking routing and empty answers, which is far harder
to diagnose later than a crash would be.

Now that the call crosses the network, consider raising `GPU_TIMEOUT` if you
see timeouts under load.

### 6.4 Chat app

```bash
cd /srv/ippms-assistant/prod
set -a; . ./.env; set +a
sudo -u ippms -E .venv/bin/python src/talk_to_vi_ippms_updated_6_7_2.py
```

Read every field of the startup line — it is your checklist:

```
[STARTUP] Discovered 8 MCP tools.
[STARTUP] question guide loaded: N rows indexed for retrieval.
[STARTUP] tool KB loaded, question guide N rows, logging ready,
          user_feedback ready, chat_history ready, glossary ready.
```

**Do not go live on a degraded startup line.** Every failure it reports is
silent at runtime.

### 6.5 Functional smoke test

Run the six-question acceptance checklist in
`docs/ENVIRONMENTS.md` at `http://10.19.75.115:8079/`, then confirm:

```sql
SELECT count(*), max(created_at) FROM tt_vi_ippms_schema.vi_chat_interactions;
SELECT count(*), max(created_at) FROM tt_vi_ippms_schema.ig_tool_call_audit;
```

Both must be rising. Also open the sidebar and confirm your **old
conversations are there** — they will be, because the DB never moved, and
seeing them is the clearest single proof that nothing was lost.

### 6.6 Install the services

Only once 6.1–6.5 pass. See `docs/ENVIRONMENTS.md`, then:

```bash
sudo systemctl enable --now instant-graph-mcp@prod && sleep 10
sudo systemctl enable --now talk-to-vi-ippms@prod
systemctl status 'instant-graph-mcp@*' 'talk-to-vi-ippms@*' --no-pager
```

**Reboot the box once** and confirm both come back unattended. A migration
that only survives while you are watching is not finished — and this is
exactly the failure mode `nohup` had.

---

## 7. Cutover

1. Announce a short window.
2. **Stop the FALCONPRD app processes.** Do not leave both running: they write
   to the same tables and share `ig_auth_sessions` keys, so two live copies
   will fight over token refresh and produce confusing auth failures.
   ```bash
   # on 10.19.71.246 — app processes only. Leave squid and the GPU proxy UP.
   pkill -f talk_to_vi_ippms
   pkill -f instant_graph_mcp
   ```
   Also remove any `@reboot` cron entry or rc-local line that would restart
   them.

   > **Leave squid and the GPU proxy running on `.246`.** They are now part of
   > the production path. This is the step most likely to go wrong out of
   > habit — "decommission the old server" is exactly the wrong instinct here.

3. Repoint DNS or the reverse proxy from `10.19.71.246:8079` to
   `10.19.75.115:8079`. Updating DNS beats asking everyone to learn a new IP.
4. Watch for 30 minutes:
   ```bash
   journalctl -u talk-to-vi-ippms@prod -u instant-graph-mcp@prod -f
   ```

---

## 8. Rollback

The database never moved and nothing was destructively changed, so rollback is
genuinely trivial — **provided you did not delete the FALCONPRD checkout**:

```bash
# on .115
sudo systemctl stop talk-to-vi-ippms@prod instant-graph-mcp@prod
# on .246 — as before
cd /srv/ippms-assistant
nohup python3 instant_graph_mcp_server_v2_5.py > mcp.log 2>&1 &
sleep 10
nohup python3 talk_to_vi_ippms_updated_6_7_2.py > app.log 2>&1 &
# revert DNS
```

No data reconciliation is needed: both hosts always wrote to the same
Postgres, so anything answered on `.115` is already visible from `.246`.

**Keep the FALCONPRD deployment intact for at least a week.** It costs nothing
and buys a 60-second rollback.

---

## 9. Post-migration

Once a week of clean running has passed:

- [ ] **Rotate `IG_DB_PASSWORD` and `GPU_API_KEY`** — both were plaintext in
      the old source. Update both `.env` files, restart both environments.
- [ ] Remove the `.246` app checkout and its copies of the assets and
      credentials — **but keep squid and the GPU proxy**.
- [ ] Remove the now-unused `.246` rule from `pg_hba.conf`; reload Postgres.
- [ ] Document FALCONPRD as a **production dependency** wherever your team
      tracks that, so nobody reclaims the host.
- [ ] Add monitoring for the two things that fail silently: squid on `:3128`
      and the GPU proxy on `:8071`.
- [ ] Consider a reverse proxy on `.115` fronting `:8079` with TLS and a
      friendly hostname.

---

## 10. Quick reference

| What | Value |
|---|---|
| Source host | `10.19.71.246` (FALCONPRD) — **stays up** |
| Target host | `10.19.75.115` (also the Postgres host) |
| Install path | `/srv/ippms-assistant/{prod,test}` |
| Service user | `ippms` |
| Prod chat UI / ops | `:8079` / `:8060` |
| Test chat UI / ops | `:8179` / `:8160` |
| MCP endpoints | `:8056` / `:8156` — loopback only |
| Postgres | `conv_ai_db`, schemas `tt_vi_ippms_schema{,_test}` — **does not move** |
| Gateway relay | squid CONNECT on `10.19.71.246:3128` |
| GPU proxy | `10.19.71.246:8071` — stays on FALCONPRD |
| Services | `instant-graph-mcp@{prod,test}` → `talk-to-vi-ippms@{prod,test}` |
