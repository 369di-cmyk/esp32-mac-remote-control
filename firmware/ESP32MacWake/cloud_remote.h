#pragma once
#include <NetworkClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <time.h>
#include <mbedtls/platform.h>
#include <esp_heap_caps.h>

uint32_t tlsPsramAllocations=0;
void *tlsCalloc(size_t count, size_t size) {
  if(psramFound()) {
    void *p=heap_caps_calloc(count,size,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
    if(p){tlsPsramAllocations++;return p;}
  }
  return heap_caps_calloc(count,size,MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT);
}
void tlsFree(void *p){heap_caps_free(p);}

String cloudOrigin, cloudKey, cloudMessage="未配置云端", cloudAckId, cloudAckResult, lastCloudId;
NetworkClientSecure cloudTLS;
HTTPClient cloudHTTP;
bool cloudHTTPReady=false;
uint32_t nextCloudPoll=0;

bool validCloudOrigin(String value) {
  if(!value.startsWith("https://") || !value.endsWith(".workers.dev") || value.length()>150) return false;
  String host=value.substring(8);
  for(unsigned i=0;i<host.length();i++) {
    char c=host[i]; if(!((c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='-'||c=='.')) return false;
  }
  return host.indexOf('.')>0;
}
void cloudSetup() {
  // The precompiled core defaults mbedTLS to internal RAM. Use its supported
  // allocator hook to place TLS buffers in the CAM's PSRAM; certificates stay verified.
  mbedtls_platform_set_calloc_free(tlsCalloc,tlsFree);
  cloudOrigin=prefs.getString("cloud_url","");cloudKey=prefs.getString("cloud_key","");
  lastCloudId=prefs.getString("last_cmd","");
  cloudTLS.useBuiltinCACertBundle();cloudTLS.setHandshakeTimeout(8);
  configTime(0,0,"time.cloudflare.com","time.google.com","pool.ntp.org");
  web.on("/cloud",HTTP_GET,[](){
    if(!authenticated())return;
    JsonDocument d;d["configured"]=cloudOrigin.length()>0;d["origin"]=cloudOrigin;d["status"]=cloudMessage;d["free_heap"]=ESP.getFreeHeap();d["largest_heap"]=ESP.getMaxAllocHeap();d["psram"]=ESP.getPsramSize();d["free_psram"]=ESP.getFreePsram();d["tls_psram_allocations"]=tlsPsramAllocations;d["unix_time"]=time(nullptr);
    String out;serializeJson(d,out);web.sendHeader("Cache-Control","no-store");web.send(200,"application/json",out);
  });
  web.on("/cloud/configure",HTTP_POST,[](){
    if(!authenticated())return;
    String origin=web.arg("origin"),key=web.arg("device_key");origin.trim();key.trim();
    if(!validCloudOrigin(origin)||key.length()!=64){web.send(400,"text/plain","Invalid origin or device key");return;}
    for(unsigned i=0;i<key.length();i++)if(!isxdigit(key[i])){web.send(400,"text/plain","Invalid key");return;}
    cloudOrigin=origin;cloudKey=key; prefs.putString("cloud_url",origin);prefs.putString("cloud_key",key);
    cloudHTTP.end();cloudHTTPReady=false;nextCloudPoll=0;cloudMessage="正在连接云端";
    web.send(200,"application/json","{\"saved\":true}");
  });
}
void cloudPoll() {
  if(setupMode||WiFi.status()!=WL_CONNECTED||cloudOrigin.isEmpty()||cloudKey.length()!=64)return;
  if(int32_t(millis()-nextCloudPoll)<0)return;
  nextCloudPoll=millis()+3000;
  if(time(nullptr)<1704067200){cloudMessage="等待网络校时";return;}
  if(!cloudHTTPReady){
    cloudHTTPReady=cloudHTTP.begin(cloudTLS,cloudOrigin+"/v1/device/poll");
    cloudHTTP.setReuse(true);cloudHTTP.setTimeout(5000);cloudHTTP.setConnectTimeout(5000);
    cloudHTTP.addHeader("Content-Type","application/json");
    cloudHTTP.addHeader("Authorization","Bearer "+cloudKey);
  }
  if(!cloudHTTPReady){cloudMessage="云端连接初始化失败";return;}
  JsonDocument request;
  request["ready"]=connected&&encrypted&&subscribed()&&!armed;
  request["uptime_ms"]=millis();
  if(!cloudAckId.isEmpty()){request["ack"]["id"]=cloudAckId;request["ack"]["result"]=cloudAckResult;}
  String payload;serializeJson(request,payload);
  int code=cloudHTTP.POST(payload);
  if(code!=200){
    char error[160]={}; int tlsCode=cloudTLS.lastError(error,sizeof(error));
    cloudMessage="云端连接错误 "+String(code)+" / TLS "+String(tlsCode)+" "+error;
    Serial.printf("CLOUD_ERROR http=%d tls=%d heap=%lu max=%lu psram=%lu time=%lld %s\n",code,tlsCode,ESP.getFreeHeap(),ESP.getMaxAllocHeap(),ESP.getPsramSize(),(long long)time(nullptr),error);
    cloudHTTP.end();cloudHTTPReady=false;
    nextCloudPoll=millis()+10000;return;
  }
  String response=cloudHTTP.getString();
  if(response.length()>2048){cloudMessage="云端响应过大";return;}
  JsonDocument reply;
  if(deserializeJson(reply,response,DeserializationOption::NestingLimit(5))){cloudMessage="云端响应格式错误";return;}
  cloudAckId="";cloudAckResult="";cloudMessage="云端在线";
  if(reply["command"].isNull())return;
  String id=reply["command"]["id"]|"";
  String action=reply["command"]["action"]|"";
  uint64_t expiry=reply["command"]["expires_at"]|0ULL;
  if(action!="wake"||id.length()!=36||id==lastCloudId)return;
  cloudAckId=id;
  if(uint64_t(time(nullptr))*1000ULL>expiry){cloudAckResult="expired";return;}
  if(!connected||!encrypted||!subscribed()||armed){cloudAckResult="not_connected";return;}
  // Store before sending: reboot or a duplicated response must not re-execute an old command.
  if(prefs.putString("last_cmd",id)==0){cloudMessage="无法保存指令编号";cloudAckResult="not_connected";return;}
  lastCloudId=id; attempts++;
  uint8_t report[8]={0x02,0,0,0,0,0,0,0};
  keyboard->setValue(report,8);keyboard->notify();delay(100);
  report[0]=0;keyboard->setValue(report,8);keyboard->notify();
  sent++;result="已发送云端唤醒按键";cloudAckResult="report_sent";
  Serial.printf("CLOUD_WAKE_REPORT_SENT ms=%lu count=%lu\n",millis(),sent);
}
