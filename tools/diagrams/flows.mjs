// 인증 흐름과 트래픽 흐름 다이어그램
import { Diagram } from './lib.mjs';

// ---------------------------------------------------------------------------
// 그림: Workload Identity (IRSA 와 비교)
// ---------------------------------------------------------------------------
function workloadIdentityFlow() {
  const d = new Diagram('workload-identity-flow', 960, 652, {
    title: 'Workload Identity 흐름 (IRSA 와 비교)',
    desc: '파드가 ServiceAccount 토큰을 클라우드의 토큰 교환 서비스(AWS STS 또는 Microsoft Entra ID)에 제시하고, 신뢰 설정을 검증받아 임시 자격 증명이나 액세스 토큰을 받은 뒤 대상 서비스(Secrets Manager 또는 Key Vault)를 호출하는 3단계 흐름을 AWS 와 Azure 로 나란히 보여 준다.',
  });
  d.heading('Workload Identity 흐름 (IRSA 와 비교)', '두 방식 모두 "ServiceAccount 토큰 → 클라우드 임시 자격 증명" 교환이며 정적 키가 필요 없습니다.');

  const lane = (y0, tone, label, p, ex, tg, tr, steps) => {
    d.group(24, y0, 912, 236, { tone, label });
    const pod = d.box(36, y0 + 40, 242, 118, { tone: 'neutral', title: p[0], lines: p.slice(1), pad: 12, titleSize: 13.5, size: 11 });
    const exch = d.box(376, y0 + 40, 236, 118, { tone, title: ex[0], lines: ex.slice(1), pad: 12, titleSize: 13.5, size: 11 });
    const tgt = d.box(710, y0 + 40, 214, 118, { tone: 'ok', title: tg[0], lines: tg.slice(1), pad: 12, titleSize: 13.5, size: 11 });
    const trust = d.box(376, y0 + 172, 236, 54, { tone, dashed: true, title: tr[0], lines: tr.slice(1), pad: 10, titleSize: 12, size: 10.5 });
    // ① 제시, ② 반환
    d.arrow([[pod.r, pod.cy - 16], [exch.l, exch.cy - 16]], { tone, label: steps[0], at: 0.5, dy: -17 });
    d.arrow([[exch.l, exch.cy + 18], [pod.r, pod.cy + 18]], { tone, label: steps[1], at: 0.5, dy: 17 });
    // ③ 호출 (교환 서비스 상자 위를 돌아서)
    d.arrow([[pod.cx, pod.t], [pod.cx, y0 + 28], [tgt.cx, y0 + 28], [tgt.cx, tgt.t]], { tone: 'ok', label: steps[2], at: 0.5, dy: 0 });
    d.arrow([[trust.cx, trust.t], [trust.cx, exch.b]], { tone, dashed: true });
  };

  lane(
    88, 'aws', 'AWS · EKS 의 IRSA',
    ['Pod + ServiceAccount', 'SA annotation:', 'eks.amazonaws.com/role-arn', 'SA 토큰 aud:', 'sts.amazonaws.com'],
    ['AWS STS', 'AssumeRoleWithWebIdentity', 'issuer 공개키로 서명 검증', '신뢰 정책(sub) 확인'],
    ['Secrets Manager', 'IAM 정책이 허용해야', 'GetSecretValue 성공'],
    ['IAM Role 신뢰 정책 (OIDC)', 'sub = system:serviceaccount:ns:sa'],
    ['① SA 토큰 제시', '② 임시 자격', '③ 임시 자격으로 API 호출 (정적 키 없음)'],
  );
  lane(
    338, 'azure', 'Azure · AKS 의 Workload Identity',
    ['Pod + ServiceAccount', 'label azure.workload.identity/use', 'annotation …/client-id = UAMI', 'SA 토큰 aud:', 'api://AzureADTokenExchange'],
    ['Microsoft Entra ID', '토큰 엔드포인트', 'issuer 공개키로 서명 검증', 'federated credential 확인'],
    ['Key Vault', 'Azure RBAC 역할', '"Key Vault Secrets User"'],
    ['UAMI + Federated credential', 'issuer = OIDC URL · subject = SA'],
    ['① SA 토큰 제시', '② 액세스 토큰', '③ 액세스 토큰으로 API 호출 (정적 키 없음)'],
  );

  d.box(24, 584, 912, 56, {
    tone: 'neutral', pad: 12, size: 12, muted: false,
    lines: ['Azure: webhook 이 환경 변수(AZURE_CLIENT_ID 등)와 SA 토큰 볼륨을 파드에 주입하고,', '앱은 SDK 의 DefaultAzureCredential 로 자동 인증합니다 (Lab 06).'],
  });
  return d;
}

// ---------------------------------------------------------------------------
// 그림: Gateway API 트래픽 흐름 (Lab 07)
// ---------------------------------------------------------------------------
function ingressFlow() {
  const d = new Diagram('ingress-flow', 960, 560, {
    title: 'Gateway API 트래픽 흐름',
    desc: '클라이언트의 요청이 Azure 로드밸런서와 Envoy 게이트웨이 프록시 파드, Service 를 거쳐 앱 파드에 도달하고, 플랫폼 팀의 Gateway 와 앱 팀의 HTTPRoute 가 관리형 Istio 기반 컨트롤 플레인을 통해 Envoy 를 구성하는 구조.',
  });
  d.heading('Gateway API 트래픽 흐름', '위쪽은 요청이 흐르는 길(데이터 경로), 아래쪽은 그 길을 만드는 리소스(제어 경로)입니다.');

  // 데이터 경로
  d.text(24, 96, '데이터 경로', { size: 12.5, bold: true, muted: true });
  const client = d.box(24, 108, 130, 100, { title: '클라이언트', lines: ['브라우저', 'curl'], pad: 12, titleSize: 13.5, size: 11.5 });
  const lb = d.box(214, 108, 150, 100, { tone: 'net', title: 'Azure LB', lines: ['공인 IP', '(Gateway 가', '자동 생성)'], pad: 12, titleSize: 13.5, size: 11.5 });
  d.group(384, 94, 552, 128, { tone: 'azure', dashed: true, label: '네임스페이스 web', labelSize: 12 });
  const envoy = d.box(394, 112, 150, 92, { tone: 'azure', title: 'Envoy 프록시', lines: ['Gateway 당 자동 생성:', 'Deployment·HPA·PDB'], pad: 10, titleSize: 13, size: 10.5 });
  const svc = d.box(624, 112, 140, 92, { tone: 'azure', title: 'Service', lines: ['aspnetapp:80', 'ClusterIP'], pad: 10, titleSize: 13, size: 11 });
  const pods = d.box(788, 112, 140, 92, { tone: 'azure', title: 'Pod ×3', lines: ['영역 분산', '(best-effort)', ':8080 · 비루트'], pad: 10, titleSize: 13, size: 11 });
  d.arrow([[client.r, client.cy], [lb.l, lb.cy]], { tone: 'azure', label: 'HTTP', at: 0.5, dy: -14 });
  d.arrow([[lb.r, lb.cy], [envoy.l, envoy.cy]], { tone: 'azure' });
  d.arrow([[envoy.r, envoy.cy], [svc.l, svc.cy]], { tone: 'azure', label: 'HTTPRoute', at: 0.5, dy: -17 });
  d.arrow([[svc.r, svc.cy], [pods.l, pods.cy]], { tone: 'azure' });

  // 제어 경로
  d.text(24, 266, '제어 경로 (리소스)', { size: 12.5, bold: true, muted: true });
  const gw = d.box(24, 280, 246, 124, {
    tone: 'id', title: '플랫폼 팀: Gateway', pad: 12, titleSize: 13, size: 11.5,
    lines: ['web-gateway', 'GatewayClass: approuting-istio', '리스너 HTTP 80 · LB 공용/내부 선택'],
  });
  const mgr = d.box(360, 280, 246, 124, {
    tone: 'ok', title: '관리형 컨트롤 플레인', pad: 12, titleSize: 13, size: 11.5,
    lines: ['Istio 기반 구현 (사이드카 없음)', 'Gateway 를 감시하다가', 'Envoy · Service(LB) ·', 'HPA · PDB 를 생성'],
  });
  const app = d.box(640, 280, 296, 124, {
    tone: 'warn', title: '앱 팀: HTTPRoute', pad: 12, titleSize: 13, size: 11.5,
    lines: ['aspnetapp · parentRefs: web-gateway', 'PathPrefix "/" → Service aspnetapp:80', '호스트 · 경로 · 가중치 · TLS 는 여기서'],
  });
  d.arrow([[gw.r, gw.cy], [mgr.l, mgr.cy]], { tone: 'id', label: 'GatewayClass', at: 0.5, dy: -17 });
  d.arrow([[470, mgr.t], [470, 204]], { tone: 'ok', label: '프로비저닝', at: 0.45 });
  d.arrow([[700, app.t], [700, 204]], { tone: 'warn', label: '라우팅 규칙', at: 0.6 });
  d.arrow([[app.cx, app.b], [app.cx, 424], [gw.cx, 424], [gw.cx, gw.b]], { tone: 'warn', label: 'parentRefs 로 Gateway 에 연결', at: 0.5 });

  // 아래: NetworkPolicy, AWS 비교
  d.box(24, 446, 440, 92, {
    tone: 'neutral', title: 'NetworkPolicy (Cilium 이 강제)', pad: 12, titleSize: 13, size: 11.5,
    lines: ['앱 파드는 같은 네임스페이스의 파드에서 오는 8080 만 허용', '다른 네임스페이스에서는 앱에 직접 접근할 수 없습니다'],
  });
  d.box(484, 446, 452, 92, {
    tone: 'aws', title: 'AWS 와 비교', pad: 12, titleSize: 13, size: 11.5,
    lines: ['ALB + AWS Load Balancer Controller ↔ Azure LB + Envoy(Gateway)', 'Ingress(annotation) ↔ Gateway + HTTPRoute (표준 API, 역할 분리)'],
  });
  return d;
}

export const diagrams = [
  { name: 'workload-identity-flow', build: workloadIdentityFlow },
  { name: 'ingress-flow', build: ingressFlow },
];
