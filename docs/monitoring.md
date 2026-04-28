# Kafka CDC Pipeline - 모니터링 가이드 (Prometheus + Grafana)

Kafka 클러스터와 CDC 파이프라인의 상태를 Prometheus와 Grafana로 모니터링하는 가이드입니다.

---

## 아키텍처

```
Kafka Cluster
    ↓
kafka-exporter (메트릭 수집 :9308)
    ↓
Prometheus (스크래핑 및 저장 :9090)
    ↓
Grafana (시각화 :3000)
```

---

## 구성 요소

| 서비스 | 이미지 | 포트 | 역할 |
|---|---|---|---|
| kafka-exporter | danielqsj/kafka-exporter | 9308 | Kafka 메트릭을 Prometheus 형식으로 노출 |
| prometheus | prom/prometheus | 9090 | 메트릭 수집 및 저장 |
| grafana | grafana/grafana | 3000 | 메트릭 시각화 대시보드 |

---

## 모니터링으로 볼 수 있는 것

### Kafka 클러스터 상태
- 활성 브로커 수
- 토픽 및 파티션 수
- 초당 메시지 처리량 (messages/sec)

### CDC 파이프라인 핵심 지표

| 지표 | 의미 | 정상 |
|---|---|---|
| `kafka_consumergroup_lag` | pg-sink가 처리 못 한 메시지 수 | 0 |
| `kafka_consumergroup_current_offset` | 각 토픽에서 처리한 메시지 수 | 계속 증가 |
| `kafka_brokers` | 활성 브로커 수 | 3 |

> Consumer LAG이 계속 올라가면 PostgreSQL 복제가 지연되고 있다는 신호

---

## 설정 파일

### monitoring/prometheus.yml

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'kafka-exporter'
    static_configs:
      - targets: ['kafka-exporter:9308']
```

`scrape_interval: 15s` — 15초마다 kafka-exporter에서 메트릭을 수집한다.

---

## 실행

### 로컬

```bash
docker compose up -d kafka-exporter prometheus grafana
```

### 배포 (EC2)

EC2 보안 그룹(`cdc-ec2-sg`)에 포트 추가 필요:

| 포트 | 용도 |
|---|---|
| 3000 | Grafana |
| 9090 | Prometheus (선택) |

```bash
docker compose -f docker-compose.prod.yml up -d kafka-exporter prometheus grafana
```

---

## Grafana 초기 설정

### 1. 접속

```
http://localhost:3000        # 로컬
http://<EC2-퍼블릭-IP>:3000  # 배포
```

- ID: `admin`
- PW: `admin`

### 2. Data Source 추가

**Connections → Data sources → Add data source → Prometheus**

| 항목 | 값 |
|---|---|
| URL | `http://prometheus:9090` |

**Save & test** 클릭 → `Successfully queried the Prometheus API` 확인

### 3. 대시보드 Import

**Dashboards → Import → ID `12483` 입력 → Load → Prometheus 선택 → Import**

> Dashboard ID `12483`은 danielqsj/kafka-exporter 전용 대시보드

---

## 주요 메트릭 쿼리

Grafana Explore에서 직접 쿼리할 수 있다.

```promql
# 브로커 수
kafka_brokers

# 컨슈머 그룹 LAG (토픽별)
kafka_consumergroup_lag

# 토픽별 현재 오프셋
kafka_consumergroup_current_offset

# 브로커 정보
kafka_broker_info
```

---

## 파이프라인 동작 확인

MySQL에 데이터를 INSERT하면 아래 지표가 변한다.

**로컬:**
```bash
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "INSERT INTO users (name, email) VALUES ('Test', 'test@example.com');"
```

**배포:**
```bash
mysql -h <RDS-MySQL-엔드포인트> -u admin -p testdb \
  -e "INSERT INTO users (name, email) VALUES ('Test', 'test@example.com');"
```

INSERT 후 Grafana에서 확인:
- `kafka_consumergroup_lag` → 잠깐 올라갔다가 0으로 복귀
- `kafka_consumergroup_current_offset` → 1 증가

LAG이 0으로 돌아오면 PostgreSQL까지 정상 복제된 것이다.

---

## 트러블슈팅

### Prometheus Target이 DOWN인 경우

```bash
# kafka-exporter 로그 확인
docker logs kafka-exporter

# 메트릭 직접 확인
curl http://localhost:9308/metrics | grep kafka_brokers
```

### Grafana에 데이터가 안 보이는 경우

1. Data source URL이 `http://prometheus:9090`인지 확인 (`localhost` 사용 불가)
2. 대시보드 우측 상단 시간 범위를 `Last 5 minutes`로 변경
3. Explore에서 `kafka_brokers` 직접 쿼리해서 데이터 확인
