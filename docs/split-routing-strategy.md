# Split Routing Strategy for Multi-AZ Deployments

## Problem Statement

In the original deployment, all private subnets across all availability zones shared a single route table that directed internet traffic (0.0.0.0/0) to the BGP router's ENI. This created a critical issue:

- **BGP router exists only in us-east-1a** (subnet 10.X.11.0/24)
- **Control plane nodes span 3 AZs:** us-east-1a, us-east-1b, us-east-1c
- **Control plane nodes in us-east-1b and us-east-1c couldn't reach the internet** through the BGP router in us-east-1a

### Impact

This caused several cluster operators to fail:

1. **Authentication Operator:** Degraded - couldn't reach OAuth endpoint
2. **Console Operator:** Degraded - couldn't reach console route health check
3. **Ingress Operator:** Degraded - canary checks failing
4. **Users couldn't login to the console** - authentication was broken

The authentication operator runs on control plane nodes and needs to verify the OAuth server health endpoint at `https://oauth-openshift.apps.managed.sandbox2629.opentlc.com/healthz`. This endpoint resolves to the cluster's load balancer public IPs, requiring internet connectivity.

## Solution: Split Routing

We implemented separate route tables for worker and control plane subnets:

### Architecture

```
VPC: 10.X.0.0/16
├── Private Subnet 10.X.11.0/24 (us-east-1a) - WORKER SUBNET
│   ├── Route Table: managed-cluster-vpc-private-rt
│   └── Default Route: 0.0.0.0/0 → BGP Router ENI
│       - Used by: Bare metal worker nodes
│       - Purpose: VM networking via BGP, internet via NAT
│
├── Private Subnet 10.X.12.0/24 (us-east-1b) - CONTROL PLANE
│   ├── Route Table: managed-cluster-vpc-private-rt-us-east-1b
│   └── Default Route: 0.0.0.0/0 → NAT Gateway
│       - Used by: Control plane nodes
│       - Purpose: Direct internet access for cluster operators
│
└── Private Subnet 10.X.13.0/24 (us-east-1c) - CONTROL PLANE
    ├── Route Table: managed-cluster-vpc-private-rt-us-east-1c
    └── Default Route: 0.0.0.0/0 → NAT Gateway
        - Used by: Control plane nodes
        - Purpose: Direct internet access for cluster operators
```

### Route Table Details

**Worker Subnet Route Table** (10.X.11.0/24):
- `10.X.0.0/16` → local (VPC)
- `0.0.0.0/0` → BGP Router ENI (eni-XXX)
- `10.0.0.0/16` → VPC Peering (to hub cluster)
- `10.255.0.0/16` → VPC Peering (to bastion)
- `192.168.100.0/24` → BGP Router ENI (CUDN VM network)

**Control Plane Route Tables** (10.X.12.0/24, 10.X.13.0/24):
- `10.X.0.0/16` → local (VPC)
- `0.0.0.0/0` → NAT Gateway (nat-XXX)
- `10.0.0.0/16` → VPC Peering (to hub cluster)
- `10.255.0.0/16` → VPC Peering (to bastion)
- `192.168.100.0/24` → BGP Router ENI (CUDN VM network)

## Traffic Flows

### Control Plane Node → Internet
```
Control Plane Node (10.X.12.Y)
  ↓ (VPC route: 0.0.0.0/0 → NAT-GW)
NAT Gateway (10.X.1.Z)
  ↓
Internet Gateway
  ↓
Internet (e.g., oauth-openshift.apps.managed...)
```

### Control Plane Node → CUDN VM
```
Control Plane Node (10.X.12.Y)
  ↓ (VPC route: 192.168.100.0/24 → BGP Router)
BGP Router (10.X.11.224)
  ↓ (BGP advertisement)
Worker Node (10.X.11.Z)
  ↓ (bridge interface)
VM (192.168.100.A)
```

### Worker Node → Internet
```
Worker Node (10.X.11.Y)
  ↓ (VPC route: 0.0.0.0/0 → BGP Router)
BGP Router (10.X.11.224)
  ├─ ens5: 10.X.11.224 (worker subnet)
  └─ ens6: 10.X.1.235 (public subnet)
      ↓ (iptables MASQUERADE)
      ↓ (default via NAT Gateway IP)
NAT Gateway (10.X.1.99)
  ↓
Internet Gateway
  ↓
Internet
```

## Implementation

The split routing is configured by `roles/router/tasks/update_vpc_route_tables_split.yml`:

1. **Identifies subnets by AZ:**
   - Worker subnet: Same AZ as BGP router (us-east-1a)
   - Control plane subnets: Other AZs (us-east-1b, us-east-1c)

2. **Updates worker subnet route table:**
   - Changes existing default route to point to BGP router ENI

3. **Creates new route tables for control plane subnets:**
   - One route table per control plane subnet
   - Default route to NAT Gateway
   - VPC peering routes to hub and bastion
   - CUDN network route via BGP router

4. **Associates subnets with new route tables:**
   - Replaces existing route table associations

## Benefits

1. **Control plane nodes have internet access:** Can reach OAuth, console, and external services
2. **Worker nodes still use BGP:** VM networking and BGP-advertised routes work as expected
3. **Cluster operators healthy:** Authentication, console, and ingress operators all functional
4. **Console login works:** Users can authenticate and access the web console
5. **No impact on VM networking:** CUDN traffic still routes through BGP router

## Rollback

If split routing causes issues, you can rollback to single route table:

```bash
ansible-playbook playbooks/78-rollback-vpc-routing.yml
```

This will:
- Delete the per-subnet control plane route tables
- Associate all subnets back to the original shared route table
- Update the shared route table to route through NAT Gateway OR BGP router (configurable)

## Testing

After applying split routing, verify:

1. **Control plane node internet connectivity:**
   ```bash
   oc debug node/<control-plane-node> -- chroot /host ping -c 3 8.8.8.8
   ```

2. **Control plane node can reach OAuth:**
   ```bash
   oc debug node/<control-plane-node> -- chroot /host curl -k -I https://oauth-openshift.apps.managed.sandbox2629.opentlc.com/healthz
   ```

3. **Cluster operators healthy:**
   ```bash
   oc get co | grep -v "True.*False.*False"
   ```

4. **Console accessible:**
   ```bash
   oc whoami --show-console
   # Open in browser and login with kubeadmin
   ```

5. **Worker node internet via BGP router:**
   ```bash
   oc debug node/<worker-node> -- chroot /host ping -c 3 8.8.8.8
   ```

## Related Documentation

- [BGP Router NAT Configuration](bgp-router-nat-configuration.md)
- [Architecture Diagrams](architecture-diagrams.md)
- [Multi-VPC Setup](multi-vpc-setup.md)
- [DEPLOYMENT_STATUS.md](DEPLOYMENT_STATUS.md)
