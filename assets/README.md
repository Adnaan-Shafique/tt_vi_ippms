# Runtime assets

These files are **deliberately not in git** — one is binary data, and the PEM is
a credential. Copy them here from the running host (see
`docs/MIGRATION_10.19.75.115.md` §4.3).

| File | Env var | If missing |
|---|---|---|
| `vi_ippms_tool_kb.md` | `VI_TOOL_KB_PATH` | Tool KB empty; startup logs `tool KB MISSING`. Agent loses its tool guidance. |
| `vi_ippms_question_guide.xlsx` | `VI_QUESTION_GUIDE_PATH` | App **still starts**; RAG retrieval silently disabled and answer quality drops. Sheet must be named `question_guide`. |

The Instant Graph CA bundle (`ig_selfsigned.pem`, `IG_CA_BUNDLE`) lives at the
install root, not here — keep it `chmod 640`.

Verify they loaded by reading the startup line:

```
[STARTUP] tool KB loaded, question guide 142 rows, logging ready, ...
```
