# 관측 스택(kube-prometheus-stack, Tempo, Loki, 데모 대시보드)을 설치하거나 업그레이드한다.
# 데모(deploy-demo.ps1)보다 먼저 설치한다. Collector가 이 스택의 Prometheus로 메트릭을, Tempo로 트레이스를, Loki로 로그를 보낸다.
# 사용법: .\scripts\deploy-observability.ps1             (설치/업그레이드)
#         .\scripts\deploy-observability.ps1 -Template   (클러스터에 적용하지 않고 렌더링 결과만 확인)
param([switch]$Template)

. "$PSScriptRoot\common.ps1"

$Namespace = 'monitoring'

$KpsChartVersion = '92.16.0'
$KpsRelease      = 'kube-prometheus-stack'
$KpsValues       = Join-Path $Root 'helm\values\kube-prometheus-stack.yaml'
$GrafanaDir      = Join-Path $Root 'helm\grafana'
$GrafanaSecret   = 'grafana-admin'
$AlertsDir       = Join-Path $Root 'observability\alerts'
$SlackSecret     = 'alertmanager-slack'
$SlackWebhooks   = Join-Path $Root 'helm\values\slack-webhooks.local.yaml'

$TempoChartVersion = '3.2.1'
$TempoRelease      = 'tempo'
$TempoValues       = Join-Path $Root 'helm\values\tempo.yaml'

$LokiChartVersion = '20.2.0'
$LokiRelease      = 'loki'
$LokiValues       = Join-Path $Root 'helm\values\loki.yaml'

Invoke-Native 'Helm 저장소 갱신' {
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
    helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update
    helm repo update prometheus-community grafana-community
}

$kps = @(
    $KpsRelease, 'prometheus-community/kube-prometheus-stack',
    '--version', $KpsChartVersion,
    '--namespace', $Namespace,
    '-f', $KpsValues
)
$tempo = @(
    $TempoRelease, 'grafana-community/tempo',
    '--version', $TempoChartVersion,
    '--namespace', $Namespace,
    '-f', $TempoValues
)
$loki = @(
    $LokiRelease, 'grafana-community/loki',
    '--version', $LokiChartVersion,
    '--namespace', $Namespace,
    '-f', $LokiValues
)

if ($Template) {
    Invoke-Native 'kube-prometheus-stack 렌더링' { helm template @kps }
    Invoke-Native 'Tempo 렌더링' { helm template @tempo }
    Invoke-Native 'Loki 렌더링' { helm template @loki }
    Invoke-Native '데모 대시보드 ConfigMap 렌더링' { & $Kubectl kustomize $GrafanaDir }
    return
}

# 리소스 존재 여부 확인. 없을 때 kubectl이 stderr에 쓰는 NotFound가 Stop 설정에서 예외가 되지 않도록 Continue로 낮춘다.
function Test-Resource([string[]]$KubectlArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Kubectl get @KubectlArgs *> $null } finally { $ErrorActionPreference = $prev }
    return ($LASTEXITCODE -eq 0)
}

# 네임스페이스와 Grafana admin Secret은 차트보다 먼저 있어야 한다 (차트가 existingSecret으로 참조)
if (-not (Test-Resource @('namespace', $Namespace))) {
    Invoke-Native "네임스페이스 $Namespace 생성" { & $Kubectl create namespace $Namespace }
}
if (-not (Test-Resource @('secret', $GrafanaSecret, '-n', $Namespace))) {
    # 클러스터를 새로 만들 때마다 무작위 비밀번호를 만든다. 화면에 출력하지 않는다.
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $password = [Convert]::ToBase64String($bytes) -replace '[+/=]', ''
    Invoke-Native 'Grafana admin Secret 생성' {
        & $Kubectl create secret generic $GrafanaSecret -n $Namespace `
            --from-literal=admin-user=admin --from-literal=admin-password=$password
    }
}

# Alertmanager Slack 웹훅 Secret. Alertmanager 파드가 마운트하므로 차트보다 먼저 있어야 한다.
# URL은 로컬 파일(커밋 안 함)에서 읽고 화면에 출력하지 않는다. 파일이 바뀌었을 수 있으므로 매번 갱신한다.
if (-not (Test-Path $SlackWebhooks)) {
    throw "$SlackWebhooks 가 없습니다. docs/operations.md의 '알림 채널(Slack)'을 참고해 만드세요."
}
$webhooks = @{}
foreach ($key in 'critical', 'warning') {
    $m = Select-String -Path $SlackWebhooks -Pattern "^${key}:\s*(\S+)\s*$"
    $url = if ($m) { $m.Matches[0].Groups[1].Value }
    if ($url -notlike 'https://hooks.slack.com/*') {
        throw "$SlackWebhooks 의 '$key' 값이 Slack 웹훅 URL(https://hooks.slack.com/...)이 아닙니다."
    }
    $webhooks[$key] = $url
}
# 명령줄 인자로 넘기지 않도록 임시 파일에 쓰고(--from-file), 끝나면 지운다. 줄바꿈 없이 쓴다.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    foreach ($key in $webhooks.Keys) {
        [IO.File]::WriteAllText((Join-Path $tmp $key), $webhooks[$key])
    }
    # create --dry-run 결과를 apply로 넘겨 있으면 갱신, 없으면 생성한다
    Invoke-Native 'Alertmanager Slack 웹훅 Secret 적용' {
        & $Kubectl create secret generic $SlackSecret -n $Namespace `
            "--from-file=critical=$(Join-Path $tmp 'critical')" "--from-file=warning=$(Join-Path $tmp 'warning')" `
            --dry-run=client -o yaml | & $Kubectl apply -f -
    }
} finally {
    Remove-Item -Recurse -Force $tmp
}

Invoke-Native 'kube-prometheus-stack 설치/업그레이드' {
    helm upgrade --install @kps --wait --timeout 15m
}
Invoke-Native 'Tempo 설치/업그레이드' {
    helm upgrade --install @tempo --wait --timeout 10m
}
Invoke-Native 'Loki 설치/업그레이드' {
    helm upgrade --install @loki --wait --timeout 10m
}
# 대시보드 ConfigMap이 커서(약 470KB) 클라이언트 측 apply의 last-applied 주석 한도(256KB)를 넘으므로 server-side로 적용한다
Invoke-Native '데모 대시보드·알림 ConfigMap 적용' {
    & $Kubectl apply -k $GrafanaDir --server-side --force-conflicts
}
# Phase 4 기준선 알림(SLO burn rate, 측정 유효성). kps Prometheus가 릴리스 라벨 없이도 읽는다
Invoke-Native 'SLO·기준선 알림 규칙(PrometheusRule) 적용' {
    & $Kubectl apply -f $AlertsDir
}
Invoke-Native '파드 상태' { & $Kubectl get pods -n $Namespace -o wide }
Write-Host "`nGrafana admin 비밀번호 확인: docs/operations.md의 '관측 스택 배포' 참고" -ForegroundColor Yellow
