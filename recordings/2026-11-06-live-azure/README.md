<!-- lang-switch -->
**English** | [한국어](README.ko.md)
<!-- /lang-switch -->

# Actual Azure lab recording · 2026-11-06

A separate, unnarrated practice recording of **real Terraform execution against Azure**, not the narrated YouTube episode.
Source: [`f9b7c04`](https://github.com/junwoojeong100/aks-terraform/tree/f9b7c047467f28e9ad2d430422bd69e3520ddbe8).

| File | Contents |
|---|---|
| [Practice video](AKS_Terraform_Live_Lab_2026-11-06_1080p.mp4) | 49:41, 53.26 MB; 1920×1080, 10 fps, H.264/AAC; silent, with 19 embedded chapters |
| [Chapters](chapters.txt) | Navigate prerequisites, creation, policy diagnosis, verification and cleanup |
| [Terminal recording](lab.cast) | Combined asciinema v2 recording |
| [Evidence](evidence.json) | Command results, timings, hashes, observed configuration, live checks, cleanup and encoded-video QA |
| `commands/*.cast` | Individual actual command recordings, including failures |
| [Backend override](recording_override.tf.example) | Exact recording-only override used; hash bound to the evidence |

This is a faithful **terminal-output replay**, not an uninterrupted desktop capture or a simulated Azure portal.
Output and original within-command waiting times were recorded from the executed subprocesses.
The movie rounds to 10 fps, adds approximately one-second reading holds, and omits between-command preparation gaps.
Account identifiers, user name, administrator IP and local paths are redacted; results and resource counts are not invented.

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
The web listener is HTTP 80, not tested production TLS.

The CLI emitted a `serviceconnector` module-loading diagnostic during an otherwise successful AKS query.
That output is preserved; independent API, node and application checks succeeded.
Cleanup preserves Key Vault purge protection and soft-delete retention; the vault was not purged.
See the actual retention and deletion results in `evidence.json`.

The separately narrated YouTube edit, production scripts and captions live in
[`build-and-run-it/ep03-aks-terraform`](https://github.com/junwoojeong100/build-and-run-it/tree/main/ep03-aks-terraform).
The recording and renderer are in its `src/live.py` and `src/live_media.py`; rendering existing public casts does not recreate Azure resources.
