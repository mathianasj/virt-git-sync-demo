# Deployment Status - BGP Router NAT Configuration with Split Routing

## Summary

Successfully implemented and tested BGP router NAT gateway configuration for both Hub and Managed OpenShift clusters. Internet connectivity is now working for all worker nodes through BGP routers, and control plane nodes route directly to NAT Gateway for cluster operator health.

**Latest Update (2026-05-07):** Implemented split routing strategy to fix console login issues caused by control plane nodes being unable to reach internet through BGP router.

## What Was Done

### 1. Manual Configuration (Proof of Concept)

**Managed Cluster (10.1.11.0/24)**:
- ✅ Added second ENI to BGP router in public subnet (10.1.1.0/24)
- ✅ Configured router routing: `default via 10.1.1.99 dev ens6` (NAT gateway)
- ✅ Removed DHCP default routes via systemd service
- ✅ Added iptables MASQUERADE rule for traffic going out ens6
- ✅ Fixed security group to allow traffic from 10.1.0.0/16
- ✅ Updated VPC route table: `0.0.0.0/0 → BGP router ENI`
- ✅ Verified internet connectivity: **3 packets, 0% loss**

**Hub Cluster (10.0.11.0/24)**:
- ✅ Same configuration applied manually
- ✅ Verified internet connectivity: **3 packets, 0% loss**

### 2. Playbook Implementation

Updated Ansible playbooks to automate the NAT configuration:

**Files Modified**:
- `roles/router/tasks/main.yml`
  - Fixed security group rules to use correct VPC CIDRs
  - Changed source/dest check to work per-ENI instead of per-instance
  - Added call to `configure_router_nat.yml` when `router_nat_enabled: true`

**Files Created**:
- `roles/router/tasks/configure_router_nat.yml`
  - Creates second ENI in public subnet for each router
  - Attaches second ENI to router instances
  - Disables source/dest check on all ENIs
  - Calls `configure_nat.yml` to configure routing and NAT

- `roles/router/tasks/configure_nat.yml` (rewritten)
  - Installs iptables-services
  - Enables IP forwarding
  - Adds iptables MASQUERADE rule
  - Creates systemd service `bgp-router-routes.service`
  - Makes configuration persistent

- `roles/router/tasks/update_vpc_route_tables.yml`
  - Updates VPC private route tables
  - Changes default route from NAT gateway to BGP router ENI

**Documentation Created/Updated**:
- `docs/bgp-router-nat-configuration.md` - Comprehensive technical documentation
- `docs/architecture-diagrams.md` - Updated diagrams with dual-ENI architecture
- `README.md` - Added BGP router NAT section and updated features list
- `docs/DEPLOYMENT_STATUS.md` - This file

### 3. Testing Results

**Managed Cluster**:
```bash
Node: ip-10-1-11-36.ec2.internal (10.1.11.36)
Test: ping -c 3 8.8.8.8
Result: 3 packets transmitted, 3 received, 0% packet loss ✅
```

**Hub Cluster**:
```bash
Node: ip-10-0-11-170.ec2.internal (10.0.11.170)
Test: ping -c 3 8.8.8.8
Result: 3 packets transmitted, 3 received, 0% packet loss ✅
```

## Current Deployment Phase

### Completed Phases (1-13):

| Phase | Playbook | Status |
|-------|----------|--------|
| 01 | Prerequisites | ✅ Complete |
| 02 | Infrastructure (VPCs, NAT gateways) | ✅ Complete |
| 03 | Bastion Setup | ✅ Complete |
| 04 | OpenShift Install (Hub + Managed) | ✅ Complete |
| 05 | ACM Setup | ✅ Complete |
| 06 | Import Managed Cluster | ✅ Complete |
| **07** | **FRR Routers + NAT Configuration** | ✅ **Complete** |
| 08 | Bare Metal MachinesSets | ✅ Complete |
| 09 | Virtualization Policy | ✅ Complete |
| 10 | Gitea Deployment | ✅ Complete |
| 11 | Cert Manager Setup | ✅ Complete |
| 12 | Virt-Git-Sync Setup | ✅ Complete |
| 13 | ODF Setup (Ceph Storage) | ✅ Complete |

### Next Phases (14-15):

| Phase | Playbook | Status |
|-------|----------|--------|
| 14 | BGP Configuration (routing setup) | ⏭️ Ready to run |
| 15 | CUDN Network (VM networking) | ⏭️ Pending |

## Architecture Overview

### Traffic Flow: Worker → Internet

```
Worker Nodes (10.X.11.0/24)
  ↓ (DHCP default route: 10.X.11.1)
  ↓ (VPC route override: 0.0.0.0/0 → BGP Router ENI)
  ↓
BGP Router
  ├─ ens5: 10.X.11.Y (worker subnet)
  └─ ens6: 10.X.1.Z (public subnet)
      ↓ (iptables MASQUERADE)
      ↓ (default via NAT gateway IP)
      ↓
NAT Gateway (10.X.1.99/178)
  ↓
Internet Gateway
  ↓
Internet
```

### Key Components

1. **Dual ENI Router**:
   - Primary: Worker subnet for BGP peering
   - Secondary: Public subnet for NAT gateway access

2. **NAT Configuration**:
   - `iptables -t nat -A POSTROUTING -o ens6 -j MASQUERADE`
   - Managed by `iptables-services` for persistence

3. **Routing Management**:
   - systemd service: `bgp-router-routes.service`
   - Removes DHCP routes on boot
   - Sets static default: `via NAT_GATEWAY_IP dev ens6`

4. **VPC Route Tables**:
   - Hub: `0.0.0.0/0 → eni-XXXXXXXXX` (hub router)
   - Managed: `0.0.0.0/0 → eni-XXXXXXXXX` (managed router)

## Configuration Variables

In `group_vars/all.yml`:

```yaml
# Enable BGP router NAT configuration
router_nat_enabled: true

# Router IPs (must be in worker subnets)
hub_router_ip: 10.0.11.111
managed_router_ip: 10.1.11.224

# Instance type for routers
router_instance_type: t3.small
router_availability_zone: us-east-1a
```

## Split Routing Fix (2026-05-07)

### Issue: Console Login Failures

**Symptoms:**
- Users unable to login to managed cluster console
- Authentication operator degraded
- Console operator degraded  
- Ingress operator degraded
- Error: "Get https://oauth-openshift.apps.managed.sandbox2629.opentlc.com/healthz: context deadline exceeded"

**Root Cause:**
Control plane nodes in subnets 10.1.12.0/24 (us-east-1b) and 10.1.13.0/24 (us-east-1c) could not reach the internet because:
- All private subnets were routing internet traffic (0.0.0.0/0) to the BGP router ENI
- BGP router only exists in subnet 10.1.11.0/24 (us-east-1a)
- Control plane nodes in other AZs couldn't route to BGP router in different AZ
- Authentication operator (running on control plane) couldn't verify OAuth endpoint

**Solution:**
Implemented split routing strategy:
- **Worker subnet (10.X.11.0/24):** Routes internet traffic through BGP router (for VM networking)
- **Control plane subnets (10.X.12.0/24, 10.X.13.0/24):** Route internet traffic directly to NAT Gateway

**Files Modified:**
- `roles/router/tasks/configure_router_nat.yml` - Updated to use split routing task
- `group_vars/all.yml` - Added documentation about split routing strategy

**Files Created:**
- `roles/router/tasks/update_vpc_route_tables_split.yml` - New task for split routing configuration
- `docs/split-routing-strategy.md` - Comprehensive documentation of split routing approach

**Verification:**
```bash
# Control plane node internet connectivity
oc debug node/ip-10-1-12-247.ec2.internal -- chroot /host ping -c 3 8.8.8.8
# Result: 3 packets transmitted, 3 received, 0% packet loss ✅

# Control plane node OAuth endpoint access
oc debug node/ip-10-1-12-247.ec2.internal -- chroot /host curl -k -I https://oauth-openshift.apps.managed.sandbox2629.opentlc.com/healthz
# Result: HTTP/1.1 200 OK ✅

# Cluster operators
oc get co authentication console ingress
# Result: All Available=True, Degraded=False ✅

# Console login
https://console-openshift-console.apps.managed.sandbox2629.opentlc.com
# Result: Login successful ✅
```

## Known Issues & Solutions

### Issue 1: SSH Timeout During Playbook Run
**Symptom**: Playbook fails when trying to SSH to router public IP  
**Cause**: Router public IP changes when second ENI is attached  
**Solution**: Updated playbook to SSH via bastion using private IPs

### Issue 2: Source/Dest Check Error with Multiple ENIs
**Symptom**: `InvalidInstanceID: There are multiple interfaces attached`  
**Cause**: Can't disable source/dest check at instance level with multiple ENIs  
**Solution**: Changed to disable per-ENI instead of per-instance

### Issue 3: Security Group Blocking Worker → Router
**Symptom**: Node can't ping router, 100% packet loss  
**Cause**: Managed router SG only allowed 10.0.0.0/16, not 10.1.0.0/16  
**Solution**: Fixed security group to allow correct VPC CIDR (10.X.0.0/16)

### Issue 4: DHCP Routes Override Static Default
**Symptom**: Multiple default routes present after configuration  
**Cause**: systemd-networkd ignores `UseRoutes=false` setting  
**Solution**: Created systemd service to delete DHCP routes on boot

## Next Steps

1. **Run Phase 14 - BGP Configuration**:
   ```bash
   ansible-playbook playbooks/14-bgp-configuration.yml
   ```
   This will configure BGP peering sessions between routers and worker nodes.

2. **Run Phase 15 - CUDN Network**:
   ```bash
   ansible-playbook playbooks/15-cudn-network.yml
   ```
   This will create the VM network (CUDN) with bridge networking.

3. **Optional - Full Deployment Test**:
   To verify end-to-end automation:
   ```bash
   # Destroy everything
   ansible-playbook playbooks/99-destroy-clusters.yml
   
   # Redeploy from scratch
   ansible-playbook playbooks/site.yml
   ```

## Documentation

All documentation has been updated to reflect the BGP router NAT configuration:

- **Technical Details**: `docs/bgp-router-nat-configuration.md`
- **Architecture Diagrams**: `docs/architecture-diagrams.md`
- **Main README**: `README.md`
- **This Status**: `docs/DEPLOYMENT_STATUS.md`

## Verification Commands

### Check Router Configuration

```bash
# Via bastion
ssh -i ~/.ssh/ocp-bastion-key ec2-user@<BASTION_IP>

# To hub router
ssh -i ~/.ssh/openshift-key ec2-user@10.0.11.111

# To managed router
ssh -i ~/.ssh/openshift-key ec2-user@10.1.11.224

# On router - check routing
ip route show
# Should show: default via 10.X.1.Y dev ens6

# On router - check NAT
sudo iptables -t nat -L POSTROUTING -n -v
# Should show: MASQUERADE ... out ens6

# On router - check systemd service
systemctl status bgp-router-routes.service
systemctl status iptables.service
```

### Test Node Internet Connectivity

```bash
# On bastion
export KUBECONFIG=/home/ec2-user/cluster-managed/auth/kubeconfig
oc debug node/<NODE_NAME> -- chroot /host ping -c 3 8.8.8.8

export KUBECONFIG=/home/ec2-user/cluster-hub/auth/kubeconfig
oc debug node/<NODE_NAME> -- chroot /host ping -c 3 8.8.8.8
```

### Check VPC Route Tables

```bash
# Hub cluster private route table
aws ec2 describe-route-tables --region us-east-1 \
  --filters "Name=tag:Name,Values=*hub*private*" \
  --query 'RouteTables[*].Routes[]'

# Managed cluster private route table
aws ec2 describe-route-tables --region us-east-1 \
  --filters "Name=tag:Name,Values=*managed*private*" \
  --query 'RouteTables[*].Routes[]'
```

## Success Metrics

- ✅ Both BGP routers have 2 ENIs attached
- ✅ Both routers have clean routing tables (single default via NAT gateway)
- ✅ iptables MASQUERADE rules persist across reboots
- ✅ VPC route tables updated correctly
- ✅ Worker nodes from both clusters can reach internet (0% packet loss)
- ✅ Security groups allow worker → router traffic
- ✅ Source/dest check disabled on all router ENIs
- ✅ systemd services enabled and running
- ✅ Playbooks updated and ready for automated deployment
- ✅ Documentation complete and updated

**Status**: ✅ **COMPLETE AND VERIFIED**
