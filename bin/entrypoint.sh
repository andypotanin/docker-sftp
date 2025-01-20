#!/bin/bash
set -e

echo "Starting SFTP Gateway container..."

# Initialize log files
touch /var/log/sshd.log /var/log/auth.log
chown udx:udx /var/log/sshd.log /var/log/auth.log
chmod 644 /var/log/sshd.log /var/log/auth.log

# Set up SSH directories and permissions
chmod 755 /etc/ssh
chmod 755 /etc/ssh/authorized_keys.d
chmod 644 /etc/ssh/sshd_config

# Generate SSH host keys if they don't exist
if [ ! -f "/etc/ssh/ssh_host_rsa_key" ]; then
    echo "Generating SSH host keys..."
    ssh-keygen -A
    chmod 600 /etc/ssh/ssh_host_*_key
    chmod 644 /etc/ssh/ssh_host_*_key.pub
fi

# Load worker configuration if available
if [ -f "/usr/local/lib/worker_config.sh" ]; then
    source /usr/local/lib/worker_config.sh
fi

# Setup Kubernetes if enabled
if [ "${SERVICE_ENABLE_K8S}" != "false" ] && [ -n "${KUBERNETES_CLUSTER_CERTIFICATE}" ]; then
    echo "Setting up Kubernetes configuration..."
    mkdir -p /home/udx/.kube
    cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt > /home/udx/.kube/kubernetes-ca.crt
    
    kubectl config set-cluster "${KUBERNETES_CLUSTER_NAME}" \
        --embed-certs=true \
        --server="${KUBERNETES_CLUSTER_ENDPOINT}" \
        --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

    kubectl config set-context "${KUBERNETES_CLUSTER_NAMESPACE}" \
        --namespace="${KUBERNETES_CLUSTER_NAMESPACE}" \
        --cluster="${KUBERNETES_CLUSTER_NAME}" \
        --user="${KUBERNETES_CLUSTER_SERVICEACCOUNT}"

    kubectl config set-credentials "${KUBERNETES_CLUSTER_SERVICEACCOUNT}" \
        --token="${KUBERNETES_CLUSTER_USER_TOKEN}"

    kubectl config use-context "${KUBERNETES_CLUSTER_NAMESPACE}"
    
    cp /root/.kube/config /home/udx/.kube/config
    chown -R udx:udx /home/udx/.kube
fi

# Start API server with PM2 if enabled
if [[ "${SERVICE_ENABLE_API}" != "false" ]]; then
    echo "Starting API server with PM2..."
    cd /opt/sources/rabbitci/rabbit-ssh
    
    # Ensure PM2 directories exist with correct permissions
    mkdir -p /home/udx/.pm2/logs
    chown -R udx:udx /home/udx/.pm2
    chmod -R 755 /home/udx/.pm2
    
    # Start PM2 as udx user
    runuser -u udx -- bash -c "cd /opt/sources/rabbitci/rabbit-ssh && PM2_HOME=/home/udx/.pm2 pm2 start ecosystem.config.js"
fi

# Start SSH daemon in foreground with debugging
if [[ "${SERVICE_ENABLE_SSHD}" != "false" ]]; then
    echo "Starting SSH daemon..."
    exec /usr/sbin/sshd -D -e
fi

# This is a fallback and should never be reached
exec tail -f /var/log/sshd.log /var/log/auth.log
