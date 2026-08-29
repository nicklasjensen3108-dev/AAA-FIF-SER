#!/usr/bin/env python3
"""Tiny TCP trace proxy used by FIFA 13 Local FUT.

This intentionally uses only the Python standard library so the public build does
not require a separate .NET 8 runtime. Ports are supplied through the same
FUT13_TRACE_LISTEN_PORT / FUT13_TRACE_TARGET_PORT environment variables used by
the older C# helper.
"""
from __future__ import annotations

import os
import signal
import socket
import threading
import uuid


def read_port(name: str, fallback: int) -> int:
    try:
        value = int(os.environ.get(name, ""))
    except ValueError:
        return fallback
    return value if 0 < value <= 65535 else fallback


def describe_tls_records(data: bytes) -> str:
    records: list[str] = []
    offset = 0
    names = {20: "ChangeCipherSpec", 21: "Alert", 22: "Handshake", 23: "ApplicationData"}
    while offset + 5 <= len(data):
        content_type = data[offset]
        version = f"{data[offset + 1]:02X}{data[offset + 2]:02X}"
        length = (data[offset + 3] << 8) | data[offset + 4]
        records.append(f"{names.get(content_type, 'Raw')}/v{version}/len={length}")
        if offset + 5 + length > len(data):
            records.append("fragmented")
            break
        offset += 5 + length
    if not records or offset < len(data):
        records.append("bytes=" + data[:32].hex().upper())
    return f"read={len(data)} [{', '.join(records)}]"


def shutdown_send(sock: socket.socket) -> None:
    try:
        sock.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def pump(conn_id: str, direction: str, source: socket.socket, destination: socket.socket) -> None:
    try:
        while True:
            data = source.recv(32 * 1024)
            if not data:
                print(f"[{conn_id}] {direction} EOF", flush=True)
                shutdown_send(destination)
                return
            print(f"[{conn_id}] {direction} {describe_tls_records(data)}", flush=True)
            destination.sendall(data)
    except OSError as exc:
        print(f"[{conn_id}] {direction} IO {exc}", flush=True)
        shutdown_send(destination)


def handle_client(client: socket.socket, target_port: int) -> None:
    conn_id = uuid.uuid4().hex[:8]
    try:
        remote = client.getpeername()
    except OSError:
        remote = "?"
    print(f"[{conn_id}] CONNECT client={remote}", flush=True)
    upstream: socket.socket | None = None
    try:
        upstream = socket.create_connection(("127.0.0.1", target_port), timeout=8.0)
        upstream.settimeout(None)
        client.settimeout(None)
        print(f"[{conn_id}] UPSTREAM connected", flush=True)
        t1 = threading.Thread(target=pump, args=(conn_id, "C->S", client, upstream), daemon=True)
        t2 = threading.Thread(target=pump, args=(conn_id, "S->C", upstream, client), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except OSError as exc:
        print(f"[{conn_id}] SOCKET {exc}", flush=True)
    finally:
        try:
            client.close()
        except OSError:
            pass
        if upstream is not None:
            try:
                upstream.close()
            except OSError:
                pass
        print(f"[{conn_id}] DISCONNECT", flush=True)


def main() -> int:
    listen_port = read_port("FUT13_TRACE_LISTEN_PORT", 42127)
    target_port = read_port("FUT13_TRACE_TARGET_PORT", 42128)
    stop = threading.Event()

    def request_stop(*_args: object) -> None:
        stop.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, request_stop)
        except (ValueError, OSError):
            pass

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", listen_port))
    listener.listen(32)
    listener.settimeout(0.5)
    print(f"FUT13 trace proxy (Python): 127.0.0.1:{listen_port} -> 127.0.0.1:{target_port}", flush=True)

    try:
        while not stop.is_set():
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if stop.is_set():
                    break
                raise
            threading.Thread(target=handle_client, args=(client, target_port), daemon=True).start()
    finally:
        listener.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
