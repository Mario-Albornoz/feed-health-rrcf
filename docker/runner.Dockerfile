# Runner image: the toolchain the root Makefile needs (Go, Python 3.12 with the detector's
# dependencies, the Kafka command-line tools, GNU make). The repository itself is NOT copied in:
# docker-compose.yml bind-mounts it at /workspace, so results, logs and the dataset stay on the host.

FROM golang:1.26-bookworm AS go

FROM python:3.12-slim-bookworm

# Kafka CLI version matches the broker image (confluentinc/cp-kafka:7.5.0 ships Kafka 3.5),
# so kafka-consumer-groups prints the same columns the Makefile's drain target parses.
ARG KAFKA_VERSION=3.5.2
ARG SCALA_VERSION=2.13

RUN apt-get update && apt-get install -y --no-install-recommends \
        make bc procps curl ca-certificates git build-essential openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*

COPY --from=go /usr/local/go /usr/local/go

# Kafka CLI, exposed under the names the Confluent image uses (kafka-topics, not kafka-topics.sh)
RUN curl -fsSL "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz" \
        | tar -xz -C /opt \
    && mv /opt/kafka_${SCALA_VERSION}-${KAFKA_VERSION} /opt/kafka \
    && for t in kafka-topics kafka-consumer-groups kafka-console-consumer kafka-broker-api-versions; do \
           printf '#!/bin/sh\nexec /opt/kafka/bin/%s.sh "$@"\n' "$t" > /usr/local/bin/$t; \
           chmod +x /usr/local/bin/$t; \
       done

# Detector dependencies, installed the same way as `make setup-detector`
COPY rrcf-detector/requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir 'setuptools<75' \
    && /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

# archive-run records `git rev-parse` of each module; the bind mount is owned by the host user
RUN git config --system --add safe.directory '*'

# Binaries and Go caches live outside the bind mount (named volumes in docker-compose.yml), so a
# Linux build never overwrites the host's price-feed-simulator/bin/simulator. The directories are
# world-writable because the container may run as the host user (see the Makefile's docker targets).
RUN mkdir -p /opt/thesis/bin /opt/thesis/go /opt/thesis/gocache && chmod -R 1777 /opt/thesis

ENV PATH=/opt/venv/bin:/usr/local/go/bin:/opt/thesis/go/bin:$PATH \
    GOPATH=/opt/thesis/go \
    GOCACHE=/opt/thesis/gocache \
    GOFLAGS=-buildvcs=false \
    HOME=/tmp \
    THESIS_IN_DOCKER=1 \
    PY=/opt/venv/bin/python3 \
    SIMULATOR_BIN=/opt/thesis/bin/simulator \
    HANDLER_BIN=/opt/thesis/bin/aggregator

WORKDIR /workspace
