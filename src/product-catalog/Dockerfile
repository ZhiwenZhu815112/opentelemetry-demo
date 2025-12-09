# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


#
# Stage 1: Build product-catalog (Go)
#
FROM golang:1.24-bookworm AS builder

# Use a dedicated working directory for the build
WORKDIR /usr/src/app/

# Copy Go module files first to leverage Docker layer cache
COPY ./src/product-catalog/go.mod go.mod
COPY ./src/product-catalog/go.sum go.sum

# Download Go dependencies
RUN go mod download

# Copy the actual application source code
COPY ./src/product-catalog/genproto/oteldemo/ genproto/oteldemo/
COPY ./src/product-catalog/products/ products/
COPY ./src/product-catalog/main.go main.go

# Build a small, statically linked Linux binary
RUN CGO_ENABLED=0 GOOS=linux GO111MODULE=on go build -ldflags "-s -w" -o product-catalog main.go


#
# Stage 2: Minimal non-root runtime image
#
FROM gcr.io/distroless/static-debian12:nonroot

# Runtime working directory
WORKDIR /usr/src/app/

# Copy only the compiled binary from the builder image
COPY --from=builder /usr/src/app/product-catalog/ ./

EXPOSE ${PRODUCT_CATALOG_PORT}
ENTRYPOINT [ "./product-catalog" ]
