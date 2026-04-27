#!/bin/bash
# Setup script for Ansible playbook environment

set -e

VENV_DIR="venv"

echo "=========================================="
echo "Setting up Ansible playbook environment"
echo "=========================================="

# Check Python version
if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 is not installed"
    exit 1
fi

PYTHON_VERSION=$(python3 --version | awk '{print $2}')
echo "Found Python: $PYTHON_VERSION"

# Create virtual environment
if [ -d "$VENV_DIR" ]; then
    echo "Virtual environment already exists at $VENV_DIR"
    read -p "Do you want to recreate it? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Removing existing virtual environment..."
        rm -rf "$VENV_DIR"
    else
        echo "Using existing virtual environment"
    fi
fi

if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

# Activate virtual environment
echo "Activating virtual environment..."
source "$VENV_DIR/bin/activate"

# Upgrade pip
echo "Upgrading pip..."
pip install --upgrade pip setuptools wheel

# Install Python dependencies
echo "Installing Python dependencies from requirements.txt..."
pip install -r requirements.txt

# Install Ansible collections
echo "Installing Ansible collections..."
ansible-galaxy collection install amazon.aws --force
ansible-galaxy collection install kubernetes.core --force
ansible-galaxy collection install community.general --force

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "To activate the virtual environment, run:"
echo "  source venv/bin/activate"
echo ""
echo "To verify installation:"
echo "  ansible --version"
echo "  python -c 'import boto3; print(\"boto3:\", boto3.__version__)'"
echo ""
echo "To run the playbook:"
echo "  ansible-playbook -i inventory/hosts.yml playbooks/site.yml"
echo ""
