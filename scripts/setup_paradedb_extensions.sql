-- ParadeDB bootstrap. Same inputs/security contract as PostgreSQL bootstrap.
\set ON_ERROR_STOP on
\ir setup_database_begin.sql

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_search;
SELECT 1 FROM paradedb.version_info();

\ir setup_database_finish.sql
