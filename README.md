<!-- lang-switch -->
**English** | [한국어](README.ko.md)
<!-- /lang-switch -->

# AKS + Terraform Hands-on Guide for AWS Engineers

A hands-on guide for engineers who know EKS, VPC, and IAM to build a production-grade **AKS (Azure Kubernetes Service)** cluster with **Terraform**, following **Azure best practices**.
Each lab is an independent Terraform stack, and every piece of code in the docs comes from real files that pass `terraform fmt`, `validate`, and `test`.

**Read it online:** [English HTML guide](https://junwoojeong100.github.io/aks-terraform/aks-terraform-guide.html) · [Korean HTML guide](https://junwoojeong100.github.io/aks-terraform/aks-terraform-guide.ko.html)

| Duration | Estimated cost | Terraform stacks | Prerequisite |
|---|---|---|---|
| About 4–6 hours in total | About $2–2.5 per hour while stacks 03–05 are running | `terraform/*` | [01. Prerequisites](labs/01-prerequisites.md) |

> [!IMPORTANT]
> On top of **static validation** (`terraform fmt`, `validate`, and `terraform test` with a mock provider), the code in this guide was **run end to end, Lab 01–11 from scratch, in a real Azure subscription** on 2026-10-13. The discrepancies found then were fixed, and the items that could not be confirmed (Spot scale-up, running an upgrade, etc.) are listed in [Appendix A](labs/99-appendix.md). After the guide was translated into English, the same end-to-end run was repeated on 2026-10-14 with the same results. Results can differ with your subscription's quotas, organization policies, and regional capacity, so read the `terraform plan` output carefully the first time you run it. After the labs, be sure to clean up with [Lab 11](labs/11-cleanup.md) (a cluster left running keeps costing money).

## Baseline versions (2026-10-13)

| Component | Version | Notes |
|---|---|---|
| Terraform | **1.16.5** | `required_version = "~> 1.16"` |
| azurerm provider | **5.9.0** | The major version after 5.0 GA (2026-07). Many changes are incompatible with 4.x code. |
| AzAPI provider | 2.13.0 | AKS features that azurerm doesn't support yet (Gateway API, etc.) |
| kubernetes provider | 3.3.0 | App/namespace deployment |
| AKS Kubernetes | **1.36** (latest GA, 1.36.4) | The AKS default is 1.35; 1.37 is in preview (GA expected in Oct 2026) |
| Azure CLI | 2.86+ | |

## Learning path

| Lab | Topic | What it covers |
|---|---|---|
| [00](labs/00-aws-azure-mapping.md) | **AWS ↔ Azure comparison** | Services, concepts, commands, and Terraform differences in one place |
| [01](labs/01-prerequisites.md) | Prerequisites | Tools, sign-in, RP registration, quotas, environment variables |
| [02](labs/02-bootstrap.md) | Remote state | S3+DynamoDB ↔ Blob, naming convention module, `terraform test` |
| [03](labs/03-network.md) | Networking | VNet, NSG, NAT Gateway, Private DNS |
| [04](labs/04-platform.md) | Platform services | ACR, Key Vault, Log Analytics, Prometheus, Grafana, identities for AKS |
| [05](labs/05-aks.md) | **AKS cluster** | CNI Overlay + Cilium, API Server VNet Integration, Entra RBAC, node pools, observability |
| [06](labs/06-workload-identity.md) | Workload Identity | IRSA ↔ Entra Workload ID, Key Vault CSI |
| [07](labs/07-ingress.md) | Ingress | ALB Controller ↔ Gateway API (approuting-istio) |
| [08](labs/08-governance.md) | Governance and security | Azure Policy, Defender, locks, budgets |
| [09](labs/09-operations.md) | Day-2 operations | Upgrades, scaling, node replacement, testing/CI (workload operations with kubectl: Appendix E) |
| [10](labs/10-aks-automatic.md) | AKS Automatic | The fully managed mode, equivalent to EKS Auto Mode |
| [11](labs/11-cleanup.md) | Cleanup | `destroy` in reverse order, Key Vault soft-delete, cost check |
| [99](labs/99-appendix.md) | Appendix | Troubleshooting, production checklist, **cluster access and internet exposure (D)**, **handling Kubernetes workloads with kubectl (E)**, references, test code |

## Architecture overview

![Overall architecture built in this guide](labs/diagrams/overview-architecture.svg)

The stacks are split by lifecycle. Each later stack picks up the results of the earlier ones by looking them up through the naming convention (`modules/naming`).

![Terraform stack layers and execution order](labs/diagrams/stack-layers.svg)

## Quick start

```bash
git clone https://github.com/junwoojeong100/aks-terraform.git && cd aks-terraform
az login && az account set --subscription "<subscription>"
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export TF_VAR_allowed_ip_ranges="[\"$(curl -s https://api.ipify.org)/32\"]"
scripts/preflight.sh                  # check tools · sign-in · quotas · permissions (read-only)

cd terraform/02-bootstrap && terraform init && terraform apply
terraform output -raw backend_hcl > ../backend.hcl
cd ../03-network && terraform init -backend-config=../backend.hcl && terraform apply
# … same pattern for 04 → 05 → 06 → 07 → 08

cd ../.. && scripts/verify.sh         # check that the stacks you applied were built as designed (read-only)
scripts/cleanup.sh --dry-run          # when you're done: review what will be deleted → scripts/cleanup.sh (Lab 11)
```

Follow the detailed steps starting from [Lab 01](labs/01-prerequisites.md). The **single-file HTML guide** is published [online](https://junwoojeong100.github.io/aks-terraform/aks-terraform-guide.html); you can also open `aks-terraform-guide.html` from this repository in a browser (works offline; supports search, copy buttons, dark mode, and progress checkboxes).

## Languages

The guide is available in **English (default)** and **Korean**: the Korean edition lives in `README.ko.md`, `labs/ko/`, and `aks-terraform-guide.ko.html`. Terraform code, comments, and script messages are English-only, because both editions embed the same source files verbatim.

## Lab scripts

The check, verify, and delete commands you would otherwise type by hand are bundled into scripts (macOS · Linux · WSL · Cloud Shell; required: `terraform` `az` `jq`, plus `kubectl` `kubelogin` from Lab 05 on).

| Script | Purpose |
|---|---|
| `scripts/preflight.sh` | Pre-start check: tools · sign-in · resource providers · vCPU quota · VM size · permissions (read-only) |
| `scripts/verify.sh [stack…]` | Verifies the result after you `apply` each stack (read-only; `✓ ✗ !` summary and exit code) |
| `scripts/cleanup.sh` | Deletes in the reverse order of creation · removes locks · checks for leftover resources (preview with `--dry-run` first) |
| `tools/validate-all.sh` | `fmt` · `validate` · `terraform test` + script syntax checks, without Azure |

## Repository layout

```text
.
├── README.md                    # English (default); README.ko.md is the Korean edition
├── aks-terraform-guide.html     # One HTML file with all docs + all Terraform code + diagrams + scripts (English); aks-terraform-guide.ko.html is Korean
├── labs/                        # Lab docs in English (code blocks are synced automatically from the real files in terraform/ and scripts/)
│   ├── diagrams/                # Diagrams (SVG), generated by tools/gen-diagrams.mjs
│   └── ko/                      # Korean edition of the lab docs (with its own diagrams/)
├── terraform/
│   ├── modules/naming/          # Naming convention module
│   ├── mocks/                   # Mock values for terraform test
│   └── 02-bootstrap … 10-aks-automatic/
├── scripts/                     # preflight.sh · verify.sh (+verify/) · cleanup.sh · lib/common.sh
└── tools/
    ├── validate-all.sh          # fmt + validate + test (no Azure needed) + script checks
    ├── sync-code.mjs            # Syncs the code blocks/numbers in md with the sources
    ├── check-docs.mjs           # Doc checks (strikethrough misparse, broken links/file paths, language pairing)
    ├── gen-diagrams.mjs         # Generates the diagrams (SVG) in both languages
    └── build-html.mjs           # md → single HTML (English and Korean)
```

## Validation and regenerating the HTML

```bash
tools/validate-all.sh                    # static validation of all stacks + mock plan tests + script checks (no subscription needed)

cd tools && npm install && npm run build  # sync code + check docs + regenerate the diagrams and both HTML guides
npm run check                             # verify that code/numbers in md match the sources + doc checks (for CI)
```

Pushing to `main` runs the same `npm run build` on a clean checkout in GitHub Actions (`.github/workflows/pages.yml`) and publishes the two HTML guides to [GitHub Pages](https://junwoojeong100.github.io/aks-terraform/). The site is always built from the pushed sources, so run the build locally only if you want to refresh the offline copies of the HTML files in this repository.

## References

- [AKS for Amazon EKS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/eks-to-aks/) · [Azure for AWS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/)
- [Baseline architecture for an AKS cluster](https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks) · [AKS Well-Architected guide](https://learn.microsoft.com/azure/well-architected/service-guides/azure-kubernetes-service)
- [azurerm 5.0 upgrade guide](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/5.0-upgrade-guide) · [Official Microsoft AKS Terraform samples](https://github.com/Azure/terraform/tree/master/quickstart)
