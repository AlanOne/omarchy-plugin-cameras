# Cameras

A camera snapshot pill for the Omarchy bar. Click it for a popup with a live thumbnail,
a one-click live-view launch (via `mpv`), and a switcher for however many cameras you've
added. Add or remove cameras right from the popup — nothing to hand-edit, no fixed camera
count. Works with Reolink (and most other RTSP/ONVIF cameras) and Google Nest cameras.

![Cameras plugin popup](preview.png)

## How it works

This plugin is a thin QML front-end. All the actual camera protocol handling — RTSP,
ONVIF, Nest's OAuth+WebRTC — is done by [go2rtc](https://github.com/AlexxIT/go2rtc), a
small self-hosted streaming server that you run once, locally. The plugin talks only to
go2rtc's local HTTP API (default `127.0.0.1:1984`) to list/add/remove cameras and fetch
snapshots, and to its local RTSP restream port (default `127.0.0.1:8554`) to hand a URL to
`mpv` for the live view. It never talks to a camera's or vendor's own protocol/API
directly, and it never stores any credentials itself — those live only in go2rtc's own
config, which go2rtc writes to when you use the popup's "Add camera" form.

**Why a separate service instead of the plugin doing this itself?** Plugins run
unsandboxed inside the long-running Omarchy shell process. Speaking RTSP/ONVIF/WebRTC
correctly (and safely) is a real amount of code with real amounts of dependencies — that
does not belong inside the shell process. go2rtc is a mature, single-binary project built
exactly for this, so the plugin stays small and only does UI + simple HTTP calls.

## Prerequisites

- **[Docker](https://docs.docker.com/engine/install/)** (or Podman with a Docker-compatible
  CLI) — to run go2rtc.
- **`mpv`** — used to open the live view. Install with your distro's package manager
  (`sudo pacman -S mpv` on Arch/Omarchy).
- **`curl`** — used internally by the plugin to talk to go2rtc's API. Present by default on
  virtually every Linux install, including Omarchy.

## Install

```sh
omarchy plugin add https://github.com/AlanOne/omarchy-plugin-cameras.git --enable
```

## Set up go2rtc

The plugin needs a go2rtc instance to talk to. A ready-to-use `docker-compose.yml` and
config example are bundled in this repo's [`go2rtc/`](go2rtc) folder:

```sh
cd ~/.config/omarchy/plugins/io.github.alanone.cameras/go2rtc
cp go2rtc.yaml.example go2rtc.yaml
docker compose up -d
```

That's it — `go2rtc.yaml` starts with zero cameras configured. You add cameras from the
plugin's popup, not by editing this file (see below); go2rtc writes them into it for you.

If you'd rather run go2rtc somewhere other than this machine/localhost, point the plugin's
settings (`go2rtcHost`, `go2rtcRtspHost` — see **Configure** below) at wherever it's
listening.

### Updating go2rtc

The bundled `docker-compose.yml` pins a specific go2rtc version *and* digest
(`alexxit/go2rtc:1.9.14@sha256:...`) rather than `:latest`. This container runs with host
networking and a writable bind-mounted config, so silently following upstream's `:latest`
tag would mean an unreviewed image update gets that same access the next time the container
restarts. To update deliberately:

1. Check the [go2rtc releases](https://github.com/AlexxIT/go2rtc/releases) for what changed.
2. Get the new digest: `docker pull alexxit/go2rtc:<new-version>` then
   `docker image inspect alexxit/go2rtc:<new-version> --format '{{index .RepoDigests 0}}'`.
3. Update the `image:` line in `docker-compose.yml` to
   `alexxit/go2rtc:<new-version>@<digest>`, then `docker compose up -d` to recreate the
   container on the new image.

## Usage

Click the camera pill in the bar to open the popup:

- **Camera switcher** (only shown once you have 2+ cameras) — tabs across the top to pick
  which camera the popup shows.
- **Snapshot preview** — refreshes automatically (interval configurable). Each refresh swaps
  in silently once the new frame has actually loaded; you only see a "Loading…" placeholder
  the first time a camera's frame loads, and "Camera unreachable" if it genuinely can't be
  reached — a routine refresh never blanks the preview you're already looking at.
- **Open live view** — launches `mpv` against the full-quality RTSP restream.
- **Edit** — change a camera's name and/or stream URL(s) in place (e.g. after a password or
  IP change), prefilled with its current values.
- **Remove** — removes the selected camera (asks go2rtc to delete it; this also removes it
  from `go2rtc.yaml`).
- **+ Add camera** — add a new camera: a name, a stream URL, and an optional second
  lower-resolution URL (used for the thumbnail/snapshot so the live view stays full
  quality). See the two setup guides below for how to get that URL for your camera.

A fresh install starts with zero cameras — the popup opens straight to the "Add a camera"
form.

## Setting up a Reolink camera

This works for any Reolink camera that supports direct RTSP/ONVIF (most standalone
cameras, e.g. the E1/E3/RLC series). Cameras that only work through a Reolink Home Hub/NVR
aren't directly reachable this way — point the URL at the hub/NVR's RTSP output instead, if
it has one.

1. **Enable RTSP in the Reolink app.** Open the camera in the Reolink app → **Device
   Settings** → the device info row → **Advanced Network Settings** → **Server Settings** →
   turn on **RTSP** (and **ONVIF**, if you want it). Note the camera's local IP while
   you're there (also visible in your router's device list).
2. **Know your camera's RTSP credentials.** This is the camera's own device login (usually
   `admin` + a password you set during setup) — not your Reolink cloud/app account.
3. **Build the stream URL:**
   ```
   rtsp://USER:PASSWORD@CAMERA_IP:554/Preview_01_main   ← full quality (live view)
   rtsp://USER:PASSWORD@CAMERA_IP:554/Preview_01_sub    ← lower quality (thumbnail)
   ```
4. In the plugin popup, click **+ Add camera**, give it a name, paste the `_main` URL into
   **Stream URL** and the `_sub` URL into **Lower-res URL**, then **Add**.

### Remote access (away from home)

To view the camera when you're not on the same network, you need port forwarding on your
router pointing an external port at the camera's RTSP port (554) and, ideally, its HTTPS
port too. If your camera is behind two routers (a modem/ISP router in front of your own
router — check by comparing your ISP router's WAN IP to what "what's my IP" shows you; if
they don't match, you likely have a second router upstream), you need to forward on
**both**: the inner router forwards to the camera, the outer router forwards to the inner
router's WAN-facing IP on the same port.

**Security note:** this puts your camera's RTSP port on the open internet. Use a
non-default external port, a strong non-default camera password, and keep the camera's
firmware current. Then use the public IP/port instead of the local one in step 3 above.

## Setting up a Google Nest camera

This uses Google's [Smart Device Management (SDM) API](https://developers.google.com/nest/device-access),
via Device Access — a Google program that costs a one-time $5 registration fee. It only
works with a personal Google account (not Google Workspace / Advanced Protection accounts).
Nest cameras are WebRTC-only over this API — go2rtc's `nest` source handles that for you.

### 1. Google Cloud project + OAuth client

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and create a project
   (any name).
2. **APIs & Services → Library** → search **Smart Device Management API** → **Enable**.
3. **APIs & Services → OAuth consent screen** → User type **External** → fill in an app
   name and your email as support/contact → add the scope
   `https://www.googleapis.com/auth/sdm.service` → under **Test users**, add your own
   Google account email. Leave the app in "Testing" — no Google review needed for personal
   use.
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID** → type **Web
   application** → add `https://www.google.com` as an authorized redirect URI (this lets
   you complete the flow by copying a code out of the address bar — no local server
   needed).
5. Note the **Client ID** and **Client Secret**.

### 2. Device Access registration ($5 one-time)

1. Go to [console.nest.google.com/device-access](https://console.nest.google.com/device-access),
   accept the terms, pay the $5 fee.
2. **Create project** → give it a name → paste in the OAuth Client ID from step 1.
3. Note the **Device Access Project ID** shown (a UUID).

### 3. Authorize your account and get a refresh token

Open this URL in a browser (fill in your own project ID and client ID), logged into the
Google account your Nest camera is on:

```
https://nestservices.google.com/partnerconnections/PROJECT_ID/auth?redirect_uri=https://www.google.com&access_type=offline&prompt=consent&client_id=CLIENT_ID&response_type=code&scope=https://www.googleapis.com/auth/sdm.service
```

Grant access to the home/structure with your camera. You'll land on
`https://www.google.com/?code=...` — copy the `code` value, then exchange it immediately
(it expires fast):

```sh
curl -sL -X POST 'https://www.googleapis.com/oauth2/v4/token' \
  --data-urlencode "client_id=CLIENT_ID" \
  --data-urlencode "client_secret=CLIENT_SECRET" \
  --data-urlencode "code=THE_CODE_YOU_COPIED" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "redirect_uri=https://www.google.com"
```

The response's `refresh_token` is what you'll use going forward — it doesn't expire unless
unused for 6+ months.

### 4. Find your device ID(s)

```sh
curl -s -H "Authorization: Bearer ACCESS_TOKEN" \
  "https://smartdevicemanagement.googleapis.com/v1/enterprises/PROJECT_ID/devices"
```

(`ACCESS_TOKEN` is the `access_token` from the previous response — it's only valid for an
hour; re-run step 3's curl with `grant_type=refresh_token&refresh_token=...` instead of the
code params to get a fresh one if needed.) Find your camera in the `devices` array and take
the last segment of its `name` field — that's the device ID.

### 5. Add it in the plugin

Build the source URL:

```
nest:?client_id=CLIENT_ID&client_secret=CLIENT_SECRET&refresh_token=REFRESH_TOKEN&project_id=PROJECT_ID&device_id=DEVICE_ID
```

In the plugin popup, **+ Add camera** → give it a name → paste that whole URL into
**Stream URL** → leave **Lower-res URL** blank (Nest only offers one stream) → **Add**.

**Note on battery-powered Nest doorbells/cameras:** these need to be awake/charged to
respond to a stream request — if one shows "unreachable," check its battery before
assuming something's misconfigured.

## Configure

The plugin has four settings (via Omarchy's plugin settings UI):

| Setting | Default | Purpose |
|---|---|---|
| `go2rtcHost` | `127.0.0.1:1984` | go2rtc's HTTP API host:port |
| `go2rtcRtspHost` | `127.0.0.1:8554` | go2rtc's re-streamed RTSP host:port (for `mpv`) |
| `refreshSeconds` | `30` | How often the snapshot refreshes |
| `popupWidth` | `340` | Popup width in pixels (before the theme's spacing scale) — the live preview is a 16:9 thumbnail scaled to this width, so e.g. `680` doubles the preview size |

Move the widget's position in the bar:

```sh
omarchy bar move io.github.alanone.cameras --section right
```

## Remove

```sh
omarchy plugin remove io.github.alanone.cameras
```

This removes the plugin, not go2rtc or its camera config — stop that separately with
`docker compose down` in your go2rtc directory if you want to tear it down too.

## Security

- The plugin runs `curl` (to talk to go2rtc's API) and `mpv` (to open a live view) as
  external processes — nothing else.
- It only ever talks to the `go2rtcHost`/`go2rtcRtspHost` you configure (localhost by
  default). It never talks to a camera vendor's cloud service or embeds any credentials of
  its own.
- go2rtc's own HTTP API returns stream info including credentials embedded in RTSP/Nest
  URLs. Keep `api.listen` bound to `127.0.0.1` (the bundled example config does this)
  unless you specifically need to reach go2rtc's own web UI from elsewhere — in that case,
  put it behind your own auth/reverse proxy rather than exposing it directly.
- If you expose a camera to the internet via port forwarding for remote access (see the
  Reolink guide above), that exposure is on your router/camera, not on this plugin —
  usual precautions apply (non-default ports, strong passwords, current firmware).

## Troubleshooting

- **Camera shows "unreachable"**: confirm go2rtc is running (`docker compose ps` in its
  directory) and reachable at the configured `go2rtcHost`; check
  `docker compose logs go2rtc` for the actual connection error to the camera.
- **Popup says "No cameras found"**: you haven't added one yet, or go2rtc isn't reachable —
  click the pill and use the "Add a camera" form, or check go2rtc is up.
- **Live view doesn't open**: confirm `mpv` is installed and on your `PATH`.
- **Bar icon doesn't theme correctly after an update**: run
  `omarchy-shell shell rescanPlugins`; if that doesn't pick up a change, a full
  `omarchy-restart-shell` will.

## License

MIT — see [LICENSE](LICENSE).
