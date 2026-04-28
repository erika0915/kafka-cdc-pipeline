# Kafka CDC Pipeline - AWS Deployment Guide

A guide to deploying the CDC pipeline built locally to an AWS EC2 + RDS environment.

---

## Overall Architecture

```
Internet
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

- EC2 is in a Public Subnet → accessible from the internet (SSH, Kafka UI)
- RDS is in a Private Subnet → not directly accessible from the internet, only reachable from EC2
- Two Private Subnets are required because RDS subnet groups need at least 2 AZs

---

## Step 1: Create VPC

**AWS Console → VPC → Create VPC**

| Field | Value |
|---|---|
| Name | cdc-vpc |
| IPv4 CIDR | 10.0.0.0/16 |
| Others | Default |

---

## Step 2: Create 3 Subnets

**VPC → Subnets → Create Subnet**

| Name | VPC | Availability Zone | IPv4 CIDR |
|---|---|---|---|
| cdc-public-subnet | cdc-vpc | ap-northeast-2a | 10.0.1.0/24 |
| cdc-private-subnet-1 | cdc-vpc | ap-northeast-2a | 10.0.2.0/24 |
| cdc-private-subnet-2 | cdc-vpc | ap-northeast-2c | 10.0.3.0/24 |

---

## Step 3: Create and Attach Internet Gateway

**VPC → Internet Gateways → Create**

| Field | Value |
|---|---|
| Name | cdc-igw |

After creation → Attach to VPC → select cdc-vpc

> Without an IGW, EC2 cannot reach the internet and Docker image pulls will fail

---

## Step 4: Configure Route Tables

### Public Route Table (for EC2)

Select the default route table auto-created with the VPC → rename to `cdc-public-rt`

Edit routes → Add route:

| Destination | Target |
|---|---|
| 0.0.0.0/0 | cdc-igw |

Subnet associations → associate `cdc-public-subnet`

### Private Route Table (for RDS)

Create route table:

| Field | Value |
|---|---|
| Name | cdc-private-rt |
| VPC | cdc-vpc |
| Routes | Keep default (local traffic only) |

Subnet associations → associate `cdc-private-subnet-1`, `cdc-private-subnet-2`

---

## Step 5: Create 3 Security Groups

**VPC → Security Groups → Create Security Group**

### For EC2 (cdc-ec2-sg)

| Type | Protocol | Port | Source |
|---|---|---|---|
| SSH | TCP | 22 | My IP |
| Custom | TCP | 8088 | My IP (Kafka UI) |
| Custom | TCP | 8083 | My IP (Connect API) |

### For RDS MySQL (cdc-rds-mysql-sg)

| Type | Protocol | Port | Source |
|---|---|---|---|
| MySQL/Aurora | TCP | 3306 | cdc-ec2-sg |

> Using SG as source instead of IP → only EC2 can access

### For RDS PostgreSQL (cdc-rds-pg-sg)

| Type | Protocol | Port | Source |
|---|---|---|---|
| PostgreSQL | TCP | 5432 | cdc-ec2-sg |

---

## Step 6: Create EC2 Instance

**EC2 → Instances → Launch Instance**

| Field | Value |
|---|---|
| Name | cdc-ec2 |
| AMI | Ubuntu Server 24.04 LTS |
| Instance Type | t3.xlarge (vCPU 4, RAM 16GB) |
| Key Pair | cdc-key (RSA, .pem) |
| VPC | cdc-vpc |
| Subnet | cdc-public-subnet |
| Auto-assign Public IP | Enable |
| Security Group | cdc-ec2-sg |
| Storage | 30GB |

### Why t3.xlarge?

| Type | vCPU | RAM | Notes |
|---|---|---|---|
| t3.medium | 2 | 4GB | Not enough |
| t3.xlarge | 4 | 16GB | Minimum |
| t3.2xlarge | 8 | 32GB | Comfortable |

Estimated memory usage:

```
kafka-1,2,3     : 1GB × 3 = 3GB  (tunable via KAFKA_HEAP_OPTS)
connect-1,2,3   : 1GB × 3 = 3GB
schema-registry :           512MB
kafka-ui        :           512MB
─────────────────────────────────
Total                       ~7GB
```

Setting `KAFKA_HEAP_OPTS: "-Xms1g -Xmx1g"` makes t3.xlarge sufficient.

### Elastic IP (Optional)

To prevent the public IP from changing on restart:

EC2 → Elastic IPs → Allocate → Associate with cdc-ec2

> Free while the instance is running; charged when associated with a stopped instance

---

## Step 7: Connect to EC2 and Install Docker

```bash
# Set key file permissions locally
chmod 400 cdc-key.pem

# SSH into EC2
ssh -i cdc-key.pem ubuntu@<EC2-PUBLIC-IP>
```

Install Docker:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo usermod -aG docker ubuntu

# Reconnect to apply group
exit
ssh -i cdc-key.pem ubuntu@<EC2-PUBLIC-IP>

# Verify
docker --version
docker compose version
```

---

## Step 8: Create RDS MySQL

**RDS → Create Database**

| Field | Value |
|---|---|
| Engine | MySQL 8.0 |
| Template | Free Tier |
| DB Instance Identifier | cdc-mysql |
| Master Username | admin |
| Master Password | set your own |
| Instance Class | db.t3.micro |
| VPC | cdc-vpc |
| Subnet Group | Create new → cdc-private-subnet-1, cdc-private-subnet-2 |
| Public Access | No |
| Security Group | cdc-rds-mysql-sg |
| Initial Database Name | testdb |

### Parameter Group Setup (Required for Debezium)

RDS → Parameter Groups → Create Parameter Group:

| Field | Value |
|---|---|
| Family | mysql8.0 |
| Name | cdc-mysql-pg |

Edit parameters:

| Parameter | Value | Reason |
|---|---|---|
| `binlog_format` | ROW | Required for Debezium to read row-level changes |
| `binlog_row_image` | FULL | Records full before/after row state |
| `log_bin_trust_function_creators` | 1 | Prevents binlog errors with functions/triggers |

After saving → attach to cdc-mysql instance → **reboot required**

### Create Debezium User

Connect to RDS MySQL from EC2:

```bash
mysql -h <RDS-MySQL-ENDPOINT> -u admin -p
```

```sql
CREATE USER 'debezium'@'%' IDENTIFIED BY 'debezium_password';
GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'debezium'@'%';
FLUSH PRIVILEGES;
```

### Create Tables

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

## Step 9: Create RDS PostgreSQL

**RDS → Create Database**

| Field | Value |
|---|---|
| Engine | PostgreSQL 15 |
| Template | Free Tier |
| DB Instance Identifier | cdc-postgres |
| Master Username | postgres |
| Master Password | set your own |
| Instance Class | db.t3.micro |
| VPC | cdc-vpc |
| Subnet Group | reuse from above |
| Public Access | No |
| Security Group | cdc-rds-pg-sg |
| Initial Database Name | targetdb |

> No additional parameter group needed for PostgreSQL. The JDBC Sink connector creates tables automatically via `auto.create: true`

---

## Step 10: Deploy the Project

### Clone the project on EC2

```bash
git clone https://github.com/erika0915/kafka-cdc-pipeline.git
cd kafka-cdc-pipeline
```

### Create .env

Set the RDS endpoints and EC2 public IP.

```bash
cat > .env << 'EOF'
CLUSTER_ID=MkU3OEVBNTcwNTJENDM2Qg

MYSQL_SOURCE_HOST=<RDS-MySQL-ENDPOINT>
MYSQL_SOURCE_PORT=3306
MYSQL_SOURCE_USER=debezium
MYSQL_SOURCE_PASSWORD=debezium

PG_SINK_URL=jdbc:postgresql://<RDS-PostgreSQL-ENDPOINT>:5432/targetdb
PG_SINK_USER=postgres
PG_SINK_PASSWORD=<your-password>

EC2_PUBLIC_IP=<EC2-PUBLIC-IP>
EOF
```

> `docker-compose.prod.yml` references `${EC2_PUBLIC_IP}` to automatically configure Kafka `ADVERTISED_LISTENERS`.

### Start the stack

Use the production compose file which excludes local DB services and uses RDS instead.

```bash
docker compose -f docker-compose.prod.yml up -d --build
```

Build takes 5–10 minutes on first run.

### Register connectors

```bash
./register-connectors.sh
```

### Verify connector status

```bash
curl -s http://localhost:8083/connectors/mysql-source/status | jq .
curl -s http://localhost:8083/connectors/pg-sink/status | jq .
```

Both connectors should show `"state": "RUNNING"` when deployment is complete.

---

## Step 11: Troubleshooting

### mysql-source Task FAILED — Missing LOCK TABLES Privilege

**Error message**
```
User does not have the 'LOCK TABLES' privilege required to obtain a consistent snapshot
```

**Cause**: Debezium requires table locking during the initial snapshot, but the debezium user lacks this privilege on RDS.

**Fix**
```bash
mysql -h <RDS-MySQL-ENDPOINT> -u admin -p
```
```sql
GRANT LOCK TABLES ON *.* TO 'debezium'@'%';
FLUSH PRIVILEGES;
```

Restart the task after granting the privilege:
```bash
curl -s -X POST http://localhost:8083/connectors/mysql-source/tasks/0/restart
curl -s http://localhost:8083/connectors/mysql-source/status | jq .
```

---

## Step 12: Verify the Pipeline

### Insert data into RDS MySQL

```bash
mysql -h <RDS-MySQL-ENDPOINT> -u admin -p testdb \
  -e "INSERT INTO users (name, email) VALUES ('Charlie', 'charlie@example.com');"
```

### Confirm replication in RDS PostgreSQL

```bash
# Install psql client if not available
sudo apt install -y postgresql-client

psql -h <RDS-PostgreSQL-ENDPOINT> -U postgres targetdb \
  -c "SELECT * FROM users;"
```

If Charlie appears in PostgreSQL, the AWS deployment is complete.

---

## Step 13: Access Kafka UI

If port 8088 is open in the EC2 security group (`cdc-ec2-sg`), Kafka UI is accessible from a browser.

```
http://<EC2-PUBLIC-IP>:8088
```

What you can monitor in Kafka UI:
- Topic list and messages (`cdc.testdb.users`, `cdc.testdb.orders`)
- Connector status
- Broker status
