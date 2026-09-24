# Running the repo on FALCONPRD, alongside the live app

Stand the repo-managed deployment up on `10.19.71.246` as the **`test`
instance**, running beside the existing live services without touching them.

Do this before the `10.19.75.115` migration. It validates the units, the env
layout, `preflight.sh` and `check-gateway.py` on a host where the networking
already works, so when you do move, the only new variables are connectivity
and firewall rules.

It is also simpler here than on `.115`: FALCONPRD reaches the gateway
directly and the GPU proxy is local, so **there is no relay and no
`HTTPS_PROXY` at all**.

---

## What must not be disturbed

| Live, leave alone | |
|---|---|
| Services | `ippms-mcp.service`, `ippms-app.service` |
| Chat UI | `:8079` |
| Ops console | `:8060` |
| MCP | `:8056` |
| Code | `/srv/ippms-assistant/*.py` (flat) |
| venv | `/srv/ippms-assistant/venv` |
| Env file | `/etc/ippms-assistant/ippms.env` |
| DB schema | `tt_vi_ippms_schema` |

The new instance avoids every one of those:

| New `test` instance | |
|---|---|
| Services | `ippms-mcp@test.service`, `ippms-app@test.service` |
| Chat UI | `:8179` |
| Ops console | `:8160` |
| MCP | `:8156` |
| Code | `/srv/ippms-assistant-v2/test/` |
| venv | `/srv/ippms-assistant-v2/test/.venv` |
| Env file | `/etc/ippms-assistant/ippms-test.env` |
| DB schema | `tt_vi_ippms_schema_test` |

systemd treats `ippms-mcp.service` and `ippms-mcp@test.service` as entirely
separate units, so there is no name collision.

The new instance lives in a **separate root**, `/srv/ippms-assistant-v2`, so
nothing below ever writes inside the live deployment's directory. That is
worth more than it looks: the live deployment is flat in
`/srv/ippms-assistant`, so had the new instance been a subdirectory of it,
any `chown -R`, `rsync --delete` or `rm -rf` aimed at the parent would have
hit the running application. With separate roots, that class of mistake is
not available.

The only thing read from `/srv/ippms-assistant` is the assets in step 3 and
the package list in step 4 — both copies, never moves.

---

## 1. Check the ports are free

```bash
ss -lnt | grep -E ':(8156|8160|8179)\b'     # expect NO output
```

Anything here, pick different ports and change them consistently in step 5.

## 2. Unpack the repo into a subdirectory

```bash
sudo mkdir -p /srv/ippms-assistant-v2/{test,backups}
sudo unzip /tmp/tt_vi_ippms.zip -d /tmp/unpacked
sudo cp -r /tmp/unpacked/*/. /srv/ippms-assistant-v2/test/

sudo chown -R ippms:ippms /srv/ippms-assistant-v2
sudo chmod +x /srv/ippms-assistant-v2/test/deploy/*.sh
```

## 3. Copy the assets from the live deployment

They are gitignored, so the zip does not contain them. Copy, do not move —
the live app is using them:

```bash
sudo cp /srv/ippms-assistant/vi_ippms_tool_kb.md \
        /srv/ippms-assistant/vi_ippms_question_guide.xlsx \
        /srv/ippms-assistant-v2/test/assets/
sudo cp /srv/ippms-assistant/ig_selfsigned.pem /srv/ippms-assistant-v2/test/

sudo chown -R ippms:ippms /srv/ippms-assistant-v2/test
sudo chmod 640 /srv/ippms-assistant-v2/test/ig_selfsigned.pem
```

## 4. Build the venv

A separate venv from the live one, so upgrading here cannot affect production.

> ### ⚠ Build it with the SAME interpreter the live service uses
>
> `sudo` resets `PATH`, so `sudo -u ippms python3 -m venv` resolves to
> `/usr/bin/python3` — on RHEL 8 that is **Python 3.6**, not whatever your
> login shell has. A 3.6 venv installs nothing useful here (`langgraph` and
> `mcp` need ≥3.10) and fails with a misleading
> `No matching distribution found ... (from versions: )` from the ancient
> pip 9.0.3 that 3.6 ships, rather than a clear "wrong Python" error.
>
> Derive the interpreter from the running service instead of trusting
> `python3`:
>
> ```bash
> LIVE_PY=$(readlink -f /srv/ippms-assistant/venv/bin/python)
> echo "$LIVE_PY"          # FALCONPRD: /usr/bin/python3.12
> "$LIVE_PY" --version     # FALCONPRD: Python 3.12.1
> ```

```bash
sudo -u ippms "$LIVE_PY" -m venv /srv/ippms-assistant-v2/test/.venv
/srv/ippms-assistant-v2/test/.venv/bin/python --version   # must match the live venv

# pip 9 cannot resolve modern wheels; upgrade inside the venv first.
# -H gives pip a writable cache (without it sudo keeps YOUR $HOME).
sudo -H -u ippms /srv/ippms-assistant-v2/test/.venv/bin/pip install \
     --proxy http://10.94.147.19:8080 --upgrade pip setuptools wheel
First capture what the live app actually runs — from the **service's** venv,
not whatever your shell has active:

```bash
/srv/ippms-assistant/venv/bin/pip freeze > /tmp/live-freeze.txt
```

Then install the same set:

```bash
sudo -H -u ippms /srv/ippms-assistant-v2/test/.venv/bin/pip install \
     --proxy http://10.94.147.19:8080 \
     -r /tmp/live-freeze.txt
```

Confirm. The strongest check is that the new environment is **package-identical**
to what is serving production — an empty diff is the point of staging here:

```bash
diff <(/srv/ippms-assistant/venv/bin/pip freeze) \
     <(/srv/ippms-assistant-v2/test/.venv/bin/pip freeze)
```

Then the imports, especially `openpyxl` — without it the question guide fails
to load and RAG is disabled *silently*:

```bash
/srv/ippms-assistant-v2/test/.venv/bin/python -c \
  "import openpyxl,pandas,dash,langgraph,mcp,psycopg2;print('imports OK')"
```

## 5. Env file

Start from the live one so every real setting carries over:

```bash
sudo cp /etc/ippms-assistant/ippms.env /etc/ippms-assistant/ippms-test.env
sudo chown ippms:ippms /etc/ippms-assistant/ippms-test.env
sudo chmod 600         /etc/ippms-assistant/ippms-test.env
sudo vi /etc/ippms-assistant/ippms-test.env
```

Change **exactly these**. Everything else stays as the live app has it:

```bash
# --- isolation from the live instance ---
IG_DB_SCHEMA=tt_vi_ippms_schema_test
IG_DB_SESSION_KEY=test            # or the live console invalidates this one's token
MCP_PORT=8156
MCP_SERVER_URL=http://127.0.0.1:8156/mcp    # ►► forget this and you drive LIVE's MCP
DASH_PORT=8160
VI_APP_PORT=8179

# --- paths, now under test/ ---
IG_CA_BUNDLE=/srv/ippms-assistant-v2/test/ig_selfsigned.pem
VI_TOOL_KB_PATH=/srv/ippms-assistant-v2/test/assets/vi_ippms_tool_kb.md
VI_QUESTION_GUIDE_PATH=/srv/ippms-assistant-v2/test/assets/vi_ippms_question_guide.xlsx
```

**Leave these as the live file has them** — they are what makes FALCONPRD
simple:

```bash
IG_DB_HOST=10.19.75.115                       # the DB is remote from here
GPU_PROXY_URL=http://127.0.0.1:8071/v1/infer  # GPU is local on this host
MCP_HOST=127.0.0.1
DASH_HOST=127.0.0.1
```

> **Do not add `HTTPS_PROXY` / `NO_PROXY` on FALCONPRD.** They exist only for
> `.115`, which has no route to the gateway. This host reaches
> `10.34.64.74:5001` directly, and pointing `HTTPS_PROXY` at a squid that is
> not installed will break every upstream call. `.env.example` ships with them
> set for the `.115` case — if you copy from it rather than from the live env
> file, remove them.

## 6. Create the test schema

Its two auth tables do not auto-create, and the **schema itself needs an
admin role** — `ig_app_user` has no CREATE on the database, and Postgres
checks that privilege before it checks existence, so even
`CREATE SCHEMA IF NOT EXISTS` fails.

First check how the prod schema is set up, then match it:

```bash
psql -h 10.19.75.115 -U ig_app_user -d conv_ai_db -c '\dn+ tt_vi_ippms_schema'
```

As an admin role, once:

```bash
psql -h 10.19.75.115 -U <admin> -d conv_ai_db -c \
  'CREATE SCHEMA IF NOT EXISTS tt_vi_ippms_schema_test AUTHORIZATION ig_app_user;'
```

Then the tables, as the app user:

```bash
psql -h 10.19.75.115 -U ig_app_user -d conv_ai_db \
     -v schema=tt_vi_ippms_schema_test \
     -f /srv/ippms-assistant-v2/test/sql/setup_ig_auth_tables.sql

psql -h 10.19.75.115 -U ig_app_user -d conv_ai_db -c '\dt tt_vi_ippms_schema_test.*'
```

Want `ig_auth_sessions` and `ig_auth_login_audit`.

No `psql` on FALCONPRD? Install `postgresql` (client only), or run the file
from `.115` where the server lives.

> That SQL is **reconstructed** from the queries in `TokenManager`. Diff it
> against your original `setup_ig_auth_tables.sql` first.

## 7. Firewall for the new chat UI

```bash
sudo firewall-cmd --permanent --add-port=8179/tcp
sudo firewall-cmd --reload
```

`8156` and `8160` stay closed — both bind loopback.

---

## 8. Verify before installing the units

```bash
cd /srv/ippms-assistant-v2/test
set -a; . /etc/ippms-assistant/ippms-test.env; set +a

.venv/bin/python deploy/check-gateway.py          # a 401 is a PASS
deploy/preflight.sh /etc/ippms-assistant/ippms-test.env
```

`check-gateway.py` should pass with no proxy configured — that is the point
of running here first.

Then both processes in the foreground, MCP first:

```bash
sudo -u ippms -E .venv/bin/python src/instant_graph_mcp_server_v2_5.py
# second terminal, same two `set -a` lines:
sudo -u ippms -E .venv/bin/python src/talk_to_vi_ippms_updated_6_7_2.py
```

**Read the whole startup line.** Anything `MISSING`, `disabled` or
`Discovered 0 MCP tools` is a stop:

```
[STARTUP] Discovered 8 MCP tools.
[STARTUP] question guide loaded: N rows indexed for retrieval.
[STARTUP] tool KB loaded, question guide N rows, logging ready, ...
```

While they run, confirm the live app is **still serving** on `:8079` and that
you have not moved its files:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8079/
systemctl is-active ippms-mcp ippms-app
```

## 9. Smoke test

Ops console over a tunnel (it binds loopback):

```bash
ssh -L 8160:127.0.0.1:8160 SNENRC@10.19.71.246    # then http://127.0.0.1:8160/
```

Then the chat UI at `http://10.19.71.246:8179/` and the six-question
checklist in `docs/ENVIRONMENTS.md`.

Now prove the isolation actually holds — this is the whole point of the
exercise:

```sql
-- the NEW instance's rows land here
SELECT count(*), max(asked_at) FROM tt_vi_ippms_schema_test.vi_chat_interactions;
SELECT count(*), max(called_at) FROM tt_vi_ippms_schema_test.ig_tool_call_audit;

-- and the LIVE schema keeps only its own traffic
SELECT count(*), max(asked_at) FROM tt_vi_ippms_schema.vi_chat_interactions;
```

If your test questions appear in `tt_vi_ippms_schema` instead, `IG_DB_SCHEMA`
or `MCP_SERVER_URL` did not get changed in step 5. Fix it before going
further — it means the new instance is driving the live MCP server.

## 10. Install the units

```bash
sudo cp /srv/ippms-assistant-v2/test/deploy/ippms-mcp@.service \
        /srv/ippms-assistant-v2/test/deploy/ippms-app@.service /etc/systemd/system/
sudo systemctl daemon-reload

sudo systemctl enable --now ippms-mcp@test && sleep 10
sudo systemctl enable --now ippms-app@test

systemctl status ippms-mcp ippms-app ippms-mcp@test ippms-app@test --no-pager
```

All four active. Watch only the new pair:

```bash
journalctl -u ippms-mcp@test -u ippms-app@test -f
```

---

## What this leaves you with

FALCONPRD now runs both the legacy flat deployment and a repo-managed
instance side by side, sharing the same gateway, GPU proxy and database
server while writing to separate schemas. You can iterate on the repo
version at `:8179` without touching `:8079`.

When you later migrate to `.115`, the only genuinely new work is:

1. connectivity — the squid relay, `HTTPS_PROXY`/`NO_PROXY`, firewall rules;
2. a loopback `pg_hba.conf` rule, since the DB becomes local there;
3. promoting this instance's configuration from `test` to `prod`.

Everything else — units, env layout, asset paths, the verification scripts —
will already have been exercised here.

## Removing it

```bash
sudo systemctl disable --now ippms-app@test ippms-mcp@test
sudo rm /etc/systemd/system/ippms-{mcp,app}@.service
sudo systemctl daemon-reload
sudo rm -rf /srv/ippms-assistant-v2/test          # ◄ the /test suffix is essential
sudo rm /etc/ippms-assistant/ippms-test.env
```

Optionally `DROP SCHEMA tt_vi_ippms_schema_test CASCADE;`. The live
deployment is untouched throughout.
