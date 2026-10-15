-- test/04_command.sql: the Act stage (0.4, docs/act.md and docs/command.md).
--
-- Written before limit_runway_command() exists, so it fails loudly until the function lands. It asserts
-- the tier and the statement for one finding of each limit kind, and the contract that makes the two
-- columns a command list rather than prose: every row carries a statement and a note, the statement is
-- one runnable line, and a finding the view reports as needing action is exactly what appears here.
--
-- Two layers, deliberately. The public limit_runway_command() is asserted against real fixtures built
-- here, which is what proves the finding and the statement agree end to end. The internal per-row
-- derivation, limit_runway_command_row(), is asserted with one synthetic finding per kind so that the
-- kinds a single pgTAP transaction cannot build - an xid age (needs ~200M xids burned with commits, as
-- scenarios s5/s6 do), a MultiXact age, a lost replication slot - are still pinned, tier and statement.
-- The whole file runs in one transaction and is rolled back.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pg_limit_runway;
\o
SELECT plan(43);

-- ---------------------------------------------------------------- the objects
SELECT has_function('limit_runway_command', ARRAY['numeric'], 'limit_runway_command(numeric) exists');
SELECT has_function('limit_runway_command_row', ARRAY['integer', 'text', 'text', 'timestamp with time zone', 'timestamp with time zone', 'numeric'],
                    'limit_runway_command_row(...) exists, the per-row derivation');
SELECT ok(NOT has_function_privilege('public', 'limit_runway_command(numeric)', 'EXECUTE'),
          'the command list is not executable by PUBLIC, like the readers');
SELECT ok(NOT has_function_privilege('public',
            'limit_runway_command_row(integer,text,text,timestamptz,timestamptz,numeric)', 'EXECUTE'),
          'the internal derivation is closed to PUBLIC too');

-- ---------------------------------------------------------------- fixtures, the kinds a transaction can build
-- A sequence a column fills, standing past the column's maximum; one no column owns, at its own end; a
-- foreign key whose int4 child cannot hold the parent's next bigint; a partition whose last bound is
-- past; three password dates landing on the three tiers.
\o /dev/null
CREATE SCHEMA lr_c;
CREATE SEQUENCE lr_c.past_seq AS bigint;
CREATE TABLE lr_c.past (id int4 PRIMARY KEY DEFAULT nextval('lr_c.past_seq'));
ALTER SEQUENCE lr_c.past_seq OWNED BY lr_c.past.id;
SELECT setval('lr_c.past_seq', 2147483648);
CREATE SEQUENCE lr_c.solo AS int MAXVALUE 100;
SELECT setval('lr_c.solo', 100);
CREATE TABLE lr_c.parent (id bigint PRIMARY KEY);
CREATE SEQUENCE lr_c.parent_seq AS bigint OWNED BY lr_c.parent.id;
CREATE TABLE lr_c.child (parent_id int4 REFERENCES lr_c.parent(id));
SELECT setval('lr_c.parent_seq', 3000000000);
CREATE TABLE lr_c.events (at timestamptz NOT NULL) PARTITION BY RANGE (at);
CREATE TABLE lr_c.events_202602 PARTITION OF lr_c.events FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE ROLE lr_c_expired LOGIN VALID UNTIL '2000-01-01';
SELECT format('CREATE ROLE lr_c_soon LOGIN VALID UNTIL %L', now() + interval '3 days') \gexec
SELECT format('CREATE ROLE lr_c_plan LOGIN VALID UNTIL %L', now() + interval '20 days') \gexec
-- The finding carries its object already quoted (findings builds it with %I), so the command must
-- quote each name exactly once: a second %I would produce """Mixed""". A name with a space and a
-- mixed-case table pin that, for a column-filled sequence, a foreign key and a partition.
CREATE SCHEMA "lr C";
CREATE SEQUENCE "lr C"."past seq" AS bigint;
CREATE TABLE "lr C"."Mixed Table" (id int4 PRIMARY KEY DEFAULT nextval('"lr C"."past seq"'));
ALTER SEQUENCE "lr C"."past seq" OWNED BY "lr C"."Mixed Table".id;
SELECT setval('"lr C"."past seq"', 2147483648);
CREATE TABLE "lr C"."Parent Tbl" (id bigint PRIMARY KEY);
CREATE SEQUENCE "lr C"."parent seq" AS bigint OWNED BY "lr C"."Parent Tbl".id;
CREATE TABLE "lr C"."Child Tbl" ("parent id" int4 REFERENCES "lr C"."Parent Tbl"(id));
SELECT setval('"lr C"."parent seq"', 3000000000);
CREATE TABLE "lr C"."Events Tbl" (at timestamptz NOT NULL) PARTITION BY RANGE (at);
CREATE TABLE "lr C"."Events Tbl 202602" PARTITION OF "lr C"."Events Tbl" FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
\o

-- ---------------------------------------------------------------- one synthetic finding per kind: tier and statement
-- The signature is (rank_class, kind, object, until_date, from_date, used_fraction); a rank_class the
-- urgency ladder reads, so the tiers below are the ladder's, not a separate table of expectations.
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(1, 'sequence', 'lr_c.past.id', NULL, NULL, NULL)),
          'act | ALTER TABLE lr_c.past ALTER COLUMN id TYPE bigint;',
          'a sequence a column fills is act, and the fix is to widen the column');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(1, 'sequence', 'lr_c.solo', NULL, NULL, NULL)),
          'act | ALTER SEQUENCE lr_c.solo AS bigint;',
          'a sequence no column owns is act, and the fix is to raise the sequence''s own ceiling');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(1, 'sequence', '"lr C"."Mixed Table".id', NULL, NULL, NULL)),
          'act | ALTER TABLE "lr C"."Mixed Table" ALTER COLUMN id TYPE bigint;',
          'an object the finder already quoted is quoted once, not twice: the derivation unquotes it first');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(1, 'sequence', '"lr D"."a.b".id', NULL, NULL, NULL)),
          'act | ALTER TABLE "lr D"."a.b" ALTER COLUMN id TYPE bigint;',
          'a dot inside a quoted name is not a separator: parse_ident keeps "a.b" as one identifier');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(1, 'foreign key', 'lr_c.child.parent_id', NULL, NULL, NULL)),
          'act | ALTER TABLE lr_c.child ALTER COLUMN parent_id TYPE bigint;',
          'a foreign key past its width is act, and the fix is to widen the child column');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(3, 'xid', 'lr_c.big', NULL, NULL, NULL)),
          'plan | VACUUM (FREEZE) lr_c.big;',
          'an xid age per table is plan, and the fix is to freeze that table');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(3, 'xid', 'database lrdev', NULL, NULL, NULL)),
          'plan | VACUUM (FREEZE);',
          'an xid age per database is plan, and the fix is to freeze every table in it');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(3, 'multixact', 'database lrdev', NULL, NULL, NULL)),
          'plan | VACUUM (FREEZE);',
          'a MultiXact age per database gets the same statement as xid');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(1, 'replication slot', 'standby_a', NULL, NULL, NULL)),
          'act | SELECT pg_drop_replication_slot(''standby_a'');',
          'an invalidated slot is act, and the fix is to drop the slot');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(4, 'connections', 'server', NULL, NULL, 0.1)),
          'plan | SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type = ''client backend'' AND state = ''idle'' AND pid <> pg_backend_pid();',
          'connection headroom low is plan, and the fix frees idle client connections only');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(4, 'connections', 'server', NULL, NULL, 0.9)),
          'act | SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type = ''client backend'' AND state = ''idle'' AND pid <> pg_backend_pid();',
          'connection headroom nearly gone is act, the same statement, tiered by the share used');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(1, 'password', 'role lr_c_expired', NULL, NULL, NULL)),
          'act | ' || format('ALTER ROLE %s VALID UNTIL %L;', 'lr_c_expired', now() + interval '1 year'),
          'an expired password is act, and the fix sets a new date and never a password');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(2, 'password', 'role lr_c_soon', now() + interval '3 days', NULL, NULL)),
          'schedule | ' || format('ALTER ROLE %s VALID UNTIL %L;', 'lr_c_soon', now() + interval '1 year'),
          'a password under 7 days out is schedule, the same statement');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(2, 'password', 'role lr_c_plan', now() + interval '20 days', NULL, NULL)),
          'plan | ' || format('ALTER ROLE %s VALID UNTIL %L;', 'lr_c_plan', now() + interval '1 year'),
          'a password inside the window but over 7 days out is plan, the same statement');
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(2, 'password', 'role lr_c_soon', now() + interval '12 hours', NULL, NULL)),
          'act | ' || format('ALTER ROLE %s VALID UNTIL %L;', 'lr_c_soon', now() + interval '1 year'),
          'a password under a day out is act: the tier is the ladder, not the kind');

-- ---------------------------------------------------------------- the partition, whose width comes from from_date
-- The finding carries both bounds, so the next partition is complete: FROM the last upper bound, TO that
-- plus the last partition's width, in the parent's schema.
SELECT is((SELECT tier || ' | ' || command
             FROM limit_runway_command_row(1, 'partition', 'public.events',
                                           '2026-03-01'::timestamptz, '2026-02-01'::timestamptz, NULL)),
          'act | ' || format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L);',
                             'public', 'events_20260301', 'public', 'events',
                             '2026-03-01'::timestamptz, '2026-03-29'::timestamptz),
          'a reached partition is act, and the statement creates the next one at the last width');
SELECT is((SELECT count(*)::int FROM limit_runway_command_row(1, 'partition', 'public.events',
                                                              '2026-03-01'::timestamptz, NULL, NULL)),
          0, 'a partition whose lower bound the finding does not carry produces no row, not a placeholder');

-- ---------------------------------------------------------------- the contract the columns must keep
SELECT is((SELECT count(*)::int FROM limit_runway_command(0) WHERE note IS NULL OR btrim(note) = ''),
          0, 'every row carries a note: the cost is in the row, not left to the reader');
SELECT is((SELECT count(*)::int FROM limit_runway_command(0)
            WHERE command IS NULL OR btrim(command) = '' OR right(btrim(command), 1) <> ';'),
          0, 'every row is one non-empty statement, terminated');
SELECT is((SELECT count(*)::int FROM limit_runway_command(0) WHERE tier NOT IN ('plan', 'schedule', 'act')),
          0, 'every tier is one of the three the contract names');
SELECT is((SELECT count(*)::int FROM limit_runway_command(0) c
             JOIN limit_runway_findings(0) f ON f.kind = c.kind AND f.object = c.object
            WHERE f.state = 'not established'),
          0, 'no not-established finding is returned: a gap is not something to act on');
SELECT is((SELECT count(*)::int FROM limit_runway_command(0)),
          (SELECT count(*)::int FROM limit_runway_findings(0)
            WHERE state <> 'not established' AND NOT (kind = 'partition' AND from_date IS NULL)),
          'the command list is exactly the findings that need action, so the two cannot drift');
SELECT is((SELECT count(*)::int FROM limit_runway_command(0.5)),
          (SELECT count(*)::int FROM limit_runway_findings(0.5)
            WHERE state <> 'not established' AND NOT (kind = 'partition' AND from_date IS NULL)),
          'the same holds at the 0.5 default, which is not the same set as min_used 0');
SELECT is((SELECT array_agg(object)::text FROM limit_runway_command(0)),
          (SELECT array_agg(object)::text FROM (SELECT object FROM limit_runway_findings(0)
              WHERE state <> 'not established' AND NOT (kind = 'partition' AND from_date IS NULL)
              ORDER BY rank_class, until_date NULLS LAST, used_fraction DESC NULLS LAST, object) f),
          'the command list carries the findings order, not an arbitrary one');
SELECT is((SELECT note FROM limit_runway_command(0) WHERE object = 'lr_c.events'),
          'creates the next partition, its width the same as the last one''s; inserts for that range fail, or land in the DEFAULT, until it exists',
          'the note states the cost, so the least destructive is not sold as free');
SELECT is((SELECT count(*)::int FROM limit_runway_command()),
          (SELECT count(*)::int FROM limit_runway_command(0.5)),
          'the default argument is the min_used the readers use');

-- ---------------------------------------------------------------- the public function against real fixtures
SELECT is((SELECT tier || ' | ' || command FROM limit_runway_command(0) WHERE object = 'lr_c.past.id'),
          'act | ALTER TABLE lr_c.past ALTER COLUMN id TYPE bigint;',
          'the finding for a column-filled sequence builds the widen statement');
SELECT is((SELECT tier || ' | ' || command FROM limit_runway_command(0) WHERE object = 'lr_c.solo'),
          'act | ALTER SEQUENCE lr_c.solo AS bigint;',
          'the finding for a standalone sequence builds the sequence statement');
SELECT is((SELECT tier || ' | ' || command FROM limit_runway_command(0) WHERE object = 'lr_c.child.parent_id'),
          'act | ALTER TABLE lr_c.child ALTER COLUMN parent_id TYPE bigint;',
          'the finding for a narrow foreign key builds the child-column statement');
SELECT is((SELECT tier || ' | ' || command FROM limit_runway_command(0) WHERE object = '"lr C"."Mixed Table".id'),
          'act | ALTER TABLE "lr C"."Mixed Table" ALTER COLUMN id TYPE bigint;',
          'a real quoted column-filled sequence builds a statement that names the real table once');
SELECT is((SELECT tier || ' | ' || command FROM limit_runway_command(0) WHERE object = '"lr C"."Child Tbl"."parent id"'),
          'act | ALTER TABLE "lr C"."Child Tbl" ALTER COLUMN "parent id" TYPE bigint;',
          'a real quoted foreign-key column is quoted once, so the statement runs');
SELECT is((SELECT tier || ' | ' || command FROM limit_runway_command(0) WHERE object = '"lr C"."Events Tbl"'),
          'act | ' || format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L);',
                             'lr C', 'Events Tbl_20260301', 'lr C', 'Events Tbl',
                             '2026-03-01'::timestamptz, '2026-03-29'::timestamptz),
          'a real quoted partition builds a partition whose name is one quoted identifier, suffix included');
SELECT is((SELECT from_date FROM limit_runway_findings(0) WHERE object = 'lr_c.events'),
          '2026-02-01'::timestamptz,
          'the partition finding carries the last partition''s lower bound');
SELECT is((SELECT tier || ' | ' || command FROM limit_runway_command(0) WHERE object = 'lr_c.events'),
          'act | ' || format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L);',
                             'lr_c', 'events_20260301', 'lr_c', 'events',
                             '2026-03-01'::timestamptz, '2026-03-29'::timestamptz),
          'the real partition finding builds the next partition at the exact width');
SELECT is((SELECT tier FROM limit_runway_command(0) WHERE object = 'role lr_c_soon'),
          'schedule', 'a real password 3 days out is schedule');
SELECT is((SELECT tier FROM limit_runway_command(0) WHERE object = 'role lr_c_plan'),
          'plan', 'a real password 20 days out is plan');
SELECT is((SELECT tier FROM limit_runway_command(0) WHERE object = 'role lr_c_expired'),
          'act', 'a real expired password is act');
SELECT is((SELECT command FROM limit_runway_command(0) WHERE kind = 'connections' AND object = 'server'),
          'SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type = ''client backend'' AND state = ''idle'' AND pid <> pg_backend_pid();',
          'the real server connection finding builds the same fixed statement');
SELECT is((SELECT tier || ' | ' || command FROM limit_runway_command(0) WHERE object = 'lr_c.solo'),
          (SELECT tier || ' | ' || command
             FROM limit_runway_command_row(1, 'sequence', 'lr_c.solo', NULL, NULL, NULL)),
          'the wrapper returns exactly what the per-row derivation builds for the same finding');

SELECT * FROM finish();
ROLLBACK;
