// Single-device wake mailbox. No Mac login password or Wi-Fi credentials are used here.
const messages = {
  unauthorized: ['唤醒令牌无效。', 'Invalid wake token.'],
  device_offline: ['设备尚未上线或最近没有响应。', 'The device has not polled recently.'],
  bluetooth_not_ready: ['设备已联网，Mac 蓝牙尚未就绪。', 'Device online; Mac Bluetooth is not ready.'],
};
const reply = (value, status = 200) => {
  if (value.error) {
    [value.message, value.message_en] = messages[value.error] ||
      ['请求未完成：' + value.error, 'Request failed: ' + value.error];
  }
  if (value.accepted) {
    value.message = value.duplicate_suppressed ? '已有唤醒请求，请稍等。' : '唤醒请求已提交。';
    value.message_en = value.duplicate_suppressed ? 'A wake request is already pending.' : 'Wake request queued.';
  }
  return Response.json(value, {status, headers: {'Cache-Control': 'no-store'}});
};
const validToken = (given, expected) => {
  if (typeof expected !== 'string' || expected.length < 32 || given.length !== expected.length) return false;
  let difference = 0;
  for (let i = 0; i < given.length; i++) difference |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  return difference === 0;
};

async function readBody(request) {
  if (Number(request.headers.get('content-length')) > 2048) return {error: 'body_too_large', status: 413};
  const reader = request.body?.getReader();
  const chunks = [];
  let length = 0;
  if (reader) {
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > 2048) {
        await reader.cancel();
        return {error: 'body_too_large', status: 413};
      }
      chunks.push(value);
    }
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  let body;
  try { body = length ? JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes)) : {}; }
  catch { return {error: 'invalid_json', status: 400}; }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return {error: 'invalid_body', status: 400};
  return {body};
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    const device = path === '/v1/device/poll';
    if (!device && path !== '/v1/wake' && path !== '/v1/status') return reply({error: 'not_found'}, 404);
    const header = request.headers.get('Authorization') || '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : '';
    const allowed = device ? validToken(token, env.DEVICE_TOKEN) :
      validToken(token, env.PHONE_TOKEN) || validToken(token, env.DOT_TOKEN);
    if (!allowed) return reply({error: 'unauthorized'}, 401);
    if (request.method !== (path === '/v1/status' ? 'GET' : 'POST'))
      return reply({error: 'method_not_allowed'}, 405);
    return env.WAKE_RELAY.getByName('default').fetch(request);
  }
};

export class WakeRelay {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; }
  async fetch(request) {
    const path = new URL(request.url).pathname;
    let body = {};
    if (request.method === 'POST') {
      const parsed = await readBody(request);
      if (parsed.error) return reply({error: parsed.error}, parsed.status);
      body = parsed.body;
    }
    // Serialize queue updates to suppress simultaneous phone/optional client requests.
    return this.ctx.blockConcurrencyWhile(async () => {
      const now = Date.now(), state = await this.ctx.storage.get('state') || {};
      if (state.command?.state === 'queued' && state.command.expires_at <= now)
        state.command.state = 'expired';
      if (path === '/v1/device/poll') {
        if (typeof body.ready !== 'boolean' || !Number.isSafeInteger(body.uptime_ms) || body.uptime_ms < 0)
          return reply({error: 'invalid_device_status'}, 400);
        state.device = {last_seen: now, ready: body.ready, uptime_ms: body.uptime_ms};
        if (body.ack && state.command?.id === body.ack.id && state.command.state === 'claimed' &&
            ['report_sent', 'not_connected', 'expired'].includes(body.ack.result)) {
          state.command.state = body.ack.result;
          state.command.acknowledged_at = now;
        }
        let command = null;
        if (body.ready && state.command?.state === 'queued') {
          state.command.state = 'claimed'; state.command.claimed_at = now;
          command = {id: state.command.id, action: 'wake', expires_at: state.command.expires_at};
        }
        await this.ctx.storage.put('state', state);
        return reply({server_time: now, command});
      }
      const online = !!state.device && now - state.device.last_seen < 20000;
      if (path === '/v1/status') return reply({device_online: online, ble_ready: online && state.device.ready,
        command: state.command || null, mac_awake: 'unknown'});
      if (!online) return reply({error: 'device_offline'}, 503);
      if (!state.device.ready) return reply({error: 'bluetooth_not_ready'}, 409);
      const pending = state.command && ['queued', 'claimed'].includes(state.command.state) &&
        state.command.expires_at > now;
      if (pending || (state.command && now - state.command.created_at < 10000))
        return reply({accepted: true, duplicate_suppressed: true, command: state.command, mac_awake: 'unknown'}, 202);
      state.command = {id: crypto.randomUUID(), state: 'queued', created_at: now, expires_at: now + 30000};
      await this.ctx.storage.put('state', state);
      return reply({accepted: true, command: state.command, mac_awake: 'unknown'}, 202);
    });
  }
}
