"""
Routes Module
Defines all HTTP endpoints for the DevOps Metrics Dashboard.

Endpoints:
- GET  /           : Dashboard homepage
- GET  /health     : Health check (for ALB)
- GET  /metrics    : Current system metrics (JSON)
- POST /api/record : Store a new metric
- GET  /api/metrics/<name> : Retrieve specific metrics
"""

import os
import logging
import platform
import psutil
from datetime import datetime
from flask import jsonify, request, render_template, current_app

logger = logging.getLogger(__name__)


def register_routes(app):
    """Register all application routes."""
    
    @app.route('/')
    def dashboard():
        """
        Main dashboard page.
        Displays current system health and recent metrics.
        """
        # Gather system metrics for display
        system_metrics = get_system_metrics()
        
        return render_template(
            'dashboard.html',
            app_name=current_app.config['APP_NAME'],
            environment=current_app.config['ENVIRONMENT'],
            metrics=system_metrics,
            instance_id=get_instance_id()
        )
    
    @app.route('/health')
    def health_check():
        """
        Health check endpoint for ALB.
        
        This endpoint should:
        - Return 200 when the app is healthy
        - Return 503 when the app is unhealthy
        - Be lightweight (no heavy computations)
        - Not depend on external services (DB, cache, etc.)
        
        ALB will mark instance unhealthy if this returns non-2xx.
        """
        # Basic health: app is running and can respond
        health_status = {
            'status': 'healthy',
            'timestamp': datetime.utcnow().isoformat(),
            'instance_id': get_instance_id(),
            'version': os.getenv('APP_VERSION', '1.0.0')
        }
        
        # Optional: Add dependency checks for deeper health verification
        # Only do this if you want ALB to route away from instances
        # with degraded dependencies
        try:
            s3_status = current_app.s3_client.check_bucket_access()
            
            if not s3_status.get('accessible'):
                # Log the issue but don't fail health check
                # S3 being unavailable shouldn't take the whole app offline
                logger.warning(f"S3 degraded: {s3_status.get('error')}")
                health_status['s3_status'] = 'degraded'
            else:
                health_status['s3_status'] = 'healthy'
        except Exception as e:
            logger.warning(f"S3 check failed: {e}")
            health_status['s3_status'] = 'unknown'
        
        return jsonify(health_status), 200
    
    @app.route('/metrics')
    def current_metrics():
        """
        Return current system metrics as JSON.
        Useful for monitoring integrations and debugging.
        """
        metrics = get_system_metrics()
        
        return jsonify({
            'timestamp': datetime.utcnow().isoformat(),
            'instance_id': get_instance_id(),
            'system': metrics
        })
    
    @app.route('/api/record', methods=['POST'])
    def record_metric():
        """
        Store a new metric data point.
        
        Expected JSON body:
        {
            "metric_name": "custom_metric",
            "value": 42.5,
            "metadata": {"source": "app_server_1"}  // optional
        }
        """
        if not request.is_json:
            return jsonify({
                'error': 'Content-Type must be application/json'
            }), 400
        
        data = request.get_json()
        
        # Validate required fields
        if 'metric_name' not in data:
            return jsonify({
                'error': 'Missing required field: metric_name'
            }), 400
        
        if 'value' not in data:
            return jsonify({
                'error': 'Missing required field: value'
            }), 400
        
        try:
            value = float(data['value'])
        except (ValueError, TypeError):
            return jsonify({
                'error': 'Field "value" must be a number'
            }), 400
        
        # Store the metric
        result = current_app.s3_client.store_metric(
            metric_name=data['metric_name'],
            value=value,
            metadata=data.get('metadata')
        )
        
        if result['success']:
            logger.info(f"Metric recorded: {data['metric_name']}={value}")
            return jsonify(result), 201
        else:
            logger.error(f"Failed to record metric: {result.get('error')}")
            return jsonify(result), 500
    
    @app.route('/api/metrics/<metric_name>')
    def get_metrics(metric_name):
        """
        Retrieve recent values for a specific metric.
        
        Query parameters:
        - limit: Maximum number of results (default: 10)
        """
        limit = request.args.get('limit', 10, type=int)
        limit = min(limit, 100)  # Cap at 100 to prevent abuse
        
        metrics = current_app.s3_client.get_recent_metrics(
            metric_name=metric_name,
            limit=limit
        )
        
        return jsonify({
            'metric_name': metric_name,
            'count': len(metrics),
            'data': metrics
        })
    
    @app.route('/api/system/record', methods=['POST'])
    def record_system_metrics():
        """
        Capture and store current system metrics.
        Useful for scheduled metric collection.
        """
        metrics = get_system_metrics()
        results = []
        
        # Store each metric type
        metric_mappings = [
            ('cpu_percent', metrics['cpu']['percent']),
            ('memory_percent', metrics['memory']['percent']),
            ('disk_percent', metrics['disk']['percent'])
        ]
        
        for metric_name, value in metric_mappings:
            result = current_app.s3_client.store_metric(
                metric_name=metric_name,
                value=value,
                metadata={
                    'instance_id': get_instance_id(),
                    'environment': current_app.config['ENVIRONMENT']
                }
            )
            results.append(result)
        
        success_count = sum(1 for r in results if r['success'])
        
        return jsonify({
            'recorded': success_count,
            'total': len(results),
            'results': results
        }), 201 if success_count > 0 else 500
    
    # Error handlers
    @app.errorhandler(404)
    def not_found(error):
        return jsonify({
            'error': 'Not found',
            'path': request.path
        }), 404
    
    @app.errorhandler(500)
    def internal_error(error):
        logger.error(f"Internal server error: {error}")
        return jsonify({
            'error': 'Internal server error'
        }), 500


def get_system_metrics() -> dict:
    """
    Collect current system metrics using psutil.
    These metrics are what you'd typically monitor in production.
    """
    try:
        cpu_percent = psutil.cpu_percent(interval=0.1)
        memory = psutil.virtual_memory()
        disk = psutil.disk_usage('/')
        
        return {
            'cpu': {
                'percent': cpu_percent,
                'count': psutil.cpu_count()
            },
            'memory': {
                'percent': memory.percent,
                'total_gb': round(memory.total / (1024**3), 2),
                'available_gb': round(memory.available / (1024**3), 2),
                'used_gb': round(memory.used / (1024**3), 2)
            },
            'disk': {
                'percent': disk.percent,
                'total_gb': round(disk.total / (1024**3), 2),
                'free_gb': round(disk.free / (1024**3), 2)
            },
            'platform': {
                'system': platform.system(),
                'release': platform.release(),
                'python_version': platform.python_version()
            }
        }
    except Exception as e:
        logger.error(f"Error collecting system metrics: {e}")
        return {
            'error': str(e),
            'cpu': {'percent': 0, 'count': 0},
            'memory': {'percent': 0, 'total_gb': 0, 'available_gb': 0, 'used_gb': 0},
            'disk': {'percent': 0, 'total_gb': 0, 'free_gb': 0}
        }


def get_instance_id() -> str:
    """
    Get EC2 instance ID from metadata service.
    Falls back to hostname in non-EC2 environments.
    """
    # First check if we have it cached in environment
    instance_id = os.getenv('INSTANCE_ID')
    if instance_id:
        return instance_id
    
    # Try EC2 metadata service (IMDSv2)
    try:
        import requests
        
        # Get token first (IMDSv2 requirement)
        token_response = requests.put(
            'http://169.254.169.254/latest/api/token',
            headers={'X-aws-ec2-metadata-token-ttl-seconds': '21600'},
            timeout=1
        )
        token = token_response.text
        
        # Get instance ID using token
        id_response = requests.get(
            'http://169.254.169.254/latest/meta-data/instance-id',
            headers={'X-aws-ec2-metadata-token': token},
            timeout=1
        )
        return id_response.text
        
    except Exception:
        # Not on EC2 or metadata service unavailable
        return platform.node()