# Node.js client + tcpdump in one image. Node makes the requests and logs
# any socket-level errors (ECONNRESET, EPIPE, etc.); tcpdump captures the
# wire-level truth from inside the same pod's netns.
FROM node:22-alpine

RUN apk add --no-cache tcpdump

WORKDIR /app
COPY package.json .
RUN npm install --omit=dev --silent
COPY client.js .

# Long sleep so reproduce.sh can drive the test via kubectl exec. The Node
# client is invoked on demand, not at pod boot.
CMD ["sleep", "infinity"]
