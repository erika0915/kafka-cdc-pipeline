FROM confluentinc/cp-kafka-connect:7.5.3
RUN confluent-hub install --no-prompt debezium/debezium-connector-mysql:2.4.2
RUN confluent-hub install --no-prompt confluentinc/kafka-connect-jdbc:10.7.3
RUN curl -L -o /usr/share/confluent-hub-components/confluentinc-kafka-connect-jdbc/lib/postgresql-42.7.2.jar \
    "https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.2/postgresql-42.7.2.jar"