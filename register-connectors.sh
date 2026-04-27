#!/bin/bash

CONNECT_URL="http://localhost:8083"

echo "Kafka Connect 준비 대기 중..."
until curl -s "$CONNECT_URL/connector-plugins" | grep -q "MySqlConnector"; do
  echo "  아직 미준비, 5초 후 재시도..."
  sleep 5
done
echo "Kafka Connect 준비 완료!"

echo ""
echo "mysql-source 커넥터 등록 중..."
curl -s -X POST "$CONNECT_URL/connectors" \
  -H "Content-Type: application/json" \
  -d @connectors/mysql-source.json | jq .

echo ""
echo "pg-sink 커넥터 등록 중..."
curl -s -X POST "$CONNECT_URL/connectors" \
  -H "Content-Type: application/json" \
  -d @connectors/pg-sink.json | jq .

echo ""
echo "등록된 커넥터 목록:"
curl -s "$CONNECT_URL/connectors" | jq .
