# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
# Copyright 2023 The OpenTelemetry Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.



##
## Base image with runtime dependencies (gRPC + protobuf)
##
FROM docker.io/library/alpine:3.21 AS base

# Install only what we need and avoid caching index
RUN apk update && \
    apk add grpc-dev protobuf-dev


##
## Builder image: toolchain + build OpenTelemetry C++ SDK + currency service
##
FROM base AS builder

# Toolchain for building C++ code and OTel C++ SDK
RUN apk add git cmake make g++ linux-headers

ARG OPENTELEMETRY_CPP_VERSION

# Build OpenTelemetry C++ SDK with OTLP gRPC support
RUN git clone --depth 1 --branch v${OPENTELEMETRY_CPP_VERSION} https://github.com/open-telemetry/opentelemetry-cpp \
    && cd opentelemetry-cpp/ \
    && mkdir build \
    && cd build \
    && cmake .. -DCMAKE_CXX_STANDARD=17 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
          -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
          -DWITH_EXAMPLES=OFF -DWITH_OTLP_GRPC=ON -DWITH_ABSEIL=ON \
    && make -j$(nproc || sysctl -n hw.ncpu || echo 1) install && cd ../..

WORKDIR /currency

# Copy currency service sources and CMake files
COPY ./src/currency/build/ build/
COPY ./src/currency/proto/ proto/
COPY ./src/currency/src/ src/
COPY ./src/currency/genproto/CMakeLists.txt genproto/CMakeLists.txt
COPY ./src/currency/CMakeLists.txt CMakeLists.txt
COPY ./pb/demo.proto proto/demo.proto

# Build and install the currency binary into /usr/local
RUN mkdir -p build && cd build \
    && cmake .. \
    && make -j$(nproc || sysctl -n hw.ncpu || echo 1) install


##
## Final runtime image (non-root)
##
FROM base AS release

# Create a dedicated non-root user and group
RUN addgroup -S app && adduser -S app -G app

# Copy installed libraries and binaries from the builder stage
COPY --from=builder /usr/local /usr/local

# Ensure our non-root user can access installed files
RUN chown -R app:app /usr/local

USER app
WORKDIR /currency

# The service still reads the port from CURRENCY_PORT env and passes it as CLI arg
EXPOSE ${CURRENCY_PORT}

ENTRYPOINT ["sh", "-c", "./usr/local/bin/currency ${CURRENCY_PORT}"]
