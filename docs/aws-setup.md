# Kafka CDC Pipeline - AWS 배포 가이드

로컬 환경에서 구성한 CDC 파이프라인을 AWS EC2 + RDS 환경으로 배포하는 가이드입니다.

---

## 전체 아키텍처

```
인터넷
  │
  ▼
Internet Gateway (cdc-igw)
  │
  ▼
VPC (10.0.0.0/16)
  │
  ├─ Public Subnet (10.0.1.0/24) — ap-northeast-2a
  │   └─ EC2 (Kafka + Kafka Connect + Schema Registry + Kafka UI)
  │
  ├─ Private Subnet 1 (10.0.2.0/24) — ap-northeast-2a
  │   └─ RDS MySQL (Source)
  │
  └─ Private Subnet 2 (10.0.3.0/24) — ap-northeast-2c
      └─ RDS PostgreSQL (Sink)
```

- EC2는 Public Subnet → 인터넷 접근 가능 (SSH, Kafka UI)
- RDS는 Private Subnet → 인터넷 직접 접근 불가, EC2에서만 접근 가능
- Private Subnet이 2개인 이유: RDS 서브넷 그룹 생성 시 최소 2개 AZ 필요

---

## 1단계: VPC 생성

**AWS 콘솔 → VPC → VPC 생성**

| 항목 | 값 |
|---|---|
| 이름 | cdc-vpc |
| IPv4 CIDR | 10.0.0.0/16 |
| 나머지 | 기본값 |

---

## 2단계: 서브넷 3개 생성

**VPC → 서브넷 → 서브넷 생성**

| 이름 | VPC | 가용 영역 | IPv4 CIDR |
|---|---|---|---|
| cdc-public-subnet | cdc-vpc | ap-northeast-2a | 10.0.1.0/24 |
| cdc-private-subnet-1 | cdc-vpc | ap-northeast-2a | 10.0.2.0/24 |
| cdc-private-subnet-2 | cdc-vpc | ap-northeast-2c | 10.0.3.0/24 |

---

## 3단계: Internet Gateway 생성 및 연결

**VPC → 인터넷 게이트웨이 → 생성**

| 항목 | 값 |
|---|---|
| 이름 | cdc-igw |

생성 후 → VPC에 연결 → cdc-vpc 선택

> IGW가 없으면 EC2가 인터넷에 연결되지 않아 Docker 이미지 pull도 불가

---

## 4단계: 라우팅 테이블 설정

### Public Route Table (EC2용)

VPC 생성 시 자동 생성된 기본 라우팅 테이블 선택 → 이름 변경: `cdc-public-rt`

라우팅 편집 → 라우팅 추가:

| 대상 | 타깃 |
|---|---|
| 0.0.0.0/0 | cdc-igw |

서브넷 연결 → `cdc-public-subnet` 연결

### Private Route Table (RDS용)

라우팅 테이블 생성:

| 항목 | 값 |
|---|---|
| 이름 | cdc-private-rt |
| VPC | cdc-vpc |
| 라우팅 | 기본값 유지 (로컬 통신만) |

서브넷 연결 → `cdc-private-subnet-1`, `cdc-private-subnet-2` 연결

---

## 5단계: 보안 그룹 3개 생성

**VPC → 보안 그룹 → 보안 그룹 생성**

### EC2용 (cdc-ec2-sg)

| 유형 | 프로토콜 | 포트 | 소스 |
|---|---|---|---|
| SSH | TCP | 22 | 내 IP |
| 사용자 지정 | TCP | 8088 | 내 IP (Kafka UI) |
| 사용자 지정 | TCP | 8083 | 내 IP (Connect API) |

### RDS MySQL용 (cdc-rds-mysql-sg)

| 유형 | 프로토콜 | 포트 | 소스 |
|---|---|---|---|
| MySQL/Aurora | TCP | 3306 | cdc-ec2-sg |

> IP가 아닌 SG를 소스로 지정 → EC2에서만 접근 가능

### RDS PostgreSQL용 (cdc-rds-pg-sg)

| 유형 | 프로토콜 | 포트 | 소스 |
|---|---|---|---|
| PostgreSQL | TCP | 5432 | cdc-ec2-sg |

---

## 6단계: EC2 생성

**EC2 → 인스턴스 → 인스턴스 시작**

| 항목 | 값 |
|---|---|
| 이름 | cdc-ec2 |
| AMI | Ubuntu Server 24.04 LTS |
| 인스턴스 유형 | t3.xlarge (vCPU 4, RAM 16GB) |
| 키 페어 | cdc-key (RSA, .pem) |
| VPC | cdc-vpc |
| 서브넷 | cdc-public-subnet |
| 퍼블릭 IP 자동 할당 | 활성화 |
| 보안 그룹 | cdc-ec2-sg |
| 스토리지 | 30GB |

### 인스턴스 타입 선택 이유

| 타입 | vCPU | RAM | 비고 |
|---|---|---|---|
| t3.medium | 2 | 4GB | 불가 |
| t3.xlarge | 4 | 16GB | 최소 사양 |
| t3.2xlarge | 8 | 32GB | 여유있게 |

서비스별 메모리 사용량 기준:

```
kafka-1,2,3     : 1GB × 3 = 3GB  (KAFKA_HEAP_OPTS로 조정)
connect-1,2,3   : 1GB × 3 = 3GB
schema-registry :           512MB
kafka-ui        :           512MB
─────────────────────────────────
합계                        ~7GB
```

`KAFKA_HEAP_OPTS: "-Xms1g -Xmx1g"` 로 낮추면 t3.xlarge로 충분

### Elastic IP 연결 (선택)

EC2 재시작 시 퍼블릭 IP가 바뀌는 것을 방지하려면:

EC2 → 탄력적 IP → 탄력적 IP 주소 할당 → cdc-ec2에 연결

> 인스턴스 실행 중에는 무료, 중지 상태에서 연결 시 과금

---

## 7단계: EC2 접속 및 Docker 설치

```bash
# 로컬에서 키 파일 권한 설정
chmod 400 cdc-key.pem

# SSH 접속
ssh -i cdc-key.pem ubuntu@<EC2-퍼블릭-IP>
```

접속 후 Docker 설치:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo usermod -aG docker ubuntu

# 재접속 (그룹 적용)
exit
ssh -i cdc-key.pem ubuntu@<EC2-퍼블릭-IP>

# 확인
docker --version
docker compose version
```

---

## 8단계: RDS MySQL 생성

**RDS → 데이터베이스 생성**

| 항목 | 값 |
|---|---|
| 엔진 | MySQL 8.0 |
| 템플릿 | 프리 티어 |
| DB 인스턴스 식별자 | cdc-mysql |
| 마스터 사용자 | admin |
| 마스터 암호 | 직접 설정 |
| 인스턴스 클래스 | db.t3.micro |
| VPC | cdc-vpc |
| 서브넷 그룹 | 새로 생성 → cdc-private-subnet-1, cdc-private-subnet-2 |
| 퍼블릭 액세스 | 아니요 |
| 보안 그룹 | cdc-rds-mysql-sg |
| 초기 데이터베이스 이름 | testdb |

### 파라미터 그룹 설정 (Debezium용 필수)

RDS → 파라미터 그룹 → 파라미터 그룹 생성:

| 항목 | 값 |
|---|---|
| 그룹 패밀리 | mysql8.0 |
| 이름 | cdc-mysql-pg |

생성 후 파라미터 편집:

| 파라미터 | 값 | 이유 |
|---|---|---|
| `binlog_format` | ROW | Debezium이 행 단위 변경사항을 읽기 위해 필요 |
| `binlog_row_image` | FULL | before/after 전체 행을 기록 |
| `log_bin_trust_function_creators` | 1 | 함수/트리거 사용 시 binlog 오류 방지 |

파라미터 그룹 저장 후 → cdc-mysql 인스턴스에 연결 → **재부팅 필요**

### Debezium 전용 계정 생성

RDS MySQL에 접속 후 (EC2에서):

```bash
mysql -h <RDS-MySQL-엔드포인트> -u admin -p
```

```sql
CREATE USER 'debezium'@'%' IDENTIFIED BY 'debezium_password';
GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'debezium'@'%';
FLUSH PRIVILEGES;
```

### users, orders 테이블 생성

```sql
USE testdb;

CREATE TABLE users (
  id         INT PRIMARY KEY AUTO_INCREMENT,
  name       VARCHAR(100) NOT NULL,
  email      VARCHAR(100),
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE orders (
  id         INT PRIMARY KEY AUTO_INCREMENT,
  user_id    INT NOT NULL,
  product    VARCHAR(100) NOT NULL,
  amount     INT NOT NULL,
  ordered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com'), ('Bob', 'bob@example.com');
INSERT INTO orders (user_id, product, amount) VALUES (1, 'Laptop', 1), (2, 'Mouse', 2);
```

---

## 9단계: RDS PostgreSQL 생성

**RDS → 데이터베이스 생성**

| 항목 | 값 |
|---|---|
| 엔진 | PostgreSQL 15 |
| 템플릿 | 프리 티어 |
| DB 인스턴스 식별자 | cdc-postgres |
| 마스터 사용자 | postgres |
| 마스터 암호 | 직접 설정 |
| 인스턴스 클래스 | db.t3.micro |
| VPC | cdc-vpc |
| 서브넷 그룹 | 위에서 만든 것 재사용 |
| 퍼블릭 액세스 | 아니요 |
| 보안 그룹 | cdc-rds-pg-sg |
| 초기 데이터베이스 이름 | targetdb |

> PostgreSQL은 파라미터 그룹 별도 설정 불필요. JDBC Sink가 자동으로 테이블을 생성함 (`auto.create: true`)

---

## 10단계: 프로젝트 배포

### EC2에서 프로젝트 클론

```bash
git clone https://github.com/erika0915/kafka-cdc-pipeline.git
cd kafka-cdc-pipeline
```

### .env 작성

RDS 환경변수와 EC2 퍼블릭 IP를 설정한다.

```bash
cat > .env << 'EOF'
CLUSTER_ID=MkU3OEVBNTcwNTJENDM2Qg

MYSQL_SOURCE_HOST=<RDS-MySQL-엔드포인트>
MYSQL_SOURCE_PORT=3306
MYSQL_SOURCE_USER=debezium
MYSQL_SOURCE_PASSWORD=debezium

PG_SINK_URL=jdbc:postgresql://<RDS-PostgreSQL-엔드포인트>:5432/targetdb
PG_SINK_USER=postgres
PG_SINK_PASSWORD=<설정한 암호>

EC2_PUBLIC_IP=<EC2-퍼블릭-IP>
EOF
```

> `docker-compose.prod.yml`은 `${EC2_PUBLIC_IP}`를 참조해 Kafka `ADVERTISED_LISTENERS`를 자동 설정한다.

### 실행

로컬 DB 없이 RDS만 사용하는 배포용 compose 파일로 실행한다.

```bash
docker compose -f docker-compose.prod.yml up -d --build
```

빌드 완료까지 5~10분 소요된다.

### 커넥터 등록

```bash
./register-connectors.sh
```

### 상태 확인

```bash
curl -s http://localhost:8083/connectors/mysql-source/status | jq .
curl -s http://localhost:8083/connectors/pg-sink/status | jq .
```

둘 다 `"state": "RUNNING"` 이면 배포 완료.

---

## 11단계: 트러블슈팅

### mysql-source 태스크 FAILED — LOCK TABLES 권한 없음

**에러 메시지**
```
User does not have the 'LOCK TABLES' privilege required to obtain a consistent snapshot
```

**원인**: Debezium이 스냅샷을 찍을 때 테이블 잠금이 필요한데 debezium 계정에 해당 권한이 없음

**해결**
```bash
mysql -h <RDS-MySQL-엔드포인트> -u admin -p
```
```sql
GRANT LOCK TABLES ON *.* TO 'debezium'@'%';
FLUSH PRIVILEGES;
```

권한 부여 후 태스크 재시작:
```bash
curl -s -X POST http://localhost:8083/connectors/mysql-source/tasks/0/restart
curl -s http://localhost:8083/connectors/mysql-source/status | jq .
```

---

## 12단계: 파이프라인 검증

### RDS MySQL에 데이터 INSERT

```bash
mysql -h <RDS-MySQL-엔드포인트> -u admin -p testdb \
  -e "INSERT INTO users (name, email) VALUES ('Charlie', 'charlie@example.com');"
```

### RDS PostgreSQL에서 복제 확인

```bash
# psql 클라이언트 설치 (없는 경우)
sudo apt install -y postgresql-client

psql -h <RDS-PostgreSQL-엔드포인트> -U postgres targetdb \
  -c "SELECT * FROM users;"
```

Charlie가 PostgreSQL에 나타나면 AWS 배포 완전히 성공.

---

## 13단계: Kafka UI 접속

EC2 보안 그룹(`cdc-ec2-sg`)에 8088 포트가 열려 있으면 브라우저에서 접속 가능하다.

```
http://<EC2-퍼블릭-IP>:8088
```

Kafka UI에서 확인할 수 있는 것:
- 토픽 목록 및 메시지 (`cdc.testdb.users`, `cdc.testdb.orders`)
- 커넥터 상태
- 브로커 상태
