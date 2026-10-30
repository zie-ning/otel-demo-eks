# OpenTelemetry Demo on AWS EKS — 프로젝트 계획

> 작성일: 2026-10-29 · 진행 상황 갱신: 2026-10-30 (Phase 2 완료)
> 목적: 포트폴리오용. OpenTelemetry Demo를 AWS EKS에 배포하고, 오픈소스 관측 스택으로 모니터링·알림을 구성한 뒤 장애 주입 시나리오를 수행해 **탐지 → 분석 → 원인 규명 → 재발 방지** 과정을 문서로 남긴다.

---

## 1. 확정된 결정 사항

| 항목 | 결정 | 근거 |
|---|---|---|
| 플랫폼 | **AWS EKS** | 클라우드 환경 실무에서 가장 일반적인 관리형 쿠버네티스. 컨트롤 플레인 운영 대신 관측성·장애 분석에 집중 |
| 리전 | **ap-northeast-2 (서울)** | |
| 노드 | **온디맨드**, 필요할 때만 생성 후 삭제 | Spot 회수로 인한 실험 방해 방지. 비용은 운영 시간으로 통제 |
| 노드 구성 | **m7i-flex.large × 3** = app 노드그룹 2대 + monitoring 노드그룹 1대(taint) | 계정이 AWS 무료 플랜이라 프리티어 대상 타입만 가능. 관측 스택을 앱과 분리해 앱 장애가 관측 도구로 번지지 않게 함 |
| 운영 방식 | Terraform `apply` / `destroy`로 켜고 끔 | 상시 운영 대비 비용 대폭 절감 |
| 네트워크 | **NAT Gateway 없이 퍼블릭 서브넷**에 노드 배치 | NAT 비용 제거. 보안 그룹과 접근 CIDR 제한으로 보완 (트레이드오프는 문서화) |
| 인프라 IaC | **Terraform** (클러스터 / 애드온 단계 분리 적용) | 같은 apply에서 클러스터 생성과 Helm 설치를 함께 할 때의 provider 초기화 문제 회피 |
| 애드온 설치 | Terraform Helm provider (AWS Load Balancer Controller 등) | 실무 관행: Terraform = 인프라 + 기본 애드온 |
| 앱 배포 | **Helm 직접 배포** (`helm upgrade --install` + values 파일 Git 관리) | 잦은 재생성에 단순한 방식이 유리. 이후 Argo CD 전환은 선택 과제 |
| 관측성 | **오픈소스 보강 (LGTM 계열)** — 아래 2장 참고 | 데모 기본 구성의 한계(인프라 메트릭·알림·SLO 부재, Jaeger 메모리 저장) 해소 |
| 외부 접속 | **ALB 기본 주소(HTTP)**, 인바운드는 **본인 IP만 허용** | 도메인 비용 없음. frontend-proxy 아래 Grafana·flagd UI가 함께 노출되므로 접근 제한 필수 |

---

## 2. 아키텍처

### 2.1 관측 스택 구성 (차트 기본 → 변경 후)

| 신호 | 차트 기본 | 변경 후 |
|---|---|---|
| 메트릭 | Prometheus (차트 내장) | **kube-prometheus-stack**의 Prometheus (OTLP 수신 활성화) + Alertmanager + node-exporter + kube-state-metrics |
| 트레이스 | Jaeger (all-in-one, 메모리 저장) | **Tempo** |
| 로그 | OpenSearch | **Loki** |
| 대시보드 | Grafana (차트 내장) | **kube-prometheus-stack**의 Grafana (데모 대시보드는 ConfigMap sidecar로 이전) |
| 수집 | OTel Collector | 유지. exporter 대상만 변경 |

중복 컴포넌트(차트 내장 Prometheus·Grafana·Jaeger·OpenSearch)는 비활성화해서 노드 자원을 아낀다.

### 2.2 데이터 흐름

```
                         ┌──────────────── EKS (ap-northeast-2, 퍼블릭 서브넷) ────────────────┐
 [본인 IP] ──HTTP──▶ ALB ──▶ frontend-proxy(Envoy) ──▶ frontend / 각 마이크로서비스          │
                         │                                   │ OTLP                           │
                         │                                   ▼                                │
                         │                          OTel Collector                            │
                         │                 ┌───────────┼────────────┐                         │
                         │            메트릭│      트레이스│        로그│                         │
                         │                 ▼           ▼            ▼                         │
                         │   Prometheus(kps)        Tempo         Loki                        │
                         │        │  + Alertmanager ──▶ 알림 채널                             │
                         │        └──────────┬──────────┘                                     │
                         │                Grafana  (메트릭 → 트레이스 → 로그 상호 이동)       │
                         └─────────────────────────────────────────────────────────────────────┘
```

핵심 시연 흐름: **에러율/지연 그래프의 exemplar → Tempo 트레이스 → 해당 요청의 Loki 로그**

### 2.3 OpenTelemetry Demo 서비스 구성 (참고)

| 구분 | 구성 요소 |
|---|---|
| 업무 서비스 | frontend(Next.js), cart(.NET + Valkey), checkout(Go), payment(Node), product-catalog(Go), recommendation(Python), shipping(Rust), currency(C++), quote(PHP), email(Ruby), ad(Java), accounting(.NET), fraud-detection(Kotlin) |
| 인프라 성격 | frontend-proxy(Envoy), Kafka, PostgreSQL, flagd(장애 플래그), load-generator(Locust) |

> 정확한 서비스·플래그 목록은 배포하는 차트 버전 기준으로 재확인한다.

---

## 3. 보안 설계 (퍼블릭 서브넷 보완)

- **ALB 인바운드**: `alb.ingress.kubernetes.io/inbound-cidrs`를 배포 스크립트(`scripts/deploy-demo.ps1`)가 실행 시점의 본인 IP로 주입 (커밋하지 않는 로컬 values 파일). 시연 시에만 일시 확대.
- **EKS API 엔드포인트**: public access CIDR을 본인 IP로 제한 (`scripts/up.ps1`이 실행할 때마다 현재 IP로 갱신). 노드는 프라이빗 엔드포인트로 접속.
- **노드 보안 그룹**: SSH 미개방, 외부 인바운드는 ALB에서 오는 트래픽만 허용.
- **Grafana**: 기본 admin 비밀번호 변경 (Kubernetes Secret으로 관리, Git에 커밋 금지).
- **IAM**: Load Balancer Controller 등 애드온은 IRSA 또는 EKS Pod Identity로 최소 권한 부여.

---

## 4. 비용 계획

시간당 대략치 (서울, 온디맨드, NAT 없음 — 실제 단가는 구축 시 AWS 가격표로 재확인):

| 항목 | 시간당 |
|---|---|
| EKS 컨트롤 플레인 | $0.10 |
| 워커 노드 m7i-flex.large × 3 ($0.118/시간) | 약 $0.35 |
| ALB | 약 $0.02 + LCU |
| 퍼블릭 IPv4 (노드·ALB) | IP당 $0.005 |
| **합계** | **약 $0.50** |

- 월 60시간 사용 시 약 $30, 80시간 시 약 $40.
- 삭제 후에도 남는 비용: Terraform state용 S3 (거의 무료).

**비용 사고 방지**
1. AWS Budgets 월 $40, 알림 $20(50%) / $40(100%) / 예상 초과
2. 한 줄로 전체 삭제하는 스크립트 (`scripts/down.ps1`)
3. 작업 종료 시 삭제 확인 체크리스트

---

## 5. 진행 단계

### Phase 0. 사전 준비 ✅ (2026-10-29)
- [x] AWS 계정 / IAM 사용자 준비: `terraform-admin` 프로필 (IAM 사용자 `terraform_admin`). MFA 설정 여부는 미확인
- [x] 로컬 도구 설치: AWS CLI 2.30, Terraform 1.15, kubectl 1.37(PowerShell 별칭), Helm 4.3
- [x] AWS Budgets 알림 설정: 월 $40, 크레딧 차감 전 금액 기준 (`terraform/00-bootstrap`)
- [x] Terraform state 백엔드(S3) 생성: `otel-demo-tfstate-520426835144`, 버전 관리·암호화·퍼블릭 차단
- [x] GitHub 저장소 생성: [zie-ning/otel-demo-eks](https://github.com/zie-ning/otel-demo-eks) (공개)

### Phase 1. 인프라 (Terraform) ✅ (2026-10-29)
- [x] VPC: 퍼블릭 서브넷 2개 AZ(2a, 2c), NAT 없음
- [x] EKS 1.37 클러스터 + 매니지드 노드그룹 (온디맨드): app × 2, monitoring × 1(taint)
  - 무료 플랜이라 t3.xlarge가 거부되어 m7i-flex.large로 변경 ([operations.md](operations.md) 문제 해결 참고)
- [x] API 엔드포인트 접근 CIDR 제한 + 프라이빗 엔드포인트
- [x] 애드온 단계(별도 apply): AWS Load Balancer Controller(Pod Identity), metrics-server
  - EBS CSI Driver는 제외: 영구 볼륨 없이 운영하고 클러스터 삭제 시 데이터도 함께 사라지는 방식이라 불필요. 필요해지면 추가
- [x] up/down 스크립트, 운영 지침([operations.md](operations.md))
- **완료 기준**: `kubectl get nodes` 정상 ✅, `down.ps1`로 깨끗하게 삭제되는 것까지 확인 ✅ (2026-10-30, 02-addons 6개 + 01-cluster 50개 삭제, EKS·EC2·ALB·VPC·EBS·ENI 잔여 없음. 첫 실행에서 스크립트 버그 2건 수정 후 재실행)

### Phase 2. 데모 배포 (Helm, 기본 구성) ✅ (2026-10-29)
- [x] opentelemetry-demo 차트 0.42.6(앱 3.1.0)을 **기본 관측 스택 그대로** 배포해 정상 동작 확인
  - 데모 서비스는 app 노드, Jaeger·Prometheus·Grafana·OpenSearch는 monitoring 노드, Collector는 DaemonSet으로 전 노드
- [x] Ingress(ALB, target-type ip) + 본인 IP 제한 (`scripts/deploy-demo.ps1`)
- [x] 트레이스 관찰 1단계: quote·shipping 직접 호출 트레이스 분석, 관측 데이터 품질 문제 발견 ([observability-findings.md](observability-findings.md))
- [x] 트레이스 관찰 2단계 (2026-10-30): 화면 동작(홈, 상품 클릭, 장바구니 담기, 주문)별 트레이스 관찰. 통화 변경은 생략
  - 브라우저 트레이스가 수집되지 않던 문제(OBS-4)를 발견해 수정: `PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`를 상대 경로로 변경
  - 주문 1건 = checkout 트레이스(스팬 58개) + Kafka 뒤 별도 트레이스 2개(accounting, fraud-detection, `FOLLOWS_FROM` 링크)
  - 발견한 패턴: 서비스 간 호출에서 처리보다 연결·대기 비용이 큼(`dns.lookup`/`tcp.connect`는 첫 연결 때만), 추천의 N+1 호출, checkout 내부 미계측 구간 약 70ms, payment·cart의 원격 flagd 질의 비용, 브라우저-서버 시계 차이 약 0.88초
  - 추가 품질 문제: OBS-5(accounting 소비 스팬이 대기 시간 포함), OBS-2 대상에 accounting 추가
- **완료 기준**: ALB 주소로 쇼핑몰 접속 ✅, load-generator 트래픽 흐름 ✅, Jaeger에서 트레이스 확인 ✅ (서비스 21개, 주문 트레이스 확인)
- Phase 3에서 이어서 볼 것: 장애 시나리오와 비교할 **정상 주문 트레이스** `54e11879d961993975e9bdfbbca50178` (클러스터 삭제 시 사라지므로 화면 캡처로 보관)

### Phase 3. 관측 스택 전환 (한 단계씩 바꾸고 매번 검증)
- [ ] ① kube-prometheus-stack 설치, OTLP 수신 활성화 → Collector 메트릭 대상 변경 → 차트 내장 Prometheus 비활성화
- [ ] ② Grafana 일원화: 데모 대시보드 ConfigMap 이전 → 차트 내장 Grafana 비활성화
- [ ] ③ Tempo 도입 → 차트 내장 Jaeger 비활성화
- [ ] ④ Loki 도입 → 차트 내장 OpenSearch 비활성화
- [ ] ⑤ Grafana 데이터소스 연결: exemplar → 트레이스, 트레이스 → 로그
- [ ] ⑥ 관측 데이터 품질 문제 수정 ([observability-findings.md](observability-findings.md)의 OBS-1~3, OBS-5는 기록만)
- [ ] ⑦ ALB 헬스체크(`ELB-HealthChecker`) 트레이스를 Collector에서 걸러내기 (15초마다 2건씩 쌓이는 잡음)
- **완료 기준**: Grafana 하나에서 메트릭 → 트레이스 → 로그로 이동 가능

### Phase 4. SLO와 알림
- [ ] SLO 정의 (예: checkout 성공률, frontend p95 지연)
- [ ] PrometheusRule로 burn-rate 알림 작성
- [ ] Alertmanager → 알림 채널 연결
- [ ] 서비스별 RED 대시보드, SLO 대시보드
- **완료 기준**: 의도적으로 에러를 내면 알림이 실제로 도착

### Phase 5. 장애 주입 시나리오
| # | 시나리오 | 주입 방법 | 보여줄 포인트 |
|---|---|---|---|
| 1 | 결제 실패율 증가 | flagd `paymentFailure` | SLO 알림 → 트레이스로 원인 서비스 특정 |
| 2 | 메모리 누수 | flagd `emailMemoryLeak` | 메모리 추세 탐지 → OOMKill·재시작과 연관 |
| 3 | Kafka 지연 | flagd `kafkaQueueProblems` | 비동기 구간 consumer lag 관측 |
| 4 | 파드 강제 종료 / 네트워크 지연 | Chaos Mesh (도입 여부 미정) | 인프라 레벨 장애와 복원력 |
| 5 | 트래픽 폭주 | load-generator 사용자 수 증가 | 지연 증가와 자원 포화 |

- 각 시나리오마다 포스트모템 작성: **탐지 → 분석 → 원인 → 조치 → 재발 방지**
- 클러스터 삭제 시 데이터가 사라지므로 **증거(스크린샷, 대시보드 export, 트레이스 ID)는 실험 직후 저장**

### Phase 6. 문서화
- [ ] README: 아키텍처 다이어그램, 구축 방법, 의사결정 기록
- [ ] 시나리오별 포스트모템
- [ ] 시연 영상 또는 GIF
- [ ] 트레이드오프 기록 (NAT 제거, 온디맨드 선택, 관측 스택 일원화 등)

---

## 6. 아직 정하지 않은 사항

| 항목 | 후보 | 결정 시점 |
|---|---|---|
| 알림 채널 | Slack / Discord / 이메일 | Phase 4 |
| 장애 주입 도구 | flagd만 / Chaos Mesh 추가 | Phase 5 |
| 노드 크기·대수 | m7i-flex.large × 3에서 실측 후 조정 | Phase 3 |
| GitOps(Argo CD) 전환 | 선택 과제 | Phase 6 이후 |

정해진 사항: Terraform state는 **S3** (Phase 0), 저장소는 **GitHub 공개** (Phase 0)

### 저장소 구조 (✅ 생성됨 / 예정)
```
.
├── terraform/
│   ├── 00-bootstrap/      # ✅ state 버킷, 예산 알림 (영구)
│   ├── 01-cluster/        # ✅ VPC, EKS, 노드그룹
│   └── 02-addons/         # ✅ Load Balancer Controller, metrics-server
├── helm/values/           # ✅ otel-demo / 예정: kube-prometheus-stack, tempo, loki
├── observability/         # 예정
│   ├── dashboards/        #   Grafana 대시보드 (ConfigMap)
│   └── alerts/            #   PrometheusRule (SLO, burn-rate)
├── scenarios/             # 예정: 시나리오별 실행 절차와 포스트모템
├── scripts/               # ✅ up / deploy-demo / down
└── docs/                  # ✅ PLAN, operations, observability-findings
```

---

## 7. 리스크와 대응

| 리스크 | 대응 |
|---|---|
| 클러스터를 끄지 않아 비용 폭증 | Budgets 알림, down 스크립트, 종료 체크리스트 |
| 퍼블릭 서브넷 노출 | 보안 그룹·CIDR 제한, SSH 미개방 |
| 관측 스택 전환 중 데이터 끊김 | Phase 3을 한 단계씩 진행하고 매번 검증 |
| 노드 메모리 부족 | 리소스 사용량 실측 후 노드 크기 조정, 불필요 컴포넌트 비활성화 |
| 차트 버전 변경으로 설정 키 상이 | 차트 버전 고정, 업그레이드 시 변경 이력 확인 |
| 실험 증거 유실 | 실험 직후 스크린샷·export 저장 |
