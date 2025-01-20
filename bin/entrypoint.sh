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

# Generate SSH host keys if they don't exist
if [ ! -f "/etc/ssh/ssh_host_rsa_key" ]; then
  ssh-keygen -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa
  chmod 0600 /etc/ssh/ssh_host_rsa_key
fi

if [ ! -f "/etc/ssh/ssh_host_dsa_key" ]; then
  ssh-keygen -f /etc/ssh/ssh_host_dsa_key -N '' -t dsa
  chmod 0600 /etc/ssh/ssh_host_dsa_key
fi

if [ ! -f "/etc/ssh/ssh_host_ecdsa_key" ]; then
  ssh-keygen -f /etc/ssh/ssh_host_ecdsa_key -N '' -t ecdsa
  chmod 0600 /etc/ssh/ssh_host_ecdsa_key
fi

if [ ! -f "/etc/ssh/ssh_host_ed25519_key" ]; then
  ssh-keygen -f /etc/ssh/ssh_host_ed25519_key -N '' -t ed25519
  chmod 0600 /etc/ssh/ssh_host_ed25519_key
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

# Install dependencies
cd /opt/app
npm install google-gax
npm install

# Start services based on configuration
if [ -f "/etc/worker/services.yml" ]; then
  echo "Starting services from worker configuration..."
  worker service start
else
  echo "No worker service configuration found. Starting services directly..."
  
  if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
    echo "Starting SSH daemon..."
    /usr/sbin/sshd -D &
  fi

  if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
    echo "Running initial SSH key sync..."
    node /usr/local/bin/controller.keys.js &
  fi

  if [[ "${SERVICE_ENABLE_API}" == "true" ]]; then
    echo "Starting API server..."
    node server.js &
  fi
fi

# Create log files if they don't exist
touch /var/log/k8gate.log /var/log/k8gate-events.log /var/log/auth.log

# Keep container running and monitor logs
if [ $# -gt 0 ]; then
    exec "$@"
else
    exec tail -F /var/log/k8gate*.log /var/log/auth.log | grep --line-buffered -E "error|warn|debug|info"
fi
