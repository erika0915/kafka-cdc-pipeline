# Kafka CDC Pipeline - Monitoring Guide (Prometheus + Grafana)

A guide to monitoring the Kafka cluster and CDC pipeline using Prometheus and Grafana.

---

## Architecture

```
Kafka Cluster
    ↓
kafka-exporter (collects metrics :9308)
    ↓
Prometheus (scrapes and stores :9090)
    ↓
Grafana (visualizes :3000)
```

---

## Components

| Service | Image | Port | Role |
|---|---|---|---|
| kafka-exporter | danielqsj/kafka-exporter | 9308 | Exposes Kafka metrics in Prometheus format |
| prometheus | prom/prometheus | 9090 | Scrapes and stores metrics |
| grafana | grafana/grafana | 3000 | Visualizes metrics via dashboards |

---

## What You Can Monitor

### Kafka Cluster Health
- Number of active brokers
- Number of topics and partitions
- Messages per second throughput

### Key CDC Pipeline Metrics

| Metric | Meaning | Healthy Value |
|---|---|---|
| `kafka_consumergroup_lag` | Unprocessed messages in pg-sink | 0 |
| `kafka_consumergroup_current_offset` | Messages processed per topic | Continuously increasing |
| `kafka_brokers` | Number of active brokers | 3 |

> A continuously rising Consumer LAG indicates that PostgreSQL replication is falling behind

---

## Configuration

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

`scrape_interval: 15s` — Prometheus collects metrics from kafka-exporter every 15 seconds.

---

## Running

### Local

```bash
docker compose up -d kafka-exporter prometheus grafana
```

### Production (EC2)

Add the following ports to the EC2 security group (`cdc-ec2-sg`):

| Port | Purpose |
|---|---|
| 3000 | Grafana |
| 9090 | Prometheus (optional) |

```bash
docker compose -f docker-compose.prod.yml up -d kafka-exporter prometheus grafana
```

---

## Grafana Initial Setup

### 1. Access

```
http://localhost:3000        # Local
http://<EC2-PUBLIC-IP>:3000  # Production
```

- Username: `admin`
- Password: `admin`

### 2. Add Data Source

**Connections → Data sources → Add data source → Prometheus**

| Field | Value |
|---|---|
| URL | `http://prometheus:9090` |

Click **Save & test** → confirm `Successfully queried the Prometheus API`

### 3. Import Dashboard

**Dashboards → Import → Enter ID `12483` → Load → Select Prometheus → Import**

> Dashboard ID `12483` is the official dashboard for danielqsj/kafka-exporter

---

## Key Metric Queries

These can be run directly in Grafana Explore.

```promql
# Number of brokers
kafka_brokers

# Consumer group lag per topic
kafka_consumergroup_lag

# Current offset per topic
kafka_consumergroup_current_offset

# Broker info
kafka_broker_info
```

---

## Verifying Pipeline Activity

Inserting data into MySQL will change the following metrics in real time.

**Local:**
```bash
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "INSERT INTO users (name, email) VALUES ('Test', 'test@example.com');"
```

**Production:**
```bash
mysql -h <RDS-MySQL-ENDPOINT> -u admin -p testdb \
  -e "INSERT INTO users (name, email) VALUES ('Test', 'test@example.com');"
```

After inserting, check Grafana:
- `kafka_consumergroup_lag` → briefly increases then returns to 0
- `kafka_consumergroup_current_offset` → increments by 1

A LAG returning to 0 confirms successful replication to PostgreSQL.

---

## Troubleshooting

### Prometheus Target Shows DOWN

```bash
# Check kafka-exporter logs
docker logs kafka-exporter

# Verify metrics directly
curl http://localhost:9308/metrics | grep kafka_brokers
```

### No Data Showing in Grafana

1. Confirm Data source URL is `http://prometheus:9090` (not `localhost`)
2. Change the dashboard time range to `Last 5 minutes`
3. Run `kafka_brokers` directly in Explore to verify data is available
