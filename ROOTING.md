# Rooting the LG CineBeam Q (HU710PB-GL)

Confirmed working on: **HU710PB-GL**, webOS 6.3.1, firmware 03.00.27, SoC k7lp.

## Resources

| Resource | Notes |
| :------- | :---- |
| [IHIXly/lg-cinebeam-hu710pw-ROOT](https://github.com/IHIXly/lg-cinebeam-hu710pw-ROOT) | SlopBro fork adapted for the CineBeam Q range — **start here** |
| [webosbrew/webos-homebrew-channel](https://github.com/webosbrew/webos-homebrew-channel) | HBC — installs automatically via SlopBro |
| [OpenLGTV Discord](https://discord.gg/libretv) | Community support; search for `HU710P` or `k7lp` |
| [CanI.RootMy.TV](https://cani.rootmy.tv) | Lists rooted TV models; projectors are mostly absent but the underlying exploit is the same |

## CineBeam-specific differences

Standard LG TV rooting guides (SlopBro, DangBro) target **TV-specific apps** as exploit entry
points — `com.webos.app.adoverlayex`, `com.webos.app.livetv`, etc. **These apps are not present
on projectors.**

The CineBeam Q fork uses `com.webos.app.voiceweb` instead, which is present on webOS 6
projectors. Before running SlopBro, confirm it exists on your device:

```sh
# From a machine on the same network — requires LG Developer Mode app installed
python3 scripts/probe-ssap.py <projector-ip> | grep voiceweb
```

Or in LG's Developer Mode app on the projector: enable Dev Mode, then use the app list to
confirm `com.webos.app.voiceweb` appears.

## Prerequisites

1. **LG Developer Mode** must be installed and active. Find it in the LG Content Store, or
   sideload via the Developer Mode app at [webostv.developer.lge.com](https://webostv.developer.lge.com).
2. The projector must be on the same local network as your computer.
3. Your computer needs Python 3 and Node.js.

## Steps

```sh
# 1. Clone the CineBeam SlopBro fork
git clone https://github.com/IHIXly/lg-cinebeam-hu710pw-ROOT tools/slopbro

# 2. Follow its README exactly — it will prompt you to accept a pairing request
#    on the projector screen. Accept it.
cd tools/slopbro
# see its README for the exact command

# 3. On success, Homebrew Channel appears on the projector's home screen.
#    Open it and enable SSH in HBC → Settings.

# 4. SSH in (default password: alpine)
ssh root@<projector-ip>
```

`tools/slopbro/` is gitignored here. Do not commit it.

## After rooting

- **Block firmware updates immediately** — the exploit is patched in newer firmware.
  HBC does this automatically; verify with:
  ```sh
  ls /var/luna/preferences/webosbrew_block_updates
  ```
- **Change the SSH password** or set up key-based auth via HBC settings.
- Return to [`README.md`](README.md) to deploy the debloat hooks.

## HU710PW vs HU710PB

The [IHIXly fork](https://github.com/IHIXly/lg-cinebeam-hu710pw-ROOT) targets the HU710PW
(white). The HU710PB-GL (black) is the same hardware — same SoC (k7lp), same webOS version
(6.3.1), same firmware generation. The exploit path and post-root setup are identical.

If you are on a different firmware version, check the OpenLGTV Discord for a report on your
specific `<model> + <firmware>` combination before attempting root.
