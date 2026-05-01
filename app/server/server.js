// Test server modeled on the production application's graceful shutdown:
// http-terminator wrapped around the HTTP server. On SIGTERM:
//   * stop accepting new connections (server.close)
//   * send `Connection: close` on every in-flight response so clients
//     remove the socket from their pool after the response completes
//   * call socket.end() on idle keep-alive sockets (graceful FIN, not RST)
//   * wait up to gracefulTerminationTimeout (15s) for active to drain
//   * after the timeout, forcibly destroy any remaining sockets
//
// Each request hangs for a random 1-3 seconds before responding, modeling
// a realistic microservice handler that does some work (DB query,
// downstream call, computation). At 2000 rps this puts ~4000 requests
// in-flight at any moment across the four replicas. When a pod is killed
// during a disruption event, all in-flight requests on that pod must be
// drained gracefully -- this is the failure mode production services
// live with.

const http = require('http');
const { createHttpTerminator } = require('http-terminator');

const MIN_DELAY_MS = 1000;
const MAX_DELAY_MS = 3000;

const server = http.createServer((req, res) => {
  const delay = MIN_DELAY_MS + Math.floor(Math.random() * (MAX_DELAY_MS - MIN_DELAY_MS + 1));
  const t = setTimeout(() => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('hello\n');
  }, delay);
  req.on('close', () => clearTimeout(t));
});

// Bump the listener accept-queue (default 511) so a burst of concurrent
// new connections from the client doesn't get refused before Node's
// accept loop can pick them up. We deliberately do NOT set
// server.maxConnections: leaving it undefined = unlimited (which is what
// we want); setting it to 0 is interpreted by Node as "max 0" and
// rejects everything.
server.listen({ port: 8080, backlog: 4096 }, () => console.log('listening on :8080'));

// 15s graceful termination timeout matches the production default.
const httpTerminator = createHttpTerminator({
  server,
  gracefulTerminationTimeout: 15_000,
});

process.on('SIGTERM', async () => {
  console.log('SIGTERM, draining via http-terminator');
  try {
    await httpTerminator.terminate();
    console.log('drain complete');
  } catch (err) {
    console.error('drain error', err);
  }
  process.exit(0);
});
