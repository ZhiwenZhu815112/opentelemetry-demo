# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
# Copyright 2021 Google LLC
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

# https://mcr.microsoft.com/v2/dotnet/sdk/tags/list


# ENPM818R Final Project use only: 


# ----------------------------
# Stage 1: build cart service
# ----------------------------
# https://mcr.microsoft.com/v2/dotnet/sdk/tags/list

FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0 AS builder
ARG TARGETARCH

WORKDIR /usr/src/app/

# Copy source code and protobuf definitions
COPY ./src/cart/ ./
COPY ./pb/ ./pb/

# Restore dependencies for the target architecture
RUN dotnet restore ./src/cart.csproj -r linux-musl-$TARGETARCH

# Publish self-contained build to /cart
RUN dotnet publish ./src/cart.csproj -r linux-musl-$TARGETARCH --no-restore -o /cart

# ----------------------------
# Stage 2: runtime (non-root)
# ----------------------------
# https://mcr.microsoft.com/v2/dotnet/runtime-deps/tags/list
FROM mcr.microsoft.com/dotnet/runtime-deps:10.0-alpine3.22

WORKDIR /usr/src/app/

# Create a non-root user and group (Alpine style)
RUN addgroup -S app && adduser -S -G app app

# Copy published binaries from builder stage
COPY --from=builder /cart/ ./

# Disable hot reload of config files in container
ENV DOTNET_HOSTBUILDER__RELOADCONFIGONCHANGE=false


# Run the service as non-root
USER app

# Expose application port (consumed by docker-compose / Kubernetes Service)
EXPOSE ${CART_PORT}
ENTRYPOINT [ "./cart" ]
