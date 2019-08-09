#!/usr/bin/env bash

set -u
set -eE
# set -o pipefail
# set -x

# Assume we run this from the root of the repo with ./docker-compose.yml
# present.

DR_COORDINATOR_ENDPOINT=${1:-m3coordinator01}

function retry() {(
    set +eE
    while true; do
        eval "$@"
        [[ "$?" == 0 ]] && return
        echo -n '. '
        sleep 1
    done
)}

# Stop containers on exit
function __cleanup {
  docker-compose down -v
  kill $DOCKER_COMPOSE_LOGS_PID
}
trap __cleanup EXIT

echo "Starting up Prometheus, http://localhost:9090"
docker-compose up -d prometheus

echo "Starting up Cadvisor, http://localhost:8080"
docker-compose up -d cadvisor

echo "Starting up Node-exporter, http://localhost:9100"
docker-compose up -d node-exporter

echo "Starting up Grafana, http://localhost:3000  creds: admin/admin"
docker-compose up -d grafana

echo "Run m3dbnode"
docker-compose up -d dbnode01
docker-compose up -d dbnode02
docker-compose up -d dbnode03

(
docker-compose logs --tail=all --follow \
  | grep -v 'is below recommended threshold\|prometheus.*connection refused\|prometheus.*no such host'
) &
DOCKER_COMPOSE_LOGS_PID=$!

echo "Setup DB node"


echo "Wait for API to be available"
retry \
  '[ "$(curl -sSf 0.0.0.0:7201/api/v1/namespace | jq ".namespaces | length")" == "0" ]'

echo "Adding placement"
function gen_db_instance() {
  local host=$1
  local isolation_group=$2
  echo '{
        "id": "'$host'",
        "isolation_group": "'$isolation_group'",
        "zone": "embedded",
        "weight": 1024,
        "endpoint": "'$host':9000",
        "hostname": "'$host'",
        "port": "9000"
    }'
}
curl -vvvsSf -X POST 0.0.0.0:7201/api/v1/placement/init -d '{
  "num_shards": 4,
  "replicationFactor": 2,
  "instances": [
     '"$(gen_db_instance dbnode01 rack-1)"'
    ,'"$(gen_db_instance dbnode02 rack-2)"'
    ,'"$(gen_db_instance dbnode03 rack-3)"'
  ]
}'

echo "Wait until placement is init'd"
retry \
  '[ "$(curl -sSf 0.0.0.0:7201/api/v1/placement | jq .placement.instances.dbnode01.id)" == \"dbnode01\" ]'

echo "Adding agg namespace"
curl -vvvsSf -X POST 0.0.0.0:7201/api/v1/namespace -d '{
  "name": "agg",
  "options": {
    "bootstrapEnabled": true,
    "flushEnabled": true,
    "writesToCommitLog": true,
    "cleanupEnabled": true,
    "snapshotEnabled": true,
    "repairEnabled": false,
    "retentionOptions": {
      "retentionPeriodDuration": "360h",
      "blockSizeDuration": "2h",
      "bufferFutureDuration": "1h",
      "bufferPastDuration": "1h",
      "blockDataExpiry": true,
      "blockDataExpiryAfterNotAccessPeriodDuration": "5m"
    },
    "indexOptions": {
      "enabled": true,
      "blockSizeDuration": "12h"
    }
  }
}'

echo "Wait until agg namespace is init'd"
retry \
  '[ "$(curl -sSf 0.0.0.0:7201/api/v1/namespace | jq .registry.namespaces.agg.indexOptions.enabled)" == true ]'

echo "Adding unagg namespace"
curl -vvvsSf -X POST 0.0.0.0:7201/api/v1/namespace -d '{
  "name": "unagg",
  "options": {
    "bootstrapEnabled": true,
    "flushEnabled": true,
    "writesToCommitLog": true,
    "cleanupEnabled": true,
    "snapshotEnabled": true,
    "repairEnabled": false,
    "retentionOptions": {
      "retentionPeriodDuration": "360h",
      "blockSizeDuration": "2h",
      "bufferFutureDuration": "1h",
      "bufferPastDuration": "1h",
      "blockDataExpiry": true,
      "blockDataExpiryAfterNotAccessPeriodDuration": "5m"
    },
    "indexOptions": {
      "enabled": true,
      "blockSizeDuration": "12h"
    }
  }
}'

echo "Wait until unagg namespace is init'd"
retry \
  '[ "$(curl -sSf 0.0.0.0:7201/api/v1/namespace | jq .registry.namespaces.unagg.indexOptions.enabled)" == true ]'

echo "Wait until bootstrapped"
retry \
  '[ "$(curl -sSf 0.0.0.0:9002/health | jq .bootstrapped)" == true ]'


echo "Initializing aggregator topology"
function gen_agg_instance() {
  local host=$1
  local isolation_group=$2
  echo '{
      "id": "'$host':6000",
      "isolation_group": "'$isolation_group'",
      "zone": "embedded",
      "weight": 100,
      "endpoint": "'$host':6000",
      "hostname": "'$host'",
      "port": 6000
    }'
}
# Replication factor corresponds to number of isolation groups
curl -vvvsSf -X POST localhost:7201/api/v1/services/m3aggregator/placement/init -d '{
    "num_shards": 4,
    "replication_factor": 3,
    "instances": [
     '"$(gen_agg_instance m3aggregator01 rack-1)"'
    ,'"$(gen_agg_instance m3aggregator02 rack-1)"'
    ,'"$(gen_agg_instance m3aggregator03 rack-2)"'
    ,'"$(gen_agg_instance m3aggregator04 rack-2)"'
    ,'"$(gen_agg_instance m3aggregator05 rack-3)"'
    ,'"$(gen_agg_instance m3aggregator06 rack-3)"'
    ]
}'

echo "Initializing m3msg topic for m3coordinator ingestion from m3aggregators"
curl -vvvsSf -X POST -H 'topic-name: aggregated_metrics_dr' localhost:7201/api/v1/topic/init -d '{ "numberOfShards": 4 }'

echo "Initializing m3coordinator topology"
curl -vvvsSf -X POST  -H 'Cluster-Environment-Name: default_env' localhost:7201/api/v1/services/m3coordinator/placement/init -d '{
    "instances": [
        {
            "id": "m3coordinator01",
            "zone": "embedded",
            "endpoint": "m3coordinator01:7507",
            "hostname": "m3coordinator01",
            "port": 7507
        },
        {
            "id": "m3coordinator02",
            "zone": "embedded",
            "endpoint": "m3coordinator02:7508",
            "hostname": "m3coordinator02",
            "port": 7508
        },
        {
            "id": "m3coordinator03",
            "zone": "embedded",
            "endpoint": "m3coordinator03:7509",
            "hostname": "m3coordinator03",
            "port": 7509
        }
    ]
}'

echo "Initializing m3coordinator topology"
curl -vvvsSf -X POST -H 'Cluster-Environment-Name: dr' localhost:7201/api/v1/services/m3coordinator/placement/init -d '{
    "instances": [
        {
            "id": "dr_m3coordinator01",
            "zone": "embedded",
            "endpoint": "'"${DR_COORDINATOR_ENDPOINT}"':7507",
            "hostname": "dr_m3coordinator01",
            "port": 7507
        },
        {
            "id": "dr_m3coordinator02",
            "zone": "embedded",
            "endpoint": "'"${DR_COORDINATOR_ENDPOINT}"':7508",
            "hostname": "dr_m3coordinator02",
            "port": 7508
        },
        {
            "id": "dr_m3coordinator03",
            "zone": "embedded",
            "endpoint": "'"${DR_COORDINATOR_ENDPOINT}"':7509",
            "hostname": "dr_m3coordinator03",
            "port": 7509
        }
    ]
}'
echo "Done initializing m3coordinator topology"

echo "Validating m3coordinator topology"
[ "$(curl -sSf localhost:7201/api/v1/services/m3coordinator/placement | jq .placement.instances.m3coordinator01.id)" == '"m3coordinator01"' ]
echo "Done validating topology"

# Do this after placement for m3coordinator is created.

echo "Adding m3coordinator as a consumer to the aggregator topic"
# Note environment is set to "dr", instead of "default_env". This allows to
# use a different placement of coordinators as consumers to aggregated metrics.
curl -vvvsSf -X POST -H 'topic-name: aggregated_metrics_dr' localhost:7201/api/v1/topic -d '{
  "consumerService": {
    "serviceId": {
      "name": "m3coordinator",
      "environment": "dr",
      "zone": "embedded"
    },
    "consumptionType": "SHARED",
    "messageTtlNanos": "600000000000"
  }
}'


echo "Running m3coordinator containers"
docker-compose up -d m3coordinator01
docker-compose up -d m3coordinator02
docker-compose up -d m3coordinator03

echo "Running m3aggregator containers"
docker-compose up -d m3aggregator01
docker-compose up -d m3aggregator02
docker-compose up -d m3aggregator03
docker-compose up -d m3aggregator04
docker-compose up -d m3aggregator05
docker-compose up -d m3aggregator06

echo "Starting up m3query"
docker-compose up -d m3query

echo "Press enter to tear down the test environment."
read
