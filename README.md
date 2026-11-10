# Altinity ClickHouse Operator test environment

 Altinity Clickhouse Operator를 설치하고, dhi 이미지를 이용하여 2 Shards 클러스트를 설치한다.
 Dhi 이미지의 볼륨 설정을 위한 init container와 local-path 기준의 pvc를 구성하고, 기본 데이터 볼륨과 backup 볼륨을 정의한다.
 Otel collector와 spring boot 애플리케이션을 이용하여 telemetry 데이터를 수집한다.
 Clickhouse Backup 및 Restore 기능을 이용하여 bakcup 볼륨에 Full 데이터 초기 백업과 증분 백업을 저장하고, 복구한다.

## 초기 설정

- 클릭하우스 네임스페이스 생성
- 클릭하우스 Operator 설치
- Clickhouse 클러스터 설치

```bash
kubectl create namespace clickhouse
kubectl apply -f clickhouse/clickhouse-operator-install-bundle.yaml
kubectl apply -f clickhouse/2s.yaml
```

## Telemetry 수집

- Otel 데이터베이스 생성
- Dice 샘플 실행
- Clickhouse 데이터 베이스 접속 및 조회

```bash
kubectl apply -f otelcol/otel-init.yaml
kubectl apply -f otelcol/otel-collector.yaml
kubectl apply -f app/dice-service.yaml
kubectl exec -it chi-clickhouse-main-0-0-0 -n clickhouse -- clickhouse-client --password clickhouse
;) select count() from otel_logs
```
## 백업 및 복구

- 초기 백업 수행
- 증분 백업 수행
- 데이터베이스 Drop 후 복구

```bash
-- 주 1회 full
;) BACKUP DATABASE default TO Disk('backups','full-20261110');

-- 평일 증분 (full 기준)
;) BACKUP DATABASE default TO Disk('backups','inc-20261110')
  SETTINGS base_backup = Disk('backups','full-20261108');

-- 복구: 증분만 지정하면 base를 자동 참조
;) DROP DATABASE default SYNC;
;) RESTORE DATABASE mydb FROM Disk('backups','inc-20261110')
     SETTINGS allow_non_empty_tables=true;
```
