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
- **cert-manager** with Let's Encrypt certificates for both clusters
- **virt-git-sync** operator for GitOps-based VM management
- **OpenShift Data Foundation** (Ceph storage) for persistent storage
- **FRRouting (FRR)** routers with BGP for advanced networking
- **VM networks (CUDN)** with bridge networking and BGP route advertisement

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

## Architecture

```
┌─────────────────┐         ┌─────────────────┐
│   Hub Cluster   │         │ Managed Cluster │
│  (OpenShift)    │◄────────┤  (OpenShift)    │
│                 │   ACM   │                 │
│  - ACM          │         │  - Imported     │
│  - Gitea        │         │                 │
│  - CNV          │         │  - CNV          │
│  - 2x c5.metal  │         │  - 2x c5.metal  │
└─────────────────┘         └─────────────────┘
        │
        │ AWS Infrastructure
        ▼
  ┌──────────────┐
  │   Bastion    │
  │  (RHEL 9)    │
  │              │
  │ - tmux       │
  │ - oc         │
  │ - helm       │
  └──────────────┘
```

## Deployment Phases

The deployment is organized into 15 sequential phases:

| Phase | Playbook | Description | Time |
|-------|----------|-------------|------|
| 01 | `01-prerequisites.yml` | Verify AWS quotas, credentials, and dependencies | 5 min |
| 02 | `02-infrastructure.yml` | Create VPCs, subnets, bastion, NAT gateways, peering | 10 min |
| 03 | `03-bastion-setup.yml` | Configure bastion with tools (oc, helm, openshift-install) | 5 min |
| 04 | `04-openshift-install.yml` | Install hub & managed clusters in tmux (parallel) | 60-90 min |
| 05 | `05-acm-setup.yml` | Deploy Advanced Cluster Management on hub | 15 min |
| 06 | `06-import-cluster.yml` | Import managed cluster into ACM | 5 min |
| 07 | `07-bare-metal-machinesets.yml` | Deploy c5.metal nodes to both clusters | 20-30 min |
| 08 | `08-virtualization-policy.yml` | Deploy OpenShift Virtualization via ACM policy | 5-10 min |
| 09 | `09-gitea-deployment.yml` | Deploy Gitea Git server via Helm on hub | 5-10 min |
| 10 | `10-cert-manager-setup.yml` | Install cert-manager & Let's Encrypt certificates | 10-15 min |
| 11 | `11-virt-git-sync-setup.yml` | Deploy virt-git-sync operator for GitOps VMs | 5 min |
| 12 | `12-odf-setup.yml` | Deploy OpenShift Data Foundation (Ceph storage) | 20-30 min |
| 13 | `13-frr-routers.yml` | Deploy FRRouting EC2 instances for BGP | 5-10 min |
| 14 | `14-bgp-configuration.yml` | Configure BGP sessions between routers & nodes | 10 min |
| 14c | `14c-worker-bgp-routing.yml` | Configure BGP routing on worker nodes | 5 min |
| 15 | `15-cudn-network.yml` | Create VM network (CUDN) with bridge & NAD | 5-10 min |

**Total Time: ~2.5-3.5 hours**

### Phase Details

- **Phases 01-03**: Infrastructure setup (AWS resources, bastion configuration)
- **Phase 04**: Core OpenShift installation (longest phase, runs in tmux for resilience)
- **Phases 05-06**: ACM setup and cluster management
- **Phases 07-08**: Bare metal nodes and virtualization platform
- **Phases 09-11**: GitOps tooling (Gitea, cert-manager, virt-git-sync)
- **Phase 12**: Persistent storage (OpenShift Data Foundation)
- **Phases 13-15**: Advanced networking (BGP routing, VM networks)

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
│   ├── 07-bare-metal-machinesets.yml # c5.metal machineset creation
│   ├── 08-virtualization-policy.yml  # OpenShift Virtualization
│   ├── 09-gitea-deployment.yml       # Gitea Helm deployment
│   ├── 10-cert-manager-setup.yml     # Let's Encrypt certificates
│   ├── 11-virt-git-sync-setup.yml    # VM GitOps operator
│   ├── 12-odf-setup.yml              # OpenShift Data Foundation
│   ├── 13-frr-routers.yml            # FRRouting EC2 deployment
│   ├── 14-bgp-configuration.yml      # BGP session setup
│   ├── 14c-worker-bgp-routing.yml    # Worker BGP routes
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

- [docs/architecture-diagrams.md](docs/architecture-diagrams.md) - Complete architecture diagrams (mermaid)
- [USAGE.md](USAGE.md) - Detailed usage instructions and troubleshooting
- [OpenShift Documentation](https://docs.openshift.com/)
- [ACM Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/)
- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
