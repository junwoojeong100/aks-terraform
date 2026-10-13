// 전체 구조와 스택 계층 다이어그램
import { Diagram } from './lib.mjs';

// ---------------------------------------------------------------------------
// 그림: 이 가이드가 만드는 전체 구조
// ---------------------------------------------------------------------------
function overviewArchitecture() {
  const d = new Diagram('overview-architecture', 960, 640, {
    title: '이 가이드가 만드는 전체 구조',
    desc: '인터넷 사용자가 공용 로드밸런서와 Gateway(Envoy)를 거쳐 3개 가용 영역에 걸친 AKS 노드 풀의 앱에 접속하고, 노드는 NAT Gateway 로 나가며, ACR 과 Key Vault 는 Private Endpoint 로 접근하는 구조.',
  });
  d.heading('이 가이드가 만드는 전체 구조', 'EKS 구성(VPC · EKS · ECR · IAM)과 짝지어 읽으세요. 색이 있는 상자는 Azure 서비스, 점선은 논리적 경계입니다.');

  // 왼쪽: 외부 행위자
  const user = d.box(24, 250, 130, 60, { title: '사용자', lines: ['인터넷'], align: 'center', pad: 10 });
  const ext = d.box(24, 467, 130, 60, { title: '외부 서비스', lines: ['egress 대상'], align: 'center', pad: 8 });
  const op = d.box(24, 546, 130, 60, { title: '운영자', lines: ['kubectl · terraform'], align: 'center', pad: 8, size: 10.5 });

  // 구독
  d.group(170, 96, 766, 532, { label: 'Azure 구독 · koreacentral', tone: 'azure' });
  d.box(186, 128, 270, 58, { tone: 'id', title: 'Microsoft Entra ID', lines: ['로그인 · Azure RBAC · Workload Identity'], size: 11 });
  d.box(468, 128, 246, 58, { tone: 'warn', title: '거버넌스 (Lab 08)', lines: ['Azure Policy · Defender · 잠금 · 예산'], size: 11 });

  // VNet
  d.group(186, 200, 528, 416, { tone: 'net', label: 'VNet 10.10.0.0/16 · 서브넷은 영역에 묶이지 않고 NSG 로 보호' });

  // 노드 서브넷 + 3개 영역
  d.group(200, 230, 500, 216, { tone: 'net', label: 'snet-aks-nodes 10.10.0.0/24', dashed: true, labelSize: 12 });
  const zx = [212, 374, 536];
  ['영역 1', '영역 2', '영역 3'].forEach((z, i) => {
    d.group(zx[i], 262, 150, 148, { label: z, labelSize: 12 });
    d.box(zx[i] + 10, 290, 130, 50, { tone: 'azure', title: 'system 노드', lines: ['D4ds_v5'], pad: 8, titleSize: 13, size: 11.5 });
    d.box(zx[i] + 10, 348, 130, 50, { tone: 'azure', title: 'user 노드', lines: ['D4ds_v5'], pad: 8, titleSize: 13, size: 11.5 });
  });
  d.text(214, 426, '앞단: 공용 Azure LB(공인 IP) → Gateway(Envoy) 파드 · Pod CIDR 10.244.0.0/16', { size: 11, muted: true, maxW: 476 });

  // 서브넷 아래 줄: NAT / Private Endpoint / API 서버 / Ingress
  const nat = d.box(200, 462, 240, 70, { tone: 'net', title: 'NAT Gateway (StandardV2)', lines: ['고정 공인 IP · 영역 중복', '노드 서브넷의 egress 경로'], pad: 10, titleSize: 12.5, size: 11 });
  const pe = d.box(460, 462, 240, 70, { tone: 'net', title: 'snet-private-endpoints', lines: ['10.10.3.0/27', 'ACR · Key Vault 로 가는 사설 경로'], pad: 10, titleSize: 12.5, size: 11 });
  const api = d.box(200, 544, 240, 64, { tone: 'net', title: 'snet-aks-apiserver', lines: ['10.10.1.0/28 · VNet Integration'], pad: 10, titleSize: 12.5, size: 11 });
  d.box(460, 544, 240, 64, { tone: 'net', title: 'snet-ingress', lines: ['10.10.2.0/27 · 내부 LB(옵션)'], pad: 10, titleSize: 12.5, size: 11 });

  // 공용 서비스
  d.group(726, 200, 196, 416, { tone: 'ok', label: '공용 서비스' });
  const svc = [
    ['ACR (Premium)', '이미지 저장소 ≈ ECR'],
    ['Key Vault', '시크릿 ≈ Secrets Manager'],
    ['Log Analytics', '로그 ≈ CloudWatch Logs'],
    ['Monitor workspace', 'Prometheus 메트릭 저장소'],
    ['Managed Grafana', '대시보드 ≈ AMG'],
  ];
  const sb = svc.map(([t, l], i) => d.box(736, 232 + i * 64, 176, 56, { tone: 'ok', title: t, lines: [l], pad: 10, titleSize: t.length > 18 ? 12 : 13, size: 11.5 }));
  d.box(736, 552, 176, 56, { title: 'Storage (Blob)', lines: ['Terraform state ≈ S3'], pad: 10, titleSize: 13, size: 11.5 });

  // 화살표
  d.arrow([[user.r, user.cy], [200, user.cy]], { tone: 'azure', label: 'HTTP(S)', at: 0.5, dy: -14 });
  d.arrow([[320, 446], [320, nat.t]], { tone: 'net' });
  d.arrow([[580, 446], [580, pe.t]], { tone: 'ok' });
  d.arrow([[nat.l, nat.cy], [ext.r, ext.cy]], { tone: 'net', label: 'egress', at: 0.5, dy: -14 });
  d.arrow([[op.r, api.cy], [api.l, api.cy]], { tone: 'id', label: 'kubectl', at: 0.5, dy: -14 });
  // Private Endpoint → ACR, Key Vault (공용 서비스 사이의 좁은 틈으로 배선)
  d.arrow([[pe.r, pe.cy], [720, pe.cy], [720, sb[0].cy], [sb[0].l, sb[0].cy]], { tone: 'ok' });
  d.arrow([[720, sb[1].cy], [sb[1].l, sb[1].cy]], { tone: 'ok' });
  return d;
}

// ---------------------------------------------------------------------------
// 그림: Terraform 스택 계층과 실행 순서
// ---------------------------------------------------------------------------
function stackLayers() {
  const d = new Diagram('stack-layers', 960, 530, {
    title: 'Terraform 스택 계층과 실행 순서',
    desc: '02-bootstrap 에서 03-network, 04-platform, 05-aks, 06-workload, 07-ingress, 08-governance 순서로 apply 하고, 삭제는 역순으로 한다. 10-aks-automatic 은 독립적인 선택 스택이다. 모든 스택의 state 는 02 가 만든 Blob 컨테이너에 저장된다.',
  });
  d.heading('Terraform 스택 계층과 실행 순서', '수명주기가 다른 것을 스택(= 독립된 state)으로 나눕니다. apply 는 화살표 방향, destroy 는 그 반대입니다.');

  const w = 204;
  const gap = 32;
  const x = (col) => 24 + col * (w + gap);
  const row1 = 106;
  const row2 = 274;
  const h = 124;

  // [열, 행 y, 색, 이름, 설명 줄, Lab]
  const stack = (col, y, tone, name, lines, lab, extra = {}) => {
    const b = d.box(x(col), y, w, h, { tone, title: name, lines, pad: 12, ...extra });
    d.pill(x(col) + 14, y - 11, lab, { tone, size: 11 });
    d.text(x(col) + 12, y + h - 12, `key: ${name}.tfstate`, { size: 11, muted: true, maxW: w - 24 });
    return b;
  };
  const g02 = stack(0, row1, 'neutral', '02-bootstrap', ['state 저장소 (Blob)', '처음엔 로컬 state', '→ 마지막에 원격으로 이전'], 'Lab 02');
  const g03 = stack(1, row1, 'net', '03-network', ['VNet · 서브넷 · NSG', 'NAT Gateway', 'Private DNS Zone'], 'Lab 03');
  const g04 = stack(2, row1, 'ok', '04-platform', ['ACR · Key Vault', 'Log Analytics · Grafana', 'Prometheus · AKS 용 UAMI'], 'Lab 04');
  const g05 = stack(3, row1, 'azure', '05-aks', ['AKS 클러스터 · 노드 풀', '관측성(DCR) · Gateway API', 'Entra RBAC 역할 할당'], 'Lab 05');
  // 2행은 오른쪽 → 왼쪽으로 이어집니다 (뱀 모양 배치)
  const g06 = stack(3, row2, 'id', '06-workload', ['Workload Identity', 'Key Vault CSI 데모'], 'Lab 06');
  const g07 = stack(2, row2, 'id', '07-ingress', ['Gateway · HTTPRoute', '데모 앱 · PDB · HPA', 'NetworkPolicy'], 'Lab 07');
  const g08 = stack(1, row2, 'warn', '08-governance', ['Azure Policy · Defender', '리소스 잠금 · 예산'], 'Lab 08');
  const g10 = stack(0, row2, 'neutral', '10-aks-automatic', ['AKS Automatic (선택)', '= EKS Auto Mode 에 해당', '위 스택과 독립적으로 실행'], 'Lab 10', { dashed: true });

  d.arrow([[g02.r, g02.cy], [g03.l, g03.cy]], { tone: 'azure' });
  d.arrow([[g03.r, g03.cy], [g04.l, g04.cy]], { tone: 'azure' });
  d.arrow([[g04.r, g04.cy], [g05.l, g05.cy]], { tone: 'azure' });
  d.arrow([[g05.cx, g05.b], [g06.cx, g06.t]], { tone: 'azure', label: 'kubeconfig · OIDC issuer', at: 0.5, dx: -92 });
  d.arrow([[g06.l, g06.cy], [g07.r, g07.cy]], { tone: 'azure' });
  d.arrow([[g07.l, g07.cy], [g08.r, g08.cy]], { tone: 'azure' });
  void g10;

  // state 저장소 띠
  const bandY = 432;
  d.box(24, bandY, 912, 58, {
    tone: 'neutral',
    title: 'Azure Blob 컨테이너 tfstate (02-bootstrap 이 생성)',
    lines: ['모든 스택의 state 저장 · Entra ID 인증(계정 키 차단) · 버전 관리 · blob lease 로 잠금   ≈   S3 버킷 + DynamoDB 락 테이블'],
    pad: 12,
    size: 12,
  });

  // 삭제 순서 안내
  d.arrow([[916, 512], [44, 512]], { tone: 'danger', dashed: true });
  d.text(480, 507, 'destroy(삭제)는 역순: 10 → 08 → 07 → 06 → 05 → 04 → 03 → 02   (Lab 11 · scripts/cleanup.sh)', { size: 12, bold: true, tone: 'danger', anchor: 'middle' });
  return d;
}

export const diagrams = [
  { name: 'overview-architecture', build: overviewArchitecture },
  { name: 'stack-layers', build: stackLayers },
];
