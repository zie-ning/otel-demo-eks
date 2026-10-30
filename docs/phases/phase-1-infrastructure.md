# Phase 1. 인프라 (Terraform)

> 상태: ✅ 완료 (2026-10-29 생성, 2026-10-30 삭제·재생성 검증) · 요약: [PLAN.md](../PLAN.md#phase-1-인프라-terraform)

## 목표
필요할 때만 띄우고 끄는 EKS 클러스터를 Terraform 코드로 만든다. 생성과 삭제를 스크립트 한 줄로 반복할 수 있어야 한다.

## 구성

### 스택 분리
| 스택 | 내용 | state |
|---|---|---|
| `terraform/01-cluster` | VPC, EKS, 노드그룹, 코어 애드온 | S3 `01-cluster/terraform.tfstate` |
| `terraform/02-addons` | AWS Load Balancer Controller, metrics-server | S3 `02-addons/terraform.tfstate` |

같은 apply에서 클러스터 생성과 Helm 설치를 함께 하면 Helm/Kubernetes provider가 아직 없는 클러스터 정보로 초기화되는 문제가 있어 둘로 나눴다. `02-addons`는 `01-cluster`의 출력값을 S3 state에서 읽는다.

### 버전
| 대상 | 버전 |
|---|---|
| terraform-aws-modules/vpc | 6.7.3 |
| terraform-aws-modules/eks | 21.29.0 |
| terraform-aws-modules/eks-pod-identity | 2.10.0 |
| AWS provider | 6.71 |
| Helm provider | 3.3 |
| EKS | 1.37 |
| AWS Load Balancer Controller 차트 | 3.6.2 |

### 네트워크 (`01-cluster`)
- 퍼블릭 서브넷 2개(ap-northeast-2a, 2c), **NAT Gateway 없음** (비용 절감. 노드는 퍼블릭 IP로 외부 통신)
- EKS API 엔드포인트: 퍼블릭 접근은 **본인 IP만**(`admin.auto.tfvars`, `up.ps1`이 실행 때마다 갱신), 프라이빗 접근 켬(노드는 VPC 내부로 접속)

### EKS
- 인증 모드 `API`, 클러스터 생성자에게 관리자 권한
- 컨트롤 플레인 로그·CloudWatch 로그 그룹·KMS 암호화는 끔 (단기 실습 클러스터라 비용과 삭제 잔여물을 줄임)
- 애드온: vpc-cni, eks-pod-identity-agent(노드보다 먼저 설치), kube-proxy, coredns

### 노드그룹
| 노드그룹 | 타입 × 수 | 라벨 / taint |
|---|---|---|
| app | m7i-flex.large × 2 | `role=app` |
| monitoring | m7i-flex.large × 1 | `role=monitoring`, taint `dedicated=monitoring:NoSchedule` |

- AL2023, gp3 50GB, 온디맨드
- 관측 도구를 별도 노드로 분리해 앱 장애나 부하가 관측 도구로 번지지 않게 했다.

### 애드온 (`02-addons`)
- AWS Load Balancer Controller: EKS Pod Identity로 IAM 권한 부여. ALB Ingress용
- metrics-server: EKS 애드온으로 설치 (`kubectl top`)
- EBS CSI Driver는 제외: 영구 볼륨 없이 운영하고 클러스터 삭제 때 데이터도 함께 지우는 방식이라 불필요

### 스크립트
- `scripts/up.ps1`: 현재 공인 IP 기록 → 01 apply → kubeconfig 갱신 → 02 apply → 노드 확인
- `scripts/down.ps1`: Ingress·LoadBalancer Service 삭제 → ELB가 사라질 때까지 대기(최대 5분) → 02 destroy → 01 destroy → 잔여 인스턴스·클러스터 확인
- `scripts/common.ps1`: 공통 변수, 네이티브 명령 실행 함수 `Invoke-Native`

## 진행 중 겪은 문제
상세 원인과 해결은 [operations.md](../operations.md#5-문제-해결)에 있다.

| 문제 | 원인 | 해결 |
|---|---|---|
| 노드그룹이 약 30분 CREATING 후 CREATE_FAILED (인스턴스 0대) | 계정이 AWS 무료 플랜이라 프리티어 대상이 아닌 t3.xlarge 실행 거부 (CloudTrail RunInstances로 확인) | m7i-flex.large × 3 (app 2 + monitoring 1)로 변경 |
| apply 도중 공인 IP 변경 | 장소 이동 | `admin.auto.tfvars`를 `up.ps1`이 매번 현재 IP로 갱신 |
| helm/kubectl 정보성 stderr로 스크립트 중단, 릴리스가 pending-install로 남음 | PowerShell 5.1이 네이티브 명령 stderr를 오류로 처리 | `Invoke-Native`에서 ErrorActionPreference를 낮추고 종료 코드로 판단 |
| `down.ps1 -AutoApprove`가 "Too many command line arguments" | 요소 1개 배열이 문자열로 풀려 splat이 글자 단위로 쪼개짐 | `@(if (...) { ... })` 형태로 수정 |

## 검증
- `kubectl get nodes`: 3대 Ready, 라벨·taint 확인
- `down.ps1`로 전체 삭제 (2026-10-30): 02-addons 6개, 01-cluster 50개 리소스 삭제. EKS·EC2·ALB·VPC·EBS·ENI 잔여 없음. 첫 실행에서 스크립트 버그 2건을 수정한 뒤 재실행
- 같은 날 `up.ps1`로 다시 생성해 동일하게 동작 확인

## 완료 기준
- [x] `kubectl get nodes` 정상
- [x] `down.ps1`로 잔여 리소스 없이 삭제

## 관련 문서
- 운영 절차·문제 해결: [operations.md](../operations.md)
