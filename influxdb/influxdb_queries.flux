// ============================================================================
// CONSULTAS FLUX PARA INFLUXDB 2.x Y GRAFANA
// Caso Empresarial: DataCenter Andino S.A.C.
// Bucket: monitoreo_datacenter | Organización: DataCenter_Andino_SAC
//
// Cada bloque es una consulta independiente: copie y ejecute una a la vez.
// Dónde ejecutarlas:
//  - InfluxDB (http://localhost:8086) -> Data Explorer -> Script Editor, o
//  - Grafana (http://localhost:3000) -> Explore, con la fuente de datos InfluxDB en modo Flux.
// Las consultas 6, 7 y 8 usan el rango de tiempo del panel (v.timeRangeStart / v.timeRangeStop).
// ============================================================================

// 1. PANEL GRAFANA: Última Lectura de Temperatura (°C)
// Se usa group() antes de last() para garantizar un único valor escalar
from(bucket: "monitoreo_datacenter")
  |> range(start: -15m)
  |> filter(fn: (r) => r["_measurement"] == "ambiente_sala")
  |> filter(fn: (r) => r["_field"] == "temperature_c")
  |> group(columns: ["_field"])
  |> last()

// 2. PANEL GRAFANA: Estado Actual de Monitoreo Térmico (0=NORMAL, 1=ADVERTENCIA, 2=CRITICO)
from(bucket: "monitoreo_datacenter")
  |> range(start: -15m)
  |> filter(fn: (r) => r["_measurement"] == "ambiente_sala")
  |> filter(fn: (r) => r["_field"] == "estado_temp_code")
  |> group(columns: ["_field"])
  |> last()

// 3. PANEL GRAFANA: Última Lectura de Iluminación Calibrada (%)
from(bucket: "monitoreo_datacenter")
  |> range(start: -15m)
  |> filter(fn: (r) => r["_measurement"] == "ambiente_sala")
  |> filter(fn: (r) => r["_field"] == "light_pct")
  |> group(columns: ["_field"])
  |> last()

// 4. PANEL GRAFANA: Estado de Luminarias (0=APAGADO, 1=PARCIAL, 2=ENCENDIDO)
from(bucket: "monitoreo_datacenter")
  |> range(start: -15m)
  |> filter(fn: (r) => r["_measurement"] == "ambiente_sala")
  |> filter(fn: (r) => r["_field"] == "estado_luz_code")
  |> group(columns: ["_field"])
  |> last()

// 5a. PANEL GRAFANA: Fecha y Hora de la Última Lectura Recibida
// Convierte _time a milisegundos epoch; el panel lo muestra con la unidad "dateTimeAsLocal"
from(bucket: "monitoreo_datacenter")
  |> range(start: -15m)
  |> filter(fn: (r) => r["_measurement"] == "ambiente_sala")
  |> filter(fn: (r) => r["_field"] == "seq_id")
  |> group()
  |> last()
  |> map(fn: (r) => ({_value: int(v: r._time) / 1000000}))

// 5b. PANEL GRAFANA: Número de Secuencia (seq_id) de la Última Lectura
from(bucket: "monitoreo_datacenter")
  |> range(start: -15m)
  |> filter(fn: (r) => r["_measurement"] == "ambiente_sala")
  |> filter(fn: (r) => r["_field"] == "seq_id")
  |> group()
  |> last()
  |> keep(columns: ["_value"])

// 6. PANEL GRAFANA: Tendencia Histórica de Temperatura (°C)
// Puntos crudos (uno cada 5 s). El panel corta la línea cuando pasan más de 15 s sin
// lecturas (insertNulls = 15000), lo que hace visible la brecha de la Prueba (e).
from(bucket: "monitoreo_datacenter")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r["_measurement"] == "ambiente_sala")
  |> filter(fn: (r) => r["_field"] == "temperature_c")
  |> keep(columns: ["_time", "_value"])

// 7. PANEL GRAFANA: Tendencia Histórica de Iluminación (%)
from(bucket: "monitoreo_datacenter")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r["_measurement"] == "ambiente_sala")
  |> filter(fn: (r) => r["_field"] == "light_pct")
  |> keep(columns: ["_time", "_value"])

// 8. PANEL GRAFANA: Bitácora de Alertas Críticas y Eventos Registrados
// group() une en una sola tabla las alertas críticas y las lecturas inválidas
from(bucket: "monitoreo_datacenter")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r["_measurement"] == "eventos_alerta")
  |> pivot(rowKey:["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> group()
  |> drop(columns: ["_start", "_stop", "_measurement"])
  |> sort(columns: ["_time"], desc: true)

// 9. EVIDENCIA DE PERSISTENCIA: Tabla cruda con marca de tiempo y seq_id
// Permite ver en pantalla el salto de seq_id producido por el corte de la Prueba (e)
from(bucket: "monitoreo_datacenter")
  |> range(start: -15m)
  |> filter(fn: (r) => r["_measurement"] == "ambiente_sala")
  |> filter(fn: (r) => r["_field"] == "seq_id" or r["_field"] == "temperature_c" or r["_field"] == "light_pct" or r["_field"] == "estado_temp_code")
  |> pivot(rowKey:["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> group()
  |> keep(columns: ["_time", "seq_id", "temperature_c", "light_pct", "estado_temp_code"])
  |> sort(columns: ["_time"], desc: true)

// ============================================================================
// CONSULTAS DE AUDITORÍA PARA LOS TRES INDICADORES DE DESEMPEÑO (KPIs)
// Ventana de prueba: últimos 15 minutos. Para que el KPI 2 sea válido, no reinicie
// la simulación de Wokwi dentro de esa ventana (seq_id volvería a 1) ni pulse los
// nodos inject (a)-(d) de Node-RED (usan seq_id 101-104).
// ============================================================================

// ----------------------------------------------------------------------------
// KPI 1: Latencia Promedio de Transporte MQTT por el Broker Mosquitto (ms)
// Cada 10 s Node-RED publica una sonda con su hora en el tópico sonda_latencia y mide
// cuánto tarda en recibirla de vuelta (Node-RED -> Mosquitto -> Node-RED).
// Se mide con un solo reloj (el de Node-RED), por lo que no depende de la velocidad
// de la simulación de Wokwi.
// La latencia de visualización en pantalla es esta cifra más la espera hasta el
// siguiente refresco de Grafana (entre 0 y 5 s).
// ----------------------------------------------------------------------------
from(bucket: "monitoreo_datacenter")
  |> range(start: -15m)
  |> filter(fn: (r) => r["_measurement"] == "diagnostico_enlace")
  |> filter(fn: (r) => r["_field"] == "latencia_mqtt_ms")
  |> group()
  |> mean()
  |> yield(name: "KPI1_latencia_mqtt_promedio_ms")

// ----------------------------------------------------------------------------
// KPI 2: Porcentaje de Mensajes Recibidos (PDR) comparando seq_id vs Conteo
// Calcula en una sola tabla:
//  - recibidos: total de puntos almacenados en InfluxDB
//  - esperados: (max_seq_id - min_seq_id + 1) emitidos por el ESP32
//  - perdidos:  mensajes no entregados durante el corte de red (Prueba E)
//  - pdr_pct:   porcentaje efectivo de entrega (0 a 100 %)
// ----------------------------------------------------------------------------
from(bucket: "monitoreo_datacenter")
  |> range(start: -15m)
  |> filter(fn: (r) => r["_measurement"] == "ambiente_sala")
  |> filter(fn: (r) => r["_field"] == "seq_id")
  |> group()
  |> toInt()
  |> reduce(
      identity: {count: 0, min_seq: 999999999, max_seq: 0},
      fn: (r, accumulator) => ({
        count: accumulator.count + 1,
        min_seq: if r._value < accumulator.min_seq then r._value else accumulator.min_seq,
        max_seq: if r._value > accumulator.max_seq then r._value else accumulator.max_seq
      })
    )
  |> map(fn: (r) => {
      esperados = r.max_seq - r.min_seq + 1
      perdidos = esperados - r.count
      pdr = if esperados > 0 then (float(v: r.count) / float(v: esperados)) * 100.0 else 0.0
      return {
        recibidos: r.count,
        seq_inicial: r.min_seq,
        seq_final: r.max_seq,
        publicados_esperados: esperados,
        mensajes_perdidos: perdidos,
        KPI2_porcentaje_recibidos_pdr: pdr
      }
    })
  |> yield(name: "KPI2_auditoria_pdr_seq_id")

// ----------------------------------------------------------------------------
// KPI 3: Tiempo de Detección de Condición Crítica (ms y segundos)
// tiempo_deteccion_ms = tiempo desde la última lectura NO crítica recibida hasta que
// Node-RED genera la alerta de la primera lectura >= 30 °C. La sala cruzó el umbral en
// algún momento de ese intervalo, así que es la cota superior del tiempo real de
// detección: aproximadamente un periodo de muestreo (5 s del nodo; en Wokwi puede ser
// mayor en tiempo real si la simulación corre por debajo del 100 %).
// Se registra una vez por episodio crítico.
// ----------------------------------------------------------------------------
from(bucket: "monitoreo_datacenter")
  |> range(start: -15m)
  |> filter(fn: (r) => r["_measurement"] == "eventos_alerta")
  |> filter(fn: (r) => r["severidad"] == "CRITICO")
  |> filter(fn: (r) => r["_field"] == "tiempo_deteccion_ms")
  |> group()
  |> mean()
  |> map(fn: (r) => ({
      KPI3_tiempo_deteccion_ms: r._value,
      KPI3_tiempo_deteccion_seg: r._value / 1000.0
    }))
  |> yield(name: "KPI3_tiempo_deteccion_critica")

// ============================================================================
// ALTERNATIVA EN SQL (solo para InfluxDB Cloud Serverless, cuyo Data Explorer no acepta Flux)
// Ejecute cada sentencia por separado, sin los "//" iniciales.
// ============================================================================
//
// Tabla cruda con marca de tiempo y seq_id:
//   SELECT time, seq_id, temperature_c, light_pct, estado_temp_str
//   FROM "ambiente_sala"
//   WHERE time >= now() - interval '15 minutes'
//   ORDER BY time DESC;
//
// KPI 1 - Latencia MQTT promedio (ms):
//   SELECT AVG(latencia_mqtt_ms) AS kpi1_latencia_mqtt_promedio_ms
//   FROM "diagnostico_enlace"
//   WHERE time >= now() - interval '15 minutes';
//
// KPI 2 - Mensajes recibidos vs. esperados:
//   SELECT COUNT(seq_id) AS recibidos,
//          MAX(seq_id) - MIN(seq_id) + 1 AS publicados_esperados,
//          MAX(seq_id) - MIN(seq_id) + 1 - COUNT(seq_id) AS mensajes_perdidos,
//          COUNT(seq_id) * 100.0 / (MAX(seq_id) - MIN(seq_id) + 1) AS kpi2_pdr_pct
//   FROM "ambiente_sala"
//   WHERE time >= now() - interval '15 minutes';
//
// KPI 3 - Tiempo de detección crítica (ms):
//   SELECT AVG(tiempo_deteccion_ms) AS kpi3_tiempo_deteccion_ms
//   FROM "eventos_alerta"
//   WHERE severidad = 'CRITICO' AND time >= now() - interval '15 minutes';
