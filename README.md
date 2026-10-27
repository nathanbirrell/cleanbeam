# cleanbeam

Debloat and optimise an **LG CineBeam Q (HU710PB-GL)** running webOS 6.3.1 for use as a dedicated
streaming projector. No antenna, no smart-TV cruft — just Plex/streaming apps and clean HDMI.

Root is required. Everything here assumes [Homebrew Channel (HBC)](https://github.com/webosbrew/webos-homebrew-channel)
is installed and SSH is enabled.

> **Disclaimer:** This documents what worked on my own device. Rooting modifies your
> projector at your own risk — it may void your warranty, breach LG's terms of service,
> or brick the device. Nothing here is affiliated with or endorsed by LG. Use it only on
> hardware you own. No warranty; see [`LICENSE`](LICENSE).

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

HBC starts the hooks about 32s into boot and runs them one at a time. `30-debloat` and
`50-preload` move themselves to the background so they don't hold up the rest; their
start and finish times go to `/tmp/cleanbeam-hooks.log`.

#### `05-luma-home-first`

Applies Luma's bind-mount first thing, then launches Home so Luma is in front at ~40s
without pressing anything (see Step 4). Logs to `/var/lib/luma-home/boot.log`.

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

## Step 4 — Install Luma and enable home integration

[Luma](https://github.com/ecklf/luma) replaces the LG home screen with a native Plex/streaming
launcher. Install it from HBC's app store, then enable the home integration:

```sh
ssh root@<ip> "sh /var/lib/luma-home/home.sh enable"
```

This bind-mounts Luma's binary over `/usr/bin/com.webos.app.home` so the Home button always
opens Luma. LG's home manifest stays in place; Luma registers with SAM itself.

### Replace Luma's boot hook with `05-luma-home-first`

`home.sh enable` installs `/var/lib/webosbrew/init.d/64-luma-home`, which applies the mount
5s after it runs. Remove it; `05-luma-home-first` (deployed in Step 3) does the same job
earlier:

```sh
ssh root@<ip> "rm /var/lib/webosbrew/init.d/64-luma-home"
```

Leaving both in place breaks the boot: every `home.cjs apply` stops all
`/usr/bin/com.webos.app.home` processes, Luma included, so 64's apply closes the Luma that 05
just launched. Running `home.sh enable` again reinstalls 64, so remove it again afterwards.

**Boot sequence:** the projector shows the last input (HDMI "No signal") at ~19s, then Luma
comes to the front by itself at ~40s. Before this hook, Luma only appeared at ~67s, when LG's
preloadmanager launched Home.

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

## Step 6 — Aerial screen saver (Apple only)

LG's screen saver is replaced with Apple TV aerials by
[nathanbirrell/custom-screensaver](https://github.com/nathanbirrell/custom-screensaver), a fork
of the Homebrew Channel app [rchalaaa/custom-screensaver](https://github.com/rchalaaa/custom-screensaver)
with the community videos removed. It plays 161 Apple clips: 139 streamed from
`sylvan.apple.com`, and 22 newer ones that Apple only serves at 240fps, re-encoded to 60fps and
hosted by [aabytt/sonoma-screen-savers](https://github.com/aabytt/sonoma-screen-savers).
Nothing is stored on the projector; each clip streams when it plays.

Build the IPK from the fork, then install it:

```sh
git clone --recurse-submodules https://github.com/nathanbirrell/custom-screensaver ~/dev/custom-screensaver
cd ~/dev/custom-screensaver && npm run build -- --production && ares-package dist/
scripts/install-aerial.sh ~/dev/custom-screensaver/org.rchalaaa.webos.custom-screensaver_1.0.4_all.ipk
```

`install-aerial.sh` keeps the app's settings across the reinstall and writes the boot hook
`50-custom-screensaver-aerial`, which bind-mounts the app's QML over
`com.webos.app.screensaver/qml/main.qml` on every boot. Settings (4K SDR, en-GB, titles on)
are changed in the app itself and saved to its `assets/settings.json`.

The fork keeps the upstream app ID, so if HBC offers an update to this app, declining it keeps
the Apple-only playlist. To test without waiting for the timeout:

```sh
ssh root@<ip>
LUNA_SOCKET=/tmp/var/run/luna-service2/com.palm.hub luna-send -w 3000 -n 1 \
  luna://com.webos.service.tvpower/power/turnOnScreenSaver '{}' &
LPID=$!; sleep 2; kill $LPID 2>/dev/null; wait $LPID 2>/dev/null
```

Any remote button closes it.

## Results

Cold boot, measured from kernel start in `/var/log/bootd.log` (about 3s less than a
stopwatch from the power button):

| Milestone | Before | After `05-luma-home-first` |
| :-------- | :----- | :------------------------- |
| HDMI in front | 16s | 16s |
| Luma bind-mount applied | ~56–59s | ~39s |
| Luma in front | ~67s | ~40s |

The 16s is LG's snapshot (hibernation image) resume and is already the fast path. Quick Start+
(`option.quickStartMode`, hidden on this model) does suspend to RAM, but wakes with a dark screen,
so leave it off.

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
scripts/         Utility scripts (probe-ssap.py, fetch-reference.sh, install-aerial.sh)
baseline.md      Pre/post measurements and change log
RESEARCH.md      Root investigation, device facts, community reports
reference/       Upstream project clones (gitignored — re-fetch with scripts/fetch-reference.sh)
tools/slopbro/   SlopBro exploit tool (gitignored)
```
