# Documentation Index

## CUDN (Cluster User Defined Network) Documentation

### Quick Start
- **[CUDN Deployment Summary](CUDN_DEPLOYMENT_SUMMARY.md)** - Current deployment status, quick reference, and verification tests

### Deep Dive
- **[CUDN BGP VRF Implementation](cudn-bgp-vrf-implementation.md)** - Complete technical documentation:
  - Problem analysis (RouteAdvertisements bidirectional imports)
  - Architecture diagrams
  - Solution implementation (manual FRRConfiguration)
  - Traffic flow explanations
  - Lessons learned

### Operations
- **[CUDN Operations Guide](cudn-operations-guide.md)** - Day-to-day operations:
  - Status checks
  - Common operations
  - Troubleshooting guides
  - Monitoring commands
  - Configuration backup/restore

## Network Architecture

### BGP Routing
- **[BGP Routing Deployment Changes](bgp-routing-deployment-changes.md)** - BGP configuration evolution
- **[Split Routing Strategy](split-routing-strategy.md)** - Dual-routing architecture details
- **[BGP Router Default Route](bgp-router-default-route.md)** - Default route configuration
- **[BGP Router NAT Configuration](bgp-router-nat-configuration.md)** - NAT and iptables setup

### Multi-VPC Setup
- **[Multi-VPC Setup](multi-vpc-setup.md)** - AWS VPC architecture for hub and managed clusters

## Bare Metal & Agent-Based Installation

- **[Bare Metal BGP Routing Setup](bare-metal-bgp-routing-setup.md)** - BGP configuration for bare metal workers
- **[Bastion SSH Access](bastion-ssh-access.md)** - Bastion host configuration and access

## Architecture Diagrams

- **[Architecture Diagrams](architecture-diagrams.md)** - Complete system architecture (Mermaid diagrams):
  - Overall deployment topology
  - Network flow diagrams
  - Component interactions

## Logical Architecture

- **[Logical Architecture](logical-architecture.md)** - High-level architectural overview

## NMState Reference

- **[NMState Quick Reference](nmstate-quick-reference.md)** - NetworkManager state configuration guide
- **[NMState Lessons Learned](nmstate-lessons-learned.md)** - Best practices and common pitfalls
- **[NMState Dual Interface Example](nmstate-dual-interface-example.yaml)** - Sample YAML configurations

## Configuration Examples

### CUDN Examples
Located in upstream repository: `/Users/mathianasj/git/ovn-kubernetes/`
- `CUDN_SETUP_GUIDE.md` - Upstream comprehensive setup guide
- `CUDN_QUICKSTART_EXAMPLES.yaml` - Complete example YAMLs

### Agent Config Examples
- **[Agent Config Dual Interface Example](agent-config-dual-interface-example.yaml)** - Dual-ENI configuration
- **[Agent Config Dual Interface Clean](agent-config-dual-interface-clean.yaml)** - Minimal dual-ENI config
- **[Agent Config All Static](agent-config-all-static.yaml)** - Static IP configuration

## Current NNCP Review

- **[Current NNCP Review](current-nncp-review.yaml)** - Active NodeNetworkConfigurationPolicy analysis

## Deployment Status

- **[Deployment Status](DEPLOYMENT_STATUS.md)** - Overall deployment progress tracking

---

## Navigation Tips

### I Want To...

**Deploy CUDN from scratch:**
1. Read [CUDN Deployment Summary](CUDN_DEPLOYMENT_SUMMARY.md) for current state
2. Review [CUDN BGP VRF Implementation](cudn-bgp-vrf-implementation.md) for architecture
3. Use ansible playbook: `ansible-playbook playbooks/15-cudn-network.yml`

**Troubleshoot CUDN issues:**
1. Go to [CUDN Operations Guide](cudn-operations-guide.md)
2. Check troubleshooting section for your specific issue
3. Run diagnostic commands from the guide

**Understand BGP routing:**
1. Read [BGP Routing Deployment Changes](bgp-routing-deployment-changes.md)
2. Review [Split Routing Strategy](split-routing-strategy.md)
3. Check [Bare Metal BGP Routing Setup](bare-metal-bgp-routing-setup.md)

**Configure dual-ENI networking:**
1. Review [NMState Quick Reference](nmstate-quick-reference.md)
2. Study examples in [NMState Dual Interface Example](nmstate-dual-interface-example.yaml)
3. Check [NMState Lessons Learned](nmstate-lessons-learned.md) for pitfalls

**Verify deployment status:**
1. Check [CUDN Deployment Summary](CUDN_DEPLOYMENT_SUMMARY.md)
2. Run verification tests from [CUDN Operations Guide](cudn-operations-guide.md)
3. Review [Deployment Status](DEPLOYMENT_STATUS.md) for overall progress

---

## Document Status

| Document | Status | Last Updated |
|----------|--------|--------------|
| CUDN Deployment Summary | ✅ Current | 2026-05-20 |
| CUDN BGP VRF Implementation | ✅ Current | 2026-05-20 |
| CUDN Operations Guide | ✅ Current | 2026-05-20 |
| BGP Routing Deployment Changes | ✅ Current | Recent |
| Split Routing Strategy | ✅ Current | Recent |
| Architecture Diagrams | ✅ Current | Recent |
| NMState Quick Reference | ✅ Current | Recent |

---

**Note:** For the most up-to-date operational status, always check [CUDN Deployment Summary](CUDN_DEPLOYMENT_SUMMARY.md) first.
