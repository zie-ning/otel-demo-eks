# Phase 3. 관측 데이터 품질 수정과 관측 스택 전환

> 상태: 🔄 진행 중 (2026-10-30 시작, 3-A 완료, 3-B ③④ 완료) · 요약: [PLAN.md](../PLAN.md#phase-3-관측-스택-전환)

## 목표
- **3-A**: Phase 2에서 발견한 관측 데이터 품질 문제를 먼저 고친다.
- **3-B**: 데모 차트 내장 관측 도구(Prometheus·Grafana·Jaeger·OpenSearch)를 kube-prometheus-stack·Tempo·Loki로 한 단계씩 바꾸고, Grafana 하나에서 메트릭 → 트레이스 → 로그로 이동할 수 있게 한다.

---

## 3-A. 관측 데이터 품질 수정

### 3-A를 먼저 한 이유
- Prometheus는 `host.name`, `k8s.pod.name` 등 리소스 속성을 **메트릭 라벨로 승격**한다. 잘못된 값이 대시보드·알림 규칙에 굳기 전에 바로잡는다.
- Tempo로 바꾸기 전에 고치면 **같은 Jaeger, 같은 집계 방식으로 수정 전후를 비교**할 수 있다.
- 수정 대상(Collector 가공 설정)이 저장소 교체와 독립적이다.

### ① Collector 리소스 속성 수정 — PR [#5](https://github.com/zie-ning/otel-demo-eks/pull/5)
브랜치 `obs/collector-resource-attributes`, 이슈 #1 #3 #4

| 문제 | 수정 | 결과 |
|---|---|---|
| OBS-1 `host.name`이 Collector 파드 이름 | `resource_detection`에서 `system` 감지기 제거, `host.name`을 실행 노드 이름으로 upsert | 20개 서비스 전부 → 0 |
| OBS-3 브라우저 스팬에 프록시 파드 정보 | `frontend-web`의 `k8s.*`·`container.*`·`host.name`·`service.instance.id` 제거 (traces·metrics 파이프라인) | 50/50 → 0/50 |
| OBS-6 ALB 헬스체크 트레이스 | 헬스체크를 Envoy 관리 포트 `10000`의 `/ready`로 이동 | frontend-proxy 트레이스 중 261/500 → 0/500 |

- 헬스체크는 처음에 Collector 필터로 거르려 했지만, User-Agent가 스팬 6개 중 2개에만 있어 나머지가 부모 없는 스팬으로 남아 기각했다.
- CodeRabbit 리뷰로 브라우저 span metrics에 `host.name`이 다시 붙는 것을 발견해 metrics 파이프라인에도 같은 처리를 넣었다.
- 집계 스크립트 `scripts/check-resource-attributes.ps1`(Jaeger API)을 만들어 수정 전후를 같은 방식으로 비교했다.

### ② OBS-2 파드 메타데이터 — PR [#7](https://github.com/zie-ning/otel-demo-eks/pull/7)
브랜치 `obs/obs-2-pod-metadata`, 이슈 #2

- **원인 확정**: cart·accounting(.NET), quote(PHP) SDK가 보내는 `container.id`는 **파드 샌드박스 ID**였다. 노드가 cgroup v2라 `/proc/self/cgroup`에 ID가 없어 SDK가 mountinfo의 `/etc/hostname` 경로(`…/sandboxes/<ID>/hostname`)를 읽는다.
- `k8s_attributes`는 값이 있는 첫 매칭 규칙(`container.id`) 하나로만 파드를 찾고 실패하면 다음 규칙으로 넘어가지 않는다.
- **처음 계획을 바꾼 이유**
  - Downward API로 `k8s.pod.uid` 주입: 앞 순서의 `container.id` 규칙에 먼저 걸려 효과 없음
  - `pod_association`에서 `container.id` 규칙 제거: 차트가 profiles 파이프라인용으로 이 규칙을 강제로 넣어 values로 불가
- **수정**: Collector에서 앱 데이터의 `container.id`를 매칭 전에 지우고(`transform/drop_sdk_container_id`), `k8s_attributes`가 쿠버네티스 API의 올바른 값으로 다시 채우게 했다. 앱 파드 재시작 없음.
- **결과**: cart 0/50 → 50/50, quote 0/4 → 37/37, accounting 0/3 → 10/10. quote의 `container.id`는 실제 값과 일치.
- **새로 발견**: OBS-7(#6) init 컨테이너가 있는 파드에는 컨테이너 단위 속성이 없음. 수정 전부터 있던 문제이고 파드·노드 단위 분석에는 영향이 없어 기록만 했다.

### 3-A 완료 기준 ✅
Jaeger에서 같은 방식으로 집계해 모든 서버 서비스에 `k8s.pod.name`, `frontend-web`에는 없음, `host.name`이 Collector 파드 이름 아님. 수치는 [observability-findings.md](../observability-findings.md)의 전후 비교표.

---

## 3-B. 관측 스택 전환

### 공통 결정 (2026-10-30)
| 항목 | 결정 | 근거 |
|---|---|---|
| 설치 방식 | `scripts/deploy-observability.ps1`로 Helm 직접 설치, values는 `helm/values/`에 Git 관리 | 데모 배포와 같은 방식. 수정·재배포가 빠름 |
| 네임스페이스 | `monitoring` | 데모 차트와 수명 분리. 데모 재설치·장애 주입이 관측 도구에 번지지 않게 함 |
| 저장소 | emptyDir (PVC 없음) | 클러스터를 작업할 때만 띄움. EBS CSI 드라이버 미설치. 증거는 삭제 전에 저장 |
| Grafana 인증 | admin 비밀번호를 Kubernetes Secret으로 관리 (커밋 금지) | 내장 Grafana는 익명 Admin |
| 순서 | ③은 설치와 병행 전송까지만, 내장 Prometheus는 ④에서 내장 Grafana와 함께 끔 | 내장 Grafana 데이터소스가 `http://prometheus:9090`으로 고정되어 있어 먼저 끄면 대시보드가 깨짐 |
| 자원 | 새 컴포넌트의 CPU requests를 실제 필요량에 가깝게 작게 | monitoring 노드 CPU requests가 이미 82%(1600m/1930m). 스케줄링은 실제 사용량이 아니라 requests 합으로 판단 |

kube-prometheus-stack을 고른 이유: 내장 Prometheus도 Alertmanager·kube-state-metrics·node-exporter를 켜서 확장할 수 있지만, Phase 4 SLO 알림을 `PrometheusRule`로 관리하는 실무 방식, 쿠버네티스 기본 알림·대시보드 포함, 데모와의 수명 분리를 위해 원래 계획을 유지했다.

### 전환 전 연결 구조 (바꿔야 하는 곳)
- Collector exporter: `prometheus:9090`(OTLP), `jaeger:4317`, `opensearch:9200`
- 데모 대시보드 8개·알림 1개는 데이터소스를 uid(`webstore-metrics`/`webstore-traces`/`webstore-logs`)로 참조. 정의 파일은 데모 차트에 있고 `grafana.enabled`에 묶여 있다
- Envoy `/grafana`, `/jaeger` 경로: frontend-proxy 환경변수 `GRAFANA_HOST`/`GRAFANA_PORT`, `JAEGER_HOST`/`JAEGER_UI_PORT`
- 저장소 도구: `scripts/check-resource-attributes.ps1`, CLAUDE.md 8장이 Jaeger API에 의존

### ③ kube-prometheus-stack 설치 ✅
브랜치 `feat/kube-prometheus-stack`, 차트 92.16.0

- 구성: Prometheus + Alertmanager + operator + node-exporter + kube-state-metrics (Grafana는 ④)
- Prometheus는 내장과 같은 설정: OTLP 수신, exemplar 저장, out-of-order 30분, 리소스 속성 24개 라벨 승격. 보존 2일, emptyDir
- EKS에서 수집할 수 없는 controller-manager·scheduler·etcd·kube-proxy와 관련 기본 규칙을 끔
- Collector가 내장 Prometheus와 kps Prometheus에 **병행 전송**해 비교

비교 결과 (load-generator 3분)
| 항목 | 내장 | kps |
|---|---|---|
| OTLP 메트릭 이름 | 417 | 417 (차이 0) |
| span metrics 전체 요청률 | 106.749/초 | 동일 |
| 서비스별 요청률 (cart / checkout / frontend) | 3.35 / 0.23 / 27.07 | 동일 |
| 라벨 이름 (cart 시계열) | 17개 | 동일 |
| 최근 1분 시계열 수 | 127 | 127 |
| exemplar 있는 시계열 | 64 | 61 (늦게 시작한 차이) |

- kps 수집 대상 22개 모두 up, 발생 알림은 항상 켜지는 `Watchdog`뿐
- monitoring 노드 CPU requests 1600m → 1770m(91%)
- 발견: span metrics(`traces_span_metrics_*`)에는 양쪽 모두 exemplar가 없음. Collector `span_metrics` 커넥터의 exemplar가 기본 꺼짐 → ⑦에서 처리

### ④ Grafana 일원화 ✅
같은 브랜치

- kps Grafana 13.3: `/grafana` 하위 경로, 익명 Viewer + admin 로그인(Secret `grafana-admin`, 스크립트가 무작위 생성)
- 데모 대시보드 8개·알림 규칙을 `helm/grafana/`(kustomize ConfigMap, server-side apply)로 이전. 데이터소스 uid 유지
- frontend-proxy `GRAFANA_HOST`를 kps Grafana로, Jaeger `PROMETHEUS_ADDR`를 kps Prometheus로 변경
- 내장 Prometheus·Grafana 비활성화, Collector 메트릭은 kps로만 전송

검증 결과
| 항목 | 결과 |
|---|---|
| ALB 경유 `/grafana/` | 200 |
| 익명 사용자 대시보드 생성 | 403 (읽기 전용) |
| admin 로그인 | 성공, Grafana 관리자 |
| 대시보드 | 데모 8/8 + kps 기본 25개 (이후 정리해 23개, 아래 "대시보드 정리") |
| 대시보드 쿼리 (`webstore-metrics`) | 정상 |
| 알림 규칙 `CartAddItemHighLatency` | 로드, health ok |
| kps 수집 대상 | 전부 up (Grafana 포함) |
| monitoring 노드 CPU requests | 1770m → **1400m(72%)** |

검증 중 발견해 수정한 것
1. 데모 알림 규칙의 수신처 `grafana-default-email`이 kps Grafana에 없어 로드 실패 → Alertmanager contact point(`helm/grafana/alerting/contact-points.yml`)를 만들고 수신처 변경. Grafana 알림도 Alertmanager로 모임
2. `serve_from_sub_path` 때문에 `/metrics`가 `localhost:3000/grafana/metrics`로 리다이렉트되어 Grafana 수집 실패 → 수집 경로 `/grafana/metrics`
3. Alertmanager 데이터소스가 "Plugin unavailable" → 제거. 이미 프로비저닝된 데이터소스는 Grafana DB에 남아 파드 재시작으로 정리

대시보드 정리
- kps 기본 대시보드 25개 중 노드가 리눅스뿐이라 쓸모없는 Node Exporter / AIX·MacOS 2개를 끔(`nodeExporter.operatingSystems`)
- Multi-Cluster, Persistent Volumes 대시보드도 이 환경에선 쓰지 않지만 개별로 끄는 옵션이 없어 유지
- 폴더 분리: 사이드카 `folderAnnotation: grafana_folder` + `foldersFromFilesStructure`. 데모 대시보드 8개는 **OpenTelemetry Demo**, kps 기본 23개는 **Kubernetes** 폴더(알림 규칙 폴더 `cart`는 별도)

확인만 한 것
- OpenSearch 데이터소스 상태 점검은 "Index not found: otel-logs-*"지만 실제 PPL 로그 쿼리는 정상
- Jaeger Monitor 탭은 kps에 span metrics가 있는데도 빈 결과. 원인 미확인, 변경 전 동작 여부도 미확인. ⑤에서 Jaeger 제거

남은 결정: kps(kubelet/cAdvisor·node-exporter·kube-state-metrics)와 Collector(kubeletstats·hostmetrics·k8s_cluster) 수집이 겹친다. 데모 Linux 대시보드는 Collector hostmetrics를 쓰므로 당분간 둘 다 유지.

### ⑤ Tempo 도입 (예정)
- 트레이스 exporter를 Tempo로, 데이터소스 `webstore-traces`를 tempo 타입으로, 내장 Jaeger·`/jaeger` 경로 비활성화
- 대시보드 "Service Dependency"(Jaeger 전용 dependencyGraph) 패널 대체
- 집계 스크립트와 CLAUDE.md 분석 원칙을 Tempo 기준으로 변경
- 차트 저장소 확인 필요 (Grafana 차트 일부가 `grafana-community`로 이전됨)

### ⑥ Loki 도입 (예정)
- 단일 바이너리, 파일시스템 저장. 캐시·canary 등 부가 컴포넌트는 끔
- Collector 로그를 Loki OTLP 입구로, 내장 OpenSearch 비활성화(CPU requests 1000m 해제)
- 대시보드 로그 패널 2개(OpenSearch PPL)를 LogQL로 재작성

### ⑦ 데이터소스 연결 (예정)
- `span_metrics` 커넥터 exemplar 켜기
- 메트릭 exemplar → Tempo, Tempo → Loki(trace_id), Loki → Tempo

### 3-B 완료 기준
- [ ] Grafana 하나에서 메트릭 → 트레이스 → 로그로 이동 가능
