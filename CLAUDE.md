# 저장소 규칙

OpenTelemetry Demo를 AWS EKS에 배포하고 관측 스택 구성, 장애 주입, 포스트모템까지 기록하는 **포트폴리오 프로젝트**다.
계획과 진행 상황은 [docs/PLAN.md](docs/PLAN.md), 운영 절차는 [docs/operations.md](docs/operations.md)가 기준이다.

## 1. 언어
- 응답, 문서, 코드 주석, 커밋 메시지: **한국어**
- 변수명, 함수명, 파일명, 리소스 이름: 영어

## 2. 저장소 구조
| 경로 | 내용 |
|---|---|
| `terraform/00-bootstrap` | state 버킷, 예산 알림. **로컬 state, 영구 유지. 절대 destroy 금지** |
| `terraform/01-cluster` | VPC, EKS, 노드그룹(app 2 / monitoring 1, taint). S3 backend |
| `terraform/02-addons` | AWS Load Balancer Controller, metrics-server. S3 backend |
| `helm/values/` | Helm values. 차트 버전은 배포 스크립트에 고정 |
| `scripts/` | `up.ps1`, `deploy-demo.ps1`, `down.ps1`, 공통 함수 `common.ps1` |
| `docs/` | `PLAN.md`(계획·진행), `operations.md`(운영·문제 해결), `observability-findings.md`(관측 데이터 품질 문제) |

## 3. 비용과 클러스터 수명
- 클러스터는 **작업할 때만** 띄운다. 켜져 있으면 시간당 약 $0.50이 나간다.
- 작업을 마칠 때는 `.\scripts\down.ps1`로 삭제하고, EKS·EC2·ALB·VPC가 남지 않았는지 확인한다.
- 계정은 AWS **무료 플랜**이라 프리티어 대상 인스턴스만 실행된다(현재 m7i-flex.large).
- 클러스터를 다시 만들면 ALB 주소가 바뀐다. 문서나 안내에 이전 주소를 쓰지 않는다.

## 4. 변경 작업 원칙
- **AWS 리소스를 만들거나 바꾸는 작업은 사용자 승인 후에만** 실행한다. Terraform은 `plan` 결과(생성/변경/삭제 수, 주요 리소스)를 먼저 보여주고, 승인받은 plan 파일로 `apply`한다.
- AWS CLI와 Terraform은 항상 `terraform-admin` 프로필을 쓴다.
- AWS 콘솔에서 Terraform 리소스를 직접 수정하지 않는다. 코드로 바꾼다.
- 버전은 고정한다(EKS, 모듈, provider, Helm 차트). 업그레이드는 하나씩, `plan`으로 영향 범위를 확인한 뒤 한다.
- 오래 걸리는 작업(클러스터 생성·삭제, `helm --wait`)은 백그라운드로 실행하고 완료 후 결과를 확인한다.

## 5. 커밋 금지 파일
- `*.tfstate`, `*.tfvars`(이메일, IP 포함), `*.tfplan`, `*.local.yaml`(ALB 허용 IP), kubeconfig, `.env`
- 예시 파일(`*.tfvars.example`)과 `.terraform.lock.hcl`은 커밋한다.
- 커밋 전 `git diff --cached --name-only`로 위 파일이 섞이지 않았는지 확인한다.

## 6. Windows PowerShell 5.1 주의사항
이 저장소의 스크립트는 Windows PowerShell 5.1에서 실행된다. 실제로 겪은 문제들이다.
- **스크립트 인코딩**: 한글이 들어간 `.ps1`은 **UTF-8 BOM**으로 저장한다. BOM이 없으면 한글이 깨진다.
- **네이티브 명령의 stderr**: helm/kubectl의 정보성 로그도 오류로 처리된다. 네이티브 명령은 `common.ps1`의 `Invoke-Native`로 실행하고, 성공 여부는 종료 코드로 판단한다.
- **배열 splat**: `$x = if (...) { @('a') }`처럼 받으면 요소 1개짜리 배열이 문자열로 풀려 `@x`가 글자 단위로 쪼개진다. `$x = @(if (...) { 'a' })`로 쓴다.
- **따옴표가 든 인자**: 큰따옴표가 포함된 jsonpath나 공백이 섞인 JSON 인자는 깨진다. `-o json` 후 PowerShell에서 거르거나, 본문은 base64로 넘긴다.
- **kubectl**: 시스템 PATH의 Docker Desktop kubectl(구버전)이 먼저 잡힌다. 스크립트에서는 `common.ps1`의 `$Kubectl`(winget 설치본)을 쓴다.
- **Helm·kubectl을 못 찾을 때**: 셸의 PATH가 갱신되지 않은 경우다. Machine + User PATH를 다시 읽어 실행한다.

## 7. 데모 배포 관련
- 데모는 `.\scripts\deploy-demo.ps1`로만 설치·업그레이드한다(차트 0.42.6 고정, ALB 허용 IP 자동 주입).
- `helm upgrade`를 하면 **load-generator가 차트 기본값(1개)으로 되살아난다.** 트레이스 관찰처럼 트래픽을 멈춰야 하는 작업 중이면 업그레이드 후 다시 0으로 줄인다.
- 데모 서비스는 app 노드, 관측 도구는 monitoring 노드(taint `dedicated=monitoring:NoSchedule`)에 배치한다. 새 관측 컴포넌트를 추가할 때는 toleration과 `nodeSelector: role=monitoring`을 함께 준다. DaemonSet은 toleration만 준다.
- 접근 허용 IP는 실행 시점의 공인 IP로 갱신된다. 공인 IP가 바뀌면 `up.ps1`(API 엔드포인트)과 `deploy-demo.ps1`(ALB)을 다시 실행한다.

## 8. 관측 데이터 분석 원칙
- 트레이스는 Jaeger UI 외에 Jaeger HTTP API(`/jaeger/ui/api/traces/...`)로 조회해 근거를 확인한다.
- 해석할 때 **확인한 사실과 추정을 구분**해서 말한다. 추정했다가 데이터로 틀린 것이 확인되면 바로잡는다고 명시한다.
- 스팬 막대 길이(소요 시간)만 보지 말고 **이벤트(Logs)와 속성**까지 본다.
- 브라우저(`frontend-web`) 스팬과 서버 스팬은 시계가 다르다(사용자 PC가 약 0.88초 빠름). 둘 사이는 시작 시각이 아니라 **소요 시간 차이**로만 비교한다.
- Jaeger Search의 서비스 필터는 루트 서비스가 아니라 **그 서비스의 스팬이 포함된 트레이스**를 모두 보여준다.

## 9. 문서 갱신 규칙
- 관측 데이터 품질 문제를 발견하면 `docs/observability-findings.md`에 **OBS-번호**로 증상(실제 수치와 트레이스 ID), 원인(확인/추정 구분), 영향, 해결 방향, 상태를 기록한다.
- 인프라·스크립트 문제와 해결은 `docs/operations.md`의 문제 해결에 기록한다.
- 단계를 마치면 `docs/PLAN.md`의 체크리스트와 완료 기준, `README.md`의 진행 상황을 갱신한다.
- 장애 시나리오(Phase 5)는 포스트모템 형식(탐지 → 분석 → 원인 → 조치 → 재발 방지)으로 남기고, 증거(스크린샷, 트레이스 ID, 대시보드 export)는 클러스터 삭제 전에 저장한다.

## 10. 커밋
- 사용자가 요청할 때만 커밋·push한다.
- 메시지는 한국어로, 첫 줄은 무엇을 했는지 요약하고 본문에 변경 파일별 내용을 적는다.
