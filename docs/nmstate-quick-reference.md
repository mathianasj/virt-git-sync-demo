# nmstate Quick Reference Guide

## Key Concepts

### 1. DNS Configuration

```yaml
dns-resolver:
  config:
    server:
      - 8.8.8.8          # Primary DNS
      - 8.8.4.4          # Secondary DNS
    search:
      - example.com      # DNS search domain
      - cluster.local
```

### 2. Default Route

```yaml
routes:
  config:
    - destination: 0.0.0.0/0          # Default route (all traffic)
      next-hop-interface: eth1         # Interface to use
      next-hop-address: 192.168.1.1    # Gateway IP
      metric: 100                      # Lower = higher priority
      table-id: 254                    # Main routing table
```

### 3. Interface Configuration (Static IP)

```yaml
interfaces:
  - name: eth0
    type: ethernet
    state: up
    ipv4:
      enabled: true
      dhcp: false                    # Static IP
      address:
        - ip: 192.168.1.10
          prefix-length: 24
      auto-dns: false                # Don't set DNS automatically
      auto-gateway: false            # Don't set default gateway
      auto-routes: false             # Don't add automatic routes
    ipv6:
      enabled: false
```

### 4. Interface Configuration (DHCP with no routes)

```yaml
interfaces:
  - name: eth0
    type: ethernet
    state: up
    ipv4:
      enabled: true
      dhcp: true                     # Get IP from DHCP
      auto-dns: false                # But don't accept DNS
      auto-gateway: false            # CRITICAL: Don't accept gateway
      auto-routes: false             # CRITICAL: Don't accept routes
    ipv6:
      enabled: false
```

### 5. Interface Configuration (DHCP with routes)

```yaml
interfaces:
  - name: eth1
    type: ethernet
    state: up
    ipv4:
      enabled: true
      dhcp: true
      auto-dns: true                 # Accept DNS from DHCP
      auto-gateway: true             # Accept default gateway
      auto-routes: true              # Accept all routes
    ipv6:
      enabled: false
```

## Common Scenarios

### Scenario 1: Two Static IPs, Default Route on Second Interface

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: dual-static-with-default
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    dns-resolver:
      config:
        server: [8.8.8.8, 8.8.4.4]
    routes:
      config:
        - destination: 0.0.0.0/0
          next-hop-interface: eth1
          next-hop-address: 192.168.2.1
    interfaces:
      - name: eth0
        type: ethernet
        state: up
        ipv4:
          enabled: true
          dhcp: false
          address:
            - ip: 192.168.1.10
              prefix-length: 24
          auto-dns: false
          auto-gateway: false
          auto-routes: false
      - name: eth1
        type: ethernet
        state: up
        ipv4:
          enabled: true
          dhcp: false
          address:
            - ip: 192.168.2.10
              prefix-length: 24
          auto-dns: false
          auto-gateway: false
          auto-routes: false
```

### Scenario 2: First Interface DHCP (No Routes), Second Interface with Default Route

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: dhcp-plus-default
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    dns-resolver:
      config:
        server: [1.1.1.1]
    routes:
      config:
        - destination: 0.0.0.0/0
          next-hop-interface: eth1
          next-hop-address: 10.0.14.1
    interfaces:
      - name: eth0
        type: ethernet
        state: up
        ipv4:
          enabled: true
          dhcp: true
          auto-dns: false
          auto-gateway: false      # Don't add default gateway
          auto-routes: false       # Don't add any routes
      - name: eth1
        type: ethernet
        state: up
        ipv4:
          enabled: true
          dhcp: false
          address:
            - ip: 10.0.14.100
              prefix-length: 24
          auto-dns: false
          auto-gateway: false
          auto-routes: false
```

## Important Flags Explained

| Flag | Purpose | When to Set false | When to Set true |
|------|---------|-------------------|------------------|
| `auto-dns` | Accept DNS from DHCP/RA | Don't want DNS from this interface | Want DNS from this interface |
| `auto-gateway` | Accept default gateway from DHCP/RA | Don't want default route from this interface | Want default route from this interface |
| `auto-routes` | Accept all routes from DHCP/RA | Don't want ANY routes from this interface | Want all routes from this interface |

## Critical Safety Rules

### ✓ DO:
- Set `auto-gateway: false` on interfaces that should NOT provide default route
- Set `auto-routes: false` on interfaces that should NOT add routes
- Define explicit routes in the `routes` section when needed
- Use `metric` to prioritize routes (lower number = higher priority)

### ✗ DON'T:
- Modify the primary interface if it's managing cluster networking
- Set `auto-gateway: true` on multiple interfaces (routing conflicts)
- Forget to set `auto-routes: false` when you want manual route control
- Mix DHCP routes and manual routes without careful planning

## DNS Configuration Options

### Global DNS (applies to all interfaces)
```yaml
dns-resolver:
  config:
    server:
      - 8.8.8.8
      - 1.1.1.1
```

### Per-Interface DNS (DHCP)
```yaml
interfaces:
  - name: eth0
    ipv4:
      auto-dns: true  # Use DNS from DHCP on this interface
```

### No DNS (manual resolution)
```yaml
dns-resolver:
  config:
    server: []  # No DNS servers
```

## Routing Table IDs

| Table ID | Name | Purpose |
|----------|------|---------|
| 254 | main | Default routing table |
| 255 | local | Local routing table (auto-managed) |
| 0 | unspec | Unspecified |
| 253 | default | Default table |
| 1-252 | custom | Custom routing tables (policy routing) |

## Common Interface Types

- `ethernet` - Physical Ethernet interface
- `vlan` - VLAN interface (802.1Q)
- `bond` - Link aggregation (bonding)
- `bridge` - Network bridge
- `vrf` - Virtual Routing and Forwarding
- `ovs-interface` - Open vSwitch interface

## Validation Commands

After applying NNCP, verify on the node:

```bash
# Check NNCP status
oc get nncp

# Check per-node status
oc get nnce -A

# Debug into node
oc debug node/<node-name>

# Inside debug pod:
chroot /host

# Check interface configuration
ip addr show

# Check routing table
ip route show

# Check DNS
cat /etc/resolv.conf

# Check specific routing table
ip route show table main
```

## Troubleshooting

### NNCP stuck in "Progressing"
```bash
oc get nnce -A  # Check node-specific status
oc describe nncp <name>
```

### Routes not applying
- Check `table-id` is correct (usually 254 for main)
- Verify interface name matches actual interface
- Check if routes conflict with existing routes

### DNS not working
- Verify `dns-resolver` section syntax
- Check if `auto-dns: true` on correct interface
- Verify DNS servers are reachable

### Interface not coming up
- Check interface name is correct: `ip link show`
- Verify no conflicting configuration
- Check for typos in YAML

## Example: Our BGP Peering Subnet Use Case

```yaml
# This is what we're using for the BGP peering subnet architecture
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: worker-bgp-peering-interface
spec:
  nodeSelector:
    node-role.kubernetes.io/worker-cnv: ""
  desiredState:
    interfaces:
      - name: enp126s0              # Secondary interface
        type: ethernet
        state: up
        ipv4:
          enabled: true
          dhcp: true                 # Get IP from DHCP
          auto-dns: false            # Don't accept DNS
          auto-gateway: false        # CRITICAL: No default gateway
          auto-routes: false         # CRITICAL: No routes
        ipv6:
          enabled: false

# Result: Interface gets IP, but adds NO routes to routing table
# Primary interface (br-ex) and main routing table remain untouched
# Cluster connectivity preserved
```

## References

- [NMState Documentation](https://nmstate.io/)
- [OpenShift NMState Operator](https://docs.openshift.com/container-platform/latest/networking/k8s_nmstate/k8s-nmstate-about-the-k8s-nmstate-operator.html)
- [Kubernetes NMState Examples](https://github.com/nmstate/kubernetes-nmstate/tree/main/docs/examples)
