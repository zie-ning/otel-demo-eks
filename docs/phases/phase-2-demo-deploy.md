# Phase 2. 데모 배포와 트레이스 관찰

> 상태: ✅ 완료 (2026-10-29 ~ 2026-10-30) · 요약: [PLAN.md](../PLAN.md#phase-2-데모-배포-helm-기본-구성)

## 목표
OpenTelemetry Demo를 **차트 기본 관측 스택 그대로** 배포해 정상 동작을 확인하고, 화면 동작별 트레이스를 직접 해석해 서비스 구조와 관측 데이터를 이해한다. 이후 단계에서 바꿀 관측 스택의 기준선이 된다.

## 배포
- 차트 `opentelemetry-demo` 0.42.6 (앱 3.1.0), `scripts/deploy-demo.ps1`, values `helm/values/otel-demo.yaml`
- 배치: 데모 서비스는 app 노드, 내장 Jaeger·Prometheus·Grafana·OpenSearch는 monitoring 노드, Collector는 DaemonSet(노드마다 1개, Service `internalTrafficPolicy: Local`)
- 외부 접속: frontend-proxy Ingress → ALB(`target-type: ip`), `inbound-cidrs`로 본인 IP만 허용. 허용 IP는 스크립트가 커밋하지 않는 `otel-demo.local.yaml`로 주입
- `helm upgrade` 때마다 load-generator가 1개로 되살아나므로 트레이스 관찰 중에는 0으로 줄였다

## 트레이스 관찰
분석 원칙(사실과 추정 구분, 이벤트·속성까지 확인, 브라우저-서버 시계 차이)은 [CLAUDE.md](../../CLAUDE.md) 8장에 정리했다.

### 1단계: 서비스 직접 호출 (2026-10-29)
- quote, shipping을 클러스터 안에서 직접 호출해 트레이스 구조를 확인 (quote 트레이스 `67762f597c6b5c14c3fbb53b5278fdca`)
- server/client 스팬 구분, 자동 계측과 수동 계측 스팬의 차이를 확인
- 이 과정에서 관측 데이터 품질 문제 OBS-1~3을 발견

### 2단계: 화면 동작별 관찰 (2026-10-30)
홈 → 상품 클릭 → 장바구니 담기 → 주문 순서로 실제 브라우저에서 동작하며 트레이스를 확인했다. 통화 변경은 생략.

| 동작 | 대표 트레이스 | 확인한 것 |
|---|---|---|
| 홈 | `84ded7d59d5a1d77ff8b68c7ffdccc73` (documentLoad) | 페이지가 하나의 트레이스로 묶이지 않음. HTML 로드와 JS가 부르는 API가 각각 별도 트레이스 |
| 장바구니 | `d4a36463…` | 첫 연결에서만 `dns.lookup`/`tcp.connect` 스팬이 생김 |
| 주문 | `54e11879d961993975e9bdfbbca50178` (스팬 58개) | checkout의 직렬 호출, Kafka로 넘어간 뒤 accounting(`f3ca251ef174ad828fc9a26754374ccc`)·fraud-detection(`1eeb8fe00b778d07e6539ebab8569c6e`)이 `FOLLOWS_FROM` 링크로 이어지는 별도 트레이스 |

발견한 패턴
- 서비스 간 호출에서 처리 시간보다 연결·대기 비용이 큰 구간이 있다(`dns.lookup`/`tcp.connect`는 첫 연결 때만)
- 추천 서비스의 N+1 호출(추천 5개 중 frontend가 4개를 다시 조회)
- checkout 내부에 계측되지 않은 구간 약 70ms
- payment·cart가 flagd에 원격으로 플래그를 질의하는 비용
- 브라우저와 서버의 시계 차이 약 0.88초(사용자 PC가 빠름). 브라우저 스팬과 서버 스팬은 시작 시각이 아니라 소요 시간으로만 비교

설명하지 못한 것
- checkout POST에서 브라우저와 Envoy 사이 약 110ms (ALB 로그 없이는 확인 불가)
- 요청이 몰릴 때 proxy → frontend 사이 6~8ms 공백

### 관찰 중 고친 것: 브라우저 트레이스 수집 (OBS-4)
- 브라우저 텔레메트리 전송 주소가 `http://localhost:8080/...`(port-forward 전제)라 ALB로 접속한 실제 브라우저의 트레이스가 수집되지 않았다.
- `PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`를 상대 경로 `/otlp-http/v1/traces`로 바꿔 해결. 상세: [observability-findings.md](../observability-findings.md) OBS-4

## 발견한 관측 데이터 품질 문제
[observability-findings.md](../observability-findings.md)에 기록. Phase 3-A에서 수정.

| ID | 문제 |
|---|---|
| OBS-1 | `host.name`이 Collector 파드 이름으로 덮어써짐 |
| OBS-2 | quote, cart, accounting 스팬에 쿠버네티스 메타데이터 없음 |
| OBS-3 | 브라우저 스팬에 frontend-proxy 파드 메타데이터가 붙음 |
| OBS-4 | 실제 사용자 브라우저 트레이스 미수집 (Phase 2에서 해결) |
| OBS-5 | accounting 소비 스팬이 메시지 대기 시간(약 55분)까지 포함 (데모 코드 영역, 기록만) |

## 증거
Phase 5 장애 시나리오와 비교할 **정상 주문 트레이스** `54e11879d961993975e9bdfbbca50178` 화면 캡처
- [전체 화면](../evidence/phase2/normal-order-trace-full.png): 브라우저 스팬까지 포함. 시계 차이 때문에 가로축이 1.1초로 늘어나 서버 막대가 왼쪽에 몰림
- [서버 구간 확대](../evidence/phase2/normal-order-trace-server-zoom.png): 미니맵에서 2.6ms~188ms 구간을 선택. checkout의 직렬 계단 구조가 보임

## 완료 기준
- [x] ALB 주소로 쇼핑몰 접속
- [x] load-generator 트래픽 흐름
- [x] Jaeger에서 트레이스 확인 (서비스 21개, 주문 트레이스)
