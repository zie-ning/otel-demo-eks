# 인프라 운영 지침

이 클러스터는 **필요할 때만 띄우고 작업이 끝나면 지우는** 방식으로 운영한다.
이 문서는 켜고 끄는 절차, 지켜야 할 규칙, 비용 관리, 문제 해결 방법을 정리한다.

---

## 1. 스택 구조

| 스택 | 경로 | 내용 | state 위치 | 수명 |
|---|---|---|---|---|
| 00-bootstrap | `terraform/00-bootstrap` | Terraform state용 S3 버킷, AWS Budgets 알림 | **로컬** `terraform.tfstate` | **영구. 지우지 않는다** |
| 01-cluster | `terraform/01-cluster` | VPC(퍼블릭 서브넷, NAT 없음), EKS, 노드그룹(app 2대 / monitoring 1대), 코어 애드온 | S3 `01-cluster/terraform.tfstate` | 작업할 때만 |
| 02-addons | `terraform/02-addons` | AWS Load Balancer Controller, metrics-server | S3 `02-addons/terraform.tfstate` | 작업할 때만 |

**순서**
- 생성: `01-cluster` → kubeconfig 갱신 → `02-addons` → 관측 스택(`deploy-observability.ps1`) → 데모(`deploy-demo.ps1`)
- 삭제: (Ingress·LoadBalancer Service 삭제) → `02-addons` → `01-cluster`

`02-addons`는 `01-cluster`의 출력값(클러스터 이름, VPC ID)을 S3 state에서 읽는다. 그래서 `01-cluster`가 먼저 있어야 한다.

### 노드그룹

| 노드그룹 | 타입 × 수 | 라벨 / taint | 용도 |
|---|---|---|---|
| app | m7i-flex.large × 2 | `role=app` | OTel Demo 서비스, 시스템 파드 |
| monitoring | m7i-flex.large × 1 | `role=monitoring`, taint `dedicated=monitoring:NoSchedule` | Prometheus, Grafana, Tempo, Loki, OTel Collector |

- 관측 스택 파드에는 위 taint에 대한 toleration과 `nodeSelector: role=monitoring`을 지정한다.
- node-exporter, 로그 수집기 같은 DaemonSet은 모든 노드에서 떠야 하므로 toleration만 지정한다.
- 계정이 AWS **무료 플랜**이라 프리티어 대상 인스턴스(m7i-flex.large 등)만 실행할 수 있다. 유료 플랜으로 전환하면 `node_instance_types`를 바꿀 수 있다.

---

## 2. 일상 운영 절차

모든 명령은 저장소 루트에서 Windows PowerShell로 실행한다.

### 작업 시작
```powershell
.\scripts\up.ps1
```
1. 현재 공인 IP를 확인해 `terraform/01-cluster/admin.auto.tfvars`에 기록한다. API 엔드포인트 허용 목록이 갱신된다.
2. `01-cluster` apply → kubeconfig 갱신 → `02-addons` apply
3. `kubectl get nodes`로 노드 상태를 출력한다.

- 소요 시간: 처음 생성할 때 약 15~20분
- 각 apply는 plan을 보여주고 `yes` 입력을 기다린다. 확인 없이 진행하려면 `-AutoApprove`를 붙인다.

### 관측 스택 배포 (데모보다 먼저)
```powershell
.\scripts\deploy-observability.ps1            # monitoring 네임스페이스에 kube-prometheus-stack, Tempo, Loki 설치/업그레이드
.\scripts\deploy-observability.ps1 -Template  # 렌더링 결과만 확인
```
- values: `helm/values/kube-prometheus-stack.yaml`, `tempo.yaml`, `loki.yaml`. 데모 대시보드·알림: `helm/grafana/` (kustomize, server-side apply)
- Collector가 이 스택으로 보낸다: 메트릭 → Prometheus(`kps-prometheus.monitoring:9090`), 트레이스 → Tempo(`tempo.monitoring:4317`), 로그 → Loki(`loki.monitoring:3100/otlp`). 그래서 데모보다 먼저 설치한다. 순서가 바뀌어도 데모는 동작하지만, 설치 전까지 Collector 로그에 전송 실패가 쌓인다.
- 저장소는 모두 emptyDir라 파드가 재시작·교체되거나 클러스터를 지우면 데이터와 Grafana에서 직접 고친 내용이 사라진다(Tempo·Loki는 재배포로 파드가 교체될 때도 사라짐). 대시보드 수정은 `helm/grafana/`에 반영하고, 증거는 삭제 전에 저장한다.
- Grafana: `http://<ALB 주소>/grafana/`. 대시보드 폴더는 **OpenTelemetry Demo**(데모 앱)와 **Kubernetes**(클러스터·노드). 익명은 대시보드 읽기만 가능하고, **Explore(트레이스·로그 조회, 지표 → 트레이스 → 로그 링크 이동)는 `admin` 로그인이 필요**하다. 비밀번호는 스크립트가 처음 설치할 때 무작위로 만든다(Git에 없음).
  ```powershell
  $s = kubectl get secret grafana-admin -n monitoring -o json | ConvertFrom-Json
  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s.data.'admin-password'))
  ```
- Prometheus·Alertmanager·Tempo·Loki는 외부에 노출하지 않는다. Grafana 데이터소스로 조회하고, API가 필요하면 `kubectl port-forward -n monitoring svc/kps-prometheus 9090`(Tempo `svc/tempo 3200`, Loki `svc/loki 3100`)
- Grafana 데이터소스 uid: `webstore-metrics`(Prometheus), `webstore-traces`(Tempo), `webstore-logs`(Loki). 데모 대시보드가 이 uid를 참조하므로 바꾸지 않는다.

### 데모 배포
```powershell
.\scripts\deploy-demo.ps1            # 설치/업그레이드 (차트 버전 고정, 모든 파드 Ready까지 대기)
.\scripts\deploy-demo.ps1 -Template  # 클러스터에 적용하지 않고 렌더링 결과만 확인
```
- values: `helm/values/otel-demo.yaml` (커밋), ALB 허용 IP는 실행 시 `helm/values/otel-demo.local.yaml`로 생성 (커밋 안 함)
- 접속 주소: `kubectl get ingress -n otel-demo`의 ADDRESS. ALB는 생성 후 2~3분 뒤부터 응답한다
- 경로: `/`(쇼핑몰), `/grafana/`(kube-prometheus-stack의 Grafana), `/feature/`(장애 플래그), `/loadgen/`(Locust). `/jaeger/ui/`는 차트가 경로를 남기지만 내장 Jaeger를 꺼서 503이다(트레이스는 Grafana에서 Tempo로 본다)

### 작업 종료
```powershell
.\scripts\down.ps1
```
1. 모든 Ingress와 LoadBalancer Service를 삭제하고, 이 클러스터가 만든 로드밸런서가 사라질 때까지 최대 5분 기다린다.
2. `02-addons` destroy → `01-cluster` destroy
3. 클러스터와 EC2 인스턴스가 남아 있지 않은지 확인한다.

### 종료 후 체크리스트
- [ ] `down.ps1`이 "삭제 완료" 메시지로 끝났다
- [ ] EC2 콘솔에서 `otel-demo` 노드 인스턴스가 없다
- [ ] EC2 → 로드밸런서에 `k8s-` 로 시작하는 ALB가 없다
- [ ] 실험 결과(스크린샷, 대시보드 export, 트레이스 ID)를 저장했다. 클러스터를 지우면 메트릭·로그·트레이스도 함께 사라진다

---

## 3. 반드시 지킬 규칙

1. **작업이 끝나면 그날 바로 `down.ps1`을 실행한다.** 켜둔 채 잊으면 하루에 약 $12, 한 달이면 약 $360이 나온다.
2. **Ingress로 생긴 ALB는 Terraform이 모르는 리소스다.** 클러스터보다 먼저 지워야 한다. 직접 지울 때도 `kubectl delete ingress`를 먼저 하고 `terraform destroy`를 나중에 한다.
3. **AWS 콘솔에서 Terraform 리소스를 직접 바꾸지 않는다.** state와 실제 상태가 어긋나 다음 apply나 destroy가 실패한다. 바꿀 것이 있으면 코드를 고친다.
4. **커밋하지 않는 파일**(`.gitignore`로 제외됨)
   - `*.tfstate`, `*.tfvars`(이메일, IP 포함). 예시 파일 `*.tfvars.example`만 커밋한다
   - kubeconfig, `*.pem`, `.env`
   - `.terraform.lock.hcl`은 provider 버전을 고정하므로 **커밋한다**
5. **00-bootstrap은 지우지 않는다.** state 버킷에는 `prevent_destroy`가 걸려 있다. 버킷을 잃으면 01·02 스택을 Terraform으로 지울 수 없게 된다.
6. **00-bootstrap의 로컬 state(`terraform/00-bootstrap/terraform.tfstate`)는 따로 백업한다.**
7. **AWS 자격 증명은 `terraform-admin` 프로필만 쓴다.** 액세스 키를 코드나 문서에 적지 않는다.

---

## 4. 비용 관리

| 항목 | 기준 |
|---|---|
| 시간당 비용 | 약 $0.50 (EKS $0.10 + m7i-flex.large 3대 × $0.118 + EBS + 퍼블릭 IPv4 + ALB) |
| 월 예산 | $40 (`otel-demo-monthly`) |
| 알림 | 실제 $20(50%), 실제 $40(100%), 예상 $40 초과 → `budget_alert_email`로 메일. **크레딧 차감 전 금액** 기준 |
| 무료 플랜 크레딧 | 2026-10-29 기준 잔액 $31.19, 만료 2027-01-13. 소진·만료 시 유료 플랜으로 전환하지 않으면 계정이 정지된다 |
| 꺼져 있을 때 | S3 state 버킷 비용만 발생 (사실상 무료) |

크레딧 잔액 확인:
```powershell
aws freetier get-account-plan-state --region us-east-1 --profile terraform-admin
```

- 예산 알림은 **실시간이 아니다.** 비용 데이터 반영과 평가 주기 때문에 반나절 정도 늦게 올 수 있다.
- 예산은 **상한선이 아니다.** 넘어도 리소스가 멈추지 않는다.

**알림을 받았을 때**
1. EKS 콘솔에서 `otel-demo` 클러스터가 남아 있는지 확인한다. 남아 있으면 `down.ps1`을 실행한다.
2. Cost Explorer에서 서비스별 비용을 확인하고, 예상보다 큰 항목이 있으면 원인을 찾는다.
3. 이번 달 남은 작업 시간을 다시 계획한다. $40은 약 80시간이다.

---

## 5. 문제 해결

### 공인 IP가 바뀌어 kubectl 접속이 안 된다
증상: `kubectl` 명령이 타임아웃되거나 `dial tcp ... i/o timeout`

원인: API 엔드포인트는 등록한 IP만 허용한다. 집이나 카페 등 네트워크가 바뀌면 IP도 바뀐다.

해결: `.\scripts\up.ps1`을 다시 실행한다. 바뀐 IP로 `admin.auto.tfvars`가 갱신되고, 01-cluster apply가 엔드포인트 허용 목록만 수정한다(클러스터 재생성 없음).

### destroy가 VPC나 서브넷에서 오래 멈춘다
증상: `module.vpc.aws_subnet...: Still destroying...`이 계속되다가 `DependencyViolation` 오류

원인: Terraform 바깥에서 만들어진 리소스(ALB, 그 보안 그룹, ENI)가 서브넷을 붙잡고 있다.

해결:
```powershell
# 이 클러스터가 만든 로드밸런서 확인 (태그 elbv2.k8s.aws/cluster=otel-demo)
aws elbv2 describe-load-balancers --profile terraform-admin --query "LoadBalancers[].[LoadBalancerName,VpcId]" --output table

# VPC에 남은 ENI 확인
aws ec2 describe-network-interfaces --profile terraform-admin --filters Name=vpc-id,Values=<VPC_ID> --query "NetworkInterfaces[].[NetworkInterfaceId,Description,Status]" --output table

# k8s-로 시작하는 보안 그룹 확인
aws ec2 describe-security-groups --profile terraform-admin --filters Name=vpc-id,Values=<VPC_ID> --query "SecurityGroups[].[GroupId,GroupName]" --output table
```
남은 로드밸런서를 콘솔에서 삭제하고, ENI가 `available` 상태로 풀리면 보안 그룹을 삭제한 뒤 `down.ps1`을 다시 실행한다.

### state 잠금이 풀리지 않는다
증상: `Error acquiring the state lock`

원인: 이전 apply/destroy가 강제 종료되어 S3의 `.tflock` 파일이 남았다.

해결: 다른 Terraform 작업이 실제로 돌고 있지 않은지 먼저 확인한 뒤, 오류 메시지에 나온 Lock ID로 해제한다.
```powershell
terraform -chdir=terraform/01-cluster force-unlock <LOCK_ID>
```

### 노드그룹이 30분 가까이 CREATING이다가 CREATE_FAILED가 된다 (인스턴스 0대)
증상: apply가 `aws_eks_node_group ... Still creating...`에서 오래 멈추고, EC2 인스턴스가 하나도 생기지 않는다. 약 30분 뒤 `AsgInstanceLaunchFailures`로 실패한다.

원인 확인: 노드그룹이 실패로 판정되기 전에도 CloudTrail에서 실제 오류를 바로 볼 수 있다.
```powershell
aws cloudtrail lookup-events --profile terraform-admin --lookup-attributes AttributeKey=EventName,AttributeValue=RunInstances --max-results 3 --query "Events[].CloudTrailEvent" --output text
```

실제 사례 (2026-10-29): `The specified instance type is not eligible for Free Tier.`
- 계정이 AWS 무료 플랜이라 t3.xlarge 실행이 거부됨
- 프리티어 대상 타입 확인: `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`
- 해결: `node_instance_types`를 m7i-flex.large로 변경. 실패한 노드그룹은 state에 남아 있어 다음 apply에서 교체된다. 수동 정리 불필요

그 밖에 확인할 것: 온디맨드 vCPU 한도(`aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A`, 현재 16)

### 노드가 클러스터에 합류하지 않는다
증상: 노드그룹 생성이 `CREATE_FAILED`(NodeCreationFailure)이거나 `kubectl get nodes`가 비어 있다

확인할 것:
1. **프라이빗 엔드포인트가 켜져 있는가** (`endpoint_private_access = true`). 퍼블릭 엔드포인트를 본인 IP로 제한했기 때문에, 노드는 프라이빗 엔드포인트로만 API 서버에 붙을 수 있다.
2. 서브넷에 `map_public_ip_on_launch = true`가 적용되어 있는가. NAT가 없으므로 노드는 퍼블릭 IP로 이미지를 받는다.
3. EKS 콘솔 → 노드그룹 → Health issues 메시지

### 스크립트가 helm/kubectl 실행 중에 NativeCommandError로 끊긴다
증상: `helm : I1029 ... client-side throttling` 같은 정보성 로그 한 줄에서 스크립트가 종료되고, Helm 릴리스가 `pending-install`로 남는다.

원인: Windows PowerShell 5.1은 네이티브 명령의 stderr 출력을 오류로 바꾼다. `$ErrorActionPreference = 'Stop'`이면 그 즉시 스크립트가 중단된다.

해결: `scripts/common.ps1`의 `Invoke-Native`가 실행 중에만 `Continue`로 낮추고 종료 코드로 성공 여부를 판단하도록 수정됨 (2026-10-29). 이미 `pending-install`로 남은 릴리스는 지우고 다시 설치한다.
```powershell
helm uninstall otel-demo -n otel-demo --wait
.\scripts\deploy-demo.ps1
```

### down.ps1 -AutoApprove가 "Too many command line arguments"로 실패한다
증상: `02-addons destroy` 단계에서 `Expected at most one positional argument.`

원인: `$approve = if (...) { @('-auto-approve') } else { @() }`처럼 `if` 식의 결과를 그대로 받으면, 요소 1개짜리 배열이 **문자열 하나로 풀린다.** 문자열을 `@approve`로 펼치면 글자 단위로 쪼개져 `- a u t o - a p p r o v e`가 전달된다.

해결: `$approve = @(if ($AutoApprove) { '-auto-approve' })`로 항상 배열을 유지 (2026-10-30, up.ps1·down.ps1 모두 수정). 같은 실행에서 `kubectl -o jsonpath`의 큰따옴표가 깨지는 문제도 있어, LoadBalancer Service 조회를 `-o json` + PowerShell 필터로 바꿨다.

### up.ps1에서 02-addons가 실패한다
- `Error: Kubernetes cluster unreachable`: kubeconfig나 IP 허용 목록 문제다. 위의 IP 변경 항목을 확인한다.
- 01-cluster state를 읽지 못한다: 01-cluster apply가 끝까지 성공했는지 확인한다.

---

### Grafana 자체 메트릭 수집 대상이 down이다 (리다이렉트)
- 증상: kps Prometheus의 `kube-prometheus-stack-grafana` 대상이 `Get "http://localhost:3000/grafana/metrics": connection refused`
- 원인: `serve_from_sub_path: true`라 `/metrics` 요청이 `root_url` 기준 `localhost:3000/grafana/metrics`로 리다이렉트된다. 수집기 입장의 localhost는 자기 자신이다.
- 해결: `grafana.serviceMonitor.path: /grafana/metrics`

### 데모 알림 규칙이 Grafana에 로드되지 않는다
- 증상: 알림 사이드카 로그에 `provisioning/alerting/reload` 500, Grafana 로그에 `receiver grafana-default-email does not exist`
- 원인: 데모 알림 규칙의 수신처가 데모 차트 내장 Grafana의 기본 contact point인데, kps Grafana에는 contact point가 없다.
- 해결: `helm/grafana/alerting/contact-points.yml`로 Alertmanager contact point를 만들고 규칙의 수신처를 바꿨다.

### values에서 뺀 Grafana 데이터소스가 계속 보인다
- 원인: Grafana는 한 번 프로비저닝한 데이터소스를 내부 DB에 남긴다. 설정에서 빼도 자동으로 지우지 않는다.
- 해결: 이 클러스터의 Grafana DB는 emptyDir라 `kubectl rollout restart deploy/kube-prometheus-stack-grafana -n monitoring`으로 새로 시작하면 정리된다.

### Grafana 데이터소스를 바꿨는데 반영되지 않는다 (같은 uid, 다른 이름)
- 증상: 데이터소스 사이드카 로그에 `provisioning/datasources/reload` 500, Grafana 로그에 `Failed to provision data sources ... data source with the same uid already exists`. 예전 데이터소스가 그대로 남는다.
- 원인: 프로비저닝은 데이터소스를 **이름**으로 찾는다. 새 이름(예: Tempo)이 DB에 남은 예전 데이터소스(Jaeger)의 uid(`webstore-traces`)를 쓰려 해서 충돌한다. uid를 유지한 채 저장소를 바꿀 때 생긴다(Phase 3-B ⑤ Jaeger → Tempo, ⑥ OpenSearch → Loki).
- 해결: 위와 같이 Grafana를 재시작한다. 새 클러스터에서는 DB가 비어 있어 생기지 않는다.

### Tempo가 OOMKilled로 재시작된다
- 증상: `tempo-0` 재시작, `lastState.terminated.reason: OOMKilled`(exit 137). 그 순간 조회한 트레이스가 없는 것처럼 보인다.
- 원인: live-store가 최근 트레이스를 메모리에 들고 있어 데모 트래픽에서도 수백 MiB를 쓰고, 여러 트레이스를 한꺼번에 조회하면 더 늘어난다. 1Gi 제한에서 12분 만에 종료됐다(재시작 직후 841Mi).
- 해결: `helm/values/tempo.yaml`의 메모리 제한 2Gi, `GOMEMLIMIT`를 제한의 80%(1638MiB)로 설정. 이후 조회 중 최대 777Mi, 재시작 0회. emptyDir라 OOM 재시작(같은 파드)에서는 WAL로 복구되지만 재배포(파드 교체)에서는 데이터가 사라진다.

### Helm values에서 목록 하나를 고쳤더니 다른 설정이 사라졌다
- 증상: Phase 3-B ④에서 Jaeger `extraEnv`의 `PROMETHEUS_ADDR`만 바꾸려고 목록을 다시 적었는데, 빠뜨린 `JAEGER_GRPC_PORT` 때문에 Jaeger가 OTLP를 임의 포트로 열어 Collector 전송이 거부됐다(⑤에서 발견).
- 원인: Helm은 맵(map)은 병합하지만 **목록(list)은 병합하지 않고 통째로 바꾼다.** `extraEnv`, Collector `processors`·`exporters` 목록이 모두 해당한다.
- 해결: 목록을 덮어쓸 때는 `helm show values <차트> --version <버전>`으로 기본 목록을 확인해 전부 옮겨 적는다. `-Template`으로 렌더링 결과를 비교한다. 맵에서 키를 지우려고 `null`을 쓰면 렌더링 결과에 `null`이 그대로 남거나(Collector exporter) 템플릿이 실패하는(Tempo 수신기) 경우가 있어 렌더링으로 확인한다.

---

## 6. 버전 관리 정책

| 대상 | 고정 위치 | 현재 값 |
|---|---|---|
| Terraform | 각 스택 `versions.tf`의 `required_version` | `>= 1.10` (S3 네이티브 잠금) |
| AWS provider | `versions.tf` + `.terraform.lock.hcl` | `~> 6.0` |
| Helm provider | `02-addons/versions.tf` | `~> 3.0` |
| VPC 모듈 | `01-cluster/vpc.tf` | `~> 6.0` |
| EKS 모듈 | `01-cluster/eks.tf` | `~> 21.0` |
| EKS 버전 | `01-cluster/variables.tf`의 `kubernetes_version` | `1.37` |
| Load Balancer Controller 차트 | `02-addons/variables.tf` | `3.6.2` |
| OpenTelemetry Demo 차트 | `scripts/deploy-demo.ps1` | `0.42.6` |
| kube-prometheus-stack 차트 | `scripts/deploy-observability.ps1` | `92.16.0` |
| Tempo 차트 (`grafana-community/tempo`) | `scripts/deploy-observability.ps1` | `3.2.1` (Tempo 3.1.1) |
| Loki 차트 (`grafana-community/loki`) | `scripts/deploy-observability.ps1` | `20.2.0` (Loki 3.7.9) |
| 로컬 kubectl | winget 설치본 (PowerShell 프로필 별칭) | 클러스터와 ±1 마이너 이내 유지 |

**업그레이드 절차**
1. 버전 하나만 바꾼다.
2. `terraform init -upgrade` → `plan`으로 변경 범위를 확인한다. 재생성(`-/+`)이 있으면 이유를 먼저 파악한다.
3. 클러스터를 띄운 상태에서 apply하고 동작을 확인한 뒤 커밋한다.
4. EKS 버전은 표준 지원 종료일을 확인한다(`aws eks describe-cluster-versions`). 표준 지원이 끝나면 연장 지원 요금이 붙어 컨트롤 플레인 비용이 크게 오른다.
