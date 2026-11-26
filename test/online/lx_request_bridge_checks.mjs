import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { setImmediate as drainJobs, setTimeout as delay } from 'node:timers/promises';

const prelude = fs.readFileSync('tool/lx_prototype/script_prelude.inc', 'utf8')
  .replace(/^R"LXJS\(/, '').replace(/\)LXJS"\s*$/, '');

async function run(env, script, exchange, { initOnly = false } = {}) {
  const context = vm.createContext({});
  const make = vm.runInContext(prelude, context, {timeout: 2000});
  const parameters = {env, info: {name: 'contract fixture'}, event: initOnly ? null : {
    source: 'tx', action: 'musicUrl', info: {type: '128k', musicInfo: {songmid: 'fixture'}},
  }};
  const step = make(parameters, script);
  vm.runInContext(script, context, {timeout: 2000});
  let answer;
  for (let actions = 0; actions < 100; actions++) {
    // The native loop drains all nested Promise jobs before stepping.
    await drainJobs();
    const message = step(answer);
    answer = undefined;
    if (message.startsWith('D')) return JSON.parse(message.slice(1));
    if (message.startsWith('Q')) {
      answer = JSON.stringify(await exchange(JSON.parse(message.slice(1))));
    } else if (message === 'X') {
      answer = JSON.stringify(await exchange('cancel'));
    } else if (message === 'P' || message === 'W') {
      await delay(2);
      if (message === 'P') answer = '{"pending":true}';
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
    lx.request('https://api.example.test/at-startup', {}, (error, response, body) => {
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
console.log('PASS LX mobile/desktop request, cancellation and offline-startup fallback contracts');
