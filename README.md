# Altinity ClickHouse Operator test environment

This repository deploys a 3-shard, 2-replica ClickHouse cluster with ClickHouse
Keeper, an OpenTelemetry Collector, and Grafana. Credentials are supplied only
through Kubernetes Secrets; do not put passwords in YAML files.

## Initial credential setup

Create the `clickhouse` namespace before creating Secrets:

```bash
kubectl create namespace clickhouse
```

Generate one password for ClickHouse and reuse it for the OpenTelemetry clients.
The password is entered only into local shell variables and Kubernetes Secrets.

```bash
read -rsp 'ClickHouse default password: ' CLICKHOUSE_PASSWORD
printf '\n'

kubectl -n clickhouse create secret generic clickhouse-default-auth \
  --from-literal=password="$CLICKHOUSE_PASSWORD"

kubectl -n clickhouse create secret generic otel-clickhouse-auth \
  --from-literal=username=default \
  --from-literal=password="$CLICKHOUSE_PASSWORD"

unset CLICKHOUSE_PASSWORD
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

The Secrets have the following purposes:

| Secret | Keys | Consumers |
|---|---|---|
| `clickhouse-default-auth` | `password` | `default` ClickHouse user at initial CHI creation |
| `otel-clickhouse-auth` | `username`, `password` | OTel initialization Job, OTel Collector, Grafana ClickHouse datasource |
| `grafana-admin` | `admin-user`, `admin-password` | Grafana web administrator login |

`clickhouse/3s-2r.yaml` references `clickhouse-default-auth` through
`spec.configuration.users.default/password`. The Operator injects its value into
the ClickHouse Pod and renders a `from_env` reference in the generated user XML,
so the password is not written into the generated ConfigMap.

## Deployment order

Install the Operator bundle first. This also installs the
`ClickHouseInstallation` and `ClickHouseKeeperInstallation` CRDs.

```bash
kubectl apply -f clickhouse/clickhouse-operator-install-bundle.yaml
kubectl apply -f clickhouse/3s-2r.yaml
```

After ClickHouse is ready, create the OpenTelemetry tables. The Job uses
`otel-clickhouse-auth`.

```bash
kubectl apply -f otelcol/otel-init.yaml
kubectl -n clickhouse wait --for=condition=complete job/otel-init --timeout=15m
```

Deploy the Collector and Grafana:

```bash
kubectl apply -f otelcol/otel-collector.yaml
kubectl apply -f grafana/grafana.yaml
```

The first initialization Job cannot be updated in place because Kubernetes Job
Pod templates are immutable. Delete it before rerunning it:

```bash
kubectl -n clickhouse delete job otel-init --ignore-not-found
kubectl apply -f otelcol/otel-init.yaml
```

## Verifying authentication

Confirm that the required Secret keys exist without printing their values:

```bash
kubectl -n clickhouse describe secret clickhouse-default-auth
kubectl -n clickhouse describe secret otel-clickhouse-auth
kubectl -n clickhouse describe secret grafana-admin
```

Test ClickHouse interactively. `--ask-password` avoids putting the password in
shell history or command output.

```bash
kubectl -n clickhouse exec -it chi-clickhouse-main-0-0-0 -c clickhouse -- \
  clickhouse-client --user default --ask-password --query 'SELECT 1'
```

Check the OpenTelemetry schema Job and Collector:

```bash
kubectl -n clickhouse logs job/otel-init
kubectl -n clickhouse logs deployment/otel-collector
```

To access Grafana locally:

```bash
kubectl -n clickhouse port-forward service/grafana 3000:3000
```

Sign in at `http://localhost:3000` with the values stored in `grafana-admin`.

## Rotating credentials

Create or update both ClickHouse Secrets with a new password, then reconcile the
CHI and restart clients so environment-variable-based credentials are reread.
Do not edit Secret values into any manifest.

```bash
read -rsp 'New ClickHouse default password: ' CLICKHOUSE_PASSWORD
printf '\n'

kubectl -n clickhouse create secret generic clickhouse-default-auth \
  --from-literal=password="$CLICKHOUSE_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n clickhouse create secret generic otel-clickhouse-auth \
  --from-literal=username=default \
  --from-literal=password="$CLICKHOUSE_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

unset CLICKHOUSE_PASSWORD
kubectl apply -f clickhouse/3s-2r.yaml
kubectl -n clickhouse rollout restart deployment/otel-collector
kubectl -n clickhouse rollout restart deployment/grafana
```
