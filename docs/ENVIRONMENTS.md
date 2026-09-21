# Environments: test → prod

Two fully independent deployments on `10.19.75.115`, both managed by
systemd. FALCONPRD ran a single systemd-managed environment; this splits that
into a promotable prod/test pair.

---

## Layout

Two separate checkouts, two venvs, two `.env` files, two Postgres schemas.
**Nothing is shared.** Restarting test cannot disturb prod.

```
/srv/ippms-assistant-v2/
├── prod/                       ← detached at a release TAG, never a branch
│   ├── .venv/  src/  assets/  ig_selfsigned.pem
├── test/                       ← tracks a branch; where you try things
│   ├── .venv/  src/  assets/  ig_selfsigned.pem
└── backups/

/etc/ippms-assistant/           ← secrets, deliberately OUTSIDE the checkout
├── ippms-prod.env                 so a redeploy, rsync or git clean
└── ippms-test.env                 can never touch them
```

| | prod | test |
|---|---|---|
| Chat UI | `:8079` | `:8179` |
| Ops console (loopback) | `:8060` | `:8160` |
| MCP (internal) | `:8056` | `:8156` |
| DB schema | `tt_vi_ippms_schema` | `tt_vi_ippms_schema_test` |
| `IG_DB_SESSION_KEY` | `default` | `test` |
| Git state | detached at a tag | a branch |
| Services | `*@prod` | `*@test` |

### Why separate schemas

Both environments hit the **same live Instant Graph APIs** — there is no test
gateway. The only thing you can isolate is what the app *writes*, and that
matters: sharing a schema would mean test traffic lands in
`vi_chat_interactions`, `ig_tool_call_audit` and `vi_chat_feedback` alongside
real usage, quietly corrupting the record you use to judge the assistant.

Separate `IG_DB_SESSION_KEY` values also stop the two `TokenManager`s from
fighting over the same `ig_auth_sessions` row and invalidating each other's
tokens.

> Test **reads** production network data and **writes** to real upstream
> sessions. It is not a sandbox — it is a staging deployment. Treat its
> queries as real load on the gateway.

---

## One-time setup

```bash
# Matches FALCONPRD: service user with a normal home, deploy dir separate.
sudo useradd -r -m -d /home/ippms -s /usr/sbin/nologin ippms
sudo mkdir -p /srv/ippms-assistant-v2/{prod,test,backups}
sudo chown -R ippms:ippms /srv/ippms-assistant-v2

# Two checkouts from the same remote
sudo -u ippms git clone <repo-url> /srv/ippms-assistant-v2/prod
sudo -u ippms git clone <repo-url> /srv/ippms-assistant-v2/test

# prod sits on a tag, never a branch — so "what is in prod" is unambiguous
sudo -u ippms git -C /srv/ippms-assistant-v2/prod checkout --detach v1.0.0
sudo -u ippms git -C /srv/ippms-assistant-v2/test checkout main

sudo mkdir -p /etc/ippms-assistant
for e in prod test; do
  sudo -u ippms python3 -m venv /srv/ippms-assistant-v2/$e/.venv
  sudo -u ippms /srv/ippms-assistant-v2/$e/.venv/bin/pip install -r /srv/ippms-assistant-v2/$e/requirements.txt
  sudo cp /srv/ippms-assistant-v2/$e/.env.example /etc/ippms-assistant/ippms-$e.env
  sudo chown ippms:ippms /etc/ippms-assistant/ippms-$e.env
  sudo chmod 600         /etc/ippms-assistant/ippms-$e.env
done
```

Create the test schema (the auth tables do **not** auto-create):

```bash
psql -h 127.0.0.1 -U ig_app_user -d conv_ai_db \
     -v schema=tt_vi_ippms_schema_test -f /srv/ippms-assistant-v2/test/sql/setup_ig_auth_tables.sql
```

Edit each `.env` — for `ippms-test.env` change **all five**:

```bash
IG_DB_SCHEMA=tt_vi_ippms_schema_test
IG_DB_SESSION_KEY=test
MCP_PORT=8156
MCP_SERVER_URL=http://127.0.0.1:8156/mcp     # ►► easy to forget; test would
DASH_PORT=8160                               #    silently drive PROD's MCP
VI_APP_PORT=8179
```

> `MCP_SERVER_URL` is the one people miss. Miss it and your test chat app
> drives the **production** MCP server — writing to the prod audit table and
> sharing prod's tokens, while every port looks correctly separated.

Install the templated units:

```bash
sudo cp /srv/ippms-assistant-v2/prod/deploy/*@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ippms-mcp@prod && sleep 10
sudo systemctl enable --now ippms-app@prod
sudo systemctl enable --now ippms-mcp@test && sleep 10
sudo systemctl enable --now ippms-app@test
```

---

## Daily operation

```bash
# status of everything
systemctl status 'ippms-mcp@*' 'ippms-app@*' --no-pager

# follow one environment
journalctl -u ippms-app@test -u ippms-mcp@test -f

# restart an environment — MCP first, the chat app is its client
sudo systemctl restart ippms-mcp@test && sleep 10
sudo systemctl restart ippms-app@test

# what is in prod right now
git -C /srv/ippms-assistant-v2/prod describe --tags
```

---

## The release cycle

```
 feature branch ──► main ──► tag vX.Y.Z ──► test checkout ──► promote.sh ──► prod
```

### 1. Develop

```bash
git checkout -b feature/my-change
# edit, commit, push, merge to main
```

### 2. Deploy to test

```bash
sudo -u ippms git -C /srv/ippms-assistant-v2/test pull origin main
sudo -u ippms /srv/ippms-assistant-v2/test/.venv/bin/pip install -r /srv/ippms-assistant-v2/test/requirements.txt
sudo systemctl restart ippms-mcp@test && sleep 10
sudo systemctl restart ippms-app@test
```

Exercise it at `http://10.19.75.115:8179/`. The ops console binds loopback —
reach it with `ssh -L 8160:127.0.0.1:8160 you@10.19.75.115`. **Read the startup line** — see
the checklist below.

### 3. Tag what you tested

```bash
git tag -a v1.1.0 -m "Add <shape>"
git push origin v1.1.0
```

Tag the exact commit you tested — do not tag, then push more commits.

### 4. Promote

```bash
sudo -u ippms /srv/ippms-assistant-v2/prod/deploy/promote.sh v1.1.0
```

The script refuses a nonexistent tag, refuses to clobber uncommitted edits on
the prod box, byte-compiles before restarting, restarts in dependency order,
and **rolls back automatically** if either service fails to come up.

### 5. Verify prod

```bash
deploy/preflight.sh /etc/ippms-assistant/ippms-prod.env
journalctl -u ippms-app@prod -n 30 --no-pager | grep STARTUP
```

### Rollback

```bash
sudo -u ippms /srv/ippms-assistant-v2/prod/deploy/promote.sh v1.0.0
```

Promotion is just "check out a tag and restart", so rolling back is the same
operation aimed at the previous tag. This is the main reason prod sits on a
detached tag rather than a branch.

---

## Acceptance checklist before promoting

**The startup line must be clean.** Every one of these failures is silent at
runtime:

```
[STARTUP] Discovered 8 MCP tools.
[STARTUP] question guide loaded: N rows indexed for retrieval.
[STARTUP] tool KB loaded, question guide N rows, logging ready,
          user_feedback ready, chat_history ready, glossary ready.
```

Anything reading `MISSING`, `disabled`, or `Discovered 0 MCP tools` is a fail.

Then run one question of each shape — they hit different code paths:

| # | Question | Exercises |
|---|---|---|
| 1 | "How many devices are in the GUJ circle?" | metadata route, circle matching |
| 2 | "How many interfaces on `<device>`?" | host resolution, fan-out |
| 3 | "On `<device>`, interface `<if>`, HC In Octets between 8am and 2pm yesterday" | KPI route, `between` parsing, charts |
| 4 | "Top 5 interfaces by HC In Octets on `<device>` currently" | ranking shape, bar chart |
| 5 | "Show me the spikes for HC In Octets on `<if>` on `<device>` in the last 6 hours" | anomaly shape |
| 6 | "What's the weather" | out-of-scope gate |

Ask **question 1 twice** and confirm the answers are character-identical — that
is the determinism guarantee the QuerySpec engine exists to provide, and a
regression there is easy to introduce and easy to miss.

Confirm side effects landed in the **test** schema:

```sql
SELECT count(*), max(created_at) FROM tt_vi_ippms_schema_test.vi_chat_interactions;
SELECT count(*), max(created_at) FROM tt_vi_ippms_schema_test.ig_tool_call_audit;
```

If those counts stay flat while prod's rise, your test `.env` is pointing at
the wrong schema or the wrong MCP server.

---

## Notes

- **Never edit code directly on the prod box.** `promote.sh` refuses to run
  with a dirty prod checkout, which is the point — the fix belongs in git.
- Both environments share the FALCONPRD relay and GPU proxy. If either is
  down, **both** environments degrade together, so rule that out first when
  test and prod fail at the same time.
- The GPU proxy is a single mistral-7b instance serving both environments.
  Heavy test load will slow production answers.
