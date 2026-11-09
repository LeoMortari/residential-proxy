FROM alpine:3.20 AS build
ARG PROXY_VERSION=0.9.4
ARG PROXY_SHA256=b497f74d6cc7ee58ff824457427acc02c6f7a102e483816fbb1b2494942ef983
RUN apk add --no-cache build-base curl
WORKDIR /src
RUN curl -fsSL "https://github.com/3proxy/3proxy/archive/refs/tags/${PROXY_VERSION}.tar.gz" -o 3proxy.tgz \
    && echo "${PROXY_SHA256}  3proxy.tgz" | sha256sum -c - \
    && tar xzf 3proxy.tgz --strip-components=1 \
    && make -f Makefile.Linux \
    && install -D -m 0755 bin/3proxy /out/3proxy

FROM alpine:3.20
RUN addgroup -g 10001 -S proxygroup \
    && adduser -u 10001 -S -G proxygroup -s /sbin/nologin -D -H proxyuser \
    && mkdir -p /var/log/3proxy \
    && chown proxyuser:proxygroup /var/log/3proxy
COPY --from=build /out/3proxy /usr/local/bin/3proxy
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh
USER 10001:10001
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD nc -z 127.0.0.1 8888 && nc -z 127.0.0.1 1080 || exit 1
ENTRYPOINT ["/entrypoint.sh"]
