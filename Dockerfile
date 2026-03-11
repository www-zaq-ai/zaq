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

COPY lib lib
COPY priv priv
COPY assets assets

RUN mix assets.deploy
RUN mix compile

COPY config/runtime.exs config/
RUN mix release

FROM debian:bookworm-slim AS app

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    HOME=/app

WORKDIR /app

RUN useradd --system --uid 1000 --create-home --home-dir /app appuser
COPY --from=build --chown=appuser:appuser /app/_build/prod/rel/zaq ./

USER appuser

CMD ["/app/bin/zaq", "start"]
