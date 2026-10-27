# Altinity ClickHouse Operator test environment

This repository deploys a 3-shard, 2-replica ClickHouse cluster with ClickHouse
Keeper, an OpenTelemetry Collector, and Grafana. The ClickHouse `default` user
accepts in-cluster IPv4 connections without a password.

## Initial setup

Create the `clickhouse` namespace before creating the Grafana administrator
Secret:

```bash
kubectl create namespace clickhouse
```

Create a separate Grafana administrator password:

```bash
read -rp 'Grafana administrator user [admin]: ' GRAFANA_ADMIN_USER
GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER:-admin}
read -rsp 'Grafana administrator password: ' GRAFANA_ADMIN_PASSWORD
printf '\n'

kubectl -n clickhouse create secret generic grafana-admin \
  --from-literal=admin-user="$GRAFANA_ADMIN_USER" \
  --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD"

unset GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
```

`clickhouse/3s-2r.yaml` configures `default/networks/ip` as `0.0.0.0/0`, so
the OTel initialization Job, OTel Collector, and Grafana can connect without a
password. Do not expose ClickHouse outside the cluster while using this setup.

## Deployment order

Install the Operator bundle first. This also installs the
`ClickHouseInstallation` and `ClickHouseKeeperInstallation` CRDs.

```bash
kubectl apply -f clickhouse/clickhouse-operator-install-bundle.yaml
kubectl apply -f clickhouse/3s-2r.yaml
```

After ClickHouse is ready, create the OpenTelemetry tables:

```bash
kubectl apply -f otelcol/otel-init.yaml
kubectl -n clickhouse wait --for=condition=complete job/otel-init --timeout=15m
```

Deploy the Collector and Grafana:

```bash
kubectl apply -f otelcol/otel-collector.yaml
kubectl apply -f grafana/grafana.yaml
```

The initialization Job cannot be updated in place because Kubernetes Job Pod
templates are immutable. Delete it before rerunning it:

```bash
kubectl -n clickhouse delete job otel-init --ignore-not-found
kubectl apply -f otelcol/otel-init.yaml
```

## Verifying connectivity

Confirm that the Grafana Secret keys exist without printing their values:

```bash
kubectl -n clickhouse describe secret grafana-admin
```

Test ClickHouse interactively:

```bash
kubectl -n clickhouse exec -it chi-clickhouse-main-0-0-0 -c clickhouse -- \
  clickhouse-client --user default --query 'SELECT 1'
```

Check the OpenTelemetry schema Job and Collector:

```bash
kubectl -n clickhouse logs job/otel-init
kubectl -n clickhouse logs deployment/otel-collector
```

To access Grafana locally:

```bash
kubectl -n kube-system get service traefik
```

Configure DNS or a local hosts entry to point `grafana.local` at the Traefik
address, then sign in at `http://grafana.local` with the values stored in
`grafana-admin`.
