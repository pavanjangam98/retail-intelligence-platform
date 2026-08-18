# Snowflake Kafka Connector — Complete End-to-End Guide

*Updated for Snowflake Connector for Kafka v4 (Snowpipe Streaming High-Performance Architecture), GA April 2026.*

---

## 1. What It Is & How It Works

The Snowflake Kafka Connector is a **Kafka Connect sink connector** — it runs inside a Kafka Connect cluster, subscribes to one or more Kafka topics, and streams the records into Snowflake tables. You don't write consumer code; you configure a JSON/properties file and Kafka Connect does the rest.

**Two live versions today:**

| Version | Status | Ingestion path | Notes |
|---|---|---|---|
| **v4.x** | GA, recommended for all new work | Snowpipe Streaming **High-Performance Architecture** (Rust SDK, server-side validation) | `connector.class = SnowflakeStreamingSinkConnector` |
| **v3.x / v2.x** | Still supported, being deprecated | Snowpipe Streaming "Classic" or file-based Snowpipe | Deprecation announcement expected mid-2026, then an 18-month migration window |

For any new project, use **v4**. This guide focuses on v4 but flags v3 differences where it matters.

### Architecture flow
1. Producers publish JSON or Avro records to a Kafka topic.
2. Kafka Connect (running the Snowflake sink connector) consumes those records.
3. The connector's Rust-based Snowpipe Streaming SDK buffers and streams rows directly into Snowflake — no intermediate files/stages needed in v4.
4. Per topic, the connector auto-creates: a target **table** (unless it already exists), and manages the streaming **channel/pipe** internally. Table/topic name mapping and column mapping happen automatically ("schematization").

---

## 2. Prerequisites

- **Snowflake side:** a database, schema, warehouse, and a dedicated role/user for the connector.
- **Kafka side:** Kafka Connect 3.9.0-tested (older versions fine, newer untested). Apache Kafka 2.8.2/3.7.2/4.1.1 or Confluent 6.2.15/7.8.2/8.2.0 are the tested combos.
- **JDK 11+** on every Kafka Connect worker node.
- Enough RAM per worker: ~5 MB per Kafka partition, *plus* — important for v4 — the Rust SDK uses **off-heap memory**, so cap the JVM heap (`-Xmx`) at roughly 50% of available RAM (e.g., `-Xmx4g` on an 8 GB box) and leave the rest for the SDK.
- Kafka Connect cluster ideally in the **same cloud region** as your Snowflake account (throughput/cost).
- **Key-pair authentication** — the connector does not use username/password.

---

## 3. Step 1 — Configure Snowflake (roles, privileges, user)

Run as `SECURITYADMIN` (or equivalent):

```sql
USE ROLE securityadmin;

-- Dedicated role for the connector
CREATE ROLE kafka_connector_role;

-- Database / schema access
GRANT USAGE ON DATABASE kafka_db TO ROLE kafka_connector_role;
GRANT USAGE ON SCHEMA kafka_db.kafka_schema TO ROLE kafka_connector_role;

-- Let it create tables/pipes automatically (skip if you pre-create objects)
GRANT CREATE TABLE ON SCHEMA kafka_db.kafka_schema TO ROLE kafka_connector_role;
GRANT CREATE PIPE  ON SCHEMA kafka_db.kafka_schema TO ROLE kafka_connector_role;

-- If you manually created the pipe yourself (user-defined pipe mode)
-- GRANT OPERATE ON PIPE kafka_db.kafka_schema.my_pipe TO ROLE kafka_connector_role;

-- If the target table already exists
-- GRANT INSERT ON TABLE kafka_db.kafka_schema.existing_table TO ROLE kafka_connector_role;

-- Dedicated service user
CREATE USER kafka_connector_user
  DEFAULT_ROLE = kafka_connector_role
  DEFAULT_WAREHOUSE = kafka_wh;

GRANT ROLE kafka_connector_role TO USER kafka_connector_user;
```

**Required privilege summary:**

| Object | Privilege | When |
|---|---|---|
| Database | USAGE | Always |
| Schema | USAGE | Always |
| Schema | CREATE TABLE | If connector auto-creates tables |
| Schema | CREATE PIPE | If connector auto-creates pipes |
| Pipe | OPERATE | If using user-defined pipes |
| Destination table | INSERT | Always |

⚠️ Grants must go **directly** to `kafka_connector_role` — they are not inherited through a role hierarchy.

### Key-pair authentication setup

```bash
# 1. Generate an unencrypted private key (or encrypted — see docs for the passphrase variant)
openssl genrsa -out rsa_key.pem 2048

# 2. Derive the public key
openssl rsa -in rsa_key.pem -pubout -out rsa_key.pub
```

Assign the public key to the Snowflake user (paste the key body only, no header/footer):

```sql
ALTER USER kafka_connector_user SET RSA_PUBLIC_KEY='MIIBIjANBgkqh...';
```

Verify:

```sql
DESC USER kafka_connector_user;  -- check RSA_PUBLIC_KEY_FP
```

Keep `rsa_key.pem` secure — you'll paste its contents (or reference it via a secrets manager) into the connector config as `snowflake.private.key`.

---

## 4. Step 2 — Install Kafka Connect + the Connector

### Apache Kafka (OSS) route
```bash
# Download & unpack Kafka
tar xzvf kafka_2.13-3.7.2.tgz

# Download connector JAR + Bouncy Castle FIPS libs, drop them in <kafka_dir>/libs
# https://central.sonatype.com/artifact/com.snowflake/snowflake-kafka-connector
# https://central.sonatype.com/artifact/org.bouncycastle/bc-fips/2.1.0
# https://central.sonatype.com/artifact/org.bouncycastle/bcpkix-fips/2.1.8
```

### Confluent route
Install from Confluent Hub (`confluent-hub install snowflakeinc/snowflake-kafka-connector`) — the Confluent package bundles the crypto dependencies for you.

---

## 5. Step 3 — Configure the Connector

You can run **standalone** (single process, config = a `.properties` file) or **distributed** (config posted via REST to a Connect cluster). Distributed is what you'll use in production.

### Minimal working config (distributed mode, JSON, v4 defaults)

```json
{
  "name": "my_kafka_connector",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector",
    "topics": "orders_topic",
    "snowflake.url.name": "https://myorg-myaccount.snowflakecomputing.com",
    "snowflake.user.name": "kafka_connector_user",
    "snowflake.private.key": "<contents of rsa_key.pem, header/footer removed, no line breaks>",
    "snowflake.database.name": "KAFKA_DB",
    "snowflake.schema.name": "KAFKA_SCHEMA",
    "snowflake.role.name": "KAFKA_CONNECTOR_ROLE",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "snowflake.streaming.validate.compatibility.with.classic": "false",
    "tasks.max": "3"
  }
}
```

Key points:
- `snowflake.streaming.validate.compatibility.with.classic: false` — set this for **fresh** installs (it's only relevant when migrating from v3).
- `snowflake.enable.schematization` defaults to `true` in v4 — records land in real, named columns instead of a single `RECORD_CONTENT` VARIANT (that VARIANT-wrapping behavior is opt-in via `false`, matching old v3 behavior).
- Use `snowflake.topic2table.map` if your table name should differ from the topic name, e.g. `"topic1:orders_fact,topic2:customers_dim"`.
- For Avro + Schema Registry, swap `value.converter` to `io.confluent.connect.avro.AvroConverter` and set `value.converter.schema.registry.url`.

### Starting it

**Distributed mode:**
```bash
curl -X POST -H "Content-Type: application/json" \
  --data @connector-config.json \
  http://localhost:8083/connectors
```

**Standalone mode:**
```bash
<kafka_dir>/bin/connect-standalone.sh \
  <kafka_dir>/config/connect-standalone.properties \
  <kafka_dir>/config/SF_connect.properties
```

---

## 6. Worked Example — End-to-End Local Project (Docker Compose)

A self-contained sandbox: Kafka broker + Kafka Connect (with the Snowflake connector pre-loaded) + a producer script, all wired to a real Snowflake account.

**`docker-compose.yml`**
```yaml
version: "3.8"
services:
  zookeeper:
    image: confluentinc/cp-zookeeper:7.6.0
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181

  kafka:
    image: confluentinc/cp-kafka:7.6.0
    depends_on: [zookeeper]
    ports: ["9092:9092"]
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:29092,PLAINTEXT_HOST://localhost:9092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1

  connect:
    image: confluentinc/cp-kafka-connect:7.6.0
    depends_on: [kafka]
    ports: ["8083:8083"]
    volumes:
      - ./connect-plugins:/usr/share/confluent-hub-components/snowflake
    environment:
      CONNECT_BOOTSTRAP_SERVERS: kafka:29092
      CONNECT_REST_PORT: 8083
      CONNECT_GROUP_ID: sf-connect-cluster
      CONNECT_CONFIG_STORAGE_TOPIC: _connect-configs
      CONNECT_OFFSET_STORAGE_TOPIC: _connect-offsets
      CONNECT_STATUS_STORAGE_TOPIC: _connect-status
      CONNECT_KEY_CONVERTER: org.apache.kafka.connect.storage.StringConverter
      CONNECT_VALUE_CONVERTER: org.apache.kafka.connect.json.JsonConverter
      CONNECT_PLUGIN_PATH: /usr/share/java,/usr/share/confluent-hub-components
```

`./connect-plugins/` = folder where you drop the Snowflake connector JAR + Bouncy Castle JARs before `docker compose up`.

**Register the connector** (`orders-connector.json`, same body as section 5), then:
```bash
curl -X POST -H "Content-Type: application/json" \
  --data @orders-connector.json http://localhost:8083/connectors
```

**Produce a few test records:**
```bash
docker exec -it <kafka_container> kafka-console-producer \
  --broker-list localhost:9092 --topic orders_topic
```
Paste JSON lines like:
```json
{"order_id": 1001, "customer": "Asha Rao", "amount": 249.50, "status": "PLACED"}
{"order_id": 1002, "customer": "Vikram Shah", "amount": 89.00, "status": "SHIPPED"}
```

**Check connector health:**
```bash
curl http://localhost:8083/connectors/my_kafka_connector/status
```

**Verify in Snowflake:**
```sql
SELECT * FROM KAFKA_DB.KAFKA_SCHEMA.ORDERS_TOPIC ORDER BY 1;
```
You should see rows with real columns (`ORDER_ID`, `CUSTOMER`, `AMOUNT`, `STATUS`) because schematization is on by default in v4, plus a `RECORD_METADATA` column with offset/partition/topic/timestamp info.

---

## 7. Error Handling & Validation

- `snowflake.validation` — `server_side` (default, Snowflake validates like COPY/Snowpipe, bad rows land in an **Error Table**) vs `client_side` (connector validates before sending, supports a Dead Letter Queue).
- `errors.tolerance` — `none` (default, task fails fast) or `all` (keep going; pair this with `errors.deadletterqueue.topic.name` under client-side validation, or you'll silently lose bad records).
- `errors.log.enable=true` is worth turning on while you're building/debugging.

---

## 8. Monitoring

- JMX metrics are on by default (`jmx=true`) — hook up Prometheus/Grafana via a JMX exporter for lag, buffer, and throughput metrics.
- `enable.mdc.logging=true` is useful once you're running several connectors on the same workers, so log lines are tagged per-connector.
- Watch `RECORD_METADATA:SnowflakeConnectorPushTime` (on by default) to estimate end-to-end latency from Kafka to Snowflake.

---

## 9. Common Gotchas (Learning Notes)

1. **Table names & case** — in v4, table/column names preserve case as-is by default (quoted identifiers). If you want classic v3-style uppercase/sanitized names, explicitly set the `snowflake.compatibility.enable.*` properties — don't assume v3 behavior by default anymore.
2. **StringConverter/ByteArrayConverter + schematization** — these aren't supported as `value.converter` when `snowflake.enable.schematization=true` (the default). Use `JsonConverter` or `AvroConverter`.
3. **Caching during dev** — the connector caches table/pipe existence checks for 5 minutes by default. If you manually create a table while testing, you may not see it picked up immediately; set `snowflake.cache.table.exists=false` and `snowflake.cache.pipe.exists=false` **only for local testing**, never in production (it adds metadata-query overhead at scale).
4. **Memory tuning matters more in v4** — because of the off-heap Rust SDK, an over-large `-Xmx` starves the SDK and can cause instability. Budget ~50% of worker RAM to heap, 50% to the SDK.
5. **One database+schema per connector config** — a single connector can read many topics, but all target tables must live in one database/schema. Use multiple connector configs for multiple schemas.
6. **Migrating from v3?** Don't just copy the v3 config forward — review `snowflake.streaming.classic.offset.migration`, `snowflake.enable.schematization`, and the two `snowflake.compatibility.*` flags first, or you'll get silently different table/column naming. Snowflake's own migration guide walks through this ("Migrate from Kafka connector v3 to v4").

---

## 10. Suggested Learning Path

1. Stand up the Docker Compose sandbox above and get one topic flowing end to end.
2. Switch the payload to Avro + a local Schema Registry to see schema evolution in action.
3. Deliberately publish a malformed record and observe Error Table / DLQ behavior under both `server_side` and `client_side` validation.
4. Move to distributed mode with `tasks.max` tuned to partition count, and load-test throughput.
5. Read Snowflake's own **"Working with the Snowflake Connector for Kafka"** and **"Monitor the Snowflake Connector for Kafka"** docs for deeper internals once the basics feel solid.

---

### Key reference pages
- Overview: `docs.snowflake.com/en/user-guide/kafka-connector-overview`
- Configure Snowflake: `docs.snowflake.com/en/user-guide/kafka-connector/setup-snowflake`
- Install & configure connector: `docs.snowflake.com/en/user-guide/kafka-connector/setup-kafka`
- v3→v4 migration: `docs.snowflake.com/en/user-guide/kafka-connector/migrate-v3-to-v4`
