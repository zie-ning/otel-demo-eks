# 관측 데이터 품질 점검 기록

Phase 2에서 데모를 차트 기본 구성으로 배포한 뒤, Jaeger 트레이스를 직접 분석하며 발견한 **텔레메트리 데이터 품질 문제**를 기록한다.
인프라 구축 중 겪은 문제(무료 플랜 인스턴스 거부, PowerShell stderr 처리 등)는 [operations.md](operations.md)의 문제 해결 항목에 있다.

| ID | 문제 | 영향 | 상태 |
|---|---|---|---|
| OBS-1 | 모든 스팬의 `host.name`이 앱이 아닌 Collector 파드 이름으로 덮어써짐 | 실행 위치 판단 오류 | 미해결 (Phase 3) |
| OBS-2 | quote, cart 스팬에 쿠버네티스 메타데이터(`k8s.*`)가 붙지 않음 | 파드·노드 단위 장애 분석 불가 | 미해결 (Phase 3) |
| OBS-3 | 브라우저(`frontend-web`) 스팬에 frontend-proxy 파드의 메타데이터가 붙음 | 브라우저 데이터를 서버 파드로 오인 | 미해결 (Phase 3) |

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

### 해결 방향
- `service.name = frontend-web`인 데이터에는 쿠버네티스 메타데이터를 붙이지 않도록 Collector에서 예외 처리하거나, 붙은 속성을 제거한다.
- 수정 후 실제로 어떤 속성이 붙어 있었는지 다시 확인해 원인 추정을 검증한다.

---

## 검증 방법 (수정 후 재확인)
```powershell
# 서비스별 k8s.pod.name 부착 여부와 host.name 값 집계 (Jaeger API)
# 확인 기준: 모든 서버 서비스에 k8s.pod.name 존재, frontend-web에는 없음, host.name이 Collector 파드 이름이 아님
```
수정 전후를 같은 방식으로 집계해 이 문서에 결과를 추가한다.
