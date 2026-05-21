# BGP Router Default Route Configuration

## Overview

This deployment replaces AWS NAT Gateway default routes with custom FRRouting BGP routers for OpenShift worker nodes. This enables advanced routing capabilities, centralized traffic control, and cost optimization.

## Architecture

### Traffic Flow

```
Internet
    ↓
Internet Gateway (IGW)
    ↓
BGP Router Instance (t3.small, FRRouting)
    - iptables NAT (MASQUERADE)
    - BGP peering with worker nodes
    - Source/Dest check disabled
    ↓
Worker Nodes (c5.metal, bare metal)
    - Default route: 0.0.0.0/0 → BGP router
    - BGP peering enabled
    - VMs run on these nodes
    ↓
VMs (OpenShift Virtualization)
    - CUDN network (192.168.100.0/24)
    - Route via worker node → BGP router → Internet
```

### Routing Scope

**Worker Nodes Only:**
- Instance Type: `c5.metal` (bare metal workers)
- Tag: `node-role.kubernetes.io/worker-cnv`
- Default route: `0.0.0.0/0` → BGP router instance

**Control Plane Nodes:**
- Keep standard NAT Gateway routes
- No changes to routing

**Public Subnets:**
- Continue using Internet Gateway
- No changes

## Configuration Details

### VPC Route Tables

Each worker subnet has its route table updated:

**Before:**
```
Destination       Target
0.0.0.0/0        nat-xxxxxxxxx (NAT Gateway)
10.0.0.0/16      local
```

**After:**
```
Destination       Target
0.0.0.0/0        i-xxxxxxxxx (BGP Router Instance)
10.0.0.0/16      local
```

### BGP Router NAT Configuration

The BGP router performs NAT (Network Address Translation) for worker traffic:

```bash
# IP Forwarding
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# iptables NAT rule
iptables -t nat -A POSTROUTING -s 10.0.0.0/16 -o eth0 -j MASQUERADE
```

### BGP Peering

- **Hub Cluster ASN:** 64512
- **Managed Cluster ASN:** 64513
- **Router ASN:** 64500

BGP peers with bare metal worker nodes to advertise:
- CUDN network: 192.168.100.0/24
- Default route: 0.0.0.0/0 (via `default-originate`)

## Deployment

### Automatic Deployment

The worker BGP routing is configured automatically as part of the main deployment:

```bash
cd playbooks
ansible-playbook site.yml
```

Phase 14c runs after BGP configuration (phase 14) and before CUDN network setup (phase 15).

### Manual Configuration

To configure worker routing separately:

```bash
ansible-playbook playbooks/14c-worker-bgp-routing.yml
```

This will:
1. Configure NAT on BGP routers
2. Identify worker node subnets dynamically
3. Update route tables for worker subnets only
4. Validate routing and connectivity
5. Save route backups to `/tmp/route-backups/`

## Verification

### 1. Verify Router NAT Configuration

**Note:** With VPC peering configured, you can SSH directly from bastion to routers using private IPs. See [Bastion SSH Access](bastion-ssh-access.md) for details.

SSH to router from bastion:

```bash
# From bastion host
ROUTER_IP=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=frr-router-hub" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

# Direct SSH via VPC peering (no jump host needed)
ssh -i ~/.ssh/ocp-bastion-key ec2-user@${ROUTER_IP}

# Check IP forwarding
sysctl net.ipv4.ip_forward
# Should show: net.ipv4.ip_forward = 1

# Check NAT rules
sudo iptables -t nat -L POSTROUTING -n -v
# Should show MASQUERADE rule for 10.0.0.0/16

# Test internet
ping -c 3 8.8.8.8
curl http://ifconfig.me
```

### 2. Verify Route Tables

```bash
# List worker subnets
aws ec2 describe-instances \
  --region us-east-1 \
  --filters \
    "Name=instance-type,Values=c5.metal" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].SubnetId' \
  --output text | tr '\t' '\n' | sort -u

# Check route table for a worker subnet
SUBNET_ID=<subnet-id>
aws ec2 describe-route-tables \
  --region us-east-1 \
  --filters "Name=association.subnet-id,Values=${SUBNET_ID}" \
  --query 'RouteTables[0].Routes'

# Should show 0.0.0.0/0 pointing to router instance-id
```

### 3. Verify Worker Node Connectivity

**Note:** Use `oc debug` to access cluster nodes - OpenShift nodes don't allow direct SSH (security best practice).

```bash
# From bastion host
export KUBECONFIG=/home/ec2-user/cluster-hub/auth/kubeconfig

# Get worker nodes
oc get nodes -l node-role.kubernetes.io/worker-cnv

# Debug a worker node to test connectivity
oc debug node/<worker-name> -- chroot /host bash -c '
  # Test internet connectivity
  ping -c 3 8.8.8.8
  
  # Check public IP (should show router public IP if NAT working)
  curl -s http://ifconfig.me
  
  # Check routing table
  ip route
  # Should show: default via <router-private-ip>
'
```

### 4. Verify BGP Peering

On router:

```bash
sudo vtysh -c "show bgp summary"
# Should show established BGP sessions with worker nodes

sudo vtysh -c "show ip route"
# Should show routes learned from BGP
```

### 5. Test VM Internet Connectivity

```bash
# Create test VM
oc apply -f test-vm.yaml

# Start VM
virtctl start test-vm

# Console into VM
virtctl console test-vm

# From VM
ping -c 3 8.8.8.8
curl http://ifconfig.me
# Should succeed via: VM → Node → BGP Router → IGW → Internet
```

## Rollback

If routing issues occur or you need to revert to NAT Gateway routing:

### Automatic Rollback

```bash
ansible-playbook playbooks/78-rollback-vpc-routing.yml
```

This will:
1. Read route backups from `/tmp/route-backups/`
2. Delete current routes (to BGP router)
3. Restore original routes (to NAT Gateway)
4. Verify restoration

### Manual Rollback via AWS Console

1. Go to **VPC → Route Tables**
2. Find worker subnet route tables (check subnet associations)
3. Edit routes
4. Change `0.0.0.0/0` target from instance-id to nat-gateway-id
5. Save

Use the backup files in `/tmp/route-backups/` to find original NAT Gateway IDs.

### Manual Rollback via AWS CLI

```bash
# Get route table ID
RTB_ID=<route-table-id>

# Delete current route
aws ec2 delete-route \
  --region us-east-1 \
  --route-table-id ${RTB_ID} \
  --destination-cidr-block 0.0.0.0/0

# Restore NAT Gateway route
NAT_GW_ID=<from-backup-file>
aws ec2 create-route \
  --region us-east-1 \
  --route-table-id ${RTB_ID} \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id ${NAT_GW_ID}
```

## Troubleshooting

### Worker Nodes Cannot Reach Internet

**Symptom:** `ping 8.8.8.8` fails from worker nodes

**Check:**
1. Router has internet connectivity:
   ```bash
   ssh ec2-user@<router-ip>
   ping 8.8.8.8
   ```

2. Route table points to router:
   ```bash
   aws ec2 describe-route-tables --route-table-ids <rtb-id>
   # Check 0.0.0.0/0 target is router instance-id
   ```

3. NAT is configured on router:
   ```bash
   sudo iptables -t nat -L POSTROUTING -n -v
   # Should show MASQUERADE rule with packet counts > 0
   ```

4. IP forwarding enabled:
   ```bash
   sysctl net.ipv4.ip_forward
   # Should show 1
   ```

**Fix:**
```bash
# Re-run NAT configuration
ansible-playbook playbooks/76-configure-bgp-router-nat.yml
```

### BGP Peering Not Established

**Symptom:** `vtysh -c "show bgp summary"` shows peers in Idle/Connect state

**Check:**
1. Security groups allow BGP (port 179)
2. Worker nodes have FRRConfiguration resources
3. Router is reachable from worker nodes

**Fix:**
```bash
# Re-run BGP configuration
ansible-playbook playbooks/14-bgp-configuration.yml
```

### Route Table Update Failed

**Symptom:** Route table still points to NAT Gateway

**Check:**
1. Worker nodes exist and are running
2. Router instance is running
3. AWS permissions allow route table modifications

**Fix:**
```bash
# Re-run worker routing configuration
ansible-playbook playbooks/14c-worker-bgp-routing.yml
```

### VMs Cannot Reach Internet

**Symptom:** Ping/curl fails from VMs

**Check:**
1. CUDN network configured correctly
2. Worker node routing works (test from worker)
3. BGP advertising CUDN routes

**Troubleshooting:**
```bash
# On worker node
ip route show table 1007
# Should show CUDN routes

# On router
sudo vtysh -c "show ip bgp 192.168.100.0/24"
# Should show CUDN prefix
```

## Cost Comparison

### Before (NAT Gateway)
- NAT Gateway: ~$0.045/hour × 3 AZs = $0.135/hour (~$99/month)
- Data processing: $0.045/GB

### After (BGP Router)
- t3.small: ~$0.021/hour × 2 routers = $0.042/hour (~$31/month)
- No data processing charges

**Savings:** ~$68/month per cluster (~69% reduction)

## High Availability (Future)

Current setup uses single router per VPC (simple, but single point of failure).

For production HA, consider:

1. **Active-Standby**
   - Deploy two routers per VPC
   - Health check monitors primary
   - Automatic failover updates route tables

2. **Active-Active with ECMP**
   - Deploy two routers per VPC
   - Use equal-cost multipath routing
   - AWS supports multiple routes for same prefix

3. **Transit Gateway**
   - For large-scale deployments (>3 VPCs)
   - Centralized routing hub
   - Simplified management

## Related Documentation

- [Multi-VPC Setup](multi-vpc-setup.md) - VPC architecture and peering
- [BGP Configuration](../playbooks/14-bgp-configuration.yml) - BGP peering setup
- [CUDN Network](../playbooks/15-cudn-network.yml) - VM networking

## Configuration Variables

Key variables in `group_vars/all.yml`:

```yaml
# BGP Router Routing Configuration
router_nat_enabled: true
worker_routing_enabled: true
worker_instance_type: c5.metal
worker_node_role_tag: "node-role.kubernetes.io/worker-cnv"

# Route table backup location
route_backup_dir: /tmp/route-backups

# Health check settings
health_check_enabled: true
health_check_retries: 3
health_check_delay: 10
```

## Security Considerations

1. **Router Security**
   - Routers in public subnets (need public IP for IGW access)
   - Security groups restrict access to VPC CIDRs
   - SSH access via bastion only

2. **Route Hijacking Protection**
   - Only worker subnet routes modified
   - Control plane unaffected
   - BGP prefix filters in place

3. **Traffic Inspection**
   - All worker traffic passes through router
   - Can add logging/monitoring/DPI
   - Compliance and audit trails possible

## Monitoring

### CloudWatch Metrics

Monitor router instances:
- CPU utilization
- Network in/out
- Status checks

### BGP Monitoring

```bash
# Check BGP session status
sudo vtysh -c "show bgp summary"

# Check advertised routes
sudo vtysh -c "show ip bgp neighbors <neighbor> advertised-routes"

# Check received routes
sudo vtysh -c "show ip bgp neighbors <neighbor> routes"
```

### NAT Monitoring

```bash
# Check NAT rule packet counters
sudo iptables -t nat -L POSTROUTING -n -v

# Monitor connection tracking
sudo conntrack -L | wc -l
```

## Support

For issues or questions:
1. Check troubleshooting section above
2. Review playbook logs in `/var/log/ocp-deployment.log`
3. Check route backups in `/tmp/route-backups/`
4. Rollback if needed using playbook 78
