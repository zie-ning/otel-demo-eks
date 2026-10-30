param(
    # Jaeger UI 주소 (예: http://<ALB 주소>/jaeger/ui)
    [Parameter(Mandatory)][string]$JaegerUrl,
    [string]$Lookback = '1h',
    # 지정하면 이 시각 이후 트레이스만 집계 (수정 전후 비교용, 예: '2026-10-30 11:50')
    [datetime]$Since,
    [int]$Limit = 50
)
# 서비스별 리소스 속성 품질 집계 (Phase 3-A 완료 기준 확인용)
# - k8s.pod.name 부착 여부 (OBS-2, OBS-3)
# - host.name이 Collector 파드 이름인지 (OBS-1)
# - ALB 헬스체크 트레이스 수
$ErrorActionPreference = 'Stop'
$api = "$($JaegerUrl.TrimEnd('/'))/api"
$services = (Invoke-RestMethod "$api/services").data | Where-Object { $_ -notmatch '^jaeger' } | Sort-Object
# Jaeger API 시간 범위는 마이크로초 단위 Unix 시각
$range = if ($Since) {
    $epoch = [datetime]'1970-01-01Z'
    $start = [long](($Since.ToUniversalTime() - $epoch.ToUniversalTime()).TotalMilliseconds * 1000)
    $end = [long](([datetime]::UtcNow - $epoch.ToUniversalTime()).TotalMilliseconds * 1000)
    "start=$start&end=$end"
} else { "lookback=$Lookback" }

$rows = foreach ($svc in $services) {
    $traces = @((Invoke-RestMethod "$api/traces?service=$svc&$range&limit=$Limit").data)
    if ($traces.Count -eq 0) { continue }
    $withPod = 0; $withoutPod = 0; $collectorHost = 0
    $hostNames = @{}
    foreach ($t in $traces) {
        foreach ($p in $t.processes.PSObject.Properties.Value) {
            if ($p.serviceName -ne $svc) { continue }
            $tags = @{}
            $p.tags | ForEach-Object { $tags[$_.key] = $_.value }
            if ($tags.ContainsKey('k8s.pod.name')) { $withPod++ } else { $withoutPod++ }
            $h = $tags['host.name']
            if ($h -like 'otel-collector-agent-*') { $collectorHost++ }
            if ($h) { $hostNames[$h] = $true }
        }
    }
    [pscustomobject]@{
        service          = $svc
        traces           = $traces.Count
        'k8s.pod.name O' = $withPod
        'k8s.pod.name X' = $withoutPod
        'host=collector' = $collectorHost
        'host.name 예시'  = ($hostNames.Keys | Select-Object -First 2) -join ', '
    }
}
$rows | Format-Table -AutoSize

# 헬스체크 트레이스: frontend-proxy 루트 스팬의 user_agent로 판별
$proxy = (Invoke-RestMethod "$api/traces?service=frontend-proxy&$range&limit=500").data
$hc = @($proxy | Where-Object {
    $root = $_.spans | Where-Object { -not $_.references -or $_.references.Count -eq 0 } | Select-Object -First 1
    $root -and (($root.tags | Where-Object { $_.key -match 'user_agent' }).value -match 'ELB-HealthChecker')
})
$period = if ($Since) { "$Since 이후" } else { "최근 $Lookback" }
"frontend-proxy 트레이스 $(@($proxy).Count)건 중 ALB 헬스체크 $($hc.Count)건 ($period, 최대 500건)"
