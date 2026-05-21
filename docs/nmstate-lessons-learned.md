# NMState Operator Lessons Learned

## What We Tried

We attempted to use the NMState operator to configure worker node routing:
- Installed NMState operator via `playbooks/132a-install-nmstate-operator.yml`
- Created NodeNetworkConfigurationPolicy (NNCP) targeting br-ex interface
- Set `auto-gateway: false` and `auto-routes: false` on br-ex
- Added static default route pointing to BGP router

## Why It Failed

### Problem 1: API Connectivity Broken
When NMState applied the NNCP to c5.metal bare metal nodes:
- NMState modified the main routing table (254)
- Default route changed from AWS gateway (10.0.11.1) to BGP router (10.0.11.111)
- Kubelet could no longer reach API server on port 10250
- Node metrics stopped reporting (console showed dashes for CPU/Memory)
- `oc debug node` commands timed out with "dial tcp 10.0.11.73:10250: i/o timeout"
- `oc get --raw /api/v1/nodes/<node>/proxy/stats/summary` timed out

### Problem 2: DNS and Health Probe Failures
- NMState runs health probes to verify network configuration:
  - DNS probe (checks `root-servers.net`)
  - API server connectivity probe
- When default route changed, both probes failed
- NNCP attempted automatic rollback but rollback also failed
- Error message: "failed running probes after network changes"
- Nodes became stuck in degraded state

### Problem 3: NetworkManager State Persistence
- Even after deleting the NNCP with `oc delete nncp <name>`, nodes remained broken
- NetworkManager retained the NMState-modified connection profiles
- Node reboots didn't automatically restore original configuration
- NetworkManager persisted profiles in `/etc/NetworkManager/system-connections/`
- Manual intervention required to restore connectivity

## Recovery Procedure

If nodes become unreachable after NNCP application:

### Step 1: Delete the NNCP
```bash
oc delete nncp worker-disable-dhcp-gateway
```

### Step 2: Restart OVN Pods
```bash
# Find OVN pods on affected nodes
oc get pods -n openshift-ovn-kubernetes -o wide | grep <node-name>

# Delete them to force restart
oc delete pod <ovn-pod-name> -n openshift-ovn-kubernetes
```

### Step 3: Reboot Affected Nodes
```bash
aws ec2 reboot-instances --region us-east-1 --instance-ids <id1> <id2>
```

### Step 4: Verify or Replace Nodes
If nodes still don't recover after reboot:
```bash
# Check node status
oc get nodes
oc adm top nodes

# If still broken, nodes need to be terminated and replaced
aws ec2 terminate-instances --instance-ids <id1> <id2>
```

## Root Cause Analysis

### Why Main Routing Table Can't Be Changed

OpenShift nodes rely on specific routing for cluster operations:

1. **API Server Communication:**
   - Kubelet connects to API server (typically via load balancer)
   - Load balancer IP is in the VPC CIDR, routed via AWS gateway
   - Changing default route breaks this communication path

2. **Cluster Service Network:**
   - Service IPs (172.30.0.0/16) routed through OVN overlay
   - Requires specific routes managed by OVN
   - Default route changes can break service discovery

3. **AWS VPC Routing:**
   - AWS manages VPC routing through route tables
   - EC2 instances expect default route via VPC gateway
   - BGP router should handle NAT, not replace VPC routing

### Why NMState Specifically Fails

NMState design assumptions that don't match our use case:

1. **Assumes All Nodes Are Equal:**
   - NMState expects to manage all network interfaces uniformly
   - Doesn't distinguish between cluster networking and VM networking

2. **Health Probes Too Aggressive:**
   - Probes fail immediately when routes change
   - Rollback triggers before routing can stabilize
   - No grace period for BGP convergence

3. **No VRF Support:**
   - NMState doesn't understand VRF routing tables
   - Can't target specific routing table (e.g., table 1997 for CUDN)
   - Only modifies main routing table (254)

## Correct Approach

### For Main Routing Table (br-ex, table 254)
**DO NOT MODIFY** - must remain as configured by OpenShift:
```
default via 10.0.11.1 dev br-ex proto dhcp metric 48
```

This route is required for:
- API server connectivity
- Cluster service access
- OVN overlay networking
- OpenShift platform stability

### For VRF Routing Tables (CUDN, e.g., table 1997)
This is where VM internet routing should be configured:
```
default via 10.0.11.111 dev br-ex table 1997
```

**Options for VRF routing:**

1. **Manual (temporary):**
   ```bash
   oc debug node/<node>
   chroot /host
   VRF_TABLE=$(ip vrf show | grep cudn-net | awk '{print $2}')
   ip route add default via 10.0.11.111 dev br-ex table $VRF_TABLE
   ```
   - Pros: Immediate, no reboot
   - Cons: Lost on reboot, manual for each node

2. **MachineConfig (persistent):**
   Create systemd service to set VRF route on boot
   - Pros: Persistent, automated
   - Cons: Requires node reboot, more complex

3. **Future: Static IP Configuration:**
   Deploy workers with static IPs instead of DHCP
   - Pros: Full control, no DHCP conflicts
   - Cons: Requires cluster rebuild, more complex deployment

## Files Created During Troubleshooting

### Working Files
- `playbooks/132a-install-nmstate-operator.yml` - Installs NMState operator (operator itself works fine)
- `roles/router/tasks/update_security_groups.yml` - Updates security groups for router-worker traffic (works)
- `playbooks/13-frr-routers.yml` - Deploys BGP routers in worker subnets (works)
- `playbooks/14-bgp-configuration.yml` - Configures BGP peering (works)

### Broken Files (DO NOT USE)
- `playbooks/132-nmstate-disable-dhcp-gateway.yml` - NNCP configuration (BREAKS NODES)
- `roles/router/tasks/update_worker_default_routes_immediate.yml` - Tries to SSH to RHCOS nodes (fails)

## Lessons for Future Work

### What We Confirmed Works
1. ✅ BGP routers in same subnet as workers
2. ✅ Security group updates for router-worker traffic
3. ✅ BGP peering between routers and worker nodes
4. ✅ NAT configuration on routers
5. ✅ VPC route table updates (for subnet-level routing)

### What We Confirmed Doesn't Work
1. ❌ SSH to RHCOS worker nodes
2. ❌ NMState on br-ex interface
3. ❌ Changing main routing table (254)
4. ❌ Automated VRF route configuration via NMState

### What Needs Future Investigation
1. 🔧 MachineConfig for persistent VRF routing
2. 🔧 Static IP configuration for bare metal workers
3. 🔧 DaemonSet approach for VRF route management
4. 🔧 Custom CNI plugin for CUDN routing

## References

- NMState Documentation: https://nmstate.io/
- OpenShift Networking: https://docs.openshift.com/container-platform/latest/networking/understanding-networking.html
- VRF Routing: https://www.kernel.org/doc/Documentation/networking/vrf.txt
- CUDN (ClusterUserDefinedNetwork): OVN-Kubernetes Layer2 topology with VRF isolation
