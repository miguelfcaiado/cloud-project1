#!/bin/bash
#===============================================================================
# EC2 User Data - Production Version (GitHub)
# 
# Use this version once your code is pushed to GitHub.
# Modify GITHUB_REPO and S3_BUCKET before deploying.
#===============================================================================

set -e
exec > >(tee /var/log/user-data.log) 2>&1

echo "=== Starting Bootstrap $(date) ==="

# ---- CONFIGURATION ----
GITHUB_REPO="https://github.com/YOUR_USERNAME/devops-metrics-dashboard.git"
S3_BUCKET="your-metrics-bucket-name"
AWS_REGION="us-east-1"
APP_NAME="devops-metrics-dashboard"
APP_USER="appuser"
APP_DIR="/opt/${APP_NAME}"

# ---- INSTALL DEPENDENCIES ----
echo "[1/6] Installing packages..."
dnf update -y
dnf install -y python3.11 python3.11-pip git amazon-cloudwatch-agent

# ---- CREATE USER ----
echo "[2/6] Creating app user..."
useradd --system --shell /bin/bash --home-dir "$APP_DIR" "$APP_USER" 2>/dev/null || true

# ---- GET INSTANCE METADATA ----
echo "[3/6] Fetching metadata..."
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

# ---- CLONE CODE ----
echo "[4/6] Cloning application..."
git clone "$GITHUB_REPO" "$APP_DIR"
cd "$APP_DIR"
python3.11 -m pip install -r requirements.txt

# ---- CREATE ENV FILE ----
echo "[5/6] Configuring environment..."
cat > "${APP_DIR}/.env" << EOF
APP_NAME=DevOps Metrics Dashboard
ENVIRONMENT=production
AWS_REGION=${AWS_REGION}
S3_BUCKET=${S3_BUCKET}
INSTANCE_ID=${INSTANCE_ID}
EOF

# ---- CREATE SYSTEMD SERVICE ----
echo "[6/6] Creating service..."
cat > /etc/systemd/system/${APP_NAME}.service << EOF
[Unit]
Description=DevOps Metrics Dashboard
After=network.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}/app
EnvironmentFile=${APP_DIR}/.env
ExecStart=/usr/local/bin/gunicorn --workers 2 --bind 0.0.0.0:5000 "main:create_app()"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/log/${APP_NAME}
chown -R ${APP_USER}:${APP_USER} ${APP_DIR} /var/log/${APP_NAME}

systemctl daemon-reload
systemctl enable ${APP_NAME}
systemctl start ${APP_NAME}

echo "=== Bootstrap Complete ==="
echo "App running at: http://${PRIVATE_IP}:5000"