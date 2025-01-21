#!/bin/bash
set -e

echo "Starting SFTP Gateway container..."

# Function to safely create/modify files
safe_touch() {
    if [ ! -f "$1" ]; then
        touch "$1" 2>/dev/null || true
    fi
    chmod 644 "$1" 2>/dev/null || true
    chown udx:udx "$1" 2>/dev/null || true
}

# Initialize log files without failing on permission errors
safe_touch /var/log/sshd.log
safe_touch /var/log/auth.log
safe_touch /var/log/k8gate.log
safe_touch /var/log/k8gate-events.log

# Ensure we're root for SSH key generation
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root"
    exit 1
fi

# Generate SSH host keys if they don't exist and we have permission
if [ ! -f "/etc/ssh/ssh_host_rsa_key" ] && [ -w "/etc/ssh" ]; then
    echo "Generating SSH host keys..."
    ssh-keygen -A
    chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
    chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
    chown root:root /etc/ssh/ssh_host_*_key 2>/dev/null || true
    chown root:root /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
elif [ ! -f "/etc/ssh/ssh_host_rsa_key" ]; then
    echo "Warning: SSH host keys missing and no write permission to /etc/ssh"
    echo "Please ensure SSH keys are mounted correctly"
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

# Install dependencies if needed
cd /opt/sources/rabbitci/rabbit-ssh
if [ ! -d "node_modules" ]; then
    npm install google-gax
    npm install
fi

# Set up environment variables
export HOME=/home/udx
export USER=udx
export DEBUG=ssh*,sftp*,k8gate*,express*
export NODE_ENV=production
export NODE_PORT=8080

# Start services directly
if [[ -f "/etc/worker/services.yml" ]]; then
    echo "Starting services directly..."
    
    # Start services based on configuration
    if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
        echo "Starting SSHD service..."
        /usr/sbin/sshd -D -f /etc/ssh/sshd_config -e &
        echo "Waiting for SSHD to start..."
        while ! netstat -tlpn | grep -q ':22'; do
            sleep 1
        done
    fi

    if [[ "${SERVICE_ENABLE_API}" == "true" ]]; then
        echo "Starting API service..."
        cd /opt/sources/rabbitci/rabbit-ssh && \
        DEBUG=k8gate:*,api:*,auth:*,ssh:*,sftp:* \
        NODE_ENV=production \
        PORT=8080 \
        NODE_PORT=8080 \
        HOME=/home/udx \
        SERVICE_ENABLE_API=true \
        SERVICE_ENABLE_SSHD=true \
        node bin/server.js &
        
        echo "Waiting for API server to start..."
        while ! netstat -tlpn | grep -q ':8080'; do
            sleep 1
        done
    fi

    # Start key synchronization service if SSHD is enabled
    if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
        echo "Starting SSH key synchronization service..."
        cd /opt/sources/rabbitci/rabbit-ssh && \
        DEBUG=ssh:keys:*,auth:* \
        DIRECTORY_KEYS_BASE=/etc/ssh/authorized_keys.d \
        PASSWORD_FILE=/etc/passwd \
        PASSWORDS_TEMPLATE=alpine.passwords \
        HOME=/home/udx \
        node bin/controller.keys.js &
    fi

    # Wait for services to initialize
    sleep 3

    # Monitor logs
    exec tail -F /var/log/k8gate*.log /var/log/auth.log /var/log/sshd.log 2>/dev/null | grep --line-buffered -E "error|warn|debug|info"
else
    echo "Error: No worker service configuration found at /etc/worker/services.yml"
    exit 1
fi

# Start SSH daemon in foreground with debugging if no services started
if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]] && [[ ! -f "/etc/worker/services.yml" ]]; then
    echo "Starting SSH daemon in fallback mode..."
    exec /usr/sbin/sshd -D -e
fi

# This is a fallback and should never be reached
exec tail -f /var/log/sshd.log /var/log/auth.log
