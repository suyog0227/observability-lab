# Observability Stack Installation

Automated installation of a centralized observability stack on Ubuntu 24.04 using native systemd services.

## Objective

This project provides centralized collection and visualization of:

- Linux infrastructure metrics
- System and application logs
- Distributed application traces

The deployment is intended for lab, POC, performance-testing, and low-ingestion environments.

## Components Installed

- Grafana
- Prometheus
- Node Exporter
- Grafana Loki
- Grafana Tempo 3.1
- Grafana Alloy

## Architecture

```text
Metrics: Linux VMs -> Node Exporter -> Prometheus -> Grafana
Logs:   Linux journald -> Grafana Alloy -> Loki -> Grafana
Traces: Applications -> OTLP -> Grafana Alloy -> Tempo -> Grafana
```

## Network Requirements

### Required inbound ports

- `3000/TCP` - Grafana web interface
- `3100/TCP` - Loki log ingestion
- `4317/TCP` - Alloy OTLP/gRPC trace ingestion
- `4318/TCP` - Alloy OTLP/HTTP trace ingestion

### Required outbound ports

- `9100/TCP` - Prometheus scraping Node Exporter on monitored VMs
- `443/TCP` - Package and software downloads

### Local-only ports

- `3200/TCP` - Tempo query API
- `4320/TCP` - Internal Tempo OTLP/HTTP
- `4321/TCP` - Internal Tempo OTLP/gRPC
- `9096/TCP` - Internal Loki gRPC

> Do not expose these services publicly. Restrict access to approved corporate, application, and monitoring networks.

## Storage and Retention

- **Prometheus:** 7 days, maximum 10 GB
- **Loki:** 72 hours
- **Tempo:** 72 hours
- **Systemd journal:** Maximum 1 GB

```text
Prometheus: /var/lib/prometheus
Loki:       /var/lib/loki
Tempo:      /data/tempo
Grafana:    /var/lib/grafana
```

## Prerequisites

- Ubuntu 24.04
- Sudo access
- Minimum 2 vCPUs
- 8 GB RAM recommended
- Minimum 20 GB free disk space
- Access to GitHub and the Grafana package repository

## Installation

```bash
git clone https://github.com/suyog0227/observability_Stack_Install.git
cd observability_Stack_Install
bash -n install.sh
chmod +x install.sh
sudo ./install.sh
```

Installation logs are written to:

```text
/var/log/observability-install.log
```

## Access Grafana

```bash
hostname -I
```

Open:

```text
http://CENTRAL_VM_IP:3000
```

Initial credentials, if unchanged:

```text
Username: admin
Password: admin
```

Change the administrator password after the first login.

## Verify Services

```bash
for service in grafana-server prometheus prometheus-node-exporter loki tempo alloy; do
    printf '%-28s ' "$service"
    systemctl is-active "$service"
done
```

## Verify Endpoints

```bash
curl -fsS http://127.0.0.1:3000/api/health
curl -fsS http://127.0.0.1:9090/-/ready
curl -fsS http://127.0.0.1:9100/metrics | head
curl -fsS http://127.0.0.1:3100/ready
curl -fsS http://127.0.0.1:3200/ready
```

## Add Remote Linux VMs

Install Node Exporter on each monitored VM, then edit:

```text
/etc/prometheus/file_sd/linux-nodes.yml
```

Example:

```yaml
- targets:
    - "172.17.80.221:9100"
    - "172.17.80.223:9100"
  labels:
    environment: "test"
    location: "azure"
```

## Remote Log Ingestion

Configure Grafana Alloy on remote VMs to send logs to:

```text
http://CENTRAL_VM_IP:3100/loki/api/v1/push
```

## Trace Ingestion

```text
OTLP/gRPC: CENTRAL_VM_IP:4317
OTLP/HTTP: http://CENTRAL_VM_IP:4318/v1/traces
```


Protect the deployment using Azure NSG, firewall, routing, and company network controls.
