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

# Ensure supervisord configuration directory exists
mkdir -p /etc/supervisor/conf.d

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

# Start services using supervisord
echo "Starting services using supervisord..."

# Function to check service health
check_service_health() {
    local service=$1
    local max_retries=${2:-30}
    local retry_count=0
    
    echo "Waiting for $service to start..."
    while [ $retry_count -lt $max_retries ]; do
        if supervisorctl status "$service" | grep -q "RUNNING"; then
            echo "$service is running"
            return 0
        fi
        retry_count=$((retry_count + 1))
        sleep 1
    done
    
    echo "ERROR: $service failed to start"
    supervisorctl status
    return 1
}

# Start supervisord
echo "Starting supervisord..."
echo "Supervisord configuration:"
cat /etc/supervisor/supervisord.conf
echo "Services configuration:"
cat /etc/supervisor/conf.d/services.conf

# Convert mounted services configuration
echo "Converting services configuration..."
if [ ! -f /etc/worker/services.yml ]; then
    echo "Error: /etc/worker/services.yml not found"
    exit 1
fi

echo "Services configuration input:"
cat /etc/worker/services.yml

echo "Converting services.yml to supervisord format..."
/usr/local/bin/convert-services.js /etc/worker/services.yml /etc/supervisor/conf.d/services.conf
if [ $? -ne 0 ]; then
    echo "Error: Failed to convert services configuration"
    exit 1
fi

echo "Generated supervisord configuration:"
cat /etc/supervisor/conf.d/services.conf

# Verify supervisord configuration
echo "Verifying supervisord configuration..."
supervisord -c /etc/supervisor/supervisord.conf -t
if [ $? -ne 0 ]; then
    echo "Error: Invalid supervisord configuration"
    exit 1
fi

# Start supervisord
echo "Starting supervisord..."
/usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf &
SUPERVISOR_PID=$!

# Wait for supervisord to be ready
echo "Waiting for supervisord to be ready..."
timeout 30 bash -c 'until supervisorctl status >/dev/null 2>&1; do sleep 1; done' || {
    echo "Error: supervisord failed to start"
    cat /var/log/supervisor/supervisord.log
    exit 1
}

if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
    echo "Starting SSHD services..."
    supervisorctl start sshd ssh_keys_sync || { echo "Error starting SSHD services"; exit 1; }
    
    # Verify SSHD is running
    timeout 30 bash -c 'until supervisorctl status sshd | grep -q "RUNNING"; do sleep 1; done' || { 
        echo "Error: SSHD failed to start"
        supervisorctl status
        exit 1
    }
fi

if [[ "${SERVICE_ENABLE_API}" == "true" ]]; then
    echo "Starting API service..."
    supervisorctl start k8gate || { echo "Error starting API service"; exit 1; }
    
    # Verify API is running
    timeout 30 bash -c 'until supervisorctl status k8gate | grep -q "RUNNING"; do sleep 1; done' || {
        echo "Error: API service failed to start"
        supervisorctl status
        exit 1
    }
    
    # Additional API health check
    echo "Checking API health..."
    timeout 30 bash -c 'until curl -sf http://localhost:8080/health > /dev/null; do sleep 1; done' || {
        echo "Error: API health check failed"
        curl -v http://localhost:8080/health || true
        exit 1
    }
fi

# Monitor logs and keep container running
echo "All services started successfully. Monitoring logs..."
tail -F /var/log/{sshd,k8gate,ssh-keys-sync,auth}.log | grep --line-buffered -E "error|warn|debug|info|ERROR|WARN|DEBUG|INFO" &

# Wait for supervisord
wait $SUPERVISOR_PID

# Wait for supervisord to be ready
sleep 2

# Start and verify services based on environment
if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
    echo "Starting SSHD services..."
    supervisorctl start sshd ssh_keys_sync
    check_service_health sshd || exit 1
    check_service_health ssh_keys_sync || exit 1
fi

if [[ "${SERVICE_ENABLE_API}" == "true" ]]; then
    echo "Starting API service..."
    supervisorctl start k8gate
    check_service_health k8gate || exit 1
    
    # Additional API health check
    echo "Checking API health..."
    retry_count=0
    while [ $retry_count -lt 30 ]; do
        if curl -sf http://localhost:8080/health > /dev/null; then
            echo "API is healthy"
            break
        fi
        retry_count=$((retry_count + 1))
        sleep 1
    done
    
    if [ $retry_count -eq 30 ]; then
        echo "ERROR: API health check failed"
        curl -v http://localhost:8080/health || true
        exit 1
    fi
fi

# Monitor logs
echo "All services started successfully. Starting log monitoring..."
exec tail -F /var/log/{sshd,k8gate,ssh-keys-sync,auth}.log | grep --line-buffered -E "error|warn|debug|info|ERROR|WARN|DEBUG|INFO"
