import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { setImmediate as drainJobs, setTimeout as delay } from 'node:timers/promises';

const prelude = fs.readFileSync('tool/lx_prototype/script_prelude.inc', 'utf8')
  .replace(/^R"LXJS\(/, '').replace(/\)LXJS"\s*$/, '');

async function run(env, script, exchange, { initOnly = false, source = 'tx', type = '128k', clockStep = 0 } = {}) {
  const context = vm.createContext({});
  let clock = 0;
  if (clockStep) vm.runInContext('globalThis.fixtureClock = 0; Date.now = () => fixtureClock; void 0;', context);
  const make = vm.runInContext(prelude, context, {timeout: 2000});
  const parameters = {env, info: {name: 'contract fixture'}, event: initOnly ? null : {
    source, action: 'musicUrl', info: {type, musicInfo: {source, songmid: 'fixture'}},
  }};
  const step = make(parameters, script);
  vm.runInContext(script, context, {timeout: 2000});
  let answer;
  let dispatched = false;
  const active = new Set();
  const ready = [];
  for (let actions = 0; actions < 500; actions++) {
    await drainJobs();
    const message = step(answer);
    answer = undefined;
    if (message.startsWith('D')) {
      assert.equal(active.size, 0);
      return JSON.parse(message.slice(1));
    }
    if (message === 'S') {
      assert.ok(!initOnly && !dispatched);
      dispatched = true;
    } else if (message.startsWith('Q')) {
      assert.ok(dispatched);
      const {id, ...request} = JSON.parse(message.slice(1));
      assert.ok(Number.isInteger(id) && !active.has(id) && active.size < 64);
      active.add(id);
      Promise.resolve(exchange(request, id)).then(reply => {
        if (active.has(id) && !reply.pending) ready.push({id, ...reply});
      });
      answer = '{"pending":true}';
    } else if (message.startsWith('X')) {
      const id = Number(message.slice(1));
      assert.ok(active.delete(id));
      const index = ready.findIndex(r => r.id === id);
      if (index >= 0) ready.splice(index, 1);
      await exchange('cancel', id);
      answer = '{"pending":true}';
    } else if (message === 'P' || message === 'W') {
      if (clockStep) vm.runInContext('globalThis.fixtureClock = ' + (clock += clockStep), context);
      else await delay(2);
      if (message === 'P') {
        assert.ok(active.size);
        const reply = ready.shift();
        if (reply) active.delete(reply.id);
        answer = JSON.stringify(reply ?? {pending:true});
      }
    } else assert.equal(message, 'T');
  }
  throw new Error('LX contract did not complete');
}

const initialize = `
  lx.send(lx.EVENT_NAMES.inited, {sources: {tx: {
    type: 'music', actions: ['musicUrl'], qualitys: ['128k'],
  }}});
`;

for (const env of ['mobile', 'desktop']) {
  let exchanges = 0;
  const original = new Uint8Array([0,128,255]);
  const script = initialize + `
    lx.on(lx.EVENT_NAMES.request, () => new Promise((resolve, reject) => {
      lx.request('https://api.example.test/bytes', {binary: true, method: 'POST',
        body: lx.utils.buffer.from([0,128,255]), _responseBytes: false},
        (error, response, body) => {
          if (error || body !== response.body) return reject();
          const bytes = lx.utils.buffer.from(body);
          if (lx.utils.buffer.bufToString(bytes, 'hex') !== '0080ff') return reject();
          if (lx.env === 'mobile' && (body.type !== 'Buffer' || response.raw !== undefined)) return reject();
          if (lx.env === 'desktop' && (response.bytes !== 3 || response.raw.length !== 3)) return reject();
          resolve('https://media.example.test/bytes.mp3');
        });
    }));
  `;
  const result = await run(env, script, request => {
    exchanges++;
    assert.equal(request.options._responseBytes, env === 'desktop');
    assert.equal(request.options._followRedirects, env === 'mobile');
    assert.deepEqual(request.options.body, {type:'Buffer', data:[0,128,255]});
    return {response: {statusCode: 200, statusMessage: 'OK', headers: {}, body: null,
      _binary: true, _rawBase64: Buffer.from(original).toString('base64')}};
  });
  assert.equal(result.url, 'https://media.example.test/bytes.mp3');
  assert.equal(exchanges, 1);
}

const parsed = await run('desktop', initialize + `
  lx.on(lx.EVENT_NAMES.request, () => new Promise((resolve, reject) => {
    lx.request('https://api.example.test/json', {}, (error, response, body) => {
      if (error || body !== response.body || body.ok !== true ||
          lx.utils.buffer.bufToString(response.raw) !== '{"ok":true}' || response.bytes !== 11) return reject();
      resolve('https://media.example.test/json.flac');
    });
  }));
`, () => ({response: {statusCode: 200, statusMessage: 'OK', headers: {},
  body: {ok:true}, _rawBase64: Buffer.from('{"ok":true}').toString('base64')}}));
assert.equal(parsed.url, 'https://media.example.test/json.flac');

let denied = 0;
const retried = await run('mobile', initialize + `
  lx.on(lx.EVENT_NAMES.request, () => new Promise((resolve, reject) => {
    lx.request('https://api.example.test/first', {}, (error, response, body) => {
      if (!(error instanceof Error) || response !== null || body !== null) return reject();
      lx.request('https://api.example.test/second', {}, (err, resp, data) => {
        if (err || data !== resp.body || data !== 'ok') return reject();
        resolve('https://media.example.test/retry.mp3');
      });
    });
  }));
`, () => ++denied === 1 ? {error:'denied'} : {response:{statusCode:200, headers:{}, body:'ok'}});
assert.equal(retried.url, 'https://media.example.test/retry.mp3');
assert.equal(denied, 2);

let active = false;
let cancelled = false;
const cancellation = await run('mobile', initialize + `
  lx.on(lx.EVENT_NAMES.request, () => new Promise((resolve, reject) => {
    const cancel = lx.request('https://api.example.test/wait', {}, () => reject());
    setTimeout(() => { cancel(); resolve('https://media.example.test/cancel.mp3'); }, 8);
  }));
`, request => {
  if (request === 'cancel') { cancelled = true; return {error:'cancelled'}; }
  active = true;
  return {pending:true};
});
assert.equal(cancellation.url, 'https://media.example.test/cancel.mp3');
assert.ok(active && cancelled);
// Some scripts save a startup request's promise and await its fallback from
// musicUrl. The startup request must never reach the broker, but dropping its
// callback leaves both that promise and musicUrl unsettled.
const startup = initialize + `
  const cancelled = lx.request('https://api.example.test/cancelled-at-startup', {}, () => {
    throw new Error('Cancelled startup callback was run');
  });
  cancelled();
  const config = new Promise((resolve, reject) => {
    lx.request('https://api.example.test/at-startup', {get body() { throw Error('Read a denied request'); }}, (error, response, body) => {
      if (!(error instanceof Error) || response !== null || body !== null) {
        resolve('unexpected startup callback');
      } else {
        reject(error);
      }
    });
  }).catch(() => new Promise((resolve, reject) => {
    lx.request('https://api.example.test/foreground-config', {}, (error, response, body) => {
      if (error) return reject(error);
      resolve(body);
    });
  }));
  lx.on(lx.EVENT_NAMES.request, () => config.then(value => {
    if (value !== 'fixture config') throw new Error('Unexpected startup result');
    return 'https://media.example.test/from-config.mp3';
  }));
`;
for (const env of ['desktop', 'mobile']) {
  const discover = await run(env, startup, () => assert.fail('Import must stay offline'), { initOnly: true });
  assert.deepEqual(discover.capabilities.sources.tx.qualitys, ['128k']);
  const requests = [];
  const play = await run(env, startup, request => {
    requests.push(request.url);
    return {response: {statusCode: 200, headers: {}, body: 'fixture config'}};
  });
  assert.deepEqual(play, {url: 'https://media.example.test/from-config.mp3'});
  assert.deepEqual(requests, ['https://api.example.test/foreground-config']);
}
const multi = `
  lx.send(lx.EVENT_NAMES.inited, {sources: {
    kw: {type: 'music', actions: ['musicUrl'], qualitys: ['128k']},
    kg: {type: 'music', actions: ['musicUrl'], qualitys: ['flac', 'made-up']},
    wy: {type: 'music', actions: ['lyric'], qualitys: ['flac']},
  }});
  lx.on(lx.EVENT_NAMES.request, function({source, info}) {
    if (this !== lx || info.musicInfo.source !== source) throw Error('wrong dispatch');
    if (source === 'kw') throw new Error('服务器繁忙');
    return Promise.resolve('https://media.example.test/' + source + '.flac');
  });
`;
for (const env of ['desktop', 'mobile']) {
  const offline = () => assert.fail('unexpected exchange');
  const init = await run(env, multi, offline, {initOnly: true});
  assert.deepEqual(Object.keys(init.capabilities.sources), ['kw', 'kg']);
  assert.deepEqual(init.capabilities.sources.kg.qualitys, ['flac']);
  assert.deepEqual(await run(env, multi, offline, {source: 'kg', type: 'flac'}),
    {url: 'https://media.example.test/kg.flac'});
  assert.deepEqual(await run(env, multi, offline, {source: 'kg'}), {error: 'unsupported'});
  assert.deepEqual(await run(env, multi, offline, {source: 'kw'}), {error: 'rateLimited'});
}
const response = body => ({response: {statusCode: 200, headers: {}, body}});

// Release the slow first HTTP request only when the third one is issued.
// This requires overlapping 1/2 and delivering 2 without waiting for 1.
for (const env of ['desktop', 'mobile']) {
  const order = [];
  let finishFirst;
  const hold = new Promise(resolve => { finishFirst = resolve; });
  const parallel = await run(env, initialize + `
    lx.on('request', async () => {
      const completed = [];
      const q = n => new Promise((resolve,reject) => {
        lx.request('https://api.example.test/' + n, {}, (err,resp,body) => {
          if (err || n !== body || body !== resp.body) return reject();
          completed.push(n); resolve();
        });
      });
      await Promise.all([q(1), q(2), q(3)]);
      if (completed.join(',') !== '2,1,3') throw Error('wrong callback routing');
      return 'https://media.example.test/parallel.mp3';
    });`, (req,id) => {
    assert.notEqual(req, 'cancel'); order.push(id);
    if (id === 1) return hold;
    if (id === 3) finishFirst(response(1));
    return response(id);
  });
  assert.deepEqual(order,[1,2,3]);
  assert.equal(parallel.url,'https://media.example.test/parallel.mp3');

  const calls = [];
  const won = await run(env, initialize + `
    lx.on('request', async () => {
      const wait = n => new Promise((resolve,reject) => lx.request(
        'https://api.example.test/' + n, {}, (err,resp,body) => err ? reject(err) : resolve(body)));
      return await Promise.race([wait(1), wait(2), wait(3)]);
    });`, (req,id) => {
    calls.push((req === 'cancel' ? 'cancel:' : 'start:') + id);
    return id === 2 ? response('https://media.example.test/win.mp3') : {pending:true};
  });
  assert.equal(won.url,'https://media.example.test/win.mp3');
  assert.deepEqual(calls,['start:1','start:2','start:3','cancel:1','cancel:3']);
}
// LX captures request arguments when the script calls it, not when a host slot
// opens. One script may reuse the same options for a batch of candidates.
for (const env of ['mobile', 'desktop']) {
  const seen = [];
  const snap = await run(env, initialize + `
    lx.on('request', async ({source, info}) => {
      const headers = {'X-Fixture': 'first'};
      const body = {source, rid: info.musicInfo.songmid, level: info.type};
      const opts = {method: 'POST', headers, body, timeout: 1000,
        localNote: 'only used by the script', _followRedirects: false, _responseBytes: false};
      const issue = () => new Promise((resolve, reject) =>
        lx.request('https://api.example.test/lookup', opts,
          (err, resp, value) => err || value !== resp.body ? reject() : resolve(value)));
      const first = issue();
      headers['X-Fixture'] = 'second';
      body.level = '320k';
      const second = issue();
      opts.method = 'HEAD';
      headers['X-Fixture'] = 'unused';
      body.rid = 'unused';
      const results = await Promise.all([first, second]);
      return results[1].data.url;
    });`, (request, id) => {
    const o = request.options;
    seen.push([o.method, o.headers['X-Fixture'], o.body.rid, o.body.level]);
    assert.equal(Object.hasOwn(o, 'localNote'), false);
    assert.equal(o._responseBytes, env === 'desktop');
    assert.equal(o._followRedirects, env === 'mobile');
    return response(id === 1 ? {code:'unavailable'} : {data:{url:'https://media.example.test/result.mp3'}});
  });
  assert.deepEqual(seen, [['POST','first','fixture','128k'], ['POST','second','fixture','320k']]);
  assert.equal(snap.url, 'https://media.example.test/result.mp3');

  // Typed bytes, form and formData are also detached; unused metadata isn't
  // part of the bounded host message, even for a library with large options.
  const payloads = [];
  const detached = await run(env, initialize + `
    lx.on('request', async () => {
      const payloads = [{body:new Uint8Array([0,255])}, {form:{value:'old'}}, {formData:{value:'old'}}];
      const calls = payloads.map(p => new Promise((resolve, reject) => {
        lx.request('https://api.example.test/upload', {method:'POST', localNote:'x'.repeat(66000), ...p},
          (err, resp, body) => err ? reject() : resolve(body));
      }));
      payloads[0].body[0] = 7; payloads[1].form.value = 'new'; payloads[2].formData.value = 'new';
      return (await Promise.all(calls))[2];
    });`, ({options:o}) => {
    assert.equal(Object.hasOwn(o, 'localNote'), false);
    payloads.push(o.body ?? o.form ?? o.formData);
    return response('https://media.example.test/form.mp3');
  });
  assert.deepEqual(payloads, [{type:'Buffer',data:[0,255]}, {value:'old'}, {value:'old'}]);
  assert.equal(detached.url, 'https://media.example.test/form.mp3');

  const tooLarge = await run(env, initialize + `
    lx.on('request', () => new Promise(resolve => lx.request('https://api.example.test/oversized',
      {method:'POST', body:'x'.repeat(66000)}, () => resolve('unexpected'))));`,
    () => assert.fail('Oversized public request reached the broker'));
  assert.deepEqual(tooLarge, {error:'script'});

  // A full IPC window is backpressure, not 64 lifetime calls. The extra
  // request waits for a free slot. Only live IDs are cancelled on success.
  const started = [];
  const cancelled = [];
  const burst = await run(env, initialize + `
    lx.on('request', () => new Promise(resolve => {
      for (let i = 1; i <= 65; i++) {
        lx.request('https://api.example.test/' + i, {}, (_, resp) => {
          if (i === 65) resolve(resp.body);
        });
      }
    }));`, (req, id) => {
    if (req === 'cancel') { cancelled.push(id); return; }
    started.push(id);
    return id === 1 || id === 65 ? response('https://media.example.test/burst') : {pending:true};
  });
  assert.equal(burst.url, 'https://media.example.test/burst');
  assert.deepEqual(started, Array.from({length:65}, (_, i) => i + 1));
  assert.deepEqual(cancelled, started.slice(1, -1));

  const delayed = await run(env, initialize + `
    lx.on('request', () => new Promise(resolve => setTimeout(() =>
      resolve('https://media.example.test/' + Date.now()), 10000)));`,
    () => assert.fail('Timer-only fixture must stay offline'), {clockStep:1000});
  assert.equal(delayed.url, 'https://media.example.test/10000');

  // A 200 callback is not itself a successful musicUrl. The same script may
  // try another candidate without changing song, channel, or requested quality.
  for (const winner of [0, 3, 4, 6, 13]) {
    let issued = 0;
    const result = await run(env, initialize + `
      lx.on('request', async ({source, info}) => {
        for (let n = 1; n <= 13; n++) {
          const opts = n <= 2 ? {} : {method:'POST', body:{source, rid:info.musicInfo.songmid, level:info.type}};
          const url = await new Promise(resolve => lx.request('https://api.example.test/' + n, opts,
            (err, resp, body) => resolve(!err && resp.statusCode === 200 && resp.body === body && body?.data?.url)));
          if (url) return url;
        }
        throw Error('No address');
      });`, ({options}, id) => {
      issued++;
      if (id <= 2) return {error:'denied'};
      assert.deepEqual(options.body, {source:'tx', rid:'fixture', level:'128k'});
      return response(id === winner ? {data:{url:'https://media.example.test/winner.mp3'}} : {code:'unavailable'});
    });
    assert.equal(issued, winner || 13);
    assert.deepEqual(result, winner ? {url:'https://media.example.test/winner.mp3'} : {error:'unavailable'});
  }
}

console.log('PASS LX mobile/desktop request, cancellation and offline-startup fallback contracts');
