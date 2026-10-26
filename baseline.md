# Baseline — 2026-10-26 (post-root, pre-debloat)

Measured immediately after rooting with SlopBro, before any service changes.
SSH as root via `ssh cleanbeam`.

## Memory

```
              total        used        free      shared  buff/cache   available
Mem:        1096864      753484       29564        8504      313816      292292
Swap:        921592      146008      775584
```

- **Total RAM:** ~1.07 GB
- **Used:** 753 MB (69%)
- **Available:** 292 MB — already tight after a fresh reboot
- **Swap in use:** 146 MB — active swapping on a fresh boot is a strong sign of RAM pressure

## webOS build

- Release: `Rockhopper 6.3.1-1065 (kisscurl-kavir)`
- Kernel: `4.4.84-pjtr.k7lp.kavir.1` — armv7l, k7lp / Realtek SoC

## Running services (88 total)

Services confirmed running that Glasshouse targets for stopping:

| Service | What it does | Stop priority |
| :------ | :----------- | :------------ |
| `contentminer.service` | ACR — watches the screen for ad/viewing telemetry | High |
| `nudge.service` | Promotional popups and feature tips | High |
| `rdxd.service` | Continuously logs diagnostics/traces to flash | High |
| `remotelogger.service` | Ships system logs to remote servers | High |
| `com.webos.service.camera.service` | USB webcam daemon (no webcam attached) | High |
| `voiceconductor.service` | LG voice assistant / AI button | Medium |
| `voiceinput.service` | Voice input pipeline | Medium |
| `crashd.service` | Crash report daemon | Medium |
| `update.service` | Software update daemon | Low (update blocking covers the network side) |

Services **not** present (TV-specific, not on this projector):
- `uploadd.service` — not in list (telemetry uploader) — may be absent or named differently

Full service list: 88 services running at idle.

## Homebrew Channel flags set

```
/var/luna/preferences/webosbrew_block_updates   ← firmware updates blocked
/var/luna/preferences/webosbrew_sshd_enabled    ← SSH enabled
```

## Next: debloat

See `PLAN.md` order of work step 6. Plan is to stop services one at a time via
`init.d/` hooks, measure memory after each, and keep what helps.
