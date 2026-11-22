import { Buffer } from 'node:buffer';
import { httpsTransport } from './https_transport.mjs';
import { check, destination, grant, NetworkError, publicAddress, safeError } from './policy.mjs';
import { collect, contentLength, header, untilAbort } from './response.mjs';
import { openWave } from './wave.mjs';

const limits = Object.freeze({
  apiHops: 4, apiParallel: 2, redirects: 3,
  resolveMs: 8000, hopMs: 3000, readMs: 3000,
  apiBytes: 512 * 1024, uploadBytes: 64 * 1024,
});
const redirectStatuses = new Set([301, 302, 303, 307, 308]);
const commonHeaders = Object.freeze({ 'accept-encoding': 'identity', 'user-agent': 'Motif-LX-probe/1' });

export function createHostSession(authorization) {
  return buildSession(authorization, httpsTransport, limits);
}

// Only the standalone checks inject DNS and dial fixtures. This module is
// never loaded into the script VM or the Motif application.
export function createFixtureSession(authorization, transport, timing = {}) {
  return buildSession(authorization, transport, { ...limits, ...timing });
}

function buildSession({ apiHosts, mediaHosts }, transport, caps) {
  const allowedApi = grant(apiHosts);
  const allowedMedia = grant(mediaHosts);
  const lease = new AbortController();
  const apiDeadline = performance.now() + caps.resolveMs;
  let usedHops = 0;
  let apiActive = 0;
  let mediaActive = false;

  async function open(start, hosts, spec, parent, { api = false, noRedirects = false } = {}) {
    let url = destination(start, hosts);
    for (let hop = 0; ; hop++) {
      check(parent);
      if (api && usedHops >= caps.apiHops) throw new NetworkError('request-budget');
      if (api) usedHops++;
      const scope = deadline(parent, caps.hopMs);
      const { signal } = scope;
      let response;
      let retained = false;
      let closed = false;
      function close() {
        if (closed) return;
        closed = true;
        signal.removeEventListener('abort', close);
        scope.clear();
        response?.close();
      }
      try {
        const answers = await untilAbort(transport.resolve(url.hostname, signal), signal);
        const pin = publicAddress(answers);
        check(signal);
        response = await untilAbort(transport.dial({
          url, pin, signal, method: spec.method, headers: spec.headers, body: spec.body,
        }), signal, (late) => late.close());
        signal.addEventListener('abort', close, { once: true });
        check(signal);
        if (redirectStatuses.has(response.status)) {
          if (noRedirects || hop === caps.redirects) throw new NetworkError('redirect');
          const next = destination(header(response, 'location'), hosts, url);
          if (spec.method === 'POST' && (next.origin !== url.origin ||
              (response.status !== 307 && response.status !== 308))) {
            throw new NetworkError('redirect');
          }
          url = next;
          continue;
        }
        const encoding = header(response, 'content-encoding');
        if (encoding !== undefined && encoding.toLowerCase() !== 'identity') {
          throw new NetworkError('encoding');
        }
        if (!api) scope.clear(); // Media body is bounded when the consumer reads.
        retained = true;
        return { response, url, signal, close, stop: scope.stop };
      } catch (error) {
        throw safeError(error, signal);
      } finally {
        if (!retained) close();
      }
    }
  }

  return Object.freeze({
    async api(input, signal = lease.signal) {
      const parent = AbortSignal.any([lease.signal, signal]);
      check(parent);
      const remaining = Math.ceil(apiDeadline - performance.now());
      if (remaining <= 0) throw new NetworkError('timeout');
      if (apiActive >= caps.apiParallel) throw new NetworkError('request-budget');
      const spec = apiRequest(input, caps.uploadBytes);
      const total = deadline(parent, remaining);
      apiActive++;
      let hop;
      try {
        hop = await open(input.url, allowedApi, spec, total.signal, { api: true });
        const { response } = hop;
        const length = contentLength(response);
        if (spec.method !== 'HEAD' && length > caps.apiBytes) throw new NetworkError('response-limit');
        const body = spec.method === 'HEAD' ? Buffer.alloc(0) :
          await collect(response, hop.signal, caps.apiBytes);
        if (spec.method !== 'HEAD' && length !== null && body.length !== length) {
          throw new NetworkError('response-length');
        }
        check(hop.signal);
        const visibleHeaders = {};
        for (const name of ['content-type', 'retry-after']) {
          const value = header(response, name);
          if (value !== undefined) visibleHeaders[name] = value;
        }
        return { status: response.status, headers: visibleHeaders, body };
      } catch (error) {
        throw safeError(error, hop?.signal ?? total.signal);
      } finally {
        hop?.close();
        total.clear();
        apiActive--;
      }
    },
    async wave(url, signal = lease.signal) {
      const parent = AbortSignal.any([lease.signal, signal]);
      check(parent);
      if (mediaActive) throw new NetworkError('media-busy');
      mediaActive = true;
      const released = () => { mediaActive = false; };
      try {
        return await openWave(url, (address, offset, etag, signal) => open(address, allowedMedia, {
          method: 'GET',
          headers: { ...commonHeaders, range: 'bytes=' + offset + '-',
            ...(etag ? { 'if-range': etag } : {}) },
        }, signal, { noRedirects: offset !== 0 }), parent, caps.readMs, released);
      } catch (error) {
        released();
        throw safeError(error, parent);
      }
    },
    revoke() {
      lease.abort(new NetworkError('cancelled'));
    },
  });
}

function apiRequest(input, maxBytes) {
  if (input === null || typeof input !== 'object' ||
      Object.keys(input).some((key) => !['url', 'method', 'json', 'form', 'accept'].includes(key))) {
    throw new NetworkError('invalid-request');
  }
  const method = input.method ?? 'GET';
  const hasJson = Object.hasOwn(input, 'json');
  const hasForm = Object.hasOwn(input, 'form');
  if (!['GET', 'HEAD', 'POST'].includes(method) || (hasJson && hasForm) ||
      (method !== 'POST' && (hasJson || hasForm))) {
    throw new NetworkError('invalid-request');
  }
  const headers = { ...commonHeaders };
  if (input.accept !== undefined) {
    if (typeof input.accept !== 'string' || !/^[\x21-\x7e][\x20-\x7e]{0,255}$/.test(input.accept)) {
      throw new NetworkError('invalid-request');
    }
    headers.accept = input.accept;
  }
  let text;
  if (hasJson) {
    try {
      text = JSON.stringify(input.json);
    } catch {
      throw new NetworkError('invalid-request');
    }
    if (text === undefined) throw new NetworkError('invalid-request');
    headers['content-type'] = 'application/json';
  } else if (hasForm) {
    if (!input.form || typeof input.form !== 'object' || Array.isArray(input.form)) {
      throw new NetworkError('invalid-request');
    }
    const pairs = Object.entries(input.form);
    if (pairs.length > 64 || pairs.some(([, value]) => typeof value !== 'string')) {
      throw new NetworkError('invalid-request');
    }
    text = new URLSearchParams(pairs).toString();
    headers['content-type'] = 'application/x-www-form-urlencoded';
  }
  if (text !== undefined && Buffer.byteLength(text) > maxBytes) throw new NetworkError('request-limit');
  const body = text === undefined ? undefined : Buffer.from(text);
  if (method === 'POST') headers['content-length'] = (body?.length ?? 0).toString();
  return { method, headers, body };
}

function deadline(parent, ms) {
  const control = new AbortController();
  const stop = () => control.abort(new NetworkError('timeout'));
  const timer = setTimeout(stop, ms);
  return { signal: AbortSignal.any([parent, control.signal]), clear: () => clearTimeout(timer), stop };
}
