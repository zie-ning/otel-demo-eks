# Phase 4. SLO와 기준선 알림

> 상태: 🚧 진행 중 (2026-10-31 시작) · 요약: [PLAN.md](../PLAN.md#phase-4-slo와-기준선-알림) · 브랜치 `feat/phase4-slo-alerts`

## 목표
- 장애 시나리오(Phase 5)를 정하기 **전에** 사용자 영향(증상) 기준의 최소 알림을 둔다.
- 기준선 알림 목록과 조건을 문서로 고정해 Phase 5에서 바뀐 점을 비교할 수 있게 한다.

---

## 결정과 근거

| 항목 | 결정 | 근거 |
|---|---|---|
| 알림 채널 | **Slack** (Alertmanager `slack_configs`, Incoming Webhook) | Alertmanager가 기본 지원하고 실무에서 가장 흔하다. 웹훅 URL은 비밀값이라 Secret으로 넣고 Git에 남기지 않는다 (2026-10-31) |
| 채널 분리 기준 | **긴급도**: `#alerts-critical` / `#alerts-warning`. SLO 알림인지 기본 규칙인지는 채널이 아니라 라벨 `alert_type`으로 구분 | 실무는 담당 팀·긴급도로 나눈다. 1인 프로젝트라 담당 구분은 의미가 없어 긴급도만 쓴다. 처음에는 "SLO용 / 인프라용"으로 나누려 했지만 알림을 만든 방식에 따른 구분이라 바꿨다 |
| kps 기본 규칙 | **Slack으로 보낸다** (critical·warning). `Watchdog`·`InfoInhibitor`는 보내지 않음 | 노드 장애·크래시 루프처럼 SLO보다 먼저 드러나는 문제를 다룬다. 처음에는 기준선을 흐린다는 이유로 보내지 않으려 했으나, 같은 채널에서 SLO 알림과 도착 시각을 비교하는 것이 Phase 5 근거가 되어 바꿨다 |

---

## 시작 시점 현황 (저장소 기준, 클러스터 미기동 상태에서 확인)
- `PrometheusRule`: `ruleSelectorNilUsesHelmValues: false`로 차트 밖에서 만든 규칙도 읽는다 (Phase 3 ③에서 미리 설정)
- Grafana 관리 알림은 contact point `kps-alertmanager`로 Alertmanager에 모인다. Alertmanager에서 밖으로 나가는 수신처는 없다
- 발생 중인 알림은 `Watchdog`뿐 (Phase 3 ③ 확인)
- SLI 후보 지표(**추정**, 클러스터에서 이름·라벨 확인 필요)
  - Collector span metrics: `traces_span_metrics_calls_total`(`status_code`), `traces_span_metrics_duration_milliseconds_bucket`. 1분 주기라 rate 구간은 `[5m]` 이상
  - 앱 SDK: `http_server_request_duration_seconds_*`
- ~~데모 알림 `CartAddItemHighLatency`는 임계값이 `0.0001`초라 거의 항상 발생할 것으로 **추정**~~ → **정정**: 클러스터를 띄운 뒤(2026-10-31) Alertmanager에 들어온 알림은 `Watchdog`뿐이었다. 이 알림은 발생하지 않고 있다. 임계값이 사실상 0인데도 발생하지 않는 이유는 아직 확인하지 않았다(규칙 상태 확인 필요). 발생하면 `severity: warning`이라 `#alerts-warning`으로 간다

## 작업 범위

| # | 작업 | 바꿀 곳 | 상태 |
|---|---|---|---|
| ⓪ | 선행 정리: monitoring 노드 메모리 limits 합 94% 조정, kps·Collector 인프라 지표 중복 중 알림에 쓸 쪽 결정 | `helm/values/` | 예정 (별도 `chore/` 브랜치 검토) |
| ① | SLO 2~3개 정의 (예: 결제 성공률, frontend p95 지연). 특정 장애 원인에 맞춘 조건은 넣지 않는다 | 이 문서 | 예정 |
| ② | burn-rate `PrometheusRule` (다중 구간) | `observability/alerts/`, `scripts/deploy-observability.ps1` | 예정 |
| ③ | Alertmanager → Slack. 웹훅 URL은 Secret | kps values, 스크립트 | ✅ 두 채널 FIRING·RESOLVED 도착 확인 |
| ④ | SLO 대시보드 (에러 버짓 잔량, burn rate). 서비스별 RED는 데모 대시보드 활용 | `helm/grafana/dashboards/` | 예정 |
| ⑤ | 검증: 의도적 에러 → Slack 도착, 기준선 알림 목록·조건 고정. Phase 5 시나리오(`paymentFailure` 등)와 겹치지 않는 방법으로 에러를 낸다 | 이 문서, PLAN | 예정 |

## ③ Alertmanager → Slack

**설정** (`helm/values/kube-prometheus-stack.yaml`의 `alertmanager.config`)

| 경로 | 조건 | 수신처 |
|---|---|---|
| 1 | `alertname =~ "Watchdog\|InfoInhibitor"` | 보내지 않음 (`null`) |
| 2 | `severity = "critical"` | `#alerts-critical` |
| 3 | `severity = "warning"` | `#alerts-warning` |
| 그 밖 | severity가 `info`이거나 없음 | 보내지 않음 (기본 수신처 `null`) |

- `group_by: [alertname, namespace]`: 차트 기본 `[namespace]`는 namespace 라벨이 없는 SLO 알림을 모두 한 메시지로 묶는다
- 차트 기본 `inhibit_rules`를 그대로 쓴다. 같은 `alertname`·`namespace`의 critical이 울리면 warning은 보내지 않으므로, SLO 빠른·느린 소진 알림은 같은 `alertname`에 severity만 다르게 둔다(②)
- `group_wait: 30s`(차트 기본)만큼 첫 알림 전송이 늦다. Phase 5의 탐지 시간에 포함된다
- 메시지: 제목 `[FIRING:N] <alertname>`, 본문에 severity·`alert_type`·namespace·summary·description·runbook 링크·시작 시각. 해제 알림도 보낸다(`send_resolved`)
- 웹훅 URL: 로컬 파일 → Secret `alertmanager-slack` → `api_url_file` ([operations.md](../operations.md#알림-채널-slack))

**검증 (배포 전)**
- `helm template`으로 렌더링한 설정을 실행 중인 Alertmanager의 `amtool check-config`로 검사: SUCCESS (경로 3, 수신처 3, inhibit 규칙 4). 한글 템플릿이 깨지지 않은 것도 확인
- 배포 전 Alertmanager에 들어온 알림: `Watchdog` 1개 (배포하면 Slack으로 가는 알림 없음)

**검증 (배포 후, 2026-10-31)** — `deploy-observability.ps1` 재배포. Secret `alertmanager-slack` 생성, 마운트된 두 파일이 웹훅 형식인지 확인(값은 출력하지 않음).
`amtool alert add`로 테스트 알림 2개(`alert_type=test`)를 보내고 08:50:01 UTC에 해제했다. Slack 도착은 Slack 커넥터로 채널을 읽어 확인했다.

| 알림 | 시작 (UTC) | FIRING 도착 (KST) | RESOLVED 도착 (KST) | 채널 |
|---|---|---|---|---|
| `SlackRoutingTestCritical` (critical) | 08:49:14 | 17:49:44 (+30초) | 17:54:44 | `#alerts-critical`만 |
| `SlackRoutingTestWarning` (warning) | 08:49:15 | 17:49:46 (+31초) | 17:54:46 | `#alerts-warning`만 |

- FIRING은 `group_wait` 30초 뒤, RESOLVED는 첫 전송 후 `group_interval` 5분 뒤에 왔다. **해제 알림은 해제 후 최대 5분 늦게 온다**(Phase 5에서 복구 시각은 Slack이 아니라 Alertmanager·Prometheus 기준으로 적는다)
- 두 알림 이름을 다르게 했다. 같은 이름이면 inhibit 규칙(같은 alertname의 critical이 warning을 억제) 때문에 warning이 오지 않는다
- 한글 summary·description·시작 시각이 깨지지 않았다
- RESOLVED 메시지에는 summary·description이 비어 있었다. 해제할 때 `amtool`로 주석 없이 다시 보내 주석이 덮어써졌기 때문이다(테스트 방식의 영향. Prometheus 규칙은 해제 때도 주석을 유지한다). 주석이 비면 빈 줄이 남는 템플릿 모양은 ② 이후 실제 알림을 보고 다듬는다

## 완료 기준
- [ ] 의도적으로 에러를 내면 알림이 실제로 Slack에 도착
- [ ] 기준선 알림 목록과 조건을 이 문서에 고정

## 남은 일
- `CartAddItemHighLatency`가 발생하지 않는 이유 확인
