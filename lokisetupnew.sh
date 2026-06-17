#!/bin/bash

# Loki Installation Script
# Config: /etc/loki
# Data: /var/lib/loki
# Version: 3.5.7

set -euo pipefail

# Variables
LOKI_VERSION="3.5.7"
DOWNLOAD_URL="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip"
ZIP_FILE="loki-linux-amd64.zip"
BINARY="loki-linux-amd64"

WORK_DIR="/tmp/loki"
CONFIG_DIR="/etc/loki"
DATA_DIR="/var/lib/loki"
BIN_DIR="/usr/local/bin"
SERVICE_FILE="/etc/systemd/system/loki.service"

echo "Installing dependencies..."
sudo apt update
sudo apt install -y unzip wget curl

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# Download Loki if not already installed
if ! command -v loki >/dev/null 2>&1; then
    echo "Downloading Loki ${LOKI_VERSION}..."
    wget -q -O "${ZIP_FILE}" "${DOWNLOAD_URL}"
    unzip -o "${ZIP_FILE}"

    sudo mv "${BINARY}" "${BIN_DIR}/loki"
    sudo chmod +x "${BIN_DIR}/loki"
fi

echo "Installed version:"
loki --version

# Create group if not exists
getent group loki >/dev/null || sudo groupadd --system loki

# Create user if not exists
id loki >/dev/null 2>&1 || \
sudo useradd --system --no-create-home \
--shell /usr/sbin/nologin \
--gid loki loki

# Create directories
sudo mkdir -p "${DATA_DIR}/chunks"
sudo mkdir -p "${DATA_DIR}/rules"
sudo mkdir -p "${CONFIG_DIR}"

sudo chown -R loki:loki "${DATA_DIR}"
sudo chmod -R 755 "${DATA_DIR}"

# Create config file
cat <<EOF | sudo tee "${CONFIG_DIR}/config.yml" >/dev/null
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2023-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  allow_structured_metadata: false
EOF

sudo chown -R loki:loki "${CONFIG_DIR}"

# Create systemd service
cat <<EOF | sudo tee "${SERVICE_FILE}" >/dev/null
[Unit]
Description=Loki Log Aggregation
After=network.target

[Service]
User=loki
Group=loki
Type=simple
ExecStart=/usr/local/bin/loki --config.file=/etc/loki/config.yml
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Open firewall if UFW exists
if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow 3100/tcp || true
fi

# Reload and start service
sudo systemctl daemon-reload
sudo systemctl enable --now loki

echo "Waiting for Loki to become ready..."

until curl -fs http://localhost:3100/ready >/dev/null 2>&1; do
    echo "Waiting for Loki..."
    sleep 5
done

echo "Loki is ready."

echo
echo "Service status:"
sudo systemctl --no-pager status loki

echo
echo "Metrics verification:"
curl -s http://localhost:3100/metrics | grep loki_build_info

echo
echo "Loki endpoint:"
echo "http://$(curl -s ifconfig.me):3100"
