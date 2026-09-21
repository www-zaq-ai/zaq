-- PostgreSQL bootstrap. Connect to a maintenance DB as the DBA (psql -X -f).
-- Inputs: zaq_database, zaq_owner, zaq_reader psql variables;
-- ZAQ_OWNER_PASSWORD and ZAQ_READER_PASSWORD environment variables.
\set ON_ERROR_STOP on
\ir setup_database_begin.sql

\ir install_vector_extension.sql

\ir setup_database_finish.sql
