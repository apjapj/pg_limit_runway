-- test/05_upgrade.sql: the update paths, which nothing else runs.
--
-- Every other test installs the default version from scratch, so no gate ever executes a
-- pg_limit_runway--X--Y.sql: the riskiest SQL in a release, the DROP FUNCTION / CREATE pairs and the
-- grants they take with them, ships unexercised. This installs 0.3.0, updates through the chain, and
-- asserts what the changelog promises: the findings function and the two readers that depend on it
-- come back with the new column, the Act stage appears, PUBLIC still has nothing, and a monitor
-- role's grant is gone until it is re-issued. The whole file runs in one transaction and rolls back.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
-- Create an old version rather than the released one, so this exercises the update path itself.
-- Drop first: a server may already carry the extension, and the CI scenario jobs install it before
-- pg_prove, so CREATE EXTENSION ... VERSION would otherwise refuse it as already existing. The drop
-- is inside the transaction and is rolled back with it, so a pre-installed 0.5.1 comes back.
DROP EXTENSION IF EXISTS pg_limit_runway;
CREATE EXTENSION pg_limit_runway VERSION '0.3.0';
\o
SELECT plan(10);

-- ---------------------------------------------------------------- before the update
SELECT hasnt_function('limit_runway_command', ARRAY['numeric'],
                      '0.3.0 has no limit_runway_command(), so the update has something to add');
SELECT hasnt_column('limit_runway', 'from_date',
                    '0.3.0 has no from_date, so the update is what adds the Act stage its bound');
\o /dev/null
CREATE ROLE lr_up;
GRANT SELECT ON limit_runway TO lr_up;
GRANT EXECUTE ON FUNCTION limit_runway_text(numeric, interval) TO lr_up;
\o

ALTER EXTENSION pg_limit_runway UPDATE;

-- ---------------------------------------------------------------- after the update
SELECT is((SELECT extversion FROM pg_extension WHERE extname = 'pg_limit_runway'), '0.5.1',
          'ALTER EXTENSION UPDATE reaches the version the control file declares');
SELECT has_column('limit_runway', 'from_date',
                  'the recreated view carries the new from_date column the Act stage needs');
SELECT has_function('limit_runway_command', ARRAY['numeric'],
                    'the Act stage exists after the update');
SELECT ok(NOT has_function_privilege('public', 'limit_runway_command(numeric)', 'EXECUTE'),
          'the new function is closed to PUBLIC after the update, like the readers');
SELECT ok(NOT has_function_privilege('public', 'limit_runway_findings(numeric,interval)', 'EXECUTE'),
          'the recreated findings function is still closed to PUBLIC: the update restates the REVOKE');
SELECT ok(NOT has_function_privilege('public', 'limit_runway_text(numeric,interval)', 'EXECUTE'),
          'the recreated text function is still closed to PUBLIC');
SELECT ok(NOT has_table_privilege('lr_up', 'limit_runway', 'SELECT'),
          'the DROP of the view took a monitor role''s grant with it, which is the re-grant the changelog warns about');
\o /dev/null
GRANT SELECT ON limit_runway TO lr_up;
GRANT EXECUTE ON FUNCTION limit_runway_command(numeric) TO lr_up;
\o
SELECT ok(has_table_privilege('lr_up', 'limit_runway', 'SELECT')
          AND has_function_privilege('lr_up', 'limit_runway_command(numeric)', 'EXECUTE'),
          'the re-issued grants stick, so the documented remedy works');

SELECT * FROM finish();
ROLLBACK;
