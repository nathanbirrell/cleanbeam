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

Use the [IHIXly/lg-cinebeam-hu710pw-ROOT](https://github.com/IHIXly/lg-cinebeam-hu710pw-ROOT)
SlopBro fork. It was written for the HU710PW (white variant) but works on the HU710PB-GL
identically — same SoC, same webOS version, same exploit entry point (`com.webos.app.voiceweb`).

```sh
git clone https://github.com/IHIXly/lg-cinebeam-hu710pw-ROOT tools/slopbro
cd tools/slopbro
# follow its README — accept the pairing prompt on the projector
```

On success, Homebrew Channel appears on the home screen. Enable SSH in HBC settings and note the
IP shown there.

> The `tools/slopbro/` directory is gitignored here. See `RESEARCH.md` for the full root
> investigation and community reports.

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

#### `65-luma-home-restart`

Fixes a boot timing issue with Luma's home integration (see Step 4). Run this only after
Luma is installed.

## Step 4 — Install Luma and enable home integration

[Luma](https://github.com/ecklf/luma) replaces the LG home screen with a native Plex/streaming
launcher. Install it from HBC's app store, then enable the home integration:

```sh
ssh root@<ip> "sh /var/lib/luma-home/home.sh enable"
```

This bind-mounts Luma's binary over `/usr/bin/com.webos.app.home` so the Home button always
opens Luma. LG's home manifest stays in place; Luma registers with SAM itself.

### Boot timing fix (`65-luma-home-restart`)

Luma's boot hook (`64-luma-home`) forks a background `sleep 5; apply` job. During those 5
seconds webOS SAM can launch `com.webos.app.home` using the original LG binary. Our hook kills
that stale process at t+8s — after the bind-mount is guaranteed to be in place — so the next
Home press launches Luma's binary.

This hook is already in `init.d/` and was deployed in Step 3. It only has effect when Luma's
home integration is enabled.

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

Cold-boot measurements after all changes:

| Metric | Baseline (pre-root) | After |
| :----- | :------------------ | :---- |
| RAM used | 753 MB | ~533 MB |
| Available RAM | 292 MB | ~454 MB |
| Swap in use | 146 MB | ~0 MB |

Boot time is ~31 seconds regardless — the critical path is `snapshot-boot-on.service`
(12s GPU/display init), a hardware dependency. Quick Start+ is not available on this model.

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
