-- Runs only in the dedicated bootstrap-admin one-shot container.
-- The official PostgreSQL OID-10 role is never used by the migrator or server.
SELECT pg_advisory_lock(1179995465, 1313429313);

SELECT format(
    'CREATE ROLE fuminiwa_sync_v2_bootstrap_admin LOGIN SUPERUSER CREATEDB CREATEROLE INHERIT REPLICATION BYPASSRLS PASSWORD %L',
    :'bootstrap_admin_password'
)
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'fuminiwa_sync_v2_bootstrap_admin'
)
\gexec

SELECT pg_advisory_unlock(1179995465, 1313429313);
