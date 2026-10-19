# Credence: the Flutter web app and the Dart server in one image.
#
#   docker build -t credence .
#   docker run -p 8094:8094 -v credence-data:/data \
#     -e PUBLIC_BASE_URL=http://localhost:8094 credence
#
# Configuration is environment variables only. SQLite lives in /data.

FROM debian:bookworm-slim AS web
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils zip \
 && rm -rf /var/lib/apt/lists/* \
 && printf '#!/bin/sh\nexec /usr/bin/tar --no-same-owner "$@"\n' > /usr/local/bin/tar \
 && chmod +x /usr/local/bin/tar
ENV TAR_OPTIONS="--no-same-owner"
ARG FLUTTER_VERSION=3.44.2
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" \
      https://github.com/flutter/flutter.git /opt/flutter \
 && git config --global --add safe.directory /opt/flutter
ENV PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}
RUN flutter config --no-analytics --no-cli-animations --no-enable-android \
 && flutter precache --web
COPY packages/sui_wallet_web /src/packages/sui_wallet_web
COPY packages/upload_recovery /src/packages/upload_recovery
WORKDIR /src/app
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY app/ ./
RUN flutter build web --release --no-wasm-dry-run --no-web-resources-cdn

# 2. Compile the server to a native executable.
FROM dart:3.12.2 AS server
COPY packages/sui_auth /src/packages/sui_auth
COPY packages/walrus_blob_check /src/packages/walrus_blob_check
WORKDIR /src/server
COPY server/pubspec.yaml server/pubspec.lock ./
RUN dart pub get
COPY server/ ./
RUN mkdir -p /out && dart compile exe bin/server.dart -o /out/credence-server

# 3. Small runtime image.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s "$(find /usr/lib -name 'libsqlite3.so.0' | head -n 1)" /usr/lib/libsqlite3.so \
 && useradd --system --home /data credence \
 && mkdir -p /data && chown credence /data
COPY --from=server /out/credence-server /app/credence-server
COPY --from=web /src/app/build/web /app/web
ENV PORT=8094 \
    DATA_DIR=/data \
    WEB_DIR=/app/web \
    SUI_CHAIN=testnet \
    EPOCHS=26 \
    MAX_UPLOAD_MB=10
USER credence
VOLUME ["/data"]
EXPOSE 8094
CMD ["/app/credence-server"]
