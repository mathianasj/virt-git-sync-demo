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

### Key Features

- **Resilient Installation**: Uses tmux sessions on bastion to survive connection loss
- **Idempotent**: Can be re-run safely without duplicating resources
- **Modular Design**: 9 phase playbooks and 8 reusable roles
- **Production-Ready**: Proper error handling, logging, and state tracking

## Quick Start

```bash
# Install prerequisites
ansible-galaxy collection install amazon.aws kubernetes.core community.general
pip3 install boto3 botocore kubernetes

# Configure AWS credentials
export AWS_ACCESS_KEY_ID="your-key"
export AWS_SECRET_ACCESS_KEY="your-secret"
export AWS_DEFAULT_REGION="us-east-1"

# Run deployment
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

## Directory Structure

```
.
├── playbooks/
│   ├── site.yml                      # Main orchestration playbook
│   ├── 01-prerequisites.yml          # Verify prerequisites
│   ├── 02-infrastructure.yml         # AWS resources
│   ├── 03-bastion-setup.yml          # Bastion configuration
│   ├── 04-openshift-install.yml      # OpenShift installation
│   ├── 05-acm-setup.yml              # ACM installation
│   ├── 06-import-cluster.yml         # Cluster import
│   ├── 07-bare-metal-machinesets.yml # Bare metal nodes
│   ├── 08-virtualization-policy.yml  # OpenShift Virtualization
│   └── 09-gitea-deployment.yml       # Gitea deployment
├── roles/
│   ├── aws_infrastructure/           # VPC, subnets, bastion
│   ├── bastion/                      # Bastion setup
│   ├── openshift_installer/          # Tmux-based installation
│   ├── acm/                          # ACM operator
│   ├── import_cluster/               # Cluster import
│   ├── bare_metal/                   # Machineset creation
│   ├── cnv_policy/                   # CNV policy
│   └── gitea/                        # Gitea Helm
├── group_vars/
│   └── all.yml                       # Global variables
├── inventory/
│   └── hosts.yml                     # Inventory
├── USAGE.md                          # Detailed usage guide
└── ansible.cfg                       # Ansible configuration
```

## Prerequisites

- Ansible 2.9+
- Python 3.6+ with boto3, botocore, kubernetes
- AWS credentials with appropriate permissions
- OpenShift pull secret from Red Hat

## Configuration

Key variables in `group_vars/all.yml`:
- `aws_region`: AWS region (default: us-east-1)
- `openshift_version`: OpenShift version (default: 4.20)
- `clusters`: Cluster definitions (names, domains, instance types)
- `bare_metal_instance_type`: Metal instance type (default: c5.metal)

## Deployment Timeline

- AWS infrastructure: ~10 minutes
- Bastion setup: ~5 minutes
- OpenShift clusters: ~60-90 minutes (parallel)
- ACM setup: ~15 minutes
- Cluster import: ~5 minutes
- Bare metal nodes: ~20 minutes
- OpenShift Virtualization: ~15 minutes
- Gitea: ~5 minutes

**Total: ~2-3 hours**

## Resilience

The playbook uses tmux sessions on the bastion for OpenShift installations:
- If Ansible connection is lost, simply re-run the playbook
- It will automatically reattach to existing tmux sessions
- Installation continues from where it left off

## License

This project is provided as-is for educational and demonstration purposes.

## See Also

- [USAGE.md](USAGE.md) - Detailed usage instructions and troubleshooting
- [OpenShift Documentation](https://docs.openshift.com/)
- [ACM Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/)
- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
