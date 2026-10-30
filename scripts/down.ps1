# 클러스터와 관련 리소스를 모두 삭제한다 (state 버킷과 예산은 유지).
# 사용법: .\scripts\down.ps1            (plan을 보고 직접 yes 입력)
#         .\scripts\down.ps1 -AutoApprove
param([switch]$AutoApprove)

. "$PSScriptRoot\common.ps1"
# if 식의 결과를 바로 받으면 요소 1개짜리 배열이 문자열로 풀려, @approve 펼칠 때 글자 단위로 쪼개진다
$approve = @(if ($AutoApprove) { '-auto-approve' })

# 1) 쿠버네티스가 만든 AWS 리소스 먼저 정리
#    Ingress/LoadBalancer Service로 생긴 ALB·NLB와 보안 그룹은 Terraform state에 없다.
#    클러스터를 먼저 지우면 이 리소스가 남아 과금되고, VPC 삭제도 막힌다.
$clusterExists = $false
aws eks describe-cluster --name $ClusterName --region $Region --profile $Profile_ *> $null
if ($LASTEXITCODE -eq 0) { $clusterExists = $true }

if ($clusterExists) {
    Invoke-Native 'kubeconfig 갱신' { aws eks update-kubeconfig --name $ClusterName --region $Region --profile $Profile_ }
    Invoke-Native 'Ingress 삭제' { & $Kubectl delete ingress --all --all-namespaces --wait=true }
    # jsonpath의 큰따옴표는 PowerShell 5.1 인자 전달에서 깨지므로 JSON으로 받아 PowerShell에서 거른다
    Invoke-Native 'LoadBalancer Service 삭제' {
        $svcs = (& $Kubectl get svc --all-namespaces -o json | Out-String | ConvertFrom-Json).items |
            Where-Object { $_.spec.type -eq 'LoadBalancer' }
        foreach ($s in $svcs) {
            & $Kubectl delete svc $s.metadata.name -n $s.metadata.namespace --wait=true
        }
        $global:LASTEXITCODE = 0
    }

    Write-Host "`n==> 로드밸런서 삭제 대기" -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes(5)
    do {
        $lbs = aws elbv2 describe-load-balancers --region $Region --profile $Profile_ --query "LoadBalancers[].LoadBalancerArn" --output text
        $remaining = @()
        foreach ($arn in ($lbs -split '\s+' | Where-Object { $_ })) {
            $tag = aws elbv2 describe-tags --resource-arns $arn --region $Region --profile $Profile_ --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value" --output text
            if ($tag -eq $ClusterName) { $remaining += $arn }
        }
        if ($remaining.Count -eq 0) { break }
        Write-Host "  남은 로드밸런서 $($remaining.Count)개, 10초 후 재확인"
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if ($remaining.Count -gt 0) { throw "로드밸런서가 삭제되지 않았습니다: $remaining" }
}

# 2) Terraform 리소스를 생성의 역순으로 삭제
Invoke-Native '02-addons init'    { terraform "-chdir=$AddonsDir" init -input=false }
Invoke-Native '02-addons destroy' { terraform "-chdir=$AddonsDir" destroy -input=false @approve }
Invoke-Native '01-cluster init'    { terraform "-chdir=$ClusterDir" init -input=false }
Invoke-Native '01-cluster destroy' { terraform "-chdir=$ClusterDir" destroy -input=false @approve }

# 3) 과금 리소스가 남지 않았는지 확인
Write-Host "`n==> 잔여 리소스 확인" -ForegroundColor Cyan
$instances = aws ec2 describe-instances --region $Region --profile $Profile_ --filters "Name=tag:eks:cluster-name,Values=$ClusterName" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text
$cluster   = aws eks list-clusters --region $Region --profile $Profile_ --query "clusters[?@=='$ClusterName']" --output text
if ($instances -or $cluster) {
    Write-Host "남은 리소스가 있습니다. 콘솔에서 확인하세요: 클러스터=[$cluster] 인스턴스=[$instances]" -ForegroundColor Red
    exit 1
}
Write-Host "삭제 완료. 과금 리소스가 남아 있지 않습니다." -ForegroundColor Green
