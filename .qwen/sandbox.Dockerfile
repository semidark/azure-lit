# Base: Qwen Code sandbox (Debian 12)
FROM ghcr.io/qwenlm/qwen-code:latest

USER root

ENV DEBIAN_FRONTEND=noninteractive

# Core packages and tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release software-properties-common \
    git openssh-client unzip jq \
    python3 python3-pip python3-venv \
    ansible \
  && rm -rf /var/lib/apt/lists/*

# Install Terraform via HashiCorp APT repository
RUN set -eux; \
  mkdir -p /usr/share/keyrings; \
  curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg; \
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list; \
  apt-get update && apt-get install -y --no-install-recommends terraform \
  && rm -rf /var/lib/apt/lists/*

# Install Azure CLI
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Install Ansible collections to a system-wide path accessible to non-root users
RUN mkdir -p /usr/share/ansible/collections && \
    ansible-galaxy collection install -p /usr/share/ansible/collections community.mysql community.general

# Default workdir; ensure node owns it
WORKDIR /workspace

# Environment for non-root user
ENV ANSIBLE_COLLECTIONS_PATHS="/usr/share/ansible/collections:/home/node/.ansible/collections"
ENV PATH="/home/node/.local/bin:${PATH}"
