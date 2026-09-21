-- ParadeDB bootstrap. Same inputs/security contract as PostgreSQL bootstrap.
\set ON_ERROR_STOP on
\ir setup_database_begin.sql

\ir install_vector_extension.sql
\ir install_pg_search_extension.sql

\ir setup_database_finish.sql
