#!/bin/bash
# Main entrypoint script for the SFTP container
# This script runs first and handles:
# - SSH host key generation
# - Kubernetes configuration setup
# - Node.js dependency installation
# - Service startup (SSHD and API server)
# - Log file initialization
#
# This script is set as the ENTRYPOINT in Dockerfile.udx and runs before
# controller.ssh.entrypoint.sh which handles the actual SSH connections.

set -e

# Ensure we're root for SSH key generation
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root"
    exit 1
fi

# Generate SSH host keys if they don't exist
if [ ! -f "/etc/ssh/ssh_host_rsa_key" ]; then
    ssh-keygen -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa
    chmod 0600 /etc/ssh/ssh_host_rsa_key
    chown root:root /etc/ssh/ssh_host_rsa_key
fi

if [ ! -f "/etc/ssh/ssh_host_dsa_key" ]; then
    ssh-keygen -f /etc/ssh/ssh_host_dsa_key -N '' -t dsa
    chmod 0600 /etc/ssh/ssh_host_dsa_key
    chown root:root /etc/ssh/ssh_host_dsa_key
    chmod 0644 /etc/ssh/ssh_host_dsa_key.pub
    chown root:root /etc/ssh/ssh_host_dsa_key.pub
fi

if [ ! -f "/etc/ssh/ssh_host_ecdsa_key" ]; then
    ssh-keygen -f /etc/ssh/ssh_host_ecdsa_key -N '' -t ecdsa
    chmod 0600 /etc/ssh/ssh_host_ecdsa_key
    chown root:root /etc/ssh/ssh_host_ecdsa_key
    chmod 0644 /etc/ssh/ssh_host_ecdsa_key.pub
    chown root:root /etc/ssh/ssh_host_ecdsa_key.pub
fi

if [ ! -f "/etc/ssh/ssh_host_ed25519_key" ]; then
    ssh-keygen -f /etc/ssh/ssh_host_ed25519_key -N '' -t ed25519
    chmod 0600 /etc/ssh/ssh_host_ed25519_key
    chown root:root /etc/ssh/ssh_host_ed25519_key
    chmod 0644 /etc/ssh/ssh_host_ed25519_key.pub
    chown root:root /etc/ssh/ssh_host_ed25519_key.pub
fi

# Set proper permissions for SSH directory
chmod 755 /etc/ssh
chmod 644 /etc/ssh/*.pub

# Load worker configuration
source /usr/local/lib/worker_config.sh

# Only setup Kubernetes if enabled
if [ "${SERVICE_ENABLE_K8S}" != "false" ]; then
  if [ "${KUBERNETES_CLUSTER_CERTIFICATE}" != "" ]; then
    echo "Writing Kubernetes certificate to [/home/node/.kube/kuberentes-ca.crt]"
    cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt > /home/node/.kube/kuberentes-ca.crt
  fi

  if [ -f /home/node/.kube/kuberentes-ca.crt ]; then
    echo "Setting up Kubernetes [$KUBERNETES_CLUSTER_NAME] cluster with [$KUBERNETES_CLUSTER_NAMESPACE] namespace."

    kubectl config set-cluster ${KUBERNETES_CLUSTER_NAME} \
      --embed-certs=true \
      --server=${KUBERNETES_CLUSTER_ENDPOINT} \
      --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

    kubectl config set-context ${KUBERNETES_CLUSTER_NAMESPACE} \
      --namespace=${KUBERNETES_CLUSTER_NAMESPACE} \
      --cluster=${KUBERNETES_CLUSTER_NAME} \
      --user=${KUBERNETES_CLUSTER_SERVICEACCOUNT}

    kubectl config set-credentials ${KUBERNETES_CLUSTER_SERVICEACCOUNT} --token=${KUBERNETES_CLUSTER_USER_TOKEN}

    kubectl config use-context ${KUBERNETES_CLUSTER_NAMESPACE}

    cp /root/.kube/config /home/node/.kube/config

    chown -R node:node /home/node/.kube
  fi
fi

# Install dependencies if needed
cd /opt/sources/rabbitci/rabbit-ssh
if [ ! -d "node_modules" ]; then
  npm install google-gax
  npm install
fi

# Create log files if they don't exist and set permissions
touch /var/log/k8gate.log /var/log/k8gate-events.log /var/log/auth.log
chown udx:udx /var/log/k8gate*.log
chmod 644 /var/log/k8gate*.log

# Enable debug logging
export DEBUG=ssh*,sftp*,k8gate*,express*

# Start services
echo "Starting services with debug logging enabled..."

# Start API server if enabled
if [[ "${SERVICE_ENABLE_API}" == "true" ]]; then
  echo "Starting API server..."
  cd /opt/sources/rabbitci/rabbit-ssh
  
  # Set up environment for API server
  export HOME=/home/udx
  export USER=udx
  export DEBUG=ssh*,sftp*,k8gate*,express*
  export NODE_ENV=production
  export NODE_PORT=8080

  # Start API server using services.yml configuration
  node bin/server.js >> /var/log/k8gate.log 2>&1 &

  # Wait for server to initialize
  sleep 3
fi

# Start SSH daemon in foreground if enabled
if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
  echo "Starting SSH daemon..."
  # Kill any existing sshd processes
  pkill sshd || true
  sleep 1
  
  # Start sshd in foreground with debug logging
  exec /usr/sbin/sshd -D -e
else
  # If SSHD is not enabled, just monitor logs
  exec tail -F /var/log/k8gate*.log /var/log/auth.log | grep --line-buffered -E "error|warn|debug|info"
fi
