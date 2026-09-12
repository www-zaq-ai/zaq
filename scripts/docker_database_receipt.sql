-- Optional Compose receipt, inside the canonical bootstrap transaction.
-- Created AFTER ACL setup; revoke the default grants that setup intentionally adds.
CREATE SCHEMA zaq_bootstrap;
REVOKE ALL ON SCHEMA zaq_bootstrap FROM PUBLIC;
SELECT format('REVOKE ALL ON SCHEMA zaq_bootstrap FROM %I, %I', :'zaq_owner', :'zaq_reader') \gexec
CREATE TABLE zaq_bootstrap.receipt (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  version integer NOT NULL,
  database_name text NOT NULL,
  owner_name text NOT NULL,
  reader_name text NOT NULL,
  engine text NOT NULL
);
REVOKE ALL ON zaq_bootstrap.receipt FROM PUBLIC;
SELECT format('REVOKE ALL ON zaq_bootstrap.receipt FROM %I, %I', :'zaq_owner', :'zaq_reader') \gexec
INSERT INTO zaq_bootstrap.receipt
VALUES (true, 1, current_database(), :'zaq_owner', :'zaq_reader', :'zaq_bootstrap_engine');
