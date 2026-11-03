"""Integration checks using only loopback connections and temporary logs."""

import os
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest


PROJECT_DIR = Path(__file__).resolve().parents[1]


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(65536)
            if not data:
                return
            self.request.sendall(data)


class ProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp_dir = tempfile.TemporaryDirectory(prefix="proxy-test-")
        cls.addClassCleanup(cls.temp_dir.cleanup)
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            cls.port = reserved.getsockname()[1]
        env = os.environ.copy()
        env.update(
            PROXY_BIND_HOST="127.0.0.1",
            PROXY_BIND_PORT=str(cls.port),
            PROXY_DIR=cls.temp_dir.name,
            PROXY_HEARTBEAT_SECONDS="180",
            PROXY_MAX_LOG_BYTES="1048576",
            PROXY_KEEP_LOG_BYTES="262144",
        )
        cls.stderr = tempfile.TemporaryFile()
        cls.addClassCleanup(cls.stderr.close)
        cls.process = subprocess.Popen(
            [sys.executable, str(PROJECT_DIR / "src" / "proxy_server.py")],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=cls.stderr,
        )
        cls.addClassCleanup(cls.stop_proxy)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if cls.process.poll() is not None:
                cls.stderr.seek(0)
                raise RuntimeError(cls.stderr.read().decode("utf-8", "replace"))
            try:
                with cls.connect():
                    return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError("Proxy did not start within 10 seconds")

    @classmethod
    def stop_proxy(cls):
        if cls.process.poll() is None:
            cls.process.terminate()
        try:
            cls.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.process.kill()
            cls.process.wait(timeout=5)

    @classmethod
    def connect(cls):
        return socket.create_connection(("127.0.0.1", cls.port), timeout=15)

    def response(self, connection):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = connection.recv(4096)
            if not chunk:
                self.fail("Proxy closed the connection before sending headers")
            data += chunk
        return data

    def test_connect_relays_binary_data_in_both_directions(self):
        with socketserver.ThreadingTCPServer(("127.0.0.1", 0), EchoHandler) as echo:
            worker = threading.Thread(target=echo.serve_forever, daemon=True)
            worker.start()
            try:
                port = echo.server_address[1]
                with self.connect() as client:
                    client.sendall(f"CONNECT 127.0.0.1:{port} HTTP/1.1\r\n\r\n".encode())
                    self.assertEqual(
                        self.response(client),
                        b"HTTP/1.1 200 Connection Established\r\n\r\n",
                    )
                    payload = bytes(range(256)) * 512
                    client.sendall(payload)
                    received = bytearray()
                    while len(received) < len(payload):
                        chunk = client.recv(65536)
                        if not chunk:
                            self.fail("Tunnel closed before all data arrived")
                        received.extend(chunk)
                    self.assertEqual(received, payload)
            finally:
                echo.shutdown()
                worker.join(timeout=5)

    def test_plain_http_is_rejected(self):
        with self.connect() as client:
            client.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
            self.assertEqual(self.response(client), b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")

    def test_unreachable_upstream_returns_bad_gateway(self):
        # Reserving without listen keeps other processes from taking this port.
        with socket.socket() as unavailable:
            unavailable.bind(("127.0.0.1", 0))
            port = unavailable.getsockname()[1]
            with self.connect() as client:
                client.sendall(f"CONNECT 127.0.0.1:{port} HTTP/1.1\r\n\r\n".encode())
                self.assertEqual(self.response(client), b"HTTP/1.1 502 Bad Gateway\r\n\r\n")


if __name__ == "__main__":
    unittest.main()
