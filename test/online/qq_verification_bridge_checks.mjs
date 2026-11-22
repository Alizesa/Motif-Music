import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const text = fs.readFileSync('lib/online/qq/auth/qq_verification_protocol.dart', 'utf8');
const script = text.match(/const qqVerificationProofScript = r'''([\s\S]*?)''';/)?.[1];
assert.ok(script, 'Production verification bridge was not found');

function harness({ visible = true, bridge = true, url = 'https://y.qq.com/verify' } = {}) {
  let now = 1000, id = 0;
  const timers = new Map(), listeners = new Map(), calls = [];
  const frame = {
    style: { display: visible ? 'block' : 'none', visibility: 'visible', opacity: '1' },
    getBoundingClientRect() { return { width: this.style.display === 'none' ? 0 : 320, height: this.style.display === 'none' ? 0 : 180 }; },
  };
  let observer;
  class Observer {
    constructor(callback) { this.callback = callback; }
    observe(target, options) { observer = { callback: this.callback, options }; }
  }
  class Xhr {
    constructor() { this.listeners = []; }
    addEventListener(name, callback) { if (name === 'loadend') this.listeners.push(callback); }
    send() {}
    complete() { for (const callback of this.listeners.splice(0)) callback(); }
  }
  const document = {
    documentElement: {}, readyState: 'complete',
    querySelectorAll: () => [frame],
    addEventListener: (name, callback) => { if (name === 'DOMContentLoaded') callback(); },
  };
  const add = (callback, delay, interval = 0) => {
    const key = ++id; timers.set(key, { callback, due: now + delay, interval }); return key;
  };
  const dispatch = (name, event) => {
    for (const callback of listeners.get(name) ?? []) callback(event);
  };
  const api = { callHandler(name, value) { calls.push(value.kind); return Promise.resolve(); } };
  const window = {
    XMLHttpRequest: Xhr,
    getComputedStyle: node => node.style,
    addEventListener(name, callback) { listeners.set(name, [...(listeners.get(name) ?? []), callback]); },
    setTimeout: (callback, delay) => add(callback, delay),
    setInterval: (callback, delay) => add(callback, delay, delay),
    clearTimeout: key => timers.delete(key),
    clearInterval: key => timers.delete(key),
    close() {},
    flutter_inappwebview: bridge ? api : undefined,
  };
  const location = new URL(url);
  const context = vm.createContext({ window, document, location, MutationObserver: Observer, Date: { now: () => now }, Promise, Number, Math, JSON });
  const evaluate = () => vm.runInContext(script, context);
  evaluate();
  function advance(amount) {
    const target = now + amount;
    while (true) {
      const due = [...timers].filter(([, item]) => item.due <= target).sort((a, b) => a[1].due - b[1].due)[0];
      if (!due) break;
      const [key, item] = due; now = item.due;
      if (!item.interval) timers.delete(key);
      item.callback();
      if (item.interval && timers.has(key)) item.due = now + item.interval;
    }
    now = target;
  }
  return {
    frame, calls, window, advance, evaluate,
    mutate() { if (observer?.options.attributes) observer.callback(); },
    ready() { window.flutter_inappwebview = api; dispatch('flutterInAppWebViewPlatformReady'); },
    message(data, origin = 'https://turing.captcha.qcloud.com') { dispatch('message', { data, origin }); },
    xhr() { return new Xhr(); },
  };
}
const checks = {
  'style-driven challenge closure resumes without a postMessage': () => {
    const h = harness();
    h.frame.style.display = 'none'; h.mutate(); h.advance(900);
    assert.deepEqual(h.calls, ['shown', 'closed']);
  },
  'CSS-only visibility changes are detected by polling': () => {
    const h = harness();
    h.frame.style.visibility = 'hidden'; h.advance(1300);
    assert.deepEqual(h.calls, ['shown', 'closed']);
  },
  'a briefly hidden challenge does not trigger a false completion': () => {
    const h = harness();
    h.frame.style.display = 'none'; h.mutate(); h.advance(300);
    h.frame.style.display = 'block'; h.mutate(); h.advance(1600);
    assert.deepEqual(h.calls, ['shown']);
  },
  'a human result waits for the parent network request before closing': () => {
    const h = harness(), request = h.xhr();
    request.send();
    h.message({ ret: 0, ticket: 'fixture-ticket', randstr: 'fixture-randstr' });
    h.advance(800); assert.deepEqual(h.calls, ['shown']);
    request.complete(); h.advance(300);
    assert.deepEqual(h.calls, ['shown', 'complete']);
  },
  'explicit cancellation never resumes verification': () => {
    const h = harness();
    h.message({ ret: 2 }); h.advance(2000);
    assert.deepEqual(h.calls, ['shown', 'cancel']);
  },
  'untrusted message origins cannot complete verification': () => {
    const h = harness();
    h.message({ ret: 0, ticket: 'fixture-ticket', randstr: 'fixture-randstr' }, 'https://captcha.qq.com.evil.example');
    h.advance(2000); assert.deepEqual(h.calls, ['shown']);
  },
  'a document-start result is queued until the native bridge is ready': () => {
    const h = harness({ bridge: false });
    h.message({ data: { ret: 0, ticket: 'fixture-ticket', randstr: 'fixture-randstr' } });
    h.advance(900); assert.deepEqual(h.calls, []);
    h.ready(); assert.deepEqual(h.calls, ['shown', 'complete']);
  },
  'a page closing before a challenge is cancelled': () => {
    const h = harness({ visible: false });
    h.window.close(); h.advance(900); assert.deepEqual(h.calls, ['cancel']);
  },
  'hidden elements with positive dimensions do not count as challenges': () => {
    const h = harness({ visible: false });
    h.frame.style.display = 'block'; h.frame.style.visibility = 'hidden';
    h.mutate(); h.window.close(); h.advance(1000);
    assert.deepEqual(h.calls, ['cancel']);
  },
  'duplicate script installation and closure deliver one result': () => {
    const h = harness(); h.evaluate();
    h.message({ ret: 0, ticket: 'fixture-ticket', randstr: 'fixture-randstr' });
    h.advance(1000); h.window.close(); h.advance(1000);
    assert.deepEqual(h.calls, ['shown', 'complete']);
  },
  'the bridge does not install on an unrelated top-level origin': () => {
    const h = harness({ url: 'https://qq.com.evil.example/verify' });
    h.message({ ret: 0, ticket: 'fixture-ticket', randstr: 'fixture-randstr' });
    h.advance(1000); assert.deepEqual(h.calls, []);
  },
};
let passed = 0;
for (const [name, check] of Object.entries(checks)) {
  try { check(); passed++; console.log('PASS ' + name); }
  catch (error) { console.error('FAIL ' + name + ': ' + error.message); process.exitCode = 1; }
}
console.log(passed + '/' + Object.keys(checks).length + ' verification bridge checks passed.');
