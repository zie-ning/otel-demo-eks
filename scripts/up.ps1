# 클러스터와 기본 애드온을 생성한다.
# 사용법: .\scripts\up.ps1            (plan을 보고 직접 yes 입력)
#         .\scripts\up.ps1 -AutoApprove
param([switch]$AutoApprove)

. "$PSScriptRoot\common.ps1"
$approve = if ($AutoApprove) { @('-auto-approve') } else { @() }

# 공인 IP가 바뀌어도 API 엔드포인트에 접근할 수 있도록 매번 현재 IP로 갱신한다.
# *.auto.tfvars는 terraform.tfvars보다 나중에 읽혀 값을 덮어쓴다 (.gitignore 대상)
$myIp = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com').Trim()
Write-Host "현재 공인 IP: $myIp" -ForegroundColor Yellow
Set-Content -Path (Join-Path $ClusterDir 'admin.auto.tfvars') -Value "admin_cidrs = [`"$myIp/32`"]" -Encoding ascii

Invoke-Native '01-cluster init'  { terraform "-chdir=$ClusterDir" init -input=false }
Invoke-Native '01-cluster apply' { terraform "-chdir=$ClusterDir" apply -input=false @approve }

Invoke-Native 'kubeconfig 갱신' { aws eks update-kubeconfig --name $ClusterName --region $Region --profile $Profile_ }

Invoke-Native '02-addons init'  { terraform "-chdir=$AddonsDir" init -input=false }
Invoke-Native '02-addons apply' { terraform "-chdir=$AddonsDir" apply -input=false @approve }

Invoke-Native '노드 상태 확인' { & $Kubectl get nodes -o wide }
Write-Host "`n완료. 작업이 끝나면 반드시 .\scripts\down.ps1 을 실행하세요." -ForegroundColor Green
