# cleanbeam

A collection of tools and hacks for the **LG CineBeam Q (HU710PB-GL)** projector running webOS
6.3.1, for debloating it and improving the everyday experience. The goal is a dedicated streaming
projector: Plex and streaming apps, clean HDMI, no antenna and no smart-TV cruft.

- **Debloat and boot tweaks** (Steps 1–5): root, boot hooks that stop telemetry and ads, and Luma
  as the home screen.
- **Aerial screen saver** (Step 6): Apple TV aerials instead of LG's screen saver.
- **Siri Remote** ([below](#siri-remote-via-a-mac)): control the projector with an Apple Siri
  Remote, through an always-on Mac.

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

#### `20-idle-sleep`

Starts the screen saver after 5 min idle and powers off after 15 more min of screen saver
(20 min idle). LG's own auto-off only covers no signal or 2–8 h without a button press. The
screen-saver timeout is a volatile configd value, so the hook sets it and restarts `nopd` every
boot, then polls the power state every 30s in the background. Playing apps hold a screen-saver
request, so playback is never cut off. Logs to `/tmp/cleanbeam-hooks.log`.

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

It also blocks SBS On Demand's ads. The app asks Google DAI (`dai.google.com`) for a stream
with the ads built in, and when that request fails it plays SBS's plain, ad-free HLS stream
instead. `securepubads.g.doubleclick.net` is blocked too, which removes its pause-screen ads.
The block applies to every app, so other apps that use Google DAI are affected as well.

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

## Siri Remote via a Mac

`tools/siri-remote/siri-bridge` lets a 2015 Siri Remote (the first one with a touchpad) control
the projector. The remote pairs with a Mac, and the bridge on that Mac turns presses and swipes
into key presses that it sends to the projector over Wi-Fi.

The projector can't take the remote directly:
- **Infrared:** the projector's micom chip decodes IR itself and passes on only LG remote codes,
  so Apple IR remotes never reach webOS, even with root.
- **Bluetooth:** the projector can pair the remote, but no data ever arrives. The remote speaks an
  Apple-only protocol that bundles buttons, touch and sensors into one channel and needs an
  undocumented start-up exchange. LG's Bluetooth stack doesn't pass through the requests that
  exchange would need.

macOS supports the remote natively. Its buttons arrive as an HID report (`0xFA`, one bit per
button) and its touchpad as a multitouch device, read through the private `MultitouchSupport`
framework. The bridge sends keys through webOS's own network remote API (SSAP, `wss://` on port
3001), so nothing changes on the projector.

| Remote | Projector |
| :----- | :-------- |
| Swipe up / down / left / right | Arrow keys, one more for each further fifth of the pad (see below) |
| Quick tap near an edge | That arrow, like Apple TV: skips back or forward in a player |
| Any button while the projector is off | Turns it on (needs `--wake`) |
| Touchpad click | OK |
| Hold touchpad click | Long press of OK: opens context menus in Plex and YouTube (needs `--ssh`) |
| Menu | Back |
| TV/Home | Home |
| Hold TV/Home | Turn the projector off |
| Play/Pause | Play / Pause (alternates) |
| Vol+ / Vol− | Volume (hold to repeat, speeding up the longer you hold) |
| Siri | Settings menu |

A swipe sends its first arrow after travelling 30% of the pad, which also locks it to that axis.
Each further 20% sends another arrow, and moving back sends the opposite one, so one long drag
walks through a grid or skips repeatedly in a player. A fast flick adds up to 5 more arrows after
you lift, and resting your finger after a swipe repeats the last arrow.

Big swipes (3+ arrows, or a flick) in quick succession the same way speed up, like scroll
acceleration: each arrow counts ×2, ×3, ×5, then ×8, for scrubbing through a 3-hour movie or mix.
A pause of over a second, a small swipe or a change of direction drops back to ×1. The extra
presses go out 30 ms apart, but never more than a quarter of a second behind, so scrolling stops
when you stop. Any button press or tap drops whatever is still queued. Taps in the middle of the
touchpad, and taps that end in a click, do nothing. Holds take half a second; until then, Click
and TV/Home wait for release before sending their short key.

With `--wake <mac>` (the projector's Wi-Fi MAC), a press while the projector is unreachable sends
a Wake-on-LAN packet. This needs LG's "turn on via Wi-Fi" setting (`wolwowlOnOff`) on. The bridge
then retries every 2 seconds, so keys work as soon as the projector has booted, about 25 seconds
after the press.

SSAP can only send complete key presses, so it can't hold OK down. With `--ssh <host>`, a root
SSH alias for the projector, the bridge keeps one SSH session open to it, running a small Python
loop that writes key-down and key-up events straight into the LG remote's input device
(`/dev/input/event1`). Apps then see OK held down, exactly as with the LG remote. Without
`--ssh`, holding the click sends a normal OK.

### Set up

1. Unpair the remote from anything else, then pair it with the Mac: hold **Menu + Volume Up** for
   5 seconds near the Mac, then connect it in **System Settings → Bluetooth**. It shows up as a
   serial number such as `C08Z39MBJ90M`.
2. Build the bridge on the Mac:

   ```sh
   cd tools/siri-remote && swiftc -O siri-bridge.swift -o siri-bridge
   ```

3. Run it, then accept the connection prompt on the projector with the LG remote. You only
   need to do this once per Mac:

   ```sh
   ./siri-bridge --host <projector-ip>
   ```

The projector issues a client key on first pairing, which the bridge keeps in
`~/Library/Application Support/cleanbeam-remote/client-key`. `pairing.json` is LG's remote-app
manifest, taken from [hobbyquaker/lgtv2](https://github.com/hobbyquaker/lgtv2) (MIT), and must
sit next to the binary. `./siri-bridge --test HOME` pairs, sends one key and exits.

4. For long-press OK, give the Mac root SSH access to the projector: create a key, add its
   public half to `/home/root/.ssh/authorized_keys` on the projector, and add a `Host` alias for
   it in `~/.ssh/config` on the Mac. Then run the bridge with `--ssh <alias>`.

The Mac has to be within Bluetooth range of where you sit. The remote drops its connection when
idle and reconnects when you press a button, with a new touchpad device each time. The bridge
watches IOKit for new touchpads and picks the remote up again by itself. While the projector is
off, the bridge retries its connections in the background, backing off to once a minute.

Apple's driver also turns the remote's buttons into Mac media keys, so Play/Pause would open
Music and the volume buttons would change the Mac's volume. Seizing the HID device doesn't stop
that, so each time the remote connects the bridge runs `hidutil` to remap those keys to F24,
which macOS ignores. The remap applies to the remote only. The Mac's own keyboard is unaffected.

### Run it on an always-on Mac

Copy the folder to the Mac, build it there, and install a launch agent so it starts at login
and restarts if it exits. The Mac has to stay logged in, because the remote's touchpad is only
available in a user session. A projector client key can be copied from another Mac to skip the
connection prompt.

```sh
scp tools/siri-remote/{siri-bridge.swift,pairing.json} <mac>:data/config/siri-bridge/
ssh <mac> 'cd ~/data/config/siri-bridge && swiftc -O siri-bridge.swift -o siri-bridge'
```

`~/Library/LaunchAgents/local.siri-bridge.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.siri-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/<you>/data/config/siri-bridge/siri-bridge</string>
    <string>--host</string>
    <string><projector-ip></string>
    <string>--ssh</string>
    <string><projector-ssh-alias></string>
    <string>--wake</string>
    <string><projector-wifi-mac></string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>/Users/<you>/data/config/siri-bridge/siri-bridge.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/<you>/data/config/siri-bridge/siri-bridge.log</string>
</dict>
</plist>
```

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.siri-bridge.plist
launchctl kickstart -k gui/$(id -u)/local.siri-bridge    # restart after rebuilding
```

The log lists each key sent to the projector, and when the remote connects or drops.

`tools/siri-remote/` also has the probes used to work out the remote's protocol: `hidmon.swift`
(HID reports), `mtmon.swift` (touchpad frames) and `featureget.swift` (read-only feature reports).

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
tools/siri-remote/  Siri Remote bridge for a Mac, plus protocol probes
```
