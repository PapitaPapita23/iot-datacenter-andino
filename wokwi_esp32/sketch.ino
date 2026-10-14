/**
 * PRÁCTICA ACADÉMICA 3 - Herramientas de Desarrollo Profesional (TIC)
 * Caso Empresarial: DataCenter Andino S.A.C.
 * Entorno: Nodo simulado en Wokwi for VS Code + Mosquitto, Node-RED, InfluxDB y Grafana locales
 *
 * Componentes en Wokwi:
 *  - ESP32 DevKit V4
 *  - Sensor DHT22 (Pin GPIO 15) -> Temperatura (°C) y Humedad (%)
 *  - Sensor LDR Módulo Fotoresistor (Pin ADC GPIO 34) -> Iluminación (% y Lux)
 *  - Botón Pulsador (Pin GPIO 4) -> Simula corte de red de 30 s para la Prueba (e)
 *  - LED Rojo (Pin GPIO 2) -> Indicador local de condición crítica (>= 30 °C)
 *
 * Notas técnicas de transporte MQTT:
 *  - La librería PubSubClient publica telemetría en QoS 0 y configura el mensaje
 *    Last Will and Testament (LWT) con QoS 1 y bandera Retain = true.
 *  - KeepAlive configurado en 10 s: en la Prueba E el ESP32 cierra el socket sin enviar
 *    DISCONNECT, por lo que el broker Mosquitto emite el LWT DESCONECTADO al detectar el
 *    cierre (normalmente en 1-2 s; como máximo tras 1.5 x KeepAlive = 15 s), mientras el
 *    ESP32 sigue incrementando seq_id cada 5 s para evidenciar los mensajes perdidos
 *    durante el corte antes de reconectar.
 *  - Cada trama incluye timestamp_ms (hora NTP del nodo en milisegundos) para que
 *    Node-RED mida la latencia de transporte. El reloj se resincroniza cada 15 s porque
 *    el reloj simulado de Wokwi se atrasa cuando la simulación corre por debajo del 100 %.
 */

#include <WiFi.h>
#include <PubSubClient.h>
#include "DHTesp.h"
#include <time.h>
#include <sys/time.h>
#include <math.h>
#include "esp_sntp.h"

// Configuración de Red Wi-Fi (Simulador Wokwi)
const char* WIFI_SSID = "Wokwi-GUEST";
const char* WIFI_PASSWORD = "";

// Configuración del Broker Mosquitto. Por defecto, el broker local de este equipo:
// desde la simulación de Wokwi for VS Code, el equipo anfitrión es host.wokwi.internal.
// Al compilar con PlatformIO (-e publico) se reemplaza por test.mosquitto.org.
#ifndef MQTT_BROKER_HOST
#define MQTT_BROKER_HOST "host.wokwi.internal"
#endif
const char* MQTT_BROKER = MQTT_BROKER_HOST;
const int   MQTT_PORT = 1883;
const char* MQTT_CLIENT_ID = "esp32-datacenter-andino-nodo01";

// Tópicos MQTT Jerárquicos
const char* TOPIC_TELEMETRY = "datacenter_andino/sala_servidores/telemetria";
const char* TOPIC_STATUS    = "datacenter_andino/sala_servidores/estado_nodo";

// Pines de Hardware en el ESP32
const int PIN_DHT = 15;      // DHT22 Data pin
const int PIN_LDR = 34;      // LDR Analog Output (ADC1_CH6 - 12 bits: 0..4095)
const int PIN_BTN_DROP = 4;  // Botón para activar corte de red de 30 s (Prueba E)
const int PIN_LED_CRIT = 2;  // LED indicador de condición crítica (>= 30 °C)

// Umbrales Operativos Didácticos (Regla 4 del Caso)
const float TEMP_WARN_THRESHOLD = 28.0;
const float TEMP_CRIT_THRESHOLD = 30.0;

// Constantes físicas del módulo LDR de Wokwi para cálculo de Lux
const float LDR_GAMMA = 0.7;
const float LDR_RL10 = 50.0; // Resistencia en kOhm a 10 lux

DHTesp dhtSensor;
WiFiClient espClient;
PubSubClient mqttClient(espClient);

unsigned long lastPublishTime = 0;
const unsigned long PUBLISH_INTERVAL_MS = 5000; // Publicación cada 5 segundos
unsigned long sequenceId = 0;                   // Contador correlativo seq_id

// Variables para simulación de Corte de Red (Prueba E: 30 segundos = 6 mensajes)
bool simulatingNetworkDrop = false;
unsigned long dropStartTimeMs = 0;
const unsigned long DROP_DURATION_MS = 30000; // 30 s de corte (dispara LWT y salta 6 seq_id)

const char* NTP_SERVER = "pool.ntp.org";

// Calcula los Lux reales del sensor LDR de Wokwi a partir de la lectura ADC (0..4095)
// El módulo es un divisor resistivo: LDR en serie con 10 kOhm, y AO entrega la fracción
// R_LDR / (R_LDR + 10k) de la tensión de alimentación, por lo que R_LDR = 10k * adc / (4095 - adc).
float calculateLuxFromADC(int adcVal) {
  if (adcVal <= 0) return 100000.0;
  if (adcVal >= 4095) return 0.1;
  float resistance = 10000.0 * (float)adcVal / (4095.0 - (float)adcVal);
  float lux = pow(LDR_RL10 * 1e3 * pow(10, LDR_GAMMA) / resistance, (1.0 / LDR_GAMMA));
  return lux;
}

void connectWiFi() {
  Serial.println();
  Serial.print("[Wi-Fi] Conectando a ");
  Serial.println(WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD, 6);

  while (WiFi.status() != WL_CONNECTED) {
    delay(400);
    Serial.print(".");
  }
  Serial.println();
  Serial.print("[Wi-Fi] Conectado exitosamente. IP: ");
  Serial.println(WiFi.localIP());
}

void reconnectMQTT() {
  if (simulatingNetworkDrop) {
    return; // No reconectar mientras dure la ventana de corte de la Prueba (e)
  }
  while (!mqttClient.connected()) {
    Serial.print("[MQTT] Conectando al broker Mosquitto (");
    Serial.print(MQTT_BROKER);
    Serial.print(")...");

    // LWT configurado con QoS 1 y Retain = true
    if (mqttClient.connect(
          MQTT_CLIENT_ID,
          TOPIC_STATUS,
          1,
          true,
          "{\"node_id\":\"esp32-sala-01\",\"status\":\"DESCONECTADO\"}"
        )) {
      Serial.println(" CONECTADO.");
      mqttClient.publish(
        TOPIC_STATUS,
        "{\"node_id\":\"esp32-sala-01\",\"status\":\"CONECTADO\"}",
        true
      );
    } else {
      Serial.print(" Falló (rc=");
      Serial.print(mqttClient.state());
      Serial.println("). Reintentando en 3 segundos...");
      delay(3000);
    }
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_LED_CRIT, OUTPUT);
  pinMode(PIN_BTN_DROP, INPUT_PULLUP);
  digitalWrite(PIN_LED_CRIT, LOW);

  dhtSensor.setup(PIN_DHT, DHTesp::DHT22);
  analogReadResolution(12); // ADC de 12 bits (0 - 4095)

  connectWiFi();
  sntp_set_sync_interval(15000); // Resincronizar NTP cada 15 s (mínimo permitido)
  configTime(0, 0, NTP_SERVER);

  mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
  mqttClient.setKeepAlive(10); // KeepAlive de 10 s para detección rápida de caída
  mqttClient.setBufferSize(512);

  Serial.println("==================================================================");
  Serial.println("NODO IOT DATACENTER ANDINO S.A.C. INICIADO");
  Serial.println("- Guía rápida del deslizador LDR en Wokwi:");
  Serial.println("  * ~6 lux    -> ~12 % (Estado: APAGADO < 20%)");
  Serial.println("  * ~50 lux   -> ~38 % (Estado: ILUMINACION_PARCIAL 20-59%)");
  Serial.println("  * ~1400 lux -> ~86 % (Estado: ENCENDIDO >= 60%)");
  Serial.println("- Para Prueba (e): presione el botón negro (GPIO 4) o envíe 'e'");
  Serial.println("  por el monitor serial para simular un corte de red de 30 s.");
  Serial.println("==================================================================");
}

void checkDropTrigger() {
  // Activar corte de 30 s si se presiona el botón en GPIO 4 o se envía 'e' por Serial
  bool btnPressed = (digitalRead(PIN_BTN_DROP) == LOW);
  bool serialTrigger = false;
  if (Serial.available() > 0) {
    char c = Serial.read();
    if (c == 'e' || c == 'E') serialTrigger = true;
  }

  if ((btnPressed || serialTrigger) && !simulatingNetworkDrop) {
    simulatingNetworkDrop = true;
    dropStartTimeMs = millis();
    // Cerrar socket TCP abruptamente para que el broker dispare el LWT tras el KeepAlive
    espClient.stop();
    Serial.println();
    Serial.println(">>> [PRUEBA E INICIADA] Corte de conexión MQTT simulado por 30 segundos.");
    Serial.println(">>> El ESP32 seguirá muestreando cada 5 s e incrementando seq_id,");
    Serial.println(">>> pero las publicaciones fallarán hasta recuperar la red.");
    delay(300);
  }

  if (simulatingNetworkDrop && (millis() - dropStartTimeMs >= DROP_DURATION_MS)) {
    simulatingNetworkDrop = false;
    Serial.println();
    Serial.println(">>> [PRUEBA E FINALIZADA] Fin del corte de 30 s. Reconectando a Mosquitto...");
    reconnectMQTT();
  }
}

void loop() {
  checkDropTrigger();

  if (!simulatingNetworkDrop) {
    if (WiFi.status() != WL_CONNECTED) {
      connectWiFi();
    }
    if (!mqttClient.connected()) {
      reconnectMQTT();
    }
    mqttClient.loop();
  }

  unsigned long now = millis();
  if (now - lastPublishTime >= PUBLISH_INTERVAL_MS) {
    lastPublishTime = now;
    sequenceId++;

    // 1. Lectura de Temperatura y Humedad desde DHT22
    TempAndHumidity data = dhtSensor.getTempAndHumidity();
    float tempC = data.temperature;
    float humPct = data.humidity;

    // 2. Lectura Analógica del LDR (0..4095), cálculo de Lux y Porcentaje Calibrado (0..100%)
    int ldrRaw = analogRead(PIN_LDR);
    float luxVal = calculateLuxFromADC(ldrRaw);
    float lightPct = (1.0 - ((float)ldrRaw / 4095.0)) * 100.0;
    if (lightPct < 0.0) lightPct = 0.0;
    if (lightPct > 100.0) lightPct = 100.0;

    // 3. Validación local ante mediciones inválidas (NaN)
    if (isnan(tempC) || isnan(humPct)) {
      Serial.println("[WARN] Lectura inválida (NaN) del sensor DHT22.");
      if (!simulatingNetworkDrop && mqttClient.connected()) {
        char errPayload[256];
        snprintf(errPayload, sizeof(errPayload),
                 "{\"node_id\":\"esp32-sala-01\",\"seq_id\":%lu,\"temperature_c\":null,\"humidity_pct\":null,\"ldr_raw\":%d,\"light_lux\":%.1f,\"light_pct\":%.2f,\"sensor_error\":true}",
                 sequenceId, ldrRaw, luxVal, lightPct);
        mqttClient.publish(TOPIC_TELEMETRY, errPayload);
      }
      return;
    }

    // LED local de alerta crítica (>= 30 °C)
    digitalWrite(PIN_LED_CRIT, (tempC >= TEMP_CRIT_THRESHOLD) ? HIGH : LOW);

    // Hora NTP del nodo: segundos (timestamp_epoch) y milisegundos (timestamp_ms).
    // timestamp_ms se arma concatenando segundos y milisegundos (3 dígitos) en un solo número;
    // vale 0 mientras el reloj aún no está sincronizado por NTP.
    struct timeval tvNow;
    gettimeofday(&tvNow, NULL);
    long epochNow = (long)tvNow.tv_sec;
    char timestampMs[20] = "0";
    if (epochNow > 1700000000L) {
      snprintf(timestampMs, sizeof(timestampMs), "%ld%03ld", epochNow, (long)(tvNow.tv_usec / 1000));
    }

    // 4. Construcción del Payload JSON identificable
    char payload[460];
    snprintf(payload, sizeof(payload),
             "{\"node_id\":\"esp32-sala-01\",\"location\":\"Sala_Servidores_Principal\",\"seq_id\":%lu,\"timestamp_epoch\":%ld,\"timestamp_ms\":%s,\"uptime_ms\":%lu,\"temperature_c\":%.2f,\"humidity_pct\":%.2f,\"ldr_raw\":%d,\"light_lux\":%.1f,\"light_pct\":%.2f,\"sensor_error\":false}",
             sequenceId, epochNow, timestampMs, now, tempC, humPct, ldrRaw, luxVal, lightPct);

    // 5. Publicación MQTT (o pérdida de paquete si estamos en la Prueba E de corte de red)
    if (simulatingNetworkDrop || !mqttClient.connected()) {
      Serial.print("[CORTE RED - MENSAJE PERDIDO #");
      Serial.print(sequenceId);
      Serial.print("] No enviado al broker -> ");
      Serial.println(payload);
    } else {
      bool published = mqttClient.publish(TOPIC_TELEMETRY, payload);
      if (published) {
        Serial.print("[MQTT PUB QoS0 #");
        Serial.print(sequenceId);
        Serial.print(" | Luz: ");
        Serial.print(luxVal, 1);
        Serial.print(" lux = ");
        Serial.print(lightPct, 1);
        Serial.print("%] ");
        Serial.println(payload);
      } else {
        Serial.println("[MQTT ERR] Falló la publicación del mensaje.");
      }
    }
  }
}
