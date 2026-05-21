# BGP Router Deployment Changes for VM Internet Connectivity

## Current Problem

VMs on the CUDN network (192.168.100.0/24) cannot reach the internet because:
1. VM traffic uses routing table 1007 which has `default via 10.0.0.1` (VPC gateway)
2. VPC gateway doesn't know how to route return traffic to 192.168.100.0/24
3. FRR can't override kernel DHCP routes in table 1007

## Proper Solution: AWS VPC Route Tables

Instead of fighting DHCP settings, use AWS VPC route tables (the AWS-native approach):

### Architecture
```
VM (192.168.100.3)
  ↓
Node (table 1007 → default via 10.0.0.1)
  ↓
VPC Router (10.0.0.1)
  ↓
VPC Route Table (0.0.0.0/0 → BGP Router instead of IGW)
  ↓
BGP Router (10.0.3.190)
  ↓
Internet Gateway
  ↓
Internet
```

## Required Changes

### 1. Router Role Enhancement (`roles/router/tasks/main.yml`)

Add after router deployment (around line 243):

```yaml
- name: Configure BGP router for NAT and forwarding
  shell: |
    aws ec2-instance-connect send-ssh-public-key \
      --region {{ aws_region }} \
      --instance-id {{ router_hub_instance.stdout }} \
      --instance-os-user ec2-user \
      --ssh-public-key "$(cat ~/.ssh/{{ router_key_name }}.pub)"
    
    ssh -i ~/.ssh/{{ router_key_name }} -o StrictHostKeyChecking=no ec2-user@{{ router_info[0].PublicIp }} << 'EOF'
      # Enable NAT for OpenShift traffic
      sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/16 -o eth0 -j MASQUERADE
      
      # Save iptables rules
      sudo service iptables save
      
      # Verify IP forwarding
      sudo sysctl net.ipv4.ip_forward
    EOF
  register: router_nat_config
  changed_when: true

- name: Get VPC route table for OpenShift nodes subnet
  shell: |
    aws ec2 describe-route-tables \
      --region {{ aws_region }} \
      --filters "Name=association.subnet-id,Values={{ hub_subnet_id }}" \
      --query 'RouteTables[0].RouteTableId' \
      --output text
  register: route_table_id
  changed_when: false

- name: Update VPC route table to use BGP router for default route
  shell: |
    # Get BGP router private IP
    ROUTER_IP=$(aws ec2 describe-instances \
      --region {{ aws_region }} \
      --instance-ids {{ router_hub_instance.stdout }} \
      --query 'Reservations[0].Instances[0].PrivateIpAddress' \
      --output text)
    
    # Check if default route exists
    CURRENT_TARGET=$(aws ec2 describe-route-tables \
      --region {{ aws_region }} \
      --route-table-ids {{ route_table_id.stdout }} \
      --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId' \
      --output text)
    
    if [ -n "$CURRENT_TARGET" ] && [ "$CURRENT_TARGET" != "None" ]; then
      # Delete existing default route (likely pointing to IGW)
      aws ec2 delete-route \
        --region {{ aws_region }} \
        --route-table-id {{ route_table_id.stdout }} \
        --destination-cidr-block 0.0.0.0/0
    fi
    
    # Add default route via BGP router
    aws ec2 create-route \
      --region {{ aws_region }} \
      --route-table-id {{ route_table_id.stdout }} \
      --destination-cidr-block 0.0.0.0/0 \
      --instance-id {{ router_hub_instance.stdout }}
    
    echo "Updated route table {{ route_table_id.stdout }}: 0.0.0.0/0 → $ROUTER_IP ({{ router_hub_instance.stdout }})"
  register: route_update
  changed_when: true

- name: Create separate route table for BGP router to reach Internet
  shell: |
    # Create new route table for BGP router
    RTB_ID=$(aws ec2 create-route-table \
      --region {{ aws_region }} \
      --vpc-id {{ hub_vpc_id }} \
      --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=bgp-router-routes}]' \
      --query 'RouteTable.RouteTableId' \
      --output text)
    
    # Add default route to Internet Gateway
    IGW_ID=$(aws ec2 describe-internet-gateways \
      --region {{ aws_region }} \
      --filters "Name=attachment.vpc-id,Values={{ hub_vpc_id }}" \
      --query 'InternetGateways[0].InternetGatewayId' \
      --output text)
    
    aws ec2 create-route \
      --region {{ aws_region }} \
      --route-table-id $RTB_ID \
      --destination-cidr-block 0.0.0.0/0 \
      --gateway-id $IGW_ID
    
    # Associate with BGP router's subnet (or create separate subnet)
    # Note: This may require creating a separate subnet for the BGP router
    
    echo $RTB_ID
  register: router_route_table
  changed_when: true
  when: false  # Disabled - needs subnet strategy decision
```

### 2. Alternative Approach: Don't Change VPC Route Tables

**SIMPLER OPTION**: Keep VPC routes as-is and add a static route on each OpenShift node:

Add to `roles/bare_metal/tasks/main.yml` or create post-install task:

```yaml
- name: Add static route for CUDN traffic via BGP router
  shell: |
    # Get BGP router IP
    ROUTER_IP=$(aws ec2 describe-instances \
      --region {{ aws_region }} \
      --filters "Name=tag:Name,Values=frr-router-hub" "Name=instance-state-name,Values=running" \
      --query 'Reservations[0].Instances[0].PrivateIpAddress' \
      --output text)
    
    # Add static route to each worker node for CUDN network egress
    oc debug node/{{ item }} -- chroot /host bash -c "
      # Add route for CUDN traffic to use BGP router
      ip route add 8.8.8.8/32 via $ROUTER_IP table 1007 || true
      
      # Or more general: route all non-local traffic from CUDN through BGP router
      # This requires modifying table 1007 default route
    "
  loop: "{{ worker_node_list }}"
```

## Recommendation: VPC Route Table Approach

### Why This Is Better:

1. **Native AWS routing** - uses VPC route tables as designed
2. **Persistent** - survives node reboots, doesn't require DaemonSets
3. **Centralized** - single route table change affects all nodes
4. **Clean** - no fighting with DHCP or kernel routes

### Implementation Steps:

1. **Deploy BGP router** (already done in `roles/router`)
2. **Configure BGP router NAT** - added above
3. **Create separate subnet + route table for BGP router**:
   - BGP router subnet: routes 0.0.0.0/0 → IGW (direct internet)
   - Worker node subnet: routes 0.0.0.0/0 → BGP router instance
4. **BGP peering** (already configured via playbooks/14-bgp-configuration.yml)
5. **CUDN route advertisement** (already configured)

### Traffic Flow:

```
VM internet request:
  192.168.100.3 → 192.168.100.1 (CUDN gateway)
  → Node (table 1007)
  → 10.0.0.1 (VPC router - DHCP default gateway)
  → VPC route table: 0.0.0.0/0 → 10.0.3.190 (BGP router)
  → BGP router NAT
  → BGP router's route table: 0.0.0.0/0 → IGW
  → Internet

VM incoming request from node:
  Node → BGP routes → knows 192.168.100.0/24
  → Node routes via table 1007
  → Delivers to VM
```

## Files That Need Changes

### New Files to Create:
- `playbooks/76-configure-vpc-routing.yml` - VPC route table updates
- `playbooks/77-configure-bgp-router-nat.yml` - NAT configuration

### Files to Modify:
- `roles/router/tasks/main.yml` - Add NAT and routing configuration
- `playbooks/13-frr-routers.yml` - Update to include VPC routing
- `group_vars/all.yml` - Add BGP router subnet configuration variables

## Testing Plan

After implementing changes:

1. Verify BGP router can reach internet
2. Verify OpenShift nodes route through BGP router
3. Verify VM can ping 8.8.8.8
4. Verify return traffic works (curl from VM)
5. Test failover: shutdown BGP router, ensure fallback works

## Rollback Plan

If issues occur:

```bash
# Restore VPC route table to IGW
aws ec2 delete-route --route-table-id <RTB_ID> --destination-cidr-block 0.0.0.0/0
aws ec2 create-route --route-table-id <RTB_ID> --destination-cidr-block 0.0.0.0/0 --gateway-id <IGW_ID>
```

## Current Status

- ✅ BGP router deployed and functional
- ✅ BGP peering established
- ✅ CUDN routes advertised (192.168.100.0/24)
- ✅ BGP router has route to VPC gateway
- ⏸️  VPC route tables NOT updated (manual intervention required)
- ❌ VM cannot reach internet (blocked at VPC routing)

## Next Steps

1. Decide on subnet strategy (separate subnet for BGP router vs shared)
2. Implement VPC route table changes
3. Test VM connectivity
4. Create DaemonSet for route persistence (if not using VPC routes)
