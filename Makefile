# pg_limit_runway Makefile
EXTENSION = pg_limit_runway
DATA      = pg_limit_runway--0.1.sql
PGFILEDESC = "pg_limit_runway - what will break next"
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
TESTDB ?= postgres
prove:
	pg_prove --dbname $(TESTDB) test/*.sql
lint:
	./scenarios/check-evidence.sh
.PHONY: install prove lint
