import { Buffer } from 'node:buffer';
import { check, NetworkError, safeError } from './policy.mjs';
import { contentLength, header, untilAbort } from './response.mjs';

const headerBytes = 44;
const chunkBytes = 32 * 1024;
const maxWaveBytes = 256 * 1024 * 1024;
const mimeTypes = new Set(['audio/wav', 'audio/x-wav', 'audio/wave', 'audio/vnd.wave',
  'application/octet-stream']);

export async function openWave(url, open, parent, readMs, released) {
  const control = new AbortController();
  const signal = AbortSignal.any([parent, control.signal]);
  let initial;
  try {
    initial = await open(url, 0, undefined, signal);
    const info = describe(initial.response, 0);
    const cursor = new Cursor(initial, info.size);
    const prefix = Buffer.alloc(headerBytes);
    await cursor.timed(readMs, async () => {
      for (let count = 0; count < headerBytes;) {
        const part = await cursor.read(headerBytes - count);
        part.copy(prefix, count);
        count += part.length;
      }
    });
    validatePcm(prefix, info.size);
    check(signal);
    return waveHandle(initial.url.href, info, prefix, cursor, open, signal,
      control, readMs, released);
  } catch (error) {
    initial?.close();
    throw safeError(error, initial?.signal ?? signal);
  }
}

function waveHandle(url, { size, etag, ranged }, prefix, first, open, signal,
  control, readMs, released) {
  let cursor = first;
  let position = 0;
  let seekable = ranged && etag !== undefined;
  let busy = false;
  let closed = false;
  const abort = () => close();
  signal.addEventListener('abort', abort, { once: true });

  function close() {
    if (closed) return;
    closed = true;
    signal.removeEventListener('abort', abort);
    control.abort(new NetworkError('cancelled'));
    cursor?.close();
    cursor = null;
    released();
  }
  function begin() {
    check(signal);
    if (busy) throw new NetworkError('media-busy');
    busy = true;
  }
  function commitOffset(offset, replacement) {
    cursor?.close();
    cursor = replacement;
    position = offset;
  }

  return Object.freeze({
    size,
    get position() { return position; },
    get seekable() { return seekable && !closed; },
    async read(count) {
      if (!Number.isSafeInteger(count) || count < 1 || count > chunkBytes) {
        throw new NetworkError('invalid-read');
      }
      begin();
      try {
        if (position === size) return Buffer.alloc(0);
        // The initial, checked RIFF header is the only header ever handed to
        // the consumer, including after a seek to the beginning.
        const part = position < headerBytes
          ? Buffer.from(prefix.subarray(position, Math.min(position + count, headerBytes)))
          : await cursor.timed(readMs, () => cursor.read(count));
        check(signal);
        position += part.length;
        if (position === size) commitOffset(position, null);
        return part;
      } catch (error) {
        const receiving = cursor?.signal ?? signal;
        try { throw safeError(error, receiving); } finally { close(); }
      } finally {
        busy = false;
      }
    },
    async seek(offset) {
      if (!Number.isSafeInteger(offset) || offset < 0 || offset > size) {
        throw new NetworkError('invalid-range');
      }
      begin();
      let candidate;
      try {
        if (offset === position) return offset;
        if (!seekable) throw new NetworkError('seek-unsupported');
        if (offset === size) {
          commitOffset(offset, null);
          return position;
        }
        const start = Math.max(offset, headerBytes);
        candidate = await open(url, start, etag, signal);
        const info = describe(candidate.response, start);
        if (info.size !== size || info.etag !== etag || candidate.url.href !== url) {
          throw new NetworkError('range-rejected');
        }
        check(signal);
        commitOffset(offset, new Cursor(candidate, size - start));
        candidate = null;
        return position;
      } catch (error) {
        if (error.code === 'seek-unsupported') seekable = false;
        throw safeError(error, candidate?.signal ?? signal);
      } finally {
        candidate?.close();
        busy = false;
      }
    },
    close,
  });
}

function describe(response, start) {
  const ranged = response.status === 206;
  if (start !== 0 && response.status === 200) throw new NetworkError('seek-unsupported');
  if (!ranged && response.status !== 200) throw new NetworkError('range-rejected');
  const length = contentLength(response);
  const range = header(response, 'content-range');
  let size = length;
  if (ranged) {
    const parts = /^bytes (\d{1,10})-(\d{1,10})\/(\d{1,10})$/.exec(range ?? '');
    if (parts === null) throw new NetworkError('range-rejected');
    const [begin, end, total] = parts.slice(1).map(Number);
    if (begin !== start || end < begin || end !== total - 1 ||
        (length !== null && length !== end - begin + 1)) {
      throw new NetworkError('range-rejected');
    }
    size = total;
  } else if (range !== undefined) {
    throw new NetworkError('range-rejected');
  }
  if (size === null || size <= headerBytes || size > maxWaveBytes) {
    throw new NetworkError('media-size');
  }
  const mime = header(response, 'content-type')?.split(';', 1)[0].trim().toLowerCase();
  if (!mimeTypes.has(mime)) throw new NetworkError('media-format');
  const etag = header(response, 'etag');
  const strong = typeof etag === 'string' && /^"[\x21\x23-\x7e]{0,126}"$/.test(etag);
  return { size, ranged, etag: strong ? etag : undefined };
}

function validatePcm(prefix, size) {
  const channels = prefix.readUInt16LE(22);
  const rate = prefix.readUInt32LE(24);
  const alignment = channels * 2;
  if (prefix.toString('ascii', 0, 4) !== 'RIFF' ||
      prefix.readUInt32LE(4) !== size - 8 ||
      prefix.toString('ascii', 8, 16) !== 'WAVEfmt ' ||
      prefix.readUInt32LE(16) !== 16 || prefix.readUInt16LE(20) !== 1 ||
      (channels !== 1 && channels !== 2) || rate < 8000 || rate > 192000 ||
      prefix.readUInt32LE(28) !== rate * alignment ||
      prefix.readUInt16LE(32) !== alignment || prefix.readUInt16LE(34) !== 16 ||
      prefix.toString('ascii', 36, 40) !== 'data' ||
      prefix.readUInt32LE(40) !== size - headerBytes ||
      (size - headerBytes) % alignment !== 0) {
    throw new NetworkError('media-format');
  }
}

class Cursor {
  #hop;
  #reader;
  #remaining;
  #queued = Buffer.alloc(0);

  constructor(hop, length) {
    this.#hop = hop;
    this.#reader = hop.response.body[Symbol.asyncIterator]();
    this.#remaining = length;
  }

  get signal() { return this.#hop.signal; }
  close() {
    this.#queued = Buffer.alloc(0);
    this.#hop.close();
  }

  async timed(ms, action) {
    const timer = setTimeout(this.#hop.stop, ms);
    try { return await action(); } finally { clearTimeout(timer); }
  }

  async read(count) {
    while (this.#queued.length === 0) {
      const item = await untilAbort(this.#reader.next(), this.signal);
      if (item.done || item.value.length > this.#remaining) throw new NetworkError('media-body');
      this.#queued = item.value;
    }
    const available = Math.min(count, this.#queued.length);
    const part = this.#queued.subarray(0, available);
    this.#queued = this.#queued.subarray(available);
    this.#remaining -= available;
    return part;
  }
}
