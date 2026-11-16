"""Opt-in real TLS test: python3 test/integration/database_tls_test.py.

Requires Docker, the pgvector/pgvector:pg18 image, OpenSSL, psql 17+ and compiled
Mix dependencies. Owns one disposable container; never uses an existing database.
"""

import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[2]
CONTAINER = "zaq-tls-test-" + secrets.token_hex(5)
PASSWORDS = [secrets.token_urlsafe(24) + ":@/?#%" for _ in range(3)]


def run(args, env=None, expected=0, timeout=180):
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    output = result.stdout + result.stderr
    for password in PASSWORDS:
        if password in output or quote(password, safe="") in output:
            raise AssertionError("A command exposed an ephemeral credential")
    if (expected == 0 and result.returncode != 0) or (expected != 0 and result.returncode == 0):
        # URLs are never included in diagnostics, even if a dependency emits one.
        safe = "\n".join(line for line in output.splitlines() if "://" not in line)
        raise AssertionError(f"{args[0]} returned {result.returncode}, expected {expected}:\n{safe[-3000:]}")
    return output.strip()


def provision(env, *args, expected=0):
    return run(["sh", "scripts/docker_entrypoint.sh", "provision-db", "--automatic", *args], env, expected)


def probe(env, mode="connect", expected=0):
    return run(["mix", "run", "--no-start", "test/support/database_tls_probe.exs", mode], env, expected, 600)


def main(directory):
    path = Path(directory)
    # PostgreSQL's unprivileged container user must traverse the certificate mount.
    path.chmod(0o755)
    for name in ("ca", "untrusted"):
        run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
             "-subj", f"/CN=ZAQ ephemeral {name}", "-keyout", str(path / f"{name}.key"),
             "-out", str(path / f"{name}.crt")])
    run(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost",
         "-keyout", str(path / "server.key"), "-out", str(path / "server.csr")])
    (path / "server.ext").write_text("subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n")
    run(["openssl", "x509", "-req", "-in", str(path / "server.csr"), "-CA", str(path / "ca.crt"),
         "-CAkey", str(path / "ca.key"), "-CAcreateserial", "-days", "1",
         "-extfile", str(path / "server.ext"), "-out", str(path / "server.crt")])
    (path / "trusted ca.pem").write_bytes((path / "ca.crt").read_bytes())
    (path / "pg_hba.conf").write_text(
        "local all all trust\nhostnossl all all all reject\nhostssl all all all scram-sha-256\n")

    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("PG", "ZAQ_DATABASE", "ZAQ_OWNER", "ZAQ_READER"))
           and key not in ("DATABASE_URL", "MIX_ENV")}
    env.update(POSTGRES_PASSWORD=PASSWORDS[0])
    run(["docker", "run", "--detach", "--rm", "--name", CONTAINER,
         "--publish", "127.0.0.1::5432", "--env", "POSTGRES_PASSWORD",
         "--mount", f"type=bind,src={path},dst=/tls,readonly",
         "pgvector/pgvector:pg18", "sh", "-c",
         "cp /tls/server.key /var/lib/postgresql/server.key && "
         "chown postgres:postgres /var/lib/postgresql/server.key && "
         "chmod 600 /var/lib/postgresql/server.key && "
         "exec docker-entrypoint.sh postgres -c ssl=on "
         "-c ssl_cert_file=/tls/server.crt -c ssl_key_file=/var/lib/postgresql/server.key "
         "-c hba_file=/tls/pg_hba.conf"], env)
    port = run(["docker", "port", CONTAINER, "5432"]).rsplit(":", 1)[1]
    for _ in range(60):
        ready = subprocess.run(["docker", "exec", CONTAINER, "pg_isready", "-U", "postgres"], capture_output=True)
        if ready.returncode == 0:
            break
        time.sleep(0.5)
    else:
        raise AssertionError("Disposable PostgreSQL did not become ready")

    env.update(PGHOST="localhost", PGPORT=port, PGUSER="postgres", PGPASSWORD=PASSWORDS[0],
               PGDATABASE="postgres", PGSSLMODE="verify-full", PGSSLROOTCERT=str(path / "ca.crt"),
               ZAQ_DATABASE="zaq_tls", ZAQ_OWNER="tls_owner", ZAQ_OWNER_PASSWORD=PASSWORDS[1],
               ZAQ_READER="tls_reader", ZAQ_READER_PASSWORD=PASSWORDS[2], ZAQ_DATABASE_SSL="true",
               ZAQ_DATABASE_SSL_CA_CERT_FILE=str(path / "trusted ca.pem"),
               SECRET_KEY_BASE=secrets.token_hex(64), SYSTEM_CONFIG_ENCRYPTION_KEY=secrets.token_hex(32),
               ROLES="bo", PORT="0", PHX_SERVER="true", ERL_FLAGS="+S 2:2")
    provision(env)
    print("PASS automatic provisioning and TLS owner authentication")

    # Capture the generated URL internally, without command output/logging.
    url = subprocess.check_output(["python3", "scripts/database_url.py", "build"], cwd=ROOT, env=env, text=True).strip()
    app = dict(env, DATABASE_URL=url)
    probe(app)
    print("PASS generated URL, trusted CA and hostname")
    probe(dict(app, ZAQ_DATABASE_SSL="invalid"))
    print("PASS explicit URL precedence")
    probe(dict(app, PGSSLMODE="disable", PGSSLROOTCERT=str(path / "untrusted.crt")))
    print("PASS application TLS is independent of libpq environment settings")

    for label, changes in [
        ("TLS absent", {"DATABASE_URL": url.split("?")[0], "ZAQ_DATABASE_SSL_CA_CERT_FILE": ""}),
        ("TLS disabled", {"DATABASE_URL": url.replace("ssl=true", "ssl=false"), "ZAQ_DATABASE_SSL_CA_CERT_FILE": ""}),
        ("untrusted CA", {"ZAQ_DATABASE_SSL_CA_CERT_FILE": str(path / "untrusted.crt")}),
        ("system trust rejects private CA", {"ZAQ_DATABASE_SSL_CA_CERT_FILE": ""}),
        ("hostname mismatch", {"DATABASE_URL": url.replace("@localhost:", "@127.0.0.1:")}),
        ("missing CA", {"ZAQ_DATABASE_SSL_CA_CERT_FILE": str(path / "missing.crt")}),
    ]:
        probe(dict(app, **changes), expected=1)
        print("PASS rejects " + label)

    probe(app, "start")
    print("PASS real release migrations and application/BO startup over TLS")
    provision(env)
    print("PASS receipt/ledger validation on post-migration restart")
    for label, changes in [
        ("wrong owner password", {"DATABASE_URL": url.replace(quote(PASSWORDS[1], safe=""), "wrong")}),
        ("wrong owner identity", {"DATABASE_URL": url.replace("tls_owner:", "tls_reader:").replace(quote(PASSWORDS[1], safe=""), quote(PASSWORDS[2], safe=""))}),
        ("owner CA mismatch", {"ZAQ_DATABASE_SSL_CA_CERT_FILE": str(path / "untrusted.crt")}),
        ("owner hostname mismatch", {"DATABASE_URL": url.replace("@localhost:", "@127.0.0.1:")}),
    ]:
        provision(dict(app, **changes), expected=1)
        print("PASS owner validation rejects " + label)

    adoption = dict(env, ZAQ_DATABASE="zaq_tls_adopt", ZAQ_OWNER="tls_adopt_owner", ZAQ_READER="tls_adopt_reader")
    run(["sh", "scripts/docker_entrypoint.sh", "provision-db"], adoption)
    adoption_url = subprocess.check_output(
        ["python3", "scripts/database_url.py", "build"], cwd=ROOT, env=adoption, text=True).strip()
    adoption["DATABASE_URL"] = adoption_url
    probe(adoption, "migrate")
    provision(adoption, expected=1)
    print("PASS automatic provisioning refuses a migrated database without a receipt")

    bad_adoption = dict(adoption, DATABASE_URL=adoption_url.replace(quote(PASSWORDS[1], safe=""), "wrong"))
    run(["sh", "scripts/docker_entrypoint.sh", "adopt-existing-db"], bad_adoption, expected=1)
    receipt = run(["psql", "-XwqAt", "-c",
                   "SELECT EXISTS (SELECT FROM pg_namespace WHERE nspname='zaq_bootstrap')"],
                  dict(adoption, PGDATABASE="zaq_tls_adopt"))
    assert receipt == "f", "Failed owner authentication wrote an adoption receipt"
    run(["sh", "scripts/docker_entrypoint.sh", "adopt-existing-db"], adoption)
    provision(adoption)
    print("PASS TLS adoption authenticates before receipt and supports validation-only restart")


if __name__ == "__main__":
    try:
        with tempfile.TemporaryDirectory(prefix="zaq-database-tls-") as directory:
            try:
                main(directory)
            finally:
                subprocess.run(["docker", "rm", "--force", CONTAINER], capture_output=True)
    except (AssertionError, subprocess.TimeoutExpired) as error:
        print(str(error))
        raise SystemExit(1) from None
