import { Buffer } from 'node:buffer';
import { check, NetworkError } from './policy.mjs';

export function untilAbort(pending, signal, discard = () => {}) {
  return new Promise((resolve, reject) => {
    const abort = () => {
      signal.removeEventListener('abort', abort);
      try { check(signal); } catch (error) { reject(error); }
    };
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
    Promise.resolve(pending).then((value) => {
      signal.removeEventListener('abort', abort);
      if (signal.aborted) discard(value);
      else resolve(value);
    }, (error) => {
      signal.removeEventListener('abort', abort);
      reject(error);
    });
  });
}

export function header(response, name) {
  const values = response.headers[name];
  if (values === undefined) return undefined;
  if (values.length !== 1 || typeof values[0] !== 'string' ||
      values[0].length > 2048 || /[^\t\x20-\x7e]/.test(values[0])) {
    throw new NetworkError('response-header');
  }
  return values[0].trim();
}

export function contentLength(response) {
  const value = header(response, 'content-length');
  if (value === undefined) return null;
  if (!/^\d{1,15}$/.test(value)) throw new NetworkError('response-header');
  return Number(value);
}

export async function collect(response, signal, capacity) {
  const reader = response.body[Symbol.asyncIterator]();
  const parts = [];
  let length = 0;
  for (;;) {
    const item = await untilAbort(reader.next(), signal);
    if (item.done) return Buffer.concat(parts, length);
    length += item.value.length;
    if (length > capacity) throw new NetworkError('response-limit');
    parts.push(item.value);
  }
}
