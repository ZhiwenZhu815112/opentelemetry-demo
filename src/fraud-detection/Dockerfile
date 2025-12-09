# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

##
## Stage 1: Build shaded JAR with Gradle
##
FROM --platform=${BUILDPLATFORM} gradle:8-jdk17 AS builder

WORKDIR /usr/src/app/

# Copy service source code
COPY ./src/fraud-detection/ ./

# Copy shared protobuf definitions into the expected proto directory
COPY ./pb/ ./src/main/proto/

# Build fat JAR using Gradle shadow plugin
RUN gradle shadowJar

##
## Stage 2: Minimal non-root runtime (Java 17)
##
FROM gcr.io/distroless/java17-debian12:nonroot

# Version of the OpenTelemetry Java agent is provided at build time
ARG OTEL_JAVA_AGENT_VERSION

WORKDIR /usr/src/app/

# Download OpenTelemetry Java agent (auto-instrumentation)
ADD --chmod=644 https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v$OTEL_JAVA_AGENT_VERSION/opentelemetry-javaagent.jar /usr/src/app/opentelemetry-javaagent.jar

# Enable auto-instrumentation for the JVM
ENV JAVA_TOOL_OPTIONS=-javaagent:/usr/src/app/opentelemetry-javaagent.jar

# Copy built JAR from builder image
COPY --from=builder /usr/src/app/build/libs/fraud-detection-1.0-all.jar fraud-detection-1.0-all.jar

ENTRYPOINT [ "java", "-jar", "fraud-detection-1.0-all.jar" ]
