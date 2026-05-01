// Sustained dual-client request stream against the server Service:
//   * half of the requests go via Node 22's global fetch (undici)
//   * half go via axios (Node http core)
//
// This mirrors typical NestJS-style service-to-service code where some
// call sites use Apollo Client / global fetch and others use axios
// directly. Both clients use stock defaults -- no httpAgent / dispatcher
// overrides -- so the test reflects what an unconfigured production
// service sees during disruption events. Errors are tracked separately
// per client so we can see whether one path is significantly more
// affected by the drain event than the other.

const axios = require('axios');

// CLIENT_FIX=1 installs a custom undici dispatcher with a short
// keepAliveTimeout. The default is 4s; we drop it to 500ms so idle
// pool sockets are reaped quickly enough that the "stale pool socket
// race" (UND_ERR_SOCKET / "other side closed") rarely fires during pod
// disruption. We do NOT set it lower than the request-completion time,
// because that would force every request to open a fresh TCP connection
// and exhaust ephemeral ports under load.
//
// axios uses Node's http.globalAgent which is keepAlive=false by
// default, so it has no equivalent pool to fix. Its remaining errors
// (in-flight cancellation when a backend dies mid-request) are not
// addressable client-side without retry, which we deliberately don't
// add here.
if (process.env.CLIENT_FIX === '1') {
  const { setGlobalDispatcher, Agent } = require('undici');
  setGlobalDispatcher(new Agent({ keepAliveTimeout: 500, keepAliveMaxTimeout: 5_000 }));
  console.log('[undici] CLIENT_FIX=1: keepAliveTimeout=500ms (short pool reuse window)');
} else {
  console.log('[undici] using default global dispatcher');
}
console.log('[axios] using default http.globalAgent (no keep-alive)');

const HOST = process.env.HOST || 'server';
const PORT = parseInt(process.env.PORT || '80', 10);
const RPS = parseInt(process.env.RPS || '100', 10);
const DURATION_MS = parseInt(process.env.DURATION_MS || '30000', 10);

const url = `http://${HOST}:${PORT}/`;

const counts = {
  fetch: { sent: 0, ok: 0, resets: 0, other: 0 },
  axios: { sent: 0, ok: 0, resets: 0, other: 0 },
};
const start = Date.now();

function classify(err) {
  const cause = err.cause;
  const causeCode = cause?.code || cause?.name;
  const codes = [err.code, causeCode, err.name].filter(Boolean).join(' ');
  const messages = [err.message || '', cause?.message || ''].join(' ');
  if (
    /ECONNRESET/i.test(codes) ||
    /ECONNRESET|socket hang up|other side closed|aborted|terminated/i.test(messages)
  ) {
    return { kind: 'reset', code: causeCode || err.code || err.name, msg: messages };
  }
  return { kind: 'other', code: causeCode || err.code || err.name || 'unknown', msg: messages };
}

async function fireFetch(idx) {
  counts.fetch.sent += 1;
  const t = Date.now() - start;
  try {
    const res = await fetch(url);
    await res.text();
    if (res.status >= 400) {
      counts.fetch.other += 1;
      console.log(`[fetch ${idx}] t=${t}ms other code=HTTP_${res.status} msg="HTTP ${res.status}"`);
      return;
    }
    counts.fetch.ok += 1;
  } catch (err) {
    const c = classify(err);
    if (c.kind === 'reset') counts.fetch.resets += 1;
    else counts.fetch.other += 1;
    console.log(`[fetch ${idx}] t=${t}ms ${c.kind} code=${c.code} msg="${c.msg}"`);
  }
}

async function fireAxios(idx) {
  counts.axios.sent += 1;
  const t = Date.now() - start;
  try {
    await axios.get(url);
    counts.axios.ok += 1;
  } catch (err) {
    const c = classify(err);
    if (c.kind === 'reset') counts.axios.resets += 1;
    else counts.axios.other += 1;
    console.log(`[axios ${idx}] t=${t}ms ${c.kind} code=${c.code} msg="${c.msg}"`);
  }
}

console.log(
  `firing at ${RPS} rps for ${DURATION_MS}ms against ${url} (50% fetch/undici, 50% axios)`,
);

const TICK_MS = 10;
const PER_TICK = Math.max(1, Math.ceil((RPS * TICK_MS) / 1000));
let i = 0;
const ticker = setInterval(() => {
  for (let k = 0; k < PER_TICK; k++) {
    if (i % 2 === 0) fireFetch(i);
    else fireAxios(i);
    i += 1;
  }
}, TICK_MS);

const statsTicker = setInterval(() => {
  const t = Date.now() - start;
  console.log(
    `stats t=${t}ms ` +
      `fetch{sent=${counts.fetch.sent} ok=${counts.fetch.ok} resets=${counts.fetch.resets} other=${counts.fetch.other}} ` +
      `axios{sent=${counts.axios.sent} ok=${counts.axios.ok} resets=${counts.axios.resets} other=${counts.axios.other}}`,
  );
}, 1000);

setTimeout(() => {
  clearInterval(ticker);
  setTimeout(() => {
    clearInterval(statsTicker);
    console.log(
      `final ` +
        `fetch{sent=${counts.fetch.sent} ok=${counts.fetch.ok} resets=${counts.fetch.resets} other=${counts.fetch.other}} ` +
        `axios{sent=${counts.axios.sent} ok=${counts.axios.ok} resets=${counts.axios.resets} other=${counts.axios.other}}`,
    );
    process.exit(0);
  }, 2000);
}, DURATION_MS);
