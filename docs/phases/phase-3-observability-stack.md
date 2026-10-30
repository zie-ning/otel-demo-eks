# Phase 3. 관측 데이터 품질 수정과 관측 스택 전환

> 상태: ✅ 완료 (2026-10-30) · 요약: [PLAN.md](../PLAN.md#phase-3-관측-스택-전환) · 증거: [evidence/phase3](../evidence/phase3/)

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
- ~~Jaeger Monitor 탭은 kps에 span metrics가 있는데도 빈 결과. 원인 미확인, 변경 전 동작 여부도 미확인. ⑤에서 Jaeger 제거~~
  → ⑤에서 정정: ④에서 Jaeger `extraEnv` 목록을 덮어쓰며 `JAEGER_GRPC_PORT`를 빠뜨려, Jaeger OTLP 수신기가 4317이 아닌 임의 포트로 열리고 Collector 전송이 거부되고 있었다(확인). Monitor 탭이 비었던 것도 이 때문일 가능성이 크다(추정, Jaeger를 제거해 더 확인하지 않음).

남은 결정: kps(kubelet/cAdvisor·node-exporter·kube-state-metrics)와 Collector(kubeletstats·hostmetrics·k8s_cluster) 수집이 겹친다. 데모 Linux 대시보드는 Collector hostmetrics를 쓰므로 당분간 둘 다 유지.

### ⑤⑥⑦ 진행 방식
⑤⑥⑦은 브랜치 하나(`feat/tempo`)와 PR 하나로 묶었다(사용자 결정). 단계마다 ③④와 같은 순서로 진행했다.
1. 새 저장소를 설치하고 Collector가 **기존 저장소와 병행 전송**
2. 같은 구간의 데이터를 양쪽에서 비교
3. 같음을 확인한 뒤 내장 컴포넌트를 끔

비교 기준을 만들려고 새 클러스터에 `main` 구성(③④ 상태)을 먼저 배포했다. 관측 스택 → 데모 순서의 새 클러스터 설치가 이때 처음 확인됐다.

### ⑤ Tempo 도입 ✅
차트 `grafana-community/tempo` 3.2.1 (Tempo 3.1.1), `helm/values/tempo.yaml`

**구성**
| 항목 | 설정 | 근거 |
|---|---|---|
| 모드 | 단일 바이너리. Tempo 3.x는 ingester·compactor 대신 live-store·backend worker를 쓰고, 이 모드에서는 Kafka가 필요 없다 | 노드 1대 |
| 저장 | emptyDir 3Gi(`extraVolumes`로 크기 제한), 보존 12시간 | 차트는 persistence를 끄면 컨테이너 쓰기 계층에 저장해 크기를 제한할 수 없다 |
| metrics-generator | `service-graphs`만 켜고 kps Prometheus에 remote write(`enableRemoteWriteReceiver`) | Jaeger 의존성 그래프를 대신할 서비스 맵용. span 지표는 Collector `span_metrics`가 이미 만든다 |
| 자원 | requests 50m / 512Mi, limit 2Gi, `GOMEMLIMIT` 1638MiB(제한의 80%) | 아래 OOM 참고 |
| Grafana | 데이터소스 uid `webstore-traces`를 Jaeger에서 넘겨받음 | 대시보드·exemplar 링크를 고치지 않아도 된다 |

대시보드: APM 트레이스 패널(Jaeger search → TraceQL `{resource.service.name=… && resource.service.namespace=…}`), 데모 Service Dependency 패널(Jaeger dependencyGraph → Tempo serviceMap)

**병행 전송 비교** (12:11:41~12:16:41 UTC, 서비스 8개 × 최대 30 트레이스, 양방향)

| 방향 | 결과 |
|---|---|
| Jaeger에서 찾은 트레이스 → Tempo 조회 | checkout 10/10, frontend 30/30, cart 30/30, payment 10/10, shipping 30/30, ad 30/30, quote 30/30, email 10/10. 스팬 수 모두 같음 |
| Tempo에서 찾은 트레이스 → Jaeger 조회 | 같은 8개 서비스 모두 존재. 스팬 수 차이 1건 |

- 차이 1건(`cac341ba7a0e572ed627e6fba10bae43`, Tempo 2 / Jaeger 4): payment ↔ flagd의 장기 연결(EventStream)이라 10분 간격의 스팬이 같은 트레이스 ID를 쓴다. Jaeger에만 있는 2개는 12:06 스팬이고, Tempo를 재배포(약 12:11)할 때 파드 교체로 emptyDir가 비워져 사라졌다. 전송 경로 문제가 아니다.
- 비교 도구: 임시 스크립트(Grafana 데이터소스 프록시로 Tempo, ALB `/jaeger`로 Jaeger 조회). 저장소에는 넣지 않았다.

**진행 중 발견해 수정한 것**
1. **Jaeger가 ④ 이후 트레이스를 받지 못하고 있었다.** `extraEnv` 목록을 덮어쓰며 `JAEGER_GRPC_PORT`를 빠뜨려 Collector 전송이 거부됐다(Jaeger OTLP 수신 주소 `[::]:36087`). 비교를 위해 변수를 되살렸고, 이후 Jaeger를 제거했다. → [operations.md](../operations.md#5-문제-해결)
2. **Grafana 데이터소스가 바뀌지 않았다.** 사이드카 재적용이 500으로 실패, Grafana 로그 `data source with the same uid already exists`. 새 이름(Tempo)이 기존 이름(Jaeger)이 쓰던 uid를 쓰려 해서 충돌했다. Grafana 파드 재시작으로 해결(DB가 emptyDir). 새 클러스터에서는 생기지 않는다. → [operations.md](../operations.md#5-문제-해결)
3. **Tempo가 OOMKilled.** 메모리 제한을 1Gi에서 2Gi로 올리고 `GOMEMLIMIT`를 설정해 해결했다. → [operations.md](../operations.md#5-문제-해결)
4. 차트 기본 Jaeger 수신기(thrift·gRPC)는 `null`로 지우면 서비스 템플릿이 값을 참조해 렌더링이 실패한다. 클러스터 내부 ClusterIP라 그대로 두었다.

**Jaeger 비활성화**
- `jaeger.enabled: false`, Collector traces exporter를 `otlp_grpc/tempo`만 남김. 비교용 Jaeger 데이터소스 삭제(역시 Grafana 재시작 필요)
- 확인: Jaeger 리소스 0개, Collector 오류 0건, `/`·`/grafana` 200, `/jaeger/ui/` 503(차트가 frontend-proxy 경로를 무조건 만들어 남음), APM 트레이스 패널 TraceQL 조회 20행

**집계 스크립트 이전** (`scripts/check-resource-attributes.ps1`)
- `-JaegerUrl` → `-GrafanaUrl`. Grafana 데이터소스 프록시로 Tempo 검색 API를 익명(Viewer)으로 조회한다.
- 트레이스 전체를 받지 않고 TraceQL `select(resource.k8s.pod.name, resource.host.name)`으로 필요한 속성만 받는다.
- 처음 실행 때 `frontend-web`에 파드 이름이 50/50 있는 것으로 나왔다. Tempo는 `select`로 고른 속성이 없으면 키를 빼지 않고 문자열 `"nil"`을 돌려주기 때문이었다(직접 쿼리 `resource.k8s.pod.name != nil`로 0건 확인). 스크립트를 고쳤다.
- 결과(최근 15분): 서버 서비스 17개 모두 `k8s.pod.name` 있음, `frontend-web` 0/50, `host.name`=Collector 0, 헬스체크 0/500. 3-A 완료 기준과 같다. 헬스체크 쿼리가 실제 헬스체크를 잡아내는지는 확인하지 못했다(현재 헬스체크 트레이스가 없음).

확인만 한 것
- Tempo 로그 `attributes truncated` (`gen_ai.tool.definitions` 2627바이트 > 2048): 데모 AI 에이전트 스팬의 긴 속성이 잘린다. 분석 대상이 아니라 기록만 한다.
- Tempo 로그 `no jobs found` 오류: 백엔드 스케줄러가 할 압축 작업이 없을 때 반복된다(추정, 정상 동작).
- 서비스 그래프 지표의 exemplar는 trace ID 라벨이 `traceID`라, Prometheus 데이터소스의 exemplar 링크(`trace_id` 하나만 설정 가능, kps 템플릿 제한)로 이어지지 않는다. 서비스 맵 자체는 정상(서비스 간 연결 30개).

### ⑥ Loki 도입 ✅
차트 `grafana-community/loki` 20.2.0 (Loki 3.7.9), `helm/values/loki.yaml`

**구성**
- Monolithic 모드, 파일시스템 저장, emptyDir 3Gi, 보존 24시간(compactor 삭제), `auth_enabled: false`
- 끈 것: gateway(nginx), chunks·results 캐시(memcached 기본값이 수 GB를 예약), canary, test, 룰 사이드카. 차트 기본값이 SimpleScalable 컴포넌트(write·read·backend) replicas를 3으로 두어 0으로 꺼야 렌더링 검증을 통과한다.
- Collector: `otlp_http/loki` → `http://loki.monitoring:3100/otlp`. Loki 3는 OTLP를 직접 받는다.
- 라벨: Loki 기본 OTLP 설정으로 `service_name`, `service_namespace`, `service_instance_id`, `k8s_*`(파드 이름 포함)가 인덱스 라벨, `trace_id`·`span_id`·`severity_text` 등은 구조화 메타데이터로 저장된다.
- Grafana: 데이터소스 uid `webstore-logs`를 OpenSearch에서 넘겨받음(이름 충돌로 Grafana 재시작 필요, ⑤와 같은 문제)

**대시보드 로그 패널 4개 변환** (OpenSearch PPL → LogQL)
| 대시보드 | 패널 | LogQL |
|---|---|---|
| Demo | Log Records by Severity (표) | `sum by (severity_text) (count_over_time({service_name="${service}"} [$__range]))` |
| Demo | Log Records (100 recent entries) (표 → 로그 패널) | `{service_name="${service}"}` |
| APM | 서비스 로그 | `{service_name="$service_name"} \| service_namespace="$service_namespace"` |
| Collector | Collector Logs | `{service_name="$service_name"}` |

- 대시보드 JSON에 대소문자만 다른 키가 있어(④ 기록) 일반 JSON 도구로 고치면 키 하나가 사라진다. 키 순서·중복을 보존하는 임시 스크립트로 바꿨다(변경 없이 읽고 쓴 결과가 원본과 바이트 단위로 같음을 먼저 확인).
- 심각도 표: API 응답(백엔드 프레임)만 보고 `Series to rows` 변환으로 바꿨다가 화면에서 열이 깨져 되돌렸다. `format: table`이면 Grafana 프런트엔드가 라벨을 열로 펼친 표를 만든다. 브라우저에서 cart `Information 353`, frontend-proxy(Envoy 로그는 심각도 없음) `Count 3644` 확인.

**병행 전송 비교** (12:52~12:57 UTC, 서비스별 로그 수)
- 14개 서비스 완전히 같음 (cart 441, frontend 1039, frontend-proxy 5112, product-catalog 1519, otelcol-contrib 2075 등)
- currency·shipping은 처음에 OpenSearch 0건(Loki 307·127)으로 나왔다. 두 서비스(C++, Rust)는 로그 시각(`timeUnixNano`)을 비워 보내, OpenSearch가 `@timestamp`를 1970-01-01로 저장했기 때문이다. 수신 시각(`observedTimestamp`) 기준으로 다시 세면 currency 308 / 307(구간 경계), shipping 127 / 127. 데이터 품질 문제로 **OBS-8**(#9) 등록.

**OpenSearch 비활성화**
- `opensearch.enabled: false`, Collector logs exporter를 `otlp_http/loki`만 남김, 비교용 데이터소스·OpenSearch 플러그인 삭제
- 확인: OpenSearch 리소스(PVC 포함) 0개, Collector 오류 0건, Loki 최근 1분 로그 2106건, APM 로그 패널 브라우저 확인

**monitoring 노드 자원 (내장 도구 모두 제거 후)**
| 항목 | ④ 완료 시 | ⑥ 완료 후 |
|---|---|---|
| CPU requests | 1400m (72%) | **500m (25%)** |
| 메모리 requests | — | 2242Mi (31%) |
| 메모리 limits 합 | — | 6736Mi (94%) |
| 실사용 메모리 | — | Prometheus 622Mi, Tempo 425Mi, Grafana 279Mi(본체), Loki 96Mi |

- OpenSearch는 실사용 CPU 20m인데 requests 1000m(차트 기본값)로 노드의 절반을 예약하고 있었다. 메모리는 885Mi(Loki 96Mi).
- 메모리 limits 합 94%: 모든 컴포넌트가 동시에 제한까지 차오르면 노드 메모리가 모자란다. 지금 실사용은 훨씬 낮아 Phase 4에서 다시 본다.

### ⑦ 데이터소스 연결 ✅

| 연결 | 설정 |
|---|---|
| 지표 → 트레이스 | Collector `span_metrics` 커넥터 `exemplars.enabled: true` (차트 기본 `{}`는 exemplar 없음). Prometheus 데이터소스의 exemplar 링크(`trace_id` → `webstore-traces`)는 ④에서 설정됨 |
| 트레이스 → 로그 | Tempo `tracesToLogsV2` 사용자 쿼리 `{service_name=~".+"} \| trace_id="…" \| span_id="…"`. trace_id·span_id가 구조화 메타데이터라 라벨 셀렉터가 아니라 파이프라인 필터로 건다 |
| 트레이스 → 지표 | Tempo `tracesToMetrics`: 스팬의 `service.name`으로 요청률·에러율·p95 지연(span metrics) |
| 로그 → 트레이스 | Loki `derivedFields`: `trace_id`(matcherType `label`, 구조화 메타데이터도 찾음)를 "Tempo에서 트레이스 보기" 링크로 |

- 트레이스 → 지표 쿼리를 처음 `rate(…[1m])`로 썼다가 결과가 비었다. span metrics도 1분에 한 번 들어와(5분에 샘플 5개) 1분 구간에 점이 하나뿐이다. `[5m]`으로 바꿨다.
- 배포 후 span metrics에 exemplar가 붙은 시리즈 191개

**검증** — API로 데이터가 이어지는지 확인한 뒤, 브라우저에서 실제 링크를 따라갔다. Explore는 익명(Viewer)에게 열리지 않아 admin 로그인이 필요하다.

| # | 단계 | 결과 | 증거 |
|---|---|---|---|
| 1 | checkout p95 지연 그래프의 exemplar | `PlaceOrder` 52.7ms, trace `c3fccc6522d5114ee2fcf70db254d060`, span `dd422a052efa8178`, "Query with Tempo" | [1-metrics-exemplar.png](../evidence/phase3/1-metrics-exemplar.png) |
| 2 | Tempo 트레이스 | 해당 스팬이 강조된 트레이스(서비스 11개, 스팬 155개) | [2-exemplar-to-tempo-trace.png](../evidence/phase3/2-exemplar-to-tempo-trace.png) |
| 3 | 스팬 Links 메뉴 | Related logs, 요청률·에러율·p95 지연 | [3-span-links-logs-metrics.png](../evidence/phase3/3-span-links-logs-metrics.png) |
| 4 | 트레이스 → 로그 | 이 스팬의 로그 3줄: `[PlaceOrder]`, `payment went through`, `order placed` | [4-trace-to-loki-logs.png](../evidence/phase3/4-trace-to-loki-logs.png) |
| 5 | 로그 → 트레이스 | 같은 trace_id 로그 56줄(checkout·payment·shipping·currency·product-catalog·cart·email 등), 로그 상세의 TraceID 링크 | [5-loki-log-traceid-link.png](../evidence/phase3/5-loki-log-traceid-link.png) |
| 6 | 다시 Tempo | 같은 트레이스로 복귀 | [6-loki-to-tempo-trace.png](../evidence/phase3/6-loki-to-tempo-trace.png) |

API 확인(같은 날): exemplar trace_id 2/2 Tempo 조회, trace_id가 있는 로그 2/2 Tempo 조회, 트레이스 `27434703…` 스팬 139개 중 45개에서 Grafana가 만드는 쿼리로 로그 조회(나머지는 로그를 남기지 않는 스팬)

### 3-B 완료 기준 ✅
- [x] Grafana 하나에서 메트릭 → 트레이스 → 로그로 이동 가능 (위 1~6)

---

## 남은 일 (Phase 4 이후)
- kps와 Collector의 인프라 지표 중복 수집 정리 ([PLAN 미결정 사항](../PLAN.md#6-아직-정하지-않은-사항))
- monitoring 노드 메모리 limits 합 94%: Phase 4에서 알림 규칙을 더하기 전에 실사용 기준으로 조정
- OBS-7(#6), OBS-8(#9): 앱 설정·코드 영역이라 기록만
- 서비스 그래프 지표 exemplar 연결(`traceID` 라벨): 필요해지면 Grafana 데이터소스를 직접 정의하는 방식 검토
- 시연할 때 Explore 링크는 admin 로그인 상태에서만 동작한다

## 관련 PR·이슈
- 3-A: PR #5, #7 / 이슈 #1 #2 #3 #4, #6(OBS-7), #9(OBS-8, ⑥에서 발견)
- ③④: PR #8
- ⑤⑥⑦: 이 문서 갱신과 함께 올리는 PR (브랜치 `feat/tempo`)
