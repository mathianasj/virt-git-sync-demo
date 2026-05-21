# CUDN Troubleshooting Quick Reference Card

## Emergency Commands

```bash
# Quick status check
oc get clusteruserdefinednetwork,frrconfiguration -A

# Test internet egress
oc run test -n cudn-vms --image=nicolaka/netshoot --rm -it -- ping -c 3 8.8.8.8

# Check default route (should be via br-ex, NOT via ens1)
oc debug node/ip-10-0-11-183.ec2.internal -- chroot /host \
  ip route show vrf cudn-net | grep default

# BGP status
ssh ec2-user@<router-ip> 'sudo vtysh -c "show ip bgp summary"'
```

## Common Issues

### ❌ VM Cannot Reach Internet

**Quick Fix:**
```bash
# Check if default route is via BGP (WRONG)
oc debug node/<node> -- chroot /host ip route show vrf cudn-net | grep "proto bgp"

# If found, delete RouteAdvertisements CR
oc delete routeadvertisements cudn-advertisement

# Restart FRR pods
oc delete pod -n openshift-frr-k8s -l bgp-peering=enabled
```

**Root Cause:** Bidirectional VRF import from RouteAdvertisements CR

**Correct Default Route:**
```
default via 10.0.11.1 dev br-ex mtu 8901
```

**Wrong Default Route:**
```
default via 10.0.14.111 dev ens1 proto bgp  # ← WRONG!
```

---

### ❌ BGP Not Advertising Routes

**Quick Check:**
```bash
# On router
ssh ec2-user@<router-ip> 'sudo vtysh -c "show ip bgp 192.168.100.0/24"'

# Should show 2 paths (multipath)
# If not, check FRRConfiguration
oc get frrconfiguration bgp-control-vrf -n openshift-frr-k8s -o yaml
```

**Required Config:**
```yaml
spec:
  bgp:
    routers:
    - asn: 64512
      vrf: bgp-control
      imports:
      - vrf: cudn-net  # ← Must import CUDN routes
      neighbors:
      - address: 10.0.14.111
        toAdvertise:
          allowed:
            prefixes:
            - 192.168.100.0/24  # ← Must advertise CUDN subnet
```

**Fix:**
```bash
# Verify bgp-control VRF imports cudn-net
oc get frrconfiguration bgp-control-vrf -n openshift-frr-k8s -o yaml | grep -A 3 imports

# Restart FRR pods if config is correct
oc delete pod -n openshift-frr-k8s <frr-pod>
```

---

### ❌ BGP Session Not Established

**Quick Check:**
```bash
# Check BGP session state
oc exec -n openshift-frr-k8s <frr-pod> -c frr -- \
  vtysh -c 'show ip bgp summary' | tail -5

# Test connectivity to peer
oc debug node/<node> -- chroot /host \
  ip vrf exec bgp-control ping -c 3 10.0.14.111
```

**Common Causes:**
1. **AWS Source/Dest Check Enabled**
   ```bash
   aws ec2 describe-network-interfaces --network-interface-ids <eni-id> \
     --query 'NetworkInterfaces[0].SourceDestCheck'
   
   # Disable if true
   aws ec2 modify-network-interface-attribute \
     --network-interface-id <eni-id> --no-source-dest-check
   ```

2. **Wrong Peer IP in FRRConfiguration**
   ```bash
   oc get frrconfiguration bgp-control-vrf -n openshift-frr-k8s \
     -o jsonpath='{.spec.bgp.routers[0].neighbors[0].address}'
   ```

3. **ens1 Not in bgp-control VRF**
   ```bash
   oc debug node/<node> -- chroot /host \
     ip link show ens1 | grep "master bgp-control"
   ```

---

### ⚠️ Node Cannot Ping VM (Cross-Node)

**This is EXPECTED behavior.**

**Why:** VRF isolation. Node's default VRF (10.0.11.x) cannot reach cudn-net VRF (192.168.100.x).

**Same-Node Works:**
```bash
# If VM is on node-183
oc debug node/ip-10-0-11-183.ec2.internal -- chroot /host ping -c 3 192.168.100.3
# ✅ Works
```

**Cross-Node Access:**
```bash
# Use a pod in CUDN namespace
oc run test -n cudn-vms --image=nicolaka/netshoot --rm -it -- ping 192.168.100.3
# ✅ Works
```

---

## Critical Checks

### ✅ Healthy CUDN

```bash
# 1. Default route via br-ex
$ oc debug node/<node> -- chroot /host ip route show vrf cudn-net | grep default
default via 10.0.11.1 dev br-ex mtu 8901 ✅

# 2. BGP sessions established
$ ssh <router> 'sudo vtysh -c "show ip bgp summary"'
10.0.14.140     4  64512  ...  Established ✅
10.0.14.144     4  64512  ...  Established ✅

# 3. Router has CUDN route
$ ssh <router> 'sudo vtysh -c "show ip bgp 192.168.100.0/24"'
Paths: (2 available, best #1)
  64512 from 10.0.14.140 (multipath) ✅
  64512 from 10.0.14.144 (multipath) ✅

# 4. Internet egress works
$ oc run test -n cudn-vms --image=nicolaka/netshoot --rm -it -- ping -c 3 8.8.8.8
3 packets transmitted, 3 received, 0% packet loss ✅
```

---

## Configuration Hierarchy

```
Manual FRRConfiguration (bgp-control-vrf)
  ├─ bgp-control VRF router
  │   ├─ imports: [cudn-net]        ← Reads CUDN routes
  │   ├─ neighbors: [10.0.14.111]   ← BGP peer
  │   └─ toAdvertise: [192.168.100.0/24]
  └─ cudn-net VRF router
      └─ NO imports                  ← Keep egress clean!

VRF Routing Tables
  ├─ cudn-net VRF (table 1691)
  │   └─ default → br-ex            ← Internet egress
  └─ bgp-control VRF (table 1000)
      └─ peering via ens1           ← BGP neighbor
```

---

## Don't Do This! ⚠️

### ❌ Do NOT Use RouteAdvertisements CR
```yaml
# This breaks egress!
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: cudn-advertisement
spec:
  targetVRF: bgp-control  # ← Creates bidirectional imports
```

**Why:** Always creates bidirectional VRF imports → BGP default route imported into cudn-net → breaks internet egress

**Use:** Manual FRRConfiguration instead

---

### ❌ Do NOT Set routeViaHost: true
```yaml
# This breaks egress!
spec:
  network:
    layer2:
      routeViaHost: true  # ← Breaks VRF isolation
```

**Why:** Delegates routing to host kernel → cudn-net VRF can't reach br-ex (in default VRF)

**Use:** `routeViaHost: false` (default)

---

## Recovery Procedures

### Emergency: Restore Internet Egress Only

```bash
# 1. Delete RouteAdvertisements
oc delete routeadvertisements cudn-advertisement

# 2. Delete manual FRRConfiguration
oc delete frrconfiguration bgp-control-vrf -n openshift-frr-k8s

# 3. Restart FRR pods
oc delete pod -n openshift-frr-k8s -l app.kubernetes.io/name=frr-k8s

# Result: CUDN egress works, no BGP advertisements
```

### Full Reset

```bash
# 1. Stop VMs
oc delete vm --all -n cudn-vms

# 2. Delete namespace
oc delete ns cudn-vms

# 3. Delete CUDN
oc delete clusteruserdefinednetwork cudn-net

# 4. Delete FRRConfiguration
oc delete frrconfiguration bgp-control-vrf -n openshift-frr-k8s

# 5. Redeploy
ansible-playbook playbooks/15-cudn-network.yml
```

---

## Key Files

| Resource | Location |
|----------|----------|
| **CUDN** | `oc get clusteruserdefinednetwork cudn-net` |
| **FRRConfiguration** | `oc get frrconfiguration bgp-control-vrf -n openshift-frr-k8s` |
| **Namespace** | `oc get ns cudn-vms` |
| **VMs** | `oc get vm -n cudn-vms` |

---

## Contact Info

- **Full Documentation:** `docs/cudn-bgp-vrf-implementation.md`
- **Operations Guide:** `docs/cudn-operations-guide.md`
- **Deployment Summary:** `docs/CUDN_DEPLOYMENT_SUMMARY.md`

---

**Last Updated:** 2026-05-20  
**Version:** 1.0  
**Status:** ✅ OPERATIONAL
