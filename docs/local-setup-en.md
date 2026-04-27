# Kafka CDC Pipeline - Local Setup Guide

A guide to setting up a local CDC pipeline that replicates changes from MySQL to PostgreSQL in real time via Kafka.

---

## Architecture

```
MySQL (testdb.users)
    ↓ Debezium MySQL Source Connector (detects binlog)
Kafka 3-broker Cluster (KRaft)
    ↓ JDBC Sink Connector
PostgreSQL (targetdb.users)
```

---

## Components

| Service | Image | Port | Role |
|---|---|---|---|
| mysql-source | mysql:8.0 | 3306 | Source DB with binlog enabled |
| postgres-sink | postgres:15 | 5432 | Sink DB |
| kafka-1/2/3 | apache/kafka:4.1.0 | 29092/39092/49092 | 3-broker cluster in KRaft mode |
| schema-registry | confluentinc/cp-schema-registry:7.7.0 | 8081 | Avro schema management |
| connect-1/2/3 | (local build) | 8083/8084/8085 | Kafka Connect 3-instance cluster |
| kafka-ui | provectuslabs/kafka-ui | 8088 | Monitoring UI |

---

## Prerequisites

- Docker Desktop installed and running
- `jq` installed (`brew install jq`)

---

## How to Run

### 1. Create environment variable file

```bash
cp .env.example .env
```

Open the `.env` file and fill in the actual values for each field.

### 2. Start the full stack

```bash
docker compose up -d
```

Check container status:

```bash
docker compose ps
```

Wait until all containers are in the `Up` state. Kafka Connect (`connect-1/2/3`) may take 1–2 minutes to become `healthy`.

### 3. Register connectors

```bash
./register-connectors.sh
```

The script automatically waits for Kafka Connect to be ready, then registers both connectors in order.

### 4. Verify connector status

```bash
curl -s http://localhost:8083/connectors/mysql-source/status | jq .
curl -s http://localhost:8083/connectors/pg-sink/status | jq .
```

Both connectors should show `"state": "RUNNING"`.

---

## Verifying the Pipeline

### Insert data into MySQL

```bash
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "INSERT INTO users (name, email) VALUES ('Charlie', 'charlie@example.com');"
```

### Check replication in PostgreSQL

```bash
docker exec -it postgres-sink psql -U postgres targetdb \
  -c "SELECT * FROM users;"
```

If the data inserted into MySQL appears in PostgreSQL, the pipeline is working correctly.

### Check Kafka topics

Open Kafka UI in your browser and verify that messages are accumulating in the `cdc.testdb.users` topic.

```
http://localhost:8088
```

---

## Connector Details

### mysql-source

Monitors the binlog of the `testdb.users` table in real time and publishes changes to the `cdc.testdb.users` topic.

- `snapshot.mode: initial` — On first run, takes a full snapshot of existing data
- `ExtractNewRecordState` transform — Strips the Debezium envelope and forwards plain records
- DELETE events are dropped

### pg-sink

Consumes the `cdc.testdb.users` topic and upserts records into the PostgreSQL `users` table.

- `insert.mode: upsert` — Inserts if the row does not exist, updates if it does (based on PK)
- `auto.create: true` — Automatically creates the table if it does not exist
- `RegexRouter` — Extracts the table name (`users`) from the topic name

---

## Stopping

```bash
docker compose down
```

To also remove data volumes:

```bash
docker compose down -v
```
