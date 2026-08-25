FROM hexpm/elixir:1.18.4-erlang-27.3.4.8-debian-bookworm-20260518-slim AS builder

ENV MIX_ENV=prod
WORKDIR /build

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY lib lib
RUN mix compile && mix release commonplace_log

FROM debian:bookworm-slim AS runtime

# Bump image_vars.BUILD_STAMP in worker/wrangler.jsonc to force a container
# rollout without a code change (used to observe old/new incarnation overlap).
ARG BUILD_STAMP=dev
LABEL org.commonplace.build_stamp=$BUILD_STAMP

RUN apt-get update \
    && apt-get install -y --no-install-recommends libstdc++6 openssl ca-certificates libncurses6 \
    && rm -rf /var/lib/apt/lists/*

ENV COMMONPLACE_REALM_HTTP_PORT=4000
WORKDIR /app

COPY --from=builder /build/_build/prod/rel/commonplace_log ./

EXPOSE 4000

CMD ["/app/bin/commonplace_log", "start"]
