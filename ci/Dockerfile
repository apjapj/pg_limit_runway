# ci/Dockerfile: the server the CI job runs. The official postgres image already ships dblink (s6) and
# nothing else is needed: these scenarios install no extension of their own yet.
ARG PG_MAJOR=18
FROM postgres:${PG_MAJOR}
