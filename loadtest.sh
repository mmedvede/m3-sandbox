#!/usr/bin/env bash

# Starts fakewebserver and restarts prometheus with new scrapes.
# Assumes the test cluster is running.

set -u
set -eE
set -o pipefail

NUM_PORTS=${1:-100}

SCRAPE_TARGETS=$(
eval echo fakewebserver01:{8080..$((8080 + $NUM_PORTS -1))} \
    | sed 's/ /", "/g'
)

sed -i.bak 's/FAKEWEBSERVERTARGETS/"'"${SCRAPE_TARGETS}"'"/g' ./prometheus/prometheus.yml
docker exec m3test_prometheus_1 kill -SIGHUP 1
mv ./prometheus/prometheus.yml.bak ./prometheus/prometheus.yml
docker-compose up -d fakewebserver01
