import { BlockList, isIP } from 'node:net';

export class NetworkError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

const dnsName = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i;
const badUrlChar = /[\u0000-\u0020\u007f-\uffff\\#]/;
const httpsAuthority = /^https:\/\/([a-z0-9.-]+)(?::443)?(?=[/?]|$)/i;

function domain(host) {
  if (typeof host !== 'string' || !dnsName.test(host) || isIP(host) ||
      /(?:^|\.)(?:localhost|local|internal|onion|arpa)$/i.test(host)) {
    throw new NetworkError('target-denied');
  }
  return host.toLowerCase();
}

export function grant(hosts = []) {
  if (!Array.isArray(hosts) || hosts.length > 32) {
    throw new NetworkError('invalid-grant');
  }
  return new Set(hosts.map(domain));
}

export function destination(value, hosts, base) {
  if (typeof value !== 'string' || value.length > 2048 ||
      value.length === 0 || badUrlChar.test(value)) {
    throw new NetworkError('target-denied');
  }
  let absolute = value;
  if (base && value.startsWith('//')) absolute = 'https:' + value;
  const hasScheme = /^[a-z][a-z0-9+.-]*:/i.test(absolute);
  const authority = httpsAuthority.exec(absolute);
  if ((hasScheme || !base) && !authority) throw new NetworkError('target-denied');
  let url;
  try {
    url = new URL(absolute, base);
  } catch {
    throw new NetworkError('target-denied');
  }
  const host = domain(url.hostname);
  if (url.protocol !== 'https:' || url.port || url.username || url.password ||
      (authority && authority[1].toLowerCase() !== host) ||
      url.href.length > 2048 || !hosts.has(host)) {
    throw new NetworkError('target-denied');
  }
  return url;
}

// Conservative host policy: exclude non-public/special-use IPv4 ranges, and
// accept only global unicast IPv6 outside its special-use assignments.
const blocked = new BlockList();
for (const [address, bits] of [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8],
  ['169.254.0.0', 16], ['172.16.0.0', 12], ['192.0.0.0', 24],
  ['192.0.2.0', 24], ['192.88.99.0', 24], ['192.168.0.0', 16],
  ['198.18.0.0', 15], ['198.51.100.0', 24], ['203.0.113.0', 24],
  ['224.0.0.0', 4], ['240.0.0.0', 4],
]) blocked.addSubnet(address, bits);
const globalV6 = new BlockList();
globalV6.addSubnet('2000::', 3, 'ipv6');
for (const [address, bits] of [
  ['2001::', 23], ['2001:db8::', 32], ['2002::', 16], ['3fff::', 20],
]) blocked.addSubnet(address, bits, 'ipv6');

export function publicAddress(answers) {
  if (!Array.isArray(answers) || answers.length === 0 || answers.length > 32) {
    throw new NetworkError('dns');
  }
  for (const { address, family } of answers) {
    if (typeof address !== 'string' || address.includes('%') || isIP(address) !== family ||
        (family === 4 ? blocked.check(address) :
          family !== 6 || !globalV6.check(address, 'ipv6') || blocked.check(address, 'ipv6'))) {
      throw new NetworkError('address-denied');
    }
  }
  // One checked address per attempt, with no second lookup or implicit retry.
  return { ...(answers.find((answer) => answer.family === 4) ?? answers[0]) };
}

export function check(signal) {
  if (signal.aborted) {
    throw signal.reason instanceof NetworkError ? signal.reason : new NetworkError('cancelled');
  }
}

export function safeError(error, signal) {
  check(signal);
  return error instanceof NetworkError ? error : new NetworkError('transport');
}
