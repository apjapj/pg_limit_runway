# pg_limit_runway Makefile
EXTENSION = pg_limit_runway
DATA      = pg_limit_runway--0.1.sql pg_limit_runway--0.2.sql pg_limit_runway--0.2.1.sql pg_limit_runway--0.2.2.sql pg_limit_runway--0.3.0.sql pg_limit_runway--0.4.0.sql pg_limit_runway--0.4.1.sql pg_limit_runway--0.1--0.2.sql pg_limit_runway--0.2--0.2.1.sql pg_limit_runway--0.2.1--0.2.2.sql pg_limit_runway--0.2.2--0.3.0.sql pg_limit_runway--0.3.0--0.4.0.sql pg_limit_runway--0.4.0--0.4.1.sql pg_limit_runway--0.5.0.sql pg_limit_runway--0.4.1--0.5.0.sql pg_limit_runway--0.5.1.sql pg_limit_runway--0.5.0--0.5.1.sql
PGFILEDESC = "pg_limit_runway - what will break next"
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
TESTDB ?= postgres
PG ?= 18
prove:
	pg_prove --dbname $(TESTDB) test/*.sql

# The read-side overhead benchmark: one call to limit_runway_text() and limit_runway_findings(),
# beside a hand-written pg_sequences query, median of N calls over a stated fixture. It creates and
# drops its own sequences and needs superuser, so it passes --force itself.
bench-overhead:
	./scripts/bench-overhead.sh --force $(if $(SEQUENCES),--sequences=$(SEQUENCES),) $(if $(N),--repeat=$(N),) $(if $(KEEP),--keep,)
defects:
	# Re-inject every recorded defect (defects/) and require the test that caught it to fail
	# again; a defect the suite no longer catches is a regression and exits non-zero.
	./scripts/check-defects.sh $(PG)
check-examples:
	# Parse and plan the SQL in the documentation's fenced blocks, against a server with the
	# extension installed. Needs a database, so it is not part of lint.
	./scripts/check-examples.sh
lint:
	# Every database-free check, in one script. Not the recipe: the Makefile needs pgxs.mk to parse,
	# and scripts/lint.sh needs no PostgreSQL toolchain. Both CI copies call the script directly.
	./scripts/lint.sh
.PHONY: install prove defects check-examples lint bench-overhead
