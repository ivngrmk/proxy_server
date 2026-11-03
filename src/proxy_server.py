#!/usr/bin/env python3
import datetime
import os
import select
import socket
import socketserver
import threading
import time

BIND_HOST = os.environ.get("PROXY_BIND_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("PROXY_BIND_PORT", "18181"))
BASE_DIR = os.environ.get("PROXY_DIR", os.path.dirname(os.path.abspath(__file__)))
LOG_DIR = os.path.join(BASE_DIR, "logs")
LOG_PATH = os.path.join(LOG_DIR, "proxy.log")
HEARTBEAT_SECONDS = int(os.environ.get("PROXY_HEARTBEAT_SECONDS", "180"))
MAX_LOG_BYTES = int(os.environ.get("PROXY_MAX_LOG_BYTES", str(1024 * 1024)))
KEEP_LOG_BYTES = int(os.environ.get("PROXY_KEEP_LOG_BYTES", str(256 * 1024)))

_log_lock = threading.Lock()


def log(message):
    os.makedirs(LOG_DIR, mode=0o700, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    with _log_lock:
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > MAX_LOG_BYTES:
            with open(LOG_PATH, "rb") as f:
                f.seek(max(0, os.path.getsize(LOG_PATH) - KEEP_LOG_BYTES))
                tail = f.read()
            with open(LOG_PATH, "wb") as f:
                f.write(b"[log compacted]\n")
                f.write(tail)

        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"{stamp} {message}\n")


def heartbeat():
    while True:
        time.sleep(HEARTBEAT_SECONDS)
        log(f"heartbeat listening {BIND_HOST}:{BIND_PORT}")


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        data = b""

        while b"\r\n\r\n" not in data and len(data) < 8192:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            data += chunk

        line = data.split(b"\r\n", 1)[0].decode("ascii", "replace")
        parts = line.split()

        if len(parts) < 3 or parts[0].upper() != "CONNECT" or ":" not in parts[1]:
            self.request.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            log(f"reject {self.client_address[0]} {line!r}")
            return

        host, port_s = parts[1].rsplit(":", 1)
        log(f"connect {self.client_address[0]} {host}:{port_s}")

        try:
            port = int(port_s)
            upstream = socket.create_connection((host, port), timeout=10)
        except Exception as exc:
            self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            log(f"bad_gateway {host}:{port_s} {exc!r}")
            return

        self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        sockets = [self.request, upstream]

        try:
            while True:
                readable, _, _ = select.select(sockets, [], [], 300)
                if not readable:
                    return

                for sock in readable:
                    other = upstream if sock is self.request else self.request
                    buf = sock.recv(65536)
                    if not buf:
                        return
                    other.sendall(buf)
        finally:
            upstream.close()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    threading.Thread(target=heartbeat, daemon=True).start()
    log(f"starting {BIND_HOST}:{BIND_PORT}")
    with Server((BIND_HOST, BIND_PORT), Handler) as server:
        server.serve_forever()
