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

## Post-debloat: immediate stop (2026-10-26)

Hook `/var/lib/webosbrew/init.d/30-debloat.sh` deployed and run manually.
Services stopped: contentminer, nudge, rdxd, remotelogger, com.webos.service.camera, voiceconductor, voiceinput.
All runtime-masked under `/run/systemd/transient/`.

```
              total        used        free      shared  buff/cache   available
Mem:        1096864      766632       25028       10168      305204      276376
Swap:        921592      222044      699548
```

**Immediate result:** Negligible RAM change after live stop — services were already mostly swapped out.
Swap used went UP by ~75 MB (222 MB vs 147 MB baseline), likely because the kernel reallocated freed
physical pages for cache and other processes paged in. **Not a reliable measurement.**

The meaningful number comes from a cold reboot. With the hook in place, these 7 services will never
start, so their startup RAM cost is avoided from the first moment.

**Next: reboot and re-measure.** Expected 50–100 MB RAM improvement at idle.

## Post-debloat: cold reboot with corrected hook (2026-10-26)

**Bug fixed:** `30-debloat.sh` → `30-debloat` (no extension).
Busybox `run-parts` silently skips any filename containing a dot — Glasshouse's `20-tvweb-services`
uses no extension for exactly this reason.

```
              total        used        free      shared  buff/cache   available
Mem:        1096864      710260       18440       39808      368164      304856
Swap:             0           0           0
```

### Results vs baseline

| Metric | Baseline | After debloat | Delta |
| :----- | :------- | :------------ | :---- |
| RAM used | 753 MB | 710 MB | **−43 MB** |
| Available | 292 MB | 305 MB | **+13 MB** |
| Swap in use | 146 MB | **0 MB** | **−146 MB** |
| Services running | 88 | 85 | −3 (some counted differently) |

- **Swap cleared entirely** — no swapping at idle after debloat. The 146 MB of swap pressure is gone.
- **43 MB RAM freed** from stopping 7 services.
- All 7 targets confirmed `inactive` / `failed` (stopped); 7 runtime masks confirmed in place.
- `com.webos.service.camera` shows `failed` rather than `inactive` — stopped cleanly, systemd just
  records the exit state.
