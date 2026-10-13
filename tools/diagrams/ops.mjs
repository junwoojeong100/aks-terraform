// 운영 · 거버넌스 · 정리 관련 다이어그램
import { Diagram } from './lib.mjs';

// ---------------------------------------------------------------------------
// 그림: 주체 → 역할 → 범위 (Lab 04)
// ---------------------------------------------------------------------------
function platformIdentities() {
  const d = new Diagram('platform-identities', 960, 560, {
    title: '누가 무엇을 할 수 있는가: 주체 → 역할 → 범위',
    desc: '클러스터 UAMI 는 네트워크 RG 에 Network Contributor 와 kubelet UAMI 에 Managed Identity Operator, kubelet UAMI 는 ACR 에 AcrPull, Grafana 관리 ID 는 Monitor workspace 에 Monitoring Data Reader, 운영자는 ACR 에 AcrPush 와 Grafana 에 Grafana Admin, 앱 UAMI 는 Key Vault 에 Key Vault Secrets User 역할이 할당된다.',
  });
  d.heading('누가 무엇을 할 수 있는가: 주체 → 역할 → 범위', 'Azure 는 JSON 정책 대신 "주체 + 내장 역할 + 범위"를 역할 할당으로 연결합니다 (AWS 의 IAM Role + 정책 연결에 해당).');

  d.text(24, 104, '주체 (Principal)', { size: 12.5, bold: true, muted: true });
  d.text(344, 104, '역할 (Role)', { size: 12.5, bold: true, muted: true });
  d.text(636, 104, '범위 (Scope)', { size: 12.5, bold: true, muted: true });

  const rows = [
    ['클러스터 UAMI', 'id', 'Network Contributor', '네트워크 RG', '서브넷 join · NAT GW 사용'],
    ['클러스터 UAMI', 'id', 'Managed Identity Operator', 'kubelet UAMI', '노드에 kubelet ID 부착'],
    ['kubelet UAMI', 'id', 'AcrPull', 'ACR', '노드가 이미지를 pull (ECR 권한)'],
    ['Grafana 관리 ID', 'id', 'Monitoring Data Reader', 'Azure Monitor workspace', 'Grafana 가 Prometheus 쿼리'],
    ['운영자 (현재 사용자)', 'neutral', 'AcrPush', 'ACR', '이미지 push · az acr import'],
    ['운영자 (현재 사용자)', 'neutral', 'Grafana Admin', 'Managed Grafana', '대시보드 로그인'],
    ['앱 UAMI (Lab 06)', 'warn', 'Key Vault Secrets User', 'Key Vault', '시크릿 읽기 전용 (최소 권한)'],
  ];
  rows.forEach(([who, tone, role, scope, why], i) => {
    const y = 116 + i * 60;
    const a = d.box(24, y, 250, 48, { tone, title: who, pad: 12, padY: 18, titleSize: 13 });
    const b = d.box(630, y, 306, 48, { tone: 'ok', title: scope, lines: [why], pad: 8, titleSize: 13, size: 11 });
    d.arrow([[a.r, a.cy], [b.l, b.cy]], { tone: tone === 'neutral' ? null : tone, label: role, at: 0.5 });
  });
  d.text(24, 546, '실습자가 아니라 팀/CI 환경이라면 "운영자" 역할은 Entra 그룹이나 CI 서비스 주체에 부여하세요 (grant_current_user_roles = false).', { size: 11.5, muted: true, maxW: 912 });
  return d;
}

// ---------------------------------------------------------------------------
// 그림: 업그레이드 흐름 (Lab 09)
// ---------------------------------------------------------------------------
function upgradeFlow() {
  const d = new Diagram('upgrade-flow', 960, 608, {
    title: '업그레이드 흐름: patch · 노드 이미지 · minor',
    desc: 'patch 와 노드 OS 이미지는 자동 업그레이드 채널이 유지보수 창에 적용하고, minor 업그레이드는 사전 점검 후 컨트롤 플레인, 확인, 노드 풀 순서로 수동 진행한다.',
  });
  d.heading('업그레이드 흐름: patch · 노드 이미지 · minor', '자동은 "유지보수 창"에서만 일어나고, 수동(az aks upgrade 나 Terraform)은 즉시 시작됩니다.');

  const autoLane = (y, tone, label, steps) => {
    d.group(24, y, 912, 128, { tone, label });
    const bs = steps.map((s, i) => d.box(36 + i * 300, y + 36, 276, 80, { tone, title: s[0], lines: s.slice(1), pad: 10, titleSize: 13, size: 11 }));
    d.arrow([[bs[0].r, bs[0].cy], [bs[1].l, bs[1].cy]], { tone });
    d.arrow([[bs[1].r, bs[1].cy], [bs[2].l, bs[2].cy]], { tone });
  };
  autoLane(92, 'ok', '① patch 업그레이드 (자동)', [
    ['채널 patch', '같은 minor 의 최신 patch 를 자동 적용'],
    ['유지보수 창', '일요일 02:00 KST · 4시간', '(maintenance_window_auto_upgrade)'],
    ['AKS 가 순서대로 적용', '컨트롤 플레인 → 노드 풀', '(surge 33%, PDB 존중)'],
  ]);
  autoLane(232, 'net', '② 노드 OS 이미지 (자동)', [
    ['채널 NodeImage', '주 단위로 새 노드 이미지가 나오면 적용'],
    ['유지보수 창', '토요일 02:00 KST · 4시간', '(maintenance_window_node_os)'],
    ['노드 이미지 교체', 'surge 노드 추가 → cordon · drain', '→ 이전 노드 제거'],
  ]);

  d.group(24, 372, 912, 160, { tone: 'azure', label: '③ minor 업그레이드 (수동 · 사전 점검 후)' });
  const steps = [
    ['1 사전 점검', 'az aks get-upgrades', 'deprecated API 확인', 'PDB · 서브넷 IP 여유'],
    ['2 컨트롤 플레인', 'az aks upgrade', '--control-plane-only', '(앱은 그대로 동작)'],
    ['3 확인', '앱 · 애드온 정상?', 'Gateway API CRD 는', '버전에 맞춰 자동 갱신'],
    ['4 노드 풀', 'az aks nodepool upgrade', 'system → user 순서', 'surge 33% · PDB 존중'],
    ['5 마무리', '새 노드 풀을 추가할 땐', '버전 변수를 현재', 'minor 에 맞추세요'],
  ];
  const sb = steps.map((s, i) => d.box(36 + i * 178, 408, 156, 112, { tone: 'azure', title: s[0], lines: s.slice(1), pad: 10, titleSize: 13, size: 10.5 }));
  for (let i = 0; i < 4; i++) d.arrow([[sb[i].r, sb[i].cy], [sb[i + 1].l, sb[i + 1].cy]], { tone: 'azure' });

  d.box(24, 546, 912, 48, {
    tone: 'neutral', pad: 12, size: 12, muted: false,
    lines: ['Terraform 은 생성 이후의 버전을 ignore_changes 로 무시합니다. 버전까지 코드로 관리하려면 Lab 09 의 C 방식을 쓰세요.'],
  });
  return d;
}

// ---------------------------------------------------------------------------
// 그림: AKS Standard vs Automatic (Lab 10)
// ---------------------------------------------------------------------------
function standardVsAutomatic() {
  const d = new Diagram('standard-vs-automatic', 960, 548, {
    title: 'AKS Standard 와 AKS Automatic: 누가 운영하나',
    desc: '시스템 노드 풀, 노드 스케일링, 업그레이드, 인증, 네트워크, 정책, 관측성, SLA 항목별로 AKS Standard 에서는 사용자가 구성하고 AKS Automatic 에서는 AKS 가 기본값으로 관리하는 정도를 비교한 표.',
  });
  d.heading('AKS Standard 와 AKS Automatic: 누가 운영하나', 'Automatic 은 EKS Auto Mode 에 해당합니다. 파란 칸은 내가 구성하는 것, 초록 칸은 AKS 가 기본으로 맡는 것입니다.');

  const lx = 24;
  const sx = 196;
  const ax = 576;
  const sw = 368;
  const aw = 360;
  const top = 96;
  d.box(sx, top, sw, 36, { tone: 'azure', title: 'AKS Standard (Lab 05) — 직접 설계', align: 'center', pad: 8, padY: 11, titleSize: 13.5 });
  d.box(ax, top, aw, 36, { tone: 'ok', title: 'AKS Automatic (Lab 10) ≈ EKS Auto Mode', align: 'center', pad: 8, padY: 11, titleSize: 13.5 });

  const rows = [
    ['시스템 노드 풀', '직접 만들고 운영 (System 풀)', '관리형 — AKS 가 운영'],
    ['노드 스케일링', 'Cluster Autoscaler (또는 NAP 선택)', 'NAP(Karpenter) 고정 + HPA · KEDA · VPA'],
    ['업그레이드', '수동 또는 채널 선택 (이 실습은 patch)', 'stable 채널(N-1) + 노드 이미지 자동'],
    ['인증 · 접근', 'Entra + Azure RBAC, 로컬 계정은 직접 끔', 'Azure RBAC 고정 · 로컬 계정 없음'],
    ['네트워크', 'Overlay + Cilium · NAT GW 를 직접 구성', 'Overlay + Cilium · 관리형 NAT · VNet 통합'],
    ['정책 · 안전장치', 'Azure Policy 를 직접 할당 (Lab 08)', 'Deployment Safeguards + PSS baseline 강제'],
    ['관측성', 'Prometheus · Container Insights 직접 연결', '포털/CLI 는 기본 · Terraform 은 직접 연결'],
    ['등급 · SLA', 'Free / Standard / Premium 중 선택', 'Standard + Pod readiness SLA 고정'],
  ];
  rows.forEach(([name, s, a], i) => {
    const y = top + 44 + i * 46;
    d.box(lx, y, 160, 38, { title: name, pad: 10, padY: 13, titleSize: 12.5 });
    d.box(sx, y, sw, 38, { tone: 'azure', title: s, pad: 12, padY: 13, titleSize: 12 });
    d.box(ax, y, aw, 38, { tone: 'ok', title: a, pad: 12, padY: 13, titleSize: 12 });
  });
  d.text(24, 534, '※ Standard 에서 Automatic 으로 제자리 전환은 지원되지 않습니다. 처음부터 어느 쪽을 쓸지 정하세요.', { size: 11.5, muted: true, maxW: 912 });
  return d;
}

// ---------------------------------------------------------------------------
// 그림: 삭제 순서 (Lab 11)
// ---------------------------------------------------------------------------
function destroyOrder() {
  const d = new Diagram('destroy-order', 960, 480, {
    title: '삭제(destroy) 순서와 주의점',
    desc: '10-aks-automatic, 08-governance, 07-ingress, 06-workload, 05-aks, 04-platform, 03-network, 02-bootstrap 순서로 삭제하며 각 단계의 주의점을 보여 준다.',
  });
  d.heading('삭제(destroy) 순서와 주의점', '생성의 역순입니다. scripts/cleanup.sh 가 이 순서와 안전장치를 자동으로 처리합니다.');

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
  const b10 = step(1, 0, r1, 'neutral', '10-aks-automatic', ['AKS Automatic (선택)', '05 와 독립이라 가장 먼저'], { dashed: true });
  const b08 = step(2, 1, r1, 'warn', '08-governance', ['리소스 잠금을 먼저 해제', '(잠금이 있으면 ScopeLocked)', 'Defender 플랜도 함께 해제']);
  const b07 = step(3, 2, r1, 'id', '07-ingress', ['클러스터가 살아 있어야', 'kubernetes provider 가', '접속해 삭제할 수 있음']);
  const b06 = step(4, 3, r1, 'id', '06-workload', ['07 과 같은 이유', 'UAMI · 연합 자격 증명', 'Key Vault 데모 시크릿']);
  const b05 = step(5, 3, r2, 'azure', '05-aks', ['AKS + 노드 풀', '노드 리소스 그룹도 함께', '삭제 (10–20분)']);
  const b04 = step(6, 2, r2, 'ok', '04-platform', ['ACR · Key Vault · Grafana', 'Key Vault 는 soft-delete:', '7일간 이름만 점유 (무과금)']);
  const b03 = step(7, 1, r2, 'net', '03-network', ['NAT Gateway · 공인 IP', '삭제되면 과금 중지', 'Private DNS Zone']);
  const b02 = step(8, 0, r2, 'neutral', '02-bootstrap (옵션)', ['state 저장소 자신이라', '로컬 state 로 되돌린 뒤', '마지막에 삭제'], { dashed: true });

  d.arrow([[b10.r, b10.cy], [b08.l, b08.cy]], { tone: 'danger' });
  d.arrow([[b08.r, b08.cy], [b07.l, b07.cy]], { tone: 'danger' });
  d.arrow([[b07.r, b07.cy], [b06.l, b06.cy]], { tone: 'danger' });
  d.arrow([[b06.cx, b06.b], [b05.cx, b05.t]], { tone: 'danger' });
  d.arrow([[b05.l, b05.cy], [b04.r, b04.cy]], { tone: 'danger' });
  d.arrow([[b04.l, b04.cy], [b03.r, b03.cy]], { tone: 'danger' });
  d.arrow([[b03.l, b03.cy], [b02.r, b02.cy]], { tone: 'danger' });

  d.box(24, 396, 912, 64, {
    tone: 'neutral', pad: 12, size: 12, muted: false, title: '실행', titleSize: 13,
    lines: ['scripts/cleanup.sh --dry-run  →  scripts/cleanup.sh   (확인 입력 · 이미 지운 스택은 건너뜀 · 마지막에 남은 리소스 점검)'],
  });
  return d;
}

// ---------------------------------------------------------------------------
// 그림: 거버넌스 범위 (Lab 08)
// ---------------------------------------------------------------------------
function governanceScopes() {
  const d = new Diagram('governance-scopes', 960, 540, {
    title: '거버넌스는 어느 범위에 거는가',
    desc: '관리 그룹, 구독, 리소스 그룹, AKS 클러스터로 이어지는 범위에 Azure Policy 이니셔티브, Defender 플랜과 예산, 리소스 잠금, Gatekeeper 가 어떻게 걸리는지 보여 준다.',
  });
  d.heading('거버넌스는 어느 범위에 거는가', '정책과 역할 할당은 상위 범위에서 하위로 상속됩니다. 이 실습은 리소스 그룹(클러스터 RG) 범위에 정책을 할당합니다.');

  const levels = [
    ['관리 그룹 (선택)', 'neutral', ['조직 공통 정책 이니셔티브를', '구독 여러 개에 한 번에 적용 (운영 권장)']],
    ['구독', 'warn', ['Defender for Containers 구독 플랜', '예산(Budget)과 비용 알림']],
    ['리소스 그룹', 'azure', ['클러스터 RG: Pod 보안 baseline/restricted 와', '클러스터 설정 정책 6개 (기본 Audit)', 'network · platform RG: 삭제 방지 잠금(옵션)']],
    ['AKS 클러스터', 'ok', ['Azure Policy 애드온(Gatekeeper)이 Admission 에서 평가', 'Audit 는 보고만, Deny 는 배포를 거부']],
  ];
  const lx = 24;
  const lw = 580;
  const gap = 28;
  let y = 100;
  levels.forEach(([title, tone, lines], i) => {
    const b = d.box(lx, y, lw, null, { tone, title, lines, pad: 12, titleSize: 14, size: 12 });
    if (i < levels.length - 1) d.arrow([[b.cx, b.b], [b.cx, b.b + gap]], { label: '상속', at: 0.5, dx: 40 });
    y = b.b + gap;
  });

  const eff = d.box(632, 100, 304, null, {
    tone: 'warn', title: '정책 효과(effect)', pad: 12, titleSize: 13.5, size: 11.5,
    lines: ['Audit (기본)  비준수를 보고만 함', 'Deny           배포를 거부', 'Disabled       평가하지 않음', '', '평가는 할당 직후 최대 수십 분', '처음에는 Audit 으로 영향부터 확인'],
  });
  d.box(632, eff.b + 20, 304, null, {
    tone: 'aws', title: 'AWS 와 비교', pad: 12, titleSize: 13.5, size: 11.5,
    lines: ['SCP: 계정이 쓸 수 있는 권한의 상한선', 'Azure Policy: 리소스의 속성을 평가해', '감사 · 거부 · 자동 수정', '', 'AWS Config 규칙 ≈ Policy Audit', 'Kyverno/OPA ≈ Policy 애드온(Gatekeeper)', 'GuardDuty ≈ Defender for Containers'],
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
