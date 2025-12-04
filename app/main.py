"""
DevOps Metrics Dashboard
A production-ready Flask application for infrastructure health monitoring.

This application demonstrates:
- AWS integration with boto3 (S3 storage)
- Health check endpoints for load balancer integration
- Environment-based configuration (12-factor app)
- Proper logging practices
"""

import os
import logging
from flask import Flask
from routes import register_routes
from s3_client import S3Client

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def create_app():
    """Application factory pattern - recommended for production Flask apps."""
    app = Flask(__name__)
    
    # Load configuration from environment variables (12-factor app principle)
    app.config.update(
        APP_NAME=os.getenv('APP_NAME', 'DevOps Metrics Dashboard'),
        AWS_REGION=os.getenv('AWS_REGION', 'us-east-1'),
        S3_BUCKET=os.getenv('S3_BUCKET', 'devops-metrics-bucket'),
        ENVIRONMENT=os.getenv('ENVIRONMENT', 'development'),
        DEBUG=os.getenv('DEBUG', 'False').lower() == 'true'
    )
    
    # Initialize S3 client and attach to app context
    app.s3_client = S3Client(
        bucket_name=app.config['S3_BUCKET'],
        region=app.config['AWS_REGION']
    )
    
    # Register all routes
    register_routes(app)
    
    logger.info(f"Application initialized: {app.config['APP_NAME']}")
    logger.info(f"Environment: {app.config['ENVIRONMENT']}")
    logger.info(f"S3 Bucket: {app.config['S3_BUCKET']}")
    
    return app


if __name__ == '__main__':
    app = create_app()
    
    # Get port from environment (useful for container deployments)
    port = int(os.getenv('PORT', 5000))
    
    # In production, use gunicorn instead of Flask's built-in server
    # gunicorn -w 4 -b 0.0.0.0:5000 "main:create_app()"
    app.run(
        host='0.0.0.0',
        port=port,
        debug=app.config['DEBUG']
    )