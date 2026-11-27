R"LXJS(
(parameters, rawScript) => {
  'use strict';
  const stringify = JSON.stringify;
  const parse = JSON.parse;
  const now = Date.now;
  const utf8 = encodeURIComponent;
  const fromUtf8 = decodeURIComponent;
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const limit = 65536;
  const allowedQualities = ['128k', '320k', 'flac', 'flac24bit'];
  const timers = new Map();
  const queued = [];
  const events = Object.freeze({ request: 'request', inited: 'inited', updateAlert: 'updateAlert' });
  let timerId = 0;
  let handler;
  let capabilities;
  let phase = 'init';
  let result;
  const active = new Map();
  let issued = 0;
  let requests = 0;

  function bufferFrom(value, encoding = 'utf8') {
    if (value?.type === 'Buffer' && Array.isArray(value.data)) value = value.data;
    if (ArrayBuffer.isView(value)) value = Array.from(value);
    if (Array.isArray(value)) {
      if (value.length > limit) throw new RangeError('Input too long');
      return new Uint8Array(value);
    }
    if (typeof value !== 'string' || value.length > limit) throw new TypeError('Invalid buffer');
    if (encoding === 'hex') {
      if (!/^(?:[0-9a-f]{2})*$/i.test(value)) throw new TypeError('Invalid hex');
      return new Uint8Array((value.match(/../g) || []).map(byte => parseInt(byte, 16)));
    }
    if (encoding === 'base64') {
      const source = value.replace(/\s/g, '').replace(/=+$/, '');
      const bytes = [];
      let accumulator = 0;
      let bits = 0;
      for (const char of source) {
        const digit = alphabet.indexOf(char);
        if (digit < 0) throw new TypeError('Invalid base64');
        accumulator = (accumulator << 6) | digit;
        bits += 6;
        if (bits >= 8) bytes.push((accumulator >> (bits -= 8)) & 255);
      }
      return new Uint8Array(bytes);
    }
    if (encoding !== 'utf8' && encoding !== 'utf-8') throw new TypeError('Unsupported encoding');
    const encoded = utf8(value);
    const bytes = [];
    for (let i = 0; i < encoded.length; i++) {
      if (encoded[i] === '%') {
        bytes.push(parseInt(encoded.slice(i + 1, i + 3), 16));
        i += 2;
      } else {
        bytes.push(encoded.charCodeAt(i));
      }
    }
    if (bytes.length > limit) throw new RangeError('Input too long');
    return new Uint8Array(bytes);
  }

  function bufToString(buffer, encoding = 'utf8') {
    if ((!Array.isArray(buffer) && !ArrayBuffer.isView(buffer)) ||
        !Number.isInteger(buffer.length) || buffer.length > limit) throw new TypeError('Invalid buffer');
    if (encoding === 'base64') {
      let out = '';
      for (let i = 0; i < buffer.length; i += 3) {
        const n = ((buffer[i] & 255) << 16) | ((buffer[i + 1] & 255) << 8) | (buffer[i + 2] & 255);
        out += alphabet[n >> 18] + alphabet[(n >> 12) & 63] +
          (i + 1 < buffer.length ? alphabet[(n >> 6) & 63] : '=') +
          (i + 2 < buffer.length ? alphabet[n & 63] : '=');
      }
      return out;
    }
    let out = '';
    for (const value of buffer) {
      out += (encoding === 'hex' ? '' : '%') + (value & 255).toString(16).padStart(2, '0');
    }
    if (encoding === 'hex') return out;
    if (encoding === 'utf8' || encoding === 'utf-8') return fromUtf8(out);
    throw new TypeError('Unsupported encoding');
  }

  // LX Mobile copies just its public request options when lx.request is called.
  // Queue serialized fields, not script-owned objects that may change while
  // another candidate occupies a slot. Only admitted calls get an exchange ID.
  function captureRequest(url, {method = 'get', headers, body, form, formData, binary, timeout}) {
    if (ArrayBuffer.isView(body)) {
      if (body.length > limit) return null;
      body = {type: 'Buffer', data: Array.from(body)};
    }
    const wire = {__proto__: null, method, headers, body, form, formData, binary: binary === true,
      _responseBytes: parameters.env === 'desktop', _followRedirects: parameters.env === 'mobile'};
    if (typeof timeout === 'number' && timeout > 0) wire.timeout = Math.min(timeout, 60000);
    const options = stringify(wire);
    if (typeof options !== 'string' || options.length >= limit) return null;
    const fields = '"url":' + stringify(url) + ',"options":' + options;
    return fields.length < limit ? fields : null;
  }

  const lx = Object.freeze({
    EVENT_NAMES: events,
    env: parameters.env,
    version: '2.0.0',
    currentScriptInfo: Object.freeze({ ...parameters.info, rawScript }),
    utils: Object.freeze({ buffer: Object.freeze({ from: bufferFrom, bufToString }) }),
    on(event, listener) {
      if (event !== events.request || typeof listener !== 'function') {
        return Promise.reject(new Error('Unsupported LX event'));
      }
      handler = listener;
      return Promise.resolve();
    },
    send(event, data) {
      if (event !== events.inited || capabilities) return Promise.reject(new Error('Unsupported LX event'));
      const sources = {};
      for (const platform of ['tx', 'kw', 'kg', 'wy', 'mg']) {
        const item = data?.sources?.[platform];
        if (item?.type !== 'music' || !Array.isArray(item.actions) ||
            !item.actions.includes('musicUrl') || !Array.isArray(item.qualitys)) continue;
        const qualitys = allowedQualities.filter(quality => item.qualitys.includes(quality));
        if (qualitys.length) sources[platform] = { type: 'music', actions: ['musicUrl'], qualitys };
      }
      capabilities = { sources };
      return Promise.resolve();
    },
    request(url, options, callback) {
      if (++requests > 12) throw new RangeError('Request limit');
      if (typeof url !== 'string' || url.length > 2048 ||
          !options || typeof options !== 'object' || typeof callback !== 'function') {
        throw new TypeError('Invalid request');
      }
      const allowed = phase === 'play';
      const entry = { callback, active: true, allowed, fields: allowed ? captureRequest(url, options) : null };
      queued.push(entry);
      return () => {
        entry.active = false;
        entry.callback = undefined;
        entry.fields = null;
      };
    },
  });

  function setTimer(callback, delay = 0, ...args) {
    if (typeof callback !== 'function' || timers.size >= 32 || ++timerId > 128) {
      throw new RangeError('Timer limit');
    }
    timers.set(timerId, { at: now() + Math.min(8000, Math.max(0, Number(delay) || 0)), callback, args });
    return timerId;
  }
  const ignore = () => {};
  for (const [name, value] of Object.entries({
    lx, setTimeout: setTimer, clearTimeout: id => { timers.delete(id); },
    console: Object.freeze({ log: ignore, info: ignore, warn: ignore, error: ignore, debug: ignore }),
  })) {
    Object.defineProperty(globalThis, name, { value, writable: false, configurable: false });
  }

  // Match the mobile preload's dynamic code restriction. The worker still
  // enforces its OS sandbox and the host independently validates all messages.
  const denyCode = () => { throw new TypeError('Dynamic code is unavailable'); };
  for (const prototype of [Function.prototype, Object.getPrototypeOf(async () => {}),
    Object.getPrototypeOf(function* () {}), Object.getPrototypeOf(async function* () {})]) {
    Object.defineProperty(prototype, 'constructor', { value: denyCode, writable: false, configurable: false });
  }
  Object.defineProperty(globalThis, 'eval', { value: denyCode, writable: false, configurable: false });
  Object.defineProperty(globalThis, 'Function', { value: denyCode, writable: false, configurable: false });

  function deliver(callback, answer) {
    if (answer.response) {
      const wire = answer.response;
      const resp = {statusCode: wire.statusCode, statusMessage: wire.statusMessage,
        headers: wire.headers, body: wire.body};
      if (typeof wire._rawBase64 === 'string') {
        const raw = bufferFrom(wire._rawBase64, 'base64');
        if (wire._binary) resp.body = parameters.env === 'mobile'
          ? {type: 'Buffer', data: Array.from(raw)} : raw;
        if (parameters.env === 'desktop') {
          resp.raw = raw;
          resp.bytes = raw.length;
        }
      }
      callback(null, resp, resp.body);
    } else {
      callback(new Error('LX request failed'), null, null);
    }
  }

  return response => {
    if (response !== undefined) {
      const answer = parse(response);
      if (answer.pending !== true) {
        const entry = active.get(answer.id);
        if (!entry) return 'D{"error":"script"}';
        active.delete(answer.id);
        const callback = entry.callback;
        entry.callback = undefined;
        if (entry.active && !result) deliver(callback, answer);
        // Drain Promise jobs before admitting more work (e.g. a race winner).
        return 'T';
      }
    }
    for (const [id, entry] of active) {
      if (entry.active && !result) continue;
      active.delete(id);
      entry.callback = undefined;
      return 'X' + id;
    }
    if (result) return 'D' + stringify(result);
    if (phase === 'init' && capabilities) {
      if (typeof handler !== 'function') return 'D{"error":"init"}';
      if (!parameters.event) return 'D' + stringify({ capabilities });
      const { source, action, info } = parameters.event;
      if (action !== 'musicUrl' || !Object.hasOwn(capabilities.sources, source) ||
          !capabilities.sources[source].qualitys.includes(info.type)) {
        return 'D{"error":"unsupported"}';
      }
      // Settle queued startup requests through the denial callback below.
      // They remain ineligible for network access after switching to play.
      timers.clear();
      phase = 'play';
      // Only fixed categories cross the process boundary, never the script's text.
      const failed = error => {
        const message = typeof error === 'string' ? error : error?.message;
        result = { error: message === '\u670d\u52a1\u5668\u7e41\u5fd9' ? 'rateLimited' :
          message === '\u53d6\u6d88http\u8bf7\u6c42' ? 'cancelled' : 'unavailable' };
      };
      try {
        const promise = handler.call(lx, parameters.event);
        if (!promise || typeof promise.then !== 'function') return 'D{"error":"script"}';
        promise.then(url => {
          result = typeof url === 'string' && url.length > 0 && url.length <= 2048
            ? { url } : { error: 'unavailable' };
        }, failed);
      } catch (error) { failed(error); }
      return 'T';
    }
    for (const [id, timer] of timers) {
      if (timer.at > now()) continue;
      timers.delete(id);
      timer.callback(...timer.args);
      return 'T';
    }
    // Independent requests can overlap, but never invent a candidate for
    // a script that is still awaiting the preceding one. The host enforces
    // both the two-slot ceiling and the shared outbound budget independently.
    while (active.size < 2 && queued.length) {
      const entry = queued.shift();
      if (!entry.active) continue;
      if (!entry.allowed) {
        const callback = entry.callback;
        entry.callback = undefined;
        entry.fields = null;
        callback(new Error('LX request unavailable during initialization'), null, null);
        return 'T';
      }
      if (entry.fields === null) return 'D{"error":"script"}';
      const id = ++issued;
      const body = '{"id":' + id + ',' + entry.fields + '}';
      entry.fields = null;
      if (body.length >= limit) return 'D{"error":"script"}';
      active.set(id, entry);
      return 'Q' + body;
    }
    if (active.size) return 'P';
    return timers.size ? 'W' : 'D{"error":"init"}';
  };
}
)LXJS"
