# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


##
## Stage 1: Build checkout service (Go)
##
FROM golang:1.24-bookworm AS builder

# Build workspace inside the container
WORKDIR /usr/src/app/

# Copy Go module files and download dependencies
COPY ./src/checkout/go.mod go.mod
COPY ./src/checkout/go.sum go.sum
RUN go mod download

# Copy application source code (generated proto, Kafka, money helpers, main)
COPY ./src/checkout/genproto/oteldemo/ genproto/oteldemo/
COPY ./src/checkout/kafka/ kafka/
COPY ./src/checkout/money/ money/
COPY ./src/checkout/main.go main.go

# Build a statically linked Linux binary
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags "-s -w" -o checkout main.go

##
## Stage 2: Minimal non-root runtime
##
FROM gcr.io/distroless/static-debian12:nonroot

# Runtime working directory
WORKDIR /usr/src/app/

# Copy the compiled binary from the builder stage
COPY --from=builder /usr/src/app/checkout/ ./

# Port is provided by env (e.g. docker compose / Kubernetes Service)
EXPOSE ${CHECKOUT_PORT}

# Run the checkout service as non-root (image is already non-root)
ENTRYPOINT [ "./checkout" ]