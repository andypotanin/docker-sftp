# K8 Container Gate (formerly docker-sftp)

A secure, Kubernetes-native SSH/SFTP gateway with GitHub-based authentication and flexible state management.

## Features

- 🔐 GitHub-based SSH key authentication
- 🚀 Direct SSH/SFTP access to Kubernetes pods
- 👥 Role-based access control tied to GitHub permissions
- 🔄 Real-time key synchronization
- 📊 Flexible state management (Kubernetes, Firebase, Local)
- 🛡️ Configurable rate limiting
- 🔍 Detailed access logging
- 🌐 Multi-cloud deployment support

## Container Labels

For a container to be accessible via K8 Container Gate, it must have the following labels:

| Label | Description | Example |
|-------|-------------|---------|
| `ci.rabbit.ssh.user` | SSH username for container access | `myapp-dev` |
| `git.name` | Repository name | `my-project` |
| `git.owner` | Repository owner | `organization` |
| `git.branch` | Git branch (optional) | `main` |
| `name` | Container name | `myapp-web` |

Example Kubernetes deployment:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    metadata:
      labels:
        ci.rabbit.ssh.user: myapp-dev
        git.name: my-project
        git.owner: organization
        git.branch: main
        name: myapp-web
```

## Quick Start

### Prerequisites

- Kubernetes cluster (AKS, GKE, or other)
- kubectl configured with cluster access
- GitHub account with repository access
- Docker for local development

### Installation

1. Clone the repository:
```bash
git clone https://github.com/andypotanin/k8-container-gate.git
cd k8-container-gate
```

2. Configure environment variables:
```bash
# Kubernetes Configuration
export KUBERNETES_CLUSTER_NAME="your-cluster"
export KUBERNETES_CLUSTER_NAMESPACE="your-namespace"
export KUBERNETES_CLUSTER_SERVICEACCOUNT="k8gate-service-account"

# GitHub Configuration
export ACCESS_TOKEN="your-github-token"
export ALLOW_SSH_ACCESS_ROLES="admin,maintain,write"
```

3. Deploy to Kubernetes:
```bash
kubectl apply -f ci/deployment-aks.yml
```

### Basic Usage

1. Add your SSH public key to GitHub
2. Configure your SSH client:
```bash
# ~/.ssh/config
Host k8gate
    HostName <your-loadbalancer-ip>
    User <github-username>
    IdentityFile ~/.ssh/id_rsa
```

3. Connect to a pod (non-interactive mode preferred):
```bash
# Run single command
ssh k8gate "wp plugin list"

# Interactive mode (when necessary)
ssh k8gate "curl https://cognition-public.s3.amazonaws.com/install_shell_integration.sh | bash"
ssh -t k8gate
```

For detailed instructions on SSH, SFTP, and SCP usage, see [Remote Access Guide](docs/remote-access.md).

## Architecture

K8 Container Gate consists of several core components:

### 1. SSH Gateway
- OpenSSH server with custom authentication
- GitHub key synchronization
- Role-based access control

### 2. State Management
Flexible backend storage options:
- Kubernetes Secrets (default)
- Firebase Realtime Database
- Local file system

### 3. Access Control
- GitHub-based authentication
- Repository-level permissions
- Rate limiting and monitoring

For detailed architecture information, see [Architecture Documentation](docs/architecture.md).

## Configuration

### worker.yml Configuration

```yaml
kind: workerConfig
version: udx.io/worker-v1/config
config:
  env:
    # Service Control
    NODE_ENV: "production"
    SERVICE_ENABLE_SSHD: "true"
    SERVICE_ENABLE_API: "true"
    DEBUG: "ssh:*"
    
  # Repository Configuration
  repos:
    - name: "owner/repo"
      branch: "master"
      roles: ["admin", "maintain", "write"]
```

### State Management Configuration

```yaml
state:
  provider: kubernetes  # or firebase, local
  options:
    kubernetes:
      secretName: k8-container-gate-keys
      namespace: ${KUBERNETES_CLUSTER_NAMESPACE}
```

For detailed configuration options, see [State Management Documentation](docs/state-management.md).

## Supply Chain Security

Our Docker image supply chain is carefully designed with security and reliability in mind:

### Base Images

1. **Root Image**: [usabilitydynamics/worker](https://github.com/udx/worker)
   - Base Alpine Linux image. Core worker functionality. Security hardening.
   - Worker configuration at [lib/worker_config.sh](https://github.com/udx/worker/blob/latest/lib/worker_config.sh)
   - Dockerfile at [udx/worker](https://github.com/udx/worker/blob/latest/Dockerfile)
   - Available on [Docker Hub](https://registry.hub.docker.com/r/usabilitydynamics/udx-worker)

2. **Node.js Layer**: [udx/worker-nodejs](https://github.com/udx/worker-nodejs)
   - Node.js runtime environment. Security hardening.
   - Dockerfile at [udx/worker-nodejs](https://github.com/udx/worker-nodejs/blob/latest/Dockerfile)
   - Available on [Docker Hub](https://registry.hub.docker.com/r/usabilitydynamics/udx-worker-nodejs)

3. **SFTP Gateway**: This Repository (aka "Container Gate")
   - Connection You To Kubernetes with Zero Trust. Security hardening.
   - Dockerfile at [udx/container-gates](https://github.com/udx/container-gates/blob/latest/Dockerfile)
   - Available on [Docker Hub](https://registry.hub.docker.com/r/usabilitydynamics/udx-sftp)

### Configuration Management

Our configuration follows the UDX Worker standard:

1. **Service Configuration**: [services.yml](src/configs/services.yml)
   - Defines service components
   - Health checks
   - Process management
   - Documentation: [Worker Services](https://github.com/udx/worker/blob/latest/src/configs/_worker_services.md)

2. **Worker Configuration**: [worker.yml](src/configs/worker.yml)
   - Environment variables
   - Secrets management
   - Security policies
   - Documentation: [Worker Config](https://github.com/udx/worker/blob/latest/src/configs/_worker_config.md)

For more details about the UDX Worker platform, visit [Docker Hub](https://registry.hub.docker.com/r/usabilitydynamics/udx-worker).

## Contributing

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.
