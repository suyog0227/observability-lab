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
# Architecture:
#
# METRICS
# Node Exporter on VMs
#       |
#       v
# Central Prometheus
#       |
#       v
# Grafana
#
# LOGS
# systemd/journald on VMs
#       |
#       v
# Grafana Alloy on VMs
#       |
#       v
# Central Loki
#       |
#       v
# Grafana
#
# TRACES
# Applications
#       |
#       v
# OTLP
#       |
#       v
# Central Grafana Alloy
#       |
#       v
# Tempo
#       |
#       v
# Grafana
#
# No Docker is used.
# ============================================================


# ------------------------------------------------------------
# Exit immediately if:
#
# - a command fails
# - an undefined variable is used
# - a pipeline command fails
#
# ERR traps also propagate into functions and subshells.
# ------------------------------------------------------------

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


# ------------------------------------------------------------
# Print a section heading.
# ------------------------------------------------------------

log() {
    printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}


# ------------------------------------------------------------
# Print a warning.
# ------------------------------------------------------------

warn() {
    printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2
}


# ------------------------------------------------------------
# Print an error and exit.
# ------------------------------------------------------------

fail() {
    printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
    exit 1
}


# ------------------------------------------------------------
# Print useful information when an unexpected error occurs.
# ------------------------------------------------------------

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
    echo "Useful service troubleshooting commands:"
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


# ------------------------------------------------------------
# Wait for an HTTP endpoint to become ready.
#
# Arguments:
#
# $1 = friendly service name
# $2 = URL
# $3 = number of attempts
# ------------------------------------------------------------

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


# ------------------------------------------------------------
# Save all installer output while still showing it in the
# browser terminal.
# ------------------------------------------------------------

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
    warn "At least 20 GB of available disk is recommended."
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

apt-cache show grafana >/dev/null 2>&1 ||
    fail "Grafana package was not found."

apt-cache show loki >/dev/null 2>&1 ||
    fail "Loki package was not found."

apt-cache show alloy >/dev/null 2>&1 ||
    fail "Grafana Alloy package was not found."


# ============================================================
# STEP 6 - INSTALL CORE OBSERVABILITY COMPONENTS
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

cp \
    -n \
    /etc/prometheus/prometheus.yml \
    /etc/prometheus/prometheus.yml.original \
    2>/dev/null || true


cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s

scrape_configs:

  # Prometheus monitors itself.
  - job_name: "prometheus"

    static_configs:
      - targets:
          - "127.0.0.1:9090"

        labels:
          environment: "observability"
          role: "prometheus"

  # Node Exporter running on the central observability VM.
  - job_name: "central-observability-node"

    static_configs:
      - targets:
          - "127.0.0.1:9100"

        labels:
          environment: "observability"
          role: "central-server"

  # Remote Linux machines.
  #
  # Targets are read from:
  #
  # /etc/prometheus/file_sd/linux-nodes.yml
  #
  # Prometheus automatically refreshes this file.
  - job_name: "remote-linux-nodes"

    file_sd_configs:
      - files:
          - "/etc/prometheus/file_sd/linux-nodes.yml"

        refresh_interval: 30s
EOF


# Create an empty valid remote-target file if it does not exist.

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


# Validate Prometheus configuration.

promtool \
    check \
    config \
    /etc/prometheus/prometheus.yml


# ============================================================
# STEP 10 - CONFIGURE LOKI
# ============================================================

log "Configuring Loki"

install \
    -d \
    -m 0755 \
    "$LOKI_DIR/chunks" \
    "$LOKI_DIR/rules" \
    "$LOKI_DIR/compactor"


if id loki >/dev/null 2>&1; then

    chown \
        -R \
        loki:"$(id -gn loki)" \
        "$LOKI_DIR"

fi


cp \
    -n \
    /etc/loki/config.yml \
    /etc/loki/config.yml.original \
    2>/dev/null || true


cat > /etc/loki/config.yml <<'EOF'
# Authentication is disabled for this internal lab.
#
# Access to TCP 3100 must be restricted through Azure NSG,
# the host firewall or another company network control.
auth_enabled: false

server:

  # Allow approved remote Alloy agents to send logs.
  http_listen_address: 0.0.0.0

  http_listen_port: 3100

  # Keep Loki's internal gRPC port local.
  grpc_listen_address: 127.0.0.1

  grpc_listen_port: 9096

  log_level: warn

common:

  ring:

    # This is Loki's internal ring address.
    # It must not be changed to 0.0.0.0.
    instance_addr: 127.0.0.1

    kvstore:
      store: inmemory

  replication_factor: 1

  path_prefix: /var/lib/loki

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
    directory: /var/lib/loki/chunks

compactor:

  working_directory: /var/lib/loki/compactor

  retention_enabled: true

  delete_request_store: filesystem

limits_config:

  # Seven-day log retention for this test environment.
  retention_period: 168h

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


# Validate Loki configuration.

if command -v loki >/dev/null 2>&1; then

    loki \
        -config.file=/etc/loki/config.yml \
        -verify-config=true

fi


# ============================================================
# STEP 11 - CONFIGURE TEMPO
# ============================================================

log "Configuring Tempo"

install \
    -d \
    -m 0755 \
    /etc/tempo \
    "$TEMPO_DIR/wal" \
    "$TEMPO_DIR/blocks" \
    "$TEMPO_RUNTIME_DIR"


if id tempo >/dev/null 2>&1; then

    chown \
        -R \
        tempo:"$(id -gn tempo)" \
        "$TEMPO_DIR" \
        "$TEMPO_RUNTIME_DIR"

fi


cp \
    -n \
    /etc/tempo/config.yml \
    /etc/tempo/config.yml.original \
    2>/dev/null || true


cat > /etc/tempo/config.yml <<EOF
stream_over_http_enabled: true

server:

  # Tempo is queried by Grafana on the same VM.
  http_listen_address: 127.0.0.1

  http_listen_port: 3200

  log_level: info

distributor:

  receivers:

    otlp:

      protocols:

        # Internal gRPC receiver.
        #
        # Remote applications send to Alloy on port 4317.
        grpc:
          endpoint: "127.0.0.1:${TEMPO_INTERNAL_OTLP_GRPC_PORT}"

        # Internal HTTP receiver used by Alloy.
        #
        # Remote applications send to Alloy on port 4318.
        http:
          endpoint: "127.0.0.1:${TEMPO_INTERNAL_OTLP_HTTP_PORT}"

storage:

  trace:

    backend: local

    wal:
      path: /data/tempo/wal

    local:
      path: /data/tempo/blocks

compactor:

  compaction:

    # Seven-day trace retention.
    block_retention: 168h

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


# Validate Tempo configuration.

tempo \
    -config.file=/etc/tempo/config.yml \
    -config.verify


# ============================================================
# STEP 12 - CONFIGURE GRAFANA ALLOY
# ============================================================

log "Configuring Grafana Alloy"

# Allow Alloy to read systemd journal entries.

usermod \
    -aG systemd-journal \
    alloy


cp \
    -n \
    /etc/alloy/config.alloy \
    /etc/alloy/config.alloy.original \
    2>/dev/null || true


cat > /etc/alloy/config.alloy <<EOF
//
// ==========================================================
// LOCAL LOG PIPELINE
//
// Central VM systemd journal
//          |
//          v
//        Alloy
//          |
//          v
//         Loki
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
//
// Local or remote application
//          |
//          | OTLP/gRPC port ${ALLOY_OTLP_GRPC_PORT}
//          | OTLP/HTTP port ${ALLOY_OTLP_HTTP_PORT}
//          v
//        Alloy
//          |
//          v
//        Tempo
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


# Validate Alloy configuration.

alloy \
    validate \
    /etc/alloy/config.alloy


# ============================================================
# STEP 13 - CONFIGURE GRAFANA DATA SOURCES
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
# STEP 14 - CONFIGURE GRAFANA NETWORK LISTENER
# ============================================================

log "Configuring Grafana network listener"

cp \
    -n \
    /etc/grafana/grafana.ini \
    /etc/grafana/grafana.ini.original \
    2>/dev/null || true


# Configure Grafana to listen on all VM interfaces.

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

fi


# ============================================================
# STEP 15 - LIMIT SYSTEMD JOURNAL STORAGE
# ============================================================

log "Limiting journald disk usage"

install \
    -d \
    -m 0755 \
    /etc/systemd/journald.conf.d


cat > /etc/systemd/journald.conf.d/observability.conf <<'EOF'
[Journal]

# Limit systemd journal storage to 1 GB.
SystemMaxUse=1G

# Preserve at least 5 GB of free disk.
SystemKeepFree=5G

# Compress older journal files.
Compress=yes
EOF


systemctl \
    restart \
    systemd-journald


# ============================================================
# STEP 16 - CHECK LOCAL FIREWALL
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

        warn "The installer will not modify company firewall policy automatically."

        warn "Request approved access for TCP 3000, 3100, 4317 and 4318."

    fi

else

    echo "UFW is not installed."

fi


cat <<'EOF'

Required inbound access to the central server:

TCP 3000:
    Grafana access from approved administrator networks.

TCP 3100:
    Loki log ingestion from Alloy agents.

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
# STEP 17 - ENABLE SERVICES
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
# STEP 18 - START SERVICES
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
    60 || true


log "Starting Tempo"

systemctl \
    restart \
    tempo


wait_url \
    "Tempo startup" \
    "http://127.0.0.1:3200/ready" \
    60 || true


log "Starting Grafana Alloy"

systemctl \
    restart \
    alloy


log "Starting Grafana"

systemctl \
    restart \
    grafana-server


# ============================================================
# STEP 19 - VERIFY SERVICES
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
# STEP 20 - VERIFY HTTP ENDPOINTS
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
# STEP 21 - DISPLAY LISTENING PORTS
# ============================================================

log "Listening ports"

ss \
    -ltnp |
    grep \
        -E \
        ':(3000|9090|9100|3100|3200|4317|4318|4320|4321)\b' ||
    true


# ============================================================
# STEP 22 - DETERMINE CENTRAL VM IP
# ============================================================

PRIMARY_IP="$(
    hostname -I 2>/dev/null |
    awk '{print $1}'
)"

PRIMARY_IP="${PRIMARY_IP:-OBSERVABILITY_SERVER_IP}"


# ============================================================
# STEP 23 - PRINT COMPLETION INFORMATION
# ============================================================

cat <<EOF


============================================================
OBSERVABILITY STACK INSTALLATION FINISHED
============================================================

Central observability server:

    ${PRIMARY_IP}

Native Linux services were installed.

No Docker was used.


------------------------------------------------------------
COMPONENT PORTS
------------------------------------------------------------

Grafana:

    ${PRIMARY_IP}:3000

Prometheus:

    ${PRIMARY_IP}:9090

Node Exporter:

    ${PRIMARY_IP}:9100

Loki ingestion:

    ${PRIMARY_IP}:3100

Tempo query API:

    127.0.0.1:3200

Alloy OTLP/gRPC:

    ${PRIMARY_IP}:${ALLOY_OTLP_GRPC_PORT}

Alloy OTLP/HTTP:

    ${PRIMARY_IP}:${ALLOY_OTLP_HTTP_PORT}

Internal Tempo OTLP/HTTP:

    127.0.0.1:${TEMPO_INTERNAL_OTLP_HTTP_PORT}

Internal Tempo OTLP/gRPC:

    127.0.0.1:${TEMPO_INTERNAL_OTLP_GRPC_PORT}


------------------------------------------------------------
GRAFANA ACCESS
------------------------------------------------------------

Open Grafana from a workstation that has network access:

    http://${PRIMARY_IP}:3000

Initial login:

    Username: admin
    Password: admin

Change the administrator password immediately after logging in.


------------------------------------------------------------
GRAFANA DATA SOURCES
------------------------------------------------------------

The following data sources were automatically provisioned:

    Prometheus
    Loki
    Tempo


------------------------------------------------------------
PROMETHEUS REMOTE NODE CONFIGURATION
------------------------------------------------------------

Install Node Exporter on each monitored Linux VM.

Then edit this file on the central observability server:

    ${PROMETHEUS_REMOTE_TARGETS_FILE}

Example:

    - targets:
        - "172.17.80.221:9100"
        - "172.17.80.223:9100"
      labels:
        environment: "test"
        location: "azure"

Prometheus detects changes to this file automatically.

Verify remote targets at:

    http://${PRIMARY_IP}:9090/targets


------------------------------------------------------------
REMOTE LOG INGESTION
------------------------------------------------------------

Install and configure Grafana Alloy on each monitored VM.

Remote Alloy agents should send logs to:

    http://${PRIMARY_IP}:3100/loki/api/v1/push

Example Loki query in Grafana Explore:

    {job="systemd-journal"}

Remote Alloy agents should add a host label to every log stream.


------------------------------------------------------------
REMOTE TRACE INGESTION
------------------------------------------------------------

Applications and OpenTelemetry agents can send traces using:

OTLP/gRPC:

    ${PRIMARY_IP}:${ALLOY_OTLP_GRPC_PORT}

OTLP/HTTP base endpoint:

    http://${PRIMARY_IP}:${ALLOY_OTLP_HTTP_PORT}

OTLP/HTTP trace endpoint:

    http://${PRIMARY_IP}:${ALLOY_OTLP_HTTP_PORT}/v1/traces


The trace path is:

Application
    |
    v
OpenTelemetry SDK or agent
    |
    v
Central Grafana Alloy
    |
    v
Grafana Tempo
    |
    v
Grafana


------------------------------------------------------------
METRIC PIPELINE
------------------------------------------------------------

Linux VM
    |
    v
Node Exporter
    |
    v
Central Prometheus
    |
    v
Grafana


------------------------------------------------------------
LOG PIPELINE
------------------------------------------------------------

Linux VM systemd/journald
    |
    v
Remote Grafana Alloy
    |
    v
Central Loki
    |
    v
Grafana


------------------------------------------------------------
NETWORK REQUIREMENTS
------------------------------------------------------------

Permit only approved source networks:

    TCP 3000 - Grafana users

    TCP 3100 - Remote Alloy log agents

    TCP 4317 - OTLP/gRPC clients

    TCP 4318 - OTLP/HTTP clients

Permit the central observability VM to connect to monitored VMs:

    TCP 9100 - Node Exporter

Do not expose these ports directly to the public internet.

Both Azure NSG rules and operating-system firewall rules may
affect connectivity.


------------------------------------------------------------
USEFUL COMMANDS
------------------------------------------------------------

Check service statuses:

    systemctl status grafana-server

    systemctl status prometheus

    systemctl status prometheus-node-exporter

    systemctl status loki

    systemctl status tempo

    systemctl status alloy


View service logs:

    journalctl -u grafana-server -n 100 --no-pager

    journalctl -u prometheus -n 100 --no-pager

    journalctl -u prometheus-node-exporter -n 100 --no-pager

    journalctl -u loki -n 100 --no-pager

    journalctl -u tempo -n 100 --no-pager

    journalctl -u alloy -n 100 --no-pager


View installation log:

    less ${INSTALL_LOG}


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