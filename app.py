#!/usr/bin/env python3
"""Pod identity dashboard for the GKE load-balancing PoC.

The app intentionally uses only the Python standard library so it can run in a
minimal container with no third-party supply chain surface.

Endpoints
---------
GET /          HTML dashboard: pod name, pod IP, node, request counter.
GET /api/info  Same identity data as JSON (handy for scripts/automation).
GET /healthz   Liveness probe.
GET /readyz    Readiness probe.

The pod identity is injected by the Kubernetes Downward API. Local fallbacks
make the app usable with a plain `python3 app.py` as well.
"""

from __future__ import annotations

import html
import json
import logging
import os
import signal
import socket
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from itertools import count
from urllib.parse import urlsplit

APP_VERSION = os.getenv("APP_VERSION", "v1")
POD_NAME = os.getenv("POD_NAME") or socket.gethostname()
POD_IP = os.getenv("POD_IP") or "unknown"
NODE_NAME = os.getenv("NODE_NAME") or "unknown"
POD_NAMESPACE = os.getenv("POD_NAMESPACE") or "unknown"
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "3002"))

STARTED_AT = datetime.now(timezone.utc)
REQUEST_SEQUENCE = count(1)
REQUEST_SEQUENCE_LOCK = threading.Lock()
SHUTTING_DOWN = threading.Event()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("pod-info")

# A stable accent colour per pod makes the browser proof obvious at a glance.
ACCENT_COLORS = ("#1a73e8", "#d93025", "#188038", "#9334e6", "#e37400")


def next_request_number() -> int:
    """Return a process-local, thread-safe request sequence number."""
    with REQUEST_SEQUENCE_LOCK:
        return next(REQUEST_SEQUENCE)


def accent_for(name: str) -> str:
    """Deterministic colour derived from the pod name (no randomised hash)."""
    return ACCENT_COLORS[sum(name.encode("utf-8")) % len(ACCENT_COLORS)]


def uptime_text() -> str:
    seconds = max(0, int((datetime.now(timezone.utc) - STARTED_AT).total_seconds()))
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


def identity_payload(request_number: int) -> dict[str, object]:
    now = datetime.now(timezone.utc)
    return {
        "pod_name": POD_NAME,
        "pod_ip": POD_IP,
        "node_name": NODE_NAME,
        "namespace": POD_NAMESPACE,
        "app_version": APP_VERSION,
        "hostname": socket.gethostname(),
        "request_number": request_number,
        "started_at": STARTED_AT.isoformat(),
        "served_at": now.isoformat(),
        "uptime_seconds": int((now - STARTED_AT).total_seconds()),
    }


def render_html(request_number: int) -> str:
    accent = accent_for(POD_NAME)
    safe = {
        "pod_name": html.escape(POD_NAME),
        "pod_ip": html.escape(POD_IP),
        "node_name": html.escape(NODE_NAME),
        "namespace": html.escape(POD_NAMESPACE),
        "app_version": html.escape(APP_VERSION),
        "started_at": html.escape(STARTED_AT.strftime("%Y-%m-%d %H:%M:%S UTC")),
        "uptime": html.escape(uptime_text()),
        "served_at": html.escape(datetime.now(timezone.utc).strftime("%H:%M:%S UTC")),
    }
    return f"""<!DOCTYPE html>
<html lang="id">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="5">
  <title>Pod {safe["pod_name"]} · GKE LB PoC</title>
  <style>
    :root {{ color-scheme: dark; --accent: {accent}; }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0; min-height: 100vh; display: grid; place-items: center;
      padding: 24px; color: #e8eaed; background: #0b0f14;
      font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
      background-image: radial-gradient(circle at 50% 0%, color-mix(in srgb, var(--accent) 24%, transparent), transparent 55%);
    }}
    main {{
      width: min(760px, 100%); background: #111820; border: 1px solid #263241;
      border-top: 5px solid var(--accent); border-radius: 18px; padding: clamp(24px, 5vw, 48px);
      box-shadow: 0 24px 80px rgb(0 0 0 / 45%);
    }}
    .eyebrow {{ margin: 0 0 10px; color: #9aa7b8; font-size: 12px; font-weight: 700; letter-spacing: .18em; text-transform: uppercase; }}
    h1 {{ margin: 0; font-size: clamp(26px, 5vw, 42px); line-height: 1.1; overflow-wrap: anywhere; }}
    .identity-label {{ margin: 8px 0 0; color: #8fa0b5; font-size: 13px; }}
    .badge {{
      display: inline-flex; align-items: center; gap: 8px; margin-top: 14px; padding: 7px 12px;
      color: #b9f6ca; background: #0d2b1b; border: 1px solid #1f6b3a; border-radius: 999px;
      font-size: 13px; font-weight: 600;
    }}
    .dot {{ width: 8px; height: 8px; border-radius: 50%; background: #34d399; box-shadow: 0 0 0 4px rgb(52 211 153 / 15%); }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 12px; margin: 28px 0; }}
    .cell {{ background: #0b1219; border: 1px solid #1f2b3a; border-radius: 12px; padding: 16px; }}
    .label {{ color: #8fa0b5; font-size: 11px; font-weight: 700; letter-spacing: .12em; text-transform: uppercase; }}
    .value {{ margin-top: 8px; color: #f5f7fa; font-family: ui-monospace, "SFMono-Regular", Menlo, monospace; font-size: 16px; overflow-wrap: anywhere; }}
    .value.accent {{ color: var(--accent); font-size: 18px; font-weight: 700; }}
    p.note {{ margin: 0; color: #a7b4c5; font-size: 14px; line-height: 1.65; }}
    footer {{ display: flex; flex-wrap: wrap; justify-content: space-between; gap: 12px; margin-top: 26px; padding-top: 18px; border-top: 1px solid #1f2b3a; color: #77869a; font-size: 12px; }}
    code {{ color: #d7e3f4; }}
  </style>
</head>
<body>
  <main>
    <p class="eyebrow">GKE Load Balancing Proof of Concept</p>
    <h1 id="pod-name">{safe["pod_name"]}</h1>
    <p class="identity-label">Pod name / hostname</p>
    <span class="badge"><span class="dot"></span>Pod ini sedang melayani request Anda</span>

    <section class="grid" aria-label="Identitas Pod">
      <div class="cell"><div class="label">Pod IP</div><div class="value accent" id="pod-ip">{safe["pod_ip"]}</div></div>
      <div class="cell"><div class="label">Node</div><div class="value" id="node-name">{safe["node_name"]}</div></div>
      <div class="cell"><div class="label">Namespace</div><div class="value">{safe["namespace"]}</div></div>
      <div class="cell"><div class="label">Versi Aplikasi</div><div class="value">{safe["app_version"]}</div></div>
      <div class="cell"><div class="label">Request ke Pod Ini</div><div class="value" id="request-number">{request_number}</div></div>
      <div class="cell"><div class="label">Uptime Pod</div><div class="value">{safe["uptime"]}</div></div>
    </section>

    <p class="note">Halaman ini otomatis dimuat ulang tiap <strong>5 detik</strong>. Setiap request membuka koneksi
    baru ke GCP Load Balancer, sehingga nama Pod dan IP seharusnya bergantian antar replika.
    Data ini juga tersedia sebagai JSON di <code>/api/info</code>.</p>

    <footer>
      <span>Started: {safe["started_at"]}</span>
      <span>Served at: {safe["served_at"]}</span>
    </footer>
  </main>
</body>
</html>
"""


class PodInfoHandler(BaseHTTPRequestHandler):
    """Stdlib HTTP handler with identity headers and hard-coded routes."""

    server_version = "pod-info"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        log.info("%s - %s", self.address_string(), fmt % args)

    def _send(
        self,
        status: int,
        body: bytes,
        content_type: str,
        *,
        request_number: int | None = None,
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; "
            "form-action 'none'; frame-ancestors 'none'",
        )
        # Identity headers make terminal-based verification trivial and stable.
        self.send_header("X-Pod-Name", POD_NAME)
        self.send_header("X-Pod-IP", POD_IP)
        self.send_header("X-Node-Name", NODE_NAME)
        if request_number is not None:
            self.send_header("X-Pod-Request", str(request_number))
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        # The PoC proves L4 load balancing per TCP connection. Closing the
        # connection on every response guarantees the browser opens a fresh
        # connection to the GCP LB on each refresh (not production behaviour).
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _route(self) -> None:
        path = urlsplit(self.path).path

        if path == "/":
            request_number = next_request_number()
            body = render_html(request_number).encode("utf-8")
            self._send(
                200,
                body,
                "text/html; charset=utf-8",
                request_number=request_number,
            )
            return

        if path == "/api/info":
            request_number = next_request_number()
            payload = json.dumps(
                identity_payload(request_number), indent=2, ensure_ascii=False
            ).encode("utf-8")
            self._send(
                200,
                payload + b"\n",
                "application/json; charset=utf-8",
                request_number=request_number,
            )
            return

        if path == "/healthz":
            self._send(200, b"ok\n", "text/plain; charset=utf-8")
            return

        if path == "/readyz":
            if SHUTTING_DOWN.is_set():
                self._send(503, b"not ready: shutting down\n", "text/plain; charset=utf-8")
            else:
                self._send(200, b"ready\n", "text/plain; charset=utf-8")
            return

        if path == "/favicon.ico":
            self._send(204, b"", "image/x-icon")
            return

        self._send(404, b"404 Not Found\n", "text/plain; charset=utf-8")

    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        self._route()

    def do_HEAD(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        self._route()


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), PodInfoHandler)
    server.daemon_threads = True

    def handle_signal(signum: int, _frame: object) -> None:
        SHUTTING_DOWN.set()
        log.info("received signal %s, shutting down", signum)
        # shutdown() blocks until serve_forever() exits, so it must run outside
        # the signal handler. This gives in-flight requests a chance to finish.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    log.info(
        "starting pod-info pod=%s pod_ip=%s node=%s version=%s listen=%s:%d",
        POD_NAME,
        POD_IP,
        NODE_NAME,
        APP_VERSION,
        HOST,
        PORT,
    )
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        log.info("server stopped")


if __name__ == "__main__":
    main()
