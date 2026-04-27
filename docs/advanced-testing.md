# Kafka CDC Pipeline - 심화 테스트 가이드

로컬 환경에서 기본 파이프라인 구성 이후 진행한 심화 테스트 내용입니다.

---

## 1. DELETE 전파

### 목표
MySQL에서 DELETE 시 PostgreSQL에도 삭제가 반영되도록 설정한다.

### 변경 내용

**connectors/mysql-source.json**
```json
"transforms.unwrap.delete.handling.mode": "none",
"transforms.unwrap.drop.tombstones": "false"
```

- `delete.handling.mode: none` — DELETE 이벤트를 tombstone(null value) 메시지로 Kafka에 전달
- `drop.tombstones: false` — tombstone 메시지를 버리지 않고 싱크 쪽으로 통과시킴

**connectors/pg-sink.json**
```json
"delete.enabled": "true"
```

- JDBC Sink가 null value 메시지를 받으면 해당 PK의 행을 DELETE 처리

### 커넥터 업데이트 (실행 중 반영)

파일 수정 후 REST API로 실행 중인 커넥터에 반영해야 한다.

```bash
curl -s -X PUT http://localhost:8083/connectors/mysql-source/config \
  -H "Content-Type: application/json" \
  -d "$(cat connectors/mysql-source.json | jq '.config')" | jq .

curl -s -X PUT http://localhost:8083/connectors/pg-sink/config \
  -H "Content-Type: application/json" \
  -d "$(cat connectors/pg-sink.json | jq '.config')" | jq .
```

### 검증

```bash
# MySQL에서 삭제
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "DELETE FROM users WHERE name='Charlie';"

# PostgreSQL에서 삭제 확인
docker exec postgres-sink psql -U postgres targetdb \
  -c "SELECT * FROM users;"
```

**결과**: Charlie가 PostgreSQL에서도 삭제됨

---

## 2. 스키마 변경 자동 반영 (auto.evolve)

### 목표
MySQL 테이블에 컬럼을 추가하면 PostgreSQL에도 자동으로 컬럼이 생성되는지 확인한다.

### 관련 설정

**connectors/pg-sink.json**
```json
"auto.evolve": "true"
```

`auto.evolve: true`로 설정돼 있으면 소스 스키마가 변경될 때 싱크 테이블도 자동으로 ALTER TABLE이 실행된다.

### 검증

```bash
# MySQL에 age 컬럼 추가
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "ALTER TABLE users ADD COLUMN age INT;"

# age 포함해서 INSERT
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "INSERT INTO users (name, email, age) VALUES ('Dave', 'dave@example.com', 30);"

# PostgreSQL에서 확인
docker exec postgres-sink psql -U postgres targetdb \
  -c "SELECT * FROM users;"
```

**결과**
- PostgreSQL `users` 테이블에 `age` 컬럼이 자동 생성됨
- Dave의 age=30이 정상 복제됨
- 기존 데이터(Alice, Bob)의 age는 NULL

---

## 3. 다중 테이블 CDC

### 목표
`users` 외에 `orders` 테이블도 CDC 파이프라인에 추가한다.

### 변경 내용

**mysql/init.sql** — orders 테이블 추가
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

### 실행 중인 MySQL에 테이블 추가

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

커넥터 설정 업데이트 후 REST API로 반영한다.

### 검증

```bash
# PostgreSQL에 orders 테이블 복제 확인
docker exec postgres-sink psql -U postgres targetdb \
  -c "SELECT * FROM orders;"

# 새 주문 INSERT
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "INSERT INTO orders (user_id, product, amount) VALUES (1, 'Keyboard', 3);"

# PostgreSQL에서 실시간 복제 확인
docker exec postgres-sink psql -U postgres targetdb \
  -c "SELECT * FROM orders;"
```

**결과**: Laptop, Mouse, Keyboard 모두 PostgreSQL에 복제됨

---

## 4. 장애 복구 테스트

### 목표
Kafka 브로커 1개가 다운되어도 파이프라인이 중단 없이 동작하는지 확인한다.

### 관련 설정

```yaml
# docker-compose.yml
KAFKA_MIN_INSYNC_REPLICAS: 2
KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
```

3브로커 중 1개가 죽어도 나머지 2개가 `MIN_INSYNC_REPLICAS: 2`를 만족하므로 쓰기/읽기가 유지된다.

### 검증 순서

```bash
# 1. 브로커 1개 중단
docker stop kafka-2

# 2. 브로커 다운 상태에서 데이터 INSERT
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "INSERT INTO orders (user_id, product, amount) VALUES (1, 'Monitor', 1);"

# 3. PostgreSQL에 복제됐는지 확인
docker exec postgres-sink psql -U postgres targetdb \
  -c "SELECT * FROM orders;"

# 4. 커넥터 상태 확인
curl -s http://localhost:8083/connectors/mysql-source/status | jq .

# 5. 브로커 복구
docker start kafka-2

# 6. 복구 후 상태 재확인
curl -s http://localhost:8083/connectors/mysql-source/status | jq .
```

**결과**
- kafka-2 중단 상태에서도 Monitor INSERT가 PostgreSQL에 즉시 복제됨
- 커넥터 상태 `RUNNING` 유지 (connect-1이 살아있는 브로커에 연결)
- kafka-2 재시작 후 자동으로 클러스터에 재합류하고 데이터 동기화
