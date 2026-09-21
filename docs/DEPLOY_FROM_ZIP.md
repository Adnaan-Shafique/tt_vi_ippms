# Deploying from a zip — step by step

For transferring this repo to `10.19.75.115` as a zip rather than a
`git clone`. Follow the phases in order; the ordering is load-bearing in two
places (§1.1 and §1.2) where the information is destroyed if you do it later.

`docs/MIGRATION_10.19.75.115.md` explains *why* each piece is shaped this way.
This file is just the sequence.

---

## ⚠ What the zip does NOT contain

The three files the app needs most are **gitignored**, so they are not in the
zip. Copying only the zip is the single most common way this deployment fails.

| File | Why it is not in git | Without it |
|---|---|---|
| `assets/vi_ippms_tool_kb.md` | data, not code | startup logs `tool KB MISSING` |
| `assets/vi_ippms_question_guide.xlsx` | binary | **app starts fine, RAG silently disabled** |
| `ig_selfsigned.pem` | it is a credential | every upstream call fails cert verification |
| `.env` | it holds secrets | nothing starts |

Copy the first three **separately from FALCONPRD** (§1.2). Build `.env` from
`.env.example` on the target (§3.4).

Also: if you download the zip from GitHub's "Download ZIP" button it contains
**no `.git` directory**, so `deploy/promote.sh` will not work — see §6.

---

## Phase 1 — On FALCONPRD `10.19.71.246`, before anything else

### 1.1 Capture the live environment ►► DO THIS FIRST

You run under `nohup`, so any variable exported in that shell exists **only**
in the running process. It is in neither the source nor a unit file. Stopping
the process destroys it permanently.

```bash
pgrep -af 'talk_to_vi_ippms|instant_graph_mcp'

for pid in $(pgrep -f 'talk_to_vi_ippms|instant_graph_mcp'); do
    echo "=== $pid ==="
    sudo tr '\0' '\n' < /proc/$pid/environ
done | tee ~/falconprd-live-env.txt
```

Keep that file. Anything in it that differs from `.env.example` is a real
setting you would otherwise lose.

### 1.2 Collect the assets the zip does not carry

```bash
mkdir -p ~/ippms-transfer
cp vi_ippms_tool_kb.md vi_ippms_question_guide.xlsx ~/ippms-transfer/
cp /srv/ippms-assistant/ig_selfsigned.pem ~/ippms-transfer/
ls -la ~/ippms-transfer/
```

### 1.3 Capture exact dependency versions

```bash
pip freeze > ~/ippms-transfer/falconprd-freeze.txt
```

### 1.4 Build a wheelhouse if `.115` has no internet

`.115` cannot reach the Instant Graph gateway, so assume it cannot reach PyPI
either. **Check first** — this determines whether you need this step:

```bash
# on .115
curl -sS --max-time 10 https://pypi.org/simple/ -o /dev/null && echo "PyPI reachable" || echo "NO PyPI — wheelhouse needed"
```

If PyPI is unreachable, build a wheelhouse on FALCONPRD (which has the working
environment) and carry it across:

```bash
# on .246
pip download -r ~/ippms-transfer/falconprd-freeze.txt -d ~/ippms-transfer/wheelhouse
du -sh ~/ippms-transfer/wheelhouse
```

If `.246` also has no internet, copy the wheels straight out of its venv
instead — or ask for an internal PyPI mirror URL. Do not discover this on
`.115` at install time.

### 1.5 Stand up the squid relay

`.115` has no route to the gateway. Everything downstream depends on this.

```bash
# on .246 — the config is in the zip at deploy/relay/squid-ig-relay.conf
sudo dnf install -y squid                  # or: apt install squid
sudo cp deploy/relay/squid-ig-relay.conf /etc/squid/conf.d/ig-relay.conf
sudo squid -k parse                        # must print no errors
sudo systemctl enable --now squid
sudo firewall-cmd --permanent --add-port=3128/tcp
sudo firewall-cmd --permanent --add-port=8071/tcp    # GPU proxy, for .115
sudo firewall-cmd --reload
```

Confirm the GPU proxy is not loopback-only — it has only ever served
localhost, so a `127.0.0.1` bind is likely and would refuse `.115`:

```bash
ss -lntp | grep 8071     # want 0.0.0.0:8071 or *:8071 — NOT 127.0.0.1:8071
```

If it is loopback-only, change its bind address and restart it.

> **Do not stop the app processes yet.** FALCONPRD keeps serving users until
> §7. And squid + the GPU proxy stay running **permanently** — they are part
> of the production path now.

---

## Phase 2 — Transfer

```bash
# from wherever you made the zip
scp tt_vi_ippms.zip           you@10.19.75.115:/tmp/
scp -r ~/ippms-transfer       you@10.19.75.115:/tmp/
```

---

## Phase 3 — Install on `10.19.75.115`

### 3.1 Verify the relay works BEFORE building anything

If this fails, stop — nothing else matters until it passes.

```bash
curl -sv --max-time 10 --proxy http://10.19.71.246:3128 \
     https://10.34.64.74:5001/api/api/v3/get-hosts 2>&1 \
     | grep -E 'CONNECT|SSL|subject|HTTP/'

nc -vz 10.19.71.246 8071      # GPU proxy
```

You want the CONNECT tunnel to establish and the TLS handshake to complete.
**A `401` from the gateway is expected and fine** — you have no token yet.
What you are proving is that the tunnel opens and the cert verifies.

### 3.2 Create the user and unpack

```bash
sudo useradd -r -m -d /srv/ippms-assistant -s /usr/sbin/nologin ippms
sudo mkdir -p /srv/ippms-assistant/{prod,test,backups}

sudo unzip /tmp/tt_vi_ippms.zip -d /tmp/unpacked
# GitHub zips nest everything under one folder — adjust the path if so:
sudo cp -r /tmp/unpacked/*/. /srv/ippms-assistant/prod/
sudo cp -r /tmp/unpacked/*/. /srv/ippms-assistant/test/

sudo chown -R ippms:ippms /srv/ippms-assistant
sudo chmod +x /srv/ippms-assistant/{prod,test}/deploy/*.sh
```

### 3.3 Place the assets the zip did not carry

```bash
for e in prod test; do
  sudo cp /tmp/ippms-transfer/vi_ippms_tool_kb.md          /srv/ippms-assistant/$e/assets/
  sudo cp /tmp/ippms-transfer/vi_ippms_question_guide.xlsx /srv/ippms-assistant/$e/assets/
  sudo cp /tmp/ippms-transfer/ig_selfsigned.pem            /srv/ippms-assistant/$e/
done

sudo chown -R ippms:ippms /srv/ippms-assistant
sudo chmod 640 /srv/ippms-assistant/{prod,test}/ig_selfsigned.pem
```

### 3.4 Virtualenvs

```bash
for e in prod test; do
  sudo -u ippms python3 -m venv /srv/ippms-assistant/$e/.venv
done
```

With internet:

```bash
for e in prod test; do
  sudo -u ippms /srv/ippms-assistant/$e/.venv/bin/pip install \
       -r /tmp/ippms-transfer/falconprd-freeze.txt
done
```

From the wheelhouse (§1.4):

```bash
for e in prod test; do
  sudo -u ippms /srv/ippms-assistant/$e/.venv/bin/pip install \
       --no-index --find-links=/tmp/ippms-transfer/wheelhouse \
       -r /tmp/ippms-transfer/falconprd-freeze.txt
done
```

Confirm `openpyxl` landed — `pandas.read_excel()` needs it, and losing it
disables RAG *silently*:

```bash
/srv/ippms-assistant/prod/.venv/bin/python -c "import openpyxl, pandas, dash, langgraph, mcp, psycopg2; print('all imports OK')"
```

### 3.5 Database

Postgres is already on this box, so no data moves. Confirm you can reach it
**from the box itself** — the existing `pg_hba.conf` has a rule for `.246`,
which is a different source address and may not cover loopback:

```bash
psql -h 127.0.0.1 -U ig_app_user -d conv_ai_db -c '\dt tt_vi_ippms_schema.*'
```

If that is refused, add a loopback rule and reload:

```
host    conv_ai_db    ig_app_user    127.0.0.1/32    scram-sha-256
```

```bash
sudo systemctl reload postgresql
```

Then create the **test** schema (its auth tables do not auto-create):

```bash
psql -h 127.0.0.1 -U ig_app_user -d conv_ai_db \
     -v schema=tt_vi_ippms_schema_test \
     -f /srv/ippms-assistant/test/sql/setup_ig_auth_tables.sql
```

### 3.6 Write the two `.env` files

```bash
for e in prod test; do
  sudo -u ippms cp /srv/ippms-assistant/$e/.env.example /srv/ippms-assistant/$e/.env
  sudo -u ippms chmod 600 /srv/ippms-assistant/$e/.env
done
sudo -u ippms vi /srv/ippms-assistant/prod/.env
```

Cross-check against `~/falconprd-live-env.txt` from §1.1 — anything set there
that differs from the template is a real setting.

**prod:**

```bash
IG_DB_HOST=127.0.0.1
IG_DB_PASSWORD=<real>            # ►► no source fallback exists any more
GPU_API_KEY=<real>               # ►► no source fallback exists any more
HTTPS_PROXY=http://10.19.71.246:3128
NO_PROXY=127.0.0.1,localhost,10.19.71.246:8071,10.19.75.115
GPU_PROXY_URL=http://10.19.71.246:8071/v1/infer
IG_CA_BUNDLE=/srv/ippms-assistant/prod/ig_selfsigned.pem
IG_CERT_HOSTNAME=ippms.vodafoneidea.com
VI_TOOL_KB_PATH=/srv/ippms-assistant/prod/assets/vi_ippms_tool_kb.md
VI_QUESTION_GUIDE_PATH=/srv/ippms-assistant/prod/assets/vi_ippms_question_guide.xlsx
```

**test** — same, but change **all six**, and every path `prod` → `test`:

```bash
IG_DB_SCHEMA=tt_vi_ippms_schema_test
IG_DB_SESSION_KEY=test
MCP_PORT=8156
MCP_SERVER_URL=http://127.0.0.1:8156/mcp     # ►► the one people forget
DASH_PORT=8160
VI_APP_PORT=8179
```

> Miss `MCP_SERVER_URL` and your test chat app drives the **production** MCP
> server — writing to the prod audit table and sharing prod's tokens — while
> every port looks correctly separated.

### 3.7 Firewall

```bash
sudo firewall-cmd --permanent --add-port=8079/tcp   # prod chat UI
sudo firewall-cmd --permanent --add-port=8060/tcp   # prod ops console
sudo firewall-cmd --permanent --add-port=8179/tcp   # test chat UI
sudo firewall-cmd --permanent --add-port=8160/tcp   # test ops console
sudo firewall-cmd --reload
```

Leave `8056`/`8156` closed — the MCP servers bind loopback and expose the
whole tool surface unauthenticated.

---

## Phase 4 — Verify before installing services

### 4.1 Automated preflight

```bash
/srv/ippms-assistant/prod/deploy/preflight.sh /srv/ippms-assistant/prod/.env
```

Fix every `✗` before continuing.

### 4.2 MCP server, in the foreground

A foreground failure is readable; a systemd one is a journal hunt.

```bash
cd /srv/ippms-assistant/prod
set -a; . ./.env; set +a
sudo -u ippms -E .venv/bin/python src/instant_graph_mcp_server_v2_5.py
```

Expect the banner and
`Connected to Postgres token store at 127.0.0.1:5432/conv_ai_db`.

Now open `http://10.19.75.115:8060/`, log in with your email + employee id,
and walk the explorer: **host → component → interface → KPI → historical
data**. This one action proves the relay, the TLS pinning, the token manager
and the database all work from this host. If data renders, the hard part is
done.

### 4.3 GPU proxy — check explicitly

```bash
curl -s --noproxy '*' -X POST "$GPU_PROXY_URL" \
  -H "Content-Type: application/json" -H "X-API-Key: $GPU_API_KEY" \
  -d '{"model":"mistral","prompt":"SYSTEM:\nreply OK\n\nUSER:\nping\n\nASSISTANT:\n","max_new_tokens":8}'
```

A JSON body with a `text` field means you are good. **Do not skip this.**
`GPULLMClient.infer()` never raises — it returns `""` on failure. A dead or
unreachable proxy does not crash anything; it degrades into wrong-looking
routing and empty answers, which is much harder to diagnose later than a
crash. The call now crosses the network, so raise `GPU_TIMEOUT` if you see
timeouts.

### 4.4 Chat app, in the foreground

```bash
cd /srv/ippms-assistant/prod
set -a; . ./.env; set +a
sudo -u ippms -E .venv/bin/python src/talk_to_vi_ippms_updated_6_7_2.py
```

**Read every field of the startup line — it is your checklist:**

```
[STARTUP] Discovered 8 MCP tools.
[STARTUP] question guide loaded: N rows indexed for retrieval.
[STARTUP] tool KB loaded, question guide N rows, logging ready,
          user_feedback ready, chat_history ready, glossary ready.
```

Anything reading `MISSING`, `disabled`, or `Discovered 0 MCP tools` means an
asset or the database did not come across. **Do not go live on a degraded
startup line** — every one of those failures is silent at runtime.

### 4.5 Smoke test

At `http://10.19.75.115:8079/`, run the six-question checklist in
`docs/ENVIRONMENTS.md`. Then confirm the side effects:

```sql
SELECT count(*), max(created_at) FROM tt_vi_ippms_schema.vi_chat_interactions;
SELECT count(*), max(created_at) FROM tt_vi_ippms_schema.ig_tool_call_audit;
```

Both must be rising. Also open the sidebar: **your old conversations should be
there.** They will be — the database never moved — and that is the clearest
single proof nothing was lost.

---

## Phase 5 — Install the services

Only once Phase 4 passes.

```bash
sudo cp /srv/ippms-assistant/prod/deploy/*@.service /etc/systemd/system/
sudo systemctl daemon-reload

sudo systemctl enable --now instant-graph-mcp@prod && sleep 10
sudo systemctl enable --now talk-to-vi-ippms@prod

sudo systemctl enable --now instant-graph-mcp@test && sleep 10
sudo systemctl enable --now talk-to-vi-ippms@test

systemctl status 'instant-graph-mcp@*' 'talk-to-vi-ippms@*' --no-pager
```

**Reboot the box once** and confirm both come back unattended:

```bash
sudo reboot
# then, after it returns:
systemctl status 'instant-graph-mcp@*' 'talk-to-vi-ippms@*' --no-pager
```

A deployment that only survives while you are watching is not finished — and
that is exactly the failure mode `nohup` had.

---

## Phase 6 — Updates without git

`deploy/promote.sh` needs a git checkout with a remote. A zip has no `.git`,
so until `.115` can reach a git remote, promote by directory instead:

```bash
# 1. unpack the new version into test and restart it
sudo -u ippms unzip -o /tmp/tt_vi_ippms-new.zip -d /tmp/new
sudo -u ippms cp -r /tmp/new/*/. /srv/ippms-assistant/test/
sudo systemctl restart instant-graph-mcp@test && sleep 10
sudo systemctl restart talk-to-vi-ippms@test

# 2. verify at :8179 against the ENVIRONMENTS.md checklist

# 3. back prod up, then copy test over it
sudo tar czf /srv/ippms-assistant/backups/prod-$(date +%F-%H%M).tgz \
     -C /srv/ippms-assistant prod
sudo -u ippms rsync -a --delete \
     --exclude '.venv' --exclude '.env' --exclude 'assets' --exclude 'ig_selfsigned.pem' \
     /srv/ippms-assistant/test/ /srv/ippms-assistant/prod/
sudo systemctl restart instant-graph-mcp@prod && sleep 10
sudo systemctl restart talk-to-vi-ippms@prod
```

The `--exclude`s matter: they are what keeps prod's own `.env`, venv and
assets from being overwritten by test's.

Rollback is the matching backup tarball.

> Better, when you can: put the repo on an internal git server `.115` can
> reach, `git clone` both environments, and use `deploy/promote.sh <tag>` —
> which byte-compiles before restarting and rolls back automatically. The zip
> flow has neither.

---

## Phase 7 — Cutover

1. Announce a short window.
2. Stop the FALCONPRD **app processes only**:
   ```bash
   # on .246
   pkill -f talk_to_vi_ippms
   pkill -f instant_graph_mcp
   crontab -l      # remove any @reboot entry that would restart them
   ```
   > **Leave squid and the GPU proxy running.** They are production
   > infrastructure now. This is the step most likely to go wrong out of
   > habit — "decommission the old server" is the wrong instinct here.
3. Repoint DNS or your reverse proxy to `10.19.75.115:8079`.
4. Watch for 30 minutes:
   ```bash
   journalctl -u talk-to-vi-ippms@prod -u instant-graph-mcp@prod -f
   ```

### Rollback

Both hosts always wrote to the same Postgres, so there is nothing to
reconcile:

```bash
# on .115
sudo systemctl stop talk-to-vi-ippms@prod instant-graph-mcp@prod
# on .246, as before
cd /srv/ippms-assistant
nohup python3 instant_graph_mcp_server_v2_5.py > mcp.log 2>&1 &
sleep 10
nohup python3 talk_to_vi_ippms_updated_6_7_2.py > app.log 2>&1 &
# revert DNS
```

**Keep the FALCONPRD app files for at least a week.** They cost nothing and
buy a 60-second rollback.

---

## Phase 8 — Afterwards

- [ ] **Rotate `IG_DB_PASSWORD` and `GPU_API_KEY`.** Both were plaintext in
      the old source files. Update both `.env`s, restart both environments.
- [ ] Delete `/tmp/ippms-transfer` — it holds the PEM and the wheelhouse.
- [ ] Remove the app checkout and credential copies from `.246`, keeping
      squid and the GPU proxy.
- [ ] Remove the stale `.246` rule from `pg_hba.conf`; reload Postgres.
- [ ] Record FALCONPRD as a **production dependency** wherever your team
      tracks that, so nobody reclaims the host.
- [ ] Monitor the two things that fail silently: squid `:3128` and the GPU
      proxy `:8071`.

---

## If something is wrong

| Symptom | Cause |
|---|---|
| `SSLCertVerificationError` | `IG_CA_BUNDLE` path wrong, or `IG_CERT_HOSTNAME` unset |
| `403` from the relay | squid ACL — check the source IP and that `5001` is in `SSL_ports` |
| `Discovered 0 MCP tools` | MCP server not up, or `MCP_SERVER_URL` port wrong |
| Answers vague / routing odd, no errors | GPU proxy unreachable — `infer()` returns `""` silently. §4.3 |
| `question guide MISSING` | asset not copied, or `openpyxl` missing |
| Postgres auth failure | `pg_hba.conf` has no loopback rule — §3.5 |
| Test rows landing in the prod schema | `IG_DB_SCHEMA` or `MCP_SERVER_URL` not changed in `test/.env` |
