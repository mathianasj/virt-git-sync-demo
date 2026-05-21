# CUDN Operations Quick Reference

## Quick Status Checks

### Check CUDN Status
```bash
# Get CUDN
oc get clusteruserdefinednetwork cudn-net

# Get NetworkAttachmentDefinition
oc get network-attachment-definitions -n cudn-vms

# Get CUDN namespace labels
oc get ns cudn-vms --show-labels
```

### Check BGP Status
```bash
# BGP sessions on router
ssh ec2-user@<router-ip> 'sudo vtysh -c "show ip bgp summary"'

# BGP routes for CUDN subnet
ssh ec2-user@<router-ip> 'sudo vtysh -c "show ip bgp 192.168.100.0/24"'

# FRR pods status
oc get pods -n openshift-frr-k8s

# FRRConfiguration
oc get frrconfiguration -n openshift-frr-k8s bgp-control-vrf -o yaml
```

### Check VRF Routing
```bash
# cudn-net VRF routes (should have default via br-ex)
oc debug node/ip-10-0-11-183.ec2.internal -- chroot /host ip route show vrf cudn-net | grep default

# Expected output:
# default via 10.0.11.1 dev br-ex mtu 8901

# bgp-control VRF routes
oc debug node/ip-10-0-11-183.ec2.internal -- chroot /host ip route show vrf bgp-control
```

### Check VM Status
```bash
# VMs in CUDN namespace
oc get vm -n cudn-vms

# VM pods
oc get pods -n cudn-vms -l kubevirt.io/domain

# VM IP addresses
oc get pod <virt-launcher-pod> -n cudn-vms \
  -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | jq .
```

## Common Operations

### Test CUDN Egress
```bash
# From test pod
oc run test-egress -n cudn-vms --image=nicolaka/netshoot --rm -it -- ping -c 3 8.8.8.8

# Check DNS resolution
oc run test-dns -n cudn-vms --image=nicolaka/netshoot --rm -it -- nslookup google.com

# Check HTTP egress
oc run test-http -n cudn-vms --image=nicolaka/netshoot --rm -it -- curl -I https://google.com
```

### Test Cross-Node Connectivity
```bash
# Create test pod on specific node
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-node76
  namespace: cudn-vms
spec:
  nodeSelector:
    kubernetes.io/hostname: ip-10-0-11-76.ec2.internal
  containers:
  - name: netshoot
    image: nicolaka/netshoot
    command: ["sleep", "3600"]
EOF

# Wait for pod
oc wait --for=condition=Ready pod/test-node76 -n cudn-vms --timeout=60s

# Test connectivity to VM
oc exec -n cudn-vms test-node76 -- ping -c 3 192.168.100.3

# Cleanup
oc delete pod test-node76 -n cudn-vms
```

### Restart FRR Pods
```bash
# Get FRR pods on BGP nodes
oc get pods -n openshift-frr-k8s -o wide | grep -E 'ip-10-0-11-(183|76)'

# Delete to restart
oc delete pod -n openshift-frr-k8s <pod-name>

# Wait for new pods to be ready
oc wait --for=condition=Ready pod -l app.kubernetes.io/name=frr-k8s \
  -n openshift-frr-k8s --timeout=120s
```

### Verify FRRConfiguration Applied
```bash
# Check FRR running config
oc exec -n openshift-frr-k8s <frr-pod> -c frr -- vtysh -c 'show running-config' | grep -A 30 'router bgp'

# Should show:
# - router bgp 64512 vrf bgp-control (with imports from cudn-net)
# - router bgp 64512 vrf cudn-net (NO imports)
```

## Troubleshooting

### Issue: VM Cannot Reach Internet

**Symptoms:**
- DNS fails or ping to 8.8.8.8 fails from VM

**Check:**
```bash
# 1. Verify default route in cudn-net VRF
oc debug node/<node> -- chroot /host ip route show vrf cudn-net | grep default

# Expected: default via 10.0.11.1 dev br-ex
# NOT: default via 10.0.14.111 dev ens1 proto bgp (this is WRONG)

# 2. Check if RouteAdvertisement is causing bidirectional imports
oc get routeadvertisements

# 3. Check FRRConfiguration for cudn-net router
oc get frrconfiguration bgp-control-vrf -n openshift-frr-k8s -o yaml | grep -A 5 'vrf: cudn-net'

# Should have NO imports field under cudn-net router
```

**Fix:**
```bash
# If default route is wrong, delete RouteAdvertisements and use manual FRRConfiguration
oc delete routeadvertisements cudn-advertisement

# Apply manual FRRConfiguration (see cudn-bgp-vrf-implementation.md)
# Then restart FRR pods
```

### Issue: BGP Not Advertising CUDN Routes

**Symptoms:**
- Router does not see 192.168.100.0/24 route

**Check:**
```bash
# 1. Verify BGP sessions are established
oc exec -n openshift-frr-k8s <frr-pod> -c frr -- vtysh -c 'show ip bgp summary'

# Look for state "Established" or PfxRcd > 0

# 2. Check bgp-control VRF is importing from cudn-net
oc exec -n openshift-frr-k8s <frr-pod> -c frr -- vtysh -c 'show running-config' | grep -A 5 'router bgp 64512 vrf bgp-control'

# Should see: import vrf cudn-net

# 3. Verify route is in bgp-control VRF
oc debug node/<node> -- chroot /host ip route show vrf bgp-control | grep 192.168.100
```

**Fix:**
```bash
# Update FRRConfiguration to ensure bgp-control imports cudn-net
# See section "Step 2: Create Manual FRRConfiguration" in cudn-bgp-vrf-implementation.md
```

### Issue: BGP Session Not Established

**Symptoms:**
- `show ip bgp summary` shows state "Idle" or "Active"

**Check:**
```bash
# 1. Verify ens1 is in bgp-control VRF
oc debug node/<node> -- chroot /host ip link show ens1 | grep 'master bgp-control'

# 2. Check BGP peering interface has IP
oc debug node/<node> -- chroot /host ip addr show ens1

# 3. Test connectivity to peer
oc debug node/<node> -- chroot /host ip vrf exec bgp-control ping -c 3 10.0.14.111

# 4. Check FRR logs
oc logs -n openshift-frr-k8s <frr-pod> -c frr | grep -i bgp
```

**Fix:**
```bash
# Common causes:
# - Source/dest check enabled on AWS ENI
aws ec2 describe-network-interfaces --network-interface-ids <eni-id> \
  --query 'NetworkInterfaces[0].SourceDestCheck'

# Disable if true
aws ec2 modify-network-interface-attribute \
  --network-interface-id <eni-id> \
  --no-source-dest-check

# - Wrong peer IP or ASN in FRRConfiguration
oc edit frrconfiguration bgp-control-vrf -n openshift-frr-k8s
```

### Issue: Node Cannot Ping VM

**This is expected behavior for cross-node access.**

**Why:**
- Node's default VRF (10.0.11.x) is isolated from cudn-net VRF (192.168.100.x)
- VM cannot route back to 10.0.11.x addresses

**Same-node access works:**
```bash
# If VM is on node-183, ping from node-183 works
oc debug node/ip-10-0-11-183.ec2.internal -- chroot /host ping -c 3 192.168.100.3
```

**Cross-node access requires CUDN pod:**
```bash
# Create pod in CUDN on the remote node
oc run test -n cudn-vms --image=nicolaka/netshoot --rm -it -- ping 192.168.100.3
```

### Issue: FRR Pod CrashLoopBackOff

**Check:**
```bash
# Get pod status
oc get pods -n openshift-frr-k8s -l app.kubernetes.io/name=frr-k8s

# Check logs
oc logs -n openshift-frr-k8s <frr-pod> -c frr --tail=100

# Common errors:
# - "VRF cudn-net not found" - VRF interface doesn't exist on node
# - "Address already in use" - Stale FRR process
```

**Fix:**
```bash
# Verify VRF exists on node
oc debug node/<node> -- chroot /host ip link show cudn-net

# Delete and recreate FRR pod
oc delete pod -n openshift-frr-k8s <frr-pod>
```

## Monitoring

### Key Metrics to Watch

**BGP Session Health:**
```bash
# Check every 5 minutes
ssh ec2-user@<router-ip> 'sudo vtysh -c "show ip bgp summary" | tail -5'

# Alert if State != Established
```

**CUDN Egress:**
```bash
# Daily egress test
oc run daily-egress-test -n cudn-vms --image=nicolaka/netshoot --restart=Never \
  -- /bin/sh -c "ping -c 3 8.8.8.8 && curl -sI https://google.com"

# Check result
oc logs -n cudn-vms daily-egress-test

# Cleanup
oc delete pod daily-egress-test -n cudn-vms
```

**VRF Default Route:**
```bash
# Ensure default route is via br-ex, not BGP
oc debug node/<node> -- chroot /host ip route show vrf cudn-net | grep default

# Alert if contains "proto bgp"
```

## Configuration Backup

### Export Current Configuration
```bash
# CUDN
oc get clusteruserdefinednetwork cudn-net -o yaml > cudn-net-backup.yaml

# FRRConfiguration
oc get frrconfiguration bgp-control-vrf -n openshift-frr-k8s -o yaml > frr-config-backup.yaml

# Namespace
oc get ns cudn-vms -o yaml > cudn-namespace-backup.yaml

# All VMs
oc get vm -n cudn-vms -o yaml > vms-backup.yaml
```

### Restore Configuration
```bash
# Apply in order
oc apply -f cudn-namespace-backup.yaml
oc apply -f cudn-net-backup.yaml
oc apply -f frr-config-backup.yaml
oc apply -f vms-backup.yaml
```

## Emergency Rollback

### Disable BGP Advertisements
```bash
# Remove BGP neighbor from FRRConfiguration
oc patch frrconfiguration bgp-control-vrf -n openshift-frr-k8s \
  --type=json -p='[{"op": "remove", "path": "/spec/bgp/routers/0/neighbors"}]'
```

### Restore CUDN Egress Only (No BGP)
```bash
# Delete FRRConfiguration
oc delete frrconfiguration bgp-control-vrf -n openshift-frr-k8s

# CUDN will still work for egress, just no BGP advertisements
```

### Complete CUDN Removal
```bash
# Stop all VMs
oc delete vm --all -n cudn-vms

# Delete namespace
oc delete ns cudn-vms

# Delete CUDN
oc delete clusteruserdefinednetwork cudn-net

# Wait for cleanup
oc get network-attachment-definitions -A | grep cudn
```

## Useful Aliases

Add to `~/.bashrc` or `~/.zshrc`:

```bash
# CUDN shortcuts
alias cudn-status='oc get clusteruserdefinednetwork,nad,vm,pods -n cudn-vms'
alias cudn-test='oc run test-egress -n cudn-vms --image=nicolaka/netshoot --rm -it -- ping -c 3 8.8.8.8'
alias bgp-status='oc exec -n openshift-frr-k8s $(oc get pods -n openshift-frr-k8s -l app.kubernetes.io/name=frr-k8s -o name | head -1) -c frr -- vtysh -c "show ip bgp summary"'
alias vrf-routes='oc debug node/ip-10-0-11-183.ec2.internal -- chroot /host ip route show vrf cudn-net'
```

## Related Documentation

- **Implementation Details:** `cudn-bgp-vrf-implementation.md`
- **Architecture Diagrams:** `architecture-diagrams.md`
- **Upstream CUDN Guide:** `/Users/mathianasj/git/ovn-kubernetes/CUDN_SETUP_GUIDE.md`
- **Upstream Examples:** `/Users/mathianasj/git/ovn-kubernetes/CUDN_QUICKSTART_EXAMPLES.yaml`
