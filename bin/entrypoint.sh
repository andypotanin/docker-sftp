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
export SERVICE_ENABLE_SSHD=${SERVICE_ENABLE_SSHD:-true}
export SERVICE_ENABLE_API=${SERVICE_ENABLE_API:-true}

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

# Create required directories
mkdir -p /var/run/supervisor /var/log/supervisor /etc/supervisor/conf.d
chmod 755 /var/run/supervisor /var/log/supervisor /etc/supervisor/conf.d
chown -R root:root /etc/supervisor/

# Set up supervisord configuration
echo "Setting up supervisord configuration..."

# Create required directories
mkdir -p /etc/worker /etc/supervisor/conf.d /var/log/supervisor /var/run/supervisor
chmod 755 /etc/worker /etc/supervisor/conf.d /var/log/supervisor /var/run/supervisor
chown -R root:root /etc/supervisor

# Copy default services.yml if not mounted
if [ ! -f "/etc/worker/services.yml" ]; then
    echo "Warning: /etc/worker/services.yml not found, using default configuration"
    cp src/configs/services.yml /etc/worker/services.yml || {
        echo "Error: Failed to copy default services.yml"
        exit 1
    }
fi
chmod 644 /etc/worker/services.yml

echo "Services configuration input:"
cat /etc/worker/services.yml

# Install js-yaml if not present
if ! npm list -g js-yaml >/dev/null 2>&1; then
    echo "Installing js-yaml..."
    npm install -g js-yaml
fi

echo "Converting services.yml to supervisord format..."
echo "Environment variables:"
env | grep -E "SERVICE_|NODE_"
echo "Node.js version: $(node --version)"

# Copy and prepare conversion script
mkdir -p /usr/local/bin
cp bin/convert-services.js /usr/local/bin/ || {
    echo "Error: Failed to copy convert-services.js"
    exit 1
}
chmod +x /usr/local/bin/convert-services.js

echo "Converting services using Node.js..."
node /usr/local/bin/convert-services.js /etc/worker/services.yml /etc/supervisor/conf.d/services.conf
CONVERT_EXIT=$?

if [ $CONVERT_EXIT -ne 0 ]; then
    echo "Error: Failed to convert services configuration"
    echo "Script content:"
    cat /usr/local/bin/convert-services.js
    echo "Services.yml content:"
    cat /etc/worker/services.yml
    exit 1
fi

echo "Generated supervisord configuration:"
cat /etc/supervisor/conf.d/services.conf

# Set correct permissions
chown -R root:root /etc/supervisor
chmod 644 /etc/supervisor/conf.d/services.conf
chmod 755 /etc/supervisor/conf.d

# Verify supervisord configuration
echo "Verifying supervisord configuration..."
supervisord -c /etc/supervisor/supervisord.conf -t
if [ $? -ne 0 ]; then
    echo "Error: Invalid supervisord configuration"
    exit 1
fi

# Start supervisord
echo "Starting supervisord..."
echo "Service control: SSHD=${SERVICE_ENABLE_SSHD}, API=${SERVICE_ENABLE_API}"

# Start supervisord daemon
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf

# Wait for supervisord socket to be ready
echo "Waiting for supervisord to be ready..."
retry_count=0
while [ $retry_count -lt 30 ]; do
    if [ -e "/var/run/supervisor.sock" ] && supervisorctl status >/dev/null 2>&1; then
        echo "Supervisord is ready"
        break
    fi
    echo "Waiting for supervisord... (attempt $((retry_count + 1))/30)"
    retry_count=$((retry_count + 1))
    sleep 1
done

if [ $retry_count -eq 30 ]; then
    echo "Error: Supervisord failed to start"
    cat /var/log/supervisor/supervisord.log
    exit 1
fi

# Update supervisord and clear stale state
supervisorctl update
supervisorctl clear all

# Start services based on environment
if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
    echo "Starting SSHD services..."
    supervisorctl start sshd || {
        echo "Error starting SSHD service"
        supervisorctl status
        cat /var/log/supervisor/supervisord.log
        exit 1
    }
    sleep 2
    supervisorctl start ssh_keys_sync || {
        echo "Error starting SSH key sync service"
        supervisorctl status
        cat /var/log/supervisor/supervisord.log
        exit 1
    }
    
    # Verify SSHD services
    check_service_health sshd || {
        echo "SSHD health check failed"
        supervisorctl status
        cat /var/log/{supervisor/supervisord,sshd}.log
        exit 1
    }
    check_service_health ssh_keys_sync || {
        echo "SSH key sync health check failed"
        supervisorctl status
        cat /var/log/{supervisor/supervisord,ssh-keys-sync}.log
        exit 1
    }
fi

if [[ "${SERVICE_ENABLE_API}" == "true" ]]; then
    echo "Starting API service..."
    supervisorctl start k8gate || {
        echo "Error starting API service"
        supervisorctl status
        cat /var/log/supervisor/supervisord.log
        exit 1
    }
    
    # Verify API service
    check_service_health k8gate || {
        echo "API service health check failed"
        supervisorctl status
        cat /var/log/{supervisor/supervisord,k8gate}.log
        exit 1
    }
    
    # Additional API health check
    echo "Checking API health..."
    retry_count=0
    while [ $retry_count -lt 30 ]; do
        if curl -sf http://localhost:8080/health > /dev/null; then
            echo "API is healthy"
            break
        fi
        echo "Waiting for API to start... (attempt $((retry_count + 1))/30)"
        supervisorctl status k8gate
        tail -n 5 /var/log/k8gate.log
        retry_count=$((retry_count + 1))
        sleep 1
    done
    
    if [ $retry_count -eq 30 ]; then
        echo "ERROR: API health check failed"
        supervisorctl status
        cat /var/log/{supervisor/supervisord,k8gate}.log
        curl -v http://localhost:8080/health || true
        exit 1
    fi
fi

# Show final service status
echo "Final service status:"
supervisorctl status

# Show final service status
echo "Final service status:"
supervisorctl status

# Monitor logs
echo "All services started successfully. Starting log monitoring..."
exec tail -F /var/log/{sshd,k8gate,ssh-keys-sync,auth}.log | grep --line-buffered -E "error|warn|debug|info|ERROR|WARN|DEBUG|INFO"
