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
  let pending;
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
      const tx = data?.sources?.tx;
      const supported = tx?.type === 'music' && Array.isArray(tx.actions) &&
        tx.actions.includes('musicUrl') && Array.isArray(tx.qualitys)
        ? allowedQualities.filter(quality => tx.qualitys.includes(quality)) : [];
      capabilities = { sources: supported.length
        ? { tx: { type: 'music', actions: ['musicUrl'], qualitys: supported } } : {} };
      return Promise.resolve();
    },
    request(url, options, callback) {
      if (++requests > 12) throw new RangeError('Request limit');
      if (typeof url !== 'string' || url.length > 2048 ||
          !options || typeof options !== 'object' || typeof callback !== 'function') {
        throw new TypeError('Invalid request');
      }
      const entry = { url, options, callback, active: true, allowed: phase === 'play' };
      queued.push(entry);
      return () => {
        entry.active = false;
        entry.callback = undefined;
        entry.options = undefined;
        entry.url = undefined;
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

  return response => {
    if (pending && response !== undefined) {
      const answer = parse(response);
      if (!answer.pending) pending.answer = answer;
    }
    if (pending && !pending.active) {
      pending = undefined;
      return 'X';
    }
    if (result) return 'D' + stringify(result);
    if (phase === 'init' && capabilities) {
      if (typeof handler !== 'function') return 'D{"error":"init"}';
      if (!parameters.event) return 'D' + stringify({ capabilities });
      if (!capabilities.sources.tx?.qualitys.includes(parameters.event.info.type)) {
        return 'D{"error":"unsupported"}';
      }
      queued.length = 0;
      timers.clear();
      phase = 'play';
      const promise = handler.call(lx, parameters.event);
      if (!promise || typeof promise.then !== 'function') return 'D{"error":"script"}';
      promise.then(url => {
        result = typeof url === 'string' && url.length <= 2048
          ? { url } : { error: 'script' };
      }, () => { result = { error: 'unavailable' }; });
      return 'T';
    }
    for (const [id, timer] of timers) {
      if (timer.at > now()) continue;
      timers.delete(id);
      timer.callback(...timer.args);
      return 'T';
    }
    if (pending) {
      if (!pending.answer) return 'P';
      const { callback, answer } = pending;
      pending.callback = undefined;
      pending.options = undefined;
      pending.url = undefined;
      pending = undefined;
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
      return 'T';
    }
    while (queued.length) {
      const entry = queued.shift();
      if (!entry.active) continue;
      if (!entry.allowed) {
        const callback = entry.callback;
        entry.callback = undefined;
        entry.options = undefined;
        entry.url = undefined;
        callback(new Error('LX request unavailable during initialization'), null, null);
        return 'T';
      }
      pending = entry;
      const options = {...entry.options, _responseBytes: parameters.env === 'desktop',
        _followRedirects: parameters.env === 'mobile'};
      if (ArrayBuffer.isView(options.body)) {
        options.body = {type: 'Buffer', data: Array.from(options.body)};
      }
      const body = stringify({ url: entry.url, options });
      return body.length < limit ? 'Q' + body : 'D{"error":"script"}';
    }
    return timers.size ? 'W' : 'D{"error":"init"}';
  };
}
)LXJS"
