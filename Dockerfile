# syntax=docker/dockerfile:1.7
ARG NODE_IMAGE=node:22-alpine
ARG DASHBOARD_VERSION=
ARG GO_VERSION=
ARG GO_SHA256=

FROM ${NODE_IMAGE} AS dashboard-builder
ARG DASHBOARD_VERSION
WORKDIR /app

RUN apk --no-cache upgrade && apk --no-cache add \
    ca-certificates curl python3 make g++ linux-headers

RUN test -n "${DASHBOARD_VERSION}" || { echo "DASHBOARD_VERSION build arg is required; the release workflow resolves the newest upstream tag" >&2; exit 1; }; \
    curl -fsSL "https://github.com/decolua/9router/archive/refs/tags/${DASHBOARD_VERSION}.tar.gz" \
    | tar -xz --strip-components=1

ENV NEXT_TELEMETRY_DISABLED=1
RUN npm install --registry=https://registry.npmmirror.com
RUN npm run build

FROM ${NODE_IMAGE} AS runner
ARG GO_VERSION
ARG GO_SHA256
ARG TARGETARCH
WORKDIR /app

LABEL org.opencontainers.image.title="9router"
LABEL org.opencontainers.image.source="https://github.com/decolua/9router"

ENV NODE_ENV=production
ENV DASHBOARD_PORT=3000
ENV GO_PORT=20129
ENV PORT=3000
ENV HOSTNAME=0.0.0.0
ENV NEXT_TELEMETRY_DISABLED=1
ENV DATA_DIR=/app/data

RUN test -n "${GO_VERSION}" || { echo "GO_VERSION build arg is required; the release workflow resolves the newest upstream tag" >&2; exit 1; }; \
    apk --no-cache upgrade && apk --no-cache add \
    ca-certificates curl gcompat nginx su-exec \
    && case "${TARGETARCH}" in \
         amd64) GO_ARCH=amd64 ;; \
         arm64) GO_ARCH=arm64 ;; \
         *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && asset="9router-go-linux-${GO_ARCH}" \
    && url="https://github.com/luqman-v1/9router-go/releases/download/${GO_VERSION}/${asset}" \
    && curl -fsSL "${url}" -o "/tmp/${asset}" \
    && if [ -n "${GO_SHA256}" ]; then \
         echo "${GO_SHA256}  /tmp/${asset}" | sha256sum -c -; \
       fi \
    && install -m 0755 "/tmp/${asset}" /usr/local/bin/9router-go \
    && rm -f "/tmp/${asset}"

COPY --from=dashboard-builder /app/public ./public
COPY --from=dashboard-builder /app/.next/static ./.next/static
COPY --from=dashboard-builder /app/.next/standalone ./
COPY --from=dashboard-builder /app/custom-server.js ./custom-server.js
COPY --from=dashboard-builder /app/open-sse ./open-sse
COPY --from=dashboard-builder /app/src/mitm ./src/mitm
COPY --from=dashboard-builder /app/node_modules/node-forge ./node_modules/node-forge
COPY --from=dashboard-builder /app/node_modules/next ./node_modules/next
COPY --from=dashboard-builder /app/node_modules/sql.js ./node_modules/sql.js
COPY nginx.conf /etc/nginx/nginx.conf
COPY combined-entrypoint.sh /usr/local/bin/combined-entrypoint.sh

RUN chmod 0755 /usr/local/bin/9router-go /usr/local/bin/combined-entrypoint.sh \
    && mkdir -p /tmp/nginx /app/data /app/data-home \
    && chown -R node:node /app /tmp/nginx

EXPOSE 20128

ENTRYPOINT ["/usr/local/bin/combined-entrypoint.sh"]
CMD ["node", "custom-server.js"]
