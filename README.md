Native Observability Stack
Automated installation of a centralized observability stack on Ubuntu 24.04 using native systemd services. Docker is not required.

Objective
This project provides centralized collection and visualization of:

Linux infrastructure metrics
System and application logs
Distributed application traces
It is intended for lab, POC, performance-testing, and low-ingestion environments.

Components Installed
Grafana
Prometheus
Node Exporter
Grafana Loki
Grafana Tempo 3.1
Grafana Alloy
Architecture
Metrics
Linux VMs -> Node Exporter -> Prometheus -> Grafana
Logs
Linux journald -> Grafana Alloy -> Loki -> Grafana
Traces
Applications -> OTLP -> Grafana Alloy -> Tempo -> Grafana
Network Ports
Required inbound ports
3000/TCP - Grafana web interface
3100/TCP - Loki log ingestion
4317/TCP - Alloy OTLP/gRPC trace ingestion
4318/TCP - Alloy OTLP/HTTP trace ingestion
Required outbound port
9100/TCP - Prometheus scraping Node Exporter on monitored VMs
443/TCP - Package and software downloads
Local-only ports
3200/TCP - Tempo query API
4320/TCP - Internal Tempo OTLP/HTTP
4321/TCP - Internal Tempo OTLP/gRPC
9096/TCP - Internal Loki gRPC
Do not expose these services directly to the public internet. Restrict access to approved corporate, application, and monitoring networks.

Storage and Retention
Prometheus: 7 days, maximum 10 GB
Loki: 72 hours
Tempo: 72 hours
Systemd journal: maximum 1 GB
Storage locations:

Prometheus: /var/lib/prometheus
Loki:       /var/lib/loki
Tempo:      /data/tempo
Grafana:    /var/lib/grafana
Prerequisites
Ubuntu 24.04
Sudo access
At least 2 vCPUs
At least 8 GB RAM recommended
At least 20 GB free disk space
Access to GitHub and the Grafana package repository
Installation
Clone the repository:

git clone https://github.com/suyog0227/observability_Stack_Install.git
cd observability_Stack_Install
Validate the script:

bash -n install.sh
Run the installer:

chmod +x install.sh
sudo ./install.sh
Installation logs are written to:

/var/log/observability-install.log
Access Grafana
Determine the VM IP:

hostname -I
Open:

http://CENTRAL_VM_IP:3000
Initial credentials, if unchanged:

Username: admin
Password: admin
Change the password immediately after the first login.

Verify Services
for service in \
grafana-server \
prometheus \
prometheus-node-exporter \
loki \
tempo \
alloy
do
    printf '%-28s ' "$service"
    systemctl is-active "$service"
done
All services should report:

active
Verify Endpoints
curl -fsS http://127.0.0.1:3000/api/health
curl -fsS http://127.0.0.1:9090/-/ready
curl -fsS http://127.0.0.1:9100/metrics | head
curl -fsS http://127.0.0.1:3100/ready
curl -fsS http://127.0.0.1:3200/ready
Add Remote Linux VMs
Install Node Exporter on each monitored VM, then edit:

/etc/prometheus/file_sd/linux-nodes.yml
Example:

- targets:
    - "172.17.80.221:9100"
    - "172.17.80.223:9100"

  labels:
    environment: "test"
    location: "azure"
Prometheus automatically detects changes to this file.

Remote Log Ingestion
Install Grafana Alloy on remote VMs and configure logs to be sent to:

http://CENTRAL_VM_IP:3100/loki/api/v1/push
Example Loki query:

{job="systemd-journal"}
Trace Ingestion
Applications can send traces through:

OTLP/gRPC: CENTRAL_VM_IP:4317
OTLP/HTTP: http://CENTRAL_VM_IP:4318/v1/traces
Useful Commands
Check service logs:

journalctl -u grafana-server -n 100 --no-pager
journalctl -u prometheus -n 100 --no-pager
journalctl -u loki -n 100 --no-pager
journalctl -u tempo -n 100 --no-pager
journalctl -u alloy -n 100 --no-pager
Check storage usage:

du -sh \
/var/lib/prometheus \
/var/lib/loki \
/data/tempo \
/var/lib/grafana 2>/dev/null

df -h /
Current Limitations
Single-node deployment
Local filesystem storage
No high availability
No MinIO or external object storage
No Alertmanager
No TLS termination
Loki authentication is disabled
This deployment should be protected using Azure NSG, firewall, routing, and company network controls.git