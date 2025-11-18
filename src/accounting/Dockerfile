# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

#
# Stage 1: Restore and build the Accounting service
#
FROM --platform=${BUILDPLATFORM} mcr.microsoft.com/dotnet/sdk:8.0 AS builder

ARG TARGETARCH
ARG BUILD_CONFIGURATION=Release

# Use a dedicated build directory
WORKDIR /src

# Copy project source and protobuf definition from the repository root.
# IMPORTANT: this Dockerfile assumes you build with:
#   docker build -f src/accounting/Dockerfile .
COPY ["/src/accounting/", "Accounting/"]
COPY ["/pb/demo.proto", "Accounting/src/protos/demo.proto"]

# Restore dependencies for the target Linux runtime/architecture
RUN dotnet restore "./Accounting/Accounting.csproj" -r linux-$TARGETARCH

# Build the application into the /app/build directory
WORKDIR "/src/Accounting"
RUN dotnet build "./Accounting.csproj" -r linux-$TARGETARCH -c $BUILD_CONFIGURATION -o /app/build

#
# Stage 2: Publish trimmed application
#
FROM builder AS publish

ARG TARGETARCH
ARG BUILD_CONFIGURATION=Release

# Publish a self-contained, trimmed output without app host
RUN dotnet publish "./Accounting.csproj" -r linux-$TARGETARCH -c $BUILD_CONFIGURATION -o /app/publish /p:UseAppHost=false

#
# Stage 3: Runtime image (non-root)
#

FROM mcr.microsoft.com/dotnet/aspnet:8.0

# Use the predefined non-root user from the base image
USER app
WORKDIR /app

# Copy published binaries from the publish stage
COPY --from=publish /app/publish .

# Temporarily switch to root to adjust permissions for logs and instrumentation script
USER root
RUN mkdir -p "/var/log/opentelemetry/dotnet"
RUN chown app "/var/log/opentelemetry/dotnet"
RUN chown app "/app/instrument.sh"

# Drop back to non-root for runtime
USER app

# Configure .NET auto-instrumentation for this service
ENV OTEL_DOTNET_AUTO_TRACES_ADDITIONAL_SOURCES=Accounting.Consumer

# The service port is configured via environment/Kubernetes Service,
# so we do not hard-code EXPOSE here.
ENTRYPOINT ["./instrument.sh", "dotnet", "Accounting.dll"]
