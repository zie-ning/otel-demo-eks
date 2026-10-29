# up.ps1 / down.ps1 공통 설정과 함수

$ErrorActionPreference = 'Stop'

$Root        = Split-Path -Parent $PSScriptRoot
$ClusterDir  = Join-Path $Root 'terraform\01-cluster'
$AddonsDir   = Join-Path $Root 'terraform\02-addons'
$Profile_    = 'terraform-admin'
$Region      = 'ap-northeast-2'
$ClusterName = 'otel-demo'

# Docker Desktop에 포함된 구버전 kubectl 대신 winget으로 설치한 kubectl을 우선 사용
$wingetKubectl = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Kubernetes.kubectl_Microsoft.Winget.Source_8wekyb3d8bbwe\kubectl.exe"
$Kubectl = if (Test-Path $wingetKubectl) { $wingetKubectl } else { 'kubectl' }

# 네이티브 명령은 실패해도 PowerShell 예외가 나지 않으므로 종료 코드를 직접 확인한다.
# Windows PowerShell 5.1은 stderr 출력(helm/kubectl의 정보성 로그 포함)을 오류로 바꾸므로,
# 실행하는 동안에는 ErrorActionPreference를 Continue로 낮춰 스크립트가 중간에 끊기지 않게 한다.
function Invoke-Native {
    param([string]$Description, [scriptblock]$Command)
    Write-Host "`n==> $Description" -ForegroundColor Cyan
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command 2>&1 | ForEach-Object { "$_" }
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Description 실패 (exit $LASTEXITCODE)"
    }
}
