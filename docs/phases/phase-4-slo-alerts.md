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
| SLI 대상 요청 | **frontend-proxy가 쇼핑몰 백엔드로 보낸 요청**(`upstream_cluster` 기준). flagd 스트리밍·관측 도구 경로는 뺀다 | 프록시는 모든 사용자 요청의 입구라 frontend가 죽어도 503을 기록한다(frontend 자체 지표는 죽으면 사라짐). 다만 프록시를 지나는 요청에는 사용자가 기다리지 않는 연결(flagd `EventStream`, 3초씩 열림)과 운영 도구가 섞여 있다. "빼야 할 것을 빼는" 방식은 새 경로가 생길 때마다 SLI가 오염되므로 "넣을 것만 넣는" 방식으로 한다 (2026-10-31) |
| span metrics 라벨 추가 | Collector `span_metrics`에 `upstream_cluster`, `http.status_code` dimension 추가 | Envoy 스팬 이름이 `GET`/`POST`뿐이고 Envoy는 SDK HTTP 지표를 내지 않아, 기존 지표로는 백엔드·응답 코드를 구분할 수 없었다. 시리즈가 늘어나는 비용은 배포 후 실측으로 확인 |
| 기준선 알림 구성 | SLO 3개(각각 critical·warning burn rate) + 쇼핑몰 요청률 급감 + Collector 전송 실패·드롭 + kps 기본 규칙. 아래 "기준선 알림" 표 | 원인 기준 알림은 넣지 않는다. 다만 **측정이 유효한지 지키는 알림**(SLI가 사라지거나 일부만 계산되는 상태)은 넣는다. 그래야 Phase 5에서 "못 잡았다"와 "측정이 망가져 있었다"를 구분할 수 있다 (2026-10-31) |
| 지연 임계값 | **400ms** (처음 제안 800ms에서 변경) | 쇼핑몰 요청은 평소 100%가 100ms 이내(p99.9 75ms). 800ms는 10배 느려져도 울리지 않는다. 800ms를 제안한 이유("정적 파일과 섞여 작은 지연에도 버짓을 쓴다")는 실측으로 해당하지 않았다 |
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
| ⓪ | 선행 정리: monitoring 노드 메모리 limits 합 94% 조정, kps·Collector 인프라 지표 중복 중 알림에 쓸 쪽 결정 | `helm/values/`, `helm/grafana/` | 메모리 ✅ requests 조정(limits는 문제 아님). 지표 중복: 조사 완료, **kps 일원화 방안 결정 대기**(⓪-2) |
| ① | SLO 2~3개 정의 (예: 결제 성공률, frontend p95 지연). 특정 장애 원인에 맞춘 조건은 넣지 않는다 | 이 문서, `otel-demo.yaml`(span metrics 라벨) | ✅ SLO 3개와 측정 유효성 알림 2개 확정 |
| ② | burn-rate `PrometheusRule` (다중 구간) | `observability/alerts/`, `scripts/deploy-observability.ps1` | ✅ 적용, 19개 규칙 정상 평가 |
| ③ | Alertmanager → Slack. 웹훅 URL은 Secret | kps values, 스크립트 | ✅ 두 채널 FIRING·RESOLVED 도착 확인 |
| ④ | SLO 대시보드 (에러 버짓 잔량, burn rate). 서비스별 RED는 데모 대시보드 활용 | `helm/grafana/dashboards/` | 예정 |
| ⑤ | 검증: 의도적 에러 → Slack 도착, 기준선 알림 목록·조건 고정. Phase 5 시나리오(`paymentFailure` 등)와 겹치지 않는 방법으로 에러를 낸다 | 이 문서, PLAN | 예정 |

## ⓪ monitoring 노드 메모리 실측 (2026-10-31)

**측정 방법**
- 설정값: `kubectl get pods --field-selector spec.nodeName=<monitoring 노드> -o json`에서 컨테이너별 requests·limits를 더했다. `describe node`의 합계(2242Mi·6736Mi)와 같다
- 실사용: Prometheus `container_memory_working_set_bytes`(cAdvisor, OOM 판단 기준과 같은 working set)의 현재값과 `max_over_time(...[3h:30s])`. 클러스터 생성 후 약 1시간(Prometheus 가동 58분, head 시리즈 167,902개) 시점이라 최대값은 사실상 1시간 최대다

**결과** (Mi, 노드 할당 가능 7106Mi)

| 파드 | requests | 현재 | 최대 | limits | 판단 |
|---|---|---|---|---|---|
| Prometheus | 537 | 542 | 543 | 1600 | requests 초과. 가동 시간이 늘면 더 커질 수 있다 |
| Grafana (본체 + 사이드카 3) | 320 | 503 | 504 | 896 | requests 초과. 본체 271(requests 128), 사이드카 77~79씩(requests 64) |
| Tempo | 512 | 480 | **863** | 2048 | 최대가 requests 초과. 값이 크게 오르내린다(`kubectl top` 직전 측정 277) |
| Loki | 256 | 117 | 130 | 1024 | 여유 |
| OTel Collector | 400 | 89 | 89 | 400 | requests가 실사용의 4.5배 |
| Alertmanager·operator·kube-state-metrics·node-exporter | 217 | 79 | 87 | 768 | 여유 |
| aws-node·kube-proxy·pod-identity-agent | 0 | 87 | 91 | 없음 | requests·limits 없음 |
| **노드 전체** (node-exporter `MemTotal - MemAvailable`) | 2242 | 2481 | 2849 | 6736 | |

- 재시작·OOMKill: 0건
- **limits 합 94%는 문제가 아니다.** 100% 미만이라 모든 컨테이너가 limits까지 써도 할당 가능량 안에 든다(오버커밋 아님). Phase 3에 "동시에 제한까지 차오르면 노드 메모리가 모자란다"고 쓴 것은 정확하지 않았다. 남은 6%와 limits 없는 시스템 파드(현재 91Mi)는 확인해야 할 점이다
- **실제 문제는 requests가 실사용보다 작은 컴포넌트다.** 노드에 메모리 압박이 오면 kubelet은 requests를 많이 넘겨 쓰는 파드부터 내쫓는다. Prometheus·Grafana·Tempo가 여기에 해당한다. Prometheus가 쫓겨나면 SLO 알림 평가도 멈춘다
- 반대로 Collector는 requests 400Mi 중 311Mi를 쓰지 않고 예약만 하고 있다. DaemonSet이라 app 노드에서도 같은 양을 예약한다

**Tempo 메모리 내역** (Tempo 자체 지표, 같은 시점)
- 수신: 스팬 118개/초, 트레이스 22.7개/초. live-store에 있는 트레이스는 293개, **1.7MB**뿐이다. Phase 3에서 "live-store가 최근 트레이스를 메모리에 들고 있어서"라고 본 것은 주된 이유가 아니었다(정정)
- Go 힙: 사용 중 331Mi(최대 676Mi), 다음 GC 기준 379Mi. `GOGC=100`이라 힙이 살아 있는 데이터의 약 2배까지 자란 뒤 GC가 돈다. `GOMEMLIMIT`(1638MiB)은 그 근처에 가야 작동하는 상한이라 평소에는 영향이 없다
- 블록: 1시간에 약 106개를 잘라(cut) 완성·저장한다(약 34초마다). 블록을 parquet로 만들 때 메모리를 많이 할당한다(**추정**)
- 최고점(08:58~08:59 UTC, working set 863Mi, 힙 676Mi)의 원인은 **확인하지 못했다.** 같은 분에 압축(compaction)은 없었다. 08:51 힙 489Mi는 압축 24블록과 겹친다
- metrics-generator(서비스 그래프) 활성 시리즈는 786개로 작다

**조정** — requests만 실사용에 맞추고 limits는 바꾸지 않는다

| 컴포넌트 | requests | 파일 | 근거 |
|---|---|---|---|
| Prometheus | 512 → **768Mi** | `kube-prometheus-stack.yaml` | 실사용 532Mi, 가동 시간에 따라 증가. SLO 알림 평가 주체 |
| Grafana 본체 | 128 → **320Mi** | 〃 | 실사용 271Mi |
| Grafana 사이드카 ×3 | 64 → **96Mi** | 〃 | 실사용 77~79Mi (limits 128Mi 유지) |
| Tempo | 512 → **768Mi** | `tempo.yaml` | 평소 200~460Mi, 최대 863Mi (limits 2Gi 유지) |
| OTel Collector | 400(limits와 같음) → **160Mi** | `otel-demo.yaml` | 실사용 89Mi. 차트가 limits만 지정해 requests가 limits와 같아졌다. `memory_limiter`가 limits의 80%를 기준으로 하므로 limits 400Mi 유지. CPU 값이 없어 QoS(Burstable)는 그대로 |

- 렌더링(`helm template`)으로 다섯 값이 의도대로 들어간 것을 확인했다
- 계산상 monitoring 노드 requests 합: 2242 → 약 2802Mi(39%). limits 합 6736Mi(94%)는 그대로
- `GOGC` 조정(Tempo 힙 성장 억제)은 동작이 바뀌므로 이번에는 하지 않는다

## ⓪-2 인프라 지표 중복 조사 (2026-10-31)

처음에는 기준선 알림이 인프라 지표를 쓰지 않아 Phase 5 이후로 미뤘다가, Phase 4에서 정리하기로 바꿨다.

**겹치는 수신기** (Collector 데모 차트 presets `hostMetrics`·`kubeletMetrics`·`clusterMetrics`가 켬)

| Collector 수신기 (주기) | 지표 | 시리즈 | kps 대응 | 시리즈 |
|---|---|---|---|---|
| `hostmetrics` (10s) | `system_*` 27개 | 417 | node-exporter `node_*` | 4,190 |
| `kubeletstats` (20s) | `k8s_pod_*`·`k8s_node_*`·`k8s_container_*`·`k8s_volume_*`·`container_*` 31개 | 1,066 | kubelet/cAdvisor `container_*` | 9,204 |
| `k8s_cluster` (10s) | `k8s_deployment_*` 등 13개 | 168 | kube-state-metrics `kube_*` | 4,146 |

- 중복 아님(대응 없음): `kafkametrics`, `receiver_creator`(postgres·redis·nginx·http_check), Collector 자체 지표(`prometheus` 수신기)
- Collector 쪽 합계 약 1,650 시리즈로 전체 head 122,736의 1.3%. **시리즈 절감 효과는 작다.** 가장 큰 수집 대상은 apiserver(59,424, 48%)
- **같은 이름 충돌**: `container_memory_working_set_bytes`, `container_memory_usage_bytes`가 cAdvisor(`job="kubelet"`)와 kubeletstats(job=서비스) 양쪽에 있다. job 없이 합산하면 두 배로 센다. kps 기본 규칙은 모두 job으로 걸러 영향 없음(Prometheus 규칙 전체 확인). ⓪ 측정은 `node` 라벨(cAdvisor에만 있음)로 걸러 영향 없었다

**사용처**

| 사용처 | 쓰는 쪽 |
|---|---|
| kps 기본 규칙·대시보드 23개 | kps (`node_*`, `kube_*`, `container_*{job="kubelet"}`) |
| Phase 4 기준선 규칙 | 둘 다 안 씀 |
| 데모 apm-dashboard | Collector: `k8s_pod_cpu_time_seconds_total`, `k8s_pod_memory_working_set_bytes`, `system_cpu_time_seconds_total`, `system_memory_usage_bytes` (패널 4개, `target_info{service_name}`와 `k8s_pod_name`·`host_name`으로 조인) |
| 데모 linux-dashboard | Collector: `system_*` 14개 (대시보드 전체) |
| `k8s_cluster` 지표 | 사용처 없음 |

**정리 방안 (제안, 결정 대기)**
- **kps로 일원화**: 인프라(노드·파드 자원·쿠버네티스 오브젝트 상태)는 kps만 수집하고, Collector는 앱 텔레메트리와 kps에 대응이 없는 것(Kafka·PostgreSQL·Valkey·nginx·Collector 자신)만 맡는다
  1. `otel-demo.yaml`에서 Collector presets `hostMetrics`·`kubeletMetrics`·`clusterMetrics`를 끈다(hostfs 마운트·관련 RBAC도 빠짐)
  2. apm-dashboard 인프라 패널 4개를 kps 지표로 다시 쓴다. 파드: cAdvisor `container_*{job="kubelet"}`를 `target_info`의 `k8s_pod_name`과 `pod`로 연결. 호스트: node-exporter를 `node_uname_info`로 노드 이름과 연결
  3. linux-dashboard는 지운다(kps `kps-nodes`·`kps-node-rsrc-use` 등이 같은 내용)
- kps를 남기는 이유: kps 기본 규칙 전부와 대시보드 23개가 kps 지표를 쓰고, Phase 3에서 kps를 고른 이유도 이것이었다. Collector로 일원화(OTel 통일)도 실무에서 쓰지만 규칙·대시보드를 모두 다시 써야 한다
- 잃는 것: apm-dashboard의 서비스 → 파드 연결 쿼리가 복잡해진다(cAdvisor에는 `pod` 라벨만 있음). 데모 원본 대시보드와 달라진다
- 대안: 사용처가 없는 `k8s_cluster`만 끈다(대시보드 수정 없음, 이름 충돌은 남음)
- 데모 차트를 재배포하면 Collector가 재시작되어 주문이 몇 건 실패할 수 있다(② 진행 중 발견)

## 다음 작업 재개 지점 (2026-10-31 클러스터 삭제 시점)

- 완료: ③ Slack 연결, ⓪ 메모리 requests 조정, ① SLO·기준선 알림 확정과 span metrics 라벨 추가, ② 규칙 적용·정상 평가 확인
- 미커밋 변경: values 3개(`kube-prometheus-stack`·`tempo`·`otel-demo`), `observability/alerts/slo-baseline.yaml`, `deploy-observability.ps1`, 문서
- 다음 순서
  1. ⓪-2 인프라 지표 일원화 방안 결정 → values·대시보드 수정
  2. `up.ps1` → `deploy-observability.ps1` → `deploy-demo.ps1` (규칙은 `deploy-observability.ps1`이 적용)
  3. 일원화 결과 확인(Collector 인프라 시리즈 0, apm-dashboard 패널), 기준선 규칙이 새 클러스터에서도 정상 평가되는지 확인
  4. ④ SLO 대시보드 → ⑤ 의도적 에러로 Slack 도착 검증, 기준선 고정
- 새 클러스터는 Prometheus·Tempo가 비어 있다. 평상시 burn rate는 트래픽이 쌓인 뒤(최소 30분~1시간) 다시 본다

## ① SLI 후보 지표 확인 (2026-10-31, 클러스터 생성 후 약 1시간 반)

Prometheus API(port-forward)와 Tempo 검색 API로 확인했다. 모든 수치는 최근 1시간, load-generator 기본값(1개), 장애 플래그 없음.

**지표**
- Collector span metrics `traces_span_metrics_calls_total` / `..._duration_milliseconds_bucket`. 라벨: `service_name`, `span_name`, `span_kind`, `status_code`(`STATUS_CODE_UNSET`/`STATUS_CODE_ERROR`)와 k8s 리소스 라벨. HTTP 상태 코드나 경로 라벨은 없다
- 지연 버킷 경계(ms): `2 4 6 8 10 50 100 200 400 800 1000 1400 2000 5000 10000 15000 +Inf`. 지연 SLO 임계값은 이 경계 중에서 고른다
- SDK의 `http_server_request_duration_seconds`는 frontend·cart·ad·shipping과 Collector만 낸다. **frontend-proxy(Envoy)는 이 지표를 내지 않는다.** frontend는 `http_request_method`·`http_response_status_code`만 있고 경로 라벨이 없다
- frontend-proxy의 span metrics `span_name`은 `GET`/`POST`뿐이다(경로 없음)

**평상시 값**

| 후보 | 요청 수(1시간) | 에러 | 지연 |
|---|---|---|---|
| frontend-proxy 서버 스팬 | 60,458 | 0 | p95 41ms, **p99 3,078ms**. 200ms 이하 98.44%, 200ms~2초 구간에는 요청이 거의 없음 |
| frontend `POST /api/checkout` 서버 스팬 | 327 | 0 | |
| checkout `PlaceOrder` 서버 스팬 | 164 (초당 0.04건) | 0 | p95 50ms, p99 89ms, 200ms 이하 100% |
| frontend HTTP 지표 | GET 200 41,476 / 308 241, POST 200 1,150 / 500 0 | 0 | |

**확인한 것**
- **frontend-proxy의 2초 넘는 요청은 flagd 스트리밍이다.** Tempo 검색 `{resource.service.name="frontend-proxy" && kind=server && duration>2s}` 결과 100건 모두 `upstream_cluster=flagservice`, `/flagservice/flagd.evaluation.v1.Service/EventStream`, 3.1~3.6초. 브라우저가 플래그 변경을 받으려고 여는 연결이라 사용자가 기다리는 요청이 아니다. 지연 SLI에서 빼야 하는데, span metrics에 `upstream_cluster` 라벨이 없어 지금은 지표로 뺄 수 없다
- 평상시 에러는 세 후보 모두 0이다. 목표치를 정하면 평상시에는 에러 버짓을 쓰지 않는다
- `PlaceOrder`는 5분에 약 12건이라, 5분 구간 burn rate는 한두 건 실패에도 크게 흔들린다. 그래서 긴 구간(1h·6h)과 AND로 묶는 방식이 필요하다
- frontend `POST /api/checkout`(327)이 `PlaceOrder`(164)의 약 2배다. 요청 하나에 같은 이름의 서버 스팬이 2개 생기는 것으로 **추정**(확인 안 함). SLI로는 `PlaceOrder`를 쓰므로 영향이 없다

**span metrics 라벨 추가 과정**
1. Envoy 스팬 속성 확인: Tempo에서 frontend-proxy 서버 스팬 하나를 열어 보니 백엔드는 `upstream_cluster`(`upstream_cluster.name`도 같은 값), 응답 코드는 `http.status_code`(문자열 `"200"`), 경로는 `http.url`이었다. 200 응답의 스팬 상태는 비어 있다(`STATUS_CODE_UNSET`)
2. 프록시가 보내는 백엔드 확인(최근 1시간 서버 스팬 500 트레이스 표본): `frontend` 340, `image-provider` 150(상품 이미지), `flagservice` 15. 표본에는 Grafana·Locust·flagd UI 경로가 없었다(이 시간에 ALB로 조회하지 않음)
3. 그래서 SLI 대상은 `upstream_cluster=~"frontend|image-provider"`로 정한다. 상품 이미지가 안 뜨는 것도 사용자 영향이다
4. `http.status_code` 속성은 frontend-proxy 외에 frontend-web(브라우저 fetch 스팬), image-provider 스팬에도 있어 그 서비스들의 시리즈도 응답 코드별로 나뉜다
5. 데모 차트 기본값은 `span_metrics: {}`(dimension 없음). `otel-demo.yaml`에 `dimensions`를 추가하고 렌더링으로 확인했다. 맵이라 기존 `exemplars` 설정과 병합된다
6. 추가 전 시리즈 수(배포 직전): `traces_span_metrics_calls_total` 151개, `..._duration_milliseconds_bucket` 2,567개

**라벨 추가 후 확인** (재배포 09:24~09:26 UTC, 측정 09:37 UTC, 최근 10분)
- 반영: requests가 values대로 들어갔다(Prometheus·Tempo 768Mi, Grafana 320Mi + 사이드카 96Mi×3, Collector 160Mi). monitoring 노드 requests 합 **2802Mi(39%)**, limits 합 6736Mi(94%). load-generator 1개 유지
- 재배포로 Prometheus(09:24:21)·Tempo(09:25:23) 파드가 새로 만들어져 그 전 지표·트레이스는 사라졌다(위 수치는 미리 기록함)
- 라벨이 붙은 서비스: frontend-proxy(11 시리즈), frontend(19), agent(3), image-provider(2)
- **시리즈 수는 사실상 그대로다**: calls 151 → 150, duration_bucket 2,567 → 2,550. 라벨 값 종류가 적어 비용이 거의 없다

| upstream_cluster | http_status_code | status_code | 10분 요청 수 |
|---|---|---|---|
| frontend | 200 | UNSET | 7,001 |
| image-provider | 200 | UNSET | 2,478 |
| flagservice | 200 | UNSET | 316 |
| frontend | 308 | UNSET | 41 |
| frontend | 500 | **ERROR** | 0 (시리즈 존재) |

- `frontend 500 ERROR` 시리즈가 생겼다는 것은 재배포 이후 frontend로 간 요청 중 500 응답이 있었고, **Envoy가 5xx 스팬을 `STATUS_CODE_ERROR`로 기록한다**는 뜻이다(시리즈가 처음 생긴 값이라 `increase`는 0으로 나옴). 어떤 요청이었는지는 확인하지 않았다
- 쇼핑몰 요청(`upstream_cluster=~"frontend|image-provider"`) 지연: 100ms 이하 100%, p95 36ms, p99 48ms, p99.9 75ms. 백엔드별 p99는 frontend 48ms, image-provider 4ms, **flagservice 4,940ms**. flagd를 빼니 p99가 3,078ms → 48ms가 됐다
- 대기 스크립트 오류: 라벨이 생길 때까지 기다리는 bash 확인 스크립트가 10분 만에 "나타나지 않음"으로 끝났지만 실제로는 라벨이 있었다. Prometheus 응답에서 값을 꺼내는 grep 패턴이 틀렸다(값 뒤의 `]`까지 잡혀 숫자 추출 실패)

**확인하지 못한 것**
- Tempo 태그 값 목록에 `http.status_code="500"`(문자열)이 있었지만 최근 1시간 검색에서는 나오지 않았다. 태그 값 목록이 더 넓은 기간을 보는 것으로 **추정**
- TraceQL `select(span.http.status_code)`가 frontend-proxy 스팬에서 `nil`을 돌려줬다. 트레이스 원본에는 값이 있다. Envoy가 문자열로 보내는 값과 Tempo의 전용 열 타입이 달라서로 **추정**(확인 안 함). span metrics는 원본 속성을 읽으므로 영향이 없다
- ~~Envoy가 5xx 응답 스팬의 상태를 `ERROR`로 기록하는지. `http.status_code` 라벨을 쓰면 상관없지만 ⑤에서 확인한다~~ → 라벨 추가 후 `http_status_code="500", status_code="STATUS_CODE_ERROR"` 시리즈로 확인했다(위)

## 기준선 알림 (2026-10-31 확정)

Phase 5에서 이 목록과 조건을 **고치지 않은 상태로** 장애를 주입한다. 바뀐 점은 Phase 5 문서에 이 표와 비교해 남긴다.

**SLO** (기준 기간 30일. burn rate 기준은 Google SRE Workbook의 다중 구간 방식)

| SLO | SLI: 좋은 요청 ÷ 전체 요청 | 목표 | 에러 버짓 |
|---|---|---|---|
| 쇼핑몰 가용성 | frontend-proxy 서버 스팬 중 `upstream_cluster=~"frontend\|image-provider"`, `http_status_code`가 5xx가 아닌 비율 | 99.5% | 0.5% |
| 주문 성공률 | checkout `oteldemo.CheckoutService/PlaceOrder` 서버 스팬 중 `status_code`가 `STATUS_CODE_ERROR`가 아닌 비율 | 99% | 1% |
| 쇼핑몰 지연 | 가용성과 같은 요청 중 400ms 버킷 이하로 끝난 비율 | 99% | 1% |

| severity | 조건 (SLO마다 같은 alertname, severity만 다름) | 뜻 |
|---|---|---|
| critical | 1시간 burn rate > 14.4 **그리고** 5분 burn rate > 14.4 | 1시간에 30일 버짓의 2%를 씀 |
| warning | 6시간 burn rate > 6 **그리고** 30분 burn rate > 6 | 6시간에 30일 버짓의 5%를 씀 |

**측정 유효성**

| 알림 | severity | 잡는 것 |
|---|---|---|
| 쇼핑몰 요청률 급감 (데이터 없음 포함) | critical | 요청이 끊기거나 SLI 시리즈가 사라져 burn rate를 계산할 수 없는 상태. `rate()`는 시리즈가 없으면 빈 결과라 `or vector(0)`로 0을 만든다 |
| Collector 전송 실패·드롭 | warning | 스팬 일부가 버려져 SLI가 남은 일부로만 계산되는 상태. Collector 전체 고장은 위 요청률 알림이 잡는다 |

**kps 기본 규칙**: 차트 기본값(EKS에서 수집할 수 없는 컨트롤 플레인 규칙만 끔). 수집 대상 down은 `TargetDown`이 다룬다.

**합치거나 줄인 것**
- "SLI 데이터 없음"과 "트래픽 급감"은 하나로 합쳤다(데이터 없음은 트래픽 0의 극단)
- 관측 파이프라인 알림은 Collector 전송 실패·드롭만 남겼다(전체 고장은 요청률 알림, 수집 대상 down은 `TargetDown`)
- 가용성과 주문 성공률은 겹쳐 보이지만 남겼다. 주문 요청(`POST /api/checkout` 1시간 327건)은 프록시 전체(60,458건)의 약 0.5%라, **결제가 100% 실패해도 가용성 burn rate는 약 1**에 그친다(기준 14.4)

**일부러 넣지 않은 것** (Phase 5에서 공백인지 확인)
- Kafka consumer lag: 시나리오 3(`kafkaQueueProblems`)이 "비동기 지연이 SLO에 드러나는가"를 확인한다
- 메모리 추세: 시나리오 2(`emailMemoryLeak`)
- 주문 API 지연 SLO: 쇼핑몰 지연 SLO에서 주문 요청은 0.5%라 묻힌다. 요청이 5분에 약 12건이라 따로 두면 크게 흔들린다
- 외부 점검(blackbox): ALB가 본인 IP만 허용해 클러스터 밖 점검 위치가 따로 필요하다. ALB·DNS 장애는 탐지하지 못한다
- Watchdog dead man's switch: 외부 감시 서비스가 없어 Prometheus·Alertmanager 자체가 죽으면 아무 알림도 오지 않는다

**알려진 한계**
- 클러스터를 몇 시간만 띄워 6시간 구간이 다 차지 않는다. Prometheus는 있는 데이터로 계산하므로 warning은 "6시간 동안 꾸준히"가 아니라 "가동 이후 동안"의 뜻이 된다
- 목표치는 Prometheus 재시작 후 10분 실측(에러 0, 지연 100% ≤100ms)으로 정했다. ② 적용 후 평상시 burn rate가 0 근처인지 다시 확인한다
- load-generator를 0으로 줄이면 요청률 급감 알림이 울린다. 미리 silence를 건다(operations.md)

## ② burn-rate 규칙 (`observability/alerts/slo-baseline.yaml`)

**구조**
- `slo-sli` 그룹: SLO별 구간 에러 비율(1 − SLI)을 recording rule로 미리 계산한다. `slo:sli_error:ratio_rate{5m,30m,1h,6h}`에 라벨 `slo`(`shop-availability`/`checkout`/`shop-latency`). 에러 버짓은 `slo:error_budget:ratio`(0.005/0.01/0.01)로 둬 알림과 대시보드(④)가 같은 값을 쓴다
- `slo-burn-rate` 그룹: `SLOErrorBudgetBurn` 하나에 critical(1h·5m > 14.4×버짓)과 warning(6h·30m > 6×버짓). `for: 2m`(지표가 1분마다 들어와 평가 한두 번의 흔들림을 거름). 라벨 `alert_type: slo`
- `slo-measurement` 그룹: `ShopTrafficLow`(critical, 쇼핑몰 요청 5건/초 미만 5분, 데이터 없음 포함), `CollectorTelemetryDropping`(warning, 스팬 거부·실패 또는 metrics·traces 전송 실패 10분). 라벨 `alert_type: measurement`
- 평가 주기 1m. 적용은 `deploy-observability.ps1`의 마지막 단계(`kubectl apply -f observability/alerts`)

**작성하며 정한 것**
- 5xx가 한 번도 없으면 분자 시리즈가 없어 비율이 빈 결과가 된다 → `or vector(0)`. 분모가 없을 때는 일부러 빈 결과로 둔다(그 상태는 `ShopTrafficLow`가 잡음)
- 지표 이름을 정규식으로 여러 개 골라 한 번에 `rate()`하면 `vector cannot contain metrics with the same labelset` 오류가 난다(`rate()`가 이름을 지워 라벨이 같아짐). Collector 알림은 지표마다 `label_replace`로 `drop` 라벨을 붙여 `or`로 묶었다
- Collector `otelcol_exporter_send_failed_*`·`enqueue_failed_*`는 지금 Prometheus에 시리즈가 없다. 실패가 한 번도 없으면 내보내지 않는 것으로 **추정**. 수신 거부·실패(`otelcol_receiver_refused_*`·`failed_*`)는 모두 0으로 있다. 큐 사용률은 tempo 0.9%, 나머지 0
- 알림 주석의 `$labels`에는 규칙에서 붙인 라벨(severity)이 들어가지 않는 것으로 알고 있어(**확인 안 함**) summary에서 severity를 뺐다. Slack 본문에는 Alertmanager가 severity를 표시한다

**검증 (적용 전)**
- `kubectl apply --dry-run=server`: 통과(operator admission webhook 검증)
- `promtool check rules`(Prometheus 파드, 표준 입력): `SUCCESS: 19 rules found`. Prometheus 이미지에 `sh`가 없어 파일을 쓸 수 없으므로 표준 입력으로 넘긴다
- 식을 현재 데이터로 직접 계산(09:42 UTC, Prometheus 재시작 09:24 이후 18분)

| 구간 | 가용성 에러 | 주문 에러 | 지연 400ms 초과 |
|---|---|---|---|
| 5m | 0 | 0 | 0 |
| 30m·1h | 0.0065% | **4.0%** | 0 |

- 쇼핑몰 요청률 16.3건/초(기준 5 미만), Collector 드롭 식 결과 없음, PlaceOrder 0.05건/초
- 적용해도 바로 울리는 알림은 없다. 주문 에러 4.0%는 버짓(1%)의 4배로 warning 기준(6배)에 못 미친다

**적용 (09:44:35 UTC)** — `kubectl apply -f observability/alerts`. 8초 뒤(09:44:43) Prometheus에 그룹 로드
- 09:46 확인: 세 그룹 19개 규칙 모두 `health: ok`, 알림 4개 모두 `inactive`. Alertmanager 활성 알림은 `Watchdog`뿐
- burn rate: 주문 3.23(1h·30m, 아래 Collector 재시작 실패 2건), 가용성 0.01, 지연 0. 6h 값이 1h와 같은 것은 Prometheus 가동이 22분이라 있는 데이터가 같기 때문(알려진 한계)

**진행 중 발견: Collector 재시작이 주문 실패를 만들었다**
- 주문 에러 4.0%(재시작 후 PlaceOrder 약 50건 중 2건)와 가용성 5xx 1건은 모두 **09:26:03~04 UTC**, Collector DaemonSet 재시작(09:25:56~09:26:00) 직후다. 재시작한 파드는 Collector 3개뿐이었다
- 트레이스 `714557fc7ea07e44d41d66ff98ef4e10`, `50944349f76a2378edd7202bcf9c83dd`: checkout `PlaceOrder` → shipping `POST /get-quote` 500 → shipping → quote `POST http://quote:8080/getquote`가 **5,002ms에 `error.type=Timeout`**. 두 번째는 frontend-proxy `/api/checkout` 5xx로 사용자에게 드러났다
- 원인 **추정**: quote(PHP)가 요청 처리 중 텔레메트리를 동기로 내보내다 Collector가 없는 동안 막혔다. 확인하지 않았다
- 영향: 데모 차트 재배포(Collector 재시작) 한 번으로 주문 에러 버짓을 쓴다. PlaceOrder가 30분에 약 50건이라 3건이 실패하면 30분 에러율 6%로 warning 조건의 짧은 구간을 넘는다(긴 구간 6시간도 클러스터 가동 시간이 짧으면 같이 넘을 수 있다). **배포 직후 warning은 이 현상일 수 있다**
- 관측 파이프라인이 앱 요청을 막는 문제라 데이터 품질(OBS)이 아니라 장애 후보로 본다. Phase 5에서 재현·원인 확인 후보로 남긴다

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
