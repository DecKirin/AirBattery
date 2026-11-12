#!/usr/bin/env python3
"""Push devices into GlassyBattery over BatteryBridge's HTTP API.

Standard library only. Usable as a module (BridgeClient) or from the shell:

    python3 glassybridge.py push --id ups --name "Office UPS" --level 87
    python3 glassybridge.py push --id ups --name "Office UPS" --level 87 --charging --icon powerplug.portrait.fill
    python3 glassybridge.py upload-icon --name ups --file ups.svg
    python3 glassybridge.py push --id ups --name "Office UPS" --level 87 --custom-icon ups --icon powerplug.portrait.fill
    python3 glassybridge.py list
    python3 glassybridge.py remove --id ups

The first run registers as "--app-name" (default "glassybridge.py") and keeps the token in
~/Library/Application Support/GlassyBridgeExample/token.json. In allowlist mode the first push
waits for you to click Approve in GlassyBattery.

HTTP clients have no connection for GlassyBattery to watch, so their devices stay until the
app's "disappear after" time runs out unless you push again or remove them. Push at least every
few minutes to keep a device fresh.
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request

DISCOVERY = os.path.expanduser("~/Library/Application Support/GlassyBattery/bridge.json")
TOKEN_FILE = os.path.expanduser("~/Library/Application Support/GlassyBridgeExample/token.json")


class BridgeError(Exception):
    def __init__(self, status, code, message):
        super().__init__(f"{status} {code}: {message}")
        self.status, self.code, self.message = status, code, message


def discover():
    """The API base URL from bridge.json, or None when BatteryBridge isn't running."""
    try:
        with open(DISCOVERY) as f:
            info = json.load(f)
        os.kill(info["pid"], 0)  # a file left by a crashed app points at nothing
        return info["url"]
    except (OSError, ValueError, KeyError):
        return None


class BridgeClient:
    def __init__(self, base_url, token=None):
        self.base_url = base_url.rstrip("/")
        self.token = token

    def _call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base_url + path, data=data, method=method)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            try:
                detail = json.load(error)["error"]
            except (ValueError, KeyError):
                detail = {"code": "http_error", "message": error.reason}
            raise BridgeError(error.code, detail["code"], detail["message"]) from None

    def register(self, name, bundle_id=None):
        """Returns {"clientID", "token", "status"}; status is "pending" in allowlist mode."""
        reply = self._call("POST", "/v1/register", {"name": name, "bundleID": bundle_id})
        self.token = reply["token"]
        return reply

    def me(self):
        return self._call("GET", "/v1/me")

    def types(self):
        return self._call("GET", "/v1/types")["types"]

    def put_device(self, device_id, name, type, level=None, charging=False, model=None,
                   has_battery=True, parent=None, icon=None, custom_icon=None):
        body = {"name": name, "type": type, "level": level, "charging": charging, "model": model,
                "hasBattery": has_battery, "parent": parent, "icon": icon, "customIcon": custom_icon}
        return self._call("PUT", f"/v1/devices/{device_id}", body)["device"]

    def put_devices(self, devices):
        """All or nothing: a list of dicts with "id", "name", "type", "level", ..."""
        return self._call("POST", "/v1/devices:batch", devices)["devices"]

    def remove_device(self, device_id):
        self._call("DELETE", f"/v1/devices/{device_id}")

    def upload_icon(self, name, path):
        """Uploads a PDF, SVG or PNG (by its extension) for devices to use as "customIcon"."""
        fmt = os.path.splitext(path)[1].lstrip(".").lower()
        with open(path, "rb") as f:
            data = base64.b64encode(f.read()).decode("ascii")
        return self._call("PUT", f"/v1/icons/{name}", {"format": fmt, "data": data})["icon"]

    def icons(self):
        return self._call("GET", "/v1/icons")["icons"]

    def delete_icon(self, name):
        self._call("DELETE", f"/v1/icons/{name}")


def load_token():
    try:
        with open(TOKEN_FILE) as f:
            return json.load(f)["token"]
    except (OSError, ValueError, KeyError):
        return None


def save_token(token):
    os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
    with open(os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump({"token": token}, f)


def connected_client(app_name, base_url=None):
    """A client with a working token, registering (again) when there is none or it was reset."""
    base_url = base_url or discover()
    if not base_url:
        sys.exit("BatteryBridge isn't running. Turn it on in GlassyBattery → Settings → BatteryBridge.")
    client = BridgeClient(base_url, load_token())
    if client.token:
        try:
            client.me()
            return client
        except BridgeError as error:
            if error.code != "unauthorized":
                raise
    reply = client.register(app_name)
    save_token(client.token)
    if reply["status"] == "pending":
        print("Waiting for approval: click Approve in the GlassyBattery notification or settings.", file=sys.stderr)
    return client


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--url", help="API base URL (default: read from bridge.json)")
    parser.add_argument("--app-name", default="glassybridge.py", help="name shown in GlassyBattery's app list")
    commands = parser.add_subparsers(dest="command", required=True)

    push = commands.add_parser("push", help="add or update a device")
    push.add_argument("--id", required=True, help="your own ID for the device: A–Z a–z 0–9 . _ -")
    push.add_argument("--name", required=True)
    push.add_argument("--type", default="generic", help="device type, which picks the icon; see `types`")
    push.add_argument("--icon", help='an SF Symbol to show instead, like "printer.fill"')
    push.add_argument("--custom-icon", help="the name of an icon uploaded with upload-icon (shown first)")
    push.add_argument("--level", type=int, help="battery percentage, 0–100")
    push.add_argument("--charging", action="store_true")
    push.add_argument("--model")
    push.add_argument("--no-battery", action="store_true", help="show the device without a percentage")

    remove = commands.add_parser("remove", help="remove a device")
    remove.add_argument("--id", required=True)
    commands.add_parser("list", help="show this app's devices")
    commands.add_parser("types", help="list the device types GlassyBattery has icons for")
    upload = commands.add_parser("upload-icon", help="upload a PDF, SVG or PNG for --custom-icon")
    upload.add_argument("--name", required=True, help="the name devices refer to it by")
    upload.add_argument("--file", required=True)
    commands.add_parser("icons", help="list this app's uploaded icons")
    delete_icon = commands.add_parser("delete-icon", help="delete an uploaded icon")
    delete_icon.add_argument("--name", required=True)

    args = parser.parse_args()
    try:
        client = connected_client(args.app_name, args.url)
        if args.command == "push":
            device = client.put_device(args.id, args.name, args.type, args.level, args.charging,
                                       args.model, has_battery=not args.no_battery, icon=args.icon,
                                       custom_icon=args.custom_icon)
            print(json.dumps(device, indent=2))
        elif args.command == "remove":
            client.remove_device(args.id)
        elif args.command == "list":
            print(json.dumps(client.me()["devices"], indent=2))
        elif args.command == "types":
            print("\n".join(client.types()))
        elif args.command == "upload-icon":
            print(json.dumps(client.upload_icon(args.name, args.file), indent=2))
        elif args.command == "icons":
            print(json.dumps(client.icons(), indent=2))
        elif args.command == "delete-icon":
            client.delete_icon(args.name)
    except BridgeError as error:
        if error.code == "pending":
            sys.exit("Not approved yet: click Approve in GlassyBattery, then run this again.")
        sys.exit(f"BatteryBridge refused: {error.message} ({error.code})")
    except urllib.error.URLError as error:
        sys.exit(f"Couldn't reach BatteryBridge: {error.reason}")


if __name__ == "__main__":
    main()
