# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

##
## Stage 1: Build Python virtual environment with dependencies
##
FROM docker.io/library/python:3.12-alpine3.22 AS build-venv

# Use a working directory (not strictly required, but keeps things tidy)
WORKDIR /app

# Install build dependencies for native Python packages
RUN apk update && \
    apk add gcc g++ linux-headers

# Copy dependency definitions first to maximize layer caching
COPY ./src/product-reviews/requirements.txt requirements.txt

# Create a virtual environment in /venv and install dependencies
RUN python -m venv /venv && \
    /venv/bin/pip install --no-cache-dir -r requirements.txt

RUN /venv/bin/opentelemetry-bootstrap -a install


##
## Stage 2: Minimal runtime image (non-root)
##
FROM docker.io/library/python:3.12-alpine3.22

# Create a dedicated non-root user and group
RUN addgroup -S app && adduser -S app -G app

# Application directory
WORKDIR /app

# Copy the pre-built virtual environment from the builder stage
COPY --from=build-venv /venv/ /venv/

# Copy application source code
COPY ./src/product-reviews/demo_pb2_grpc.py demo_pb2_grpc.py
COPY ./src/product-reviews/demo_pb2.py demo_pb2.py
COPY ./src/product-reviews/product_reviews_server.py product_reviews_server.py
COPY ./src/product-reviews/database.py database.py
COPY ./src/product-reviews/metrics.py metrics.py

# Ensure the non-root user owns the application files and venv
RUN chown -R app:app /app /venv

# Switch to non-root user
USER app

# gRPC product-reviews service will listen on PRODUCT_REVIEWS_PORT
EXPOSE ${PRODUCT_REVIEWS_PORT}

# Start the service with OpenTelemetry auto-instrumentation
ENTRYPOINT [ "/venv/bin/opentelemetry-instrument", "/venv/bin/python", "product_reviews_server.py" ]
