# Sandbox environment for M3 ecosystem

Based on M3 docker integration tests from [m3](https://github.com/m3db/m3/).

WARNING: this configuration was used for a specific use case, so some of it
could be strange, e.g.  aggregator writing to a different cluster. It is still
useful to get a working M3 environment running.

# Requirements

Running the stack could be tricky if there is not enough RAM/CPU. If nodes are
crashing, try removing scrape endpoints from
[./prometheus/prometheus.yml](./prometheus/prometheus.yml).

# Running

To start all-in-one cluster:

    ./bringup.sh

The script brings up m3db, aggregator, coordinator, query, grafana, prometheus,
etc. It would use the same m3db both for primary storage and for storing
aggregated metrics. Query is setup to get metrics from aggregated namespace
only.

To run two clusters (one per VM), each one replicating aggregated metrics to
one another:

    # assuming VM IPs are 10.0.0.1 and 10.0.0.2:

    # on 10.0.0.1:
    ./bringup.sh 10.0.0.2

    # on 10.0.0.2
    ./bringup.sh 10.0.0.1

In this case aggregator would forward metrics to a different cluster for
backup.

# Loadtest

If you want to add 100 more scrape endpoints to prometheus:

    ./loadtest.sh 100

This would create a temporary prometheus config scraping 100 fakewebserver
endpoints and force prometheus config reload.

# Endpoints

Prometheus http://localhost:9090

Grafana http://localhost:3000  creds: admin/admin
