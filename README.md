# Project 1: DevOps Metrics Dashboard


## Project Summary

Built and deployed a **production-grade Python web application** on AWS with high availability, auto-scaling, and infrastructure best practices.

### What I Built

A real-time infrastructure monitoring dashboard that:
- Displays system metrics (CPU, Memory, Disk usage)
- Stores metrics to S3 for historical analysis
- Runs behind a load balancer with auto-scaling
- Follows AWS Well-Architected Framework principles

### Technologies Used

| Category | Technologies |
|----------|--------------|
| **Application** | Python, Flask, Gunicorn, Jinja2 |
| **AWS Compute** | EC2, Auto Scaling Groups, Launch Templates |
| **AWS Networking** | VPC, Subnets, Internet Gateway, NAT Gateway, ALB |
| **AWS Storage** | S3 |
| **AWS Security** | IAM Roles/Policies, Security Groups |
| **AWS Monitoring** | CloudWatch, Target Group Health Checks |
| **Infrastructure** | User Data scripts, Systemd services |

---

## Architecture Decisions & Why

### 1. Private Subnets for EC2 Instances

**Decision**: Application servers run in private subnets, not public.

**Why**: 
- EC2 instances have no public IP addresses
- Cannot be directly accessed from the internet
- Only the ALB (in public subnets) can reach them
- Reduces attack surface significantly


---

### 2. NAT Gateway for Outbound Traffic

**Decision**: Used NAT Gateway instead of placing instances in public subnets.

**Why**:
- Private instances still need outbound internet access (package updates, GitHub, PyPI)
- NAT Gateway provides outbound-only connectivity
- Instances can reach the internet, but internet can't reach instances


---

### 3. Application Load Balancer (ALB) over Network Load Balancer

**Decision**: Chose ALB instead of NLB.

**Why**:
- ALB operates at Layer 7 (HTTP/HTTPS)
- Supports path-based routing (/health, /metrics, /api/*)
- Native health checks on HTTP endpoints
- Better suited for web applications


---

### 4. Multi-AZ Deployment

**Decision**: Deployed across 2 Availability Zones.

**Why**:
- If one AZ fails, application continues running
- ALB automatically routes traffic to healthy instances
- Auto Scaling Group launches replacements in available AZs


---

### 5. Health Check Endpoint Design

**Decision**: Created a dedicated `/health` endpoint that returns HTTP 200.

**Why**:
- Lightweight — doesn't load the full application
- Returns quickly (no database queries, minimal processing)
- ALB marks instances unhealthy if this fails
- Separates "app is running" from "app is fully functional"


---

### 6. Auto Scaling Configuration

**Decision**: Min 2, Max 4, scale at 70% CPU.

**Why**:
- Min 2 ensures high availability (one can fail)
- 70% threshold leaves headroom before saturation
- Max 4 controls costs while allowing burst capacity


---

### 7. IAM Role Instead of Access Keys

**Decision**: Used IAM Instance Profile, not hardcoded credentials.

**Why**:
- Credentials rotate automatically
- No secrets in code or environment files
- Follows AWS security best practices
- Can be audited via CloudTrail


---

### 8. User Data for Bootstrap

**Decision**: Used User Data scripts instead of custom AMIs.

**Why**:
- Infrastructure as Code — script is version controlled
- Easy to update — change script, refresh instances
- Always gets latest code from GitHub
- No AMI management overhead



```
