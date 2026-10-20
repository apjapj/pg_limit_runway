# ci/Dockerfile: the server the CI job runs. The official postgres image already ships dblink (s6);
# pgTAP is the one addition, from the PostgreSQL apt repository the official image already has
# configured, for test/*.sql.
ARG PG_MAJOR=18
ARG APT_MAJOR=18
FROM postgres:${PG_MAJOR}
ARG PG_MAJOR
ARG APT_MAJOR
RUN apt-get update \
 && apt-get install -y --no-install-recommends "postgresql-${APT_MAJOR}-pgtap" \
 && rm -rf /var/lib/apt/lists/*
