# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

##
## Stage 1: Base Python image
##
FROM python:3.12-slim-bookworm AS base

##
## Stage 2: Build dependencies (Locust + Playwright deps)
##
FROM base AS builder

# Install build tools for Python packages that need compilation
RUN apt-get -qq update \
    && apt-get install -y --no-install-recommends g++ \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies into a separate prefix so we can copy them later
COPY ./src/load-generator/requirements.txt .
RUN pip install --prefix="/reqs" -r requirements.txt

##
## Stage 3: Runtime image (non-root)
##
FROM base

# Create dedicated non-root user and group for the load generator
RUN groupadd -r app && useradd -r -g app app

WORKDIR /usr/src/app/

# Copy installed Python packages from the builder stage
COPY --from=builder /reqs /usr/local

# Configure Playwright browser path and install Chromium with minimal deps
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers
RUN playwright install --with-deps chromium

# Copy application code
COPY ./src/load-generator/locustfile.py .
COPY ./src/load-generator/people.json .

# Ensure the non-root user owns app files and Playwright browsers
RUN chown -R app:app /usr/src/app /opt/pw-browsers || true

# Switch to non-root user
USER app

# Run Locust; additional args (host, users, spawn-rate) can be passed at runtime
ENTRYPOINT ["locust", "--skip-log-setup"]
