// ESP32 Wi-Fi command relay -> bonded BLE keyboard wake. No password input.
// HTTPS cloud mailbox plus local control. No automatic periodic key presses.
#include <WiFi.h>
#include <WebServer.h>
#include <Preferences.h>
#include <ESPmDNS.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEHIDDevice.h>
#include <BLESecurity.h>
#include <esp32-hal-bt.h>

WebServer web(80);
Preferences prefs;
BLEHIDDevice *hid;
BLECharacteristic *keyboard;
volatile bool connected = false, encrypted = false, advertiseAgain = false;
bool setupMode = false, armed = false;
uint32_t due = 0, attempts = 0, sent = 0;
String accessKey, result = "尚未测试";

// Standard eight-byte keyboard report, report ID stored in GATT descriptor.
uint8_t reportMap[] = {
  0x05,0x01,0x09,0x06,0xA1,0x01,0x85,0x01,
  0x05,0x07,0x19,0xE0,0x29,0xE7,0x15,0x00,0x25,0x01,
  0x75,0x01,0x95,0x08,0x81,0x02,
  0x95,0x01,0x75,0x08,0x81,0x01,
  0x95,0x05,0x75,0x01,0x05,0x08,0x19,0x01,0x29,0x05,0x91,0x02,
  0x95,0x01,0x75,0x03,0x91,0x01,
  0x95,0x06,0x75,0x08,0x15,0x00,0x25,0x65,
  0x05,0x07,0x19,0x00,0x29,0x65,0x81,0x00,0xC0
};
class ConnectionCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *) override {
    connected = true; encrypted = false;
    Serial.printf("BLE_CONNECTED ms=%lu\n", millis());
  }
  void onDisconnect(BLEServer *) override {
    connected = encrypted = false; advertiseAgain = true;
    Serial.printf("BLE_DISCONNECTED ms=%lu\n", millis());
  }
};
class SecurityCallbacks : public BLESecurityCallbacks {
  bool onSecurityRequest() override { return true; }
  void onAuthenticationComplete(esp_ble_auth_cmpl_t auth) override {
    encrypted = auth.success;
    Serial.printf("BLE_AUTH success=%d ms=%lu\n", auth.success, millis());
  }
};
void startKeyboard() {
  // This accessory only uses BLE. Keep Classic Bluetooth RAM available for TLS.
  btMemRelease(BT_MODE_CLASSIC_BT);
  BLEDevice::init("CAM Mac Wake");
  BLESecurity::setCapability(ESP_IO_CAP_NONE);
  BLESecurity::setAuthenticationMode(true, false, true);
  BLEDevice::setSecurityCallbacks(new SecurityCallbacks());
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ConnectionCallbacks());
  hid = new BLEHIDDevice(server);
  hid->manufacturer()->setValue("ESP32 Mac Remote Control");
  hid->pnp(0x01, 0xFFFF, 0x0001, 0x0100);
  hid->hidInfo(0, 0x03); // Remote Wake + Normally Connectable.
  keyboard = hid->inputReport(1);
  hid->outputReport(1);
  hid->reportMap(reportMap, sizeof(reportMap));
  uint8_t released[8] = {};
  keyboard->setValue(released, sizeof(released));
  hid->setBatteryLevel(100);
  hid->startServices();
  BLEAdvertising *ad = BLEDevice::getAdvertising();
  ad->setAppearance(HID_KEYBOARD);
  ad->addServiceUUID(hid->hidService()->getUUID());
  ad->setScanResponse(true);
  ad->setMinPreferred(0x06); ad->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();
  Serial.println("BLE_READY: CAM Mac Wake");
}
bool subscribed() {
  auto cccd = static_cast<BLE2902 *>(keyboard->getDescriptorByUUID(BLEUUID((uint16_t)0x2902)));
  return cccd && cccd->getNotifications();
}
bool authenticated() {
  if (web.authenticate("wake", accessKey.c_str())) return true;
  web.requestAuthentication(); return false;
}
String statusJson() {
  long remaining = armed ? max(0L, (long)(int32_t(due-millis())/1000)) : 0;
  return String("{\"connected\":") + (connected?"true":"false") +
    ",\"encrypted\":" + (encrypted?"true":"false") +
    ",\"subscribed\":" + (subscribed()?"true":"false") +
    ",\"armed\":" + (armed?"true":"false") +
    ",\"remaining\":" + remaining + ",\"attempts\":" + attempts +
    ",\"reports_sent\":" + sent + ",\"uptime_ms\":" + millis() +
    ",\"result\":\"" + result + "\"}";
}
void armWake(uint32_t seconds) {
  due = millis() + seconds*1000; armed = true;
  result = "等待定时发送";
  Serial.printf("WAKE_ARMED delay_s=%lu due_ms=%lu\n", seconds, due);
}
#include "cloud_remote.h"

void setup() {
  pinMode(4, OUTPUT); digitalWrite(4, LOW); // Keep the ESP32-CAM flash LED off.
  Serial.begin(115200); delay(400);
  prefs.begin("macwake", false);
  accessKey = prefs.getString("key", "");
  if (accessKey.length() != 16 && accessKey.length() != 32) {
    char generated[33];
    snprintf(generated, sizeof(generated), "%08lx%08lx%08lx%08lx",
      (unsigned long)esp_random(), (unsigned long)esp_random(),
      (unsigned long)esp_random(), (unsigned long)esp_random());
    accessKey = generated;
    prefs.putString("key", accessKey);
  }
  startKeyboard();
  WiFi.mode(WIFI_STA);
  WiFi.setHostname("esp32-remote-control");
  String ssid = prefs.getString("ssid", ""), password = prefs.getString("password", "");
  if (!ssid.isEmpty()) {
    WiFi.begin(ssid.c_str(), password.c_str());
    uint32_t started = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - started < 20000) delay(100);
  }
  if (WiFi.status() != WL_CONNECTED) {
    setupMode = true;
    WiFi.mode(WIFI_AP);
    WiFi.softAP("ESP32-Remote-Setup", accessKey.c_str());
    Serial.println("SETUP_AP: ESP32-Remote-Setup");
  } else {
    WiFi.setAutoReconnect(true);
    MDNS.begin("esp32-remote-control");
  }
  // Local USB console only. Never upload provisioning logs or flash backups.
  Serial.printf("LOCAL_URL: http://%s/\n",
    (setupMode ? WiFi.softAPIP() : WiFi.localIP()).toString().c_str());
  Serial.println("LOCAL_USERNAME: wake");
  Serial.printf("LOCAL_SETUP_PASSWORD: %s\n", accessKey.c_str());

  web.on("/", HTTP_GET, []() {
    if (!authenticated()) return;
    web.sendHeader("Cache-Control", "no-store");
    String page = R"HTML(<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ESP32 Mac Wake</title><body style="font:18px system-ui;max-width:680px;margin:32px auto;padding:16px">
<h1>ESP32 Mac Wake / 蓝牙唤醒</h1>
<p>This device sends one Shift press and release. Mac passwords stay on the Mac.<br>
设备只发送一次 Shift 按下与松开；Mac 登录密码仅保存在 Mac 上。</p>
<p><a href="/status">BLE status / 蓝牙状态</a> · <a href="/cloud">Relay status / 云端状态</a></p>
<form action="/wake" method="post"><button name="delay" value="0">Wake now / 立即唤醒</button>
<button name="delay" value="60">Wake after 60 s / 60 秒后唤醒</button></form>
<form action="/cancel" method="post"><button>Cancel timer / 取消定时</button></form>
<h2>Relay configuration / 云端配置</h2>
<p>Enter your own Worker origin and DEVICE_TOKEN. Save this before Wi-Fi setup.<br>
填写自己的 Worker 地址与 DEVICE_TOKEN；首次使用请先保存此项，再保存 Wi-Fi。</p>
<form action="/cloud/configure" method="post" autocomplete="off">
<p><label>Worker URL <input name="origin" type="url" required placeholder="https://your-worker.your-account.workers.dev"></label></p>
<p><label>DEVICE_TOKEN <input name="device_key" type="password" required minlength="64" maxlength="64" autocomplete="new-password"></label></p>
<button>Save relay / 保存云端设置</button></form>
)HTML";
    if (setupMode) page += R"HTML(
<h2>Wi-Fi setup / Wi-Fi 配置</h2>
<p>Use a 2.4 GHz network with internet access. Only the ESP32 changes its connection.<br>
使用可联网的 2.4 GHz 网络；这里只配置 ESP32 的连接。</p>
<form action="/configure" method="post" autocomplete="off">
<p><label>SSID <input name="ssid" required maxlength="32" autocomplete="off"></label></p>
<p><label>Wi-Fi password / 密码 <input name="pass" type="password" maxlength="64" autocomplete="new-password"></label></p>
<button>Save and restart / 保存并重启</button></form>)HTML";
    page += "</body></html>";
    web.send(200, "text/html; charset=utf-8", page);
  });
  web.on("/status", HTTP_GET, []() {
    if (!authenticated()) return;
    web.sendHeader("Cache-Control", "no-store");
    web.send(200, "application/json", statusJson());
  });
  web.on("/wake", HTTP_POST, []() {
    if (!authenticated()) return;
    String seconds = web.arg("delay");
    if (seconds != "0" && seconds != "60") { web.send(400, "text/plain", "Use delay=0 or delay=60"); return; }
    if (!connected || !encrypted || !subscribed()) { web.send(409, "text/plain", "BLE not ready / 蓝牙尚未就绪"); return; }
    if (armed) { web.send(409, "text/plain", "Already armed / 已安排唤醒"); return; }
    armWake(seconds.toInt());
    web.send(202, "application/json", "{\"accepted\":true}");
  });
  web.on("/cancel", HTTP_POST, []() {
    if (!authenticated()) return;
    armed = false;
    web.send(200, "application/json", "{\"cancelled\":true}");
  });
  web.on("/configure", HTTP_POST, []() {
    if (!authenticated()) return;
    if (!setupMode) { web.send(403, "text/plain", "Wi-Fi setup is available only in setup mode"); return; }
    String ssid = web.arg("ssid"), password = web.arg("pass");
    if (ssid.length() < 1 || ssid.length() > 32 || password.length() > 64) {
      web.send(400, "text/plain", "Invalid Wi-Fi configuration / Wi-Fi 配置无效"); return;
    }
    prefs.putString("ssid", ssid); prefs.putString("password", password);
    web.send(200, "text/html; charset=utf-8", "Saved. Reconnect your phone to its usual network; the ESP32 is restarting. / 已保存。请将手机重新连接到常用网络，ESP32 正在重启。");
    delay(1200); ESP.restart();
  });
  cloudSetup();
  web.begin();
  Serial.println("COMMANDS: STATUS / ARM60 / CANCEL");
}

void loop() {
  web.handleClient();
  if (advertiseAgain) { advertiseAgain = false; BLEDevice::startAdvertising(); }
  static String line;
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\r') continue;
    if (c == '\n') {
      line.trim();
      if (line == "STATUS") Serial.println(statusJson());
      else if (line == "ARM60" && connected && encrypted && subscribed() && !armed) armWake(60);
      else if (line == "CANCEL") armed = false;
      line = "";
    } else if (line.length() < 64) line += c;
  }
  if (armed && int32_t(millis() - due) >= 0) {
    if (connected && encrypted && subscribed()) {
      armed = false; attempts++;
      uint8_t report[8] = {0x02,0,0,0,0,0,0,0};
      keyboard->setValue(report, 8); keyboard->notify(); delay(100);
      report[0] = 0; keyboard->setValue(report, 8); keyboard->notify();
      sent++; result = "Wake report sent / 已发送唤醒按键";
      Serial.printf("WAKE_REPORT_SENT ms=%lu count=%lu\n", millis(), sent);
    } else if (int32_t(millis() - due) > 15000) {
      armed = false; attempts++; result = "BLE timeout / 蓝牙超时";
    }
  }
  cloudPoll();
  delay(5);
}
