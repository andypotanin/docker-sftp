#!/bin/bash
set -e

# Load worker configuration
source /usr/local/lib/worker_config.sh

# Generate host keys if not present
if [[ ! -f /etc/ssh/ssh_host_rsa_key ]]; then
    ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N ''
fi

if [[ ! -f /etc/ssh/ssh_host_dsa_key ]]; then
    ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N ''
fi

# Only setup Kubernetes if enabled
if [ "${SERVICE_ENABLE_K8S}" != "false" ]; then
  if [ "${KUBERNETES_CLUSTER_CERTIFICATE}" != "" ]; then
    echo "Writing Kubernetes certificate to [/home/udx/.kube/kuberentes-ca.crt]"
    cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt > /home/udx/.kube/kuberentes-ca.crt
  fi

  if [ -f /home/udx/.kube/kuberentes-ca.crt ]; then
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

    cp /root/.kube/config /home/udx/.kube/config

    chown -R udx:udx /home/udx/.kube
  fi
fi

# Install dependencies
npm install google-gax
npm install

# Start services using PM2
if [ -f "/etc/worker/services.yml" ]; then
  echo "Starting services from worker configuration..."
  worker service start
else
  echo "No worker service configuration found. Starting services directly..."
  
  if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
    echo "Starting SSH daemon..."
    pm2 start sshd
  fi

  if [[ "${SERVICE_ENABLE_API}" == "true" ]]; then
    echo "Starting API server..."
    pm2 start k8-container-gate
  fi
fi

# Create log files if they don't exist
touch /var/log/k8gate.log /var/log/k8gate-events.log /var/log/auth.log

# Keep container running and monitor logs
pm2 logs
