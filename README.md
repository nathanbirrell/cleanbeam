# cleanbeam

Debloat and optimise an **LG CineBeam Q (HU710PB-GL)** running webOS 6.3.1 for use as a dedicated
streaming projector. No antenna, no smart-TV cruft — just Plex/streaming apps and clean HDMI.

Root is required. Everything here assumes [Homebrew Channel (HBC)](https://github.com/webosbrew/webos-homebrew-channel)
is installed and SSH is enabled.

## Device

| Field | Value |
| :---- | :---- |
| Model | HU710PB-GL |
| webOS | 6.3.1 (Rockhopper kisscurl-kavir) |
| Firmware | 03.00.27 |
| SoC | k7lp / Realtek (armv7l) |
| SSH | `ssh root@<ip>` — password `alpine`, or key via HBC settings |

## Step 1 — Root the device

See [`ROOTING.md`](ROOTING.md) for the confirmed path for this projector, including
CineBeam-specific differences from standard LG TV rooting guides.

## Step 2 — Block firmware updates

HBC sets a flag that prevents OTA updates. Verify it is in place:

```sh
ssh root@<ip> "ls /var/luna/preferences/webosbrew_block_updates"
```

If the file is missing, create it:

```sh
ssh root@<ip> "touch /var/luna/preferences/webosbrew_block_updates"
```

**Do not update the firmware.** Updates patch the root exploit.

## Step 3 — Deploy the init.d hooks

HBC runs every executable in `/var/lib/webosbrew/init.d/` on each boot via busybox `run-parts`.
Files must have **no extension** — busybox silently skips any filename containing a dot.

Copy all hooks to the projector and make them executable:

```sh
scp init.d/* root@<ip>:/var/lib/webosbrew/init.d/
ssh root@<ip> "chmod +x /var/lib/webosbrew/init.d/*"
```

### What each hook does

#### `30-debloat`

Stops and runtime-masks 13 services that have no purpose on a streaming projector:

| Service | What it does |
| :------ | :----------- |
| `contentminer.service` | ACR — watches the screen for ad/viewing telemetry |
| `nudge.service` | Promotional popups and feature tips |
| `rdxd.service` | Continuously logs diagnostics/traces to flash |
| `remotelogger.service` | Ships system logs to LG servers |
| `com.webos.service.camera.service` | USB webcam daemon |
| `voiceconductor.service` | LG voice assistant |
| `voiceinput.service` | Voice input pipeline |
| `crashd.service` | Crash report uploader |
| `update.service` | Software update daemon (triple-blocked: HBC flag + hosts + this) |
| `tvdataexchanger.service` | TV broadcast/EPG data exchange (no antenna port) |
| `com.webos.app.multiview.service` | Picture-in-picture |
| `db8-epgdb.service` | Electronic programme guide database |
| `iepg-ping-fepg.service` | EPG ping service |

Masks are written to `/run/systemd/transient/` (volatile — reapplied every boot).
`webapp-mgr.service` is left running — it is needed for YouTube and other web apps.

**RAM result:** ~220 MB used vs 753 MB baseline, swap down from 146 MB to near zero.

#### `40-hosts`

Bind-mounts a replacement `/etc/hosts` that blocks ~50 LG ad, telemetry, update, and ACR
domains. Requests fail instantly (127.0.0.1) instead of timing out. Includes HBC's own
update-blocking entries since this mount overlays HBC's.

#### `50-preload`

Disables SAM preloading for 19 streaming and promo apps (Netflix, Disney+, Prime Video, etc.)
via `setPreloadPolicy`. Prevents them from being loaded into RAM in the background while
browsing the home screen.

#### `63-luma-home-early` and `65-luma-home-restart`

Fix a boot timing issue with Luma's home integration (see Step 4). Only have effect when
Luma's home integration is enabled.

## Step 4 — Install Luma and enable home integration

[Luma](https://github.com/ecklf/luma) replaces the LG home screen with a native Plex/streaming
launcher. Install it from HBC's app store, then enable the home integration:

```sh
ssh root@<ip> "sh /var/lib/luma-home/home.sh enable"
```

This bind-mounts Luma's binary over `/usr/bin/com.webos.app.home` so the Home button always
opens Luma. LG's home manifest stays in place; Luma registers with SAM itself.

### Boot timing (`63-luma-home-early` + `65-luma-home-restart`)

Luma's default boot hook sleeps 5 seconds before applying the bind-mount. During that window,
pressing Home opens the original LG launcher. Two hooks fix this:

- `63-luma-home-early` — applies the bind-mount at t+2s instead of t+5s, cutting the window
- `65-luma-home-restart` — kills any stale LG home process at t+8s as a fallback

Both are already in `init.d/` and were deployed in Step 3.

**Boot sequence note:** The projector starts on the last-active input (HDMI) and transitions to
Luma automatically once the system is fully up. Pressing Home immediately after the display
appears may still catch the 2-second window. Waiting a moment reliably lands on Luma.

## Step 5 — One-time Luna settings

These write to DB8 and survive reboots without a hook.

### Disable the no-signal art gallery

Without this, a no-signal HDMI input cycles through LG's art gallery images.

```sh
ssh root@<ip>
LUNA_SOCKET=/tmp/var/run/luna-service2/com.palm.hub luna-send -w 3000 -n 1 \
  luna://com.webos.service.settings/setSystemSettings \
  '{"category":"general","settings":{"noSignalScreenSaver":"off"}}' &
LPID=$!; sleep 2; kill $LPID 2>/dev/null; wait $LPID 2>/dev/null
```

## Results

Cold-boot RAM measurements (all hooks active, Luma installed):

| Metric | Baseline (pre-root) | After debloat | After all hooks |
| :----- | :------------------ | :------------ | :-------------- |
| RAM used | 753 MB | 710 MB | ~533 MB |
| Available RAM | 292 MB | 305 MB | ~454 MB |
| Swap in use | 146 MB | 0 MB | ~0 MB |

The largest single wins: stopping ACR/telemetry services (−43 MB RAM, −146 MB swap), disabling
app preloading (frees RAM previously occupied by background Netflix/Disney+/etc. instances), and
blocking ad domains (home screen rows fail fast instead of timing out on every view).

**Boot time is ~31 seconds** regardless of changes — the critical path is
`snapshot-boot-on.service` (12s GPU/display init, a hardware dependency). Quick Start+ standby
is not available on this model. The 13 masked services are not on the critical path so masking
them does not change the countdown; they save post-boot CPU and RAM only.

## Known limitations

**Boot sequence**: The projector boots to the last-active input (HDMI no-signal) rather than
straight to Luma. This is because LG's SDX server overrides the `homeAutoLaunch` setting to
`"off"` on every boot when the network connects. No projector-side fix exists without knowing
the SDX endpoint domain to block. One Home press takes you to Luma.

**AirPlay HEVC**: The LG webOS AirPlay stack does not advertise HEVC support. iPhones show
"video is in a format that can't be streamed on this device" for H.265 content. Workarounds:
use Screen Mirroring instead, Infuse (iOS), or Airflow (Mac) for AirPlay.

**PLXNative and complex MKV files**: Files with many PGS (Blu-ray bitmap) subtitle streams can
fail to play via direct stream. In Plex, force transcoding for those files or lower the quality
setting in PLXNative to avoid direct play.

## Layout

```
init.d/          Boot hooks — deploy to /var/lib/webosbrew/init.d/
scripts/         Utility scripts (probe-ssap.py, fetch-reference.sh)
baseline.md      Pre/post measurements and change log
RESEARCH.md      Root investigation, device facts, community reports
reference/       Upstream project clones (gitignored — re-fetch with scripts/fetch-reference.sh)
tools/slopbro/   SlopBro exploit tool (gitignored)
```
