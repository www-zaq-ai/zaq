"""Container connection URLs. Stdout is captured by the shell, never logged."""

import os
import sys
from urllib.parse import parse_qsl, quote, urlencode, urlsplit, urlunsplit


class ConfigurationError(ValueError):
    """A fixed diagnostic containing no environment values."""


def build_url(env):
    ssl = env.get("ZAQ_DATABASE_SSL", "")
    if ssl not in ("", "true", "false"):
        raise ConfigurationError("ZAQ_DATABASE_SSL must be true or false.")
    user = quote(env.get("ZAQ_OWNER", "zaq_owner"), safe="")
    password = quote(env["ZAQ_OWNER_PASSWORD"], safe="")
    database = quote(env.get("ZAQ_DATABASE", "zaq_prod"), safe="")
    host = env["PGHOST"]
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    port = env.get("PGPORT", "5432")
    query = f"?ssl={ssl}" if ssl else ""
    return f"postgresql://{user}:{password}@{host}:{port}/{database}{query}"


def libpq_url(env):
    url = urlsplit(env["DATABASE_URL"])
    if url.scheme not in ("ecto", "postgres", "postgresql") or not url.hostname:
        raise ConfigurationError("DATABASE_URL must be an owner PostgreSQL URL.")

    query = parse_qsl(url.query, keep_blank_values=True)
    tls = [value for key, value in query if key == "ssl"]
    if len(tls) > 1 or (tls and tls[0] not in ("true", "false")):
        raise ConfigurationError("DATABASE_URL must have at most one ssl=true or ssl=false option.")

    # These are Ecto's typed URL options, not libpq connection parameters.
    ecto_options = {"timeout", "pool_size", "idle_interval"}
    libpq_options = {
        "application_name", "connect_timeout", "options", "sslmode", "sslrootcert",
        "sslcert", "sslkey", "sslcrl", "sslcrldir", "channel_binding",
        "target_session_attrs", "gssencmode", "keepalives", "keepalives_idle",
        "keepalives_interval", "keepalives_count", "tcp_user_timeout",
    }
    if any(key not in ecto_options | libpq_options | {"ssl"} for key, _ in query):
        raise ConfigurationError("DATABASE_URL has an unsupported owner-validation option.")
    if tls and any(key.startswith("ssl") and key != "ssl" for key, _ in query):
        raise ConfigurationError("DATABASE_URL cannot combine ssl with libpq TLS options.")

    ca = env.get("ZAQ_DATABASE_SSL_CA_CERT_FILE", "")
    if ca and tls != ["true"]:
        raise ConfigurationError("ZAQ_DATABASE_SSL_CA_CERT_FILE requires DATABASE_URL ssl=true.")
    translated = [(key, value) for key, value in query if key not in ecto_options | {"ssl"}]
    if tls == ["true"]:
        translated += [("sslmode", "verify-full"), ("sslrootcert", ca or "system")]
    elif tls == ["false"]:
        translated += [("sslmode", "disable")]

    # libpq URI decoding uses percent escapes, not HTML form '+' space encoding.
    return urlunsplit(("postgresql", url.netloc, url.path, urlencode(translated, quote_via=quote), url.fragment))


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["build"]:
            result = build_url(os.environ)
        elif sys.argv[1:] == ["libpq"]:
            result = libpq_url(os.environ)
        else:
            raise ConfigurationError("Expected build or libpq URL mode.")
    except ConfigurationError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (ValueError, KeyError):
        # Parser exceptions may embed the URL. Only our fixed validation messages
        # are safe; never render the exception or environment here.
        print("Invalid database connection configuration.", file=sys.stderr)
        sys.exit(1)
    print(result)
