# Archived Bare Metal Tasks

## create_machineconfig.yml.unused

**Reason for archiving:** Redundant with VPC-level routing

This MachineConfig attempted to set the default gateway on worker nodes using NetworkManager/nmcli to point to the BGP router. However, this is unnecessary because:

1. **VPC route tables** already handle routing at the AWS hypervisor level
2. The worker subnet route table has `0.0.0.0/0 → BGP router ENI`
3. AWS intercepts and routes packets based on destination IP before they leave the subnet
4. No OS-level configuration is needed on the worker nodes

**Previous behavior:**
- Created MachineConfig `98-worker-cnv-bgp-gateway`
- Ran `/usr/local/bin/set-gw.sh` on worker nodes
- Used NetworkManager to set static gateway via `ipv4.routes`

**Current behavior:**
- VPC route table points worker subnet default route to BGP router
- Worker nodes get normal DHCP gateway (e.g., 10.0.11.1)
- AWS hypervisor intercepts traffic and routes via BGP router ENI
- Simpler, more reliable, no per-node configuration needed

**Reference:**
- Original Red Hat solution: https://access.redhat.com/solutions/3868301
- VPC route table configuration: `roles/router/tasks/update_vpc_route_tables_split.yml`
