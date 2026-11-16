#!/bin/bash
set -Eeuo pipefail

# Prometheus + Grafana + Alertmanager + Node Exporter
# Ubuntu EC2 monitoring-server installation
# Run: sudo bash promo.sh

PROMETHEUS_VERSION="2.55.1"
ALERTMANAGER_VERSION="0.27.0"
NODE_EXPORTER_VERSION="1.8.2"
AWS_REGION="us-east-1"
EC2_NAME_TAG="node-server"

echo "=================================================="
echo " Installing Prometheus, Grafana, Alertmanager,"
echo " and Node Exporter"
echo "=================================================="

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run this script as root: sudo bash promo.sh"
  exit 1
fi

# Ask for the NEW PagerDuty integration key.
# The key is stored in a root-readable file, not in this script.
echo
echo "Enter your NEW PagerDuty Events API v2 routing key."
echo "Do not reuse a key that has been exposed in a script or chat."
read -rsp "PagerDuty routing key: " PAGERDUTY_ROUTING_KEY
echo
if [[ -z "${PAGERDUTY_ROUTING_KEY}" ]]; then
  echo "A PagerDuty routing key is required. Exiting."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo
echo "[1/8] Updating packages and installing prerequisites..."

# Remove the obsolete Grafana OSS repository that causes NO_PUBKEY errors.
for source_file in /etc/apt/sources.list.d/*; do
  [[ -f "${source_file}" ]] || continue
  if grep -qF "packages.grafana.com/oss/deb" "${source_file}"; then
    echo "Removing obsolete Grafana repository: ${source_file}"
    rm -f "${source_file}"
  fi
done

apt-get update
apt-get install -y ca-certificates curl wget tar gnupg

echo
echo "[2/8] Configuring the current Grafana repository..."

install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key \
  | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
chmod 0644 /etc/apt/keyrings/grafana.gpg

cat >/etc/apt/sources.list.d/grafana.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main
EOF

apt-get update
apt-get install -y grafana

echo
echo "[3/8] Preparing service accounts and directories..."

if ! id prometheus >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin prometheus
fi

if ! id node_exporter >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
fi

install -d -o prometheus -g prometheus /etc/prometheus /var/lib/prometheus
install -d -o prometheus -g prometheus /etc/alertmanager /var/lib/alertmanager

echo
echo "[4/8] Installing Prometheus..."

# Stop the existing service before replacing its executable.
systemctl stop prometheus 2>/dev/null || true

if pgrep -x prometheus >/dev/null 2>&1; then
  echo "A Prometheus process is still running."
  echo "Inspect it with: pgrep -a prometheus"
  echo "Stop that process, then run this script again."
  exit 1
fi

cd /tmp
curl -fL --retry 3 \
  -o "prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" \
  "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"

tar -xzf "prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
cd "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64"

install -m 0755 prometheus /usr/local/bin/prometheus
install -m 0755 promtool /usr/local/bin/promtool
cp -r consoles console_libraries /etc/prometheus/
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

cat >/etc/systemd/system/prometheus.service <<'EOF'
[Unit]
Description=Prometheus Monitoring
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus/ \
  --web.console.templates=/etc/prometheus/consoles \
  --web.console.libraries=/etc/prometheus/console_libraries
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

echo
echo "[5/8] Installing Alertmanager and configuring PagerDuty..."

systemctl stop alertmanager 2>/dev/null || true

if pgrep -x alertmanager >/dev/null 2>&1; then
  echo "An Alertmanager process is still running."
  echo "Inspect it with: pgrep -a alertmanager"
  exit 1
fi

cd /tmp
curl -fL --retry 3 \
  -o "alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz" \
  "https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz"

tar -xzf "alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz"
cd "/tmp/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64"

install -m 0755 alertmanager /usr/local/bin/alertmanager
install -m 0755 amtool /usr/local/bin/amtool
install -m 0600 /dev/null /etc/alertmanager/pagerduty-routing-key
printf '%s' "${PAGERDUTY_ROUTING_KEY}" >/etc/alertmanager/pagerduty-routing-key
chown prometheus:prometheus /etc/alertmanager/pagerduty-routing-key
unset PAGERDUTY_ROUTING_KEY

cat >/etc/alertmanager/alertmanager.yml <<'EOF'
global:
  resolve_timeout: 5m

route:
  receiver: pagerduty
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h

receivers:
  - name: pagerduty
    pagerduty_configs:
      - routing_key_file: /etc/alertmanager/pagerduty-routing-key
        severity: critical
EOF

chown -R prometheus:prometheus /etc/alertmanager /var/lib/alertmanager
chmod 0600 /etc/alertmanager/pagerduty-routing-key

cat >/etc/systemd/system/alertmanager.service <<'EOF'
[Unit]
Description=Prometheus Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager/
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

echo
echo "[6/8] Creating Prometheus alert rules..."

cat >/etc/prometheus/alert.rules.yml <<'EOF'
groups:
  - name: example-alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Instance {{ $labels.instance }} is down"
          description: "Prometheus target {{ $labels.instance }} has been unreachable for more than 1 minute."

      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 40
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "High CPU usage detected on {{ $labels.instance }}"
          description: "CPU usage is above 40% for more than 2 minutes. VALUE = {{ $value }}%"

      # This rule works only if your application exports http_requests_total
      # with a status label. Node Exporter does not provide this application metric.
      - alert: UnauthorizedRequests
        expr: increase(http_requests_total{status=~"401|403"}[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Unauthorized requests on {{ $labels.instance }}"
          description: "Detected HTTP 401/403 requests in the past 5 minutes."
EOF

chown prometheus:prometheus /etc/prometheus/alert.rules.yml

echo
echo "[7/8] Installing Node Exporter on this monitoring EC2..."

systemctl stop node_exporter 2>/dev/null || true

if pgrep -x node_exporter >/dev/null 2>&1; then
  echo "A Node Exporter process is still running."
  echo "Inspect it with: pgrep -a node_exporter"
  exit 1
fi

cd /tmp
curl -fL --retry 3 \
  -o "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
  "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

tar -xzf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
cd "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"

install -m 0755 node_exporter /usr/local/bin/node_exporter
chown node_exporter:node_exporter /usr/local/bin/node_exporter

cat >/etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

echo
echo "[8/8] Writing Prometheus configuration and starting services..."

cat >/etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "localhost:9093"

rule_files:
  - "/etc/prometheus/alert.rules.yml"

scrape_configs:
  # Prometheus application metrics
  - job_name: "prometheus"
    static_configs:
      - targets:
          - "localhost:9090"

  # Node Exporter running on this monitoring EC2
  - job_name: "monitoring-server"
    static_configs:
      - targets:
          - "localhost:9100"

  # Node Exporters on other EC2 instances tagged Name=node-server
  - job_name: "ec2-node-exporters"
    ec2_sd_configs:
      - region: "${AWS_REGION}"
        port: 9100
        filters:
          - name: "tag:Name"
            values:
              - "${EC2_NAME_TAG}"
    relabel_configs:
      - source_labels:
          - "__meta_ec2_private_ip"
        regex: "(.*)"
        target_label: "__address__"
        replacement: "\$1:9100"
EOF

chown prometheus:prometheus /etc/prometheus/prometheus.yml
chmod 0640 /etc/prometheus/prometheus.yml

echo "Checking Prometheus configuration..."
/usr/local/bin/promtool check config /etc/prometheus/prometheus.yml
/usr/local/bin/promtool check rules /etc/prometheus/alert.rules.yml

echo "Checking Alertmanager configuration..."
/usr/local/bin/amtool check-config /etc/alertmanager/alertmanager.yml

systemctl daemon-reload
systemctl enable --now prometheus
systemctl enable --now grafana-server
systemctl enable --now alertmanager
systemctl enable --now node_exporter

echo
echo "=================================================="
echo " Installation commands completed."
echo "=================================================="
echo
echo "Service status:"
systemctl --no-pager --full status prometheus || true
systemctl --no-pager --full status grafana-server || true
systemctl --no-pager --full status alertmanager || true
systemctl --no-pager --full status node_exporter || true

echo
echo "Prometheus:    http://<MONITORING-EC2-PUBLIC-IP>:9090"
echo "Grafana:       http://<MONITORING-EC2-PUBLIC-IP>:3000"
echo "Alertmanager:  http://<MONITORING-EC2-PUBLIC-IP>:9093"
echo "Node Exporter: http://<MONITORING-EC2-PRIVATE-IP>:9100/metrics"
echo
echo "Security: restrict these ports in the EC2 Security Group."
echo "Do not expose Node Exporter (9100) or Alertmanager (9093) publicly."
