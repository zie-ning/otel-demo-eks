# OpenTelemetry Demo를 Helm으로 설치하거나 업그레이드한다.
# 사용법: .\scripts\deploy-demo.ps1             (설치/업그레이드)
#         .\scripts\deploy-demo.ps1 -Template   (클러스터에 적용하지 않고 렌더링 결과만 확인)
param([switch]$Template)

. "$PSScriptRoot\common.ps1"

$ChartVersion = '0.42.6'
$Namespace    = 'otel-demo'
$Release      = 'otel-demo'
$ValuesFile   = Join-Path $Root 'helm\values\otel-demo.yaml'
$LocalValues  = Join-Path $Root 'helm\values\otel-demo.local.yaml'

# ALB 접근 허용 IP는 커밋하지 않는 로컬 values 파일로 주입한다 (.gitignore 대상)
$myIp = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com').Trim()
Write-Host "ALB 접근 허용 IP: $myIp" -ForegroundColor Yellow
@"
components:
  frontend-proxy:
    ingress:
      annotations:
        alb.ingress.kubernetes.io/inbound-cidrs: $myIp/32
"@ | Set-Content -Path $LocalValues -Encoding ascii

Invoke-Native 'Helm 저장소 갱신' {
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update
    helm repo update open-telemetry
}

$common = @(
    $Release, 'open-telemetry/opentelemetry-demo',
    '--version', $ChartVersion,
    '--namespace', $Namespace,
    '-f', $ValuesFile,
    '-f', $LocalValues
)

if ($Template) {
    Invoke-Native '렌더링' { helm template @common }
    return
}

Invoke-Native '데모 설치/업그레이드' {
    helm upgrade --install @common --create-namespace --wait --timeout 15m
}
Invoke-Native '파드 상태' { & $Kubectl get pods -n $Namespace -o wide }
Invoke-Native 'Ingress 주소' { & $Kubectl get ingress -n $Namespace }
