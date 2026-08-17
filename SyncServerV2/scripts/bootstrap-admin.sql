-- Runs only in the dedicated bootstrap-admin one-shot container.
-- The official PostgreSQL OID-10 role is never used by the migrator or server.
-- Validation and role creation are one transaction under the same advisory
-- lock. Any non-fresh target aborts before CREATE ROLE and leaves no catalog
-- change behind.
\set ON_ERROR_STOP on
BEGIN;
SELECT pg_advisory_xact_lock(1179995465, 1313429313);

DO $bootstrap_guard$
DECLARE
    catalog_row record;
    unknown_catalog_objects bigint;
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
          AND datacl IS NULL
          AND NOT datistemplate
          AND datallowconn
          AND datconnlimit = -1
    ) THEN
        RAISE EXCEPTION 'bootstrap-admin initialization authority does not own the target database';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_namespace
        WHERE nspname = 'public'
          AND nspowner = (SELECT oid FROM pg_roles WHERE rolname = 'pg_database_owner')
          AND nspacl::text = '{pg_database_owner=UC/pg_database_owner,=U/pg_database_owner}'
    ) THEN
        RAISE EXCEPTION 'bootstrap-admin public schema baseline is not fresh';
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

    -- PostgreSQL allocates every operator-created role at or above
    -- FirstNormalObjectId. The official init authority is OID 10, while all
    -- predefined roles remain below this boundary. A role-only legacy or test
    -- cluster is therefore not a fresh provisioning target.
    IF EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE oid >= 16384
    ) THEN
        RAISE EXCEPTION 'bootstrap-admin found an unknown user role';
    END IF;

    IF (SELECT count(*) FROM pg_auth_members) <> 3 OR EXISTS (
        SELECT 1
        FROM pg_auth_members membership
        JOIN pg_roles granted_role ON granted_role.oid = membership.roleid
        JOIN pg_roles member_role ON member_role.oid = membership.member
        JOIN pg_roles grantor_role ON grantor_role.oid = membership.grantor
        WHERE member_role.rolname <> 'pg_monitor'
           OR granted_role.rolname NOT IN (
               'pg_read_all_settings',
               'pg_read_all_stats',
               'pg_stat_scan_tables'
           )
           OR grantor_role.rolname <> current_user
           OR membership.admin_option
           OR NOT membership.inherit_option
           OR NOT membership.set_option
    ) THEN
        RAISE EXCEPTION 'bootstrap-admin role membership baseline is not fresh';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_db_role_setting
    ) THEN
        RAISE EXCEPTION 'bootstrap-admin database or role settings are not fresh';
    END IF;

    -- Scan every PostgreSQL catalog table that has an OID, rather than
    -- maintaining an incomplete hand-written list of user-creatable object
    -- kinds. pg_database is checked above and pg_authid is represented by the
    -- pg_roles check above; every other high-OID row is operator-created.
    FOR catalog_row IN
        SELECT catalog.oid::regclass AS relation
        FROM pg_class catalog
        JOIN pg_namespace namespace ON namespace.oid = catalog.relnamespace
        WHERE namespace.nspname = 'pg_catalog'
          AND catalog.relkind = 'r'
          AND catalog.relname NOT IN ('pg_database', 'pg_authid')
          AND EXISTS (
              SELECT 1
              FROM pg_attribute attribute
              WHERE attribute.attrelid = catalog.oid
                AND attribute.attname = 'oid'
                AND attribute.attnum > 0
                AND NOT attribute.attisdropped
          )
        ORDER BY catalog.relname
    LOOP
        EXECUTE format(
            'SELECT count(*) FROM %s WHERE oid >= 16384',
            catalog_row.relation
        ) INTO unknown_catalog_objects;
        IF unknown_catalog_objects <> 0 THEN
            RAISE EXCEPTION 'bootstrap-admin found an unknown user catalog object';
        END IF;
    END LOOP;

    -- These mutable catalogs have no OID of their own. Parent objects are
    -- covered by the scan above; the remaining standalone state must match an
    -- untouched freshly-created database.
    IF EXISTS (SELECT 1 FROM pg_replication_origin)
       OR EXISTS (SELECT 1 FROM pg_seclabel)
       OR EXISTS (
           SELECT 1
           FROM pg_shseclabel
           WHERE classoid = 'pg_database'::regclass
             AND objoid = (SELECT oid FROM pg_database WHERE datname = current_database())
       ) OR (SELECT count(*) FROM pg_description
             WHERE classoid = 'pg_namespace'::regclass
               AND objoid = (SELECT oid FROM pg_namespace WHERE nspname = 'public')) <> 1
       OR EXISTS (
           SELECT 1
           FROM pg_description
           WHERE classoid = 'pg_namespace'::regclass
             AND objoid = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
             AND (objsubid <> 0 OR description <> 'standard public schema')
       ) OR EXISTS (
           SELECT 1
           FROM pg_shdescription
           WHERE classoid = 'pg_database'::regclass
             AND objoid = (SELECT oid FROM pg_database WHERE datname = current_database())
       ) THEN
        RAISE EXCEPTION 'bootstrap-admin found unknown non-OID catalog state';
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
