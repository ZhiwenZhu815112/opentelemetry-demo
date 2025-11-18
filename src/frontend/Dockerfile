# Copyright The OpenTelemetry Authors

# SPDX-License-Identifier: Apache-2.0





### OUR ENPM818R Final Project requirement:

    # Use a multi-stage Docker bulds. 

    # non-root users

    # ----------------------------



# Stage 1: build Next.js app

# ----------------------------

FROM docker.io/library/node:22-slim AS builder



WORKDIR /app



# Install dependencies

COPY ./src/frontend/package.json package.json

COPY ./src/frontend/package-lock.json package-lock.json

RUN npm ci



# Copy source code

COPY ./src/frontend/components/ components/

COPY ./src/frontend/gateways/ gateways/

COPY ./src/frontend/pages/ pages/

COPY ./src/frontend/protos/ protos/

COPY ./src/frontend/providers/ providers/

COPY ./src/frontend/services/ services/

COPY ./src/frontend/styles/ styles/

COPY ./src/frontend/types/ types/

COPY ./src/frontend/utils/enums/ utils/enums/

COPY ./src/frontend/utils/telemetry/ utils/telemetry/

COPY ./src/frontend/utils/imageLoader.js utils/imageLoader.js

COPY ./src/frontend/utils/Request.ts utils/Request.ts

COPY ./src/frontend/next.config.js next.config.js

COPY ./src/frontend/tsconfig.json tsconfig.json



# Build Next.js standalone app

RUN npm run build





# ----------------------------

# Stage 2: install production deps

# ----------------------------

FROM docker.io/library/node:22-slim AS deps

WORKDIR /app

COPY ./src/frontend/package.json package.json

COPY ./src/frontend/package-lock.json package-lock.json

RUN npm ci --omit=dev


# ----------------------------

# Stage 3: minimal non-root runtime

# ----------------------------

FROM gcr.io/distroless/nodejs22-debian12:nonroot

WORKDIR /app


# Copy built app

COPY --from=builder /app/.next/standalone/ ./

COPY --from=builder /app/.next/static/ .next/static/


# Copy production node_modules

COPY --from=deps /app/node_modules/ node_modules/


# Public assets and telemetry instrumentation

COPY ./src/frontend/public/ public/

COPY ./src/frontend/utils/telemetry/Instrumentation.js Instrumentation.js

EXPOSE ${FRONTEND_PORT}

CMD ["--require=./Instrumentation.js", "server.js"]