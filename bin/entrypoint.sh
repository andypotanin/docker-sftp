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

# Start services using worker service management
echo "Starting services from worker configuration..."

# Check worker binary and validate configuration
worker_path=$(which worker)
if [ -z "$worker_path" ]; then
    echo "Error: worker binary not found in PATH"
    echo "PATH=$PATH"
    exit 1
fi

# Set debug environment for worker
export WORKER_DEBUG=true
export DEBUG="${DEBUG:-*},worker:*"

# Verify worker installation
echo "Worker binary: $worker_path ($(ls -l $worker_path))"
echo "Worker version: $($worker_path --version)"

# Validate services configuration
config_file="/etc/worker/services.yml"
if [ ! -f "$config_file" ]; then
    echo "Error: services.yml not found at $config_file"
    ls -la /etc/worker/
    exit 1
fi

echo "Validating services configuration..."
$worker_path validate "$config_file" || {
    echo "Error: Invalid services configuration"
    echo "Configuration contents:"
    cat "$config_file"
    exit 1
}

# Initialize worker daemon with debug logging
echo "Initializing worker daemon..."
$worker_path --debug init || {
    echo "Failed to initialize worker daemon"
    $worker_path --debug init 2>&1
    exit 1
}

# List available services with debug output
echo "Available services:"
$worker_path --debug list || {
    echo "ERROR: Failed to list services"
    echo "Service listing output:"
    $worker_path --debug list 2>&1
    echo "Current configuration:"
    ls -la /etc/worker/
    cat "$config_file"
    exit 1
}

# Initialize worker with debug logging
echo "Initializing worker daemon..."
$worker_path --debug init || {
    echo "Failed to initialize worker daemon. Error code: $?"
    echo "Daemon initialization output:"
    $worker_path --debug init 2>&1
    exit 1
}

# List available services with debug output
echo "Available services:"
$worker_path --debug list || {
    echo "ERROR: Failed to list services"
    echo "Service listing output:"
    $worker_path --debug list 2>&1
    echo "Current configuration:"
    ls -la /etc/worker/
    cat "$config_file"
    exit 1
}
    
# Start enabled services
if [ -f "/etc/worker/services.yml" ]; then
    # Start SSHD service if enabled
    if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
        echo "Starting SSHD service..."
        $worker_path start sshd --debug || {
            echo "ERROR: Failed to start SSHD service"
            echo "Service configuration:"
            $worker_path show sshd --debug || true
            echo "Available services:"
            $worker_path list --debug || true
            echo "SSHD process status:"
            ps aux | grep sshd || true
            echo "SSHD logs:"
            tail -n 50 /var/log/sshd.log || true
            exit 1
        }

        # Start key synchronization service
        echo "Starting SSH key synchronization service..."
        $worker_path start ssh_keys_sync --debug || {
            echo "ERROR: Failed to start ssh_keys_sync service"
            echo "Service configuration:"
            $worker_path show ssh_keys_sync --debug || true
            echo "Available services:"
            $worker_path list --debug || true
            echo "Process status:"
            ps aux | grep controller.keys || true
            echo "Key sync logs:"
            tail -n 50 /var/log/ssh-keys-sync.log || true
            exit 1
        }
    fi

    # Start API service if enabled
    if [[ "${SERVICE_ENABLE_API}" == "true" ]]; then
        echo "Starting API service..."
        $worker_path start k8gate --debug || {
            echo "ERROR: Failed to start k8gate service"
            echo "Service configuration:"
            $worker_path show k8gate --debug || true
            echo "Available services:"
            $worker_path list --debug || true
            echo "Node.js process status:"
            ps aux | grep node || true
            echo "API server logs:"
            tail -n 50 /var/log/k8gate.log || true
            exit 1
        }
    fi

    # Verify all services started successfully
    echo "Verifying service status..."
    $worker_path status --debug || {
        echo "ERROR: Service verification failed"
        exit 1
    }

    # Wait for services to initialize
    sleep 3

    # Monitor logs
    exec tail -F /var/log/k8gate*.log /var/log/auth.log | grep --line-buffered -E "error|warn|debug|info"
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
