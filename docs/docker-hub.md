# k8-container-gate

A secure, K8-native SSH/SFTP gateway with GitHub-based authentication and flexible state management.

## Features

- **GitHub Authentication**: Secure access using GitHub SSH keys and user roles
- **Multi-Platform Support**: Runs on AMD64 and ARM64 architectures
- **Cloud Run Integration**: API gateway mode for secure Kubernetes access
- **SFTP/SSH Gateway**: Direct file transfer and shell access to Kubernetes clusters
- **State Management**: Flexible state providers (Kubernetes, Firebase, Local)
- **VPC Connectivity**: Secure private networking between Cloud Run and GKE
- **Health Monitoring**: Built-in health checks and metrics
- **Rate Limiting**: Configurable rate limiting and access controls

## Quick Start

```bash
docker pull usabilitydynamics/k8-container-gate:latest
```

## Environment Variables

- `SERVICE_ENABLE_API`: Enable API gateway mode
- `SERVICE_ENABLE_SSHD`: Enable SSH/SFTP gateway mode
- `K8S_CLUSTER`: Kubernetes cluster name
- `K8S_PROJECT_ID`: Google Cloud project ID
- `K8S_LOCATION`: Cluster location/region
- `K8S_NAMESPACE`: Target Kubernetes namespace
- `ALLOW_SSH_ACCESS_ROLES`: GitHub roles allowed SSH access

## Documentation

For detailed setup and configuration instructions, visit our [GitHub repository](https://github.com/andypotanin/docker-sftp).

## Tags

- `latest`: Latest stable release
- `v0.9.0`: Current stable version
- `master`: Development build

## Security

- Regular security scans and updates
- No high-risk vulnerabilities
- Default non-root user
- Minimal base image
