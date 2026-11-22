import assert from 'node:assert/strict';
import { createHostSession } from './broker.mjs';

// A published PCM test file from pydub's MIT-licensed test suite.
// This optional check has no account, cookies, audio output or local download.
const host = 'raw.githubusercontent.com';
const revision = '103e339d3bc7a9a58a9f1de65f7d8074659b5f5a';
const fixtureUrl = 'https://' + host + '/jiaaro/pydub/' + revision + '/test/data/test-dc_offset.wav';
const session = createHostSession({ mediaHosts: [host] });
let phase = 'open';
try {
  const wave = await session.wave(fixtureUrl);
  phase = 'read';
  const prefix = await wave.read(44);
  assert.equal(prefix.toString('ascii', 0, 4), 'RIFF');
  assert.equal(wave.size, 882044);
  const samples = await wave.read(128);
  assert.ok(samples.length > 0);
  assert.ok(wave.seekable, 'the server did not advertise a verifiable range');
  phase = 'seek';
  assert.equal(await wave.seek(44000), 44000);
  const distant = await wave.read(128);
  assert.ok(distant.length > 0);
  assert.equal(wave.position, 44000 + distant.length);
  wave.close();
  console.log('PASS public HTTPS certificate, pinned dialing, WAV and nonzero Range');
} catch (error) {
  console.error('Public HTTPS fixture failed at ' + phase + ': ' + (error.code ?? 'fixture'));
  process.exitCode = 1;
} finally {
  session.revoke();
}
