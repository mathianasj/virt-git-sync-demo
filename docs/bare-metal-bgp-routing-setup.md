# Bare Metal BGP Routing Configuration

## Overview

This document describes the automatic routing configuration for c5.metal bare metal nodes to use BGP routers as their default gateway.

**Following Red Hat Solution**: [How to change default gateway on CoreOS nodes in OpenShift 4](https://access.redhat.com/solutions/3868301)

## Architecture

### Static IP Assignments
- **Hub Router**: `10.0.11.111` (in subnet 10.0.11.0/24)
- **Managed Router**: `10.1.11.224` (in subnet 10.1.11.0/24)

These static IPs are assigned to the FRRouting EC2 instances during deployment.

### Routing Flow
```
c5.metal bare metal node → BGP router (10.0.11.111 or 10.1.11.224) → Internet/VM network
```

## Implementation

### 1. Static Router IPs

**File**: `group_vars/all.yml`
```yaml
# Static IP addresses for BGP routers (must be within worker subnets)
# These IPs are used as default gateway for c5.metal bare metal nodes
hub_router_ip: 10.0.11.111
managed_router_ip: 10.1.11.224
```

### 2. Router EC2 Deployment with Static IPs

**File**: `roles/router/tasks/main.yml`

Modified the router deployment to use `--private-ip-address` flag when launching EC2 instances:

```bash
aws ec2 run-instances \
  --private-ip-address {{ hub_router_ip }} \
  ...
```

### 3. MachineConfig for Bare Metal Nodes

**File**: `roles/bare_metal/tasks/create_machineconfig.yml`

Creates a MachineConfig that:
- Targets nodes with label `machineconfiguration.openshift.io/role: worker-cnv`
- Creates a script at `/usr/local/bin/set-gw.sh`
- Runs a systemd service (`systemd-bgp-gw.service`) on boot
- Uses **NetworkManager (nmcli)** to properly configure the gateway
- Sets the default gateway on the primary network interface to point to the BGP router

#### The Script (`/usr/local/bin/set-gw.sh`)

```bash
#!/bin/bash
# Get the primary network interface (typically ens5 on c5.metal in AWS)
INTERFACE=$(ip route show default | head -1 | awk '{print $5}')

if [ -z "$INTERFACE" ]; then
  echo "ERROR: Could not determine primary interface"
  exit 1
fi

echo "Setting gateway <ROUTER_IP> on interface $INTERFACE"

# Get the NetworkManager connection name for this interface
CON=$(/bin/nmcli con show | grep "$INTERFACE" | awk 'NF-=3')

if [ -z "$CON" ]; then
  echo "ERROR: Could not find NetworkManager connection for $INTERFACE"
  exit 1
fi

echo "Connection name: $CON"

# Modify the connection to use new gateway
/bin/nmcli con modify "$CON" ipv4.gateway <ROUTER_IP>

# Bring the connection up with new configuration
/bin/nmcli con up "$CON"

echo "Gateway successfully set to <ROUTER_IP> on $INTERFACE"
```

Key features:
- **Automatic interface detection**: Detects the primary network interface (typically `ens5` on c5.metal)
- **NetworkManager integration**: Uses `nmcli` to modify the connection properly
- **Persistent configuration**: NetworkManager stores the configuration persistently
- **Proper RHCOS approach**: Follows Red Hat's recommended method for CoreOS nodes

### 4. Deployment Flow

**Order of operations** (in `roles/bare_metal/tasks/main.yml`):

1. **Create MachineConfig** (on both clusters)
   - Applied to all nodes with `worker-cnv` role
   - Configures default gateway to BGP router using NetworkManager
   
2. **Create MachineSets** (in parallel)
   - Deploys c5.metal instances
   - Nodes automatically get `worker-cnv` label
   - MachineConfig is applied automatically by Machine Config Operator

3. **Node Boot Sequence**:
   ```
   Node boots → Network comes up → systemd-bgp-gw.service runs → 
   /usr/local/bin/set-gw.sh executes → nmcli modifies connection → 
   Connection brought up with new gateway → Kubelet starts
   ```

## Configuration Files Modified

### Group Variables
- `group_vars/all.yml` - Added static router IPs

### Router Role
- `roles/router/defaults/main.yml` - Added static router IPs
- `roles/router/tasks/main.yml` - Modified EC2 launch to use static IPs

### Bare Metal Role
- `roles/bare_metal/tasks/main.yml` - Added MachineConfig creation step
- `roles/bare_metal/tasks/create_machineconfig.yml` - **NEW** - Creates MachineConfig for BGP routing using NetworkManager
- `roles/bare_metal/tasks/direct_parallel.yml` - No changes (MachineSet deployment unchanged)

## MachineConfig Details

### Name
`98-worker-cnv-bgp-gateway`

### Target
Nodes with label: `machineconfiguration.openshift.io/role: worker-cnv`

### Files Created
- `/usr/local/bin/set-gw.sh` (mode 0755) - Base64 encoded script

### Systemd Unit
`systemd-bgp-gw.service`

**What it does**:
1. Detects the primary network interface
2. Finds the NetworkManager connection for that interface
3. Modifies the connection's `ipv4.gateway` setting
4. Brings the connection up with the new configuration
5. Logs the change

**When it runs**:
- After `network-online.target` and `ignition-firstboot-complete.service`
- Before `kubelet.service` and `crio.service`
- Type: `oneshot`
- Runs: `/usr/local/bin/set-gw.sh` then `systemctl daemon-reload`

### NetworkManager Commands Used
For hub cluster:
```bash
nmcli con modify "Wired Connection" ipv4.gateway 10.0.11.111
nmcli con up "Wired Connection"
```

For managed cluster:
```bash
nmcli con modify "Wired Connection" ipv4.gateway 10.1.11.224
nmcli con up "Wired Connection"
```

## Verification

### Check MachineConfig Applied
```bash
oc get machineconfig 98-worker-cnv-bgp-gateway
oc get nodes -l node-role.kubernetes.io/worker-cnv
```

### Check MachineConfigPool Status
```bash
oc get mcp
oc get mcp worker-cnv -o yaml
```

### Check Gateway on Bare Metal Node
```bash
# From bastion, SSH to a c5.metal node or use oc debug
oc debug node/<node-name>
chroot /host

# Check NetworkManager connection
nmcli con show
nmcli d show <interface>  # e.g., ens5

# Should show IP4.GATEWAY: 10.0.11.111 (hub) or 10.1.11.224 (managed)
```

### Check Route Table
```bash
oc debug node/<node-name>
chroot /host
ip route show
# Should show: default via 10.0.11.111 dev ens5 proto dhcp metric 100
```

### Check Service Status
```bash
oc debug node/<node-name>
chroot /host
systemctl status systemd-bgp-gw.service
journalctl -u systemd-bgp-gw.service
```

### Check Script Execution
```bash
oc debug node/<node-name>
chroot /host
cat /usr/local/bin/set-gw.sh
# Run it manually to test:
/usr/local/bin/set-gw.sh
```

### Verify Router is Reachable
```bash
# From bare metal node
ping 10.0.11.111  # Hub router
# or
ping 10.1.11.224  # Managed router
```

## Troubleshooting

### MachineConfig Not Applied
Check Machine Config Operator and MachineConfigPool:
```bash
oc get mcp
oc get mcp worker-cnv -o yaml
oc get machineconfig | grep bgp
```

Check if nodes are being updated:
```bash
oc get nodes -o wide
# Look for nodes in SchedulingDisabled state (being updated)
```

### Gateway Not Set
Check the systemd service:
```bash
oc debug node/<node-name>
chroot /host
systemctl status systemd-bgp-gw.service
journalctl -u systemd-bgp-gw.service -n 50
```

Check if script exists and is executable:
```bash
ls -la /usr/local/bin/set-gw.sh
```

Manually run the script:
```bash
/usr/local/bin/set-gw.sh
```

### NetworkManager Issues
Check NetworkManager connections:
```bash
nmcli con show
nmcli d show
```

Check NetworkManager logs:
```bash
journalctl -u NetworkManager -n 50
```

### Router Not Reachable
1. Verify router EC2 instance is running with correct static IP:
   ```bash
   aws ec2 describe-instances --instance-ids <instance-id>
   ```

2. Check security groups allow traffic

3. Verify source/destination check is disabled on router instance:
   ```bash
   aws ec2 describe-instance-attribute --instance-id <instance-id> --attribute sourceDestCheck
   ```

4. Ping test from node:
   ```bash
   oc debug node/<node-name>
   chroot /host
   ping <router-ip>
   ```

### Rolling Back
To remove the MachineConfig:
```bash
oc delete machineconfig 98-worker-cnv-bgp-gateway
```

This will trigger a rolling update to remove the configuration.

## Important Notes

1. **Static IPs are required**: The router IPs must be static and predictable for the MachineConfig
2. **Subnet placement**: Router must be in the same subnet as the c5.metal workers
3. **MachineConfig timing**: MachineConfig is applied before MachineSet to ensure it's ready when nodes boot
4. **Automatic application**: Once MachineConfig exists, all new nodes with `worker-cnv` label will automatically get the gateway configuration
5. **NetworkManager persistence**: Using `nmcli` ensures the configuration persists across reboots and is managed properly by NetworkManager
6. **Primary interface only**: This only affects the default gateway on the primary network interface, not secondary interfaces or VRF routing tables
7. **Red Hat recommended**: This approach follows Red Hat's official solution guide for changing default gateway on CoreOS nodes

## Advantages of NetworkManager Approach

Compared to using `ip route` commands directly:

1. **Persistence**: NetworkManager stores configuration and applies it automatically
2. **Proper RHCOS integration**: Works with RHCOS's immutable OS design
3. **Connection management**: Properly manages the network connection state
4. **Red Hat supported**: Official Red Hat solution
5. **Atomic updates**: Connection changes are applied atomically
6. **Better error handling**: NetworkManager handles network state properly

## References

- [Red Hat Solution: How to change default gateway on CoreOS nodes in OpenShift 4](https://access.redhat.com/solutions/3868301)
- [OpenShift Machine Config Operator Documentation](https://docs.openshift.com/container-platform/latest/post_installation_configuration/machine-configuration-tasks.html)
- [NetworkManager CLI (nmcli) Documentation](https://networkmanager.dev/docs/api/latest/nmcli.html)
