param(
    # Grafana 주소 (예: http://<ALB 주소>/grafana). Tempo는 Grafana 데이터소스 프록시로 조회한다 (익명 Viewer 권한으로 가능)
    [Parameter(Mandatory)][string]$GrafanaUrl,
    # 조회 구간 길이 (예: 30m, 1h)
    [string]$Lookback = '1h',
    # 지정하면 이 시각 이후 트레이스만 집계 (수정 전후 비교용, 예: '2026-10-30 11:50')
    [datetime]$Since,
    [int]$Limit = 50
)
# 서비스별 리소스 속성 품질 집계 (Phase 3-A 완료 기준 확인용, ⑤에서 Jaeger API → Tempo API로 이전)
# - k8s.pod.name 부착 여부 (OBS-2, OBS-3)
# - host.name이 Collector 파드 이름인지 (OBS-1)
# - ALB 헬스체크 트레이스 수
$ErrorActionPreference = 'Stop'
$api = "$($GrafanaUrl.TrimEnd('/'))/api/datasources/proxy/uid/webstore-traces/api"

# Tempo 검색 API의 시간 범위는 초 단위 Unix 시각
$end = [DateTimeOffset]::UtcNow
$start = if ($Since) {
    [DateTimeOffset]$Since.ToUniversalTime()
} else {
    $n = [int]($Lookback -replace '\D', '')
    if ($Lookback -match 'h$') { $end.AddHours(-$n) } else { $end.AddMinutes(-$n) }
}
$range = "start=$($start.ToUnixTimeSeconds())&end=$($end.ToUnixTimeSeconds())"

function Search-Traces([string]$TraceQL, [int]$Max) {
    $q = [uri]::EscapeDataString($TraceQL)
    # spss=1: 트레이스마다 조건에 맞는 스팬 1개만 받는다
    @((Invoke-RestMethod "$api/search?q=$q&$range&limit=$Max&spss=1").traces)
}

$services = (Invoke-RestMethod "$api/v2/search/tag/resource.service.name/values?$range").tagValues.value | Sort-Object

$rows = foreach ($svc in $services) {
    # 해당 서비스 스팬의 리소스 속성 두 개만 골라 받는다 (트레이스 전체를 내려받지 않음)
    # 함수가 돌려준 배열은 원소가 하나면 풀려 단일 객체가 되므로 호출 지점에서 다시 배열로 감싼다 (PowerShell 5.1)
    $traces = @(Search-Traces "{resource.service.name=`"$svc`"} | select(resource.k8s.pod.name, resource.host.name)" $Limit)
    if ($traces.Count -eq 0) { continue }
    $withPod = 0; $withoutPod = 0; $collectorHost = 0
    $hostNames = @{}
    foreach ($t in $traces) {
        $attrs = @{}
        # select()로 고른 속성이 없으면 Tempo는 키를 빼지 않고 문자열 "nil"을 돌려준다
        $t.spanSet.spans[0].attributes | Where-Object { $_.value.stringValue -ne 'nil' } |
            ForEach-Object { $attrs[$_.key] = $_.value.stringValue }
        if ($attrs.ContainsKey('k8s.pod.name')) { $withPod++ } else { $withoutPod++ }
        $h = $attrs['host.name']
        if ($h -like 'otel-collector-agent-*') { $collectorHost++ }
        if ($h) { $hostNames[$h] = $true }
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

# 헬스체크 트레이스: Envoy가 스팬 속성 user_agent에 요청 헤더를 기록한다
# 두 검색은 각각 최대 500건을 따로 가져오므로 같은 표본이 아니다. 비율이 아니라 건수를 따로 표시한다
$proxy = @(Search-Traces '{resource.service.name="frontend-proxy"}' 500)
$hc = @(Search-Traces '{resource.service.name="frontend-proxy" && span.user_agent =~ "ELB-HealthChecker.*"}' 500)
$period = if ($Since) { "$Since 이후" } else { "최근 $Lookback" }
"frontend-proxy 트레이스 $($proxy.Count)건, ALB 헬스체크 트레이스 $($hc.Count)건 ($period, 검색별 최대 500건)"
