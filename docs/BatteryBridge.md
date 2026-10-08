# BatteryBridge API

BatteryBridge lets other apps on the same Mac add devices to GlassyBattery. A bridged device shows up in the menu bar dropdown, widgets, the `glassybattery` CLI and AppleScript like any Bluetooth device, and reaches your other Macs through Nearcast.

Use it for anything GlassyBattery can't discover by itself: a vendor's peripheral app, a UPS, a game controller on a custom driver, a Raspberry Pi reporting a sensor's battery through a helper on this Mac.

- [Turning it on](#turning-it-on)
- [Security model](#security-model)
- [Finding the server](#finding-the-server)
- [Registering](#registering)
- [Devices](#devices)
- [HTTP endpoints](#http-endpoints)
- [The stream](#the-stream)
- [Errors](#errors)
- [Lifetime, Nearcast and limits](#lifetime-nearcast-and-limits)
- [Examples](#examples)

## Turning it on

**Settings → BatteryBridge → Enable BatteryBridge.** It is off by default. The pane also sets the port (default `48620`), the mode, and lists every app that has registered.

| Mode | New apps |
|---|---|
| **Block List** (default) | Can add devices right away. You block the ones you don't want. |
| **Allow List** | Wait as *pending* until you click **Approve**, either in the notification GlassyBattery shows or in the app list. |

## Security model

- The server binds `127.0.0.1` only. Nothing off this Mac can connect; other Macs see bridged devices through Nearcast.
- Every request must carry a `Host` of `127.0.0.1`, `localhost` or `[::1]`, with or without the port. This defeats DNS rebinding.
- Requests with an `Origin` header are refused, and request bodies must be `application/json`. Browsers send `Origin` and can't send JSON cross-origin without a preflight, so web pages can't use the API. Native HTTP clients (curl, `URLSession`, `urllib`, `requests`, `fetch` in Node) work as is.
- Each app has its own bearer token. Only a SHA-256 of it is stored. Blocking an app, resetting its token or removing it takes effect immediately, including on open streams.
- An app can only see and change its own devices, and can't take the name of a device that already exists, so it can't overwrite your real Magic Mouse.

## Finding the server

While BatteryBridge runs it writes `~/Library/Application Support/GlassyBattery/bridge.json`:

```json
{
  "api" : 1,
  "pid" : 45900,
  "port" : 48620,
  "streamPort" : 48621,
  "streamURL" : "ws://127.0.0.1:48621",
  "url" : "http://127.0.0.1:48620"
}
```

Read the URLs from here rather than assuming the default port. The file is removed when BatteryBridge stops or GlassyBattery quits. If GlassyBattery crashed it may linger, so check that `pid` is alive (`kill(pid, 0)`). No file means BatteryBridge is off.

`GET /v1/health` needs no token and answers `{"api":1,"app":"GlassyBattery","version":"1.13.4"}`.

## Registering

```sh
curl -s -H 'Content-Type: application/json' \
     -d '{"name":"Logi Options+","bundleID":"com.logi.optionsplus"}' \
     http://127.0.0.1:48620/v1/register
```

```json
{"clientID":"e5a48008d8c2","status":"active","token":"gbb_HdUr6Zaipaj…"}
```

- `name` (required, 1–64 characters) is what the user sees in the app list. `bundleID` is optional but recommended.
- The token is returned **once**. Store it (Keychain, or a file only you can read) and send it as `Authorization: Bearer <token>`.
- Status is `201 active` in Block List mode and `202 pending` in Allow List mode. A pending app gets `403 pending` until it is approved. There's no need to register again: keep the token and retry, or open a stream and wait for `ready`.
- Registering again with the same `bundleID` (or, without one, the same name) **replaces** the token instead of adding a second entry, so an app that lost its token can recover. In Allow List mode this sends the app back to pending: another process could claim the same bundle ID, so a new token never inherits an approval.
- A blocked app gets `403 blocked`, and registering again doesn't change that.
- If the user resets the token in Settings, the old one gets `401 unauthorized`. Register again to get a new one.

## Devices

| Field | Type | Notes |
|---|---|---|
| `id` | string | **Your** ID for the device, 1–64 of `A–Z a–z 0–9 . _ -`. Unique per app. In `PUT` it comes from the URL. |
| `name` | string | 1–64 characters, shown in the dropdown. Must not be in use by another device (`409 name_taken`). |
| `type` | string | Picks the icon, see below. Unknown types fall back to `general_bt`. |
| `level` | int | 0–100. Required unless `hasBattery` is `false`. |
| `charging` | bool | Default `false`. Shows the bolt. |
| `hasBattery` | bool | Default `true`. `false` shows the device without a percentage. |
| `model` | string | Optional, up to 64 characters, shown under the name. |
| `parent` | string | Optional name of another device to group under, like AirPods under their case. |

Responses describe a device the same way, plus `lastUpdate` (Unix seconds).

### Types

`GET /v1/types` returns the current list.

| Type | Icon |
|---|---|
| `general_bt` | Bluetooth (the fallback) |
| `iPhone`, `MobilePhone`, `iPad`, `iPod`, `Watch`, `RealityDevice` | iPhone, generic phone, iPad, iPod touch, Apple Watch, Vision Pro |
| `ap_pod_left`, `ap_pod_right`, `ap_pod_all`, `ap_case` | AirPods-style left, right and both earbuds, and the case |
| `Headphones`, `Headset`, `Speaker` | Headphones, speaker |
| `Keyboard`, `Mouse`, `MMouse`, `Trackpad`, `Gamepad` | Keyboard, mouse, Magic Mouse, trackpad, game controller |
| `ApplePencil`, `Pencil` | Apple Pencil, generic stylus |
| `mac`, `macbook`, `macbookpro`, `macbookair`, `macmini`, `macstudio`, `macpro`, `imac`, `imacpro` | Display, MacBook, Mac mini, Mac Studio, Mac Pro, iMac |

## HTTP endpoints

One request per connection (`Connection: close`), bodies up to 256 KB, `Content-Length` required (no chunked bodies). All endpoints except `health`, `types` and `register` need the bearer token.

| Method & path | Body | Success |
|---|---|---|
| `GET /v1/health` | – | `200` `{api, app, version}` |
| `GET /v1/types` | – | `200` `{types: [...]}` |
| `POST /v1/register` | `{name, bundleID?}` | `201`/`202` `{clientID, token, status}` |
| `GET /v1/me` | – | `200` `{client: {id, name, bundleID, status, nearcast}, devices: [...]}` |
| `PUT /v1/devices/{id}` | a device, `id` optional | `200` `{device}` |
| `POST /v1/devices:batch` | array of up to 32 devices, each with `id` | `200` `{devices: [...]}`. All or nothing: if one is invalid, none are stored. |
| `DELETE /v1/devices/{id}` | – | `204`, or `404 not_found` |

```sh
TOKEN=gbb_…
curl -s -X PUT http://127.0.0.1:48620/v1/devices/mx-keys \
     -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
     -d '{"name":"MX Keys Mini","type":"Keyboard","level":64,"charging":false}'

curl -s -X POST 'http://127.0.0.1:48620/v1/devices:batch' \
     -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
     -d '[{"id":"l","name":"Buds L","type":"ap_pod_left","level":50,"parent":"Buds Case"},
          {"id":"r","name":"Buds R","type":"ap_pod_right","level":52,"parent":"Buds Case"},
          {"id":"c","name":"Buds Case","type":"ap_case","level":90}]'
```

## The stream

For apps that run continuously, the WebSocket at `streamURL` is better than polling HTTP:

- **Cleanup:** devices disappear as soon as the app quits (or crashes), instead of lingering until they expire.
- **Approval:** an app waiting for approval is told the moment it is approved.
- **Revocation:** blocking the app or resetting its token closes the stream with a reason.

The handshake follows the same Host and Origin rules as HTTP. Messages are JSON text frames.

**1. Say hello within 5 seconds**, or the stream is closed:

```json
{"op":"hello","token":"gbb_…","onDisconnect":"remove","ref":"h1"}
```

`onDisconnect` is `"remove"` (default: when this app's last stream closes, all its devices are removed) or `"keep"` (they stay until they expire).

The server answers one of these:
- `{"event":"ready","client":{…}}`
- `{"event":"pending","client":{…}}`. Stay connected; `{"event":"ready",…}` follows when the user approves.
- `{"event":"revoked"}` or `{"event":"blocked"}`, then the stream closes.

**2. Then send any of:**

| Message | Reply |
|---|---|
| `{"op":"upsert","ref":1,"device":{…device with id…}}` | `{"event":"ack","ref":1,"device":{…}}` |
| `{"op":"batch","ref":2,"devices":[…]}` | `{"event":"ack","ref":2,"devices":[…]}`, all or nothing |
| `{"op":"remove","ref":3,"id":"mx-keys"}` | `{"event":"ack","ref":3,"id":"mx-keys"}` |
| `{"op":"ping","ref":4}` | `{"event":"pong","ref":4}` (WebSocket pings are answered too) |

`ref` is optional, may be a string or a number, and is echoed so you can match replies. A rejected message gets `{"event":"error","ref":…,"error":{"code","message"}}` and the stream stays open.

**3. The server may end the stream with** `{"event":"blocked"}`, `{"event":"revoked"}` (token reset: register again) or `{"event":"removed"}` (the user removed your app; registering again starts over).

## Errors

Every error body is `{"error":{"code":"…","message":"…"}}`. Switch on `code`; `message` is for logs.

| Status | Code | Meaning |
|---|---|---|
| 400 | `malformed_request` | Not valid HTTP/1.1 |
| 401 | `unauthorized` | Missing or unknown token (reset, or the app was removed) |
| 403 | `pending` | Waiting for approval in Allow List mode |
| 403 | `blocked` | The user blocked this app |
| 403 | `forbidden_host`, `forbidden_origin` | Non-loopback `Host`, or a browser request |
| 404 | `not_found`, `no_such_route` | No such device / endpoint |
| 405 | `method_not_allowed` | Wrong method for the endpoint |
| 409 | `name_taken` | Another device already has that name |
| 411 | `length_required` | Chunked body |
| 413 | `payload_too_large` | Over 256 KB, or headers over 16 KB |
| 415 | `unsupported_media_type` | Body isn't `application/json` |
| 422 | `invalid_body`, `invalid_<field>`, `too_many_devices` | Validation failed |
| 429 | `too_many_clients` | 64 apps are already registered |

Stream-only codes: `hello_required`, `hello_timeout`, `already_ready`, `unknown_op`.

## Lifetime, Nearcast and limits

- A device stays listed while it keeps being updated. Like every other source it disappears after GlassyBattery's *disappear after* time (20 minutes by default) without an update, and the dropdown marks it ⚠︎ after 10 minutes. HTTP clients should push at least every few minutes; stream clients are cleaned up on disconnect (see `onDisconnect`).
- Bridged devices are shared with your other Macs over Nearcast (when Nearcast is on) unless the user turns off **Nearcast** for that app in the app list.
- Limits: 64 apps, 32 devices per app, 32 devices per batch, 32 concurrent HTTP connections with a 10-second timeout, 32 open streams.
- Devices live in memory. After GlassyBattery restarts, apps push them again; registrations and tokens survive.

## Examples

In [`Examples/BatteryBridge`](../Examples/BatteryBridge):

- [`python/glassybridge.py`](../Examples/BatteryBridge/python/glassybridge.py) is a standard-library HTTP client, usable as a module or from the shell:
  `python3 glassybridge.py push --id ups --name "Office UPS" --level 87`.
- [`swift/BridgeStreamExample.swift`](../Examples/BatteryBridge/swift/BridgeStreamExample.swift) is a dependency-free stream client that reports a simulated headset until you press Ctrl-C:
  `swift BridgeStreamExample.swift`.
