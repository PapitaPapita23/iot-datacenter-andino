# Sistema IoT de Monitoreo de Temperatura e Iluminación — DataCenter Andino S.A.C.

Repositorio de la **Práctica Académica 3 (Unidad 3: Internet de las Cosas)** del curso *Herramientas de Desarrollo Profesional – TIC*. Implementa una arquitectura IoT de extremo a extremo, **con sensores simulados y sin contenedores**, para supervisar en tiempo real la temperatura y la iluminación de la sala de servidores de **DataCenter Andino S.A.C.**

```text
[DHT22 + LDR simulados en Wokwi]
        │
        ▼
[ESP32 (cliente MQTT publicador)] ── Wi-Fi Wokwi-GUEST, JSON cada 5 s
        │
        ▼
[Broker Mosquitto local (puerto 1883)]
        │
        ▼
[Node-RED local (puerto 1880): suscribe, valida, clasifica y genera alertas]
        │
        ▼
[InfluxDB 2.x local (puerto 8086): bucket monitoreo_datacenter]
        │
        ▼
[Grafana local (puerto 3000): valores actuales, históricos, estados y bitácora de alertas]
```

---

## 1. Estructura del Repositorio

```text
├── README.md                          # Esta guía: requisitos, instalación, parámetros, arranque y pruebas
├── .gitignore                         # Evita subir archivos .env, tokens, claves y carpetas locales
├── .env.example                       # Plantilla de variables de entorno (sin secretos)
├── wokwi_esp32/
│   ├── sketch.ino                     # Firmware ESP32: DHT22 + LDR (lux y %) + botón de corte de 30 s
│   ├── diagram.json                   # Circuito Wokwi (inicia en 24.5 °C y 6 lux)
│   ├── libraries.txt                  # Librerías para Wokwi en el navegador (PubSubClient, DHTesp)
│   ├── platformio.ini                 # Compilación local del firmware (para Wokwi for VS Code)
│   └── wokwi.toml                     # Configuración de Wokwi for VS Code
├── mosquitto/
│   └── mosquitto.conf                 # Configuración para un broker Mosquitto propio (incluye plantilla TLS)
├── nodered/
│   └── flows.json                     # Flujo exportado de Node-RED
├── influxdb/
│   └── influxdb_queries.flux          # Consultas de los paneles, tabla de persistencia y 3 KPIs
├── grafana/
│   └── grafana_dashboard.json         # Dashboard importable (pide la fuente de datos al importar)
└── scripts/
    ├── iniciar_servicios.ps1          # Arranca InfluxDB, Grafana y Node-RED en Windows
    └── detener_servicios.ps1          # Detiene los tres servicios
```

---

## 2. Requisitos

| Componente | Requisito |
| :--- | :--- |
| Sistema | Windows 10 u 11 (los scripts de arranque son PowerShell; los componentes también existen para Linux y macOS) |
| Simulador | VS Code con la extensión Wokwi, Python 3 y PlatformIO Core. No requiere hardware |
| Broker MQTT | Eclipse Mosquitto 2.x instalado en el equipo como servicio (incluye `mosquitto_sub` para verificar el broker) |
| Node-RED | Node.js LTS y Node-RED 3 o superior, con el paquete `node-red-contrib-influxdb` |
| InfluxDB | InfluxDB OSS 2.7 (binario para Windows) |
| Grafana | Grafana OSS 10.1 o superior (binario para Windows) |

Todos los servicios corren en el propio equipo y ninguno usa Docker ni contenedores. Probado con Mosquitto 2.1.2, Node-RED 5.0, InfluxDB 2.7.11 y Grafana 11.6.

---

## 3. Parámetros del Broker Mosquitto, Tópicos MQTT y Estructura de Datos

### 3.1. Parámetros del broker

| Parámetro | Valor |
| :--- | :--- |
| Host | `localhost` (`127.0.0.1`). El ESP32 simulado lo alcanza como `host.wokwi.internal` |
| Puerto | `1883` (TCP sin cifrar; `8883` con TLS en la propuesta productiva) |
| Alcance | Solo acepta conexiones del propio equipo |
| Autenticación | Anónima (sin usuario ni contraseña) |
| Archivo de configuración | `mosquitto/mosquitto.conf`, copiado a `C:\Program Files\mosquitto\mosquitto.conf` |
| Registro | `C:\ProgramData\mosquitto\mosquitto.log` (conexiones y desconexiones de clientes) |
| Client ID del ESP32 | `esp32-datacenter-andino-nodo01` |
| Client ID de Node-RED | `nodered-datacenter-andino` |
| KeepAlive | `10 s` en el ESP32, `30 s` en Node-RED |
| QoS | Telemetría del ESP32 en QoS 0 (límite de `PubSubClient`); LWT, suscripciones y alertas de Node-RED en QoS 1 |

Dos clientes con el mismo Client ID se desconectan entre sí: ejecute una sola simulación de Wokwi y una sola instancia de Node-RED a la vez.

Wokwi for VS Code permite que el ESP32 simulado llegue a los servicios del propio equipo con el nombre `host.wokwi.internal`. El simulador web de wokwi.com no puede hacerlo: para usarlo hay que compilar el entorno `publico` (`python -m platformio run -d wokwi_esp32 -e publico`), que apunta al broker de pruebas `test.mosquitto.org`, y poner ese mismo host en el nodo de broker de Node-RED.

### 3.2. Tópicos MQTT

| Tópico | Dirección | Contenido |
| :--- | :--- | :--- |
| `datacenter_andino/sala_servidores/telemetria` | ESP32 → Mosquitto → Node-RED | Lectura de temperatura, humedad e iluminación cada 5 s |
| `datacenter_andino/sala_servidores/alertas` | Node-RED → Mosquitto | Alerta cuando la temperatura es crítica (`>= 30.0 °C`) |
| `datacenter_andino/sala_servidores/estado_nodo` | ESP32 / Mosquitto (LWT, retenido) | `CONECTADO` al iniciar sesión; `DESCONECTADO` cuando el broker detecta la caída del nodo |
| `datacenter_andino/sala_servidores/sonda_latencia` | Node-RED → Mosquitto → Node-RED | Sonda cada 10 s para medir la latencia de transporte del broker (KPI 1) |

### 3.3. Estructura del mensaje de telemetría (JSON)

```json
{
  "node_id": "esp32-sala-01",
  "location": "Sala_Servidores_Principal",
  "seq_id": 103,
  "timestamp_epoch": 1791919500,
  "timestamp_ms": 1791919500123,
  "uptime_ms": 515000,
  "temperature_c": 33.00,
  "humidity_pct": 42.00,
  "ldr_raw": 3497,
  "light_lux": 8.0,
  "light_pct": 14.60,
  "sensor_error": false
}
```

- `seq_id` aumenta en 1 con cada muestreo, se haya podido publicar o no. Un salto en la secuencia indica mensajes perdidos.
- `timestamp_ms` es la hora NTP del nodo en milisegundos, con fines informativos. Vale `0` mientras el reloj no está sincronizado. No se usa para medir latencias, porque el reloj simulado de Wokwi se atrasa cuando la simulación corre por debajo del 100 %.
- Si el DHT22 entrega una lectura inválida, el nodo envía `temperature_c: null`, `humidity_pct: null` y `sensor_error: true`.

### 3.4. Estructura de datos en InfluxDB

La marca de tiempo (`_time`) de cada punto es la hora en que Node-RED lo escribe.

| Medición | Tags | Fields |
| :--- | :--- | :--- |
| `ambiente_sala` | `node_id`, `location` | `temperature_c`, `humidity_pct`, `light_pct`, `light_lux`, `ldr_raw`, `estado_temp_str`, `estado_temp_code`, `estado_luz_str`, `estado_luz_code`, `seq_id`, `intervalo_ms` |
| `eventos_alerta` | `node_id`, `location`, `severidad` (`CRITICO` o `ERROR_SENSOR`) | `tipo_evento`, `mensaje`, `seq_id`; en alertas críticas además `temperature_c`, `light_pct`, `umbral_superado`, `tiempo_deteccion_ms` |
| `diagnostico_enlace` | `origen` | `latencia_mqtt_ms` |

Todos los tiempos se miden con el reloj de Node-RED:

- `intervalo_ms`: tiempo real entre dos lecturas consecutivas recibidas.
- `tiempo_deteccion_ms`: tiempo desde la última lectura no crítica hasta la alerta de la primera lectura crítica; se registra una vez por episodio.
- `latencia_mqtt_ms`: ida y vuelta de la sonda Node-RED → Mosquitto → Node-RED.

Node-RED no escribe valores estimados: si un tiempo no puede medirse, el campo se omite.

### 3.5. Reglas de clasificación en Node-RED

| Variable | Estado | Condición | Código |
| :--- | :--- | :--- | :--- |
| Temperatura | `NORMAL` | `< 28.0 °C` | `0` |
| Temperatura | `ADVERTENCIA` | `>= 28.0 °C` y `< 30.0 °C` | `1` |
| Temperatura | `CRITICO` | `>= 30.0 °C` (genera alerta registrada) | `2` |
| Iluminación | `APAGADO` | `< 20 %` | `0` |
| Iluminación | `ILUMINACION_PARCIAL` | `20 %` a `59.9 %` | `1` |
| Iluminación | `ENCENDIDO` | `>= 60 %` | `2` |

Los umbrales de temperatura son parámetros didácticos de la práctica, no límites normativos. El nivel de luz es una variable ambiental complementaria: por sí solo no demuestra presencia de personas ni intrusiones.

Las lecturas inválidas (nulas, `NaN`, temperatura fuera de `-10 °C` a `85 °C` o luz fuera de `0 %` a `100 %`) no se escriben en `ambiente_sala`; quedan registradas en `eventos_alerta` como `MEDICION_INVALIDA`.

---

## 4. Instalación y Arranque (sin contenedores)

Siga los pasos en este orden. Las rutas de ejemplo usan la carpeta `%USERPROFILE%\iot-datacenter-local`.

### Paso 1: Instalar los componentes
1. **Node-RED.** Instale [Node.js LTS](https://nodejs.org/) y ejecute:
   ```powershell
   npm install -g node-red
   mkdir $env:USERPROFILE\.node-red -Force; cd $env:USERPROFILE\.node-red
   npm install node-red-contrib-influxdb
   ```
2. **InfluxDB.** Descargue el binario de InfluxDB OSS 2.7 para Windows desde [influxdata.com/downloads](https://www.influxdata.com/downloads/) y descomprímalo de modo que quede `%USERPROFILE%\iot-datacenter-local\influxdb\influxd.exe`.
3. **Grafana.** Descargue el binario independiente (zip) de Grafana OSS para Windows desde [grafana.com/grafana/download](https://grafana.com/grafana/download?platform=windows) y descomprímalo en `%USERPROFILE%\iot-datacenter-local\` (quedará una carpeta `grafana-v…` con `bin\grafana.exe`).
4. **Mosquitto.** Instálelo con `winget install EclipseFoundation.Mosquitto` o con el instalador de [mosquitto.org/download](https://mosquitto.org/download/). Queda como servicio de Windows.
5. **Variables de entorno.** Copie `.env.example` como `.env` y defina `GRAFANA_PASSWORD`: será la contraseña del usuario `admin` de Grafana. El archivo `.env` no se sube al repositorio.

### Paso 2: Configurar el broker Mosquitto y arrancar los servicios
1. Aplique la configuración del repositorio al broker. En PowerShell **como administrador**, desde la carpeta raíz del proyecto:
   ```powershell
   New-Item -ItemType Directory -Force C:\ProgramData\mosquitto
   Copy-Item mosquitto\mosquitto.conf "C:\Program Files\mosquitto\mosquitto.conf"
   Restart-Service mosquitto
   ```
   El broker queda escuchando en `localhost:1883` y arranca solo con Windows.
2. Arranque los otros tres servicios, ya sin permisos de administrador:
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\iniciar_servicios.ps1
   ```
   El script abre InfluxDB (`http://localhost:8086`), Grafana (`http://localhost:3000`) y Node-RED (`http://localhost:1880`), cada uno en su ventana, y muestra cuáles quedaron listos. Para detenerlos, ejecute `scripts\detener_servicios.ps1`.

Los cuatro servicios escuchan solo en el propio equipo.

### Paso 3: Configurar InfluxDB
1. Abra `http://localhost:8086` y complete la configuración inicial: usuario y contraseña, organización **`DataCenter_Andino_SAC`** y bucket **`monitoreo_datacenter`**.
2. Copie el **token de operador** que muestra la pantalla final y guárdelo en `INFLUXDB_TOKEN` de su archivo `.env`.

### Paso 4: Importar el flujo en Node-RED
1. Abra `http://localhost:1880`.
2. En **Menú (☰) → Import**, seleccione `nodered/flows.json` y pulse **Import**.
3. Abra el nodo **`Escribir en InfluxDB (ambiente_sala)`** y pulse el lápiz junto a **Server**: verifique la **URL** `http://localhost:8086`, pegue el **Token** y guarde.
4. Verifique en ese nodo y en **`Registrar Alerta en InfluxDB (eventos_alerta)`** que **Organization** sea `DataCenter_Andino_SAC` y **Bucket** sea `monitoreo_datacenter`.
5. Pulse **Deploy**. Los dos nodos MQTT deben mostrar **`connected`** en verde.

### Paso 5: Ejecutar el nodo ESP32 en Wokwi for VS Code
1. Instale en VS Code la extensión **Wokwi Simulator** y active su licencia (`F1` → `Wokwi: Request a New License`).
2. Instale PlatformIO Core y compile el firmware (la primera vez descarga el compilador del ESP32):
   ```bash
   python -m pip install --user platformio
   python -m platformio run -d wokwi_esp32
   ```
3. Abra `wokwi_esp32/diagram.json` en VS Code y ejecute `F1` → `Wokwi: Start Simulator`. Si VS Code pide un archivo de configuración, elija `wokwi_esp32/wokwi.toml`.
4. Tras modificar `sketch.ino`, repita la compilación del punto 2 y reinicie la simulación.

El monitor serial mostrará la conexión a `Wokwi-GUEST`, la conexión al broker `host.wokwi.internal` y una línea `[MQTT PUB QoS0 #...]` cada 5 segundos. Compruebe que la primera lectura de luz sea cercana a `12 %`; si no lo es, haga clic en el sensor LDR y lleve el deslizador a `6 lux`.

### Paso 6: Verificar la recepción en el broker Mosquitto
1. Suscríbase a los tres tópicos del proyecto:
   ```powershell
   & "C:\Program Files\mosquitto\mosquitto_sub.exe" -h localhost -p 1883 -v -t "datacenter_andino/sala_servidores/telemetria" -t "datacenter_andino/sala_servidores/alertas" -t "datacenter_andino/sala_servidores/estado_nodo"
   ```
2. Debe aparecer el estado retenido `CONECTADO` y, cada 5 segundos, un mensaje JSON de telemetría.

### Paso 7: Conectar Grafana con InfluxDB e importar el dashboard
1. Abra `http://localhost:3000` e ingrese con el usuario `admin` y la contraseña definida en `.env`.
2. Vaya a **Connections → Data sources → Add new data source → InfluxDB**.
3. En **Query language**, seleccione **`Flux`**. Complete **URL** (`http://localhost:8086`), **Organization** (`DataCenter_Andino_SAC`), **Token** y **Default Bucket** (`monitoreo_datacenter`). Pulse **Save & test**.
4. Vaya a **Dashboards → New → Import**, suba `grafana/grafana_dashboard.json`, elija su fuente de datos InfluxDB en el selector y pulse **Import**.
5. El dashboard abre en **`Last 15 minutes`** con actualización cada **`5s`** y muestra:
   - última temperatura e iluminación,
   - estado térmico y estado de luminarias,
   - fecha, hora y número de secuencia de la última lectura,
   - tendencias históricas de temperatura (con las líneas de 28 °C y 30 °C) e iluminación,
   - bitácora de alertas críticas y lecturas inválidas.

---

## 5. Equivalencia del Sensor LDR en Wokwi (lux y porcentaje)

El deslizador del módulo fotoresistor de Wokwi está graduado en **lux**. El ESP32 lee la tensión en el ADC de 12 bits (`0–4095`) y publica los lux calculados (`light_lux`) y el porcentaje calibrado `light_pct = (1 − ldr_raw / 4095) × 100`.

| Deslizador en Wokwi | `ldr_raw` aproximado | `light_pct` aproximado | Estado |
| :--- | :--- | :--- | :--- |
| **`6 lux`** (valor inicial) | `3590` | `12 %` | `APAGADO` |
| **`50 lux`** | `2530` | `38 %` | `ILUMINACION_PARCIAL` |
| **`1400 lux`** (Prueba d) | `560` | `86 %` | `ENCENDIDO` |

Los valores exactos de cada lectura aparecen en el monitor serial.

---

## 6. Pruebas Funcionales

Mantenga abiertos Wokwi, Node-RED (pestaña **Debug**), `mosquitto_sub` y el dashboard de Grafana.

| Prueba | Acción | Resultado esperado | Dónde verificarlo |
| :--- | :--- | :--- | :--- |
| **(a) Normal** | DHT22 en `24.5 °C`, LDR en `6 lux` | Estado `NORMAL` y luz `APAGADO` | Medidor verde y estado `NORMAL (<28°C)` en Grafana |
| **(b) Advertencia** | Subir DHT22 a `28.8 °C` | Estado `ADVERTENCIA`, sin alerta crítica | Medidor y estado en ámbar |
| **(c) Crítico** | Subir DHT22 a `33.0 °C` | Estado `CRITICO`, LED rojo en Wokwi y alerta registrada | Nodo `Log ALERTA CRÍTICA`, tópico `alertas` en `mosquitto_sub`, fila nueva en la bitácora de Grafana |
| **(d) Iluminación** | DHT22 a `25.0 °C`, LDR a `1400 lux` | Luz `ENCENDIDO` | Salto en la gráfica de iluminación y estado `ENCENDIDO (>=60%)` |
| **(e) Interrupción y recuperación** | Pulsar el botón negro de Wokwi (o enviar `e` por el monitor serial) | 30 s sin publicaciones; `DESCONECTADO` en `estado_nodo`; reconexión automática | Brecha en las gráficas, `Log Estado Conexión (LWT)` y salto de `seq_id` en InfluxDB |

Durante el corte de la prueba (e) el ESP32 sigue muestreando cada 5 s e incrementando `seq_id`, pero no publica: se pierden unos 6 mensajes. Al cumplirse los 30 s reconecta, publica `CONECTADO` y reanuda el envío.

Para probar el filtro de lecturas inválidas, pulse en Node-RED el nodo `Prueba (e): Lectura Inválida NaN / Error Sensor`: la lectura no llega a `ambiente_sala` y aparece en la bitácora como `MEDICION_INVALIDA`.

### Persistencia e indicadores

El archivo `influxdb/influxdb_queries.flux` contiene:

- **Consulta 9:** tabla de `ambiente_sala` con marca de tiempo y `seq_id`, para comprobar la persistencia y ver el salto de secuencia.
- **KPI 1 — Latencia de transporte MQTT:** promedio de `latencia_mqtt_ms` (sonda Node-RED → Mosquitto → Node-RED). La latencia en pantalla suma la espera hasta el siguiente refresco de Grafana (0 a 5 s).
- **KPI 2 — Porcentaje de mensajes recibidos:** compara los puntos almacenados con el rango de `seq_id` publicado.
- **KPI 3 — Tiempo de detección crítica:** promedio de `tiempo_deteccion_ms`, desde la última lectura no crítica hasta la alerta. Es la cota superior del tiempo de detección y equivale a un periodo de muestreo.

En Wokwi la simulación puede correr por debajo del tiempo real; en ese caso las lecturas llegan cada más de 5 s reales y el KPI 3 crece en la misma proporción.

Las consultas se ejecutan en el **Data Explorer** de InfluxDB (`http://localhost:8086`, con el editor de scripts) o en **Explore** de Grafana. Para que el KPI 2 sea válido, no reinicie la simulación de Wokwi ni pulse las pruebas (a)–(d) de Node-RED dentro de la ventana de 15 minutos.

---

## 7. Seguridad de Credenciales

- El token de InfluxDB se introduce únicamente en el nodo de configuración de Node-RED y en la fuente de datos de Grafana. No está en ningún archivo del repositorio.
- `.gitignore` excluye `.env`, `flows_cred.json`, certificados, claves y la carpeta de compilación `.pio/`.
- `.env.example` solo contiene valores de ejemplo.
- InfluxDB, Grafana y Node-RED escuchan únicamente en `127.0.0.1`, por lo que no son accesibles desde otros equipos de la red.

---

## 8. Subir el Proyecto a GitHub o GitLab

Desde la carpeta raíz del proyecto:

```bash
git init
git add .
git commit -m "Sistema IoT de monitoreo de sala de servidores - DataCenter Andino"
git branch -M main
git remote add origin https://github.com/SU_USUARIO/iot-datacenter-andino.git
git push -u origin main
```

Configure el repositorio como público, o comparta un enlace de lectura con el docente.
