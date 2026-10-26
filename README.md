# cleanbeam

Make an LG CineBeam Q (HU710PB, webOS 6.0, software 3.00.27) faster and less bloated.

webOS stays on the device; this project removes the cruft around it. Background and device facts are in
the handover doc: https://claude.ai/artifact/RefEZU6ME65pR8Xz2yB9vT

## Layout

- `reference/`: read-only clones of the upstream projects we study (git-ignored, re-clone with `scripts/fetch-reference.sh`)
  - `webos-homebrew-channel`: root service, boot hooks, telemetry neutering, update blocking
  - `glasshouse`: on-device dashboard with service masking, preload control, hosts blocker, Home replacement
  - `webos-vibehack`: no-root launcher via LG Developer Mode
- `PLAN.md`: what each project offers for speed and debloat, and the order we'll try things in

## Device

| Field | Value |
| :---- | :---- |
| Model | HU710PB-GL |
| Product code | HU710PB-GL BAULLAN |
| Manufactured | 2024 |
| Software version | 3.00.27 |
| webOS | 6.0 |
| webOS TV version | likely 6.3.1 (reported for another HU710PB-GL on 03.00.27; confirm on ours) |
| SoC | k7lp (same report) |
| OTAID | not shown in About; not needed so far |
| Developer Mode | works on this model and firmware (same report) |

## Status

Nothing has been changed on the projector yet. The first blocker is whether firmware 3.00.27 can be rooted.
