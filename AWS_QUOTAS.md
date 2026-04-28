# AWS Quota Requirements for Dual Cluster Deployment

This deployment creates two OpenShift clusters in the same AWS region, which requires increased AWS quotas beyond the defaults.

**NEW**: The playbook now **automatically requests quota increases** and can wait for approval! See "Automatic Quota Increase" section below.

## Required Quotas

### Elastic IPs (Most Critical)

**Default**: 5 per region  
**Required**: 10-15 per region

**Why**: 
- 3 NAT Gateways (shared VPC): 3 EIPs
- Each OpenShift cluster creates ~2-3 load balancers: 4-6 EIPs
- **Total**: 8-10 EIPs minimum

### VPCs

**Default**: 5 per region  
**Required**: 1 (shared by both clusters)

No increase needed - we create one VPC for both clusters.

### EC2 Instances

**Default**: Varies by instance type  
**Required**:
- Bastion: 1x t3.medium
- Control plane: 6x m5.xlarge (3 per cluster)
- Workers: 6x m5.2xlarge (3 per cluster)
- Bare metal: 4x c5.metal (2 per cluster)

**Total**: ~17 instances

Check your limits for:
- `m5.xlarge`: Need at least 6
- `m5.2xlarge`: Need at least 6
- `c5.metal`: Need at least 4

## Automatic Quota Increase (Recommended)

**The playbook handles this for you!**

When you run the playbook, it automatically checks your quotas. If insufficient, it will prompt:

```
==========================================
Elastic IP Quota Insufficient
==========================================
Available: 2 EIPs
Required: ~8 EIPs

Options:
  1. Request quota increase and wait (recommended)
  2. Request increase but continue (risky)
  3. Continue anyway (will likely fail)
  4. Abort deployment

Enter your choice (1-4):
```

### Option 1: Request and Wait (Recommended)

The playbook will:
1. ✅ Submit quota increase request to AWS
2. ✅ Display request ID and status
3. ✅ Poll every 60 seconds for approval
4. ✅ Continue automatically when approved
5. ✅ Refresh quotas before proceeding

**Timeline**: Usually 15-30 minutes, max 60 minutes

**Safe to interrupt**: Press Ctrl+C during wait - request stays active, re-run playbook to check status

### Option 2: Request but Continue

- Requests the increase
- Continues deployment immediately
- **Risk**: May fail when creating NAT gateways or load balancers

### Option 3: Continue Anyway

- No quota request
- **Will likely fail** during infrastructure creation

### Option 4: Abort

- Exits safely
- Request quota manually or wait and re-run

## Manual Quota Increase (If Needed)

If automatic request fails or you prefer manual control:

## How to Request Quota Increases

### Option 1: AWS Console

1. Go to [AWS Service Quotas Console](https://console.aws.amazon.com/servicequotas)
2. Select region: **us-east-1** (or your target region)
3. Search for the quota:
   - **"EC2-VPC Elastic IPs"** - Request increase to **15**
   - **"Running On-Demand All Standard instances"** - Check your vCPU limits
   - **"Running On-Demand c instances"** - For c5.metal (metal instances)
4. Click "Request quota increase"
5. Enter desired value
6. Submit request

**Timeline**: Usually approved in 15-30 minutes for standard quotas, up to 2 business days for metal instances.

### Option 2: AWS CLI

```bash
# Request Elastic IP increase to 15
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-0263D0A3 \
  --desired-value 15 \
  --region us-east-1

# Check request status
aws service-quotas list-requested-service-quota-change-history-by-quota \
  --service-code ec2 \
  --quota-code L-0263D0A3 \
  --region us-east-1
```

### Option 3: AWS Support

For larger increases or metal instances:
1. Go to [AWS Support Center](https://console.aws.amazon.com/support)
2. Create case: "Service limit increase"
3. Select "EC2 Instances" or "VPC"
4. Specify region and desired limits
5. Explain use case: "Deploying two OpenShift clusters for testing/development"

## Alternative: Deploy to Different Regions

If quota increases are delayed, you can deploy clusters to different regions:

### Edit `group_vars/all.yml`:

```yaml
# Cluster 1 - us-east-1
clusters:
  - name: hub-cluster
    aws_region: us-east-1  # Add this
    base_domain: example.com
    cluster_name: hub
    # ... rest of config

  - name: managed-cluster
    aws_region: us-west-2  # Different region
    base_domain: example.com
    cluster_name: managed
    # ... rest of config
```

**Note**: This requires modifying the playbooks to handle multi-region deployment (not currently supported).

## Checking Current Quotas

### Before Running Playbook

The playbook automatically checks quotas during prerequisites and will warn you if insufficient.

### Manual Check

```bash
# Elastic IP quota
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-0263D0A3 \
  --region us-east-1

# Current Elastic IP usage
aws ec2 describe-addresses --region us-east-1

# VPC quota
aws service-quotas get-service-quota \
  --service-code vpc \
  --quota-code L-F678F1CE \
  --region us-east-1

# Current VPC usage
aws ec2 describe-vpcs --region us-east-1

# EC2 instance limits (vCPUs)
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --region us-east-1
```

## What Happens if Quota Exceeded

If quotas are exceeded during deployment:

1. **Elastic IPs**: NAT gateway or load balancer creation fails
   - Error: `AddressLimitExceeded`
   - Solution: Request quota increase, wait for approval, re-run playbook

2. **EC2 Instances**: Cluster node creation fails
   - Error: `InstanceLimitExceeded` or `VcpuLimitExceeded`
   - Solution: Request quota increase for instance type

3. **VPCs**: VPC creation fails (unlikely with our setup)
   - Error: `VpcLimitExceeded`

## Quota Increase Best Practices

1. **Request early**: Submit quota increase requests before starting deployment
2. **Be generous**: Request more than minimum (e.g., 20 EIPs instead of 10)
3. **Document use case**: Helps AWS approve faster
4. **Check regularly**: Quotas can change or reset
5. **Plan for growth**: If testing multiple scenarios, request higher limits

## Cost Considerations

Quota increases themselves are free, but using resources has costs:

- **Elastic IPs**: $0.005/hour when not attached to running instance
- **NAT Gateways**: $0.045/hour + data transfer
- **EC2 Instances**: Varies by type (c5.metal is ~$4.08/hour)

For this deployment, estimated hourly cost: **$50-80/hour** in us-east-1.

**Recommendation**: Delete resources when not in use to avoid unnecessary charges.

## Getting Help

If you encounter quota issues:
1. Check this guide
2. Review AWS Service Quotas documentation
3. Contact AWS Support
4. Check the playbook prerequisites output for specific guidance
