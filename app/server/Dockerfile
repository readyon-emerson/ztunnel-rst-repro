# Tiny Node.js HTTP server with production-grade graceful shutdown via
# http-terminator. Used as the destination pod in the bench: drains
# in-flight requests on SIGTERM the way real services configured with
# http-terminator do, including FIN of idle keep-alives and Connection:
# close on active responses.
FROM node:22-alpine

# netcat for the lame-duck readinessProbe (checks both port 8080 and
# absence of the /tmp/draining marker file the preStop hook creates).
RUN apk add --no-cache netcat-openbsd

WORKDIR /app
COPY package.json .
RUN npm install --omit=dev --silent
COPY server.js .

# Run as non-root to mirror typical production hardening. Listening on 8080
# (unprivileged) and exposing 80 via the Kubernetes Service.
USER node

EXPOSE 8080
CMD ["node", "server.js"]
