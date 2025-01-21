---
layout: post
title: "Building a Kubernetes-Native SFTP Gateway with GitHub Authentication"
date: 2025-01-21 06:29:00 -0500
categories: [kubernetes, docker, devops]
tags: [sftp, kubernetes, docker, github-auth, nodejs, alpine]
author: UDX Team
---

Today, I want to share our journey of building a Kubernetes-native SFTP gateway that uses GitHub authentication. This project solves a common challenge in modern cloud environments: providing secure SFTP access to Kubernetes pods while maintaining security and ease of use.

## The Challenge

Traditional SFTP servers often rely on local user accounts or complex key management systems. In a Kubernetes environment, this becomes even more challenging due to the dynamic nature of pods and the need for centralized authentication. We needed a solution that would:

1. Provide secure SFTP access to Kubernetes pods
2. Use GitHub authentication for simplicity and security
3. Be lightweight and cloud-native
4. Support flexible state management
5. Be easy to deploy and maintain

## The Solution: K8-Container-Gate

We built `k8-container-gate`, a lightweight SFTP gateway that runs as a container and integrates seamlessly with Kubernetes. Here are the key components:

### 1. Base Image Selection

We chose `node:23.5-alpine` as our base image for several reasons:
- Minimal footprint (~248MB final image size)
- Built-in Node.js support for our API layer
- Alpine Linux's security and simplicity

### 2. Core Components

The gateway consists of several key components:
- OpenSSH server for SFTP functionality
- Node.js API for authentication and management
- kubectl for Kubernetes interaction
- Health check system using netcat

### 3. Security First

Security was a top priority. We implemented several measures:
```bash
# SSH hardening
echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
echo "ChallengeResponseAuthentication no" >> /etc/ssh/sshd_config
echo "PermitRootLogin no" >> /etc/ssh/sshd_config
```

- Disabled password authentication
- Disabled root login
- Run as non-root user
- GitHub key-based authentication

### 4. Container Optimization

We focused on creating an efficient container:
```dockerfile
# Minimal dependencies
RUN apk add --no-cache \
    openssh \
    openssh-server \
    curl \
    bash \
    git \
    sudo \
    netcat-openbsd
```

- Only essential packages installed
- Multi-stage build for minimal layers
- Proper permission management
- Health checks for container orchestration

## Deployment and Usage

The gateway can be deployed easily on any Kubernetes cluster:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sftp-gateway
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: sftp-gateway
        image: usabilitydynamics/k8-container-gate:latest
        ports:
        - containerPort: 22
        - containerPort: 8080
```

Users can connect using their GitHub SSH keys:
```bash
sftp -P <port> user@gateway-host
```

## Lessons Learned

During development, we encountered and solved several challenges:

1. **Architecture Support**: Ensuring proper kubectl installation across different architectures (amd64/arm64)
2. **Permission Management**: Balancing security with functionality for the non-root user
3. **Container Size**: Optimizing the image size while maintaining functionality
4. **CI/CD Integration**: Setting up GitHub Actions for automated builds and deployments

## Future Improvements

We're planning several enhancements:
1. Support for additional authentication providers
2. Enhanced monitoring and logging
3. Multi-cluster support
4. Custom SFTP command handlers

## Conclusion

Building a Kubernetes-native SFTP gateway with GitHub authentication has been an interesting journey in combining traditional protocols with modern cloud-native practices. The result is a lightweight, secure, and easy-to-use solution that bridges the gap between SFTP and Kubernetes.

The project is open-source and available on [GitHub](https://github.com/andypotanin/docker-sftp). We welcome contributions and feedback from the community!

## Resources

- [Docker Hub Image](https://hub.docker.com/r/usabilitydynamics/k8-container-gate)
- [GitHub Repository](https://github.com/andypotanin/docker-sftp)
- [Documentation](https://github.com/andypotanin/docker-sftp/wiki)
