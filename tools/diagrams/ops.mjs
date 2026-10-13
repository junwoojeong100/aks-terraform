// Diagrams for operations, governance, and cleanup
import { Diagram, t } from './lib.mjs';

// ---------------------------------------------------------------------------
// Figure: principal → role → scope (Lab 04)
// ---------------------------------------------------------------------------
function platformIdentities() {
  const title = t('Who can do what: principal → role → scope', '누가 무엇을 할 수 있는가: 주체 → 역할 → 범위');
  const d = new Diagram('platform-identities', 960, 560, {
    title,
    desc: t(
      'The cluster UAMI gets Network Contributor on the network RG and Managed Identity Operator on the kubelet UAMI. The kubelet UAMI gets AcrPull on ACR. The Grafana managed identity gets Monitoring Data Reader on the Azure Monitor workspace. The operator gets AcrPush on ACR and Grafana Admin on Grafana. The app UAMI gets Key Vault Secrets User on Key Vault.',
      '클러스터 UAMI 는 네트워크 RG 에 Network Contributor 와 kubelet UAMI 에 Managed Identity Operator, kubelet UAMI 는 ACR 에 AcrPull, Grafana 관리 ID 는 Monitor workspace 에 Monitoring Data Reader, 운영자는 ACR 에 AcrPush 와 Grafana 에 Grafana Admin, 앱 UAMI 는 Key Vault 에 Key Vault Secrets User 역할이 할당된다.',
    ),
  });
  d.heading(
    title,
    t(
      'Instead of JSON policies, Azure uses a role assignment: "principal + built-in role + scope" (≈ AWS IAM role + attached policy).',
      'Azure 는 JSON 정책 대신 "주체 + 내장 역할 + 범위"를 역할 할당으로 연결합니다 (AWS 의 IAM Role + 정책 연결에 해당).',
    ),
  );

  d.text(24, 104, t('Principal', '주체 (Principal)'), { size: 12.5, bold: true, muted: true });
  d.text(344, 104, t('Role', '역할 (Role)'), { size: 12.5, bold: true, muted: true });
  d.text(636, 104, t('Scope', '범위 (Scope)'), { size: 12.5, bold: true, muted: true });

  const clusterUami = t('Cluster UAMI', '클러스터 UAMI');
  const operator = t('Operator (current user)', '운영자 (현재 사용자)');
  const rows = [
    [clusterUami, 'id', 'Network Contributor', t('Network RG', '네트워크 RG'), t('Join subnets · use NAT GW', '서브넷 join · NAT GW 사용')],
    [clusterUami, 'id', 'Managed Identity Operator', 'kubelet UAMI', t('Attach the kubelet identity to nodes', '노드에 kubelet ID 부착')],
    ['kubelet UAMI', 'id', 'AcrPull', 'ACR', t('Nodes pull images (≈ ECR permissions)', '노드가 이미지를 pull (ECR 권한)')],
    [t('Grafana managed identity', 'Grafana 관리 ID'), 'id', 'Monitoring Data Reader', 'Azure Monitor workspace', t('Grafana queries Prometheus', 'Grafana 가 Prometheus 쿼리')],
    [operator, 'neutral', 'AcrPush', 'ACR', t('Push images · az acr import', '이미지 push · az acr import')],
    [operator, 'neutral', 'Grafana Admin', 'Managed Grafana', t('Sign in to dashboards', '대시보드 로그인')],
    [t('App UAMI (Lab 06)', '앱 UAMI (Lab 06)'), 'warn', 'Key Vault Secrets User', 'Key Vault', t('Read-only access to secrets (least privilege)', '시크릿 읽기 전용 (최소 권한)')],
  ];
  rows.forEach(([who, tone, role, scope, why], i) => {
    const y = 116 + i * 60;
    const a = d.box(24, y, 250, 48, { tone, title: who, pad: 12, padY: 18, titleSize: 13 });
    const b = d.box(630, y, 306, 48, { tone: 'ok', title: scope, lines: [why], pad: 8, titleSize: 13, size: 11 });
    d.arrow([[a.r, a.cy], [b.l, b.cy]], { tone: tone === 'neutral' ? null : tone, label: role, at: 0.5 });
  });
  d.text(24, 546, t('In a team or CI environment, grant the "operator" roles to an Entra group or a CI service principal (grant_current_user_roles = false).', '실습자가 아니라 팀/CI 환경이라면 "운영자" 역할은 Entra 그룹이나 CI 서비스 주체에 부여하세요 (grant_current_user_roles = false).'), { size: 11.5, muted: true, maxW: 912 });
  return d;
}

// ---------------------------------------------------------------------------
// Figure: upgrade flow (Lab 09)
// ---------------------------------------------------------------------------
function upgradeFlow() {
  const title = t('Upgrade flow: patch · node image · minor', '업그레이드 흐름: patch · 노드 이미지 · minor');
  const d = new Diagram('upgrade-flow', 960, 608, {
    title,
    desc: t(
      'Patch and node OS image upgrades are applied by the automatic upgrade channels during the maintenance window. A minor upgrade is manual: preflight checks first, then the control plane, a verification step, and finally the node pools.',
      'patch 와 노드 OS 이미지는 자동 업그레이드 채널이 유지보수 창에 적용하고, minor 업그레이드는 사전 점검 후 컨트롤 플레인, 확인, 노드 풀 순서로 수동 진행한다.',
    ),
  });
  d.heading(
    title,
    t(
      'Automatic upgrades happen only inside the "maintenance window"; manual ones (az aks upgrade or Terraform) start immediately.',
      '자동은 "유지보수 창"에서만 일어나고, 수동(az aks upgrade 나 Terraform)은 즉시 시작됩니다.',
    ),
  );

  const autoLane = (y, tone, label, steps) => {
    d.group(24, y, 912, 128, { tone, label });
    const bs = steps.map((s, i) => d.box(36 + i * 300, y + 36, 276, 80, { tone, title: s[0], lines: s.slice(1), pad: 10, titleSize: 13, size: 11 }));
    d.arrow([[bs[0].r, bs[0].cy], [bs[1].l, bs[1].cy]], { tone });
    d.arrow([[bs[1].r, bs[1].cy], [bs[2].l, bs[2].cy]], { tone });
  };
  autoLane(92, 'ok', t('① Patch upgrade (automatic)', '① patch 업그레이드 (자동)'), [
    t(['Patch channel', 'Applies the latest patch of the', 'same minor automatically'], ['채널 patch', '같은 minor 의 최신 patch 를 자동 적용']),
    t(['Maintenance window', 'Sunday 02:00 KST · 4 hours', '(maintenance_window_auto_upgrade)'], ['유지보수 창', '일요일 02:00 KST · 4시간', '(maintenance_window_auto_upgrade)']),
    t(['AKS applies them in order', 'Control plane → node pools', '(surge 33%, honors PDBs)'], ['AKS 가 순서대로 적용', '컨트롤 플레인 → 노드 풀', '(surge 33%, PDB 존중)']),
  ]);
  autoLane(232, 'net', t('② Node OS image (automatic)', '② 노드 OS 이미지 (자동)'), [
    t(['NodeImage channel', 'Applies each new node image', 'release (weekly)'], ['채널 NodeImage', '주 단위로 새 노드 이미지가 나오면 적용']),
    t(['Maintenance window', 'Saturday 02:00 KST · 4 hours', '(maintenance_window_node_os)'], ['유지보수 창', '토요일 02:00 KST · 4시간', '(maintenance_window_node_os)']),
    t(['Node image replacement', 'Add surge node → cordon · drain', '→ remove the old node'], ['노드 이미지 교체', 'surge 노드 추가 → cordon · drain', '→ 이전 노드 제거']),
  ]);

  d.group(24, 372, 912, 160, { tone: 'azure', label: t('③ Minor upgrade (manual · after preflight checks)', '③ minor 업그레이드 (수동 · 사전 점검 후)') });
  const steps = [
    t(['1 Preflight check', 'az aks get-upgrades', 'Check deprecated APIs', 'PDB · spare subnet IPs'], ['1 사전 점검', 'az aks get-upgrades', 'deprecated API 확인', 'PDB · 서브넷 IP 여유']),
    t(['2 Control plane', 'az aks upgrade', '--control-plane-only', '(apps keep running)'], ['2 컨트롤 플레인', 'az aks upgrade', '--control-plane-only', '(앱은 그대로 동작)']),
    t(['3 Verify', 'Apps · add-ons OK?', 'Gateway API CRDs are', 'updated automatically', 'to match the version'], ['3 확인', '앱 · 애드온 정상?', 'Gateway API CRD 는', '버전에 맞춰 자동 갱신']),
    t(['4 Node pools', 'az aks nodepool upgrade', 'system → user order', 'surge 33%, honors PDBs'], ['4 노드 풀', 'az aks nodepool upgrade', 'system → user 순서', 'surge 33% · PDB 존중']),
    t(['5 Wrap-up', 'Adding a node pool?', 'Set the version', 'variable to the', 'current minor'], ['5 마무리', '새 노드 풀을 추가할 땐', '버전 변수를 현재', 'minor 에 맞추세요']),
  ];
  const sb = steps.map((s, i) => d.box(36 + i * 178, 408, 156, 112, { tone: 'azure', title: s[0], lines: s.slice(1), pad: 10, titleSize: 13, size: 10.5 }));
  for (let i = 0; i < 4; i++) d.arrow([[sb[i].r, sb[i].cy], [sb[i + 1].l, sb[i + 1].cy]], { tone: 'azure' });

  d.box(24, 546, 912, 48, {
    tone: 'neutral', pad: 12, size: 12, muted: false,
    lines: [t('Terraform ignores versions after creation (ignore_changes). To manage versions in code too, use option C in Lab 09.', 'Terraform 은 생성 이후의 버전을 ignore_changes 로 무시합니다. 버전까지 코드로 관리하려면 Lab 09 의 C 방식을 쓰세요.')],
  });
  return d;
}

// ---------------------------------------------------------------------------
// Figure: AKS Standard vs Automatic (Lab 10)
// ---------------------------------------------------------------------------
function standardVsAutomatic() {
  const title = t('AKS Standard vs. AKS Automatic: who operates what', 'AKS Standard 와 AKS Automatic: 누가 운영하나');
  const d = new Diagram('standard-vs-automatic', 960, 548, {
    title,
    desc: t(
      'A table that compares, item by item, what you configure yourself in AKS Standard with what AKS manages by default in AKS Automatic: system node pool, node scaling, upgrades, authentication, networking, policy, observability, and SLA.',
      '시스템 노드 풀, 노드 스케일링, 업그레이드, 인증, 네트워크, 정책, 관측성, SLA 항목별로 AKS Standard 에서는 사용자가 구성하고 AKS Automatic 에서는 AKS 가 기본값으로 관리하는 정도를 비교한 표.',
    ),
  });
  d.heading(
    title,
    t(
      'Automatic is the equivalent of EKS Auto Mode. Blue cells are what you configure; green cells are what AKS handles by default.',
      'Automatic 은 EKS Auto Mode 에 해당합니다. 파란 칸은 내가 구성하는 것, 초록 칸은 AKS 가 기본으로 맡는 것입니다.',
    ),
  );

  const lx = 24;
  const sx = 196;
  const ax = 576;
  const sw = 368;
  const aw = 360;
  const top = 96;
  d.box(sx, top, sw, 36, { tone: 'azure', title: t('AKS Standard (Lab 05) — design it yourself', 'AKS Standard (Lab 05) — 직접 설계'), align: 'center', pad: 8, padY: 11, titleSize: 13.5 });
  d.box(ax, top, aw, 36, { tone: 'ok', title: 'AKS Automatic (Lab 10) ≈ EKS Auto Mode', align: 'center', pad: 8, padY: 11, titleSize: 13.5 });

  const rows = [
    [t('System node pool', '시스템 노드 풀'), t('You create and operate it (System pool)', '직접 만들고 운영 (System 풀)'), t('Managed — operated by AKS', '관리형 — AKS 가 운영')],
    [t('Node scaling', '노드 스케일링'), t('Cluster Autoscaler (or choose NAP)', 'Cluster Autoscaler (또는 NAP 선택)'), t('NAP (Karpenter) only + HPA · KEDA · VPA', 'NAP(Karpenter) 고정 + HPA · KEDA · VPA')],
    [t('Upgrades', '업그레이드'), t('Manual, or choose a channel (this lab: patch)', '수동 또는 채널 선택 (이 실습은 patch)'), t('stable channel (N-1) + automatic node images', 'stable 채널(N-1) + 노드 이미지 자동')],
    [t('Auth · access', '인증 · 접근'), t('Entra + Azure RBAC; you disable local accounts', 'Entra + Azure RBAC, 로컬 계정은 직접 끔'), t('Azure RBAC only · no local accounts', 'Azure RBAC 고정 · 로컬 계정 없음')],
    [t('Networking', '네트워크'), t('Overlay + Cilium, you set up the NAT GW', 'Overlay + Cilium · NAT GW 를 직접 구성'), t('Overlay + Cilium, managed NAT, VNet integration', 'Overlay + Cilium · 관리형 NAT · VNet 통합')],
    [t('Policy', '정책 · 안전장치'), t('You assign Azure Policy yourself (Lab 08)', 'Azure Policy 를 직접 할당 (Lab 08)'), t('Deployment Safeguards + PSS baseline enforced', 'Deployment Safeguards + PSS baseline 강제')],
    [t('Observability', '관측성'), t('You connect Prometheus · Container Insights', 'Prometheus · Container Insights 직접 연결'), t('Portal/CLI: on by default · Terraform: manual', '포털/CLI 는 기본 · Terraform 은 직접 연결')],
    [t('Tier · SLA', '등급 · SLA'), t('Choose Free / Standard / Premium', 'Free / Standard / Premium 중 선택'), t('Fixed: Standard + Pod readiness SLA', 'Standard + Pod readiness SLA 고정')],
  ];
  rows.forEach(([name, s, a], i) => {
    const y = top + 44 + i * 46;
    d.box(lx, y, 160, 38, { title: name, pad: 10, padY: 13, titleSize: 12.5 });
    d.box(sx, y, sw, 38, { tone: 'azure', title: s, pad: 12, padY: 13, titleSize: 12 });
    d.box(ax, y, aw, 38, { tone: 'ok', title: a, pad: 12, padY: 13, titleSize: 12 });
  });
  d.text(24, 534, t('※ Converting Standard to Automatic in place is not supported. Decide which one to use from the start.', '※ Standard 에서 Automatic 으로 제자리 전환은 지원되지 않습니다. 처음부터 어느 쪽을 쓸지 정하세요.'), { size: 11.5, muted: true, maxW: 912 });
  return d;
}

// ---------------------------------------------------------------------------
// Figure: destroy order (Lab 11)
// ---------------------------------------------------------------------------
function destroyOrder() {
  const title = t('Destroy order and caveats', '삭제(destroy) 순서와 주의점');
  const d = new Diagram('destroy-order', 960, 480, {
    title,
    desc: t(
      'Stacks are destroyed in this order: 10-aks-automatic, 08-governance, 07-ingress, 06-workload, 05-aks, 04-platform, 03-network, 02-bootstrap. The diagram shows the caveats for each step.',
      '10-aks-automatic, 08-governance, 07-ingress, 06-workload, 05-aks, 04-platform, 03-network, 02-bootstrap 순서로 삭제하며 각 단계의 주의점을 보여 준다.',
    ),
  });
  d.heading(
    title,
    t(
      'This is the reverse of creation order. scripts/cleanup.sh handles this order and the safeguards automatically.',
      '생성의 역순입니다. scripts/cleanup.sh 가 이 순서와 안전장치를 자동으로 처리합니다.',
    ),
  );

  const w = 204;
  const gap = 32;
  const x = (col) => 24 + col * (w + gap);
  const h = 118;
  const step = (n, col, y, tone, name, lines, extra = {}) => {
    const b = d.box(x(col), y, w, h, { tone, title: name, lines, pad: 12, ...extra });
    d.badge(x(col) + w - 22, y + 22, n, { tone: 'danger', r: 11 });
    return b;
  };
  const r1 = 100;
  const r2 = 258;
  const b10 = step(1, 0, r1, 'neutral', '10-aks-automatic', t(['AKS Automatic (optional)', 'Independent of 05, so', 'delete it first'], ['AKS Automatic (선택)', '05 와 독립이라 가장 먼저']), { dashed: true });
  const b08 = step(2, 1, r1, 'warn', '08-governance', t(['Remove resource locks', 'first (a lock causes', 'ScopeLocked errors)', 'Defender plans off too'], ['리소스 잠금을 먼저 해제', '(잠금이 있으면 ScopeLocked)', 'Defender 플랜도 함께 해제']));
  const b07 = step(3, 2, r1, 'id', '07-ingress', t(['The cluster must still', 'exist so the kubernetes', 'provider can connect', 'and delete resources'], ['클러스터가 살아 있어야', 'kubernetes provider 가', '접속해 삭제할 수 있음']));
  const b06 = step(4, 3, r1, 'id', '06-workload', t(['Same reason as 07', 'UAMI', 'Federated credential', 'Key Vault demo secret'], ['07 과 같은 이유', 'UAMI · 연합 자격 증명', 'Key Vault 데모 시크릿']));
  const b05 = step(5, 3, r2, 'azure', '05-aks', t(['AKS + node pools', 'Node resource group is', 'deleted too (10–20 min)'], ['AKS + 노드 풀', '노드 리소스 그룹도 함께', '삭제 (10–20분)']));
  const b04 = step(6, 2, r2, 'ok', '04-platform', t(['ACR · Key Vault · Grafana', 'Key Vault soft-delete:', 'only the name is held', 'for 7 days (no charge)'], ['ACR · Key Vault · Grafana', 'Key Vault 는 soft-delete:', '7일간 이름만 점유 (무과금)']));
  const b03 = step(7, 1, r2, 'net', '03-network', t(['NAT Gateway · public IP', 'Billing stops on delete', 'Private DNS zone'], ['NAT Gateway · 공인 IP', '삭제되면 과금 중지', 'Private DNS Zone']));
  const b02 = step(8, 0, r2, 'neutral', t('02-bootstrap', '02-bootstrap (옵션)'), t(['Optional · it hosts the', 'state store itself, so', 'revert to local state', 'and delete it last'], ['state 저장소 자신이라', '로컬 state 로 되돌린 뒤', '마지막에 삭제']), { dashed: true });

  d.arrow([[b10.r, b10.cy], [b08.l, b08.cy]], { tone: 'danger' });
  d.arrow([[b08.r, b08.cy], [b07.l, b07.cy]], { tone: 'danger' });
  d.arrow([[b07.r, b07.cy], [b06.l, b06.cy]], { tone: 'danger' });
  d.arrow([[b06.cx, b06.b], [b05.cx, b05.t]], { tone: 'danger' });
  d.arrow([[b05.l, b05.cy], [b04.r, b04.cy]], { tone: 'danger' });
  d.arrow([[b04.l, b04.cy], [b03.r, b03.cy]], { tone: 'danger' });
  d.arrow([[b03.l, b03.cy], [b02.r, b02.cy]], { tone: 'danger' });

  d.box(24, 396, 912, 64, {
    tone: 'neutral', pad: 12, size: 12, muted: false, title: t('Run', '실행'), titleSize: 13,
    lines: [t('scripts/cleanup.sh --dry-run  →  scripts/cleanup.sh   (confirmation prompt · skips deleted stacks · final check for leftovers)', 'scripts/cleanup.sh --dry-run  →  scripts/cleanup.sh   (확인 입력 · 이미 지운 스택은 건너뜀 · 마지막에 남은 리소스 점검)')],
  });
  return d;
}

// ---------------------------------------------------------------------------
// Figure: governance scopes (Lab 08)
// ---------------------------------------------------------------------------
function governanceScopes() {
  const title = t('Where to apply governance: scopes', '거버넌스는 어느 범위에 거는가');
  const d = new Diagram('governance-scopes', 960, 540, {
    title,
    desc: t(
      'Shows how Azure Policy initiatives, Defender plans and budgets, resource locks, and Gatekeeper apply across the chain of scopes: management group, subscription, resource group, and AKS cluster.',
      '관리 그룹, 구독, 리소스 그룹, AKS 클러스터로 이어지는 범위에 Azure Policy 이니셔티브, Defender 플랜과 예산, 리소스 잠금, Gatekeeper 가 어떻게 걸리는지 보여 준다.',
    ),
  });
  d.heading(
    title,
    t(
      'Policies and role assignments are inherited downward. This lab assigns policies at the resource group (cluster RG) scope.',
      '정책과 역할 할당은 상위 범위에서 하위로 상속됩니다. 이 실습은 리소스 그룹(클러스터 RG) 범위에 정책을 할당합니다.',
    ),
  );

  const levels = [
    [t('Management group (optional)', '관리 그룹 (선택)'), 'neutral', t(['Apply one organization-wide policy initiative', 'to many subscriptions at once (recommended in production)'], ['조직 공통 정책 이니셔티브를', '구독 여러 개에 한 번에 적용 (운영 권장)'])],
    [t('Subscription', '구독'), 'warn', t(['Defender for Containers subscription plan', 'Budget and cost alerts'], ['Defender for Containers 구독 플랜', '예산(Budget)과 비용 알림'])],
    [t('Resource group', '리소스 그룹'), 'azure', t(['Cluster RG: Pod security baseline/restricted and', '6 cluster configuration policies (Audit by default)', 'network · platform RGs: deletion-protection locks (optional)'], ['클러스터 RG: Pod 보안 baseline/restricted 와', '클러스터 설정 정책 6개 (기본 Audit)', 'network · platform RG: 삭제 방지 잠금(옵션)'])],
    [t('AKS cluster', 'AKS 클러스터'), 'ok', t(['The Azure Policy add-on (Gatekeeper) evaluates at admission', 'Audit only reports; Deny rejects the deployment'], ['Azure Policy 애드온(Gatekeeper)이 Admission 에서 평가', 'Audit 는 보고만, Deny 는 배포를 거부'])],
  ];
  const lx = 24;
  const lw = 580;
  const gap = 28;
  let y = 100;
  levels.forEach(([name, tone, lines], i) => {
    const b = d.box(lx, y, lw, null, { tone, title: name, lines, pad: 12, titleSize: 14, size: 12 });
    if (i < levels.length - 1) d.arrow([[b.cx, b.b], [b.cx, b.b + gap]], { label: t('inherited', '상속'), at: 0.5, dx: t(52, 40) });
    y = b.b + gap;
  });

  const eff = d.box(632, 100, 304, null, {
    tone: 'warn', title: t('Policy effects', '정책 효과(effect)'), pad: 12, titleSize: 13.5, size: 11.5,
    lines: t(
      ['Audit (default): report only', 'Deny: reject the deployment', 'Disabled: skip evaluation', '', 'Evaluation can take up to tens of', 'minutes right after assignment', 'Start with Audit to see the impact first'],
      ['Audit (기본)  비준수를 보고만 함', 'Deny           배포를 거부', 'Disabled       평가하지 않음', '', '평가는 할당 직후 최대 수십 분', '처음에는 Audit 으로 영향부터 확인'],
    ),
  });
  d.box(632, eff.b + 20, 304, null, {
    tone: 'aws', title: t('AWS comparison', 'AWS 와 비교'), pad: 12, titleSize: 13.5, size: 11.5,
    lines: t(
      ['SCP: a permission ceiling for an account', 'Azure Policy: evaluates resource', 'properties to audit · deny · modify', '', 'AWS Config rules ≈ Policy Audit', 'Kyverno/OPA ≈ Policy add-on (Gatekeeper)', 'GuardDuty ≈ Defender for Containers'],
      ['SCP: 계정이 쓸 수 있는 권한의 상한선', 'Azure Policy: 리소스의 속성을 평가해', '감사 · 거부 · 자동 수정', '', 'AWS Config 규칙 ≈ Policy Audit', 'Kyverno/OPA ≈ Policy 애드온(Gatekeeper)', 'GuardDuty ≈ Defender for Containers'],
    ),
  });
  return d;
}

export const diagrams = [
  { name: 'platform-identities', build: platformIdentities },
  { name: 'upgrade-flow', build: upgradeFlow },
  { name: 'standard-vs-automatic', build: standardVsAutomatic },
  { name: 'destroy-order', build: destroyOrder },
  { name: 'governance-scopes', build: governanceScopes },
];
