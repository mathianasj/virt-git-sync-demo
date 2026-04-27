# Dual OpenShift Cluster Deployment - Usage Guide

This guide explains how to use the Ansible playbooks to deploy two OpenShift 4.20 clusters on AWS with ACM, OpenShift Virtualization, and Gitea.

## Prerequisites

### Local Machine Requirements

1. **Python 3.6+** installed
   ```bash
   python3 --version
   ```

2. **Setup virtual environment and dependencies** (recommended)
   ```bash
   # Run the setup script (creates venv and installs everything)
   ./setup.sh
   
   # Activate the virtual environment
   source venv/bin/activate
   
   # Or use the helper script
   source activate
   ```

   **Alternative: Manual installation** (if not using venv)
   ```bash
   pip3 install -r requirements.txt
   ansible-galaxy collection install amazon.aws kubernetes.core community.general
   ```

3. **AWS credentials** configured
   ```bash
   export AWS_ACCESS_KEY_ID="your-access-key"
   export AWS_SECRET_ACCESS_KEY="your-secret-key"
   export AWS_DEFAULT_REGION="us-east-1"
   ```

4. **OpenShift pull secret** saved to a file
   ```bash
   # Download from: https://console.redhat.com/openshift/install/pull-secret
   # Save it as pull-secret.json in the project directory
   
   # The playbook will prompt for the file path (default: ./pull-secret.json)
   ```

### Verify Installation

```bash
# Activate venv if using it
source venv/bin/activate

# Check versions
ansible --version
python -c "import boto3; print('boto3:', boto3.__version__)"
python -c "import kubernetes; print('kubernetes:', kubernetes.__version__)"
```

### Configuration

Before running, review and customize these files:

1. **group_vars/all.yml** - Adjust cluster names, instance types, etc.
   - Adjust instance types if needed
   - Modify network CIDRs if conflicts exist
   - Update bastion_ami if not using us-east-1

**Note:** The playbook will automatically discover and use your Route53 hosted zones. You don't need to configure the domain manually - it will be detected from AWS Route53.

## Running the Deployment

### Full Deployment

Deploy everything with a single command:

```bash
# First, save your pull secret to a file
# Download from: https://console.redhat.com/openshift/install/pull-secret
# Save as: pull-secret.json (in project directory)

# Run the deployment
ansible-playbook -i inventory/hosts.yml playbooks/site.yml
```

You will be prompted for the path to your pull secret file (default: `./pull-secret.json`).

**Note:** An example format is provided in `pull-secret.json.example` for reference.

### Phase-by-Phase Deployment

You can run individual phases for troubleshooting or partial deployment:

```bash
# Phase 1: Prerequisites check
ansible-playbook -i inventory/hosts.yml playbooks/01-prerequisites.yml

# Phase 2: AWS infrastructure
ansible-playbook -i inventory/hosts.yml playbooks/02-infrastructure.yml

# Phase 3: Bastion setup
ansible-playbook -i inventory/hosts.yml playbooks/03-bastion-setup.yml

# Phase 4: OpenShift installation (longest phase ~60-90 min)
ansible-playbook -i inventory/hosts.yml playbooks/04-openshift-install.yml

# Phase 5: ACM installation
ansible-playbook -i inventory/hosts.yml playbooks/05-acm-setup.yml

# Phase 6: Import managed cluster
ansible-playbook -i inventory/hosts.yml playbooks/06-import-cluster.yml

# Phase 7: Bare metal machinesets
ansible-playbook -i inventory/hosts.yml playbooks/07-bare-metal-machinesets.yml

# Phase 8: OpenShift Virtualization
ansible-playbook -i inventory/hosts.yml playbooks/08-virtualization-policy.yml

# Phase 9: Gitea deployment
ansible-playbook -i inventory/hosts.yml playbooks/09-gitea-deployment.yml
```

## Resilience and Recovery

### Tmux Session Management

The playbook uses tmux sessions on the bastion for resilient OpenShift installations:

- **Hub cluster**: tmux session `hub-install`
- **Managed cluster**: tmux session `managed-install`

### If Connectivity is Lost

If your Ansible playbook is interrupted:

1. **Re-run the playbook** - it will automatically detect and reattach to existing tmux sessions
   ```bash
   ansible-playbook -i inventory/hosts.yml playbooks/site.yml
   ```

2. **Manual check** - SSH to bastion and check tmux sessions
   ```bash
   ssh -i ~/.ssh/ocp-bastion-key ec2-user@<bastion-ip>
   tmux ls
   tmux attach -t hub-install
   ```

### Idempotency

The playbooks are designed to be idempotent:
- Re-running will not duplicate resources
- Existing clusters are detected and installation is skipped
- AWS resources are checked before creation

## Monitoring Progress

### From Local Machine

Watch the Ansible output for progress through phases.

### From Bastion

SSH to the bastion to check installation logs:

```bash
ssh -i ~/.ssh/ocp-bastion-key ec2-user@<bastion-ip>

# Check tmux sessions
tmux ls

# Attach to hub cluster installation
tmux attach -t hub-install

# View install logs
tail -f /root/cluster-hub/install.log
tail -f /root/cluster-managed/install.log

# Check state file
cat /root/.ocp-deployment-state.json

# Check deployment log
tail -f /var/log/ocp-deployment.log
```

## Post-Deployment

### Access Clusters

After successful deployment:

1. **SSH to bastion**
   ```bash
   ssh -i ~/.ssh/ocp-bastion-key ec2-user@<bastion-ip>
   ```

2. **Export kubeconfig**
   ```bash
   export KUBECONFIG=/root/cluster-hub/auth/kubeconfig
   oc get nodes
   oc get co
   ```

3. **Get console URLs**
   ```bash
   # Hub cluster console
   oc whoami --show-console

   # Managed cluster
   export KUBECONFIG=/root/cluster-managed/auth/kubeconfig
   oc whoami --show-console
   ```

4. **Get kubeadmin passwords**
   ```bash
   cat /root/cluster-hub/auth/kubeadmin-password
   cat /root/cluster-managed/auth/kubeadmin-password
   ```

### Verify ACM

```bash
export KUBECONFIG=/root/cluster-hub/auth/kubeconfig

# Check ACM status
oc get multiclusterhub -n open-cluster-management

# Check managed clusters
oc get managedclusters

# Get ACM console URL
oc get route multicloud-console -n open-cluster-management
```

### Verify OpenShift Virtualization

```bash
# On both clusters
oc get hyperconverged -n openshift-cnv
oc get csv -n openshift-cnv
```

### Access Gitea

Gitea URL will be displayed at the end of deployment:
```
https://gitea-gitea.apps.hub.example.com
```

Default credentials:
- Username: `gitea_admin`
- Password: `ChangeMe123!` (change this immediately)

## Troubleshooting

### Installation Failures

1. **Check tmux sessions** on bastion
   ```bash
   tmux attach -t hub-install
   # Press Ctrl+b, then d to detach
   ```

2. **Review install logs**
   ```bash
   cat /root/cluster-hub/install.log | grep -i error
   ```

3. **Check AWS resources**
   ```bash
   aws ec2 describe-instances --region us-east-1 --filters "Name=tag:Name,Values=*ocp*"
   ```

### Common Issues

**Issue**: AWS quota limits
- **Solution**: Check EC2 instance quotas, especially for c5.metal instances

**Issue**: DNS propagation delays
- **Solution**: Wait 5-10 minutes after infrastructure creation

**Issue**: Pull secret invalid
- **Solution**: Verify JSON format and validity at console.redhat.com

**Issue**: Bastion SSH timeout
- **Solution**: Check security group rules allow SSH from your IP

## Cleanup

To tear down the environment:

1. **Delete OpenShift clusters** (from bastion)
   ```bash
   cd /root/cluster-hub
   openshift-install destroy cluster --dir=/root/cluster-hub
   
   cd /root/cluster-managed
   openshift-install destroy cluster --dir=/root/cluster-managed
   ```

2. **Delete AWS infrastructure**
   - Manually delete VPC, subnets, NAT gateways, bastion via AWS console
   - Or create a cleanup playbook

## Timeline

Expected deployment times:
- Phase 1-3: ~15 minutes
- Phase 4 (OpenShift): ~90-120 minutes (both clusters in parallel)
- Phase 5-6 (ACM): ~20 minutes
- Phase 7 (Bare metal): ~20 minutes
- Phase 8 (CNV): ~15 minutes
- Phase 9 (Gitea): ~5 minutes

**Total**: ~2-3 hours

## Support

For issues:
1. Check `/var/log/ocp-deployment.log` on bastion
2. Review Ansible output
3. Check OpenShift installer logs
4. Verify AWS console for resource states
