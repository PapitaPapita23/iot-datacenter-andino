# ============================================================================
# Inicia los servicios locales del prototipo (sin contenedores):
#   InfluxDB  -> http://localhost:8086
#   Grafana   -> http://localhost:3000
#   Node-RED  -> http://localhost:1880
# Cada servicio se abre en su propia ventana minimizada. Si un servicio ya está
# escuchando en su puerto, no se vuelve a iniciar.
#
# Uso:  powershell -ExecutionPolicy Bypass -File scripts\iniciar_servicios.ps1
#       (opcional)  -Base "C:\ruta\donde\descomprimio\influxdb-y-grafana"
# ============================================================================
param(
    [string]$Base = "$env:USERPROFILE\iot-datacenter-local"
)

function Test-Port([int]$Port) {
    [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Wait-Port([int]$Port, [int]$Seconds = 60) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        if (Test-Port $Port) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

# Credenciales locales (solo se usan la primera vez que arranca Grafana)
$envFile = Join-Path $PSScriptRoot '..\.env'
$cfg = @{}
if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1]] = $Matches[2] }
}

# --- InfluxDB ---------------------------------------------------------------
if (Test-Port 8086) {
    Write-Host "InfluxDB ya estaba en ejecucion (puerto 8086)."
} else {
    $influxd = Join-Path $Base 'influxdb\influxd.exe'
    if (-not (Test-Path $influxd)) { Write-Host "No se encontro $influxd"; exit 1 }
    $datos = Join-Path $Base 'datos\influxdb'
    New-Item -ItemType Directory -Force $datos | Out-Null
    Start-Process -FilePath $influxd -WindowStyle Minimized -ArgumentList @(
        '--bolt-path', "`"$datos\influxd.bolt`"",
        '--engine-path', "`"$datos\engine`"",
        '--http-bind-address', '127.0.0.1:8086',
        '--reporting-disabled'
    )
    Write-Host "InfluxDB iniciando..."
}

# --- Grafana ----------------------------------------------------------------
if (Test-Port 3000) {
    Write-Host "Grafana ya estaba en ejecucion (puerto 3000)."
} else {
    $grafanaHome = Get-ChildItem $Base -Directory -Filter 'grafana*' | Select-Object -First 1
    if (-not $grafanaHome) { Write-Host "No se encontro la carpeta de Grafana en $Base"; exit 1 }
    $datos = Join-Path $Base 'datos\grafana'
    New-Item -ItemType Directory -Force $datos | Out-Null
    $env:GF_SERVER_HTTP_ADDR = '127.0.0.1'
    $env:GF_SERVER_HTTP_PORT = '3000'
    $env:GF_PATHS_DATA = $datos
    $env:GF_PATHS_LOGS = Join-Path $datos 'log'
    $env:GF_ANALYTICS_REPORTING_ENABLED = 'false'
    $env:GF_ANALYTICS_CHECK_FOR_UPDATES = 'false'
    $env:GF_USERS_DEFAULT_LANGUAGE = 'es-ES'
    if ($cfg.GRAFANA_USERNAME) { $env:GF_SECURITY_ADMIN_USER = $cfg.GRAFANA_USERNAME }
    if ($cfg.GRAFANA_PASSWORD) { $env:GF_SECURITY_ADMIN_PASSWORD = $cfg.GRAFANA_PASSWORD }
    Start-Process -FilePath (Join-Path $grafanaHome.FullName 'bin\grafana.exe') -WindowStyle Minimized -ArgumentList @(
        'server', '--homepath', "`"$($grafanaHome.FullName)`""
    )
    Write-Host "Grafana iniciando..."
}

# --- Node-RED ---------------------------------------------------------------
if (Test-Port 1880) {
    Write-Host "Node-RED ya estaba en ejecucion (puerto 1880)."
} else {
    $nodeRed = (Get-Command node-red.cmd -ErrorAction SilentlyContinue).Source
    if (-not $nodeRed) {
        $prefix = (& npm config get prefix).Trim()
        $nodeRed = Join-Path $prefix 'node-red.cmd'
    }
    if (-not (Test-Path $nodeRed)) { Write-Host "No se encontro Node-RED. Instalelo con: npm install -g node-red"; exit 1 }
    Start-Process -FilePath 'cmd.exe' -WindowStyle Minimized -ArgumentList @('/c', "`"$nodeRed`"")
    Write-Host "Node-RED iniciando..."
}

# --- Resumen ----------------------------------------------------------------
$servicios = @(
    @{ Nombre = 'InfluxDB'; Puerto = 8086; Url = 'http://localhost:8086' },
    @{ Nombre = 'Grafana';  Puerto = 3000; Url = 'http://localhost:3000' },
    @{ Nombre = 'Node-RED'; Puerto = 1880; Url = 'http://localhost:1880' }
)
Write-Host ""
foreach ($s in $servicios) {
    $estado = if (Wait-Port $s.Puerto 90) { 'LISTO      ' } else { 'NO RESPONDE' }
    Write-Host ("{0,-9} {1}  {2}" -f $s.Nombre, $estado, $s.Url)
}
