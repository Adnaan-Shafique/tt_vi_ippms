#!/usr/bin/env python3
"""Verify the Instant Graph gateway is reachable with the app's exact TLS setup.

    python3 deploy/check-gateway.py            # reads the env already exported
    set -a; . /etc/ippms-assistant/ippms-prod.env; set +a; python3 deploy/check-gateway.py

curl cannot replicate this check: the gateway's cert is self-signed and needs
VERIFY_X509_PARTIAL_CHAIN, and it is reached by IP while the cert's SAN is a
DNS name. This mirrors _build_ig_ssl_context() and _PinnedSSLContextAdapter()
from instant_graph_mcp_server_v2_5.py, including the proxy_manager_for
override that keeps the pinned context on proxied connections.

A 401 is SUCCESS — it means TLS verified and the gateway answered; you simply
have no token. Only TLS/proxy errors are failures.
"""
import os
import ssl
import sys

import requests
from requests.adapters import HTTPAdapter

BASE = os.environ.get("INSTANT_GRAPH_BASE_URL", "https://10.34.64.74:5001/api/api")
CA = os.environ.get("IG_CA_BUNDLE") or None
CERT_HOST = os.environ.get("IG_CERT_HOSTNAME") or None
PROXY = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or None


class _Pinned(HTTPAdapter):
    def __init__(self, ctx, assert_hostname=None, *a, **kw):
        self._ctx, self._host = ctx, assert_hostname
        super().__init__(*a, **kw)

    def _pin(self, kw):
        kw["ssl_context"] = self._ctx
        if self._host:
            kw["assert_hostname"] = self._host
        return kw

    def init_poolmanager(self, *a, **kw):
        return super().init_poolmanager(*a, **self._pin(kw))

    def proxy_manager_for(self, *a, **kw):
        return super().proxy_manager_for(*a, **self._pin(kw))


print(f"  base    {BASE}")
print(f"  proxy   {PROXY or '(direct)'}")
print(f"  ca      {CA or '(system trust store)'}")
print(f"  pin SAN {CERT_HOST or '(none — normal hostname verification)'}")
print()

if CA and not os.path.exists(CA):
    sys.exit(f"FAIL: IG_CA_BUNDLE={CA} does not exist. Every call would fail cert verification.")

ctx = None
if CA:
    ctx = ssl.create_default_context(cafile=CA)
    ctx.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
    if CERT_HOST:
        ctx.check_hostname = False

s = requests.Session()
s.mount("https://", _Pinned(ctx, CERT_HOST) if ctx else HTTPAdapter())

try:
    r = s.get(f"{BASE}/v3/get-hosts", timeout=20)
except requests.exceptions.SSLError as e:
    sys.exit(f"FAIL (TLS): {e}\n\n  Check IG_CA_BUNDLE points at the gateway's PEM and\n"
             f"  IG_CERT_HOSTNAME matches the cert's SAN.")
except requests.exceptions.ProxyError as e:
    sys.exit(f"FAIL (proxy): {e}\n\n  The proxy refused. If it denies CONNECT to port 5001,\n"
             f"  use the squid relay in deploy/relay/ instead.")
except requests.RequestException as e:
    sys.exit(f"FAIL: {type(e).__name__}: {e}")

if r.status_code in (401, 403):
    print(f"PASS — TLS verified, gateway answered {r.status_code} (no token, as expected).")
else:
    print(f"PASS — TLS verified, gateway answered {r.status_code}.")
