# Dual OpenShift Cluster Deployment with ACM

Comprehensive Ansible playbooks for deploying two OpenShift 4.20 clusters on AWS with Advanced Cluster Management (ACM), OpenShift Virtualization, and Gitea.

## Overview

This project automates the complete deployment of:
- **Two OpenShift 4.20 clusters** on AWS (IPI installation)
- **Advanced Cluster Management (ACM)** on hub cluster
- **Managed cluster import** into ACM
- **Bare metal workers** (c5.metal) for both clusters via day 2 machinesets
- **OpenShift Virtualization** deployed via ACM policy to both clusters
- **Gitea** git server on hub cluster via Helm
- **OpenShift GitOps (ArgoCD)** for continuous delivery and multi-cluster GitOps
- **cert-manager** with Let's Encrypt certificates for both clusters
- **virt-git-sync** operator with ArgoCD integration for bidirectional GitOps VM lifecycle management
- **OpenShift Data Foundation** (Ceph storage) for persistent storage
- **AWS VPC Route Server** - Native AWS dynamic BGP routing (2026 feature) with:
  - Direct BGP peering from OpenShift workers to Route Server
  - Automatic VPC route table updates for VM networks
  - ECMP multipath routing support
  - Deployed in hub, managed, and bastion VPCs
- **AWS Transit Gateway** - Cross-VPC routing with dynamic BGP:
  - **Transit Gateway Connect** attachments with GRE tunnels
  - **BGP peering** between TGW and Route Servers in each VPC
  - **Dynamic route learning** - same CUDN prefix from both clusters
  - **Automatic failover** based on BGP path selection
  - Enables bastion access to VMs with active-active or failover scenarios
- **VM networks (CUDN)** - Layer2 ClusterUserDefinedNetwork with **GitOps management and shared CIDR for failover**:
  - **GitOps managed:** CUDN configuration in Git, synced via ArgoCD
  - **Shared network:** 192.168.100.0/24 (advertised by both hub and managed clusters)
  - Both clusters advertise the same prefix to their Route Servers
  - Transit Gateway learns from both and selects best path dynamically
  - Internet egress for KubeVirt VMs via OVN overlay
  - BGP route advertisements via VPC Route Server
  - VRF isolation (bgp-control, cudn-net) for traffic separation
- **EC2 FRR routers** - BGP hub with GRE tunnels to Transit Gateway:
  - Acts as route reflector between OpenShift workers, Route Server, and Transit Gateway
  - Provides GRE tunnel connectivity for bastion-to-VM routing via TGW
  - Three BGP sessions per router: iBGP (OpenShift), eBGP (Route Server), eBGP (TGW)
  - Fully automated deployment and configuration

### Key Features

- **Automatic Route53 Discovery**: Detects and uses existing Route53 hosted zones
- **Resilient Installation**: Uses tmux sessions on bastion to survive connection loss
- **Idempotent**: Can be re-run safely without duplicating resources
- **Modular Design**: 15 phase playbooks and 13 reusable roles
- **Production-Ready**: Proper error handling, logging, and state tracking
- **Complete Documentation**: Architecture diagrams, usage guides, and troubleshooting docs

## Quick Start

```bash
# 1. Setup Python virtual environment and install dependencies
./setup.sh

# 2. Activate virtual environment
source venv/bin/activate

# 3. Download OpenShift pull secret
# Get it from: https://console.redhat.com/openshift/install/pull-secret
# Save as: pull-secret.json

# 4. Configure AWS credentials
export AWS_ACCESS_KEY_ID="your-key"
export AWS_SECRET_ACCESS_KEY="your-secret"
export AWS_DEFAULT_REGION="us-east-1"

# 5. Run deployment
ansible-playbook -i inventory/hosts.yml playbooks/site.yml
```

See [USAGE.md](USAGE.md) for detailed instructions.

### Validate CUDN GitOps Deployment

To validate the GitOps approach, see [CUDN_GITOPS_VALIDATION.md](CUDN_GITOPS_VALIDATION.md) for step-by-step commands to:
- Clean up existing CUDN resources
- Deploy via GitOps (run playbook 15)
- Verify ArgoCD Applications and Git repository
- Test GitOps workflow (modify via Git, self-healing)

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Transit Gateway (ASN 64515)                     │
│              Dynamic BGP Route Learning & Failover                   │
│                                                                       │
│  Learns 192.168.100.0/24 from both clusters via Route Servers       │
│  Automatic failover based on BGP path selection                     │
└─────────────────────────────────────────────────────────────────────┘
         │                         │                         │
         │                         │                         │
    ┌────▼────┐              ┌─────▼─────┐           ┌──────▼──────┐
    │ Hub VPC │              │ Mgd VPC   │           │ Bastion VPC │
    │ Route   │──BGP─┐       │ Route     │──BGP─┐    │ Route       │
    │ Server  │      │       │ Server    │      │    │ Server      │
    │ 64514   │      │       │ 64517     │      │    │ 64516       │
    └─────────┘      │       └───────────┘      │    └─────────────┘
         │           │            │              │          │
         │           │            │              │          │
    ┌────▼────────────▼───┐  ┌───▼──────────────▼──┐  ┌───▼─────────┐
    │   Hub Cluster       │  │ Managed Cluster     │  │  Bastion    │
    │   (OpenShift)       │  │  (OpenShift)        │  │  (RHEL 9)   │
    │                     │  │                     │  │             │
    │  - ACM              │  │  - Imported         │  │ - oc/helm   │
    │  - Gitea            │  │  - CNV              │  │ - tmux      │
    │  - CNV              │  │  - 2x c5.metal      │  └─────────────┘
    │  - 2x c5.metal      │  │                     │  ┌─────────────┐
    │                     │  │  Advertises:        │  │  Windows    │
    │  Advertises:        │  │  192.168.100.0/24   │  │  (Testing)  │
    │  192.168.100.0/24   │  │  to Route Server    │  │             │
    │  to Route Server    │  │                     │  │ - RDP       │
    └─────────────────────┘  └─────────────────────┘  │ - Failover  │
                                                       │   Testing   │
                                                       └─────────────┘

Shared VM Network: 192.168.100.0/24 (advertised by both clusters)
Dynamic Failover: Transit Gateway learns best path via BGP
Zero Downtime: Automatic rerouting when one cluster fails
```

## Deployment Phases

The deployment is organized into 20 sequential phases:

| Phase | Playbook | Description | Time |
|-------|----------|-------------|------|
| 01 | `01-prerequisites.yml` | Verify AWS quotas, credentials, and dependencies | 5 min |
| 02 | `02-infrastructure.yml` | Create VPCs, subnets, bastion, NAT gateways, peering | 10 min |
| 03 | `03-bastion-setup.yml` | Configure bastion with tools (oc, helm, openshift-install) | 5 min |
| 04 | `04-openshift-install.yml` | Install hub & managed clusters in tmux (parallel) | 60-90 min |
| 05 | `05-acm-setup.yml` | Deploy Advanced Cluster Management on hub | 15 min |
| 06 | `06-import-cluster.yml` | Import managed cluster into ACM | 5 min |
| 07 | `07-frr-routers.yml` | Deploy EC2 FRR routers (BGP hub for TGW connectivity) | 5-10 min |
| 08 | `08-bare-metal-machinesets.yml` | Deploy c5.metal nodes to both clusters | 20-30 min |
| 09 | `09-odf-setup.yml` | Deploy OpenShift Data Foundation (Ceph storage) | 20-30 min |
| 10 | `10-virtualization-policy.yml` | Deploy OpenShift Virtualization via ACM policy | 5-10 min |
| 11 | `11-gitea-deployment.yml` | Deploy Gitea Git server via Helm on hub | 5-10 min |
| 11a | `11a-openshift-gitops.yml` | Install OpenShift GitOps (ArgoCD) on hub cluster | 5-8 min |
| 12 | `12-cert-manager-setup.yml` | Install cert-manager & Let's Encrypt certificates | 10-15 min |
| 13 | `13-virt-git-sync-setup.yml` | Deploy virt-git-sync operator for GitOps VMs | 5 min |
| 14 | `14-bgp-configuration.yml` | Configure BGP sessions & worker routing | 10-15 min |
| 15 | `15-cudn-network.yml` | Create VM network (CUDN) with bridge & NAD | 5-10 min |
| 15a-15c | `15a-c-cudn-*.yml` | Placeholder playbooks (functionality in phases 14-15) | 0 min |
| 16 | `16-transit-gateway-setup.yml` | Create Transit Gateway for cross-VPC routing | 5-10 min |
| 07a | `07a-ec2-router-bgp-config.yml` | Configure EC2 router GRE tunnels and BGP sessions | 5-10 min |
| 17 | `17-route-server-setup.yml` | Deploy VPC Route Servers for dynamic BGP | 5-10 min |
| 18 | `18-route-server-bgp.yml` | Configure TGW Connect & worker BGP peering | 10-15 min |
| 19 | `19-windows-instance.yml` | Deploy Windows instance for failover testing | 10-15 min |

**Total Time: ~2.5-4 hours**

### Phase Details

- **Phases 01-03**: Infrastructure setup (AWS resources, bastion configuration)
- **Phase 04**: Core OpenShift installation (longest phase, runs in tmux for resilience)
- **Phases 05-06**: ACM setup and cluster management
- **Phase 07**: EC2 FRR routers deployment (BGP hub for Transit Gateway connectivity)
- **Phases 08-09**: Bare metal nodes and persistent storage (ODF)
- **Phases 10-13**: OpenShift Virtualization, GitOps (ArgoCD), and automation tooling
- **Phases 14-15**: BGP configuration and VM network (CUDN)
- **Phase 16**: Transit Gateway with VPC attachments and TGW Connect peers
- **Phase 07a**: EC2 router GRE tunnels and BGP configuration (requires TGW Connect IPs)
- **Phase 17**: VPC Route Servers in all three VPCs for native AWS routing
- **Phase 18**: TGW Connect BGP peering and worker Route Server configuration
- **Phase 19**: Windows instance in bastion VPC for failover testing

### Hybrid Routing Architecture

This deployment uses a **hybrid routing architecture** where EC2 routers and VPC Route Servers work together:

- **EC2 FRR Routers**: Act as BGP hub/route reflector with three sessions:
  - iBGP with OpenShift worker nodes (receive CUDN routes)
  - eBGP with VPC Route Server (advertise CUDN routes)
  - eBGP with Transit Gateway via GRE tunnel (advertise CUDN routes for bastion access)
  
- **VPC Route Servers**: Provide native AWS dynamic BGP routing:
  - Automatically update VPC route tables based on BGP advertisements
  - Enable ECMP multipath routing support
  - Deployed in hub, managed, and bastion VPCs

- **Transit Gateway**: Enables cross-VPC connectivity:
  - Connects bastion VPC to cluster VPCs for VM access
  - Learns CUDN routes from both clusters via EC2 routers
  - Provides automatic failover based on BGP path selection

### BGP Router NAT Configuration with Split Routing

When `router_nat_enabled: true` (default), BGP routers are configured with dual network interfaces and the deployment uses a **split routing strategy** to ensure both worker and control plane nodes have proper connectivity:

**Architecture**:
- **Primary ENI (ens5)**: Located in worker subnet (10.X.11.0/24), used for BGP peering
- **Secondary ENI (ens6)**: Located in public subnet (10.X.1.0/24), connected to NAT gateway

**Split Routing Strategy**:
- **Worker subnet** (10.X.11.0/24, us-east-1a): Routes internet traffic through BGP router for VM networking
- **Control plane subnets** (10.X.12.0/24, 10.X.13.0/24): Route internet traffic directly to NAT Gateway
- This ensures control plane nodes can reach cluster routes (OAuth, console) while workers use BGP

**Traffic Flows**:
- Worker: `Worker Node → BGP Router → NAT Gateway → Internet`
- Control Plane: `Control Plane Node → NAT Gateway → Internet`
- VM Network: `All Nodes → BGP Router → Worker Nodes → VMs`

**Key Features**:
- iptables MASQUERADE on ens6 for outbound NAT
- systemd service removes DHCP routes and sets static default via NAT gateway
- Separate route tables per subnet for control plane vs. worker routing
- Configuration persists across reboots via iptables-services and systemd
- Ensures cluster operators (authentication, console, ingress) remain healthy

See [docs/bgp-router-nat-configuration.md](docs/bgp-router-nat-configuration.md) and [docs/split-routing-strategy.md](docs/split-routing-strategy.md) for detailed documentation.

## Directory Structure

```
.
├── playbooks/
│   ├── site.yml                      # Main orchestration (runs all phases)
│   ├── 01-prerequisites.yml          # AWS quotas & dependencies
│   ├── 02-infrastructure.yml         # VPCs, subnets, bastion
│   ├── 03-bastion-setup.yml          # Bastion tools & configuration
│   ├── 04-openshift-install.yml      # OpenShift IPI installation
│   ├── 05-acm-setup.yml              # ACM operator & MultiClusterHub
│   ├── 06-import-cluster.yml         # Import managed cluster
│   ├── 13-frr-routers.yml            # FRRouting EC2 deployment (runs before bare metal)
│   ├── 07-bare-metal-machinesets.yml # c5.metal machineset creation
│   ├── 08-virtualization-policy.yml  # OpenShift Virtualization
│   ├── 09-gitea-deployment.yml       # Gitea Helm deployment
│   ├── 10-cert-manager-setup.yml     # Let's Encrypt certificates
│   ├── 11-virt-git-sync-setup.yml    # VM GitOps operator
│   ├── 12-odf-setup.yml              # OpenShift Data Foundation
│   ├── 14-bgp-configuration.yml      # BGP session setup & worker routing
│   ├── 15-cudn-network.yml           # VM network creation
│   └── 99-destroy-clusters.yml       # Cleanup (openshift-install destroy)
├── roles/
│   ├── aws_infrastructure/           # VPC, subnets, bastion, peering
│   ├── bastion/                      # Bastion setup & workspace
│   ├── openshift_installer/          # Tmux-based installation
│   ├── acm/                          # ACM operator deployment
│   ├── import_cluster/               # Cluster import automation
│   ├── bare_metal/                   # Machineset creation
│   ├── cnv_policy/                   # CNV ACM policy
│   ├── gitea/                        # Gitea Helm deployment
│   ├── cert_manager/                 # cert-manager & Let's Encrypt
│   ├── virt_git_sync/                # virt-git-sync operator
│   ├── odf/                          # ODF storage deployment
│   ├── router/                       # FRR router deployment
│   ├── ovn_bgp/                      # BGP configuration
│   └── cudn/                         # VM network setup
├── docs/
│   ├── architecture-diagrams.md      # Mermaid architecture diagrams
│   └── *.md                          # Additional documentation
├── group_vars/
│   └── all.yml                       # Global variables
├── inventory/
│   └── hosts.yml                     # Inventory configuration
├── USAGE.md                          # Detailed usage guide
└── ansible.cfg                       # Ansible configuration
```

## Prerequisites

- Python 3.6+
- AWS credentials with appropriate permissions
- **Route53 public hosted zone** (playbook auto-discovers from your AWS account)
- OpenShift pull secret from Red Hat
- **AWS Quotas**: Elastic IPs (15+), EC2 instances - See [AWS_QUOTAS.md](AWS_QUOTAS.md)

**Note:** Run `./setup.sh` to automatically create a Python virtual environment and install all required dependencies (Ansible, boto3, kubernetes, etc.)

**Important:** Two OpenShift clusters in one region require increased AWS quotas. The playbook **automatically checks quotas and can request increases for you**, waiting for approval before proceeding. See [AWS_QUOTAS.md](AWS_QUOTAS.md) for details.

## Configuration

Key variables in `group_vars/all.yml`:
- `aws_region`: AWS region (default: us-east-1)
- `openshift_version`: OpenShift version (default: 4.20)
- `clusters`: Cluster definitions (names, domains, instance types)
- `bare_metal_instance_type`: Metal instance type (default: c5.metal)

## Monitoring Progress

The deployment creates detailed logs and state tracking:

- **Installation logs**: Stored on bastion in each cluster's `install_dir`
- **Tmux sessions**: OpenShift installations run in background sessions
  ```bash
  ssh -i ~/.ssh/ocp-bastion-key ec2-user@<bastion-ip>
  tmux attach -t hub-install      # Attach to hub installation
  tmux attach -t managed-install  # Attach to managed installation
  ```
- **Architecture diagrams**: See `docs/architecture-diagrams.md` for complete visual documentation

## Cleanup

To destroy the OpenShift clusters (keeps VPCs and bastion):
```bash
ansible-playbook playbooks/99-destroy-clusters.yml
```

To remove all AWS resources including VPCs:
```bash
ansible-playbook playbooks/cleanup-all-aws-resources.yml
```

## Resilience

The playbook uses tmux sessions on the bastion for OpenShift installations:
- If Ansible connection is lost, simply re-run the playbook
- It will automatically reattach to existing tmux sessions
- Installation continues from where it left off

## License

This project is provided as-is for educational and demonstration purposes.

## See Also

### Project Documentation

- [docs/architecture-diagrams.md](docs/architecture-diagrams.md) - Complete architecture diagrams (mermaid)
- [USAGE.md](USAGE.md) - Detailed usage instructions and troubleshooting

### CUDN & BGP Networking Documentation

- [docs/CUDN_DEPLOYMENT_SUMMARY.md](docs/CUDN_DEPLOYMENT_SUMMARY.md) - CUDN deployment status and quick reference
- [docs/cudn-bgp-vrf-implementation.md](docs/cudn-bgp-vrf-implementation.md) - Technical deep dive: CUDN with BGP and VRF
- [docs/cudn-operations-guide.md](docs/cudn-operations-guide.md) - Operations guide and troubleshooting for CUDN
- [docs/bgp-routing-deployment-changes.md](docs/bgp-routing-deployment-changes.md) - BGP routing configuration changes
- [docs/split-routing-strategy.md](docs/split-routing-strategy.md) - Split routing implementation details

### External Documentation

- [OpenShift Documentation](https://docs.openshift.com/)
- [ACM Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/)
- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
