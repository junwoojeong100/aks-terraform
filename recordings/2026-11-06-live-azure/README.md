<!-- lang-switch -->
**English** | [한국어](README.ko.md)
<!-- /lang-switch -->

# Actual Azure lab recording · 2026-11-06

A separate, unnarrated practice recording of **real Terraform execution against Azure**, not the narrated YouTube episode.
Source: [`f9b7c04`](https://github.com/junwoojeong100/aks-terraform/tree/f9b7c047467f28e9ad2d430422bd69e3520ddbe8).

| File | Contents |
|---|---|
| [Practice video](AKS_Terraform_Live_Lab_2026-11-06_1080p.mp4) | 51:56, 57.54 MB; 1920×1080, 10 fps, H.264/AAC; silent, with 29 embedded chapters |
| [Chapters](chapters.txt) | Navigate the repository, guide, creation, Portal, HTTPS app, policy diagnosis and cleanup |
| [Terminal recording](lab.cast) | Original, byte-identical terminal-only asciinema v2 replay |
| [Evidence](evidence.json) | Separate cast/movie timings, source hashes, edit segments, observed configuration, live checks, cleanup and encoded-video QA |
| `commands/*.cast` | Individual actual command recordings, including failures |
| [Backend override](recording_override.tf.example) | Exact recording-only override used; hash bound to the evidence |
| [Screen sources](sources/) | Episode 03's 4 browser MP4s, 4 guide WebMs, 4 original guide screenshots and 4 browser-preview PNGs |
| [Browser evidence](sources/data/browser_run.json), [supplemental lab](sources/data/portal_run.json) | Original capture/TLS checks and complete creation/cleanup evidence for the separate browser-filming lab |

The terminal sections remain a faithful **terminal-output replay**, not an uninterrupted desktop capture.
Output and original within-command waiting times were recorded from the executed subprocesses; all 62 command clips are preserved.
Those sections round to 10 fps, add approximately one-second reading holds, and omit between-command preparation gaps.
Account identifiers, user name, administrator IP and local paths are redacted; results and resource counts are not invented.

## Episode 03 screen footage added

The expanded movie reuses the actual screen sources already used for Episode 03:

| Screen | Scope |
|---|---|
| GitHub repository and readable URL | Actual public repository, before the original preflight |
| Guide overview, network diagram, Automatic comparison and cleanup | Original offline-HTML screenshots and scripted browser recordings; Automatic is explicitly labeled **NOT deployed** |
| Azure Portal overview and node pools | Actual `ep03ui` supplemental lab, with 2 System + 1 User nodes; not the original `ep03live` terminal run |
| HTTPS app load, Home and refresh | Actual supplemental Gateway app through its temporary publicly trusted TLS frontend |

Full viewports are shown without cropping, with visible scope labels. Screen recordings play at 1x, rounded up to 10 fps
with less than 0.1 second of final-frame hold; each guide screenshot stays on screen for 4 seconds.
The added footage contributes 134.5 seconds. Both labs were already cleaned up; this update created no Azure resources.
Their different recording IDs and the browser lab's TLS/cleanup evidence are preserved under `sources/data/`.
The filmed hostname was temporary and no longer serves the app.

`lab.cast` is unchanged and intentionally excludes these screen sections. In `evidence.json`, command `cast_start`/`cast_end`
refer to that terminal-only replay; `video_start`/`video_end` refer to the expanded MP4.
The complete 3115.6-second movie passed full video/audio decoding, and decoded frames from all 74 edit segments
matched their source clips. Original command casts, combined cast bytes and within-command timings were verified unchanged.

## What actually ran

| Item | Observed scope |
|---|---|
| Region / cluster | Korea Central / AKS Standard / Kubernetes 1.36.5 |
| Compute | 2 System + 1 User nodes, `Standard_D4ds_v5`, zone 1 only; fixed autoscaler bounds |
| Network | CNI Overlay, Cilium, NAT Gateway, API Server VNet Integration |
| Administrator API | Public, restricted to the recording machine's IP; local accounts disabled |
| Stacks | 02-bootstrap → 03-network → 04-platform → 05-aks → 07-ingress |
| Monitoring | Workspaces created; Grafana disabled; Log Analytics daily cap 1 GB |
| Live verification | Azure provisioning Succeeded, authenticated API, 3 Ready nodes, web rollout, Gateway Programmed, HTTP 200 |
| Cleanup | Recorded reverse-order destroy and an empty demo-resource-group query |

This smaller, single-zone recording is **not the guide's production HA topology**, and its cost is not the guide's dated estimate.

## Policy and test limitations

The new state account's public network access was disabled by inherited organization policy. The original Blob backend
really failed with HTTP 403. No policy exemption or public-access change was made. Applied stacks 03, 04, 05 and 07 used the explicitly
recorded **local-backend override**, with state and plans confined to the ignored, access-restricted recording workspace.
This does **not** demonstrate a successful Blob-state migration. A shared deployment needs an approved private backend path;
do not copy this temporary local-state choice into a shared environment.

The vault reports public network access **Disabled**. A metadata-only probe returned **ForbiddenByRbac**; that rejection
does not isolate a network failure. No additional vault data role or private client path was established.
**Lab 06's live secret-mount test was not performed.** No secret value was read or printed.
The source's identity example, DNS/NSG experiments, Spot scale-up, upgrades and Automatic stack are not newly validated here.
The original web listener is HTTP 80, not tested production TLS. The added browser footage uses a separate temporary
Caddy frontend with a public Let's Encrypt certificate and HTTP 308 redirect, proxying to the supplemental HTTP Gateway.
Normal certificate verification succeeded; no warning bypass or trust-store change was used.
This is not production ingress certification, mTLS or end-to-end TLS; certificate storage lasted only for the filming Pod.

The CLI emitted a `serviceconnector` module-loading diagnostic during an otherwise successful AKS query.
That output is preserved; independent API, node and application checks succeeded.
Cleanup preserves Key Vault purge protection and soft-delete retention; the vault was not purged.
See the actual retention and deletion results in `evidence.json`.

The separately narrated YouTube edit, production scripts and captions live in
[`build-and-run-it/ep03-aks-terraform`](https://github.com/junwoojeong100/build-and-run-it/tree/main/ep03-aks-terraform).
The recording and renderer are in its `src/live.py` and `src/live_media.py`; rendering existing public casts and screen sources
does not recreate Azure resources. The expanded practice movie remains silent and separate from the narrated YouTube edit.
