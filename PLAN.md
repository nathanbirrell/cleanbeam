# Plan

## What the two main projects actually do for speed and debloat

Both need root. Neither mentions projectors, and Glasshouse's 53 tested devices are all TVs, so the
HU710PB would be a first.

### Homebrew Channel (`reference/webos-homebrew-channel/services/startup.sh`)

Runs once per boot from `/var/lib/webosbrew/startup.sh`. The parts relevant to us:

| Lever | How | Effect |
| :---- | :-- | :----- |
| Telemetry spools | Read-only bind mounts over `/tmp/rdxd`, `/tmp/uploadd`, `/var/spool/rdxd`, `/var/spool/uploadd/{pending,uploaded}` | Crash/usage uploads have nowhere to write |
| Update blocking | Flag file `/var/luna/preferences/webosbrew_block_updates` makes it bind-mount an `/etc/hosts` pointing `snu/su/su-ssl/su-dev.lge.com` at localhost | Keeps root from being patched away |
| User hooks | Every executable in `/var/lib/webosbrew/init.d` runs at boot via `run-parts` | Where our own debloat script would live |
| Failsafe | Flag `/var/luna/preferences/webosbrew_failsafe`; if a boot crashes mid-hook, the next boot only opens a telnet shell | Safety net for experiments |

Nothing touches the read-only rootfs; everything is bind mounts under `/tmp` and undone by a reboot.

### Glasshouse (`reference/glasshouse/server/lib/`, `docs/TV-CHANGES.md`)

A Node server on the TV. The speed and debloat pieces are separable from the dashboard:

| Lever | Source | How |
| :---- | :----- | :-- |
| Background services | `services.js` | `systemctl stop` and mask under `/run` for `uploadd`, `rdxd`, `contentminer` (ACR), `nudge` (promo popups), `remotelogger`, `com.webos.service.camera`, `com.webos.service.mycar`, `voiceconductor`; boot hook `init.d/20-tvweb-services`, re-checked every 5 min |
| App preloading | `preload.js` | Sets `isEnabled:false` per app in configd `com.webos.service.preloadmanager.supportAppList`, so LG stops keeping Netflix, YouTube etc. resident in RAM |
| Ad/telemetry hosts | `privacy.js` | Replacement `/etc/hosts` bind mount blocking `*.lgtvsdp.com`, `*.lgsmartad.com`, `*.lgappstv.com` stats, `ngfts.lge.com`, and the Alphonso ACR hosts |
| Uninstall apps | `apps.js` | Permanent removal through LG's install service to free flash |
| Hide system tiles | `homescreen*.js` | Bind-mounted `appinfo.json` edits (experimental) |
| Replace LG Home | `home-takeover.js` | Bind-mounts its own app over `com.webos.app.home` |
| Remote keys | `remotekeys.js` | Surface-manager key filter to remap or disable shortcut buttons |

## Without root

vibehack confirms there's no package disabling without root. What's left is the settings debloat
from the handover doc, a Developer Mode launcher, and LG's network control API (SSAP over websocket,
port 3000/3001, the API vibehack and Home Assistant use), which can script settings and close apps
from a computer.

## Order of work

1. **Identify the device.** ✅ Model HU710PB-GL, firmware 03.00.27, SoC k7lp, webOS 6.3.1.
2. **Turn off auto-updates.** Do this now and keep it off throughout.
3. **Confirm voiceweb.** Set up Developer Mode and verify `com.webos.app.voiceweb` is present
   (see SlopBro section above). If present, the root path is likely viable.
4. **Root with SlopBro.** Clone [IHIXly/lg-cinebeam-hu710pw-ROOT](https://github.com/IHIXly/lg-cinebeam-hu710pw-ROOT),
   run against the projector's IP. Accept the pairing prompt. If it succeeds, Homebrew Channel
   appears on the home screen.
5. **Post-root baseline.** SSH in (default password `alpine`), measure free RAM, list running
   services with `systemctl list-units --state=running`, confirm which Glasshouse service IDs
   exist on a projector build.
6. **Debloat.** Write `init.d/` hooks one at a time: stop telemetry services, block ad hosts,
   disable preloaded apps. Measure after each change.
7. **If root fails:** fall back to settings debloat + Developer Mode launcher + SSAP scripting.

## Root check so far (2026-10-26)

- CanI.RootMy.TV identifies a device by its OTAID. Every OTAID in its bundled data is a TV family
  (`HE_DTV_...`), and none looks like a projector.
- The site lists 03.00.27 as a known version string, and 03.xx firmware lines up with webOS 6,
  but without the projector's OTAID we can't say which entry, if any, applies.
- Next: read the webOS TV version and OTAID from Settings → General → About. If the OTAID isn't
  in the checker, ask on the OpenLGTV Discord with model, product code, software version and OTAID.

## SlopBro CineBeam adaptation (2026-10-26)

[IHIXly/lg-cinebeam-hu710pw-ROOT](https://github.com/IHIXly/lg-cinebeam-hu710pw-ROOT)
(published 2026-09-23) is SlopBro adapted for the **HU710PW** — the white variant of the same
projector range. Confirmed working:

| Field | Value |
| :---- | :---- |
| Device | HU710PW |
| webOS | 6.3.1 |
| Firmware | 03.01.13 |
| SoC | k7lp / Realtek |
| Result | Root + Homebrew Channel |

**The key CineBeam change:** on TVs SlopBro uses `com.webos.app.adoverlayex` and similar apps as
exploit entry points. Those aren't present on projectors. The adaptation uses
`com.webos.app.voiceweb` instead (webOS major version 6 or 11).

**Relevance to our HU710PB-GL:**
- Same SoC (k7lp), same webOS version (6.3.1), same firmware generation (03.00.27 vs 03.01.13 —
  ours is actually older/lower, which is usually better for exploit availability).
- `com.webos.app.voiceweb` must be present on the PB as well — it was confirmed present on the PB
  via the Developer Mode report.
- The PW vs PB distinction appears to be a colour/market variant; the underlying platform is
  the same.

**Confirmed on our HU710PB-GL (2026-10-26):** SSAP `listApps` returned 109 apps.
Both exploit entry points from the HU710PW adaptation are present:
- ✅ `com.webos.app.voiceweb` — primary entry point used by the HU710PW fork
- ✅ `com.webos.app.acroverlay` (LivePlus) — fallback entry point
- ✅ `com.palmdts.devmode` — Developer Mode already installed

The exploit path is confirmed viable. See `scripts/probe-ssap.py` for the app listing tool.

## Community reports (2026-10-26)

- **Developer Mode confirmed.** [webosbrew/youtube-webos#457](https://github.com/webosbrew/youtube-webos/issues/457#issuecomment-4908203765)
  (2026-07-07): an HU710PB-GL on webOS 6.3.1, firmware 03.00.27, SoC k7lp, running Developer
  Mode only, not rooted. The Cobalt build of youtube-webos installed with `luna-send-pub` (Dev
  Manager's drag-and-drop hung) and blocked YouTube ads; SponsorBlock didn't work.
- **Root not confirmed.** On the OpenLGTV Discord (2026-09-14) someone asked whether DangBro or
  SlopBro work on the HU710PB. The only reply was general: webOS 5 and earlier can basically always be
  rooted, and newer devices are fine if you don't update. Nobody reported rooting this model, and ours
  is webOS 6.
- Takeaway: Developer Mode is a known-good path today. Root stays unproven; asking for an
  HU710PB / k7lp / 03.00.27 data point is the next step before trying any exploit.

## Open questions

- Which SoC is in the HU710PB? Reported as k7lp; confirm on ours from the Instart menu or a shell.
- Does a projector build of webOS 6 carry the same services (`contentminer`, `nudge`, preloadmanager)?
  Check with `systemctl list-units` once we have a shell.
- Is the slowness mainly RAM pressure from preloaded apps, or Home's ad/recommendation rows loading
  over the network? The baseline in step 2 should tell.
