# Multi-VPC Setup with VPC Peering

## Overview

This deployment uses separate VPCs for each component with non-overlapping CIDR ranges and VPC peering to enable cross-VPC communication.

## VPC Configuration

### CIDR Allocations

| VPC Name | CIDR Range | Purpose | Clusters |
|----------|------------|---------|----------|
| bastion-vpc | 10.255.0.0/16 | Bastion host and management | N/A |
| hub-cluster-vpc | 10.0.0.0/16 | Hub OpenShift cluster | hub |
| managed-cluster-vpc | 10.1.0.0/16 | Managed OpenShift cluster | managed |

### Subnet Breakdown

#### Bastion VPC (10.255.0.0/16)
- **Public Subnet**: 10.255.1.0/24 (us-east-1a)
- **Private Subnet**: 10.255.11.0/24 (us-east-1a)

#### Hub Cluster VPC (10.0.0.0/16)
- **Public Subnets**:
  - 10.0.1.0/24 (us-east-1a)
  - 10.0.2.0/24 (us-east-1b)
  - 10.0.3.0/24 (us-east-1c)
- **Private Subnets**:
  - 10.0.11.0/24 (us-east-1a)
  - 10.0.12.0/24 (us-east-1b)
  - 10.0.13.0/24 (us-east-1c)

#### Managed Cluster VPC (10.1.0.0/16)
- **Public Subnets**:
  - 10.1.1.0/24 (us-east-1a)
  - 10.1.2.0/24 (us-east-1b)
  - 10.1.3.0/24 (us-east-1c)
- **Private Subnets**:
  - 10.1.11.0/24 (us-east-1a)
  - 10.1.12.0/24 (us-east-1b)
  - 10.1.13.0/24 (us-east-1c)

## VPC Peering

VPC peering is enabled between all VPCs to allow cross-VPC communication:

1. **Bastion ↔ Hub**: Allows bastion to manage hub cluster
2. **Bastion ↔ Managed**: Allows bastion to manage managed cluster
3. **Hub ↔ Managed**: Allows communication between clusters (required for ACM)

### Routing

Each VPC's route tables include routes to all peered VPCs:

- Bastion VPC routes to 10.0.0.0/16 (hub) and 10.1.0.0/16 (managed)
- Hub VPC routes to 10.255.0.0/16 (bastion) and 10.1.0.0/16 (managed)
- Managed VPC routes to 10.255.0.0/16 (bastion) and 10.0.0.0/16 (hub)

## Security Groups

Security groups are configured to allow:

1. **Cross-VPC traffic**: All VPCs can communicate with each other
2. **Kubernetes API access**: Port 6443 accessible from bastion and other clusters
3. **SSH access**: Bastion can SSH to router instances via VPC peering
4. **Public ingress**: HTTP/HTTPS accessible from internet

### Router Security Groups

Router instances have explicit security group rules for SSH access:

```yaml
# Explicit SSH from bastion VPC (for auditing)
- Protocol: TCP
  Port: 22
  Source: 10.255.0.0/16

# All traffic from bastion VPC  
- Protocol: All
  Source: 10.255.0.0/16

# All traffic within cluster VPC
- Protocol: All
  Source: 10.0.0.0/16 (hub) or 10.1.0.0/16 (managed)
```

## Bastion Direct Access via VPC Peering

With VPC peering configured between bastion VPC and all cluster VPCs, the bastion host can directly access router instances without SSH helper pods or EC2 Instance Connect.

### Direct SSH to Routers

From bastion host:

```bash
# Get router private IPs
HUB_ROUTER_IP=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=frr-router-hub" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

MANAGED_ROUTER_IP=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=frr-router-managed" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

# Direct SSH (no EC2 Instance Connect needed)
ssh -i ~/.ssh/ocp-bastion-key ec2-user@${HUB_ROUTER_IP}
ssh -i ~/.ssh/ocp-bastion-key ec2-user@${MANAGED_ROUTER_IP}
```

### Why VPC Peering Simplifies Access

**Before VPC Peering:**
- Bastion VPC (10.255.0.0/16) had no route to cluster VPCs
- Required SSH helper pods running inside clusters
- Used EC2 Instance Connect for temporary SSH key authorization
- Complex nested SSH: `bastion → oc exec ssh-helper → router`

**After VPC Peering:**
- Route tables updated with peering routes
- Bastion can reach router private IPs directly
- No SSH helper pods needed
- Simple direct SSH: `bastion → router`

**Benefits:**
- No dependency on Kubernetes API for router access
- Works even if cluster degraded
- Simpler troubleshooting
- No 60-second EC2 Instance Connect time window
- No Kubernetes secret management for SSH keys

### Accessing Cluster Nodes

**Important:** OpenShift cluster nodes do NOT support direct SSH. Use `oc debug node/<node-name>` instead.

```bash
# From bastion host
export KUBECONFIG=/home/ec2-user/cluster-hub/auth/kubeconfig

# List nodes
oc get nodes

# Access a node
oc debug node/<node-name>
```

This is a security best practice:
- Nodes are immutable infrastructure
- Access is logged via Kubernetes API
- RBAC-controlled access
- No SSH key distribution needed

For complete SSH access documentation, see [Bastion SSH Access](bastion-ssh-access.md).

## Benefits

1. **Network Isolation**: Each cluster operates in its own VPC
2. **Non-overlapping IPs**: No CIDR conflicts between clusters
3. **Flexible Scaling**: Easy to add more clusters with new VPCs
4. **Security**: Network-level isolation with controlled peering
5. **Cost Optimization**: Shared bastion reduces costs

## Adding Additional Clusters

To add a new cluster:

1. Choose a new non-overlapping CIDR range (e.g., 10.2.0.0/16)
2. Add VPC configuration to `group_vars/all.yml` in the `vpcs` list
3. Add cluster configuration to `clusters` list with matching `vpc_name`
4. Update VPC peering in `vpc_multi.yml` to peer new VPC with existing VPCs
5. Run the playbook

## Troubleshooting

### Check VPC Peering Status
```bash
aws ec2 describe-vpc-peering-connections \
  --region us-east-1 \
  --filters "Name=tag:Project,Values=openshift-dual-cluster"
```

### Verify Route Tables
```bash
# Bastion VPC routes
aws ec2 describe-route-tables \
  --region us-east-1 \
  --filters "Name=vpc-id,Values=<bastion_vpc_id>"

# Hub cluster VPC routes
aws ec2 describe-route-tables \
  --region us-east-1 \
  --filters "Name=vpc-id,Values=<hub_vpc_id>"
```

### Test Connectivity
From bastion host:
```bash
# Test connection to hub cluster API
curl -k https://<hub-api-endpoint>:6443

# Test connection to managed cluster API
curl -k https://<managed-api-endpoint>:6443
```

## Worker Node Routing via BGP Routers

### Overview

Worker nodes (bare metal c5.metal instances) use custom BGP routers for internet access instead of AWS NAT Gateways. This provides:
- Advanced routing capabilities for VMs
- BGP-based route advertisement
- Centralized traffic control
- Cost savings (~$68/month per cluster)

### Routing Architecture

```
Worker Node (c5.metal)
  ↓ (default route: 0.0.0.0/0)
BGP Router Instance (t3.small)
  ↓ (iptables NAT + BGP peering)
Internet Gateway
  ↓
Internet
```

**Control plane nodes** continue using standard NAT Gateway routes (unchanged).

### Route Table Configuration

Worker subnet route tables are automatically updated during deployment (phase 14c):

**Before:**
- `0.0.0.0/0` → NAT Gateway

**After:**
- `0.0.0.0/0` → BGP Router Instance

Route backups are saved to `/tmp/route-backups/` for rollback if needed.

### Verification

```bash
# Check worker route table
aws ec2 describe-route-tables \
  --region us-east-1 \
  --filters "Name=association.subnet-id,Values=<worker-subnet-id>" \
  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]'

# Should show instance-id (BGP router) not nat-gateway-id
```

### Rollback

To restore NAT Gateway routing:

```bash
ansible-playbook playbooks/78-rollback-vpc-routing.yml
```

See [BGP Router Default Route](bgp-router-default-route.md) for detailed configuration and troubleshooting.

## Configuration Files

- **Main config**: `group_vars/all.yml`
- **VPC tasks**: `roles/aws_infrastructure/tasks/vpc_multi.yml`
- **Security groups**: `roles/aws_infrastructure/tasks/security_groups_multi.yml`
- **Install config template**: `roles/openshift_installer/templates/install-config.yaml.j2`
- **Worker routing**: `playbooks/14c-worker-bgp-routing.yml`
