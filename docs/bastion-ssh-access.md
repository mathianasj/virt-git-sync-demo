# Bastion SSH Access via VPC Peering

## Overview

The bastion host can directly SSH to all instances in cluster VPCs via VPC peering. This eliminates the need for SSH helper pods and EC2 Instance Connect workarounds that were previously required.

## Network Topology

The deployment uses three separate VPCs with full mesh peering:

- **Bastion VPC**: `10.255.0.0/16` - Hosts the bastion instance
- **Hub Cluster VPC**: `10.0.0.0/16` - Hosts hub OpenShift cluster (peered with bastion)
- **Managed Cluster VPC**: `10.1.0.0/16` - Hosts managed OpenShift cluster (peered with bastion)

VPC peering connections enable private IP connectivity between all VPCs without traversing the public internet.

## Architecture

### Before VPC Peering (Deprecated)

```
Bastion (10.255.x.x)
  ↓ (oc login + kubeconfig)
Kubernetes API
  ↓ (oc exec ssh-helper)
SSH Helper Pod (in cluster)
  ↓ (EC2 Instance Connect 60s window)
  ↓ (ssh to private IP)
Router Instance (10.0.x.x)
```

**Limitations:**
- Required SSH helper pod creation/management
- Dependent on EC2 Instance Connect API (60-second time window)
- SSH keys stored in Kubernetes secrets
- Complex nested SSH chains
- Failed if Kubernetes API unavailable

### After VPC Peering (Current)

```
Bastion (10.255.x.x)
  ↓ (direct SSH via VPC peering)
Router Instance (10.0.x.x)
```

**Benefits:**
- No SSH helper pods required
- No EC2 Instance Connect API dependency
- Direct SSH using bastion key only
- Works even if cluster degraded
- Simpler troubleshooting

## SSH Access Patterns

### Router Instances

Router instances (EC2 VMs running FRRouting) support direct SSH from the bastion:

```bash
# From bastion host
export HUB_ROUTER_IP=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=frr-router-hub" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

export MANAGED_ROUTER_IP=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=frr-router-managed" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

# SSH to hub router
ssh -i ~/.ssh/ocp-bastion-key ec2-user@${HUB_ROUTER_IP}

# SSH to managed router
ssh -i ~/.ssh/ocp-bastion-key ec2-user@${MANAGED_ROUTER_IP}
```

### OpenShift Cluster Nodes

**Important:** OpenShift cluster nodes do NOT support direct SSH. This is a security best practice.

Use `oc debug node/<node-name>` instead:

```bash
# From bastion host
export KUBECONFIG=/home/ec2-user/cluster-hub/auth/kubeconfig

# List nodes
oc get nodes

# Debug a specific node
oc debug node/<node-name>

# Example: Check routing on a worker node
oc debug node/ip-10-0-11-123.ec2.internal -- chroot /host ip route show
```

**Why not direct SSH to cluster nodes?**

1. **Security Best Practice**: OpenShift nodes don't enable SSH by default
2. **Immutable Infrastructure**: Nodes are cattle, not pets
3. **Audit Trail**: Kubernetes API access is logged and RBAC-controlled
4. **No Key Management**: Works with existing cluster credentials
5. **Red Hat Supported**: `oc debug` is the official access method

## Security Groups

Router security groups include the following rules:

### Ingress Rules

```yaml
# Explicit SSH from bastion VPC (for auditing)
- Protocol: TCP
  Port: 22
  Source: 10.255.0.0/16

# All traffic from bastion VPC
- Protocol: All
  Source: 10.255.0.0/16

# All traffic within cluster VPC
- Protocol: All
  Source: 10.0.0.0/16 (hub) or 10.1.0.0/16 (managed)

# SSH from anywhere (emergency access only)
- Protocol: TCP
  Port: 22
  Source: 0.0.0.0/0
```

### Egress Rules

```yaml
# All traffic outbound
- Protocol: All
  Destination: 0.0.0.0/0
```

## SSH Key Management

### Single Key for All Access

The deployment uses a single SSH key pair for all infrastructure access:

- **Key Name**: `ocp-bastion-key`
- **Private Key**: Stored locally at `~/.ssh/ocp-bastion-key`
- **Public Key**: Registered in AWS EC2 key pairs
- **Used For**: Bastion host, router instances

No separate router keys are needed with VPC peering.

### Key Location

On your local machine:
```bash
~/.ssh/ocp-bastion-key        # Private key (keep secure)
~/.ssh/ocp-bastion-key.pub    # Public key
```

On bastion host:
```bash
~/.ssh/ocp-bastion-key        # Copied during deployment (used for router access)
~/.ssh/openshift-key          # Separate key for OpenShift installation
~/.ssh/openshift-key.pub
```

## Connectivity Verification

### Test VPC Peering

From your local machine:

```bash
# Get bastion public IP
BASTION_IP=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Role,Values=bastion" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

# SSH to bastion
ssh -i ~/.ssh/ocp-bastion-key ec2-user@${BASTION_IP}
```

From bastion host:

```bash
# Get router IPs
HUB_ROUTER_IP=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=frr-router-hub" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

MANAGED_ROUTER_IP=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=frr-router-managed" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

# Test ICMP connectivity
ping -c 3 ${HUB_ROUTER_IP}
ping -c 3 ${MANAGED_ROUTER_IP}

# Test SSH connectivity
ssh -i ~/.ssh/ocp-bastion-key ec2-user@${HUB_ROUTER_IP} "hostname"
ssh -i ~/.ssh/ocp-bastion-key ec2-user@${MANAGED_ROUTER_IP} "hostname"

# Test BGP status
ssh -i ~/.ssh/ocp-bastion-key ec2-user@${HUB_ROUTER_IP} "sudo vtysh -c 'show bgp summary'"
ssh -i ~/.ssh/ocp-bastion-key ec2-user@${MANAGED_ROUTER_IP} "sudo vtysh -c 'show bgp summary'"
```

### Verify Security Groups

```bash
# Check router security groups allow SSH from bastion VPC
aws ec2 describe-security-groups \
  --region us-east-1 \
  --filters "Name=tag:Router,Values=frr" \
  --query 'SecurityGroups[*].[GroupName,IpPermissions[?FromPort==`22`]]' \
  --output table
```

Should show ingress rules from `10.255.0.0/16` (bastion VPC CIDR).

## Ansible Playbook Integration

### Direct SSH Task File

Router role provides a reusable direct SSH task:

**File**: `roles/router/tasks/direct_ssh.yml`

```yaml
---
# Execute command on router via direct SSH from bastion
# Variables:
#   - router_private_ip: Router's private IP address
#   - router_command: Command to execute

- name: Execute command on router via direct SSH
  shell: |
    ssh -i ~/.ssh/{{ bastion_key_name }} \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        {{ router_user | default('ec2-user') }}@{{ router_private_ip }} "{{ router_command }}"
  register: router_ssh_result
  changed_when: false
```

### Usage Example

```yaml
- name: Check router NAT configuration
  include_tasks: roles/router/tasks/direct_ssh.yml
  vars:
    router_private_ip: "{{ hub_router_ip }}"
    router_command: |
      sysctl -n net.ipv4.ip_forward
      sudo iptables -t nat -L POSTROUTING -n

- name: Display router output
  debug:
    var: router_ssh_result.stdout_lines
```

## Troubleshooting

### Cannot Ping Router from Bastion

**Check VPC peering status:**

```bash
aws ec2 describe-vpc-peering-connections \
  --region us-east-1 \
  --filters "Name=status-code,Values=active" \
  --output table
```

**Check route tables:**

```bash
# Get bastion VPC ID
BASTION_VPC_ID=$(aws ec2 describe-vpcs \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=bastion-vpc" \
  --query 'Vpcs[0].VpcId' \
  --output text)

# Check routes to cluster VPCs
aws ec2 describe-route-tables \
  --region us-east-1 \
  --filters "Name=vpc-id,Values=${BASTION_VPC_ID}" \
  --query 'RouteTables[*].Routes[?DestinationCidrBlock==`10.0.0.0/16` || DestinationCidrBlock==`10.1.0.0/16`]' \
  --output table
```

Should show routes via VPC peering connections.

### Cannot SSH to Router

**Verify security group rules:**

```bash
aws ec2 describe-security-groups \
  --region us-east-1 \
  --filters "Name=group-name,Values=frr-router-hub-sg" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`]' \
  --output json
```

**Test with verbose SSH:**

```bash
ssh -v -i ~/.ssh/ocp-bastion-key ec2-user@${HUB_ROUTER_IP}
```

**Check instance is running:**

```bash
aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=frr-router-hub" \
  --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PrivateIpAddress]' \
  --output table
```

### SSH Key Permission Denied

**Ensure correct key permissions:**

```bash
chmod 600 ~/.ssh/ocp-bastion-key
```

**Verify key is registered in AWS:**

```bash
aws ec2 describe-key-pairs \
  --region us-east-1 \
  --key-names ocp-bastion-key \
  --output table
```

## Emergency Access

### EC2 Instance Connect (Backup Method)

If VPC peering is broken or bastion is unavailable, use EC2 Instance Connect:

```bash
# From local machine with AWS CLI
HUB_ROUTER_ID=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=frr-router-hub" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# Generate temporary SSH key
ssh-keygen -t rsa -f /tmp/temp-key -N ""

# Send public key (valid for 60 seconds)
aws ec2-instance-connect send-ssh-public-key \
  --region us-east-1 \
  --instance-id ${HUB_ROUTER_ID} \
  --instance-os-user ec2-user \
  --ssh-public-key file:///tmp/temp-key.pub

# SSH within 60 seconds
HUB_ROUTER_IP=$(aws ec2 describe-instances \
  --region us-east-1 \
  --instance-ids ${HUB_ROUTER_ID} \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

ssh -i /tmp/temp-key ec2-user@${HUB_ROUTER_IP}
```

**Note**: This requires direct network access to the router's private IP, which may not work without VPC peering.

### AWS Systems Manager Session Manager (Alternative)

If SSH is completely unavailable, use SSM Session Manager (requires SSM agent installed on instances).

## Best Practices

1. **Always use bastion as jump host** - Never expose cluster nodes directly to internet
2. **Keep bastion SSH key secure** - Store private key with appropriate permissions (600)
3. **Use oc debug for cluster nodes** - Don't enable SSH on OpenShift nodes
4. **Audit SSH access** - Review CloudTrail logs for bastion access
5. **Rotate keys regularly** - Update SSH keys according to security policy
6. **Test VPC peering** - Verify connectivity after infrastructure changes
7. **Document IP ranges** - Keep CIDR documentation up to date

## Related Documentation

- [Multi-VPC Setup](multi-vpc-setup.md) - VPC architecture and peering configuration
- [BGP Router Default Route](bgp-router-default-route.md) - Router NAT and routing configuration
- [OpenShift Installation](../README.md) - Full deployment guide
