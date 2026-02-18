###############################################################################
# Global Banking Data Warehouse — PostgreSQL Docker Image
# Base: Ubuntu 24.04 LTS  |  PostgreSQL: Latest Stable (17)
# One-click: docker compose up   →  fully loaded DW in ~2 minutes
###############################################################################

FROM ubuntu:24.04

# ── Build args (override at build time if needed) ─────────────────────────────
ARG PG_VERSION=17
ARG DB_NAME=banking_dw
ARG DB_USER=postgres
ARG DB_PASSWORD=Password1001

# Propagate as ENV so entrypoint.sh can use them
ENV PG_VERSION=${PG_VERSION} \
    DB_NAME=${DB_NAME} \
    DB_USER=${DB_USER} \
    DB_PASSWORD=${DB_PASSWORD} \
    DEBIAN_FRONTEND=noninteractive \
    PGDATA=/var/lib/postgresql/${PG_VERSION}/main \
    PATH="/usr/lib/postgresql/${PG_VERSION}/bin:$PATH"

# ── System update + PostgreSQL install ───────────────────────────────────────
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        locales \
        sudo && \
    # Generate UTF-8 locale (required by PostgreSQL)
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8 && \
    # Add official PostgreSQL APT repository
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
         | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
         https://apt.postgresql.org/pub/repos/apt \
         $(lsb_release -cs)-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update -y && \
    # Install PostgreSQL (latest stable via pgdg repo)
    apt-get install -y --no-install-recommends \
        postgresql-${PG_VERSION} \
        postgresql-client-${PG_VERSION} \
        postgresql-contrib-${PG_VERSION} && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# ── Copy SQL initialisation scripts ──────────────────────────────────────────
# Scripts are executed in filename order by entrypoint
COPY sql/01_banking_dw_ddl.sql    /docker-entrypoint-initdb/01_banking_dw_ddl.sql
COPY sql/02_banking_dw_data.sql   /docker-entrypoint-initdb/02_banking_dw_data.sql
COPY sql/03_sequences_reset.sql   /docker-entrypoint-initdb/03_sequences_reset.sql

# Copy and set entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── Expose PostgreSQL port ────────────────────────────────────────────────────
EXPOSE 5432

# ── Health check ─────────────────────────────────────────────────────────────
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=10 \
    CMD pg_isready -U ${DB_USER} -d ${DB_NAME} -h localhost || exit 1

ENTRYPOINT ["/entrypoint.sh"]
