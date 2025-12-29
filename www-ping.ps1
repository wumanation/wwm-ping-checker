param(
    # Either provide -ProcessName or -Pid
    [string]$ProcessName = "wwm",
    [int]$wwmPid,

    # Port range to identify the "game server" connection (RemotePort)
    [int]$PortMin = 4000,
    [int]$PortMax = 4999,

    # Ping options
    [int]$PingCount = 10,

    # How long to sample connections to decide which IP is "the one"
    [int]$SampleSeconds = 10,
    [int]$SampleIntervalMs = 250
)

function Resolve-Pid {
    param([string]$Name, [int]$Id)

    if ($Id -gt 0) { return $Id }
    if (-not $Name) { throw "Provide -ProcessName or -Pid." }

    $procs = Get-Process -Name $Name -ErrorAction Stop
    if ($procs.Count -gt 1) {
        Write-Host "Multiple processes matched '$Name'. Using the first PID: $($procs[0].Id)" -ForegroundColor Yellow
    }
    return $procs[0].Id
}

function Is-IPv4 {
    param([string]$Ip)
    return $Ip -match '^\d{1,3}(\.\d{1,3}){3}$'
}

$wwmPid = Resolve-Pid -Name $ProcessName -Id $wwmPid

Write-Host "Sampling connections for PID $wwmPid for $SampleSeconds seconds..." -ForegroundColor Cyan
Write-Host "Filtering by RemotePort in range $PortMin-$PortMax" -ForegroundColor Cyan

$end = (Get-Date).AddSeconds($SampleSeconds)
$hits = @()

while ((Get-Date) -lt $end) {
    # TCP established connections in port range
    $tcp = Get-NetTCPConnection -OwningProcess $wwmPid -ErrorAction SilentlyContinue |
        Where-Object {
            $_.State -eq 'Established' -and
            $_.RemotePort -ge $PortMin -and $_.RemotePort -le $PortMax -and
            (Is-IPv4 $_.RemoteAddress)
        } |
        Select-Object RemoteAddress, RemotePort

    foreach ($c in $tcp) {
        $hits += "$($c.RemoteAddress):$($c.RemotePort)"
    }

    Start-Sleep -Milliseconds $SampleIntervalMs
}

if (-not $hits -or $hits.Count -eq 0) {
    Write-Host "No matching established TCP connections found for this PID in that port range." -ForegroundColor Yellow
    exit 1
}

# Pick the most frequently seen endpoint during sampling
$top = $hits | Group-Object | Sort-Object Count -Descending | Select-Object -First 1
$endpoint = $top.Name
$remoteIp, $remotePort = $endpoint.Split(':')

Write-Host ""
Write-Host "Likely server endpoint: $remoteIp`:$remotePort (seen $($top.Count) times during sampling)" -ForegroundColor Green
Write-Host "Pinging $remoteIp $PingCount times..." -ForegroundColor Cyan
Write-Host ""

# Ping (ICMP). Many servers block this.
$results = Test-Connection -ComputerName $remoteIp -Count $PingCount -ErrorAction SilentlyContinue

if (-not $results) {
    Write-Host "No ping replies received. ICMP may be blocked (very common for game servers)." -ForegroundColor Yellow
    exit 2
}

$times = $results | Select-Object -ExpandProperty ResponseTime
$avg = [Math]::Round(($times | Measure-Object -Average).Average, 2)
$min = ($times | Measure-Object -Minimum).Minimum
$max = ($times | Measure-Object -Maximum).Maximum

$loss = $PingCount - $times.Count
$lossPct = [Math]::Round(($loss / $PingCount) * 100, 1)

Write-Host "Server IP:        $remoteIp"
Write-Host "Server Port:      $remotePort"
Write-Host "Ping sent:        $PingCount"
Write-Host "Ping received:    $($times.Count)"
Write-Host "Packet loss:      $loss ($lossPct`%)"
Write-Host "Ping min/avg/max:  $min / $avg / $max ms" -ForegroundColor Green
