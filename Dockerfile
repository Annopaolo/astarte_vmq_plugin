## TODO: build the plugin and link it here
FROM hexpm/elixir:1.15.5-erlang-26.1-debian-bullseye-20230612-slim AS base

# install build dependencies
# --allow-releaseinfo-change allows to pull from 'oldstable'
RUN apt-get update --allow-releaseinfo-change -y \
  && apt-get install -y build-essential git curl \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /build

FROM base as builder

# Pass --build-arg BUILD_ENV=dev to build a dev image
ARG BUILD_ENV=prod

ENV MIX_ENV=${BUILD_ENV}

# Cache elixir deps
ADD mix.exs mix.lock astarte_vmq_plugin/
RUN cd astarte_vmq_plugin && \
  mix do deps.get, deps.compile && \
  cd ..

# Add all the rest
ADD . astarte_vmq_plugin/

# Build and release
RUN cd astarte_vmq_plugin && \
  mix do compile, release && \
  cd ..

RUN echo astarte_vmq_plugin/_build/${BUILD_ENV}/rel/astarte_vmq_plugin/bin/astarte_vmq_plugin

# TODO change me
FROM debian:bookworm-slim

# We have to redefine this here since it goes out of scope for each build stage
ARG BUILD_ENV=prod

RUN apt-get update && \
  apt-get -y install bash procps openssl iproute2 curl jq libsnappy-dev net-tools nano && \
  rm -rf /var/lib/apt/lists/* && \
  addgroup --gid 10000 vernemq && \
  adduser --uid 10000 --system --ingroup vernemq --home /vernemq --disabled-password vernemq

WORKDIR /vernemq

# Defaults
ENV DOCKER_VERNEMQ_KUBERNETES_LABEL_SELECTOR="app=vernemq" \
  DOCKER_VERNEMQ_LOG__CONSOLE=console \
  PATH="/vernemq/bin:$PATH" \
  VERNEMQ_VERSION="2.0.1"
COPY --chown=10000:10000 bin/vernemq.sh /usr/sbin/start_vernemq
COPY --chown=10000:10000 bin/join_cluster.sh /usr/sbin/join_cluster
COPY --chown=10000:10000 files/vm.args /vernemq/etc/vm.args

# Note that the following copies a binary package under EULA (requiring a paid subscription).
RUN ARCH=$(uname -m | sed -e 's/aarch64/arm64/') && \
  curl -L https://github.com/vernemq/vernemq/releases/download/$VERNEMQ_VERSION/vernemq-$VERNEMQ_VERSION.bookworm.$ARCH.tar.gz -o /tmp/vernemq-$VERNEMQ_VERSION.bookworm.tar.gz && \
  tar -xzvf /tmp/vernemq-$VERNEMQ_VERSION.bookworm.tar.gz && \
  rm /tmp/vernemq-$VERNEMQ_VERSION.bookworm.tar.gz && \
  chown -R 10000:10000 /vernemq && \
  ln -s /vernemq/etc /etc/vernemq && \
  ln -s /vernemq/data /var/lib/vernemq && \
  ln -s /vernemq/log /var/log/vernemq

## Add the Elixir plugin
COPY --from=builder /build/astarte_vmq_plugin/_build/$BUILD_ENV/rel/astarte_vmq_plugin /etc/astarte_vmq_plugin
# Copy the schema over
COPY --from=builder /build/astarte_vmq_plugin/priv/astarte_vmq_plugin.schema /vernemq/share/schema/astarte_vmq_plugin.schema

# Ports
# 1883  MQTT
# 8883  MQTT/SSL
# 8080  MQTT WebSockets
# 44053 VerneMQ Message Distribution
# 4369  EPMD - Erlang Port Mapper Daemon
# 8888  Health, API, Prometheus Metrics
# 9100 9101 9102 9103 9104 9105 9106 9107 9108 9109  Specific Distributed Erlang Port Range

EXPOSE 1883 8883 8080 44053 4369 8888 \
  9100 9101 9102 9103 9104 9105 9106 9107 9108 9109


VOLUME ["/vernemq/log", "/vernemq/data", "/vernemq/etc"]

HEALTHCHECK CMD vernemq ping | grep -q pong

USER vernemq

CMD ["start_vernemq"]
