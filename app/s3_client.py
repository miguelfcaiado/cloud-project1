"""
S3 Client Module
Handles all interactions with AWS S3 for metrics storage.

This module demonstrates:
- boto3 SDK usage
- Error handling for AWS operations
- JSON serialization for metrics data
"""

import json
import logging
from datetime import datetime
from typing import Optional

import boto3
from botocore.exceptions import ClientError, NoCredentialsError

logger = logging.getLogger(__name__)


class S3Client:
    """
    S3 Client for storing and retrieving metrics data.
    
    In production, credentials are provided via:
    - IAM Instance Profile (EC2)
    - IAM Role (EKS/ECS)
    - Environment variables (local development)
    """
    
    def __init__(self, bucket_name: str, region: str = 'us-east-1'):
        self.bucket_name = bucket_name
        self.region = region
        self._client = None
        
    @property
    def client(self):
        """Lazy initialization of boto3 client."""
        if self._client is None:
            try:
                self._client = boto3.client('s3', region_name=self.region)
                logger.info(f"S3 client initialized for region: {self.region}")
            except NoCredentialsError:
                logger.warning("AWS credentials not found. S3 operations will fail.")
                self._client = None
        return self._client
    
    def store_metric(self, metric_name: str, value: float, metadata: Optional[dict] = None) -> dict:
        """
        Store a metric data point in S3.
        
        Args:
            metric_name: Name of the metric (e.g., 'cpu_usage', 'request_count')
            value: Numeric value of the metric
            metadata: Optional additional context
            
        Returns:
            dict with success status and storage location
        """
        timestamp = datetime.utcnow()
        
        # Create structured metric object
        metric_data = {
            'metric_name': metric_name,
            'value': value,
            'timestamp': timestamp.isoformat(),
            'metadata': metadata or {}
        }
        
        # S3 key pattern: metrics/YYYY/MM/DD/metric_name/timestamp.json
        # This pattern enables efficient time-based queries
        s3_key = (
            f"metrics/{timestamp.year}/{timestamp.month:02d}/{timestamp.day:02d}/"
            f"{metric_name}/{timestamp.strftime('%H%M%S%f')}.json"
        )
        
        try:
            if self.client is None:
                return {
                    'success': False,
                    'error': 'S3 client not available (check AWS credentials)',
                    'metric': metric_data
                }
            
            self.client.put_object(
                Bucket=self.bucket_name,
                Key=s3_key,
                Body=json.dumps(metric_data),
                ContentType='application/json'
            )
            
            logger.info(f"Metric stored: {metric_name}={value} at s3://{self.bucket_name}/{s3_key}")
            
            return {
                'success': True,
                'location': f"s3://{self.bucket_name}/{s3_key}",
                'metric': metric_data
            }
            
        except ClientError as e:
            error_code = e.response['Error']['Code']
            error_msg = e.response['Error']['Message']
            logger.error(f"S3 error storing metric: {error_code} - {error_msg}")
            
            return {
                'success': False,
                'error': f"{error_code}: {error_msg}",
                'metric': metric_data
            }
    
    def get_recent_metrics(self, metric_name: str, limit: int = 10) -> list:
        """
        Retrieve recent metrics from S3.
        
        Args:
            metric_name: Name of the metric to retrieve
            limit: Maximum number of metrics to return
            
        Returns:
            List of metric objects, most recent first
        """
        today = datetime.utcnow()
        prefix = f"metrics/{today.year}/{today.month:02d}/{today.day:02d}/{metric_name}/"
        
        try:
            if self.client is None:
                logger.warning("S3 client not available")
                return []
            
            response = self.client.list_objects_v2(
                Bucket=self.bucket_name,
                Prefix=prefix,
                MaxKeys=limit
            )
            
            metrics = []
            for obj in response.get('Contents', []):
                try:
                    result = self.client.get_object(
                        Bucket=self.bucket_name,
                        Key=obj['Key']
                    )
                    metric_data = json.loads(result['Body'].read().decode('utf-8'))
                    metrics.append(metric_data)
                except Exception as e:
                    logger.error(f"Error reading metric {obj['Key']}: {e}")
                    continue
            
            # Sort by timestamp descending
            metrics.sort(key=lambda x: x.get('timestamp', ''), reverse=True)
            
            return metrics[:limit]
            
        except ClientError as e:
            logger.error(f"S3 error retrieving metrics: {e}")
            return []
    
    def check_bucket_access(self) -> dict:
        """
        Verify S3 bucket exists and is accessible.
        Useful for health checks and debugging.
        """
        try:
            if self.client is None:
                return {
                    'accessible': False,
                    'error': 'S3 client not initialized'
                }
            
            self.client.head_bucket(Bucket=self.bucket_name)
            
            return {
                'accessible': True,
                'bucket': self.bucket_name,
                'region': self.region
            }
            
        except ClientError as e:
            error_code = e.response['Error']['Code']
            
            if error_code == '404':
                error_msg = f"Bucket '{self.bucket_name}' does not exist"
            elif error_code == '403':
                error_msg = f"Access denied to bucket '{self.bucket_name}'"
            else:
                error_msg = str(e)
            
            return {
                'accessible': False,
                'error': error_msg
            }