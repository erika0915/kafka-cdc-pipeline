# Kafka CDC Pipeline - Advanced Testing Guide

Advanced tests conducted after the basic pipeline setup in the local environment.

---

## 1. DELETE Propagation

### Goal
Ensure that DELETE operations in MySQL are also reflected in PostgreSQL.

### Changes

**connectors/mysql-source.json**
```json
"transforms.unwrap.delete.handling.mode": "none",
"transforms.unwrap.drop.tombstones": "false"
```

- `delete.handling.mode: none` — Forwards DELETE events to Kafka as tombstone (null value) messages
- `drop.tombstones: false` — Passes tombstone messages downstream instead of discarding them

**connectors/pg-sink.json**
```json
"delete.enabled": "true"
```

- When the JDBC Sink receives a null value message, it performs a DELETE on the row matching the PK

### Updating Connectors at Runtime

After modifying the files, apply changes to the running connectors via the REST API.

```bash
curl -s -X PUT http://localhost:8083/connectors/mysql-source/config \
  -H "Content-Type: application/json" \
  -d "$(cat connectors/mysql-source.json | jq '.config')" | jq .

curl -s -X PUT http://localhost:8083/connectors/pg-sink/config \
  -H "Content-Type: application/json" \
  -d "$(cat connectors/pg-sink.json | jq '.config')" | jq .
```

### Verification

```bash
# Delete from MySQL
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "DELETE FROM users WHERE name='Charlie';"

# Confirm deletion in PostgreSQL
docker exec postgres-sink psql -U postgres targetdb \
  -c "SELECT * FROM users;"
```

**Result**: Charlie is deleted from PostgreSQL as well

---

## 2. Automatic Schema Evolution (auto.evolve)

### Goal
Verify that adding a column to a MySQL table automatically creates the same column in PostgreSQL.

### Related Setting

**connectors/pg-sink.json**
```json
"auto.evolve": "true"
```

When `auto.evolve: true` is set, the sink connector automatically issues an `ALTER TABLE` on the target table when the source schema changes.

### Verification

```bash
# Add age column to MySQL
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "ALTER TABLE users ADD COLUMN age INT;"

# Insert a row with age
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "INSERT INTO users (name, email, age) VALUES ('Dave', 'dave@example.com', 30);"

# Confirm in PostgreSQL
docker exec postgres-sink psql -U postgres targetdb \
  -c "SELECT * FROM users;"
```

**Result**
- The `age` column is automatically created in the PostgreSQL `users` table
- Dave's age=30 is replicated correctly
- Existing rows (Alice, Bob) have NULL for age

---

## 3. Multi-Table CDC

### Goal
Extend the CDC pipeline to include the `orders` table in addition to `users`.

### Changes

**mysql/init.sql** — Add orders table
```sql
CREATE TABLE orders (
  id         INT PRIMARY KEY AUTO_INCREMENT,
  user_id    INT NOT NULL,
  product    VARCHAR(100) NOT NULL,
  amount     INT NOT NULL,
  ordered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

**connectors/mysql-source.json**
```json
"table.include.list": "testdb.users,testdb.orders"
```

**connectors/pg-sink.json**
```json
"topics": "cdc.testdb.users,cdc.testdb.orders"
```

### Adding the Table to the Running MySQL

```bash
docker exec mysql-source mysql -u appuser -papppassword testdb -e "
CREATE TABLE IF NOT EXISTS orders (
  id         INT PRIMARY KEY AUTO_INCREMENT,
  user_id    INT NOT NULL,
  product    VARCHAR(100) NOT NULL,
  amount     INT NOT NULL,
  ordered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO orders (user_id, product, amount) VALUES (1, 'Laptop', 1), (2, 'Mouse', 2);
"
```

Apply connector config changes via the REST API after updating the files.

### Verification

```bash
# Confirm orders table is replicated to PostgreSQL
docker exec postgres-sink psql -U postgres targetdb \
  -c "SELECT * FROM orders;"

# Insert a new order
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "INSERT INTO orders (user_id, product, amount) VALUES (1, 'Keyboard', 3);"

# Confirm real-time replication in PostgreSQL
docker exec postgres-sink psql -U postgres targetdb \
  -c "SELECT * FROM orders;"
```

**Result**: Laptop, Mouse, and Keyboard are all replicated to PostgreSQL

---

## 4. Fault Tolerance Test

### Goal
Verify that the pipeline continues to operate without interruption when one Kafka broker goes down.

### Related Settings

```yaml
# docker-compose.yml
KAFKA_MIN_INSYNC_REPLICAS: 2
KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
```

With 3 brokers, even if 1 goes down, the remaining 2 still satisfy `MIN_INSYNC_REPLICAS: 2`, so reads and writes continue uninterrupted.

### Test Sequence

```bash
# 1. Stop one broker
docker stop kafka-2

# 2. Insert data while the broker is down
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "INSERT INTO orders (user_id, product, amount) VALUES (1, 'Monitor', 1);"

# 3. Confirm replication to PostgreSQL
docker exec postgres-sink psql -U postgres targetdb \
  -c "SELECT * FROM orders;"

# 4. Check connector status
curl -s http://localhost:8083/connectors/mysql-source/status | jq .

# 5. Restore the broker
docker start kafka-2

# 6. Re-check status after recovery
curl -s http://localhost:8083/connectors/mysql-source/status | jq .
```

**Result**
- Monitor INSERT is immediately replicated to PostgreSQL even with kafka-2 down
- Connector state remains `RUNNING` (connect-1 stays connected to the surviving brokers)
- After kafka-2 restarts, it automatically rejoins the cluster and syncs data
