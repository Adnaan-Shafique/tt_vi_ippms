"""
═══════════════════════════════════════════════════════════════════════════════
 ippms_config — YAML-backed roles and user-facing copy
═══════════════════════════════════════════════════════════════════════════════

 Two files, both under config/ next to this package:

   roles.yaml     admins + seed SMEs. The trust anchor; never written by the
                  application. See the header in that file for why.
   content.yaml   user-facing copy (welcome screen, help text, starter chips,
                  SME-application wording).

 Three things this module guarantees, because the app is long-running and a
 bad edit at the wrong moment should not take the assistant down:

   1. LAST-KNOWN-GOOD. If a reload finds malformed YAML or a wrong shape, the
      previously loaded config stays in force and the failure is logged. Only
      the very first load can leave us with nothing, and even then every
      accessor falls back to a built-in default rather than raising.

   2. NO PARTIAL APPLY. A file is validated fully, into a fresh object, before
      it replaces the live one. A file that is half-valid is not half-applied.

   3. EVERY KEY OPTIONAL. Deleting or mistyping a content key gives you the
      built-in default for that key alone, not a stack trace. roles.yaml is
      stricter: a malformed roles file is refused outright, because silently
      falling back to "no admins" or "no SMEs" would revoke access without
      anyone noticing.

 Role resolution (role_for) is the only place the three tiers are decided:

   admin  if listed in roles.yaml admins
   sme    if listed in roles.yaml smes, OR an admin has approved their
          application (that grant lives in Postgres, not here — see
          set_sme_grant_provider)
   user   otherwise

 Admins are a superset of SMEs: can_edit_glossary() is true for both.
"""

from __future__ import annotations

import logging
import os
import threading
from typing import Any, Callable, Dict, List, Optional, Set

import yaml

log = logging.getLogger("talk_to_vi_ippms.config")

# config/ sits beside src/, so walk up one level from this file. Overridable
# for deployments that keep configuration outside the code tree.
_SRC_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_DIR = os.environ.get(
    "VI_CONFIG_DIR", os.path.join(os.path.dirname(_SRC_DIR), "config"))

ROLES_PATH = os.path.join(CONFIG_DIR, "roles.yaml")
CONTENT_PATH = os.path.join(CONFIG_DIR, "content.yaml")

ROLE_ADMIN = "admin"
ROLE_SME = "sme"
ROLE_USER = "user"


# ── Built-in defaults ────────────────────────────────────────────────────────
#  Used when content.yaml is missing a key, missing entirely, or unreadable.
#  Kept in sync with config/content.yaml by hand — they are a safety net, not
#  the source of truth, so a small drift here is harmless.

_DEFAULT_CONTENT: Dict[str, Any] = {
    "brand": {
        "name": "Talk to VI-IPPMS",
        "tagline": "Instant Graph · conversational analytics",
    },
    "welcome": {
        "eyebrow": "TALK TO VI-IPPMS",
        "heading": "What would you like to know?",
        "intro": ("Ask in plain English. The agent routes through Router → Resolve → "
                  "QuerySpec → deterministic executor → Synthesize (falling back to a "
                  "ReAct tool loop only for unusual shapes), using live Instant Graph APIs."),
    },
    "capabilities": [
        {"icon": "🗂️", "title": "Device metadata",
         "description": "Counts & listings of devices by circle or name pattern",
         "question": "How many devices are in the GUJ circle?"},
        {"icon": "🔌", "title": "Interfaces & components",
         "description": "Interfaces / components / KPIs per device",
         "question": "How many interfaces on APVSPGJWPAR01HNE40?"},
        {"icon": "📈", "title": "KPI retrieval",
         "description": "Values & statistics over a time window",
         "question": "min/max/avg HC In Octets on Interface 100GE0/3/2 in the last 6 hours"},
        {"icon": "🧭", "title": "Filter & slice",
         "description": "Slice devices/KPIs by circle, component, threshold",
         "question": "List devices matching PAR01"},
    ],
    "quick_questions": [
        "How many devices are in the GUJ circle?",
        "List devices matching PAR01",
        "How many components on APVSPGJWPAR01HNE40?",
        "How many KPIs are tracked on APVSPGJWPAR01HNE40?",
    ],
    "help_text": (
        "I'm the Talk-to-VI-IPPMS assistant. I answer questions about your network "
        "monitoring data using live APIs — no SQL. Try:\n"
        "• Metadata: “How many devices are in the GUJ circle?”, “How many interfaces "
        "on APVSPGJWPAR01HNE40?”, “List devices matching PAR01”, “How many KPIs are "
        "tracked on that device?”\n"
        "• KPI data: “On <device>, interface 100GE0/3/2, what was HC In Octets in the "
        "last 6 hours?”, “min/max/avg traffic on Eth-Trunk1 yesterday”."
    ),
    "sme_access": {
        "apply_button": "🙋  Apply for SME access",
        "pending_button": "⏳  SME request pending",
        "modal_title": "Apply for SME access",
        "modal_blurb": ("SMEs can add glossary terms — the abbreviations, full forms and "
                        "business rules the assistant uses to understand your questions. "
                        "Tell the admins why you should have that access and they'll "
                        "review it."),
        "justification_label": "Why do you need SME access?",
        "justification_placeholder": ("e.g. I own the Gujarat transport KPI definitions "
                                      "and maintain the naming standards."),
        "submitted_toast": "Request sent. An admin will review it.",
        "approved_toast": ("Your SME access has been approved — the glossary form is now "
                           "available."),
    },
}


# ── Live state ───────────────────────────────────────────────────────────────

_lock = threading.RLock()
_roles: Dict[str, Set[str]] = {"admins": set(), "smes": set()}
_content: Dict[str, Any] = dict(_DEFAULT_CONTENT)
_loaded_once = False

# Phase 2 plugs the Postgres-backed SME grants in here. Until then role_for
# consults roles.yaml alone, which is exactly the behaviour of the old
# hardcoded GLOSSARY_EDITORS set.
_sme_grant_provider: Optional[Callable[[], Set[str]]] = None


def set_sme_grant_provider(fn: Optional[Callable[[], Set[str]]]) -> None:
    """Register a callable returning the set of emails with an approved SME
    application. Called by the app once the database layer is ready; kept as a
    hook so this module has no database dependency of its own."""
    global _sme_grant_provider
    with _lock:
        _sme_grant_provider = fn


# ── Loading ──────────────────────────────────────────────────────────────────

def _read_yaml(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def _norm_emails(value: Any, field: str) -> Set[str]:
    """Validate a list-of-emails field and normalise it for comparison."""
    if value is None:
        return set()
    if not isinstance(value, list):
        raise ValueError(f"{field!r} must be a list, got {type(value).__name__}")
    out: Set[str] = set()
    for item in value:
        if not isinstance(item, str) or not item.strip():
            raise ValueError(f"{field!r} contains a non-string or blank entry: {item!r}")
        if "@" not in item:
            raise ValueError(f"{field!r} entry {item!r} does not look like an email address")
        out.add(item.strip().lower())
    return out


def _parse_roles(raw: Any) -> Dict[str, Set[str]]:
    if not isinstance(raw, dict):
        raise ValueError("roles.yaml must be a mapping at the top level")
    admins = _norm_emails(raw.get("admins"), "admins")
    smes = _norm_emails(raw.get("smes"), "smes")
    if not admins:
        # Not fatal for the assistant, but it means nobody can approve SME
        # applications or open the dashboard — worth shouting about.
        log.error("roles.yaml lists no admins: SME approvals and the admin "
                  "dashboard will be unreachable until one is added.")
    return {"admins": admins, "smes": smes}


def _merge_content(raw: Any) -> Dict[str, Any]:
    """Overlay the file onto the built-in defaults, one top-level key at a time.

    Shallow by design: a mapping in the file replaces the corresponding default
    mapping wholesale rather than merging key-by-key, so what you read in
    content.yaml is what you get. Dropping one key from a mapping you otherwise
    override is still safe — content() falls back to the built-in default for
    any individual path it cannot resolve. Anything of the wrong type is
    skipped with a warning and the default is kept."""
    merged: Dict[str, Any] = {k: v for k, v in _DEFAULT_CONTENT.items()}
    if raw is None:
        return merged
    if not isinstance(raw, dict):
        raise ValueError("content.yaml must be a mapping at the top level")
    for key, default in _DEFAULT_CONTENT.items():
        if key not in raw:
            continue
        value = raw[key]
        if value is None:
            continue
        if not isinstance(value, type(default)):
            log.warning("content.yaml: %r should be %s, got %s — keeping the default.",
                        key, type(default).__name__, type(value).__name__)
            continue
        merged[key] = value
    for key in raw:
        if key not in _DEFAULT_CONTENT and key != "version":
            log.warning("content.yaml: ignoring unknown key %r.", key)
    return merged


def reload_config() -> Dict[str, Any]:
    """Re-read both files. Returns a per-file report:

        {"roles": {"ok": bool, "error": str|None, "admins": int, "smes": int},
         "content": {"ok": bool, "error": str|None}}

    Never raises, and never leaves the process with a half-applied config: a
    file that fails validation leaves the previously loaded values in force.
    The two files are independent, so a broken content.yaml does not stop a
    fixed roles.yaml from applying."""
    global _roles, _content, _loaded_once
    report: Dict[str, Any] = {}

    try:
        parsed_roles = _parse_roles(_read_yaml(ROLES_PATH))
    except FileNotFoundError:
        parsed_roles = None
        report["roles"] = {"ok": False, "error": f"{ROLES_PATH} not found"}
        log.error("roles.yaml not found at %s — keeping the roles already in "
                  "memory (nobody is admin or SME on a cold start).", ROLES_PATH)
    except Exception as exc:
        parsed_roles = None
        report["roles"] = {"ok": False, "error": str(exc)}
        log.error("roles.yaml is invalid (%s) — KEEPING THE PREVIOUS ROLES. "
                  "Access is unchanged; fix the file and reload.", exc)

    try:
        parsed_content = _merge_content(_read_yaml(CONTENT_PATH))
    except FileNotFoundError:
        parsed_content = None
        report["content"] = {"ok": False, "error": f"{CONTENT_PATH} not found"}
        log.warning("content.yaml not found at %s — using built-in copy.", CONTENT_PATH)
    except Exception as exc:
        parsed_content = None
        report["content"] = {"ok": False, "error": str(exc)}
        log.error("content.yaml is invalid (%s) — keeping the previous copy.", exc)

    with _lock:
        if parsed_roles is not None:
            _roles = parsed_roles
            report["roles"] = {"ok": True, "error": None,
                               "admins": len(parsed_roles["admins"]),
                               "smes": len(parsed_roles["smes"])}
        if parsed_content is not None:
            _content = parsed_content
            report["content"] = {"ok": True, "error": None}
        _loaded_once = True
        admin_n, sme_n = len(_roles["admins"]), len(_roles["smes"])

    log.info("[CONFIG] roles: %d admin(s), %d seed SME(s) from %s", admin_n, sme_n, CONFIG_DIR)
    return report


def ensure_loaded() -> None:
    """Load on first use so importing this module never touches the disk."""
    if _loaded_once:
        return
    with _lock:
        if _loaded_once:
            return
    reload_config()


# ── Roles ────────────────────────────────────────────────────────────────────

def _approved_smes() -> Set[str]:
    """Emails with an approved SME application, from the registered provider.

    Best-effort on purpose: if the database is unreachable, a runtime-granted
    SME is temporarily treated as a normal user rather than the whole app
    failing. Seeded SMEs and admins in roles.yaml are unaffected, since they
    never depend on the database."""
    with _lock:
        provider = _sme_grant_provider
    if provider is None:
        return set()
    try:
        return {e.strip().lower() for e in (provider() or set()) if e}
    except Exception as exc:
        log.warning("SME grant lookup failed (%s) — falling back to roles.yaml only.", exc)
        return set()


def role_for(email: Optional[str]) -> str:
    """Resolve a signed-in user's role. Returns ROLE_ADMIN / ROLE_SME / ROLE_USER.

    The single place the three tiers are decided — every permission check in
    the app goes through here or one of the helpers below, so there is one
    definition of who is what."""
    ensure_loaded()
    e = (email or "").strip().lower()
    if not e:
        return ROLE_USER
    with _lock:
        admins, smes = _roles["admins"], _roles["smes"]
    if e in admins:
        return ROLE_ADMIN
    if e in smes or e in _approved_smes():
        return ROLE_SME
    return ROLE_USER


def is_admin(email: Optional[str]) -> bool:
    return role_for(email) == ROLE_ADMIN


def can_edit_glossary(email: Optional[str]) -> bool:
    """Admins and SMEs may add or edit glossary terms; nobody else."""
    return role_for(email) in (ROLE_ADMIN, ROLE_SME)


def admin_emails() -> List[str]:
    """Sorted admin list, for display on the dashboard."""
    ensure_loaded()
    with _lock:
        return sorted(_roles["admins"])


def seed_sme_emails() -> List[str]:
    """Sorted seed-SME list (roles.yaml only — excludes runtime grants)."""
    ensure_loaded()
    with _lock:
        return sorted(_roles["smes"])


# ── Content ──────────────────────────────────────────────────────────────────

def content(*path: str, default: Any = None) -> Any:
    """Read a content value by key path, e.g. content("welcome", "heading").

    Falls back to the built-in default for that path, then to `default`. Never
    raises and never returns a half-built structure, so callers can use the
    result directly in a layout."""
    ensure_loaded()
    with _lock:
        node: Any = _content
    for key in path:
        if isinstance(node, dict) and key in node:
            node = node[key]
        else:
            node = None
            break
    if node is not None:
        return node
    fallback: Any = _DEFAULT_CONTENT
    for key in path:
        if isinstance(fallback, dict) and key in fallback:
            fallback = fallback[key]
        else:
            return default
    return fallback
