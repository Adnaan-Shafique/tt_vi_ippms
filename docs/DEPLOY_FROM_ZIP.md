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

The live processes hold settings that exist nowhere else in a readable form.
Capture them before stopping anything.

```bash
pgrep -af 'talk_to_vi_ippms|instant_graph_mcp'

for pid in $(pgrep -f 'talk_to_vi_ippms|instant_graph_mcp'); do
    echo "=== $pid ==="
    sudo cat /proc/$pid/environ | tr '\0' '\n'
done | tee ~/falconprd-live-env.txt
```

**Check for existing unit files first.** If the output contains
`INVOCATION_ID` or `JOURNAL_STREAM`, these processes are already managed by
systemd, and the real units are better starting points than the templates in
`deploy/`:

```bash
systemctl status <pid> <pid> | head -20      # reveals the unit names
sudo systemctl cat <unit> <unit> | tee ~/ippms-transfer/falconprd-units.txt
```

> `sudo` must do the **reading**. Writing it as
> `sudo tr '\0' '\n' < /proc/$pid/environ` fails with *Permission denied*:
> your shell opens the redirect as your own user before `sudo` ever runs, so
> the elevation applies only to `tr`. Same trap with `>` into a root-owned
> path.

If `sudo cat` is still refused, `ps` reads the same data:

```bash
sudo ps eww -p <pid>
```

Keep that file. Anything in it that differs from `.env.example` is a real
setting you would otherwise lose.

### 1.2 Collect the assets and the env file the zip does not carry

The live env file is the real source of truth for your configuration — more
complete than anything `ps` shows. It is `chmod 600` and owned by `ippms`, so
it needs `sudo` to read:

```bash
sudo cp /etc/ippms-assistant/ippms.env ~/ippms-transfer/
sudo chown $(id -un):$(id -gn) ~/ippms-transfer/ippms.env
chmod 600 ~/ippms-transfer/ippms.env
```

It contains live credentials. Keep it `600`, do not paste it anywhere, and
delete the transfer directory once the migration is done.

```bash
mkdir -p ~/ippms-transfer
cp vi_ippms_tool_kb.md vi_ippms_question_guide.xlsx ~/ippms-transfer/
cp /srv/ippms-assistant/ig_selfsigned.pem ~/ippms-transfer/
ls -la ~/ippms-transfer/
```

### 1.3 Capture exact dependency versions

Use the **service's** venv, not whatever venv your shell has active — they
are usually different, and freezing the wrong one gives you the wrong package
set:

```bash
/srv/ippms-assistant/venv/bin/pip freeze > ~/ippms-transfer/falconprd-freeze.txt
```

### 1.4 Decide how `.115` will install packages

Three possibilities, in order of preference. **Check from `.115`**, not from
FALCONPRD — reachability differs between the two hosts:

```bash
# on .115
curl -sS --max-time 10 https://pypi.org/simple/ -o /dev/null && echo "direct PyPI OK"

# via the corporate proxy, if you use one for pip
curl -sS --max-time 10 --proxy http://10.94.147.19:8080 \
     https://pypi.org/simple/ -o /dev/null && echo "proxied PyPI OK"
```

If either works, skip the wheelhouse and install normally (§3.4), adding
`--proxy http://10.94.147.19:8080` when that is how you reach PyPI.

Only if **neither** works, build a wheelhouse on FALCONPRD:

If PyPI is unreachable, build a wheelhouse on FALCONPRD (which has the working
environment) and carry it across:

```bash
# on .246
/srv/ippms-assistant/venv/bin/pip download \
    -r ~/ippms-transfer/falconprd-freeze.txt -d ~/ippms-transfer/wheelhouse
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
sudo firewall-cmd --permanent --add-port=3128/tcp    # squid relay
sudo firewall-cmd --permanent --add-port=8071/tcp    # GPU proxy
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

> **Why not the corporate proxy?** `10.94.147.19:8080` can reach the gateway
> — it answers `200 Connection established` for `CONNECT 10.34.64.74:5001`.
> We deliberately do not use it. It belongs to another team and was lent for
> downloading Python packages; a production data path must not depend on
> infrastructure we neither own nor get told about when it changes. The
> gateway goes through FALCONPRD, which we control. The corporate proxy is
> used for pip only, at install time, and never appears in a service env file.

### 3.1 Verify both upstreams BEFORE building anything

If either fails, stop — nothing else matters until they pass.

```bash
nc -vz 10.19.71.246 8071      # GPU proxy on FALCONPRD
```

For the gateway, `curl` cannot fully replicate the app's TLS setup: the cert
is self-signed (needing `VERIFY_X509_PARTIAL_CHAIN`) and is reached by IP
while its SAN is a DNS name. A curl `SSL certificate problem: unable to get
local issuer certificate` therefore proves only that CONNECT worked — which
is still the important half. Look for `200 Connection established`:

```bash
curl -sv --max-time 10 --proxy http://10.19.71.246:3128 \
     https://10.34.64.74:5001/api/api/v3/get-hosts 2>&1 | grep -E 'CONNECT|SSL|HTTP/'
```

Once a venv exists (§3.4), verify properly — this mirrors the app's exact
SSL context, pinning and proxy handling:

```bash
set -a; . /etc/ippms-assistant/ippms-prod.env; set +a
/srv/ippms-assistant-v2/prod/.venv/bin/python /srv/ippms-assistant-v2/prod/deploy/check-gateway.py
```

**A `401` is a PASS** — TLS verified and the gateway answered; you simply have
no token.

### 3.2 Create the user and unpack

```bash
# Matches FALCONPRD: service user with a normal home, deploy dir separate.
sudo useradd -r -m -d /home/ippms -s /usr/sbin/nologin ippms
sudo mkdir -p /srv/ippms-assistant-v2/{prod,test,backups}

sudo unzip /tmp/tt_vi_ippms.zip -d /tmp/unpacked
# GitHub zips nest everything under one folder — adjust the path if so:
sudo cp -r /tmp/unpacked/*/. /srv/ippms-assistant-v2/prod/
sudo cp -r /tmp/unpacked/*/. /srv/ippms-assistant-v2/test/

sudo chown -R ippms:ippms /srv/ippms-assistant-v2
sudo chmod +x /srv/ippms-assistant-v2/{prod,test}/deploy/*.sh
```

### 3.3 Place the assets the zip did not carry

```bash
for e in prod test; do
  sudo cp /tmp/ippms-transfer/vi_ippms_tool_kb.md          /srv/ippms-assistant-v2/$e/assets/
  sudo cp /tmp/ippms-transfer/vi_ippms_question_guide.xlsx /srv/ippms-assistant-v2/$e/assets/
  sudo cp /tmp/ippms-transfer/ig_selfsigned.pem            /srv/ippms-assistant-v2/$e/
done

sudo chown -R ippms:ippms /srv/ippms-assistant-v2
sudo chmod 640 /srv/ippms-assistant-v2/{prod,test}/ig_selfsigned.pem
```

### 3.4 Virtualenvs

```bash
for e in prod test; do
  sudo -u ippms "$LIVE_PY" -m venv /srv/ippms-assistant-v2/$e/.venv
done
```

> ⚠ **Do not source the service env file for these pip commands.** It sets
> `HTTPS_PROXY` to the squid relay, which allows only the Instant Graph
> gateway and will refuse PyPI with a `403`. The two proxies serve different
> purposes: squid for the gateway at runtime, the corporate proxy for
> packages at install time. Keep them apart.

With direct PyPI access:

```bash
for e in prod test; do
  sudo -u ippms /srv/ippms-assistant-v2/$e/.venv/bin/pip install \
       -r /tmp/ippms-transfer/falconprd-freeze.txt
done
```

Through the corporate proxy:

```bash
for e in prod test; do
  sudo -u ippms /srv/ippms-assistant-v2/$e/.venv/bin/pip install \
       --proxy http://10.94.147.19:8080 \
       -r /tmp/ippms-transfer/falconprd-freeze.txt
done
```

From the wheelhouse (§1.4):

```bash
for e in prod test; do
  sudo -u ippms /srv/ippms-assistant-v2/$e/.venv/bin/pip install \
       --no-index --find-links=/tmp/ippms-transfer/wheelhouse \
       -r /tmp/ippms-transfer/falconprd-freeze.txt
done
```

Confirm `openpyxl` landed — `pandas.read_excel()` needs it, and losing it
disables RAG *silently*:

```bash
/srv/ippms-assistant-v2/prod/.venv/bin/python -c "import openpyxl, pandas, dash, langgraph, mcp, psycopg2; print('all imports OK')"
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
     -f /srv/ippms-assistant-v2/test/sql/setup_ig_auth_tables.sql
```

### 3.6 Write the two `.env` files

```bash
sudo mkdir -p /etc/ippms-assistant
for e in prod test; do
  sudo cp /srv/ippms-assistant-v2/$e/.env.example /etc/ippms-assistant/ippms-$e.env
  sudo chown ippms:ippms /etc/ippms-assistant/ippms-$e.env
  sudo chmod 600         /etc/ippms-assistant/ippms-$e.env
done
sudo vi /etc/ippms-assistant/ippms-prod.env
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
IG_CA_BUNDLE=/srv/ippms-assistant-v2/prod/ig_selfsigned.pem
IG_CERT_HOSTNAME=ippms.vodafoneidea.com
VI_TOOL_KB_PATH=/srv/ippms-assistant-v2/prod/assets/vi_ippms_tool_kb.md
VI_QUESTION_GUIDE_PATH=/srv/ippms-assistant-v2/prod/assets/vi_ippms_question_guide.xlsx
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
sudo firewall-cmd --permanent --add-port=8179/tcp   # test chat UI
sudo firewall-cmd --reload
```

**Only the chat UIs are published.** `MCP_HOST` and `DASH_HOST` both bind
`127.0.0.1`, matching the FALCONPRD deployment: the MCP endpoint is an
unauthenticated tool surface, and the ops console is an admin surface. Reach
the console over an SSH tunnel when you need it:

```bash
ssh -L 8060:127.0.0.1:8060 you@10.19.75.115     # then http://127.0.0.1:8060/
```

---

## Phase 4 — Verify before installing services

### 4.1 Automated preflight

```bash
/srv/ippms-assistant-v2/prod/deploy/preflight.sh /etc/ippms-assistant/ippms-prod.env
```

Fix every `✗` before continuing.

### 4.2 MCP server, in the foreground

A foreground failure is readable; a systemd one is a journal hunt.

```bash
cd /srv/ippms-assistant-v2/prod
set -a; . ./.env; set +a
sudo -u ippms -E .venv/bin/python src/instant_graph_mcp_server_v2_5.py
```

Expect the banner and
`Connected to Postgres token store at 127.0.0.1:5432/conv_ai_db`.

Now tunnel to the console — it binds loopback, so it is not reachable
directly:

```bash
ssh -L 8060:127.0.0.1:8060 you@10.19.75.115
```

Open `http://127.0.0.1:8060/`, log in with your email + employee id,
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
cd /srv/ippms-assistant-v2/prod
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
SELECT count(*), max(asked_at) FROM tt_vi_ippms_schema.vi_chat_interactions;
SELECT count(*), max(called_at) FROM tt_vi_ippms_schema.ig_tool_call_audit;
```

Both must be rising. Also open the sidebar: **your old conversations should be
there.** They will be — the database never moved — and that is the clearest
single proof nothing was lost.

---

## Phase 5 — Install the services

Only once Phase 4 passes.

```bash
sudo cp /srv/ippms-assistant-v2/prod/deploy/*@.service /etc/systemd/system/
sudo systemctl daemon-reload

sudo systemctl enable --now ippms-mcp@prod && sleep 10
sudo systemctl enable --now ippms-app@prod

sudo systemctl enable --now ippms-mcp@test && sleep 10
sudo systemctl enable --now ippms-app@test

systemctl status 'ippms-mcp@*' 'ippms-app@*' --no-pager
```

**Reboot the box once** and confirm both come back unattended:

```bash
sudo reboot
# then, after it returns:
systemctl status 'ippms-mcp@*' 'ippms-app@*' --no-pager
```

A deployment that only survives while you are watching is not finished.

---

## Phase 6 — Updates without git

`deploy/promote.sh` needs a git checkout with a remote. A zip has no `.git`,
so until `.115` can reach a git remote, promote by directory instead:

```bash
# 1. unpack the new version into test and restart it
sudo -u ippms unzip -o /tmp/tt_vi_ippms-new.zip -d /tmp/new
sudo -u ippms cp -r /tmp/new/*/. /srv/ippms-assistant-v2/test/
sudo systemctl restart ippms-mcp@test && sleep 10
sudo systemctl restart ippms-app@test

# 2. verify at :8179 against the ENVIRONMENTS.md checklist

# 3. back prod up, then copy test over it
sudo tar czf /srv/ippms-assistant-v2/backups/prod-$(date +%F-%H%M).tgz \
     -C /srv/ippms-assistant-v2 prod
sudo -u ippms rsync -a --delete \
     --exclude '.venv' --exclude 'assets' --exclude 'ig_selfsigned.pem' \
     /srv/ippms-assistant-v2/test/ /srv/ippms-assistant-v2/prod/
sudo systemctl restart ippms-mcp@prod && sleep 10
sudo systemctl restart ippms-app@prod
```

The `--exclude`s keep prod's venv and assets from being overwritten by
test's. The env files need no exclude — they live in `/etc/ippms-assistant/`,
outside the checkout, which is exactly why they are kept there.

Rollback is the matching backup tarball.

> Better, when you can: put the repo on an internal git server `.115` can
> reach, `git clone` both environments, and use `deploy/promote.sh <tag>` —
> which byte-compiles before restarting and rolls back automatically. The zip
> flow has neither.

---

## Phase 7 — Cutover

1. Announce a short window.
2. Stop the FALCONPRD **app services only** (they run under systemd — use the
   unit names found in §1.1, not `pkill`, or systemd will restart them):
   ```bash
   # on .246
   sudo systemctl disable --now <mcp-unit> <chat-unit>
   ```
   > **Leave squid and the GPU proxy running.** They are production
   > infrastructure now. This is the step most likely to go wrong out of
   > habit — "decommission the old server" is the wrong instinct here.
3. Repoint DNS or your reverse proxy to `10.19.75.115:8079`.
4. Watch for 30 minutes:
   ```bash
   journalctl -u ippms-app@prod -u ippms-mcp@prod -f
   ```

### Rollback

Both hosts always wrote to the same Postgres, so there is nothing to
reconcile:

```bash
# on .115
sudo systemctl stop ippms-app@prod ippms-mcp@prod
# on .246 — re-enable the original units
sudo systemctl enable --now <mcp-unit> && sleep 10
sudo systemctl enable --now <chat-unit>
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
| Ops console refuses connection | `DASH_HOST` is `127.0.0.1` by design — use the SSH tunnel, §3.7 |
| Test rows landing in the prod schema | `IG_DB_SCHEMA` or `MCP_SERVER_URL` not changed in `ippms-test.env` |
