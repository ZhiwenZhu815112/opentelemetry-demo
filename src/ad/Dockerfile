# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

#
# Stage 1: Build the Ad service with Gradle
#
FROM --platform=${BUILDPLATFORM} eclipse-temurin:21-jdk AS builder
ARG _JAVA_OPTIONS
WORKDIR /usr/src/app/


# Copy Gradle wrapper and build configuration from the repository root.
# IMPORTANT: this Dockerfile assumes you build with:
#   docker build -f src/ad/Dockerfile .
COPY ./src/ad/gradlew* ./src/ad/settings.gradle* ./src/ad/build.gradle ./
COPY ./src/ad/gradle ./gradle

# Warm up Gradle and download dependencies
RUN chmod +x ./gradlew
RUN ./gradlew
RUN ./gradlew downloadRepos

# Copy application sources and protobuf definitions
COPY ./src/ad/ ./
COPY ./pb/ ./proto

# Build the distribution into build/install/...
RUN chmod +x ./gradlew
RUN ./gradlew installDist -PprotoSourceDir=./proto

#
# Stage 2: Minimal runtime image (non-root)
#
FROM eclipse-temurin:21-jre

ARG OTEL_JAVA_AGENT_VERSION
ARG _JAVA_OPTIONS

WORKDIR /usr/src/app/

# Create a non-root user to run the service
RUN groupadd --system app && useradd --system --gid app app

# Copy the built application from the builder stage
COPY --from=builder /usr/src/app/ ./

# Download the OpenTelemetry Java agent
ADD --chmod=644 https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v$OTEL_JAVA_AGENT_VERSION/opentelemetry-javaagent.jar /usr/src/app/opentelemetry-javaagent.jar

# Ensure the non-root user owns the application directory
RUN chown -R app:app /usr/src/app

# Switch to non-root user for runtime
USER app

# Attach the Java agent via JAVA_TOOL_OPTIONS
ENV JAVA_TOOL_OPTIONS=-javaagent:/usr/src/app/opentelemetry-javaagent.jar


# The service port is configured via environment (docker compose / Kubernetes),
# so we keep the generic exposed port here.
EXPOSE ${AD_PORT}
ENTRYPOINT [ "./build/install/opentelemetry-demo-ad/bin/Ad" ]
