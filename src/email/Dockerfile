# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


##
## Stage 1: Build Ruby dependencies (gems)
##
FROM docker.io/library/ruby:3.4.7-alpine3.22 AS builder
WORKDIR /email_server

# Copy Gemfile definitions first so bundle install can be cached
COPY ./src/email/Gemfile Gemfile
COPY ./src/email/Gemfile.lock Gemfile.lock

# Install build tools and compile native gems
RUN apk update && \
    apk add make gcc musl-dev gcompat && \
    bundle install

##
## Stage 2: Minimal runtime image (non-root)
##
FROM docker.io/library/ruby:3.4.7-alpine3.22

# Create a dedicated non-root user and group
RUN addgroup -S app && adduser -S app -G app

WORKDIR /email_server

# Copy installed Ruby gems from the builder stage
COPY --from=builder /usr/local/bundle/ /usr/local/bundle/

# Copy application source code
COPY ./src/email/views/ views/
COPY ./src/email/.ruby-version .ruby-version
COPY ./src/email/Gemfile Gemfile
COPY ./src/email/Gemfile.lock Gemfile.lock
COPY ./src/email/email_server.rb email_server.rb

# Ensure the non-root user owns the application and gems
RUN chown -R app:app /email_server /usr/local/bundle

# Run as non-root user from here on
USER app

# Email service listens on EMAIL_PORT (configured via env or compose/K8s)
EXPOSE ${EMAIL_PORT}
ENTRYPOINT ["bundle", "exec", "ruby", "email_server.rb"]
