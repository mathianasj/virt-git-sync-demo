# BGP Router NAT Configuration

## Overview

This document describes how the BGP routers are configured to provide internet access for OpenShift worker nodes through NAT gateway routing.

## Architecture

```
Worker Nodes (10.X.11.0/24)
    |
    | VPC Route: 0.0.0.0/0 → BGP Router ENI
    |
    v
BGP Router (2 ENIs)
    ├─ ens5 (10.X.11.224) - Worker subnet (private)
    └─ ens6 (10.X.1.Y)   - Public subnet
        |
        | Default Route: via NAT Gateway IP
        |
        v
NAT Gateway (10.X.1.99)
    |
    v
Internet Gateway
    |
    v
Internet
```

## Configuration Details

### 1. Router Network Interfaces

Each BGP router has two Elastic Network Interfaces (ENIs):

- **Primary ENI (ens5)**:
  - Located in worker subnet (10.0.11.0/24 for hub, 10.1.11.0/24 for managed)
  - Static IP: 10.0.11.111 (hub), 10.1.11.224 (managed)
  - Used for BGP peering with worker nodes
  - Direct connection to worker nodes

- **Secondary ENI (ens6)**:
  - Located in public subnet (10.0.1.0/24 for hub, 10.1.1.0/24 for managed)
  - DHCP-assigned IP in public subnet
  - Connected to NAT gateway subnet
  - Used for internet-bound traffic

### 2. Router Routing Configuration

**Clean Routing Table** (DHCP routes removed):
```
default via 10.X.1.99 dev ens6 proto static onlink
10.X.1.0/24 dev ens6 proto kernel scope link src 10.X.1.Y metric 513
10.X.11.0/24 dev ens5 proto kernel scope link src 10.X.11.224 metric 512
```

**Key Points**:
- Single default route pointing to NAT gateway private IP
- DHCP default routes are removed by systemd service
- Local subnet routes remain for direct connectivity

### 3. NAT Configuration

**iptables MASQUERADE Rule**:
```bash
iptables -t nat -A POSTROUTING -o ens6 -j MASQUERADE
```

This rule:
- Applies to all traffic exiting via ens6 (public subnet interface)
- Changes source IP from worker node IP (10.X.11.Y) to router's ens6 IP
- Allows NAT gateway to route return traffic back through router

**Persistence**:
- Managed by `iptables-services` package
- Rules saved to `/etc/sysconfig/iptables`
- Loaded automatically at boot via systemd

### 4. Systemd Service for Route Management

**Service**: `bgp-router-routes.service`

**Purpose**: Removes DHCP-added default routes and sets static default route

**Service Definition**:
```ini
[Unit]
Description=Configure BGP router static routes
After=systemd-networkd.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  sleep 5; \
  ip route del default via 10.X.11.1 dev ens5 2>/dev/null || true; \
  ip route del default via 10.X.1.1 dev ens6 proto dhcp 2>/dev/null || true; \
  ip route del 10.X.0.2 via 10.X.11.1 dev ens5 2>/dev/null || true; \
  ip route del 10.X.0.2 via 10.X.1.1 dev ens6 2>/dev/null || true; \
  ip route add default via 10.X.1.99 dev ens6 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

**Why This is Needed**:
- Amazon Linux 2023 uses systemd-networkd
- DHCP client automatically adds default routes
- `UseRoutes=false` in networkd config doesn't work reliably
- This service runs after network is up and removes unwanted routes

### 5. VPC Route Table Configuration

**Private Subnet Route Table Changes**:

Before:
```
0.0.0.0/0 → nat-XXXXXXXXX (NAT Gateway)
10.X.0.0/16 → local
```

After:
```
0.0.0.0/0 → eni-XXXXXXXXX (BGP Router Primary ENI)
10.X.0.0/16 → local
```

This change:
- Redirects all internet-bound traffic from workers to BGP router
- Workers no longer directly access NAT gateway
- Traffic flow: Worker → VPC Route → BGP Router → NAT Gateway → Internet

### 6. Security Group Configuration

**BGP Router Security Groups**:

Must allow traffic from both VPC CIDRs:
- Hub router: allows 10.0.0.0/16
- Managed router: allows 10.1.0.0/16

**Critical Rule**:
```bash
# Allow all traffic from cluster VPC
aws ec2 authorize-security-group-ingress \
  --group-id <router-sg> \
  --protocol -1 \
  --cidr 10.X.0.0/16
```

**Common Issue**: If security group only allows traffic from wrong VPC CIDR (e.g., managed router allowing only 10.0.0.0/16 instead of 10.1.0.0/16), nodes cannot ping the router.

### 7. Source/Destination Check

**Must be disabled on ALL router ENIs**:

```bash
# For each ENI attached to router
aws ec2 modify-network-interface-attribute \
  --network-interface-id eni-XXXXXXXXX \
  --no-source-dest-check
```

**Why**:
- Allows router to forward traffic with source IPs that don't match its own
- Required for NAT and routing functionality
- Must be set per-ENI when multiple interfaces exist

## Traffic Flow

### Outbound Traffic (Worker → Internet)

1. Worker node sends packet to 8.8.8.8
   - Source: 10.1.11.36
   - Destination: 8.8.8.8

2. Worker's routing table: `default via 10.1.11.1`
   - But VPC route table overrides: 0.0.0.0/0 → BGP Router ENI

3. Packet arrives at BGP router ens5 (10.1.11.224)
   - Source: 10.1.11.36
   - Destination: 8.8.8.8

4. Router forwards packet via ens6
   - iptables MASQUERADE changes source to router's ens6 IP
   - Source: 10.1.1.235 (router ens6)
   - Destination: 8.8.8.8

5. Packet sent to NAT gateway (10.1.1.99)

6. NAT gateway changes source to public IP
   - Source: <NAT Gateway Public IP>
   - Destination: 8.8.8.8

7. Packet reaches internet via Internet Gateway

### Return Traffic (Internet → Worker)

1. Response packet arrives at NAT gateway
   - Destination: <NAT Gateway Public IP>

2. NAT gateway maps back to router ens6 IP
   - Destination: 10.1.1.235

3. Packet arrives at router ens6

4. Router's iptables NAT table tracks connection state

5. Router forwards packet to original worker via ens5
   - Destination: 10.1.11.36

6. Worker receives response packet

## Deployment via Ansible

### Playbook: `playbooks/13-frr-routers.yml`

**When `router_nat_enabled: true`** (in `group_vars/all.yml`):

1. **Creates/validates security groups** with correct VPC CIDR rules
2. **Creates second ENI** in public subnet for each router
3. **Attaches ENI** to router instance (device index 1)
4. **Disables source/dest check** on all ENIs
5. **Configures router via SSH**:
   - Installs iptables-services
   - Enables IP forwarding
   - Adds MASQUERADE rule
   - Creates systemd service for route management
   - Applies routing configuration
6. **Updates VPC route tables** to point default routes to router ENIs

### Key Variables

```yaml
# In group_vars/all.yml
router_nat_enabled: true
hub_router_ip: 10.0.11.111
managed_router_ip: 10.1.11.224
```

## Troubleshooting

### Workers Can't Reach Internet

**Check 1**: Verify VPC route table
```bash
aws ec2 describe-route-tables --route-table-ids rtb-XXXXXXXXX
# Should show: 0.0.0.0/0 → eni-XXXXXXXXX (router ENI)
```

**Check 2**: Verify router routing
```bash
ssh router
ip route show
# Should show: default via 10.X.1.99 dev ens6
```

**Check 3**: Verify NAT rules
```bash
ssh router
sudo iptables -t nat -L POSTROUTING -n -v
# Should show: MASQUERADE ... out ens6
```

**Check 4**: Verify IP forwarding
```bash
ssh router
sysctl net.ipv4.ip_forward
# Should show: net.ipv4.ip_forward = 1
```

**Check 5**: Verify security group
```bash
# Check if router SG allows traffic from worker VPC
aws ec2 describe-security-groups --group-ids sg-XXXXXXXXX
# Should show rule: -1 (all) from 10.X.0.0/16
```

**Check 6**: Test connectivity steps
```bash
# From worker node
ping 10.X.11.224  # Ping router - should work
ping 8.8.8.8      # Ping internet - should work if NAT configured

# From router
ping 8.8.8.8      # Should work (router has internet)
ping 10.X.11.36   # Should work (router can reach workers)
```

### Common Issues

1. **Security group blocks worker → router traffic**
   - Solution: Add rule allowing all traffic from worker VPC CIDR

2. **DHCP routes override static default route**
   - Solution: Verify bgp-router-routes.service is enabled and running
   - Check: `systemctl status bgp-router-routes.service`

3. **NAT rules not persisting after reboot**
   - Solution: Verify iptables service is enabled
   - Check: `systemctl status iptables`
   - Verify: `/etc/sysconfig/iptables` contains MASQUERADE rule

4. **Source/dest check enabled on ENIs**
   - Solution: Disable on all ENIs
   - Check: `aws ec2 describe-network-interfaces --network-interface-ids eni-XXX`

## Performance Considerations

- **Single point of failure**: Each cluster has one router instance
  - Consider HA setup with multiple routers for production
  - Current setup is for development/testing

- **NAT gateway costs**: Traffic routes through both router and NAT gateway
  - Alternative: Use router as NAT without NAT gateway (more complex)

- **Instance sizing**: t3.small is adequate for development
  - Monitor network performance for production workloads
  - Consider larger instance types for high traffic scenarios

## Related Playbooks

- `13-frr-routers.yml` - Creates routers and configures NAT
- `14-bgp-configuration.yml` - Configures BGP peering
- `07-bare-metal-machinesets.yml` - Creates worker nodes that use routers
