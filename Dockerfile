# syntax=docker/dockerfile:1.7

FROM elixir:1.19.5-otp-28 AS build

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv
COPY lib lib

RUN mix compile

COPY assets assets
RUN mix assets.deploy

COPY config/runtime.exs config/

RUN mix zaq.python.fetch

RUN mix release

# Keep a stable path to the release-bundled Python requirements
RUN cp /app/_build/prod/rel/zaq/lib/zaq-*/priv/python/crawler-ingest/requirements.txt /app/release-requirements.txt

# -- agent-browser CLI (native Rust binary for the web_browsing action) --
# Compiled from crates.io into a single self-contained binary that is copied
# into the runtime image. The browser itself is the system Chromium installed
# in the shared browser-runtime stage, so we do not run
# `agent-browser install` (which would download ~684MB of Chrome for Testing).
FROM rust:1-slim-trixie AS agent-browser

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends pkg-config libssl-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Pin the version for reproducible builds — an unpinned install would compile
# whatever is latest on crates.io at build time, risking silent CLI regressions.
COPY priv/browser/agent-browser.version /tmp/agent-browser.version
RUN cargo install agent-browser --version "=$(cat /tmp/agent-browser.version)" --locked --root /opt/agent-browser

# Production and the opt-in browser-tool CI job use this exact browser setup.
# Chromium follows Debian security updates; its resolved version is logged below.
FROM debian:trixie-slim AS browser-runtime

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates \
      python3 python3-venv python3-pip \
      chromium fonts-liberation && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    HOME=/app \
    AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium \
    # --no-sandbox: Chromium's setuid sandbox can't run unprivileged in a
    # container; --disable-dev-shm-usage avoids crashes from the small default
    # /dev/shm. This relaxes Chromium's own sandbox, so the compensating control
    # is domain allowlisting via AGENT_BROWSER_ALLOWED_DOMAINS (see
    # Zaq.Agent.Tools.Web.Browsing.domain_flags/1).
    AGENT_BROWSER_ARGS=--no-sandbox,--disable-dev-shm-usage

WORKDIR /app

RUN useradd --system --uid 1000 --create-home --home-dir /app appuser && \
    chown appuser:appuser /app
COPY --from=agent-browser /opt/agent-browser/bin/agent-browser /usr/local/bin/agent-browser
RUN agent-browser --version && chromium --version

# Keep app last: an ordinary docker build still produces the production release.
FROM browser-runtime AS app

ENV MIX_ENV=prod PHX_SERVER=true
COPY --from=build --chown=appuser:appuser /app/_build/prod/rel/zaq ./

RUN python3 -m venv /app/.venv && \
    /app/.venv/bin/pip install --no-cache-dir -r /app/lib/zaq-*/priv/python/crawler-ingest/requirements.txt && \
    chown -R appuser:appuser /app/.venv

USER appuser

CMD ["/bin/sh", "-c", "/app/bin/zaq eval \"Zaq.Release.migrate()\" && exec /app/bin/zaq start"]
