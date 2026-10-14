#!/usr/bin/env bash

# ============================================================
# Native Central Observability Stack Installer
# Target OS: Ubuntu 24.04
#
# Components:
#   - Grafana
#   - Prometheus
#   - Node Exporter
#   - Loki
#   - Grafana Alloy
#   - Grafana Tempo
#
# Intended use:
#   - Lab
#   - POC
#   - Low-ingestion performance test
#
# No Docker is used.
# ============================================================

set -Eeuo pipefail


# ============================================================
# ROOT CHECK
# ============================================================

if [[ ${EUID} -ne 0 ]]; then
    echo "Run this installer with sudo:"
    echo
    echo "sudo ./install.sh"
    exit 1
fi


# Prevent apt from asking interactive questions.
export DEBIAN_FRONTEND=noninteractive


# ============================================================
# VARIABLES
# ============================================================

TEMPO_VERSION="${TEMPO_VERSION:-3.1.0}"

# Storage retention defaults suitable for the current VM.
LOKI_RETENTION="${LOKI_RETENTION:-72h}"

TEMPO_RETENTION="${TEMPO_RETENTION:-72h}"

PROMETHEUS_RETENTION_TIME="${PROMETHEUS_RETENTION_TIME:-7d}"

PROMETHEUS_RETENTION_SIZE="${PROMETHEUS_RETENTION_SIZE:-10GB}"


LOKI_DIR="/var/lib/loki"

TEMPO_DIR="/data/tempo"

TEMPO_RUNTIME_DIR="/var/tempo"

PROMETHEUS_FILE_SD_DIR="/etc/prometheus/file_sd"

PROMETHEUS_REMOTE_TARGETS_FILE="${PROMETHEUS_FILE_SD_DIR}/linux-nodes.yml"

ALLOY_OTLP_GRPC_PORT="4317"

ALLOY_OTLP_HTTP_PORT="4318"

TEMPO_INTERNAL_OTLP_HTTP_PORT="4320"

TEMPO_INTERNAL_OTLP_GRPC_PORT="4321"

INSTALL_LOG="/var/log/observability-install.log"


# ============================================================
# HELPER FUNCTIONS
# ============================================================

log() {
    printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}


warn() {
    printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2
}


fail() {
    printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
    exit 1
}


on_error() {
    local exit_code=$?
    local line_number="${1:-unknown}"

    echo
    echo "Installation failed."
    echo "Line: ${line_number}"
    echo "Exit code: ${exit_code}"
    echo
    echo "Review the installation log:"
    echo
    echo "less ${INSTALL_LOG}"
    echo
    echo "Check failed systemd services:"
    echo
    echo "systemctl --failed"
    echo
    echo "Useful troubleshooting commands:"
    echo
    echo "journalctl -u grafana-server -n 100 --no-pager"
    echo "journalctl -u prometheus -n 100 --no-pager"
    echo "journalctl -u prometheus-node-exporter -n 100 --no-pager"
    echo "journalctl -u loki -n 100 --no-pager"
    echo "journalctl -u tempo -n 100 --no-pager"
    echo "journalctl -u alloy -n 100 --no-pager"
    echo

    exit "$exit_code"
}


trap 'on_error $LINENO' ERR


wait_url() {
    local name="$1"
    local url="$2"
    local attempts="${3:-60}"
    local i

    for ((i=1; i<=attempts; i++)); do
        if curl \
            -fsS \
            --max-time 3 \
            "$url" \
            >/dev/null 2>&1; then

            echo "${name}: OK"
            return 0
        fi

        sleep 1
    done

    echo "${name}: NOT READY (${url})"
    return 1
}


backup_file() {
    local file="$1"

    if [[ -f "$file" && ! -f "${file}.original" ]]; then
        cp \
            -a \
            "$file" \
            "${file}.original"
    fi

    return 0
}


# ============================================================
# INSTALLATION LOG
# ============================================================

touch "$INSTALL_LOG"

chmod 0600 "$INSTALL_LOG"

exec > >(tee -a "$INSTALL_LOG") 2>&1


# ============================================================
# STEP 1 - VERIFY OPERATING SYSTEM
# ============================================================

log "Checking operating system"

[[ -r /etc/os-release ]] ||
    fail "/etc/os-release does not exist."

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] ||
    fail "This installer supports Ubuntu only."

echo "Detected operating system: ${PRETTY_NAME}"

echo "Detected architecture: $(dpkg --print-architecture)"

echo "Installation log: ${INSTALL_LOG}"

if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    warn "This installer was designed for Ubuntu 24.04."
    warn "Detected Ubuntu version: ${VERSION_ID:-unknown}"
fi


# ============================================================
# STEP 2 - CHECK SYSTEM RESOURCES
# ============================================================

log "Checking system resources"

CPU_COUNT="$(nproc)"

MEMORY_MB="$(
    awk '/MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo
)"

ROOT_FREE_MB="$(
    df --output=avail -BM / |
        tail -n 1 |
        tr -dc '0-9'
)"

echo "CPU count: ${CPU_COUNT}"

echo "Memory: ${MEMORY_MB} MB"

echo "Root filesystem available: ${ROOT_FREE_MB} MB"

if (( CPU_COUNT < 2 )); then
    warn "At least 2 CPU cores are recommended."
fi

if (( MEMORY_MB < 6000 )); then
    warn "At least 6 GB of RAM is recommended."
fi

if (( ROOT_FREE_MB < 20000 )); then
    fail "At least 20 GB of available root filesystem space is required."
fi


# ============================================================
# STEP 3 - CHECK NETWORK ACCESS
# ============================================================

log "Checking required network access"

curl \
    -fsSI \
    --max-time 20 \
    https://apt.grafana.com \
    >/dev/null ||
    fail "Cannot reach https://apt.grafana.com"

curl \
    -fsSI \
    --max-time 20 \
    https://github.com \
    >/dev/null ||
    fail "Cannot reach https://github.com"

echo "Grafana package repository: reachable"

echo "GitHub: reachable"


# ============================================================
# STEP 4 - INSTALL PREREQUISITES
# ============================================================

log "Installing prerequisites"

apt-get update

apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    wget


# ============================================================
# STEP 5 - ADD GRAFANA PACKAGE REPOSITORY
# ============================================================

log "Adding Grafana APT repository"

install \
    -d \
    -m 0755 \
    /etc/apt/keyrings

curl \
    -fsSL \
    https://apt.grafana.com/gpg-full.key \
    -o /etc/apt/keyrings/grafana.asc

chmod \
    0644 \
    /etc/apt/keyrings/grafana.asc

cat > /etc/apt/sources.list.d/grafana.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main
EOF

apt-get update


# Verify required packages are available.

for package in grafana loki alloy; do
    apt-cache show "$package" >/dev/null 2>&1 ||
        fail "Package was not found: ${package}"
done


# ============================================================
# STEP 6 - INSTALL CORE COMPONENTS
# ============================================================

log "Installing Grafana, Prometheus, Node Exporter, Loki and Alloy"

apt-get install -y \
    alloy \
    grafana \
    loki \
    prometheus \
    prometheus-node-exporter


# ============================================================
# STEP 7 - INSTALL TEMPO
# ============================================================

log "Installing Tempo ${TEMPO_VERSION}"

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64|arm64)
        ;;
    *)
        fail "Unsupported Tempo architecture: ${ARCH}"
        ;;
esac


if command -v tempo >/dev/null 2>&1 &&
   tempo --version 2>&1 |
       grep -q "${TEMPO_VERSION}"; then

    echo "Tempo ${TEMPO_VERSION} is already installed."

else
    TEMPO_DEB="/tmp/tempo_${TEMPO_VERSION}_linux_${ARCH}.deb"

    TEMPO_URL="https://github.com/grafana/tempo/releases/download/v${TEMPO_VERSION}/tempo_${TEMPO_VERSION}_linux_${ARCH}.deb"

    echo "Downloading Tempo:"
    echo
    echo "${TEMPO_URL}"
    echo

    curl \
        -fL \
        --retry 3 \
        --retry-delay 2 \
        "$TEMPO_URL" \
        -o "$TEMPO_DEB"

    apt-get install \
        -y \
        "$TEMPO_DEB"

    rm \
        -f \
        "$TEMPO_DEB"
fi


command -v tempo >/dev/null 2>&1 ||
    fail "Tempo executable was not installed."


# ============================================================
# STEP 8 - STOP SERVICES BEFORE CONFIGURATION
# ============================================================

log "Stopping observability services"

for service in \
    grafana-server \
    prometheus \
    prometheus-node-exporter \
    loki \
    alloy \
    tempo
do
    systemctl stop "$service" 2>/dev/null || true
done


# ============================================================
# STEP 9 - CONFIGURE PROMETHEUS
# ============================================================

log "Configuring Prometheus"

install \
    -d \
    -m 0755 \
    "$PROMETHEUS_FILE_SD_DIR"

backup_file /etc/prometheus/prometheus.yml


cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s

scrape_configs:

  - job_name: "prometheus"

    static_configs:
      - targets:
          - "127.0.0.1:9090"

        labels:
          environment: "observability"
          role: "prometheus"

  - job_name: "central-observability-node"

    static_configs:
      - targets:
          - "127.0.0.1:9100"

        labels:
          environment: "observability"
          role: "central-server"

  - job_name: "remote-linux-nodes"

    file_sd_configs:
      - files:
          - "/etc/prometheus/file_sd/linux-nodes.yml"

        refresh_interval: 30s
EOF


if [[ ! -f "$PROMETHEUS_REMOTE_TARGETS_FILE" ]]; then

    cat > "$PROMETHEUS_REMOTE_TARGETS_FILE" <<'EOF'
# Add remote Node Exporter endpoints here.
#
# Example:
#
# - targets:
#     - "172.17.80.221:9100"
#     - "172.17.80.223:9100"
#   labels:
#     environment: "test"
#     location: "azure"
#
[]
EOF

fi


chown \
    -R \
    prometheus:prometheus \
    "$PROMETHEUS_FILE_SD_DIR"

chmod \
    0755 \
    "$PROMETHEUS_FILE_SD_DIR"

chmod \
    0644 \
    "$PROMETHEUS_REMOTE_TARGETS_FILE"


promtool \
    check \
    config \
    /etc/prometheus/prometheus.yml


# ============================================================
# STEP 10 - LIMIT PROMETHEUS STORAGE
# ============================================================

log "Configuring Prometheus storage retention"

backup_file /etc/default/prometheus

cat > /etc/default/prometheus <<EOF
ARGS="--storage.tsdb.retention.time=${PROMETHEUS_RETENTION_TIME} --storage.tsdb.retention.size=${PROMETHEUS_RETENTION_SIZE}"
EOF

echo "Prometheus retention time: ${PROMETHEUS_RETENTION_TIME}"

echo "Prometheus maximum TSDB size: ${PROMETHEUS_RETENTION_SIZE}"


# ============================================================
# STEP 11 - CONFIGURE LOKI
# ============================================================

log "Configuring Loki"

install \
    -d \
    -m 0755 \
    "$LOKI_DIR/chunks" \
    "$LOKI_DIR/rules" \
    "$LOKI_DIR/compactor"

backup_file /etc/loki/config.yml


cat > /etc/loki/config.yml <<EOF
auth_enabled: false

server:

  http_listen_address: 0.0.0.0

  http_listen_port: 3100

  grpc_listen_address: 127.0.0.1

  grpc_listen_port: 9096

  log_level: warn

common:

  ring:

    instance_addr: 127.0.0.1

    kvstore:
      store: inmemory

  replication_factor: 1

  path_prefix: ${LOKI_DIR}

schema_config:

  configs:

    - from: 2024-01-01

      store: tsdb

      object_store: filesystem

      schema: v13

      index:
        prefix: index_
        period: 24h

storage_config:

  filesystem:
    directory: ${LOKI_DIR}/chunks

compactor:

  working_directory: ${LOKI_DIR}/compactor

  retention_enabled: true

  delete_request_store: filesystem

limits_config:

  retention_period: ${LOKI_RETENTION}

  allow_structured_metadata: true

analytics:

  reporting_enabled: false
EOF


if id loki >/dev/null 2>&1; then

    chown \
        -R \
        loki:"$(id -gn loki)" \
        "$LOKI_DIR"

fi


loki \
    -config.file=/etc/loki/config.yml \
    -verify-config=true

echo "Loki retention: ${LOKI_RETENTION}"


# ============================================================
# STEP 12 - CONFIGURE TEMPO
# ============================================================

log "Configuring Tempo"

install \
    -d \
    -m 0755 \
    /etc/tempo \
    "$TEMPO_DIR/wal" \
    "$TEMPO_DIR/blocks" \
    "$TEMPO_RUNTIME_DIR"

backup_file /etc/tempo/config.yml


cat > /etc/tempo/config.yml <<EOF
stream_over_http_enabled: true

server:

  http_listen_address: 127.0.0.1

  http_listen_port: 3200

  log_level: info

distributor:

  receivers:

    otlp:

      protocols:

        grpc:
          endpoint: "127.0.0.1:${TEMPO_INTERNAL_OTLP_GRPC_PORT}"

        http:
          endpoint: "127.0.0.1:${TEMPO_INTERNAL_OTLP_HTTP_PORT}"

storage:

  trace:

    backend: local

    wal:
      path: ${TEMPO_DIR}/wal

    local:
      path: ${TEMPO_DIR}/blocks

compactor:

  compaction:

    block_retention: ${TEMPO_RETENTION}

usage_report:

  reporting_enabled: false
EOF


if id tempo >/dev/null 2>&1; then

    chown \
        -R \
        tempo:"$(id -gn tempo)" \
        "$TEMPO_DIR" \
        "$TEMPO_RUNTIME_DIR"

fi


tempo \
    -config.file=/etc/tempo/config.yml \
    -config.verify

echo "Tempo retention: ${TEMPO_RETENTION}"


# ============================================================
# STEP 13 - CONFIGURE GRAFANA ALLOY
# ============================================================

log "Configuring Grafana Alloy"

usermod \
    -aG systemd-journal \
    alloy

backup_file /etc/alloy/config.alloy


cat > /etc/alloy/config.alloy <<EOF
//
// ==========================================================
// LOCAL LOG PIPELINE
// ==========================================================
//

loki.relabel "journal" {
  forward_to = []

  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }

  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "level"
  }

  rule {
    source_labels = ["__journal__hostname"]
    target_label  = "host"
  }
}

loki.source.journal "system_logs" {
  forward_to = [
    loki.write.local.receiver,
  ]

  relabel_rules = loki.relabel.journal.rules

  labels = {
    job         = "systemd-journal",
    environment = "observability",
  }
}

loki.write "local" {
  endpoint {
    url = "http://127.0.0.1:3100/loki/api/v1/push"
  }
}

//
// ==========================================================
// CENTRAL TRACE PIPELINE
// ==========================================================
//

otelcol.receiver.otlp "applications" {

  grpc {
    endpoint = "0.0.0.0:${ALLOY_OTLP_GRPC_PORT}"
  }

  http {
    endpoint = "0.0.0.0:${ALLOY_OTLP_HTTP_PORT}"
  }

  output {
    traces = [
      otelcol.processor.batch.traces.input,
    ]
  }
}

otelcol.processor.batch "traces" {

  timeout = "5s"

  send_batch_size = 1024

  output {
    traces = [
      otelcol.exporter.otlphttp.tempo.input,
    ]
  }
}

otelcol.exporter.otlphttp "tempo" {

  client {
    endpoint = "http://127.0.0.1:${TEMPO_INTERNAL_OTLP_HTTP_PORT}"
  }
}
EOF


alloy \
    validate \
    /etc/alloy/config.alloy


# ============================================================
# STEP 14 - CONFIGURE GRAFANA DATA SOURCES
# ============================================================

log "Provisioning Grafana data sources"

install \
    -d \
    -m 0755 \
    /etc/grafana/provisioning/datasources


cat > /etc/grafana/provisioning/datasources/observability.yml <<'EOF'
apiVersion: 1

deleteDatasources:

  - name: Prometheus
    orgId: 1

  - name: Loki
    orgId: 1

  - name: Tempo
    orgId: 1

datasources:

  - name: Prometheus

    uid: prometheus

    type: prometheus

    access: proxy

    url: http://127.0.0.1:9090

    isDefault: true

    editable: true

  - name: Loki

    uid: loki

    type: loki

    access: proxy

    url: http://127.0.0.1:3100

    editable: true

    jsonData:

      derivedFields:

        - datasourceUid: tempo

          matcherRegex: '(?:trace_id|traceID|traceid)[=:" ]+([a-fA-F0-9]{16,32})'

          name: TraceID

          url: '$${__value.raw}'

  - name: Tempo

    uid: tempo

    type: tempo

    access: proxy

    url: http://127.0.0.1:3200

    editable: true

    jsonData:

      tracesToLogsV2:

        datasourceUid: loki

        spanStartTimeShift: "-5m"

        spanEndTimeShift: "5m"

        filterByTraceID: true

        filterBySpanID: false

      tracesToMetrics:

        datasourceUid: prometheus

      serviceMap:

        datasourceUid: prometheus

      nodeGraph:

        enabled: true

      search:

        hide: false
EOF


chown \
    root:grafana \
    /etc/grafana/provisioning/datasources/observability.yml

chmod \
    0640 \
    /etc/grafana/provisioning/datasources/observability.yml


# ============================================================
# STEP 15 - CONFIGURE GRAFANA NETWORK LISTENER
# ============================================================

log "Configuring Grafana network listener"

backup_file /etc/grafana/grafana.ini


if grep \
    -Eq \
    '^[;[:space:]]*http_addr[[:space:]]*=' \
    /etc/grafana/grafana.ini; then

    sed \
        -i \
        's/^[;[:space:]]*http_addr[[:space:]]*=.*$/http_addr = 0.0.0.0/' \
        /etc/grafana/grafana.ini

else

    cat >> /etc/grafana/grafana.ini <<'EOF'

[server]
http_addr = 0.0.0.0
EOF

fi


if grep \
    -Eq \
    '^[;[:space:]]*http_port[[:space:]]*=' \
    /etc/grafana/grafana.ini; then

    sed \
        -i \
        's/^[;[:space:]]*http_port[[:space:]]*=.*$/http_port = 3000/' \
        /etc/grafana/grafana.ini

else

    cat >> /etc/grafana/grafana.ini <<'EOF'
http_port = 3000
EOF

fi


# ============================================================
# STEP 16 - LIMIT SYSTEMD JOURNAL STORAGE
# ============================================================

log "Limiting journald disk usage"

install \
    -d \
    -m 0755 \
    /etc/systemd/journald.conf.d


cat > /etc/systemd/journald.conf.d/observability.conf <<'EOF'
[Journal]

SystemMaxUse=1G

SystemKeepFree=5G

Compress=yes
EOF


systemctl \
    restart \
    systemd-journald


# ============================================================
# STEP 17 - CHECK LOCAL FIREWALL
# ============================================================

log "Checking local firewall"

if command -v ufw >/dev/null 2>&1; then

    UFW_STATUS="$(
        ufw status 2>/dev/null |
        head -n 1 ||
        true
    )"

    echo "UFW status: ${UFW_STATUS:-unknown}"

    if echo "$UFW_STATUS" |
       grep -qi "active"; then

        warn "UFW is active."

        warn "The installer will not modify company firewall policy."

        warn "Allow only approved sources to TCP 3000, 3100, 4317 and 4318."

    fi

else

    echo "UFW is not installed."

fi


cat <<'EOF'

Required inbound access to the central server:

TCP 3000:
    Grafana access from approved administrator networks.

TCP 3100:
    Loki ingestion from approved remote Alloy agents.

TCP 4317:
    OTLP/gRPC trace ingestion.

TCP 4318:
    OTLP/HTTP trace ingestion.

Required outbound access from the central server:

TCP 9100:
    Prometheus scraping Node Exporter on monitored VMs.

Do not expose observability ports directly to the public
internet.

Azure NSG rules and company network controls must also permit
the required traffic.

EOF


# ============================================================
# STEP 18 - ENABLE SERVICES
# ============================================================

log "Enabling observability services"

systemctl \
    daemon-reload


systemctl enable \
    prometheus-node-exporter \
    prometheus \
    loki \
    tempo \
    alloy \
    grafana-server


# ============================================================
# STEP 19 - START SERVICES
# ============================================================

log "Starting Node Exporter"

systemctl \
    restart \
    prometheus-node-exporter


log "Starting Prometheus"

systemctl \
    restart \
    prometheus


log "Starting Loki"

systemctl \
    restart \
    loki


wait_url \
    "Loki startup" \
    "http://127.0.0.1:3100/ready" \
    120 ||
    fail "Loki did not become ready within 120 seconds."


log "Starting Tempo"

systemctl \
    restart \
    tempo


wait_url \
    "Tempo startup" \
    "http://127.0.0.1:3200/ready" \
    120 ||
    fail "Tempo did not become ready within 120 seconds."


log "Starting Grafana Alloy"

systemctl \
    restart \
    alloy


log "Starting Grafana"

systemctl \
    restart \
    grafana-server


# ============================================================
# STEP 20 - VERIFY SERVICES
# ============================================================

log "Verifying systemd services"

SERVICES=(
    grafana-server
    prometheus
    prometheus-node-exporter
    loki
    alloy
    tempo
)

FAILED=0


for service in "${SERVICES[@]}"; do

    status="$(
        systemctl \
            is-active \
            "$service" \
            2>/dev/null ||
        true
    )"

    printf \
        '%-28s %s\n' \
        "$service" \
        "$status"

    if [[ "$status" != "active" ]]; then

        FAILED=1

        echo
        echo "Recent ${service} logs:"
        echo

        journalctl \
            -u "$service" \
            -n 30 \
            --no-pager ||
            true

        echo

    fi

done


# ============================================================
# STEP 21 - VERIFY HTTP ENDPOINTS
# ============================================================

log "Verifying endpoints"


wait_url \
    "Grafana" \
    "http://127.0.0.1:3000/api/health" \
    60 ||
    FAILED=1


wait_url \
    "Prometheus" \
    "http://127.0.0.1:9090/-/ready" \
    60 ||
    FAILED=1


wait_url \
    "Node Exporter" \
    "http://127.0.0.1:9100/metrics" \
    60 ||
    FAILED=1


wait_url \
    "Loki" \
    "http://127.0.0.1:3100/ready" \
    60 ||
    FAILED=1


wait_url \
    "Tempo" \
    "http://127.0.0.1:3200/ready" \
    60 ||
    FAILED=1


# ============================================================
# STEP 22 - DISPLAY LISTENING PORTS
# ============================================================

log "Listening ports"

ss \
    -ltnp |
    grep \
        -E \
        ':(3000|9090|9100|3100|3200|4317|4318|4320|4321)\b' ||
    true


# ============================================================
# STEP 23 - DISPLAY STORAGE USAGE
# ============================================================

log "Observability storage usage"

du \
    -sh \
    /var/lib/prometheus \
    /var/lib/loki \
    /data/tempo \
    /var/lib/grafana \
    2>/dev/null ||
    true

echo

df \
    -h \
    /


# ============================================================
# STEP 24 - DETERMINE CENTRAL VM IP
# ============================================================

PRIMARY_IP="$(
    hostname -I 2>/dev/null |
    awk '{print $1}'
)"

PRIMARY_IP="${PRIMARY_IP:-OBSERVABILITY_SERVER_IP}"


# ============================================================
# STEP 25 - PRINT COMPLETION INFORMATION
# ============================================================

cat <<EOF


============================================================
OBSERVABILITY STACK INSTALLATION FINISHED
============================================================

Central observability server:

    ${PRIMARY_IP}

No Docker was used.


------------------------------------------------------------
COMPONENT ENDPOINTS
------------------------------------------------------------

Grafana:

    http://${PRIMARY_IP}:3000

Prometheus:

    http://${PRIMARY_IP}:9090

Node Exporter:

    http://${PRIMARY_IP}:9100/metrics

Loki ingestion:

    http://${PRIMARY_IP}:3100/loki/api/v1/push

Tempo query API:

    http://127.0.0.1:3200

Alloy OTLP/gRPC:

    ${PRIMARY_IP}:${ALLOY_OTLP_GRPC_PORT}

Alloy OTLP/HTTP base endpoint:

    http://${PRIMARY_IP}:${ALLOY_OTLP_HTTP_PORT}

Alloy OTLP/HTTP trace endpoint:

    http://${PRIMARY_IP}:${ALLOY_OTLP_HTTP_PORT}/v1/traces


------------------------------------------------------------
RETENTION SETTINGS
------------------------------------------------------------

Prometheus retention time:

    ${PROMETHEUS_RETENTION_TIME}

Prometheus maximum storage:

    ${PROMETHEUS_RETENTION_SIZE}

Loki retention:

    ${LOKI_RETENTION}

Tempo retention:

    ${TEMPO_RETENTION}


------------------------------------------------------------
GRAFANA ACCESS
------------------------------------------------------------

Open Grafana from an approved workstation:

    http://${PRIMARY_IP}:3000

If the default credentials are still enabled:

    Username: admin
    Password: admin

Change the administrator password immediately.


------------------------------------------------------------
GRAFANA DATA SOURCES
------------------------------------------------------------

The following data sources were provisioned:

    Prometheus
    Loki
    Tempo


------------------------------------------------------------
PROMETHEUS REMOTE NODE CONFIGURATION
------------------------------------------------------------

Edit:

    ${PROMETHEUS_REMOTE_TARGETS_FILE}

Example:

    - targets:
        - "172.17.80.221:9100"
        - "172.17.80.223:9100"
      labels:
        environment: "test"
        location: "azure"

Prometheus automatically detects changes to the file.

Verify remote targets at:

    http://${PRIMARY_IP}:9090/targets


------------------------------------------------------------
REMOTE LOG INGESTION
------------------------------------------------------------

Remote Alloy agents should send logs to:

    http://${PRIMARY_IP}:3100/loki/api/v1/push

Example Loki query:

    {job="systemd-journal"}


------------------------------------------------------------
REMOTE TRACE INGESTION
------------------------------------------------------------

OTLP/gRPC:

    ${PRIMARY_IP}:${ALLOY_OTLP_GRPC_PORT}

OTLP/HTTP:

    http://${PRIMARY_IP}:${ALLOY_OTLP_HTTP_PORT}/v1/traces


------------------------------------------------------------
NETWORK REQUIREMENTS
------------------------------------------------------------

Permit only approved source networks:

    TCP 3000 - Grafana users

    TCP 3100 - Remote Alloy log agents

    TCP 4317 - OTLP/gRPC clients

    TCP 4318 - OTLP/HTTP clients

Permit the central server to reach monitored VMs:

    TCP 9100 - Node Exporter

Do not expose these services directly to the public internet.


------------------------------------------------------------
USEFUL COMMANDS
------------------------------------------------------------

Check service status:

    systemctl status grafana-server

    systemctl status prometheus

    systemctl status prometheus-node-exporter

    systemctl status loki

    systemctl status tempo

    systemctl status alloy


Check failed services:

    systemctl --failed


View service logs:

    journalctl -u grafana-server -n 100 --no-pager

    journalctl -u prometheus -n 100 --no-pager

    journalctl -u prometheus-node-exporter -n 100 --no-pager

    journalctl -u loki -n 100 --no-pager

    journalctl -u tempo -n 100 --no-pager

    journalctl -u alloy -n 100 --no-pager


View installation log:

    less ${INSTALL_LOG}


Check storage growth:

    du -sh /var/lib/prometheus /var/lib/loki /data/tempo /var/lib/grafana

    df -h /


============================================================

EOF


# ============================================================
# FINAL RESULT
# ============================================================

if [[ "$FAILED" -ne 0 ]]; then

    echo
    echo "One or more verification checks failed."
    echo
    echo "Review the service logs displayed above."
    echo
    echo "Installation log:"
    echo
    echo "${INSTALL_LOG}"
    echo

    exit 1

fi


echo
echo "All observability services passed verification."
echo
echo "Installation completed successfully."
echo

exit 0
