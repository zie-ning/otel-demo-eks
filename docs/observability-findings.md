# 관측 데이터 품질 점검 기록

Phase 2에서 데모를 차트 기본 구성으로 배포한 뒤, Jaeger 트레이스를 직접 분석하며 발견한 **텔레메트리 데이터 품질 문제**를 기록한다.
인프라 구축 중 겪은 문제(무료 플랜 인스턴스 거부, PowerShell stderr 처리 등)는 [operations.md](operations.md)의 문제 해결 항목에 있다.

| ID | 문제 | 영향 | 상태 |
|---|---|---|---|
| OBS-1 | 모든 스팬의 `host.name`이 앱이 아닌 Collector 파드 이름으로 덮어써짐 | 실행 위치 판단 오류 | **해결** (2026-10-30, #1) |
| OBS-2 | quote, cart, accounting 스팬에 쿠버네티스 메타데이터(`k8s.*`)가 붙지 않음 | 파드·노드 단위 장애 분석 불가 | 미해결 (Phase 3-A ②, #2) |
| OBS-3 | 브라우저(`frontend-web`) 스팬에 frontend-proxy 파드의 메타데이터가 붙음 | 브라우저 데이터를 서버 파드로 오인 | **해결** (2026-10-30, #3) |
| OBS-4 | 실제 사용자 브라우저의 트레이스가 수집되지 않음 (전송 주소가 `localhost:8080`) | 사용자 체감 지연과 브라우저 구간 관측 불가 | **해결** (2026-10-30) |
| OBS-5 | accounting의 `order-consumed` 스팬이 메시지 대기 시간까지 포함해 55분짜리로 기록됨 | 소요 시간 통계 왜곡, 트레이스 화면 축이 비정상적으로 길어짐 | 기록만 (데모 코드 영역) |
| OBS-6 | ALB 헬스체크가 15초마다 frontend-proxy → frontend 트레이스를 만듦 | 실제 트래픽 트레이스가 묻히고 요청 수·지연 지표 왜곡 | **해결** (2026-10-30, #4) |

환경: 차트 `opentelemetry-demo` 0.42.6 (앱 3.1.0), Collector는 DaemonSet 모드(노드마다 1개), 확인일 2026-10-29

---

## OBS-1. host.name이 Collector 파드 이름으로 덮어써짐

### 증상
quote 직접 호출 트레이스(`67762f597c6b5c14c3fbb53b5278fdca`)의 리소스 속성:
```
host.name = otel-collector-agent-4kkfp   ← quote가 아니라 Collector 파드 이름
```
다른 서비스도 모두 자기를 받은 Collector 파드 이름(`otel-collector-agent-4kkfp`, `otel-collector-agent-xgcg8` 등)으로 찍혀 있었다.

### 원인
Collector traces 파이프라인의 `resource_detection` 프로세서:
```yaml
resource_detection:
  detectors: [env, system]
```
- `system` 감지기는 **Collector가 실행 중인 호스트의 이름**을 `host.name`으로 설정한다. 쿠버네티스에서 파드의 호스트 이름은 파드 이름이다.
- 감지기의 기본 동작이 기존 값 덮어쓰기라서, 앱이 보낸 값과 관계없이 Collector 파드 이름으로 바뀐다.

### 영향
- `host.name`이 "앱이 실행된 곳"이 아니라 "데이터를 받은 Collector"를 가리킨다.
- Collector가 노드당 하나라 간접적으로 노드를 추정할 수는 있지만, 속성 이름의 의미와 실제 값이 달라 분석 시 오해를 부른다.

### 해결 방향
- `resource_detection`에서 `system` 감지기를 빼거나 덮어쓰기(`override`)를 끈다.
- 노드 식별은 `k8s.node.name`(OBS-2 해결 후)으로 일원화한다.

### 해결 (2026-10-30)
`helm/values/otel-demo.yaml`의 `opentelemetry-collector.config`:
- `resource_detection.detectors`를 `[env]`로 바꿔 `system` 감지기를 뺐다.
- `resource` 프로세서에서 `host.name`을 Collector의 `K8S_NODE_NAME`(실행 노드 이름)으로 `upsert`한다. Collector가 DaemonSet이고 앱은 같은 노드의 Collector로 보내므로(`internalTrafficPolicy: Local`) Collector 노드 = 앱 노드다.
- 그냥 지우지 않은 이유: hostmetrics(노드 CPU·메모리)처럼 리소스 속성 없이 들어오는 데이터도 노드를 구분할 수 있어야 한다. Collector 자체 텔레메트리도 차트 기본값으로 `host.name`에 노드 이름을 쓴다.
- 앱이 직접 보낸 `host.name`이 있어도 노드 이름으로 바뀐다. 파드 구분은 `k8s.pod.name`으로 한다.

결과: `host.name`이 Collector 파드 이름인 서비스 **20개 → 0개**. 예: quote `ip-10-0-0-147…`(quote 파드가 실제로 있는 노드).

---

## OBS-2. quote, cart 스팬에 쿠버네티스 메타데이터가 없음

### 증상
최근 1시간 트레이스를 서비스별로 집계한 결과:
```
quote   k8s.pod.name 있음 0 / 없음 57
cart    k8s.pod.name 있음 0 / 없음 11
그 외 서비스(frontend, frontend-proxy, shipping, checkout, currency, payment, email, flagd, product-catalog)는 모두 있음
```

### 원인
Collector의 `k8s_attributes` 프로세서는 데이터를 보낸 파드를 아래 순서의 규칙으로 찾는다.
```yaml
pod_association:
  - container.id   (리소스 속성)
  - k8s.pod.ip     (리소스 속성)
  - k8s.pod.uid    (리소스 속성)
  - connection     (데이터를 보낸 연결의 IP)
```
- 대부분의 서비스는 `container.id`를 보내지 않아 마지막 규칙(연결 IP = 파드 IP)으로 파드를 찾는다.
- quote(PHP)와 cart(.NET)는 SDK가 `container.id`를 스스로 감지해 보내는데, **그 값이 실제 컨테이너 ID와 다르다.**

| 서비스 | 앱이 보낸 container.id | 쿠버네티스 실제 containerID |
|---|---|---|
| quote | `47dd0169a21e…` | `aff2481ef371…` |
| cart | `171fda072aa6…` | `3b4dbfccd076…` |

- 첫 규칙에 해당하는 값이 있으므로 그 ID로 파드를 찾고, 일치하는 컨테이너가 없어 실패한다. 다음 규칙으로 넘어가지 않아 메타데이터 없이 통과한다.
- 잘못된 ID는 SDK가 컨테이너 런타임 정보를 읽다가 같은 파드의 다른 컨테이너(파드 샌드박스 등) ID를 가져온 것으로 추정한다. **값 불일치는 확인했고, 어떤 컨테이너의 ID인지는 미확인.**

### 추가 확인 (2026-10-30, 클러스터 재생성 후)
- 클러스터를 새로 만든 뒤에도 cart(`container.id = 3f004740…`)에 쿠버네티스 메타데이터가 없어 같은 문제가 재현된다.
- **accounting(.NET 자동 계측)도 같은 문제**를 확인했다. 주문 트레이스에 링크된 accounting 트레이스(`f3ca251ef174ad828fc9a26754374ccc`)의 리소스에 `container.id = a4792d4f…`는 있고 `k8s.*` 속성은 없다. 처음 집계(quote, cart)에서는 accounting 트레이스가 표본에 없어 놓쳤다.
- 같은 .NET이라도 SDK가 `container.id`를 감지해 보내는 서비스(cart, accounting)가 영향을 받는다. 같은 클러스터의 Java(ad, fraud-detection), Go, Rust, Node.js 서비스는 정상이다.

### 확인한 것과 배제한 것
- Collector Service의 `internalTrafficPolicy`는 `Local`이라, 앱은 같은 노드의 Collector로 보낸다. "다른 노드의 Collector가 받아서 파드를 못 찾는다"는 가설은 배제했다.
- 같은 노드(ip-10-0-0-170)의 shipping, currency는 정상적으로 메타데이터가 붙는다. 노드나 Collector 인스턴스 문제가 아니라 서비스별 차이다.

### 영향
- quote, cart 장애 시 "어느 파드, 어느 노드에서 발생했나"를 텔레메트리만으로 판단할 수 없다.
- cart는 장바구니 경로라 Phase 5 시나리오(cartFailure 등)에 직접 영향이 있다.

### 해결 방향
1. (권장) 쿠버네티스 Downward API로 각 앱에 자기 파드 UID와 IP를 환경변수로 주입하고 `OTEL_RESOURCE_ATTRIBUTES`에 `k8s.pod.uid`, `k8s.pod.ip`를 넣는다. 감지 방식에 의존하지 않는 확실한 매칭이 된다.
2. 또는 `pod_association`에서 `container.id` 규칙을 빼거나 마지막으로 옮긴다.

---

## OBS-3. 브라우저 스팬에 frontend-proxy 파드 메타데이터가 붙음

### 증상
`frontend-web`(사용자 브라우저에서 실행되는 JavaScript) 스팬 41건 모두에 `k8s.pod.name` 등 쿠버네티스 메타데이터가 붙어 있다. 브라우저는 파드가 아니다.

### 원인 (추정)
- 브라우저 텔레메트리는 frontend-proxy의 `/otlp-http/` 경로를 거쳐 Collector로 들어온다.
- `k8s_attributes`의 마지막 규칙(연결 IP)이 **연결을 맺은 frontend-proxy 파드**를 데이터의 출처로 판단해 그 파드의 메타데이터를 붙인 것으로 본다.
- 연결 IP 기반 매칭은 프록시를 거치는 구조에서 출처를 잘못 판단할 수 있다.

### 영향
- 브라우저 데이터를 frontend-proxy 파드에서 발생한 것으로 오인할 수 있다. 예를 들어 파드별 집계에서 frontend-proxy 수치가 부풀려진다.

### 실제 사용자 트래픽으로 재확인 (2026-10-30, OBS-4 수정 후)
실제 브라우저의 `documentLoad` 트레이스(`84ded7d59d5a1d77ff8b68c7ffdccc73`) 리소스 속성:
```
browser.language     = ko                                  ← 브라우저가 보낸 값
user_agent.original  = … Claude/4.29.0 Chrome/152 …        ← 브라우저가 보낸 값
container.image.tag  = 3.1.0-frontend-proxy                ← Collector가 붙인 값 (잘못됨)
k8s.deployment.name  = frontend-proxy                      ← 〃
k8s.pod.name         = frontend-proxy-64b96f69f7-jng29     ← 〃
k8s.node.name        = ip-10-0-0-147…                      ← 〃
```
브라우저 데이터에 frontend-proxy 파드 정보가 붙는 것을 실제 사용자 트래픽에서도 확인했다. 연결 IP 기반 매칭이 원인이라는 추정과 일치한다.

### 해결 방향
- `service.name = frontend-web`인 데이터에는 쿠버네티스 메타데이터를 붙이지 않도록 Collector에서 예외 처리하거나, 붙은 속성을 제거한다.

### 해결 (2026-10-30)
- `k8s_attributes`에는 서비스별 예외 설정이 없어, 붙은 뒤에 지우는 방식을 택했다.
- traces 파이프라인의 `resource` 다음에 `transform/browser_resource`를 추가해 `service.name == "frontend-web"`이면 `k8s.*`, `container.*`, `host.name`, `service.instance.id`(프록시 파드 값 `otel-demo.frontend-proxy-…`가 들어가 있었음)를 지운다. `resource` 앞에 두면 `host.name`이 다시 붙는다.
- 같은 처리를 **metrics 파이프라인에도** 넣었다. 브라우저 스팬으로 만든 span metrics가 metrics 파이프라인의 `resource`를 지나며 `host.name`(노드 이름)이 다시 붙기 때문이다. 처음 배포 후 Prometheus `target_info{service_name="frontend-web"}`에 `host_name=ip-10-0-1-105…`가 붙은 것을 확인했다(PR #5 CodeRabbit 리뷰로 발견).
  - 재배포 후(11:34 이후 load-generator 4분): `frontend-web`의 `target_info`와 span metrics에 `host_name`, `k8s_pod_name` 없음. hostmetrics(`system_cpu_time_seconds_total`)는 노드 3개의 `host_name`을 그대로 유지.

결과: `frontend-web`의 `k8s.pod.name` 부착 **50/50 → 0/50**. 남은 리소스 속성은 브라우저가 보낸 `browser.language`, `user_agent.original`과 `service.namespace`, `service.version`뿐이다(트레이스 `0c708fe9cfab43f18298cd4987ea6400`).

---

## OBS-4. 실제 사용자 브라우저의 트레이스가 수집되지 않음

### 증상 (2026-10-30)
- ALB 주소로 쇼핑몰 홈을 열었지만 `frontend-web` 트레이스가 하나도 생기지 않았다. 이 시점까지 쌓인 `frontend-web` 트레이스 74건은 모두 load-generator의 헤드리스 브라우저(`HeadlessChrome`, `k8s.deployment.name=load-generator`)가 만든 것이었다.
- 브라우저 네트워크 기록:
```
POST http://localhost:8080/otlp-http/v1/traces  [FAILED: net::ERR_BLOCKED_BY_CLIENT]  (30건 이상)
```

### 원인
frontend 컨테이너의 환경변수:
```
PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT = http://localhost:8080/otlp-http/v1/traces
```
- 차트 기본값은 `kubectl port-forward`로 로컬에서 접속하는 상황을 가정한다.
- ALB로 접속한 실제 사용자 브라우저는 **자기 PC의 localhost:8080**으로 보내려다 실패한다. Claude 앱의 브라우저 패널에서는 `ERR_BLOCKED_BY_CLIENT`로 차단되고, 일반 브라우저라면 연결 거부가 된다.

### 영향
- 각 요청의 트레이스가 frontend-proxy에서 시작해, 브라우저 ↔ ALB 구간(인터넷 왕복)이 빠진다.
- 사용자 화면에서 체감하는 로딩 시간(문서 로드, 리소스 로딩)을 관측할 수 없다.

### 해결 (2026-10-30)
`helm/values/otel-demo.yaml`에서 `components.frontend.envOverrides`로 값을 **상대 경로** `/otlp-http/v1/traces`로 바꿨다. 브라우저는 접속한 ALB 주소를 기준으로 보내고, frontend-proxy가 `/otlp-http/` 경로를 Collector로 전달한다. ALB 주소가 바뀌어도 값을 고칠 필요가 없다.

### 수정 후 확인 결과
- 브라우저의 `window.ENV.NEXT_PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT = "/otlp-http/v1/traces"`, 실제 전송 주소는 `http://<ALB>/otlp-http/v1/traces`
- 홈 화면을 한 번 새로 고친 뒤 3분 동안 `frontend-web` 트레이스 17건이 수집되었고, 모두 실제 브라우저(`user_agent`에 `Claude/…Chrome/152`)에서 나왔다.
- 트레이스 구조:
  - `documentLoad` 트레이스 1건(스팬 25개): HTML 받기(`documentFetch` 21.9ms)와 JS·CSS·이미지 `resourceFetch`
  - 브라우저가 부른 API마다 **별도 트레이스**(루트가 `frontend-web [client] GET`): `/api/cart`, `/api/products`, `/api/currency`, flagd `ResolveAll`, 이미지
- 처음 예상과 달리 **페이지 전체가 하나의 트레이스로 묶이지는 않는다.** 페이지 로드 후 JavaScript가 따로 보내는 요청은 `documentLoad`의 자식이 아니라 각자 새 트레이스로 시작한다.
- `/api/cart` 예: 브라우저 기준 71ms, 서버(frontend-proxy) 기준 28.2ms → 약 43ms가 브라우저 ↔ ALB 구간(인터넷 왕복 등)에 쓰였다. 이 구간은 수정 전에는 보이지 않았다.

### 남은 확인 사항
- 브라우저 스팬의 시작 시각이 서버 스팬보다 약 0.8초 늦게 찍힌다. 사용자 PC와 서버의 **시계 차이(clock skew)**로 보이며, 구간별 지연을 계산할 때는 각 스팬의 소요 시간(duration)만 비교해야 한다.
- OBS-3(브라우저 스팬에 프록시 파드 메타데이터 부착)을 실제 사용자 트래픽으로 다시 확인한다.

---

## OBS-5. accounting의 소비 스팬이 대기 시간까지 포함함

### 증상 (2026-10-30)
사용자 주문(`54e11879d961993975e9bdfbbca50178`)을 처리한 accounting 트레이스(`f3ca251ef174ad828fc9a26754374ccc`):
```
accounting [internal] order-consumed   시작 09:23:18.827   소요 3,303,176ms (약 55분)
  accounting [consumer] receive orders   (주문 트레이스로 FOLLOWS_FROM 링크)   28.3ms
  accounting [client]   astronomy_db                                           11.8ms
  accounting [client]   astronomy_db   INSERT INTO accounting."order" …          2.6ms
```

### 원인 (추정)
- 루트 스팬 `order-consumed`가 **다음 메시지를 기다리기 시작한 시점**에 열리고, 메시지를 처리한 뒤 닫히는 구조로 보인다.
- 클러스터 생성 후(09:23) 첫 주문이 10:18에 들어와서, 대기 55분이 그대로 스팬 소요 시간이 되었다.

### 영향
- 소요 시간 기반 통계(평균, p95)나 span metrics가 크게 왜곡된다.
- 실제 처리 시간(약 30~40ms)과 대기 시간이 구분되지 않는다.

### 대응
- 데모 애플리케이션 코드의 계측 방식 문제라 이 프로젝트에서는 수정하지 않고, **대시보드·알림에서 이 스팬을 처리 시간 지표로 쓰지 않도록** 주의한다. 처리 시간은 `receive orders` 이하 스팬으로 본다.

---

## OBS-6. ALB 헬스체크 트레이스가 실제 트래픽을 가림

### 증상 (2026-10-30)
- ALB 대상 그룹 헬스체크(`GET /`, `User-Agent: ELB-HealthChecker/2.0`, 15초 간격)가 frontend-proxy → frontend를 거치며 매번 트레이스를 만든다.
- load-generator 0개 상태에서 frontend-proxy 트레이스 500건 중 **261건**이 헬스체크였다.
- 헬스체크 트레이스 1건은 스팬 6개(frontend-proxy 2, frontend 4)다(예: `2f7224c1b0727deaa3f1572691970f37`).

### 영향
- 실제 사용자 트래픽 트레이스가 Jaeger 검색 결과에서 묻힌다.
- 요청 수·지연 지표(span metrics, Phase 4 SLO)에 헬스체크가 섞인다.

### 검토한 방법
- **Collector `filter` 프로세서로 제거 (기각)**: User-Agent 값은 6개 스팬 중 2개(frontend-proxy 서버 스팬, frontend 첫 서버 스팬)에만 있다. 필터는 스팬 단위로 동작해 나머지 4개가 부모 없는 스팬으로 남는다. 트레이스 단위로 지우려면 tail sampling용 게이트웨이 Collector가 필요하다.
- **Envoy 설정에서 헬스체크 경로만 트레이싱 제외 (기각)**: Envoy 설정이 이미지 안 템플릿으로 생성되어, 바꾸려면 설정 파일 전체를 덮어써야 한다.
- **헬스체크를 Envoy 관리 포트로 이동 (채택)**: 관리 포트(`10000`) 요청은 트레이싱·액세스 로그 경로(HTTP connection manager)를 거치지 않는다.

### 해결 (2026-10-30)
- Ingress 어노테이션 `alb.ingress.kubernetes.io/healthcheck-port: "10000"`, `healthcheck-path: /ready`
- 확인: 대상 그룹 헬스체크가 `10000 /ready`로 바뀌고 대상 `healthy`. LB Controller가 노드 보안그룹에 ALB 백엔드 보안그룹 → `8080-10000` 규칙을 추가했다.
- 결과: frontend-proxy 트레이스 중 헬스체크 **261/500 → 0/500**.
- 대가: 헬스체크가 frontend까지는 확인하지 않고 Envoy 생존만 본다. ALB 입장의 대상은 Envoy라 의미상 맞지만, frontend 장애는 ALB 헬스체크가 아니라 관측 스택(Phase 4 알림)으로 잡아야 한다.

---

## 검증 방법 (수정 후 재확인)
```powershell
# 서비스별 k8s.pod.name 부착 여부, host.name이 Collector 파드 이름인지, 헬스체크 트레이스 수 집계 (Jaeger API)
.\scripts\check-resource-attributes.ps1 -JaegerUrl http://<ALB 주소>/jaeger/ui -Lookback 3h
.\scripts\check-resource-attributes.ps1 -JaegerUrl http://<ALB 주소>/jaeger/ui -Since '2026-10-30 11:11:53'   # 배포 이후만
```
확인 기준: 모든 서버 서비스에 `k8s.pod.name` 존재, `frontend-web`에는 없음, `host.name`이 Collector 파드 이름이 아님, 헬스체크 트레이스 0건

### Phase 3-A ① 전후 비교 (2026-10-30)
수정 전은 최근 3시간, 수정 후는 배포(11:11:53) 이후 load-generator 3분 실행 구간. 서비스별 최대 50 트레이스.

| 항목 | 수정 전 | 수정 후 |
|---|---|---|
| `host.name`이 Collector 파드 이름인 서비스 | 20 / 20 | **0** / 18 |
| `frontend-web`에 `k8s.pod.name` | 50 / 50 | **0** / 50 |
| `k8s.pod.name` 없는 서버 서비스 | cart, quote, accounting | cart, quote, accounting (OBS-2, ② 대상) |
| frontend-proxy 트레이스 중 헬스체크 | 261 / 500 | **0** / 500 |
