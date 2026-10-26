#!/usr/bin/env python3
"""
probe-ssap.py — minimal SSAP client to check for a specific app on an LG webOS device.
Connects to ws://<ip>:3000, pairs, then queries applicationManager/getAppInfo.

Usage:
    python3 scripts/probe-ssap.py 192.168.1.249 com.webos.app.voiceweb
    python3 scripts/probe-ssap.py 192.168.1.249   # lists a few known apps
"""

import json
import socket
import struct
import base64
import hashlib
import os
import sys
import time

TARGET_APPS = [
    "com.webos.app.voiceweb",
    "com.webos.app.adoverlayex",
    "com.webos.app.adoverlay",
    "com.webos.app.acroverlay",
    "com.webos.app.tinybrowser",
    "com.webos.app.dangbei-overlay",
]

HANDSHAKE = json.dumps({
    "type": "register",
    "id": "reg0",
    "payload": {
        "forcePairing": False,
        "pairingType": "PROMPT",
        "manifest": {
            "manifestVersion": 1,
            "appVersion": "1.1",
            "signed": {
                "created": "20140509",
                "appId": "com.lge.test",
                "vendorId": "com.lge",
                "localizedAppNames": {"": "LG Remote App", "ko-KR": "리모컨 앱"},
                "localizedVendorNames": {"": "LG Electronics"},
                "permissions": ["TEST_SECURE", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD",
                                "READ_INSTALLED_APPS", "READ_LGE_SDX", "READ_NOTIFICATIONS",
                                "SEARCH", "WRITE_SETTINGS", "WRITE_NOTIFICATION_ALERT",
                                "CONTROL_POWER", "READ_CURRENT_CHANNEL", "READ_RUNNING_APPS",
                                "READ_UPDATE_INFO", "UPDATE_FROM_REMOTE_APP",
                                "READ_LGE_TV_INPUT_EVENTS", "READ_TV_CURRENT_TIME"],
                "serial": "2f930e2d2cfe083771f68e4fe7bb07",
            },
            "permissions": ["LAUNCH", "LAUNCH_READY", "APP_TO_APP", "CLOSE", "TEST_OPEN",
                            "TEST_PROTECTED", "CONTROL_AUDIO", "CONTROL_DISPLAY",
                            "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_RECORDING",
                            "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV",
                            "CONTROL_POWER", "READ_APP_STATUS", "READ_CURRENT_CHANNEL",
                            "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE", "READ_RUNNING_APPS",
                            "READ_TV_CHANNEL_LIST", "WRITE_NOTIFICATION_TOAST",
                            "READ_POWER_STATE", "READ_COUNTRY_INFO"],
            "signatures": [{"signatureVersion": 1, "signature": "fg=="}],
        },
    },
})

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_handshake(sock, host):
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((
        f"GET / HTTP/1.1\r\n"
        f"Host: {host}:3000\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n"
    ).encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        resp += sock.recv(4096)
    expected = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
    assert expected.encode() in resp, "WS handshake failed"


def ws_send(sock, msg):
    data = msg.encode() if isinstance(msg, str) else msg
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    length = len(data)
    if length < 126:
        header = struct.pack("!BB", 0x81, 0x80 | length) + mask
    elif length < 65536:
        header = struct.pack("!BBH", 0x81, 0xFE, length) + mask
    else:
        header = struct.pack("!BBQ", 0x81, 0xFF, length) + mask
    sock.sendall(header + masked)


def ws_recv(sock):
    def read_exact(n):
        buf = b""
        while len(buf) < n:
            buf += sock.recv(n - len(buf))
        return buf

    b1, b2 = struct.unpack("!BB", read_exact(2))
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(8))[0]
    masked = bool(b2 & 0x80)
    if masked:
        mask = read_exact(4)
    payload = read_exact(length)
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return payload.decode(errors="replace")


def send_request(sock, uri, payload=None, req_id="req1"):
    msg = {"type": "request", "id": req_id, "uri": uri}
    if payload:
        msg["payload"] = payload
    ws_send(sock, json.dumps(msg))


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.249"
    apps_to_check = sys.argv[2:] if len(sys.argv) > 2 else TARGET_APPS

    print(f"Connecting to {host}:3000 ...")
    sock = socket.create_connection((host, 3000), timeout=10)
    ws_handshake(sock, host)
    print("WebSocket connected. Registering (accept the prompt on the projector) ...")

    ws_send(sock, HANDSHAKE)

    # Wait for pairing confirmation
    for _ in range(30):
        msg = ws_recv(sock)
        data = json.loads(msg)
        if data.get("type") == "registered":
            print(f"  Paired! Client key: {data.get('payload', {}).get('client-key', '(none)')}\n")
            break
        if data.get("type") == "response" and data.get("payload", {}).get("pairingType"):
            print("  Waiting for you to accept the pairing prompt on the projector ...")
    else:
        print("  Timed out waiting for pairing.")
        return

    sock.settimeout(5)
    results = {}
    for i, app_id in enumerate(apps_to_check):
        req_id = f"app{i}"
        send_request(sock, "ssap://com.webos.applicationManager/getAppInfo",
                     {"id": app_id}, req_id=req_id)
        try:
            msg = ws_recv(sock)
            data = json.loads(msg)
            payload = data.get("payload", {})
            if payload.get("returnValue") and payload.get("appInfo"):
                info = payload["appInfo"]
                print(f"  ✅  {app_id}")
                print(f"      title:   {info.get('title', '?')}")
                print(f"      version: {info.get('version', '?')}")
                results[app_id] = True
            else:
                err = payload.get("errorText", "not found")
                print(f"  ❌  {app_id} — {err}")
                results[app_id] = False
        except socket.timeout:
            print(f"  ?   {app_id} — timeout")
            results[app_id] = None
        time.sleep(0.2)

    sock.close()
    print()
    if results.get("com.webos.app.voiceweb"):
        print("voiceweb is present — SlopBro exploit path should work on this device.")
    else:
        alts = [k for k, v in results.items() if v and k != "com.webos.app.voiceweb"]
        if alts:
            print(f"voiceweb not found, but alternative entry points present: {alts}")
        else:
            print("No known exploit entry-point apps found. Manual investigation needed.")


if __name__ == "__main__":
    main()
