<!-- lang-switch -->
**English** | [한국어](ko/00-aws-azure-mapping.md)
<!-- /lang-switch -->

# AWS ↔ Azure infrastructure services compared (for EKS engineers)

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| 30 min read | None | (none) | None |

This document puts the service, concept, and Terraform differences in one place so that **engineers who are familiar with AWS (EKS, VPC, IAM …)** can get up to speed on Azure and AKS quickly.
The code in every later lab carries comments that map each piece back to AWS (for example `# Equivalent to …` or `AWS comparison: …`), so come back to these tables whenever you get stuck.

> [!NOTE]
> Official comparison resources: [Azure for AWS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/) and
> [AKS for Amazon EKS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/eks-to-aks/) (maintained by Microsoft).
> The tables in this guide are based on those resources and the latest AKS documentation (as of 2026-10), trimmed to the parts the labs need.

## 1. Ten mindset shifts to make first

![AWS ↔ Azure service map](diagrams/aws-azure-map.svg)

| # | AWS intuition | Azure approach |
|---|---|---|
| 1 | An account is the isolation, billing, and permission boundary | The **subscription** is the billing and quota boundary, and the **resource group (RG)** is the unit of lifecycle, permissions, and deletion. Every resource must live inside an RG. |
| 2 | You write IAM users, roles, and policy JSON yourself | **Microsoft Entra ID** (the directory) + **Azure RBAC**: a *role assignment* ties together "who (principal) + which role + at what scope". You mostly use built-in roles. |
| 3 | A subnet belongs to a single AZ | **A subnet spans the whole region**, and the availability zone (AZ) is a **property of the resource**, such as a VM, node pool, or load balancer. |
| 4 | Security Group (stateful) + NACL (stateless) | A single **NSG** does both jobs: it is stateful, rules have priorities (the lower the number, the earlier it is evaluated), and it supports both Allow and Deny. Attach it to a subnet or a NIC. |
| 5 | Private subnet + NAT Gateway (edit the route table) | Attach the NAT Gateway **directly to the subnet**. No route table is needed, and relying on the default outbound IP is being phased out. |
| 6 | Gateway/Interface VPC Endpoint | **Private Endpoint** (assigns a private IP to the service) + a **Private DNS Zone** that you configure yourself. There is no automatic "Enable Private DNS" option. |
| 7 | Role + trust policy | Create a **Managed Identity** (UAMI), an identity that exists as a resource, and add a **role assignment** on the target resource. No keys or secrets. |
| 8 | S3 + DynamoDB for Terraform state locking | **Blob Storage** alone is enough: locking is handled automatically by a blob lease, and authentication uses Entra ID (RBAC). |
| 9 | Most services need no separate activation | Each subscription needs **Resource Provider (RP) registration** (`Microsoft.ContainerService`, etc.). azurerm 5.x does not register providers automatically. |
| 10 | With EKS, the nodes (EC2) show up directly in your account | AKS nodes are created in a separate **node resource group** (`MC_...` or a name you specify) that AKS manages. |

## 2. Organization, accounts, and regions

![Accounts, regions and availability zones compared](diagrams/account-hierarchy.svg)

| AWS | Azure | Differences / notes |
|---|---|---|
| AWS Organizations root | **Entra tenant** + root management group | The tenant is the directory (users and apps); management groups are the hierarchy that groups subscriptions. |
| OU | **Management group** | Policies and role assignments are inherited by the subscriptions below. |
| Account | **Subscription** | The unit of quota (vCPU, etc.) and billing. Check the vCPU quota per region and per VM family in advance. |
| (none) | **Resource group** | A container that groups resources with the same lifecycle. Deleting it deletes every resource inside. Also used as a scope for tags, locks, and RBAC. |
| SCP | **Azure Policy** + RBAC | An SCP is a permission ceiling, whereas Azure Policy is a set of rules that evaluate and enforce *resource properties* (audit, deny, automatic remediation). |
| Region / AZ | Region / **Availability Zone** | `koreacentral` provides 3 AZs. Zone numbers (1, 2, 3) can map to different physical AZs in each subscription. |
| Resource ARN | **Resource ID** | Takes the form `/subscriptions/<id>/resourceGroups/<rg>/providers/<RP>/<type>/<name>`. In Terraform, resources reference each other through `id`. |
| Tags | **Tags** | Tag keys are case-insensitive. Resource group tags are not inherited automatically (Policy can add inheritance). Use tags as filters in cost analysis. |

## 3. Networking

| AWS | Azure | Differences / notes |
|---|---|---|
| VPC | **Virtual Network (VNet)** | Regional. Can have multiple address spaces. |
| Subnet (tied to one AZ) | **Subnet** (not tied to an AZ) | You can apply a **delegation** to a subnet so that a specific service (such as the AKS API server) uses it exclusively. |
| Security Group / NACL | **NSG**, ASG (Application Security Group) | An NSG attaches to a subnet or NIC. An ASG lets you use a "logical group" in rules, much like an SG reference. |
| Internet Gateway | (no separate resource) | Having a public IP gives internet connectivity. For outbound traffic, explicitly specify one of NAT, load balancer, or firewall. |
| NAT Gateway + EIP | **NAT Gateway** + Public IP | The `StandardV2` SKU is zone-redundant. Attach it to a subnet. |
| VPC Endpoint (Interface) | **Private Endpoint** | Each PaaS service needs its own `privatelink.*` Private DNS Zone. |
| VPC Endpoint (Gateway: S3/DDB) | **Service Endpoint** | Routes traffic from the subnet to the PaaS public endpoint over the Azure backbone. Private Endpoint is recommended for new designs. |
| Route 53 (Public/Private zone) | **Azure DNS**, **Private DNS Zone** | A Private Zone defines its resolution scope through VNet links. |
| ALB / NLB | **Application Gateway** (L7), **Azure Load Balancer** (L4), **Front Door** (global L7) | On AKS, a Gateway API implementation or **Application Gateway for Containers** is the counterpart of the ALB Controller. |
| Transit Gateway / VPC Peering | **VNet Peering**, **Virtual WAN** | Hub-and-spoke: Azure Firewall/Bastion/VPN in the hub, workloads in the spokes. |
| Network Firewall | **Azure Firewall** | To keep costs down, this lab uses a NAT Gateway; the firewall setup is covered in the appendix. |
| VPC Flow Logs | **VNet Flow Logs** | Creation of new NSG flow logs has been discontinued, and they have been replaced by VNet flow logs. |

> [!IMPORTANT]
> **IP planning changes.** The VPC CNI in EKS consumes a VPC IP for every pod, but **Azure CNI Overlay**, the recommended AKS configuration, uses VNet IPs only for nodes and gives pods a separate CIDR (`pod_cidr`). The pod CIDR only has to avoid overlapping with the VNet and on-premises ranges.

## 4. Identity, permissions, and secrets

| AWS | Azure | Differences / notes |
|---|---|---|
| IAM User/Group | **Entra ID users/groups** | Sign-in, MFA, and Conditional Access are managed in Entra. |
| IAM Role (assumed by people or services) | **Managed Identity** (granted to a resource) + **service principal** | System-assigned (same lifetime as the resource) / **User-assigned (UAMI, a standalone resource)**. UAMI is recommended for AKS. |
| IAM Policy (JSON) | **Role Definition + Role Assignment** | Pick a built-in role (Contributor, AcrPull …) → assign it at a *scope*. Custom roles are JSON too. |
| Permission boundary | (none) / Azure Policy, ABAC conditions | Partially implemented with assignment conditions (ABAC). |
| STS AssumeRole | Token issuance (Entra) | Apps obtain tokens automatically through the SDK's `DefaultAzureCredential`. |
| Instance profile | **Managed Identity** (VM/VMSS) | The node (kubelet) identity corresponds to this. |
| IRSA / EKS Pod Identity | **Microsoft Entra Workload ID** | The cluster's **OIDC issuer** + a **federated credential** (issuer+subject) + the SA annotation `azure.workload.identity/client-id`. The structure is almost identical to IRSA. |
| KMS | **Key Vault** (Keys) / Managed HSM | Manages service encryption keys (CMK). |
| Secrets Manager / Parameter Store | **Key Vault** (Secrets) / App Configuration | On AKS, mount them with the **Secrets Store CSI Driver**. |
| ACM | **Key Vault** (Certificates) / App Service certificates | Gateway TLS certificates are synced from Key Vault. |
| CloudTrail | **Activity Log** + **Diagnostic settings** | The management plane is covered by the Activity Log; the data plane (such as Key Vault access) is sent to Log Analytics through diagnostic settings. |

## 5. Containers and Kubernetes (EKS ↔ AKS)

| AWS | Azure | Differences / notes |
|---|---|---|
| EKS (Standard) | **AKS Standard** | The control plane is managed in both. The uptime SLA starts with the AKS **Standard tier** (paid). |
| EKS Auto Mode | **AKS Automatic** | A mode that hands nodes, scaling, upgrades, and even security defaults over to the platform. As of 2026, Microsoft recommends "Automatic for most new production workloads" → Lab 10. |
| Managed node group (ASG) | **Node pool** (VMSS) | Separate the **System pool** (system pods such as CoreDNS) from the **User pool** (apps). At least 3 nodes / 4 vCPUs are recommended for the System pool. |
| Karpenter | **Node Auto Provisioning (NAP)** | AKS runs Karpenter as a managed service. Optional on Standard, default on Automatic. |
| Cluster Autoscaler | **Cluster Autoscaler** | min/max per node pool. Balances pools across availability zones (`balance_similar_node_groups`). |
| Fargate | Virtual nodes (ACI) / **Container Apps** | AKS has no 1:1 equivalent for serverless pods, so consider a separate service. |
| ECR | **ACR** | Private Endpoint, geo-replication, and zone redundancy require Premium. Nodes get pull permission through the `AcrPull` role. |
| VPC CNI | **Azure CNI Overlay + Cilium** | Cilium (eBPF) replaces kube-proxy and the NetworkPolicy implementation. kubenet is not recommended for new clusters. |
| AWS Load Balancer Controller (ALB) | **App Routing Gateway API** (approuting-istio), **Application Gateway for Containers** | ingress-nginx maintenance ended in 2026-03 → move to Gateway API → Lab 07. |
| EBS CSI / EFS CSI | **Azure Disk CSI / Azure Files CSI** | Installed and enabled by default. |
| EKS access entries (replacing `aws-auth`) | **Azure RBAC for Kubernetes** (+ Kubernetes RBAC) | **Turning off** local accounts (static kubeconfig) is recommended. Sign in with tokens through `kubelogin`. |
| EKS control plane logging | **Diagnostic settings** (`kube-audit-admin`, `kube-apiserver` …) | Sent to Log Analytics. `kube-audit` is high-volume, so `kube-audit-admin` is recommended. |
| EKS upgrades (manual / Extended Support) | **Auto-upgrade channels** (`patch`, `stable` …) + **maintenance window** | 12 months of support. From 2027-06, the platform automatically upgrades versions that are out of support. |
| Container Insights / AMP / AMG | **Container Insights** (logs) / **Managed Prometheus** / **Managed Grafana** | Unified under Azure Monitor. You connect the collection configuration through DCRs/DCRAs → Lab 05. |
| GuardDuty EKS / Inspector | **Microsoft Defender for Containers** | A subscription-level plan + a cluster profile. |
| AWS Config / Kyverno | **Azure Policy for Kubernetes** (Gatekeeper) | Assign policy initiatives at the RG or subscription scope → Lab 08. |
| EKS pricing: hourly fee per cluster | AKS: **Free / Standard / Premium** tiers | Free has no SLA. Standard has an hourly fee per cluster (check the official price list). Premium includes LTS. |

> [!TIP]
> **The AKS node resource group**: in addition to the cluster RG (for example, `rg-...-aks`), a separate node RG (`rg-...-aks-nodes`) is created that holds the VMSS, load balancers, and disks. Don't modify it directly (Automatic locks it down completely).

## 6. Storage and state

| AWS | Azure | Differences / notes |
|---|---|---|
| S3 | **Blob Storage** (Storage account → Container) | Account names must be globally unique (lowercase letters and digits, 3–24 characters). Versioning and soft delete are account-level options. |
| DynamoDB (lock) | (not needed) | The azurerm backend locks state with a blob lease. |
| EBS | **Managed Disk** | Premium SSD v2 / Ultra, etc. Ephemeral OS disks use the node's local storage. |
| EFS | **Azure Files** (NFS/SMB) | Included in the default AKS CSI drivers. |

## 7. Cost management

| AWS | Azure | Differences / notes |
|---|---|---|
| Budgets | **Cost Management budgets** | `azurerm_consumption_budget_subscription` + tag filter → Lab 08. |
| Savings Plans / RI | **Reservations / Savings plan** | Can also be applied to node VMs. |
| Spot Instances | **Spot VM** (Spot node pool) | On eviction: `Delete` or `Deallocate`. Pods need a toleration. |
| Cost Explorer (EKS) | **AKS cost analysis add-on** | View costs per namespace/workload (`cost_analysis_enabled`). |

## 8. Differences from a Terraform perspective

| AWS | Azure | Differences / notes |
|---|---|---|
| `provider "aws"` | `provider "azurerm"` (+ `azapi`, `azuread`) | **azurerm** = core resources, **azapi** = direct ARM API calls (new features and unsupported properties), **azuread** = Entra objects. azapi plays a role similar to AWS's `awscc`. |
| Credentials: `AWS_PROFILE`, SSO | `az login` + `ARM_SUBSCRIPTION_ID` | In CI, sign in without passwords through **OIDC (workload identity federation)**. |
| `terraform-aws-modules` | **Azure Verified Modules (AVM)** | Official, verified modules. For learning purposes, this lab defines resources directly (consider AVM for production too). |
| `tags` on resources | `tags` on resources + **a resource group is required** | Almost every resource needs the `resource_group_name` argument. |
| S3 backend | **azurerm backend** (`use_azuread_auth = true`) | Uses Entra authentication/RBAC instead of key authentication. |
| Data source (`data "aws_vpc"`) | `data "azurerm_virtual_network"` | To connect stacks, this lab uses a **naming convention + data sources** instead of remote state. |
| Deletion protection / Soft delete | Key Vault soft-delete / purge protection, resource locks | After `terraform destroy`, names can stay reserved for a while → Lab 11. |

> [!WARNING]
> **Key changes in azurerm 5.x (GA in 2026-07)**: the default for automatic Resource Provider registration is `none`, the `node_provisioning_profile` block of `azurerm_kubernetes_cluster` is now required, `rbac_authorization_enabled` of `azurerm_key_vault` is now required, and many `enable_*` arguments were renamed to `*_enabled`. If you copy 4.x code, you get errors at the `terraform validate` step.

## 9. Command cheat sheet

| AWS | Azure | Differences / notes |
|---|---|---|
| `aws sts get-caller-identity` | `az account show` | Check the current subscription, tenant, and user |
| `aws configure sso` / `aws sso login` | `az login` | Select a subscription with `az account set --subscription <id>` |
| `aws eks update-kubeconfig --name x` | `az aks get-credentials -g <rg> -n x` + `kubelogin convert-kubeconfig -l azurecli` | kubelogin handles the Entra sign-in |
| `aws ecr get-login-password \| docker login` | `az acr login -n <acr>` | Use `az acr import` to copy an external image into ACR on the server side |
| `aws ec2 describe-vpcs` | `az network vnet list -o table` | Use `-o table` and `--query` (JMESPath) |
| `aws iam list-attached-role-policies` | `az role assignment list --assignee <id> --all -o table` | Look up role assignments |
| `aws logs start-query` | `az monitor log-analytics query -w <id> --analytics-query "…"` | Uses KQL |
| `aws service-quotas get-service-quota` | `az vm list-usage -l koreacentral -o table` | Quota per vCPU family |
| `eksctl upgrade` | `az aks get-upgrades -g <rg> -n <name>` → `az aks upgrade` | In this lab: patches go through the auto-upgrade channel, and minor versions through `az aks upgrade` after a preflight check (Lab 09). Terraform ignores the version after creation with `ignore_changes` (Lab 09 also describes how to manage the version in code). |

## 10. Best practices this lab follows (summary)

- **State/structure**: stacks split by lifecycle (network → platform → aks → workload), remote state with Entra authentication, pinned provider versions, automated validation with `terraform fmt/validate/test`.
- **Networking**: Azure CNI Overlay + Cilium, fixed egress through a NAT Gateway (StandardV2), default outbound access disabled on subnets, Private Endpoints (ACR/Key Vault).
- **Identity/security**: UAMI + role assignments, **local accounts disabled**, Entra + Azure RBAC, Workload Identity, Key Vault RBAC and purge protection, ACR anonymous access and admin account disabled, Azure Policy, Defender.
- **Availability/operations**: Standard tier (SLA), spread across 3 availability zones, separate System/User pools, PDB, HPA, and topology spread, maintenance window + automatic patch upgrades.
- **Observability**: Managed Prometheus + Container Insights (DCR) + Managed Grafana, control plane diagnostic logs.
- **Cost**: daily log cap, budget alerts, Spot pool (optional), `terraform destroy` after the lab.

Next → [01. Prerequisites](01-prerequisites.md)
