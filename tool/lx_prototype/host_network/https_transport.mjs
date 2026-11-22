import { Resolver } from 'node:dns/promises';
import { Agent, request } from 'node:https';
import { isIP } from 'node:net';
import { check, NetworkError } from './policy.mjs';

async function resolve(host, signal) {
  check(signal);
  const resolver = new Resolver({ timeout: 1500, tries: 1 });
  const abort = () => resolver.cancel();
  signal.addEventListener('abort', abort, { once: true });
  try {
    const query = async (family) => {
      try {
        const addresses = await (family === 4 ? resolver.resolve4(host) : resolver.resolve6(host));
        return addresses.map((address) => ({ address, family }));
      } catch (error) {
        if (error.code === 'ENODATA' || error.code === 'ENOTFOUND') return [];
        throw error;
      }
    };
    const answers = (await Promise.all([query(4), query(6)])).flat();
    check(signal);
    return answers;
  } catch {
    check(signal);
    throw new NetworkError('dns');
  } finally {
    resolver.cancel();
    signal.removeEventListener('abort', abort);
  }
}

// This low-level adapter accepts only a destination already checked by the
// broker. The hostname remains the HTTP authority and TLS identity.
function dial({ url, pin, method, headers, body, signal }) {
  check(signal);
  return new Promise((settle, reject) => {
    const agent = new Agent({ keepAlive: false, maxSockets: 1 });
    let incoming;
    let outgoing;
    let closed = false;
    function abort() {
      close();
      reject(new NetworkError('cancelled'));
    }
    function close() {
      if (closed) return;
      closed = true;
      signal.removeEventListener('abort', abort);
      incoming?.destroy();
      outgoing?.destroy();
      agent.destroy();
    }
    try {
      outgoing = request(url, {
        agent, method, headers,
        maxHeaderSize: 16 * 1024,
        highWaterMark: 32 * 1024,
        rejectUnauthorized: true,
        servername: url.hostname,
        family: pin.family,
        autoSelectFamily: false,
        lookup(host, options, done) {
          if (signal.aborted || host !== url.hostname || isIP(pin.address) !== pin.family) {
            done(new NetworkError('address-denied'));
          } else if (options.all) {
            done(null, [{ address: pin.address, family: pin.family }]);
          } else {
            done(null, pin.address, pin.family);
          }
        },
      }, (response) => {
        incoming = response;
        // A disconnect while the consumer is paused still has an error handler.
        response.on('error', () => {});
        // Node sets the peer from the one numeric result above. Keep identity
        // and connection bound to that same address, including IPv6.
        const peer = response.socket.remoteAddress;
        if (signal.aborted || !peer || !sameAddress(peer, pin)) {
          close();
          reject(new NetworkError('address-denied'));
          return;
        }
        settle({ status: response.statusCode, headers: response.headersDistinct, body: response, close });
      });
      outgoing.on('error', (error) => {
        close();
        reject(error);
      });
      signal.addEventListener('abort', abort, { once: true });
      outgoing.end(body);
    } catch (error) {
      close();
      reject(error);
    }
  });
}

function sameAddress(peer, pin) {
  if (peer === pin.address) return true;
  if (pin.family !== 6 || isIP(peer) !== 6) return false;
  // Normalize equivalent IPv6 textual representations without resolving them.
  return new URL('https://[' + peer + ']').hostname ===
    new URL('https://[' + pin.address + ']').hostname;
}

export const httpsTransport = Object.freeze({ resolve, dial });
