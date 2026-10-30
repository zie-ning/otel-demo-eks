# OpenTelemetry Demo on AWS EKS

[OpenTelemetry Demo](https://github.com/open-telemetry/opentelemetry-demo)를 AWS EKS에 배포하고, 오픈소스 관측 스택(Prometheus·Grafana·Tempo·Loki)으로 모니터링과 알림을 구성한 뒤, 장애 주입 시나리오로 **탐지 → 분석 → 원인 규명 → 재발 방지** 과정을 기록하는 프로젝트입니다.

> 진행 중인 프로젝트입니다. 전체 계획과 의사결정 근거는 [docs/PLAN.md](docs/PLAN.md), 클러스터 운영 절차는 [docs/operations.md](docs/operations.md)를 참고하세요.

## 기술 스택

| 영역 | 사용 기술 |
|---|---|
| 인프라 | AWS EKS (ap-northeast-2), Terraform |
| 배포 | Helm |
| 관측성 | OpenTelemetry Collector, Prometheus (kube-prometheus-stack), Grafana, Tempo, Loki, Alertmanager |
| 장애 주입 | flagd feature flag, (검토 중) Chaos Mesh |

## 저장소 구조

```
.
├── CLAUDE.md               # 저장소 작업 규칙
├── docs/
│   ├── PLAN.md             # 프로젝트 계획, 의사결정 기록, 진행 상황
│   ├── operations.md       # 인프라 운영 지침 (켜고 끄기, 규칙, 비용, 문제 해결)
│   └── observability-findings.md  # 텔레메트리 데이터 품질 문제 기록
├── helm/values/
│   └── otel-demo.yaml      # 데모 차트 values (노드 배치, ALB Ingress)
├── scripts/
│   ├── up.ps1              # 클러스터 + 애드온 생성
│   ├── deploy-demo.ps1     # OpenTelemetry Demo 설치/업그레이드
│   ├── check-resource-attributes.ps1  # 서비스별 리소스 속성 품질 집계 (Jaeger API)
│   └── down.ps1            # ALB 정리 후 전체 삭제
└── terraform/
    ├── 00-bootstrap/       # Terraform state용 S3 버킷, AWS Budgets 알림 (영구)
    ├── 01-cluster/         # VPC(퍼블릭 서브넷, NAT 없음), EKS, 노드그룹
    └── 02-addons/          # AWS Load Balancer Controller, metrics-server
```

## 진행 상황

- [x] Phase 0. 사전 준비 (도구, 자격 증명, state 버킷, 예산 알림)
- [x] Phase 1. 인프라 (VPC, EKS, 노드그룹 app/monitoring, LB Controller, metrics-server)
- [x] Phase 2. 데모 배포 (Helm, ALB 외부 접속, 화면 동작별 트레이스 관찰, 관측 데이터 품질 문제 OBS-1~5 기록)
- [ ] Phase 3. 관측 스택 전환
- [ ] Phase 4. SLO와 알림
- [ ] Phase 5. 장애 주입 시나리오
- [ ] Phase 6. 문서화

## 부트스트랩 사용법

```bash
cd terraform/00-bootstrap
cp terraform.tfvars.example terraform.tfvars   # 알림 이메일 입력
terraform init
terraform apply
```

state 버킷은 클러스터와 별개로 유지되며 `prevent_destroy`로 보호됩니다.
