# Percona Server for MongoDB without AVX
# Based on the mongodb-no-avx setup, adapted for percona-server-mongodb 8.0.x (Bazel build)

FROM debian:12 AS build

# Build dependencies (mirrors percona-packaging/scripts/psmdb_builder.sh for Debian)
RUN apt-get update -y && apt-get install -y \
        build-essential \
        libcurl4-openssl-dev \
        libexpat1-dev \
        libkrb5-dev \
        libldap2-dev \
        liblzma-dev \
        libncurses6 \
        libsasl2-dev \
        libssl-dev \
        python-dev-is-python3 \
        python3-pip \
        python3-venv \
        patchelf \
        curl \
        git \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Percona release as <mongo version>-<percona release>, e.g. 8.0.38-16 (git tag psmdb-8.0.38-16)
ARG PSMDB_VERSION=8.0.38-16

RUN mkdir /src && \
    curl -o /tmp/psmdb.tar.gz -L "https://github.com/percona/percona-server-mongodb/archive/refs/tags/psmdb-${PSMDB_VERSION}.tar.gz" && \
    tar xaf /tmp/psmdb.tar.gz --strip-components=1 -C /src && \
    rm /tmp/psmdb.tar.gz

WORKDIR /src

# Apply the no-AVX patch (single unified diff, see psmdb_no_avx_patch.diff):
# 1. Toolchain: -march=sandybridge -> -march=nehalem (no AVX)
# 2. mozjs: drop -mavx2 and SIMD_avx2.cpp, SIMD.cpp never reports AVX2 support
# 3. aws-sdk-cpp: drop -mavx/-mavx2/-mavx512*, AVX2/AVX512/CLMUL intrinsics and SIMD encoding
COPY ./psmdb_no_avx_patch.diff /psmdb_no_avx_patch.diff
RUN patch -p1 < /psmdb_no_avx_patch.diff

ARG NUM_JOBS=

# Build mongod + mongos with Percona's release profile (see .bazelrc.psmdb).
# The install tree location differs between targets, so locate the binaries by path.
RUN python3 buildscripts/install_bazel.py && \
    export PATH="$HOME/.local/bin:$PATH" && \
    if [ -n "${NUM_JOBS}" ] && [ "${NUM_JOBS}" -gt 0 ]; then \
        export JOBS_ARG="--jobs=${NUM_JOBS}"; \
    fi && \
    bazel build --config=psmdb_opt_release \
        --define=MONGO_VERSION=${PSMDB_VERSION} \
        ${JOBS_ARG} \
        install-mongod install-mongos && \
    mkdir -p /install/bin && \
    for b in mongod mongos; do \
        src="$(find -L bazel-bin -maxdepth 4 -type f -path "*/bin/$b" | head -n1)" && \
        test -n "$src" && cp -L "$src" "/install/bin/$b"; \
    done

# Strip debug symbols to reduce binary size significantly
RUN strip --strip-debug /install/bin/mongod && \
    strip --strip-debug /install/bin/mongos

# Final image
FROM debian:12-slim

LABEL org.opencontainers.image.source=https://github.com/fenio/mongodb-no-avx
LABEL org.opencontainers.image.description="Percona Server for MongoDB 8.0 compiled without AVX/AVX2 CPU requirements"
LABEL org.opencontainers.image.licenses=SSPL-1.0

# Runtime dependencies (SASL client, LDAP and Kerberos are enabled in Percona builds)
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        libcurl4 \
        libssl3 \
        liblzma5 \
        libexpat1 \
        libsasl2-2 \
        libldap-2.5-0 \
        libgssapi-krb5-2 \
        ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /install/bin/mongod /usr/local/bin/
COPY --from=build /install/bin/mongos /usr/local/bin/

RUN mkdir -p /data/db /data/configdb && \
    chmod -R 750 /data && \
    chown -R 999:999 /data

RUN groupadd -r mongodb --gid=999 && \
    useradd -r -g mongodb --uid=999 mongodb

VOLUME ["/data/db", "/data/configdb"]

EXPOSE 27017

USER mongodb

ENTRYPOINT ["/usr/local/bin/mongod"]
CMD ["--bind_ip_all"]
