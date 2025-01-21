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
- 🌐 Multi-cloud deployment support (GKE, Cloud Run, AKS)

## Architecture

The system consists of three main components:

1. **API Gateway** (Cloud Run)
   - Handles authentication and control plane
   - Manages GitHub key synchronization
   - Provides monitoring and logging endpoints
   - Runs on port 8080

2. **SFTP Gateway** (Kubernetes)
   - Handles SFTP connections on port 1127
   - Manages SSH access on port 22
   - Direct container access via Kubernetes

3. **State Management**
   - GitHub for key management
   - Kubernetes for container state
   - Optional Firebase for additional state

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

## Deployment Options

### 1. Cloud Run + GKE

This is the recommended setup for Google Cloud:

1. Deploy API Gateway to Cloud Run:
```bash
gcloud run deploy sftp-api \
  --image docker.io/usabilitydynamics/k8-container-gate:latest \
  --platform managed \
  --region us-central1 \
  --port 8080 \
  --memory 512Mi \
  --cpu 1 \
  --min-instances 1 \
  --set-env-vars="SERVICE_ENABLE_API=true,SERVICE_ENABLE_SSHD=false" \
  --vpc-connector vpc-connector \
  --vpc-egress all-traffic
```

2. Deploy SFTP Gateway to GKE:
```bash
kubectl apply -f k8s/deployment-gke.yml
```

### 2. Kubernetes-Only Setup

For traditional Kubernetes deployment:

```bash
kubectl apply -f k8s/deployment-full.yml
```

## Environment Variables

### API Gateway
- `SERVICE_ENABLE_API`: Enable API endpoints (default: true)
- `SERVICE_ENABLE_SSHD`: Enable SSH daemon (default: false for Cloud Run)
- `K8S_CLUSTER`: Kubernetes cluster name
- `K8S_PROJECT_ID`: GCP project ID (for GKE)
- `K8S_LOCATION`: Cluster location
- `K8S_NAMESPACE`: Kubernetes namespace

### SFTP Gateway
- `ALLOW_SSH_ACCESS_ROLES`: GitHub roles allowed SSH access
- `ACCESS_TOKEN`: GitHub access token
- `SSH_PORT`: SSH port (default: 22)
- `SFTP_PORT`: SFTP port (default: 1127)

## CI/CD

The project uses GitHub Actions for CI/CD:

1. **Docker Build** (.github/workflows/docker-build.yml)
   - Builds and pushes to Docker Hub
   - Tags with version from package.json
   - Available at `usabilitydynamics/k8-container-gate`

2. **Cloud Run Deploy** (.github/workflows/deploy-cloud-run.yml)
   - Deploys API Gateway to Cloud Run
   - Configures K8s connectivity
   - Manages secrets and environment

## Basic Usage

1. Add your SSH public key to GitHub
2. Configure your SSH client:
```bash
# ~/.ssh/config
Host k8gate
    HostName <your-loadbalancer-ip>
    User <github-username>
    IdentityFile ~/.ssh/id_rsa
```

3. Connect to a pod:
```bash
# Run single command
ssh k8gate "wp plugin list"

# Interactive mode
ssh -t k8gate
```

For detailed instructions on SSH, SFTP, and SCP usage, see [Remote Access Guide](docs/remote-access.md).

## Docker Image

Latest image is available on Docker Hub:
- Repository: [usabilitydynamics/k8-container-gate](https://registry.hub.docker.com/r/usabilitydynamics/k8-container-gate)
- Tags: 
  - `latest`: Latest stable release
  - `vX.Y.Z`: Specific versions
  - `master`: Latest development build
