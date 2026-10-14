# ============================================================================
# Detiene los servicios locales del prototipo: Node-RED (1880), Grafana (3000)
# e InfluxDB (8086). Los datos almacenados no se borran.
#
# Uso:  powershell -ExecutionPolicy Bypass -File scripts\detener_servicios.ps1
# ============================================================================
$servicios = @(
    @{ Nombre = 'Node-RED'; Puerto = 1880 },
    @{ Nombre = 'Grafana';  Puerto = 3000 },
    @{ Nombre = 'InfluxDB'; Puerto = 8086 }
)
foreach ($s in $servicios) {
    $ids = Get-NetTCPConnection -State Listen -LocalPort $s.Puerto -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
    if (-not $ids) {
        Write-Host ("{0,-9} no estaba en ejecucion" -f $s.Nombre)
        continue
    }
    foreach ($id in $ids) {
        Stop-Process -Id $id -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Host ("{0,-9} detenido" -f $s.Nombre)
}
