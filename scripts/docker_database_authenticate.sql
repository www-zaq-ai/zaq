-- Authenticate DATABASE_URL without putting its password in argv or SQL text.
\set ECHO none
\getenv owner_connection ZAQ_OWNER_DATABASE_URL
SELECT oid AS expected_oid FROM pg_database WHERE datname = :'zaq_database' \gset
SELECT coalesce(inet_server_addr()::text, '') AS expected_address,
       coalesce(inet_server_port(), 0) AS expected_port \gset
\connect -reuse-previous=off :"owner_connection"
SELECT current_user = :'zaq_owner' AND current_database() = :'zaq_database'
  AND (SELECT oid FROM pg_database WHERE datname = current_database()) = :expected_oid
  AND coalesce(inet_server_addr()::text, '') = :'expected_address'
  AND coalesce(inet_server_port(), 0) = :expected_port AS correct_target \gset
\if :correct_target
\else
  DO $$ BEGIN RAISE EXCEPTION 'DATABASE_URL does not address the provisioned owner/database/server'; END $$;
\endif
