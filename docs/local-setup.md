# Kafka CDC Pipeline - 로컬 환경 구성 가이드

MySQL의 변경사항을 Kafka를 거쳐 PostgreSQL로 실시간 복제하는 CDC 파이프라인 로컬 구성 방법입니다.

---

## 아키텍처

```
MySQL (testdb.users)
    ↓ Debezium MySQL Source Connector (binlog 감지)
Kafka 3-broker Cluster (KRaft)
    ↓ JDBC Sink Connector
PostgreSQL (targetdb.users)
```

---

## 구성 요소

| 서비스 | 이미지 | 포트 | 역할 |
|---|---|---|---|
| mysql-source | mysql:8.0 | 3306 | 소스 DB, binlog 활성화 |
| postgres-sink | postgres:15 | 5432 | 싱크 DB |
| kafka-1/2/3 | apache/kafka:4.1.0 | 29092/39092/49092 | KRaft 모드 3브로커 클러스터 |
| schema-registry | confluentinc/cp-schema-registry:7.7.0 | 8081 | Avro 스키마 관리 |
| connect-1/2/3 | (로컬 빌드) | 8083/8084/8085 | Kafka Connect 3인스턴스 |
| kafka-ui | provectuslabs/kafka-ui | 8088 | 모니터링 UI |

---

## 사전 준비

- Docker Desktop 설치 및 실행
- `jq` 설치 (`brew install jq`)

---

## 실행 방법

### 1. 환경 변수 파일 생성

```bash
cp .env.example .env
```

`.env` 파일을 열어 각 항목을 실제 값으로 채운다.

### 2. 전체 스택 기동

```bash
docker compose up -d
```

컨테이너 상태 확인:

```bash
docker compose ps
```

모든 컨테이너가 `Up` 상태가 될 때까지 대기한다. Kafka Connect(`connect-1/2/3`)는 `healthy`가 되기까지 1~2분 소요된다.

### 3. 커넥터 등록

```bash
./register-connectors.sh
```

스크립트가 Kafka Connect 준비를 자동으로 감지한 후 두 커넥터를 순서대로 등록한다.

### 4. 커넥터 상태 확인

```bash
curl -s http://localhost:8083/connectors/mysql-source/status | jq .
curl -s http://localhost:8083/connectors/pg-sink/status | jq .
```

두 커넥터 모두 `"state": "RUNNING"` 이면 정상이다.

---

## 동작 확인

### MySQL에 데이터 삽입

```bash
docker exec -it mysql-source mysql -u appuser -papppassword testdb \
  -e "INSERT INTO users (name, email) VALUES ('Charlie', 'charlie@example.com');"
```

### PostgreSQL에서 복제 확인

```bash
docker exec -it postgres-sink psql -U postgres targetdb \
  -c "SELECT * FROM users;"
```

MySQL에 삽입한 데이터가 PostgreSQL에 나타나면 파이프라인이 정상 동작하는 것이다.

### Kafka 토픽 확인

브라우저에서 Kafka UI를 열어 `cdc.testdb.users` 토픽에 메시지가 쌓이는 것을 확인한다.

```
http://localhost:8088
```

---

## 커넥터 설명

### mysql-source

`testdb.users` 테이블의 binlog를 실시간으로 감지하여 `cdc.testdb.users` 토픽으로 발행한다.

- `snapshot.mode: initial` — 최초 실행 시 기존 데이터 전체를 스냅샷으로 복제
- `ExtractNewRecordState` 변환 — Debezium envelope을 제거하고 단순 레코드만 전달
- DELETE는 drop 처리

### pg-sink

`cdc.testdb.users` 토픽을 소비하여 PostgreSQL `users` 테이블에 upsert한다.

- `insert.mode: upsert` — PK 기준으로 없으면 INSERT, 있으면 UPDATE
- `auto.create: true` — 테이블이 없으면 자동 생성
- `RegexRouter` — 토픽명에서 테이블명(`users`) 추출

---

## 종료

```bash
docker compose down
```

데이터 볼륨까지 삭제하려면:

```bash
docker compose down -v
```
