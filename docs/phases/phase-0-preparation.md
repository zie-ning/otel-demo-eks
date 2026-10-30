# Phase 0. 사전 준비

> 상태: ✅ 완료 (2026-10-29) · 요약: [PLAN.md](../PLAN.md#phase-0-사전-준비)

## 목표
클러스터를 만들기 전에 필요한 도구, 자격 증명, 비용 안전장치, Terraform state 저장소를 준비한다.

## 진행 내용

### 자격 증명
- AWS CLI 프로필 `terraform-admin` (IAM 사용자 `terraform_admin`)을 모든 AWS CLI·Terraform 작업에 사용한다.
- MFA 설정 여부는 확인하지 않았다.

### 로컬 도구
| 도구 | 버전 | 비고 |
|---|---|---|
| AWS CLI | 2.30 | |
| Terraform | 1.15 | S3 네이티브 잠금(`use_lockfile`)을 쓰려고 1.10 이상 필요 |
| kubectl | 1.37 | winget 설치. 시스템 PATH의 Docker Desktop kubectl(구버전)이 먼저 잡혀 PowerShell 프로필에 별칭 추가 |
| Helm | 4.3 | |

### Terraform state 버킷과 예산 알림 (`terraform/00-bootstrap`)
- **state 버킷** `otel-demo-tfstate-520426835144`
  - 버전 관리, AES256 암호화, 퍼블릭 액세스 차단, 이전 버전 90일 후 만료
  - `prevent_destroy`로 실수 삭제 방지
  - 이 스택 자체의 state는 **로컬**(`terraform.tfstate`)에 둔다. 버킷을 만드는 스택이 그 버킷에 state를 둘 수 없기 때문
- **AWS Budgets** `otel-demo-monthly`: 월 $40
  - 알림: 실제 비용 50%($20), 100%($40), 예상 비용 100%
  - `include_credit = false`: 크레딧 차감 **전** 금액 기준. 무료 플랜 크레딧으로 실제 청구는 0이어도 사용량을 알 수 있게 함
  - 알림 이메일은 `terraform.tfvars`(커밋 안 함)에 둔다

### GitHub 저장소
- [zie-ning/otel-demo-eks](https://github.com/zie-ning/otel-demo-eks) (공개)
- `.gitignore`: tfstate, tfvars(예시 제외), tfplan, `*.local.yaml`, kubeconfig, `.pem`, `.env`
- `.gitattributes`: 줄바꿈 LF 통일

## 완료 기준
- [x] `terraform-admin` 프로필로 AWS CLI 호출 가능
- [x] 00-bootstrap apply 완료 (버킷, 예산)
- [x] 저장소 생성과 첫 push

## 관련 문서
- 운영 절차와 비용 관리: [operations.md](../operations.md)
