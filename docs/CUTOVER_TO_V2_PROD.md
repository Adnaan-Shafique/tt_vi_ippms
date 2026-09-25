# Cutover: old deployment → v2 on production (`:8079`)

**This is a one-time migration, not a promote.** `deploy/promote.sh` moves an
existing `/srv/ippms-assistant-v2/prod` git checkout between tags. That
checkout does not exist yet, and this deployment was transferred by zip rather
than cloned, so the script does not apply. Use `promote.sh` for *subsequent*
releases, once prod is a git checkout.

What changes: the live chat UI on `:8079` stops being served by
`/srv/ippms-assistant` (units `ippms-mcp` / `ippms-app`) and starts being
served by `/srv/ippms-assistant-v2/prod` (units `ippms-mcp@prod` /
`ippms-app@prod`).

**There is downtime**, because both stacks want ports 8079/8056/8060 and only
one can hold them. Budget a minute or two.

**The old deployment is not deleted.** That is the rollback.

---

## What production gains, and the one thing to look at first

Roles, the SME application workflow, the admin dashboard — and **glossary
injection**, which is the one with teeth.

Until now `vi_glossary_terms` in the prod schema has been write-only: SMEs have
been adding terms and none of them affected an answer. After this cutover every
one of those definitions starts steering routing and phrasing. Read the table
before you start, so nothing in it is a surprise:

```bash
sudo -u ippms psql -h 10.19.75.115 -U ig_app_user -d conv_ai_db -c \
"SELECT term, full_form, left(definition,70) AS definition, filled_by, updated_at
   FROM tt_vi_ippms_schema.vi_glossary_terms ORDER BY updated_at DESC;"
```

If anything there is a joke, a test entry or plain wrong, delete it now — it is
about to become production behaviour. Injection is capped at 6 definitions per
question and only fires on whole-word matches, but a wrong definition that
matches is still a wrong definition.

---

## 1. Pre-flight — nothing here changes anything

Run all of it before touching a service. Any failure is a reason to stop.

```bash
# a) Can the app user create tables in the prod schema? The new
#    vi_sme_requests table is created at startup; if this is false, SME
#    approvals silently stay disabled.
sudo -u ippms psql -h 10.19.75.115 -U ig_app_user -d conv_ai_db -tAc \
  "SELECT has_schema_privilege('ig_app_user','tt_vi_ippms_schema','CREATE');"
#    -> must print t.  If f, run sql/setup_sme_requests.sql as an admin role
#       first, and expect the three ALTERs in step 5 to need the same.

# b) Schema snapshot, for comparison if anything looks wrong later.
#    Schema-only on purpose: the migrations are additive (three nullable
#    columns + one new table) and touch no existing row, and a full dump of
#    ig_tool_call_audit is ~1.09M rows you do not need.
sudo -u ippms pg_dump -h 10.19.75.115 -U ig_app_user -d conv_ai_db \
  --schema-only -n tt_vi_ippms_schema \
  > /srv/ippms-assistant-v2/backups/prod_schema_$(date +%Y%m%d_%H%M).sql

# c) Write down exactly what is running now, so "what did it look like
#    before?" is answerable at 2am.
systemctl status ippms-mcp ippms-app --no-pager | head -20
ss -lntp | grep -E ':(8056|8060|8079)\b'
sudo -u ippms psql -h 10.19.75.115 -U ig_app_user -d conv_ai_db -tAc \
  "SELECT count(*), max(asked_at) FROM tt_vi_ippms_schema.vi_chat_interactions;"
```

---

## 2. Build the new prod tree — still no impact on the running service

Copy from the **test tree you have actually been running**, not from a fresh
zip: it is the exact code you validated, and it already carries the assets and
the certificate, which are gitignored.

```bash
sudo mkdir -p /srv/ippms-assistant-v2/{prod,backups}

# Everything except the virtualenv — a venv hardcodes absolute paths in
# bin/ and pyvenv.cfg, so a copied one points back at test.
sudo rsync -a --exclude '.venv' --exclude '__pycache__' \
  /srv/ippms-assistant-v2/test/ /srv/ippms-assistant-v2/prod/

sudo chown -R ippms:ippms /srv/ippms-assistant-v2/prod
sudo chmod +x /srv/ippms-assistant-v2/prod/deploy/*.sh
sudo chmod 640 /srv/ippms-assistant-v2/prod/ig_selfsigned.pem

# Confirm the pieces that are not in git made it across.
ls -l /srv/ippms-assistant-v2/prod/assets/ /srv/ippms-assistant-v2/prod/ig_selfsigned.pem
ls -l /srv/ippms-assistant-v2/prod/config/roles.yaml
```

### The virtualenv

Build it from the interpreter the **live** deployment is using, not from
whatever `python3` resolves to under sudo — `sudo` resets PATH, and on this
host that lands on 3.6.8, whose pip cannot install the requirements. The error
it gives ("No matching distribution found ... from versions: ") does not
mention the Python version at all.

```bash
PY=$(readlink -f /srv/ippms-assistant/venv/bin/python)   # expect /usr/bin/python3.12
echo "$PY"; "$PY" --version

sudo -u ippms -H "$PY" -m venv /srv/ippms-assistant-v2/prod/.venv
sudo -u ippms -H /srv/ippms-assistant-v2/prod/.venv/bin/python -m pip install \
  --upgrade pip --proxy http://10.94.147.19:8080
sudo -u ippms -H /srv/ippms-assistant-v2/prod/.venv/bin/pip install \
  -r /srv/ippms-assistant-v2/prod/requirements.txt --proxy http://10.94.147.19:8080

# Sanity: the version, and that PyYAML (new in this release) is present.
/srv/ippms-assistant-v2/prod/.venv/bin/python -V
/srv/ippms-assistant-v2/prod/.venv/bin/python -c "import yaml, dash, psycopg2; print('deps ok')"
```

> The corporate proxy is for **pip only**, at install time. It must never
> appear in a service environment file — the Instant Graph gateway goes
> through a host you control. See `.env.example`.

---

## 3. Production environment file

Start from the live one so the secrets are carried over byte-for-byte rather
than retyped.

```bash
sudo cp /etc/ippms-assistant/ippms.env /etc/ippms-assistant/ippms-prod.env
sudo chown root:ippms /etc/ippms-assistant/ippms-prod.env
sudo chmod 640      /etc/ippms-assistant/ippms-prod.env
```

Then confirm — do not assume — that it contains these. The schema and session
key are what keep prod pointed at prod:

```
IG_DB_SCHEMA=tt_vi_ippms_schema          # NOT ..._test
IG_DB_SESSION_KEY=default                # NOT test
MCP_PORT=8056
MCP_SERVER_URL=http://127.0.0.1:8056/mcp
DASH_HOST=127.0.0.1                      # ops console stays on loopback
DASH_PORT=8060
VI_APP_HOST=0.0.0.0                      # the chat UI is the only published one
VI_APP_PORT=8079
```

```bash
sudo grep -E 'SCHEMA|SESSION_KEY|PORT|DASH_HOST|APP_HOST|MCP_SERVER_URL' \
  /etc/ippms-assistant/ippms-prod.env
```

A test-schema value left in here is the one mistake that is both easy to make
and hard to notice: prod would look healthy while writing into the test schema.

---

## 4. Verify the new tree before it serves anyone

```bash
cd /srv/ippms-assistant-v2/prod

# Syntax, before any restart can be affected by it.
sudo -u ippms .venv/bin/python -m py_compile src/*.py && echo "compile ok"

# The gateway, with prod's own environment. A 401 is a PASS: TLS verified and
# the gateway answered, you just have no token.
sudo -u ippms bash -c 'set -a; . /etc/ippms-assistant/ippms-prod.env; set +a; \
  exec /srv/ippms-assistant-v2/prod/.venv/bin/python deploy/check-gateway.py'

# Everything else: secrets, assets, Postgres, venv Python, ports.
sudo -u ippms bash -c 'set -a; . /etc/ippms-assistant/ippms-prod.env; set +a; \
  exec deploy/preflight.sh'
```

`preflight.sh` will report ports 8056/8060/8079 as busy. That is expected —
the old stack still holds them. Everything else must be green.

---

## 5. Cutover

From here the service is down until step 6 reports healthy. The database
migrations run automatically on first start: three nullable columns on
`vi_chat_interactions` (`notice`, `glossary_version`, `glossary_terms`) and the
new `vi_sme_requests` table. Adding nullable columns does not rewrite the
table, and the old code lists its INSERT columns explicitly, so the old
deployment keeps working against the migrated schema — which is what makes the
rollback below safe.

```bash
# Stop the old stack and stop it coming back on reboot.
sudo systemctl disable --now ippms-app ippms-mcp

# Ports must be clear before the new stack can bind them.
ss -lntp | grep -E ':(8056|8060|8079)\b'     # expect NO output

# MCP first — the chat app is its client.
sudo systemctl enable --now ippms-mcp@prod
sleep 10
sudo systemctl enable --now ippms-app@prod
```

---

## 6. Verify — in this order

```bash
systemctl is-active ippms-mcp@prod ippms-app@prod      # both: active

# The startup lines must be clean. "MISSING" or "disabled" here means a
# degraded start that will otherwise only show up as bad answers later.
sudo journalctl -u ippms-app@prod -n 40 --no-pager | grep -E '\[STARTUP\]|\[CONFIG\]'
```

Expect, among others:

```
[STARTUP] tool KB loaded, question guide N rows, logging ready, ... glossary ready.
[STARTUP] SME applications ready.
[STARTUP] roles: 6 admin(s), 3 seed SME(s) from /srv/ippms-assistant-v2/prod/config
[STARTUP] Talk-to-VI-IPPMS on http://0.0.0.0:8079  (MCP=http://127.0.0.1:8056/mcp, ...)
```

Then, in a browser at `http://10.19.71.246:8079/`:

1. Sign in. Ask a question you know the answer to. Confirm it is correct.
2. Ask the **same question twice** — the answers should be identical.
3. Open 🛡️ Admin → Usage. It should show real production history, not zeroes.
4. Confirm the sidebar shows the glossary button for you (you are an admin).

And confirm prod is writing to the prod schema, not the test one:

```bash
sudo -u ippms psql -h 10.19.75.115 -U ig_app_user -d conv_ai_db -c \
"SELECT 'prod' env, count(*), max(asked_at) FROM tt_vi_ippms_schema.vi_chat_interactions
 UNION ALL
 SELECT 'test', count(*), max(asked_at) FROM tt_vi_ippms_schema_test.vi_chat_interactions;"
```

The prod count must have grown by your test questions. If the **test** count
grew instead, stop and fix `IG_DB_SCHEMA` in `ippms-prod.env`.

---

## 7. Rollback

One block. Works at any point after step 5, and does not depend on anything
above having succeeded.

```bash
sudo systemctl disable --now ippms-app@prod ippms-mcp@prod
sudo systemctl enable  --now ippms-mcp ippms-app
sleep 10
systemctl is-active ippms-mcp ippms-app
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8079/
```

The old tree at `/srv/ippms-assistant` is untouched, and its venv and env file
are its own. The added columns and the new table stay behind; they are
nullable and unused by the old code, so they cost nothing. Drop them only if
you are abandoning v2 entirely:

```sql
ALTER TABLE tt_vi_ippms_schema.vi_chat_interactions
  DROP COLUMN IF EXISTS notice,
  DROP COLUMN IF EXISTS glossary_version,
  DROP COLUMN IF EXISTS glossary_terms;
DROP TABLE IF EXISTS tt_vi_ippms_schema.vi_sme_requests;
```

**Do not delete `/srv/ippms-assistant` for at least a week.**

---

## 8. Afterwards

- **Reboot the host** at a quiet time. Until you do, nothing has proved these
  units come back unattended — which is the whole reason for moving off
  `nohup`. Both `@prod` and `@test` are enabled, so both should return.
- **Rotate `IG_DB_PASSWORD` and `GPU_API_KEY`.** They were plaintext in the
  distributed source. Now that prod depends on this repo, this is overdue.
- **Make prod a git checkout** so `deploy/promote.sh` works for the next
  release. Until then every promotion is a manual copy like this one.
- **Watch the Painpoints tab for a few days.** A rise in the fallback or
  empty-answer rate after this cutover would be the first sign that a glossary
  definition is steering the agent somewhere unhelpful.
