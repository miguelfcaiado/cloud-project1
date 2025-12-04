#!/bin/bash
#===============================================================================
# EC2 User Data Bootstrap Script
# DevOps Metrics Dashboard
#
# This script runs automatically when an EC2 instance launches.
# It configures the server and deploys the application without manual SSH.
#
# IMPORTANT: User data scripts run as root, so no 'sudo' needed.
# Logs are available at: /var/log/cloud-init-output.log
#===============================================================================

set -e  # Exit on any error
exec > >(tee /var/log/user-data.log) 2>&1  # Log everything

echo "=========================================="
echo "Starting EC2 Bootstrap - $(date)"
echo "=========================================="

#-------------------------------------------------------------------------------
# CONFIGURATION - Modify these variables for your deployment
#-------------------------------------------------------------------------------
APP_NAME="devops-metrics-dashboard"
APP_USER="appuser"
APP_DIR="/opt/${APP_NAME}"
GITHUB_REPO="https://github.com/YOUR_USERNAME/devops-metrics-dashboard.git"
S3_BUCKET="your-metrics-bucket-name"  # Will be overridden by instance tag if set
AWS_REGION="us-east-1"

#-------------------------------------------------------------------------------
# STEP 1: System Updates and Dependencies
#-------------------------------------------------------------------------------
echo "[1/8] Updating system packages..."
dnf update -y

echo "[1/8] Installing required packages..."
dnf install -y \
    python3.11 \
    python3.11-pip \
    git \
    htop \
    jq \
    amazon-cloudwatch-agent

# Set Python 3.11 as default
alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
alternatives --set python3 /usr/bin/python3.11

#-------------------------------------------------------------------------------
# STEP 2: Create Application User
#-------------------------------------------------------------------------------
echo "[2/8] Creating application user..."
if ! id "$APP_USER" &>/dev/null; then
    useradd --system --shell /bin/bash --home-dir "$APP_DIR" "$APP_USER"
    echo "Created user: $APP_USER"
else
    echo "User $APP_USER already exists"
fi

#-------------------------------------------------------------------------------
# STEP 3: Fetch Instance Metadata (IMDSv2)
#-------------------------------------------------------------------------------
echo "[3/8] Fetching instance metadata..."

# Get IMDSv2 token
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Fetch metadata using token
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id)
AVAILABILITY_ZONE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/availability-zone)
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/local-ipv4)

echo "Instance ID: $INSTANCE_ID"
echo "Availability Zone: $AVAILABILITY_ZONE"
echo "Private IP: $PRIVATE_IP"

# Try to get S3 bucket from instance tags (requires IAM permissions)
# This allows different environments to use different buckets
TAGGED_BUCKET=$(aws ec2 describe-tags \
    --region "$AWS_REGION" \
    --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=S3Bucket" \
    --query 'Tags[0].Value' --output text 2>/dev/null || echo "")

if [ -n "$TAGGED_BUCKET" ] && [ "$TAGGED_BUCKET" != "None" ]; then
    S3_BUCKET="$TAGGED_BUCKET"
    echo "Using S3 bucket from tag: $S3_BUCKET"
fi

#-------------------------------------------------------------------------------
# STEP 4: Clone Application Code
#-------------------------------------------------------------------------------
echo "[4/8] Setting up application directory..."
mkdir -p "$APP_DIR"

# Option A: Clone from GitHub (recommended for real projects)
# Uncomment these lines and comment out Option B when using GitHub
# echo "Cloning from GitHub..."
# git clone "$GITHUB_REPO" "$APP_DIR"

# Option B: Download from S3 (useful for private code)
# Upload your code first: aws s3 cp app.zip s3://your-bucket/deployments/
# echo "Downloading from S3..."
# aws s3 cp "s3://${S3_BUCKET}/deployments/app.zip" /tmp/app.zip
# unzip /tmp/app.zip -d "$APP_DIR"

# Option C: Create the app inline (for this tutorial)
# In production, use Option A or B instead
echo "Creating application files..."

mkdir -p "${APP_DIR}/app/templates"

# Create main.py
cat > "${APP_DIR}/app/main.py" << 'MAINPY'
import os
import logging
from flask import Flask
from routes import register_routes
from s3_client import S3Client

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def create_app():
    app = Flask(__name__)
    app.config.update(
        APP_NAME=os.getenv('APP_NAME', 'DevOps Metrics Dashboard'),
        AWS_REGION=os.getenv('AWS_REGION', 'us-east-1'),
        S3_BUCKET=os.getenv('S3_BUCKET', 'devops-metrics-bucket'),
        ENVIRONMENT=os.getenv('ENVIRONMENT', 'production'),
        DEBUG=os.getenv('DEBUG', 'False').lower() == 'true'
    )
    app.s3_client = S3Client(
        bucket_name=app.config['S3_BUCKET'],
        region=app.config['AWS_REGION']
    )
    register_routes(app)
    logger.info(f"Application initialized: {app.config['APP_NAME']}")
    return app

if __name__ == '__main__':
    app = create_app()
    port = int(os.getenv('PORT', 5000))
    app.run(host='0.0.0.0', port=port, debug=app.config['DEBUG'])
MAINPY

# Create s3_client.py
cat > "${APP_DIR}/app/s3_client.py" << 'S3PY'
import json
import logging
from datetime import datetime
from typing import Optional
import boto3
from botocore.exceptions import ClientError, NoCredentialsError

logger = logging.getLogger(__name__)

class S3Client:
    def __init__(self, bucket_name: str, region: str = 'us-east-1'):
        self.bucket_name = bucket_name
        self.region = region
        self._client = None
        
    @property
    def client(self):
        if self._client is None:
            try:
                self._client = boto3.client('s3', region_name=self.region)
            except NoCredentialsError:
                logger.warning("AWS credentials not found")
                self._client = None
        return self._client
    
    def store_metric(self, metric_name: str, value: float, metadata: Optional[dict] = None) -> dict:
        timestamp = datetime.utcnow()
        metric_data = {
            'metric_name': metric_name,
            'value': value,
            'timestamp': timestamp.isoformat(),
            'metadata': metadata or {}
        }
        s3_key = f"metrics/{timestamp.year}/{timestamp.month:02d}/{timestamp.day:02d}/{metric_name}/{timestamp.strftime('%H%M%S%f')}.json"
        
        try:
            if self.client is None:
                return {'success': False, 'error': 'S3 client not available', 'metric': metric_data}
            self.client.put_object(
                Bucket=self.bucket_name,
                Key=s3_key,
                Body=json.dumps(metric_data),
                ContentType='application/json'
            )
            return {'success': True, 'location': f"s3://{self.bucket_name}/{s3_key}", 'metric': metric_data}
        except ClientError as e:
            return {'success': False, 'error': str(e), 'metric': metric_data}
    
    def get_recent_metrics(self, metric_name: str, limit: int = 10) -> list:
        today = datetime.utcnow()
        prefix = f"metrics/{today.year}/{today.month:02d}/{today.day:02d}/{metric_name}/"
        try:
            if self.client is None:
                return []
            response = self.client.list_objects_v2(Bucket=self.bucket_name, Prefix=prefix, MaxKeys=limit)
            metrics = []
            for obj in response.get('Contents', []):
                result = self.client.get_object(Bucket=self.bucket_name, Key=obj['Key'])
                metrics.append(json.loads(result['Body'].read().decode('utf-8')))
            return sorted(metrics, key=lambda x: x.get('timestamp', ''), reverse=True)[:limit]
        except ClientError:
            return []
    
    def check_bucket_access(self) -> dict:
        try:
            if self.client is None:
                return {'accessible': False, 'error': 'S3 client not initialized'}
            self.client.head_bucket(Bucket=self.bucket_name)
            return {'accessible': True, 'bucket': self.bucket_name}
        except ClientError as e:
            return {'accessible': False, 'error': str(e)}
S3PY

# Create routes.py
cat > "${APP_DIR}/app/routes.py" << 'ROUTESPY'
import os
import logging
import platform
import psutil
from datetime import datetime
from flask import jsonify, request, render_template, current_app

logger = logging.getLogger(__name__)

def register_routes(app):
    @app.route('/')
    def dashboard():
        try:
            return render_template(
                'dashboard.html',
                app_name=current_app.config['APP_NAME'],
                environment=current_app.config['ENVIRONMENT'],
                metrics=get_system_metrics(),
                instance_id=get_instance_id()
            )
        except Exception as e:
            logger.error(f"Dashboard error: {e}")
            return jsonify({'error': str(e)}), 500
    
    @app.route('/health')
    def health_check():
        health_status = {
            'status': 'healthy',
            'timestamp': datetime.utcnow().isoformat(),
            'instance_id': get_instance_id(),
            'version': os.getenv('APP_VERSION', '1.0.0')
        }
        try:
            s3_status = current_app.s3_client.check_bucket_access()
            health_status['s3_status'] = 'healthy' if s3_status.get('accessible') else 'degraded'
        except Exception:
            health_status['s3_status'] = 'unknown'
        return jsonify(health_status), 200
    
    @app.route('/metrics')
    def current_metrics():
        return jsonify({
            'timestamp': datetime.utcnow().isoformat(),
            'instance_id': get_instance_id(),
            'system': get_system_metrics()
        })
    
    @app.route('/api/record', methods=['POST'])
    def record_metric():
        if not request.is_json:
            return jsonify({'error': 'Content-Type must be application/json'}), 400
        data = request.get_json()
        if 'metric_name' not in data or 'value' not in data:
            return jsonify({'error': 'Missing required fields'}), 400
        try:
            value = float(data['value'])
        except (ValueError, TypeError):
            return jsonify({'error': 'Value must be a number'}), 400
        result = current_app.s3_client.store_metric(
            metric_name=data['metric_name'],
            value=value,
            metadata=data.get('metadata')
        )
        return jsonify(result), 201 if result['success'] else 500
    
    @app.route('/api/metrics/<metric_name>')
    def get_metrics(metric_name):
        limit = min(request.args.get('limit', 10, type=int), 100)
        metrics = current_app.s3_client.get_recent_metrics(metric_name, limit)
        return jsonify({'metric_name': metric_name, 'count': len(metrics), 'data': metrics})
    
    @app.errorhandler(404)
    def not_found(error):
        return jsonify({'error': 'Not found'}), 404

def get_system_metrics() -> dict:
    try:
        return {
            'cpu': {'percent': psutil.cpu_percent(interval=0.1), 'count': psutil.cpu_count()},
            'memory': {
                'percent': psutil.virtual_memory().percent,
                'total_gb': round(psutil.virtual_memory().total / (1024**3), 2),
                'available_gb': round(psutil.virtual_memory().available / (1024**3), 2),
                'used_gb': round(psutil.virtual_memory().used / (1024**3), 2)
            },
            'disk': {
                'percent': psutil.disk_usage('/').percent,
                'total_gb': round(psutil.disk_usage('/').total / (1024**3), 2),
                'free_gb': round(psutil.disk_usage('/').free / (1024**3), 2)
            },
            'platform': {
                'system': platform.system(),
                'release': platform.release(),
                'python_version': platform.python_version()
            }
        }
    except Exception as e:
        return {'error': str(e)}

def get_instance_id() -> str:
    instance_id = os.getenv('INSTANCE_ID')
    if instance_id:
        return instance_id
    try:
        import requests
        token = requests.put(
            'http://169.254.169.254/latest/api/token',
            headers={'X-aws-ec2-metadata-token-ttl-seconds': '21600'},
            timeout=1
        ).text
        return requests.get(
            'http://169.254.169.254/latest/meta-data/instance-id',
            headers={'X-aws-ec2-metadata-token': token},
            timeout=1
        ).text
    except Exception:
        return platform.node()
ROUTESPY

# Create dashboard.html template
cat > "${APP_DIR}/app/templates/dashboard.html" << 'HTMLTEMPLATE'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{{ app_name }}</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            min-height: 100vh; color: #e0e0e0; padding: 2rem;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        header { text-align: center; margin-bottom: 3rem; }
        h1 { font-size: 2.5rem; color: #00d4ff; margin-bottom: 0.5rem; }
        .subtitle { color: #888; }
        .env-badge {
            display: inline-block; padding: 0.25rem 0.75rem; border-radius: 20px;
            font-size: 0.75rem; font-weight: 600; text-transform: uppercase; margin-top: 0.5rem;
        }
        .env-development { background: #ff9800; color: #000; }
        .env-staging { background: #2196f3; color: #fff; }
        .env-production { background: #4caf50; color: #fff; }
        .metrics-grid {
            display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 1.5rem; margin-bottom: 2rem;
        }
        .metric-card {
            background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1);
            border-radius: 12px; padding: 1.5rem;
        }
        .metric-card h3 { color: #888; font-size: 0.875rem; text-transform: uppercase; margin-bottom: 1rem; }
        .metric-value { font-size: 3rem; font-weight: 700; color: #00d4ff; }
        .metric-unit { font-size: 1.25rem; color: #666; }
        .metric-details { margin-top: 1rem; padding-top: 1rem; border-top: 1px solid rgba(255,255,255,0.1); }
        .metric-detail-row { display: flex; justify-content: space-between; margin-bottom: 0.5rem; font-size: 0.875rem; }
        .metric-detail-label { color: #666; }
        .progress-bar { height: 8px; background: rgba(255,255,255,0.1); border-radius: 4px; margin-top: 0.75rem; }
        .progress-fill { height: 100%; border-radius: 4px; }
        .progress-low { background: linear-gradient(90deg, #4caf50, #8bc34a); }
        .progress-medium { background: linear-gradient(90deg, #ff9800, #ffc107); }
        .progress-high { background: linear-gradient(90deg, #f44336, #ff5722); }
        .info-section {
            background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.1);
            border-radius: 12px; padding: 1.5rem; margin-top: 2rem;
        }
        .info-section h3 { color: #00d4ff; margin-bottom: 1rem; }
        .info-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; }
        .info-label { font-size: 0.75rem; color: #666; text-transform: uppercase; }
        .info-value { color: #e0e0e0; }
        .status-dot { width: 10px; height: 10px; border-radius: 50%; background: #4caf50; display: inline-block; animation: pulse 2s infinite; }
        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
        footer { text-align: center; margin-top: 3rem; color: #666; font-size: 0.875rem; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>{{ app_name }}</h1>
            <p class="subtitle">Infrastructure Health Monitoring</p>
            <span class="env-badge env-{{ environment|lower }}">{{ environment }}</span>
        </header>
        <div class="metrics-grid">
            <div class="metric-card">
                <h3>CPU Usage</h3>
                <div class="metric-value">{{ "%.1f"|format(metrics.cpu.percent) }}<span class="metric-unit">%</span></div>
                <div class="progress-bar">
                    <div class="progress-fill {% if metrics.cpu.percent < 50 %}progress-low{% elif metrics.cpu.percent < 80 %}progress-medium{% else %}progress-high{% endif %}" style="width: {{ metrics.cpu.percent }}%"></div>
                </div>
                <div class="metric-details">
                    <div class="metric-detail-row"><span class="metric-detail-label">CPU Cores</span><span>{{ metrics.cpu.count }}</span></div>
                </div>
            </div>
            <div class="metric-card">
                <h3>Memory Usage</h3>
                <div class="metric-value">{{ "%.1f"|format(metrics.memory.percent) }}<span class="metric-unit">%</span></div>
                <div class="progress-bar">
                    <div class="progress-fill {% if metrics.memory.percent < 50 %}progress-low{% elif metrics.memory.percent < 80 %}progress-medium{% else %}progress-high{% endif %}" style="width: {{ metrics.memory.percent }}%"></div>
                </div>
                <div class="metric-details">
                    <div class="metric-detail-row"><span class="metric-detail-label">Total</span><span>{{ metrics.memory.total_gb }} GB</span></div>
                    <div class="metric-detail-row"><span class="metric-detail-label">Available</span><span>{{ metrics.memory.available_gb }} GB</span></div>
                </div>
            </div>
            <div class="metric-card">
                <h3>Disk Usage</h3>
                <div class="metric-value">{{ "%.1f"|format(metrics.disk.percent) }}<span class="metric-unit">%</span></div>
                <div class="progress-bar">
                    <div class="progress-fill {% if metrics.disk.percent < 50 %}progress-low{% elif metrics.disk.percent < 80 %}progress-medium{% else %}progress-high{% endif %}" style="width: {{ metrics.disk.percent }}%"></div>
                </div>
                <div class="metric-details">
                    <div class="metric-detail-row"><span class="metric-detail-label">Total</span><span>{{ metrics.disk.total_gb }} GB</span></div>
                    <div class="metric-detail-row"><span class="metric-detail-label">Free</span><span>{{ metrics.disk.free_gb }} GB</span></div>
                </div>
            </div>
        </div>
        <div class="info-section">
            <h3>Instance Information</h3>
            <div class="info-grid">
                <div><span class="info-label">Instance ID</span><div class="info-value">{{ instance_id }}</div></div>
                <div><span class="info-label">OS</span><div class="info-value">{{ metrics.platform.system }} {{ metrics.platform.release }}</div></div>
                <div><span class="info-label">Python</span><div class="info-value">{{ metrics.platform.python_version }}</div></div>
                <div><span class="info-label">Status</span><div class="info-value"><span class="status-dot"></span> Healthy</div></div>
            </div>
        </div>
        <footer><p>DevOps Metrics Dashboard • {{ instance_id }}</p></footer>
    </div>
    <script>setTimeout(function() { location.reload(); }, 30000);</script>
</body>
</html>
HTMLTEMPLATE

# Create requirements.txt
cat > "${APP_DIR}/requirements.txt" << 'REQUIREMENTS'
Flask==3.0.0
gunicorn==21.2.0
boto3==1.34.0
psutil==5.9.7
requests==2.31.0
REQUIREMENTS

#-------------------------------------------------------------------------------
# STEP 5: Install Python Dependencies
#-------------------------------------------------------------------------------
echo "[5/8] Installing Python dependencies..."
cd "$APP_DIR"
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt

#-------------------------------------------------------------------------------
# STEP 6: Create Environment File
#-------------------------------------------------------------------------------
echo "[6/8] Creating environment configuration..."
cat > "${APP_DIR}/.env" << ENVFILE
# Application Configuration
APP_NAME=DevOps Metrics Dashboard
ENVIRONMENT=production
DEBUG=False
PORT=5000
APP_VERSION=1.0.0

# AWS Configuration
AWS_REGION=${AWS_REGION}
S3_BUCKET=${S3_BUCKET}

# Instance Metadata
INSTANCE_ID=${INSTANCE_ID}
AVAILABILITY_ZONE=${AVAILABILITY_ZONE}
PRIVATE_IP=${PRIVATE_IP}
ENVFILE

#-------------------------------------------------------------------------------
# STEP 7: Create Systemd Service
#-------------------------------------------------------------------------------
echo "[7/8] Creating systemd service..."
cat > /etc/systemd/system/${APP_NAME}.service << SERVICEUNIT
[Unit]
Description=DevOps Metrics Dashboard
Documentation=https://github.com/YOUR_USERNAME/devops-metrics-dashboard
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}/app
EnvironmentFile=${APP_DIR}/.env

# Use Gunicorn for production (4 workers recommended for t3.micro)
ExecStart=/usr/local/bin/gunicorn \
    --workers 2 \
    --bind 0.0.0.0:5000 \
    --access-logfile /var/log/${APP_NAME}/access.log \
    --error-logfile /var/log/${APP_NAME}/error.log \
    --capture-output \
    --timeout 30 \
    "main:create_app()"

# Restart policy
Restart=always
RestartSec=5

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/${APP_NAME}

[Install]
WantedBy=multi-user.target
SERVICEUNIT

# Create log directory
mkdir -p /var/log/${APP_NAME}
chown ${APP_USER}:${APP_USER} /var/log/${APP_NAME}

# Set ownership of application directory
chown -R ${APP_USER}:${APP_USER} ${APP_DIR}

# Enable and start the service
systemctl daemon-reload
systemctl enable ${APP_NAME}
systemctl start ${APP_NAME}

#-------------------------------------------------------------------------------
# STEP 8: Configure CloudWatch Agent (Optional but Recommended)
#-------------------------------------------------------------------------------
echo "[8/8] Configuring CloudWatch Agent..."
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
    "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "root"
    },
    "metrics": {
        "namespace": "DevOpsMetricsDashboard",
        "metrics_collected": {
            "cpu": {
                "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
                "metrics_collection_interval": 60
            },
            "disk": {
                "measurement": ["used_percent"],
                "metrics_collection_interval": 60,
                "resources": ["/"]
            },
            "mem": {
                "measurement": ["mem_used_percent"],
                "metrics_collection_interval": 60
            }
        },
        "append_dimensions": {
            "InstanceId": "${aws:InstanceId}",
            "AutoScalingGroupName": "${aws:AutoScalingGroupName}"
        }
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/devops-metrics-dashboard/access.log",
                        "log_group_name": "/devops-metrics-dashboard/access",
                        "log_stream_name": "{instance_id}",
                        "retention_in_days": 7
                    },
                    {
                        "file_path": "/var/log/devops-metrics-dashboard/error.log",
                        "log_group_name": "/devops-metrics-dashboard/error",
                        "log_stream_name": "{instance_id}",
                        "retention_in_days": 7
                    }
                ]
            }
        }
    }
}
CWCONFIG

# Start CloudWatch Agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

#===============================================================================
# BOOTSTRAP COMPLETE
#===============================================================================
echo "=========================================="
echo "Bootstrap Complete - $(date)"
echo "=========================================="
echo ""
echo "Application Status:"
systemctl status ${APP_NAME} --no-pager
echo ""
echo "Application URL: http://${PRIVATE_IP}:5000"
echo "Health Check: http://${PRIVATE_IP}:5000/health"
echo ""
echo "Useful Commands:"
echo "  View logs:    journalctl -u ${APP_NAME} -f"
echo "  Restart app:  systemctl restart ${APP_NAME}"
echo "  App status:   systemctl status ${APP_NAME}"
echo "=========================================="