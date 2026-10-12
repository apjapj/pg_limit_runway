# pg_limit_runway Makefile
EXTENSION = pg_limit_runway
DATA      = pg_limit_runway--0.1.sql pg_limit_runway--0.2.sql pg_limit_runway--0.2.1.sql pg_limit_runway--0.1--0.2.sql pg_limit_runway--0.2--0.2.1.sql
PGFILEDESC = "pg_limit_runway - what will break next"
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
TESTDB ?= postgres
prove:
	pg_prove --dbname $(TESTDB) test/*.sql
lint:
	# The doc-facts checks, ported from pg_lock_tree's scripts/lint-docs.sh: the version agrees
	# across control and the newest release and the README header, every SQL file is installed
	# with no DATA duplicate, local doc paths resolve, and no em-dashes.
	./scripts/lint-docs.sh
	./scenarios/check-evidence.sh
	# Rejects a duplicated mapping key, which PyYAML accepts silently and Forgejo does not.
	# A workflow with one dispatches no jobs at all and its run reads as a plain failure.
	./scripts/check-workflows.sh
.PHONY: install prove lint
