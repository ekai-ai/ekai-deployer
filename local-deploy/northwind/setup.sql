-- Creates the sample role and an empty, isolated database on ekai-postgres.
-- Run as the ekai superuser against the maintenance database, passing
-- -v db=<name> -v usr=<role> -v pw=<password> (see load.sh). Statements must
-- run one at a time, not in one transaction (DROP DATABASE).
-- Re-running resets the database completely, including any dbt marts schemas.

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION', :'usr', :'pw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'usr') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'usr', :'pw') \gexec

SELECT format('DROP DATABASE IF EXISTS %I WITH (FORCE)', :'db') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'usr') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db') \gexec

-- Postgres grants CONNECT to everyone by default; without this the sample
-- user could open ekai's own application database.
REVOKE CONNECT ON DATABASE ekaibackend FROM PUBLIC;
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
