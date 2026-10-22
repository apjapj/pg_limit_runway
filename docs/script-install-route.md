# The script install route: design

**Status: design, no generated scripts yet.** This is the pilot for the alternative route on
`pg_limit_runway`. The normal `CREATE EXTENSION` path stays the default; this route is for a server
where the extension files cannot be installed or `CREATE EXTENSION` is not available.

## What the route is

Three generated psql scripts at the repository root:

```
install.sql       install the current version into a chosen schema
uninstall.sql     remove every object the route created
migrate.sql       apply the cumulative update path from a recorded version to current
```

They are generated from the extension's own release and update scripts by
`scripts/generate-script-route.sh`. They are shipped in the public repository, so a reader can
download the tag and run them without `make install` or a control file.

They are **not** a replacement for `CREATE EXTENSION`, and they are not tested as one. The
extension install stays the documented default.

## Generation

The generator:

1. Reads `pg_limit_runway.control` for the default version.
2. Reads the matching `pg_limit_runway--<version>.sql`.
3. Removes the `\echo Use "CREATE EXTENSION ..." \quit` guard.
4. Replaces `@extschema@` with the psql identifier variable `:"schema"` and prepends
   `\set schema` documentation plus `CREATE SCHEMA IF NOT EXISTS :"schema";`.
5. Removes `pg_extension_config_dump(...)`, which requires extension membership.
6. Adds the route's marker table and version row.
7. Writes `uninstall.sql` from a reviewed object list, in dependency order, and `migrate.sql` from
   the ordered update scripts.

The generated files are committed and diffed in CI; a release script change without regenerating
them fails the build.

## Schema and marker

The route installs into one schema named by `-v schema=...`, default `public`. It creates:

```sql
CREATE TABLE IF NOT EXISTS :"schema".limit_runway_script_install (
    version      text PRIMARY KEY,
    installed_at timestamptz NOT NULL DEFAULT now(),
    route        text NOT NULL DEFAULT 'script'
);
```

This table is the only object the route adds that `CREATE EXTENSION` does not. It records the
version `migrate.sql` starts from. It is dropped by `uninstall.sql`.

## Install rules

- Refuse if `pg_extension` has a `pg_limit_runway` row. The two routes must not be mixed.
- Refuse if the marker table already exists, with a clear message to use `migrate.sql`.
- Create the schema if needed, but never drop it on uninstall.
- Run the release SQL with `search_path` set to the target schema and `check_function_bodies = off`,
  as the release file already requires.
- Insert the version row only after every object is created, in the same transaction.

## Uninstall rules

- Refuse if `pg_extension` has a row; that is an extension install, use `DROP EXTENSION`.
- Drop the view, functions, tables and sequences in dependency order with `IF EXISTS`.
- No `CASCADE`. A user object that depends on the view must block the drop, exactly as
  `DROP EXTENSION` would.
- Drop the marker table last.
- Do not drop the schema.

## Migration rules

- Read the marker version. Refuse if it is missing, or if it is not a version this file knows.
- Apply the update scripts from that version to current, in order. A current install is a no-op.
- Update the marker row in the same transaction as the last step.
- A migration that drops and recreates a function loses grants, exactly as the extension update
  path does. The script prints the re-grant statements and refuses to run silently past them.

## Tests per major, 14 to 19rc1

For each major:

1. Run `install.sql` into `public`; assert the version marker, the view answers, and one writer path
   (`limit_runway_sample()` writes a row).
2. Run `uninstall.sql`; assert no survivors, including the marker and history table; assert the
   schema remains.
3. Install the oldest supported version, then run `migrate.sql`; assert the current view shape and
   that the history rows survive.
4. Run `install.sql` twice; the second must refuse with the marker message.
5. Run `uninstall.sql` after `CREATE EXTENSION`; it must refuse.
6. Run the whole sequence with a non-superuser database owner and check the documented grants.

## Known differences from `CREATE EXTENSION`

- `pg_extension` has no row. `ALTER EXTENSION ... UPDATE`, `pg_available_extensions`, the
  extension-update checks and `pg_extension_config_dump` do not apply.
- The history table is an ordinary table, so `pg_dump` includes it by default; it is not registered
  as extension configuration.
- `uninstall.sql` is the only uninstall path. `DROP EXTENSION` is not available.
- The script route must not be mixed with the extension route in one database.

## Open questions before code

1. Does the route install into `public` only, or accept any schema? The design supports any schema,
   but `@extschema@` inside string literals needs a generator test.
2. Is `migrate.sql` cumulative from the oldest version only, or should one file accept a
   `-v from_version=` and skip steps? The former is smaller; the latter is friendlier.
3. Should the generated scripts be at the repository root or in `scripts/sql/`? Root is more
   discoverable; `scripts/sql/` keeps shell and SQL apart.
4. Do we accept the extra marker table as the route's identity, or store the version in a comment on
   the view? A table is honest and survives; a comment is easier to lose.
