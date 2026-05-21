# CUDN with BGP Advertisements and VRF Implementation

## Overview

This document describes the implementation of ClusterUserDefinedNetwork (CUDN) with BGP route advertisements and VRF isolation for KubeVirt VMs in an OpenShift cluster running on AWS.

**Date:** 2026-05-20  
**Environment:** OpenShift on AWS with c5.metal instances, FRR-based BGP routers

## Goals

1. **CUDN Network:** Layer2 Primary network (192.168.100.0/24) for KubeVirt VMs
2. **Egress Internet:** VMs can access the internet via automatic SNAT
3. **BGP Advertisements:** Advertise CUDN subnet (192.168.100.0/24) to external BGP routers
4. **VRF Isolation:** Separate BGP control plane from data plane using VRFs

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ OpenShift Worker Node (ip-10-0-11-183)                      │
│                                                              │
│  ┌──────────────┐          ┌──────────────┐                │
│  │ Main VRF     │          │ cudn-net VRF │                │
│  │ (default)    │          │ (table 1691) │                │
│  │              │          │              │                │
│  │ ens0 (mgmt)  │          │ ovn-k8s-mp2  │                │
│  │ br-ex        │◄─────────│ 192.168.100.2│                │
│  │              │  route   │              │                │
│  └──────────────┘          └──────┬───────┘                │
│                                   │                         │
│  ┌──────────────┐                 │                         │
│  │ bgp-control  │                 │                         │
│  │ VRF          │                 │                         │
│  │ (table 1000) │◄────────────────┘                         │
│  │              │  import routes                            │
│  │ ens1 (BGP)   │─────────► Router (10.0.14.111)           │
│  │              │  advertise 192.168.100.0/24              │
│  └──────────────┘                                           │
└─────────────────────────────────────────────────────────────┘
```

## Initial Problem: RouteAdvertisement Breaking Egress

### Symptom
After enabling RouteAdvertisements CR, BGP advertisements worked but VM internet connectivity broke.

### Root Cause
OVN-Kubernetes RouteAdvertisements controller creates **bidirectional VRF imports**:

```yaml
# OVN-generated FRRConfiguration (ovnk-generated-xxxxx)
spec:
  bgp:
    routers:
    - asn: 64512
      vrf: bgp-control
      imports:
      - vrf: cudn-net          # ✅ Import CUDN routes to advertise
      neighbors: [...]
    - asn: 64512
      vrf: cudn-net
      imports:
      - vrf: bgp-control        # ❌ Import BGP default route (breaks egress!)
```

This caused the cudn-net VRF to import the BGP default route:
```bash
# Before (working):
default via 10.0.11.1 dev br-ex mtu 8901

# After RouteAdvertisement (broken):
default nhid 1414 via 10.0.14.111 dev ens1 proto bgp metric 20
```

The new default route pointed to ens1 (in bgp-control VRF), which was unreachable from cudn-net VRF, breaking egress.

**Code reference:**  
`ovn-kubernetes/go-controller/pkg/clustermanager/routeadvertisements/controller.go` lines 965-988 creates reciprocal imports by design.

## Solution: Manual FRRConfiguration

We replaced RouteAdvertisements CR with a manual FRRConfiguration that only imports in one direction.

### Step 1: Remove RouteAdvertisements

```bash
oc delete routeadvertisements cudn-advertisement
```

This automatically deleted the OVN-generated FRRConfigurations (`ovnk-generated-xxxxx`).

### Step 2: Create Manual FRRConfiguration

```bash
cat <<'EOF' | oc apply -f -
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: bgp-control-vrf
  namespace: openshift-frr-k8s
  labels:
    app: bgp-router-vrf
spec:
  bgp:
    routers:
    # BGP control plane router - imports CUDN routes to advertise
    - asn: 64512
      vrf: bgp-control
      imports:
      - vrf: cudn-net          # ✅ One-way import: read CUDN routes
      prefixes:
      - 192.168.100.0/24
      neighbors:
      - address: 10.0.14.111   # BGP router IP
        asn: 64500
        disableMP: true
        sourceaddress: ens1
        toAdvertise:
          allowed:
            mode: filtered
            prefixes:
            - 192.168.100.0/24
        toReceive:
          allowed:
            mode: all
    
    # CUDN VRF router - NO imports (keeps default route clean)
    - asn: 64512
      vrf: cudn-net            # ✅ No imports! Egress remains via br-ex
  
  nodeSelector:
    matchLabels:
      bgp-peering: enabled
EOF
```

### Step 3: Restart FRR Pods

```bash
# Find FRR pods on worker nodes
oc get pods -n openshift-frr-k8s -o wide | grep -E 'ip-10-0-11-(183|76)'

# Restart them to reload configuration
oc delete pod -n openshift-frr-k8s frr-k8s-99xn6 frr-k8s-hjvj2
```

## Verification

### 1. CUDN Egress Works

```bash
# Test from CUDN pod
oc run test-cudn-egress -n cudn-vms --image=nicolaka/netshoot --rm -it -- ping -c 3 8.8.8.8
# Result: ✅ 3 packets transmitted, 3 received
```

### 2. Default Route Correct

```bash
# Check cudn-net VRF routing table
oc debug node/ip-10-0-11-183.ec2.internal -- chroot /host ip route show vrf cudn-net

# Result:
# default via 10.0.11.1 dev br-ex mtu 8901 ✅ (via OVN overlay, not BGP)
# 192.168.100.0/24 dev ovn-k8s-mp2 proto kernel scope link src 192.168.100.2
```

### 3. BGP Advertisement Works

```bash
# Check BGP router received routes
ssh ec2-user@<router-ip> 'sudo vtysh -c "show ip bgp 192.168.100.0/24"'

# Result:
# BGP routing table entry for 192.168.100.0/24
# Paths: (2 available, best #1, table default)
#   64512
#     10.0.14.140 (multipath) ✅
#     10.0.14.144 (multipath) ✅
```

### 4. BGP Session Status

```bash
ssh ec2-user@<router-ip> 'sudo vtysh -c "show ip bgp summary"'

# Result:
# Neighbor        V    AS   MsgRcvd   MsgSent   TblVer  State/PfxRcd
# 10.0.14.140     4  64512      2082      2542     1213            1 ✅
# 10.0.14.144     4  64512      4054      5825     1213            1 ✅
```

## Traffic Flow

### Egress from VM (192.168.100.3 → 8.8.8.8)

1. VM sends packet to gateway (192.168.100.1)
2. OVN overlay routes to br-ex in cudn-net VRF
3. SNAT to node IP (10.0.11.183)
4. Exit via br-ex to internet

```
VM (192.168.100.3) 
  → ovn-k8s-mp2 (192.168.100.2) 
  → br-ex (10.0.11.183) 
  → Internet
```

### BGP Advertisement (192.168.100.0/24 → Router)

1. bgp-control VRF imports routes from cudn-net VRF
2. FRR advertises 192.168.100.0/24 via ens1
3. Router receives and installs multipath route

```
cudn-net VRF (192.168.100.0/24) 
  → import to bgp-control VRF 
  → BGP advertisement via ens1 
  → Router
```

## Key Differences: RouteAdvertisements vs Manual FRRConfiguration

| Aspect | RouteAdvertisements CR | Manual FRRConfiguration |
|--------|----------------------|------------------------|
| **VRF Imports** | Bidirectional (breaks egress) | One-way (bgp-control imports cudn-net only) |
| **Management** | Auto-generated per node | Single static config |
| **Egress Routing** | BGP default route imported | Clean default via br-ex |
| **BGP Advertisements** | ✅ Works | ✅ Works |
| **Internet Egress** | ❌ Broken | ✅ Works |

## Connectivity Matrix

| Source | Destination | Result | Notes |
|--------|-------------|--------|-------|
| VM (192.168.100.3) | Internet (8.8.8.8) | ✅ Works | Via br-ex SNAT |
| CUDN Pod (node-76) | VM (node-183) | ✅ Works | OVN Layer2 overlay |
| Node-183 (10.0.11.183) | VM (192.168.100.3) | ✅ Works | Same-node, local route |
| Node-76 (10.0.11.76) | VM (192.168.100.3) | ❌ Fails | VRF isolation by design |
| BGP Router | VM (192.168.100.3) | ✅ Works | Route learned via BGP |

**Note:** Cross-node access from host requires entering the CUDN namespace as a pod, not from the node's main VRF.

## Configuration Files

### ClusterUserDefinedNetwork

```yaml
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: cudn-net
  labels:
    network.type: kubevirt-l2
spec:
  namespaceSelector:
    matchLabels:
      network.type: kubevirt-l2
  
  network:
    topology: Layer2
    
    layer2:
      role: Primary
      subnets:
        - "192.168.100.0/24"
      mtu: 1400
      ipam:
        mode: Enabled
        lifecycle: Persistent
```

### FRRConfiguration (Final Working Version)

Located in: `openshift-frr-k8s` namespace as `bgp-control-vrf`

```yaml
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: bgp-control-vrf
  namespace: openshift-frr-k8s
  labels:
    app: bgp-router-vrf
spec:
  bgp:
    routers:
    - asn: 64512
      vrf: bgp-control
      imports:
      - vrf: cudn-net
      prefixes:
      - 192.168.100.0/24
      neighbors:
      - address: 10.0.14.111
        asn: 64500
        disableMP: true
        sourceaddress: ens1
        toAdvertise:
          allowed:
            mode: filtered
            prefixes:
            - 192.168.100.0/24
        toReceive:
          allowed:
            mode: all
    - asn: 64512
      vrf: cudn-net
  
  nodeSelector:
    matchLabels:
      bgp-peering: enabled
```

## Lessons Learned

### 1. RouteAdvertisements CRD Limitation

The `targetVRF` field in RouteAdvertisements has two modes:
- **`targetVRF: "bgp-control"`** - Creates bidirectional imports (breaks egress)
- **`targetVRF: "auto"`** - Requires VRF defined in source FRRConfiguration (validation error)

Neither mode supports our use case: advertise CUDN routes without importing BGP routes back.

### 2. VRF Import Direction Matters

One-way import is sufficient for BGP advertisements:
```
cudn-net VRF → bgp-control VRF → BGP neighbor
```

Reverse import is not needed and breaks egress by importing the BGP default route.

### 3. Manual FRRConfiguration Required

For this specific use case (advertise CUDN without affecting egress), manual FRRConfiguration is necessary. RouteAdvertisements CRD is designed for different scenarios (e.g., EVPN, full VRF peering).

### 4. routeViaHost Must Be Disabled

Earlier in this deployment, we discovered that `routeViaHost: true` breaks CUDN egress because:
- It delegates routing to host kernel
- Host VRF isolation prevents cudn-net VRF from reaching br-ex (in default VRF)

**Solution:** OVN handles egress internally with `routeViaHost: false` (upstream default).

### 5. AWS Source/Dest Check

All ENIs on c5.metal instances must have source/dest check disabled for BGP routing to work.

```bash
# Disable on all ENIs
aws ec2 modify-network-interface-attribute \
  --network-interface-id <eni-id> \
  --no-source-dest-check
```

## Troubleshooting Commands

### Check VRF Routing

```bash
# cudn-net VRF routes
oc debug node/<node> -- chroot /host ip route show vrf cudn-net

# bgp-control VRF routes
oc debug node/<node> -- chroot /host ip route show vrf bgp-control
```

### Check FRR Configuration

```bash
# View running FRR config
oc exec -n openshift-frr-k8s <frr-pod> -c frr -- vtysh -c 'show running-config'

# View BGP summary
oc exec -n openshift-frr-k8s <frr-pod> -c frr -- vtysh -c 'show ip bgp summary'
```

### Check BGP Advertisements

```bash
# On router
ssh ec2-user@<router-ip> 'sudo vtysh -c "show ip bgp 192.168.100.0/24"'

# On worker node
oc exec -n openshift-frr-k8s <frr-pod> -c frr -- vtysh -c 'show ip bgp vrf bgp-control'
```

### Test CUDN Egress

```bash
# From test pod
oc run test -n cudn-vms --image=nicolaka/netshoot --rm -it -- ping -c 3 8.8.8.8

# From VM (requires virtctl)
virtctl console -n cudn-vms <vm-name>
# Inside VM: ping -c 3 8.8.8.8
```

## References

- OVN-Kubernetes CUDN Documentation: `/Users/mathianasj/git/ovn-kubernetes/CUDN_SETUP_GUIDE.md`
- RouteAdvertisements Controller Source: `ovn-kubernetes/go-controller/pkg/clustermanager/routeadvertisements/controller.go`
- VRF Configuration: `/Users/mathianasj/git/virt-git-sync-demo/roles/ovn_bgp/tasks/configure_vrf.yml`

## Next Steps

1. **Playbook Update:** Update ansible playbooks to create manual FRRConfiguration instead of RouteAdvertisements
2. **Documentation:** Add this as a known limitation in deployment guides
3. **Monitoring:** Add alerting for BGP session state and CUDN egress connectivity
4. **Testing:** Implement automated tests for CUDN egress and BGP advertisements
