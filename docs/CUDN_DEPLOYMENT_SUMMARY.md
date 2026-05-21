# CUDN Deployment Summary

**Last Updated:** 2026-05-20  
**Status:** ✅ **FULLY OPERATIONAL**

## Current State

### Working Features

✅ **CUDN Network (192.168.100.0/24)**
- Layer2 Primary topology for KubeVirt VMs
- Persistent IP allocation (IPAM enabled)
- Multi-namespace support (labeled namespaces join automatically)

✅ **Internet Egress**
- VMs can access the internet via automatic SNAT
- Default route: `default via 10.0.11.1 dev br-ex` (OVN overlay)
- DNS resolution working
- HTTP/HTTPS egress verified

✅ **BGP Route Advertisements**
- CUDN subnet (192.168.100.0/24) advertised to external BGP routers
- Multipath routing (both workers advertising)
- BGP sessions established: ASN 64512 (workers) ↔ ASN 64500 (routers)

✅ **VRF Isolation**
- bgp-control VRF (table 1000): BGP peering via ens1
- cudn-net VRF (table 1691): CUDN workload traffic
- Clean separation between control and data planes

✅ **Cross-Node VM Connectivity**
- VMs can communicate across nodes via OVN Layer2 overlay
- Live migration supported (IP persistence)

## Configuration Overview

### Key Components

| Component | Value | Location |
|-----------|-------|----------|
| **CUDN Name** | `cudn-net` | ClusterUserDefinedNetwork CR |
| **CUDN CIDR** | `192.168.100.0/24` | Layer2 subnet |
| **VM Namespace** | `cudn-vms` | Labeled with `network.type: kubevirt-l2` |
| **FRRConfiguration** | `bgp-control-vrf` | `openshift-frr-k8s` namespace |
| **BGP ASN (Workers)** | `64512` | Both hub and managed clusters |
| **BGP ASN (Routers)** | `64500` | FRR routers on EC2 |
| **BGP Peer IP (Hub)** | `10.0.14.111` | frr-router-hub |
| **VRF Names** | `bgp-control`, `cudn-net` | Linux VRF interfaces |

### Network Topology

```
Internet
   ↑
   │ (SNAT to 10.0.11.183)
   │
┌──┴────────────────────────────────────────┐
│ br-ex (default VRF)                       │
│   ↑                                       │
│   │ default route from cudn-net VRF       │
│   │                                       │
│ ┌─┴──────────────────┐                   │
│ │ cudn-net VRF       │                   │
│ │ (table 1691)       │                   │
│ │                    │                   │
│ │ ovn-k8s-mp2        │◄─────┐            │
│ │ 192.168.100.2      │      │            │
│ └────────────────────┘      │            │
│           ▲                 │            │
│           │ VMs             │ import     │
│           │                 │            │
│   192.168.100.3/24          │            │
│   (KubeVirt VM)             │            │
│                             │            │
│ ┌───────────────────────────┴──┐         │
│ │ bgp-control VRF              │         │
│ │ (table 1000)                 │         │
│ │                              │         │
│ │ ens1 ──────────────────────► │         │
│ └──────────────────────────────┘         │
│              │                            │
└──────────────┼────────────────────────────┘
               │ BGP session
               ▼
         BGP Router (10.0.14.111)
         ASN 64500
         Route: 192.168.100.0/24 via workers
```

## Important Notes

### ⚠️ Do NOT Use RouteAdvertisements CR

The OVN-Kubernetes `RouteAdvertisements` CR creates **bidirectional VRF imports** which breaks CUDN egress:

```yaml
# RouteAdvertisements creates this (BAD):
routers:
- vrf: bgp-control
  imports: [vrf: cudn-net]      # ✅ Needed for advertising
- vrf: cudn-net
  imports: [vrf: bgp-control]   # ❌ Breaks egress!
```

**Why it breaks:** The reverse import pulls the BGP default route into cudn-net VRF, overriding the br-ex default route needed for internet egress.

**Solution:** Use manual `FRRConfiguration` with one-way import only (see `cudn-bgp-vrf-implementation.md`).

### 🔧 Manual FRRConfiguration Required

Current configuration uses manual FRRConfiguration (`bgp-control-vrf`) instead of RouteAdvertisements:

```yaml
# Manual FRRConfiguration (GOOD):
routers:
- vrf: bgp-control
  imports: [vrf: cudn-net]      # ✅ One-way import
  neighbors: [...]
- vrf: cudn-net                 # ✅ No imports (clean egress)
```

This allows:
- ✅ BGP advertisements of CUDN routes
- ✅ Internet egress via OVN overlay
- ✅ No route leaking from BGP to CUDN

## Verification Tests (All Passing)

```bash
# Test 1: VM Internet Egress ✅
oc run test -n cudn-vms --image=nicolaka/netshoot --rm -it -- ping -c 3 8.8.8.8
# Result: 3 packets transmitted, 3 received, 0% packet loss

# Test 2: BGP Route on Router ✅
ssh ec2-user@<router-ip> 'sudo vtysh -c "show ip bgp 192.168.100.0/24"'
# Result: 2 paths available (multipath from both workers)

# Test 3: Default Route in cudn-net VRF ✅
oc debug node/ip-10-0-11-183.ec2.internal -- chroot /host ip route show vrf cudn-net | grep default
# Result: default via 10.0.11.1 dev br-ex mtu 8901

# Test 4: Cross-Node VM Connectivity ✅
# Pod on node-76 → VM on node-183
# Result: Ping successful via OVN Layer2 overlay
```

## Known Limitations

### 1. Node-to-VM Cross-Node Access

**Limitation:** Nodes cannot ping VMs on other nodes from the default VRF.

**Reason:** VRF isolation by design. Node's default VRF (10.0.11.x) is separate from cudn-net VRF (192.168.100.x).

**Workaround:** Access VMs via pods in the CUDN namespace:
```bash
oc run test -n cudn-vms --image=nicolaka/netshoot --rm -it -- ping 192.168.100.3
```

**Same-node access works:** Nodes can ping VMs running on the same node due to local routing.

### 2. RouteAdvertisements CRD Not Compatible

**Limitation:** Cannot use RouteAdvertisements CR for this use case.

**Reason:** Always creates bidirectional VRF imports, regardless of `targetVRF` setting.

**Solution:** Use manual FRRConfiguration (current configuration).

### 3. FRR Pod Restart Required After Config Changes

**Limitation:** FRRConfiguration changes don't always reload automatically.

**Workaround:** Delete FRR pods to force reload:
```bash
oc delete pod -n openshift-frr-k8s <frr-pod-name>
```

## Troubleshooting Quick Links

| Issue | Documentation |
|-------|--------------|
| VM cannot reach internet | [Operations Guide - Troubleshooting](cudn-operations-guide.md#issue-vm-cannot-reach-internet) |
| BGP not advertising | [Operations Guide - Troubleshooting](cudn-operations-guide.md#issue-bgp-not-advertising-cudn-routes) |
| Node cannot ping VM | [Operations Guide - Troubleshooting](cudn-operations-guide.md#issue-node-cannot-ping-vm) |
| Full technical details | [Implementation Guide](cudn-bgp-vrf-implementation.md) |

## Critical Configuration Files

### On Cluster

```bash
# CUDN definition
oc get clusteruserdefinednetwork cudn-net -o yaml

# FRRConfiguration (BGP setup)
oc get frrconfiguration bgp-control-vrf -n openshift-frr-k8s -o yaml

# CUDN namespace
oc get namespace cudn-vms -o yaml
```

### In Repository

- **Implementation Guide:** `docs/cudn-bgp-vrf-implementation.md`
- **Operations Guide:** `docs/cudn-operations-guide.md`
- **Ansible Role:** `roles/cudn/`
- **VRF Configuration:** `roles/ovn_bgp/tasks/configure_vrf.yml`

## Deployment Checklist

- [x] CUDN ClusterUserDefinedNetwork created
- [x] Namespace labeled for CUDN
- [x] VRF interfaces configured (bgp-control, cudn-net)
- [x] FRRConfiguration deployed (manual, not RouteAdvertisements)
- [x] FRR pods running on worker nodes
- [x] BGP sessions established
- [x] CUDN routes advertised to router
- [x] VM internet egress tested
- [x] Cross-node VM connectivity tested
- [x] Documentation completed

## Next Steps

1. **Update Playbooks**
   - Modify `roles/cudn/tasks/route_advertisement.yml` to create manual FRRConfiguration
   - Remove RouteAdvertisements CR creation
   - Document playbook changes

2. **Monitoring Setup**
   - Add Prometheus metrics for BGP session state
   - Alert on CUDN egress failures
   - Monitor VRF default route changes

3. **Testing Automation**
   - Create automated test suite for CUDN egress
   - Verify BGP advertisements in CI/CD
   - Test VM live migration with persistent IPs

4. **Future Enhancements**
   - Explore per-VM /32 BGP advertisements
   - Implement network policies for CUDN
   - Add multi-cluster CUDN federation

## Contact & Support

- **Implementation Details:** See `cudn-bgp-vrf-implementation.md`
- **Day-to-day Operations:** See `cudn-operations-guide.md`
- **Upstream Documentation:** `/Users/mathianasj/git/ovn-kubernetes/CUDN_SETUP_GUIDE.md`

---

**Deployment Date:** 2026-05-20  
**Deployed By:** Automation via Ansible  
**Last Verified:** 2026-05-20 15:00 UTC  
**Status:** ✅ OPERATIONAL
