-- Runs only in the dedicated bootstrap-admin one-shot container.
-- The official PostgreSQL OID-10 role is never used by the migrator or server.
-- Validation and role creation are one transaction under the same advisory
-- lock. Any non-fresh target aborts before CREATE ROLE and leaves no catalog
-- change behind.
\set ON_ERROR_STOP on
BEGIN;
SELECT pg_advisory_xact_lock(1179995465, 1313429313);

DO $bootstrap_guard$
BEGIN
    IF current_database() <> 'fuminiwa_sync_v2' THEN
        RAISE EXCEPTION 'bootstrap-admin target database is not the fixed v2 database';
    END IF;

    IF current_user <> 'fuminiwa_sync_v2_postgres_init'
       OR current_setting('is_superuser') <> 'on'
       OR NOT EXISTS (
           SELECT 1
           FROM pg_roles
           WHERE rolname = current_user
             AND oid = 10
             AND rolsuper
             AND rolcreaterole
             AND rolcreatedb
             AND rolcanlogin
             AND rolinherit
             AND rolreplication
             AND rolbypassrls
       ) THEN
        RAISE EXCEPTION 'bootstrap-admin requires the exact official PostgreSQL initialization authority';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_database
        WHERE datname = current_database()
          AND datdba = (SELECT oid FROM pg_roles WHERE rolname = current_user)
    ) THEN
        RAISE EXCEPTION 'bootstrap-admin initialization authority does not own the target database';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname IN (
            'fuminiwa_sync_v2_bootstrap_admin',
            'fuminiwa_sync_v2_bootstrap',
            'fuminiwa_sync_v2_migrator',
            'fuminiwa_sync_v2_runtime'
        )
    ) THEN
        RAISE EXCEPTION 'bootstrap-admin found a pre-existing v2 role';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_namespace
        WHERE nspname NOT IN ('pg_catalog', 'information_schema', 'public')
          AND nspname NOT LIKE 'pg_toast%'
          AND nspname NOT LIKE 'pg_temp_%'
          AND nspname NOT LIKE 'pg_toast_temp_%'
    ) OR EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname NOT LIKE 'pg_toast%'
          AND n.nspname NOT LIKE 'pg_temp_%'
          AND n.nspname NOT LIKE 'pg_toast_temp_%'
          AND c.relpersistence <> 't'
    ) OR EXISTS (
        SELECT 1
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname NOT LIKE 'pg_toast%'
          AND n.nspname NOT LIKE 'pg_temp_%'
          AND n.nspname NOT LIKE 'pg_toast_temp_%'
          AND t.typelem = 0
          AND t.typtype IN ('c', 'd', 'e', 'r')
    ) OR EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname NOT LIKE 'pg_toast%'
          AND n.nspname NOT LIKE 'pg_temp_%'
          AND n.nspname NOT LIKE 'pg_toast_temp_%'
    ) OR EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname <> 'plpgsql'
    ) THEN
        RAISE EXCEPTION 'bootstrap-admin target database is not fresh';
    END IF;
END
$bootstrap_guard$;

SELECT format(
    'CREATE ROLE fuminiwa_sync_v2_bootstrap_admin LOGIN SUPERUSER CREATEDB CREATEROLE INHERIT REPLICATION BYPASSRLS PASSWORD %L',
    :'bootstrap_admin_password'
)
\gexec

COMMIT;
