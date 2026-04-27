# Ansible Playbook Project

This repository contains Ansible playbooks for infrastructure automation.

## Directory Structure

```
.
├── playbooks/          # Ansible playbooks
├── roles/              # Custom Ansible roles
├── inventory/          # Inventory files (hosts, groups)
├── group_vars/         # Group-specific variables
├── host_vars/          # Host-specific variables
├── files/              # Static files to be copied to hosts
├── templates/          # Jinja2 templates
└── ansible.cfg         # Ansible configuration
```

## Prerequisites

- Ansible 2.9 or higher
- Python 3.6 or higher

## Usage

Run playbooks from the project root:

```bash
ansible-playbook -i inventory/<inventory-file> playbooks/<playbook-name>.yml
```

## Configuration

Ansible settings are defined in `ansible.cfg`. Modify as needed for your environment.
