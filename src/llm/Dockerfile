# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


##
## Stage 1: Build Python virtual environment with dependencies
##
FROM docker.io/library/python:3.12-alpine3.22 AS build-venv

# Install build tools for compiling any native dependencies
RUN apk update && \
    apk add gcc g++ linux-headers

# Copy requirements first to leverage Docker layer cache
COPY ./src/llm/requirements.txt requirements.txt

# Create virtual environment and install dependencies into it
RUN python -m venv venv && \
    venv/bin/pip install --no-cache-dir -r requirements.txt

##
## Stage 2: Minimal runtime image (non-root)
##
FROM docker.io/library/python:3.12-alpine3.22

# Create a dedicated non-root user and group
RUN addgroup -S app && adduser -S app -G app

WORKDIR /app

# Copy pre-built virtual environment from builder stage
COPY --from=build-venv /venv/ /venv/

# Copy application code and data files
COPY ./src/llm/app.py app.py
COPY ./src/llm/product-review-summaries/product-review-summaries.json product-review-summaries.json
COPY ./src/llm/product-review-summaries/inaccurate-product-review-summaries.json inaccurate-product-review-summaries.json

# Ensure the non-root user owns the app and venv
RUN chown -R app:app /app /venv

# Run as non-root user from here on
USER app

# LLM service listens on LLM_PORT (configured via env / compose / K8s)
EXPOSE ${LLM_PORT}
ENTRYPOINT [ "/venv/bin/python", "app.py" ]
