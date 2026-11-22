import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { createServer as createHttpsServer } from 'node:https';
import { createServer } from 'node:net';
import { Readable, PassThrough } from 'node:stream';
import { setImmediate as nextTurn } from 'node:timers/promises';
import { test } from 'node:test';
import { getCACertificates, setDefaultCACertificates } from 'node:tls';
import { createFixtureSession, createHostSession } from './broker.mjs';
import { httpsTransport } from './https_transport.mjs';

const apiHost = 'api.fixture.test';
const mediaHost = 'media.fixture.test';
const mirrorHost = 'mirror.fixture.test';
const api = 'https://' + apiHost;
const media = 'https://' + mediaHost;
const mirror = 'https://' + mirrorHost;
const grant = { apiHosts: [apiHost, mirrorHost], mediaHosts: [mediaHost, mirrorHost] };
const pin4 = { address: '93.184.216.34', family: 4 };
const pin6 = { address: '2606:4700::1111', family: 6 };

function fixture(handler, { authorization = grant, addresses = () => [pin4], timing } = {}) {
  const lookups = [];
  const dials = [];
  let active = 0;
  const session = createFixtureSession(authorization, {
    async resolve(host, signal) {
      lookups.push(host);
      return addresses(host, signal);
    },
    async dial(spec) {
      dials.push(spec);
      const { status, fields, body } = await handler(spec);
      const stream = body instanceof Readable ? body : Readable.from(body === undefined ? [] : body);
      active++;
      let closed = false;
      return {
        status,
        headers: Object.fromEntries(Object.entries(fields ?? {})
          .map(([key, value]) => [key, Array.isArray(value) ? value : [String(value)]])),
        body: stream,
        close() {
          if (closed) return;
          closed = true;
          active--;
          stream.destroy();
        },
      };
    },
  }, timing);
  return { session, lookups, dials, get active() { return active; } };
}

function fail(promise, code) {
  return assert.rejects(promise, { code });
}

function deferred() {
  return Promise.withResolvers();
}

function generatedWave(size = 96 * 1024 + 44) {
  const data = Buffer.alloc(size);
  for (let i = 44; i < size; i++) data[i] = i % 251;
  data.write('RIFF');
  data.writeUInt32LE(size - 8, 4);
  data.write('WAVEfmt ', 8);
  data.writeUInt32LE(16, 16);
  data.writeUInt16LE(1, 20);
  data.writeUInt16LE(1, 22);
  data.writeUInt32LE(16000, 24);
  data.writeUInt32LE(32000, 28);
  data.writeUInt16LE(2, 32);
  data.writeUInt16LE(16, 34);
  data.write('data', 36);
  data.writeUInt32LE(size - 44, 40);
  return data;
}

function waveResponse(data, start = 0, { status = 206, fields = {}, body } = {}) {
  return {
    status,
    fields: {
      'content-type': 'audio/wav',
      'content-length': data.length - start,
      etag: '"pcm-fixture"',
      ...(status === 206 ? { 'content-range': 'bytes ' + start + '-' + (data.length - 1) + '/' + data.length } : {}),
      ...fields,
    },
    body: body ?? [data.subarray(start)],
  };
}

async function exact(wave, count) {
  const bytes = [];
  let length = 0;
  while (length < count) {
    const part = await wave.read(count - length);
    assert.notEqual(part.length, 0);
    bytes.push(part);
    length += part.length;
  }
  return Buffer.concat(bytes, length);
}

test('exact permission by purpose before DNS; require canonical HTTPS authorities', async () => {
  const f = fixture(() => assert.fail('an unauthorized target was dialed'));
  for (const url of [
    'http://' + apiHost, api + ':444', api + '.', api + '#', api + '.other.test',
    api + ' /file', api + '\\file', api + '\n', 'https://@' + apiHost,
    'https://user@' + apiHost, 'https://a%70i.fixture.test', 'https://localhost/a',
    'https://127.0.0.1/a', 'https://[::1]/a', 'https:///api.fixture.test',
    'https://unapproved.fixture.test', media + '/wrong-purpose',
  ]) {
    await fail(f.session.api({ url }), 'target-denied');
  }
  await fail(f.session.wave(api + '/wrong-purpose'), 'target-denied');
  await fail(f.session.api({ url: api, method: 'CONNECT' }), 'invalid-request');
  await fail(f.session.api({ url: api, headers: { Cookie: 'example' } }), 'invalid-request');
  await fail(f.session.api({ url: api, accept: 'application/json\r\nX-Other: 1' }), 'invalid-request');
  await fail(createHostSession({}).api({ url: api }), 'target-denied');
  assert.deepEqual(f.lookups, []);
  assert.deepEqual(f.dials, []);
});

test('reject special-purpose and mixed DNS answers without dialing', async () => {
  for (const [address, family] of [
    ['0.0.0.0', 4], ['10.0.0.1', 4], ['100.64.0.1', 4], ['127.0.0.1', 4],
    ['169.254.1.2', 4], ['172.31.0.3', 4], ['192.0.2.1', 4], ['192.168.1.1', 4],
    ['198.18.1.2', 4], ['224.0.0.1', 4], ['250.0.0.1', 4], ['::', 6], ['::1', 6],
    ['::ffff:10.0.0.1', 6], ['64:ff9b::abcd', 6], ['100::1', 6], ['fc00::1', 6],
    ['fe80::1%3', 6], ['fe80::1', 6], ['ff02::1', 6], ['2001:db8::1', 6],
    ['2002:abcd::1', 6], ['3fff::1', 6], ['93.184.216.34', 6],
  ]) {
    const f = fixture(() => assert.fail('an unsafe IP was dialed'),
      { addresses: () => [pin4, { address, family }] });
    await fail(f.session.api({ url: api }), 'address-denied');
    assert.deepEqual(f.lookups, [apiHost]);
    assert.deepEqual(f.dials, []);
  }
  for (const answers of [[], Array(33).fill(pin4)]) {
    const f = fixture(() => assert.fail(), { addresses: () => answers });
    await fail(f.session.api({ url: api }), 'dns');
    assert.equal(f.dials.length, 0);
  }
});

test('pins every allowed hop to the answer it checked, and closes redirects', async () => {
  const f = fixture(({ url }) => url.hostname === apiHost
    ? { status: 302, fields: { location: mirror + '/final' } }
    : { status: 200, fields: { 'content-type': 'application/json', 'set-cookie': 'ignore-me' },
      body: [Buffer.from('{"ok":true}')] },
  { addresses: (host) => host === apiHost ? [pin4] : [pin6] });
  const result = await f.session.api({ url: 'HTTPS://' + apiHost.toUpperCase() + ':443/start' });
  assert.equal(result.status, 200);
  assert.deepEqual(result.headers, { 'content-type': 'application/json' });
  assert.deepEqual(JSON.parse(result.body), { ok: true });
  assert.deepEqual(f.lookups, [apiHost, mirrorHost]);
  assert.deepEqual(f.dials.map(({ pin }) => pin), [pin4, pin6]);
  assert.equal(f.active, 0);
});

test('reject redirect before dialing unauthorized domain or forbidden resolved address', async () => {
  for (const [location, code, lookups] of [
    [media + '/next', 'target-denied', [apiHost]],
    ['http://' + apiHost + '/next', 'target-denied', [apiHost]],
    [mirror + '/next', 'address-denied', [apiHost, mirrorHost]],
    [['/valid', '/other'], 'response-header', [apiHost]],
  ]) {
    const f = fixture(() => ({ status: 302, fields: { location } }),
      { addresses: (host) => host === apiHost ? [pin4] : [{ address: '127.0.0.1', family: 4 }] });
    await fail(f.session.api({ url: api }), code);
    assert.deepEqual(f.lookups, lookups);
    assert.equal(f.dials.length, 1);
    assert.equal(f.active, 0);
  }
});

test('script header/body restrictions, GET, HEAD, POST JSON and URL-encoded form', async () => {
  const f = fixture(() => ({ status: 200,
    fields: { 'content-type': 'text/plain', 'retry-after': '1', 'www-authenticate': 'hidden' },
    body: [Buffer.from('ok')],
  }));
  assert.equal((await f.session.api({ url: api, method: 'GET' })).body.toString(), 'ok');
  const head = await f.session.api({ url: api, method: 'HEAD' });
  assert.equal(head.body.length, 0);
  assert.deepEqual(head.headers, { 'content-type': 'text/plain', 'retry-after': '1' });
  await f.session.api({ url: api, method: 'POST', json: { query: 'music' }, accept: 'text/plain' });
  await f.session.api({ url: api, method: 'POST', form: { q: 'one two', empty: '' } });
  assert.deepEqual(f.dials.map((spec) => spec.method), ['GET', 'HEAD', 'POST', 'POST']);
  assert.equal(f.dials[2].body.toString(), '{"query":"music"}');
  assert.equal(f.dials[2].headers['content-type'], 'application/json');
  assert.equal(f.dials[3].body.toString(), 'q=one+two&empty=');
  assert.equal(f.dials[3].headers['content-type'], 'application/x-www-form-urlencoded');
  assert.equal(f.active, 0);
  await fail(f.session.api({ url: api, method: 'POST', json: 'x'.repeat(65537) }), 'request-limit');
});

test('POST forwards its body only on same-origin redirects which preserve the method', async () => {
  for (const [status, location, allowed] of [[307, '/next', true], [303, '/next', false],
    [308, mirror + '/next', false]]) {
    const f = fixture(({ url }) => url.pathname === '/start'
      ? { status, fields: { location } } : { status: 200 });
    const request = f.session.api({ url: api + '/start', method: 'POST', json: { track: 1 } });
    if (allowed) {
      await request;
      assert.equal(f.dials[1].body.toString(), '{"track":1}');
    } else {
      await fail(request, 'redirect');
    }
    assert.equal(f.dials.length, allowed ? 2 : 1);
    assert.equal(f.active, 0);
  }
});

test('redirects consume the same API quota; there is no automatic retry', async () => {
  const f = fixture(() => ({ status: 302, fields: { location: '/another-hop' } }));
  await fail(f.session.api({ url: api }), 'redirect');
  await fail(f.session.api({ url: api }), 'request-budget');
  assert.equal(f.dials.length, 4);
  assert.equal(f.active, 0);
});

test('limit API size on headers and streamed bytes; do not expand compressed bodies', async () => {
  const oversized = Buffer.alloc(300 * 1024);
  const f = fixture(({ url }) => {
    switch (url.pathname) {
      case '/length': return { status: 200, fields: { 'content-length': 9 * 1024 * 1024 } };
      case '/chunks': return { status: 200, body: [oversized, oversized] };
      default: return { status: 200, fields: { 'content-encoding': 'gzip' } };
    }
  });
  await fail(f.session.api({ url: api + '/length' }), 'response-limit');
  await fail(f.session.api({ url: api + '/chunks' }), 'response-limit');
  await fail(f.session.api({ url: api + '/gzip' }), 'encoding');
  assert.equal(f.active, 0);
});

test('max two API operations; revoke stops both bodies and discards later results', async () => {
  const bodies = [new PassThrough(), new PassThrough()];
  const f = fixture(({ url }) => ({ status: 200, body: bodies[Number(url.pathname[1])] }));
  const first = fail(f.session.api({ url: api + '/0' }), 'cancelled');
  const second = fail(f.session.api({ url: api + '/1' }), 'cancelled');
  await fail(f.session.api({ url: api + '/2' }), 'request-budget');
  await nextTurn();
  assert.equal(f.active, 2);
  f.session.revoke();
  await Promise.all([first, second]);
  assert.ok(bodies.every((body) => body.destroyed));
  assert.equal(f.active, 0);
  await fail(f.session.api({ url: api }), 'cancelled');
  assert.equal(f.dials.length, 2);
});

test('cancelling or timing out resolution does not dial; late responses are closed', async () => {
  const pendingDns = deferred();
  const f = fixture(() => assert.fail('late DNS result was used'),
    { addresses: () => pendingDns.promise });
  const abort = new AbortController();
  const result = fail(f.session.api({ url: api }, abort.signal), 'cancelled');
  abort.abort();
  await result;
  pendingDns.resolve([pin4]);
  await nextTurn();
  assert.deepEqual(f.dials, []);
  const pending = deferred();
  const g = fixture(() => pending.promise, { timing: { hopMs: 30 } });
  await fail(g.session.api({ url: api }), 'timeout');
  pending.resolve({ status: 200, body: [Buffer.from('late')] });
  await nextTurn();
  assert.equal(g.active, 0);
});

test('WAV reads with backpressure and seeks using the same checked representation', async () => {
  const data = generatedWave();
  let served = 0;
  const f = fixture(({ url, headers }) => {
    if (url.hostname === mediaHost) return { status: 302, fields: { location: mirror + '/wav' } };
    const start = Number(headers.range.slice(6, -1));
    function* chunks() {
      for (let i = start; i < data.length; i += 512) {
        served += Math.min(512, data.length - i);
        yield data.subarray(i, i + 512);
      }
    }
    return waveResponse(data, start, { body: Readable.from(chunks(), { objectMode: false, highWaterMark: 1024 }) });
  });
  const wave = await f.session.wave(media + '/start');
  assert.ok(wave.seekable);
  assert.equal(wave.size, data.length);
  assert.deepEqual(await exact(wave, 128), data.subarray(0, 128));
  assert.ok(served < data.length / 4);
  assert.equal(await wave.seek(75000), 75000);
  assert.equal(f.dials.at(-1).url.hostname, mirrorHost);
  assert.equal(f.dials.at(-1).headers.range, 'bytes=75000-');
  assert.equal(f.dials.at(-1).headers['if-range'], '"pcm-fixture"');
  assert.deepEqual(await exact(wave, 99), data.subarray(75000, 75099));
  assert.equal(await wave.seek(0), 0);
  assert.equal(f.dials.at(-1).headers.range, 'bytes=44-');
  assert.deepEqual(await exact(wave, 128), data.subarray(0, 128));
  assert.equal(await wave.seek(wave.size), wave.size);
  assert.equal((await wave.read(32)).length, 0);
  assert.equal(f.active, 0);
  wave.close();
});

test('initial 200 and weak ETag allow sequential WAV, but never claim a seek', async () => {
  const data = generatedWave();
  for (const spec of [{ status: 200 }, { fields: { etag: 'W/"fixture"' } }]) {
    const f = fixture(() => waveResponse(data, 0, spec));
    const wave = await f.session.wave(media);
    assert.equal(wave.seekable, false);
    assert.deepEqual(await exact(wave, 66), data.subarray(0, 66));
    await fail(wave.seek(1000), 'seek-unsupported');
    assert.equal(wave.position, 66);
    assert.equal(f.dials.length, 1);
    wave.close();
    assert.equal(f.active, 0);
  }
});

test('failed Range never swaps the live stream or forwards the validator', async () => {
  const data = generatedWave();
  for (const [reply, code] of [
    [waveResponse(data, 0, { status: 200 }), 'seek-unsupported'],
    [{ status: 416 }, 'range-rejected'],
    [waveResponse(data, 999), 'range-rejected'],
    [waveResponse(data, 1000, { fields: { etag: '"new-generation"' } }), 'range-rejected'],
    [waveResponse(data, 1000, { fields: { 'content-length': 100 } }), 'range-rejected'],
    [{ status: 302, fields: { location: mirror } }, 'redirect'],
  ]) {
    const f = fixture(({ headers }) => headers.range === 'bytes=0-' ? waveResponse(data) : reply);
    const wave = await f.session.wave(media);
    assert.deepEqual(await exact(wave, 88), data.subarray(0, 88));
    await fail(wave.seek(1000), code);
    assert.equal(wave.position, 88);
    assert.equal(f.active, 1);
    assert.equal(f.dials.length, 2);
    assert.deepEqual(await exact(wave, 24), data.subarray(88, 112));
    wave.close();
    assert.equal(f.active, 0);
  }
});

test('reject playlists, noncanonical chunks and inconsistent lengths without an extra open', async () => {
  for (const kind of ['playlist', 'wrong MIME', 'extra chunk', 'huge', 'truncated', 'wrong total']) {
    const data = generatedWave();
    const f = fixture(() => {
      if (kind === 'playlist') data.write('#EXTM3U\n');
      if (kind === 'extra chunk') data.write('LIST', 36);
      if (kind === 'wrong total') data.writeUInt32LE(data.length, 4);
      const spec = kind === 'wrong MIME' ? { fields: { 'content-type': 'application/vnd.apple.mpegurl' } } :
        kind === 'huge' ? { status: 200, fields: { 'content-length': 500 * 1024 * 1024 } } :
          kind === 'truncated' ? { body: [data.subarray(0, 12)] } : {};
      return waveResponse(data, 0, spec);
    });
    await fail(f.session.wave(media), kind === 'truncated' ? 'media-body' :
      kind === 'huge' ? 'media-size' : 'media-format');
    assert.equal(f.dials.length, 1);
    assert.equal(f.active, 0);
  }
});

test('closing, revoking and read timeout stop a blocked media body', async () => {
  for (const mode of ['close', 'revoke', 'timeout']) {
    const data = generatedWave();
    const stream = new PassThrough();
    stream.write(data.subarray(0, 44));
    const f = fixture(() => waveResponse(data, 0, { body: stream }), { timing: { readMs: 30 } });
    const wave = await f.session.wave(media);
    await fail(f.session.wave(media), 'media-busy');
    assert.equal((await wave.read(44)).length, 44);
    const completion = fail(wave.read(16), mode === 'timeout' ? 'timeout' : 'cancelled');
    await fail(wave.seek(90), 'media-busy');
    if (mode === 'close') wave.close();
    if (mode === 'revoke') f.session.revoke();
    await completion;
    assert.ok(stream.destroyed);
    assert.equal(f.active, 0);
    await fail(wave.read(16), 'cancelled');
  }
});

test('actual TLS adapter tears down a TCP connection cancelled during handshake', { timeout: 3000 }, async () => {
  // Only the low-level adapter is used here; the broker rejects loopback.
  const server = createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const abort = new AbortController();
  let accepted;
  try {
    const peerReady = once(server, 'connection');
    const ending = fail(httpsTransport.dial({
      url: new URL('https://fixture.invalid:' + server.address().port),
      pin: { address: '127.0.0.1', family: 4 }, method: 'GET', headers: {}, signal: abort.signal,
    }), 'cancelled');
    [accepted] = await peerReady;
    accepted.resume();
    const peerClosed = once(accepted, 'close');
    abort.abort();
    await Promise.all([ending, peerClosed]);
  } finally {
    abort.abort();
    accepted?.destroy();
    server.close();
  }
});

test('local HTTPS verifies the hostname, streams Range and closes a live socket on revoke', { timeout: 8000 }, async () => {
  const host = 'wav.fixture.invalid';
  const openssl = process.env.MOTIF_TEST_OPENSSL || 'openssl';
  // New fixture identity per run, with both PEM blocks kept in memory.
  const makeCertificate = spawnSync(openssl, ['req', '-x509', '-newkey', 'rsa:2048',
    '-nodes', '-days', '1', '-subj', '/CN=' + host, '-addext', 'subjectAltName=DNS:' + host,
    '-keyout', '-', '-out', '-'], { encoding: 'ascii', timeout: 5000, windowsHide: true });
  assert.equal(makeCertificate.status, 0, 'OpenSSL could not create the ephemeral TLS fixture');
  const key = makeCertificate.stdout.match(/-----BEGIN PRIVATE KEY-----[\s\S]+?-----END PRIVATE KEY-----/)?.[0];
  const cert = makeCertificate.stdout.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/)?.[0];
  assert.ok(key && cert, 'the ephemeral TLS fixture did not produce both PEM blocks');

  const bytes = generatedWave();
  const requests = [];
  const stalled = deferred();
  const server = createHttpsServer({ key, cert }, (req, res) => {
    requests.push({ name: req.socket.servername, url: req.url, headers: req.headers });
    if (req.url === '/hold') {
      res.on('close', stalled.resolve);
      res.writeHead(200, { 'content-type': 'audio/wav', 'content-length': bytes.length });
      res.write(bytes.subarray(0, 44));
      return;
    }
    const start = Number(req.headers.range.slice(6, -1));
    const part = waveResponse(bytes, start);
    res.writeHead(part.status, part.fields);
    res.end(bytes.subarray(start));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  const loopbackPin = { address: '127.0.0.1', family: 4 };
  const signal = AbortSignal.timeout(1800);
  const baselineCAs = getCACertificates('default');
  let session;
  try {
    const rejected = (name) => httpsTransport.dial({
      url: new URL('https://' + name + ':' + port + '/hold'),
      pin: loopbackPin, method: 'GET', headers: {}, signal,
    });
    await assert.rejects(rejected(host), { code: 'DEPTH_ZERO_SELF_SIGNED_CERT' });
    setDefaultCACertificates([...baselineCAs, cert]);
    await assert.rejects(rejected('wrong.fixture.invalid'), { code: 'ERR_TLS_CERT_ALTNAME_INVALID' });
    assert.equal(requests.length, 0);

    const origin = 'https://' + host;
    session = createFixtureSession({ mediaHosts: [host] }, {
      async resolve() { return [pin4]; },
      dial(spec) {
        assert.deepEqual(spec.pin, pin4);
        // Route this independent test seam to the local HTTPS fixture only.
        const url = new URL(spec.url);
        url.port = port;
        return httpsTransport.dial({ ...spec, url, pin: loopbackPin });
      },
    });
    const wave = await session.wave(origin + '/open');
    assert.deepEqual(await exact(wave, 200), bytes.subarray(0, 200));
    await wave.seek(76000);
    assert.deepEqual(await exact(wave, 150), bytes.subarray(76000, 76150));
    assert.deepEqual(requests.map(({ name }) => name), [host, host]);
    assert.equal(requests[0].headers.host, host + ':' + port);
    assert.equal(requests[1].headers['if-range'], '"pcm-fixture"');
    assert.equal(requests[1].headers.range, 'bytes=76000-');
    wave.close();
    const pending = await session.wave(origin + '/hold');
    await pending.read(44);
    const read = fail(pending.read(100), 'cancelled');
    session.revoke();
    await Promise.all([read, stalled.promise]);
  } finally {
    session?.revoke();
    setDefaultCACertificates(baselineCAs);
    server.close();
    server.closeAllConnections();
  }
});
