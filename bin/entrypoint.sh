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
echo "Checking worker installation and configuration..."

# Check worker binary
if ! command -v worker &> /dev/null; then
    echo "Error: worker binary not found in PATH"
    exit 1
fi

echo "Worker binary location: $(which worker)"
echo "Worker version: $(worker --version || echo 'version check failed')"

# Check services configuration
if [ ! -f "/etc/worker/services.yml" ]; then
    echo "Error: services.yml not found at /etc/worker/services.yml"
    ls -la /etc/worker/ || echo "Worker config directory is empty or missing"
    exit 1
fi

# Verify services.yml permissions and content
echo "Services configuration:"
ls -la /etc/worker/services.yml
cat /etc/worker/services.yml

# Verify worker can read the configuration
/usr/local/bin/worker validate /etc/worker/services.yml || {
    echo "ERROR: Failed to validate services configuration"
    exit 1
}

echo "Services configuration found:"
cat /etc/worker/services.yml

# Verify worker configuration directory
echo "Worker configuration directory:"
ls -la /etc/worker/

# Validate services configuration
echo "Validating services configuration..."
/usr/local/bin/worker --debug validate /etc/worker/services.yml || {
    echo "Failed to validate services configuration. Error code: $?"
    exit 1
}

# List and verify available services
echo "Available services:"
/usr/local/bin/worker --debug list || {
    echo "Failed to list services. Error code: $?"
    exit 1
}

# Initialize worker daemon
echo "Initializing worker daemon..."
/usr/local/bin/worker --debug init || {
    echo "Failed to initialize worker daemon. Error code: $?"
    exit 1
}
    
    # Start services based on configuration
    echo "Starting services with worker..."
    worker_path=$(which worker)
    
    echo "Available services:"
    $worker_path list --debug || { 
        echo "ERROR: Failed to list services"
        echo "Worker configuration:"
        ls -la /etc/worker/
        cat /etc/worker/services.yml
        exit 1
    }
    
    if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
        echo "Starting SSHD service..."
        $worker_path start sshd --debug || {
            echo "ERROR: Failed to start SSHD service"
            echo "Service configuration:"
            $worker_path show sshd --debug || true
            echo "SSHD status:"
            ps aux | grep sshd
            exit 1
        }
    fi

    if [[ "${SERVICE_ENABLE_API}" == "true" ]]; then
        echo "Starting API service..."
        $worker_path start k8gate --debug || {
            echo "ERROR: Failed to start k8gate service"
            echo "Service configuration:"
            $worker_path show k8gate --debug || true
            echo "Node.js process status:"
            ps aux | grep node
            exit 1
        }
    fi

    # Start key synchronization service if SSHD is enabled
    if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
        echo "Starting SSH key synchronization service..."
        /usr/local/bin/worker start ssh-keys-sync || {
            echo "Failed to start ssh-keys-sync service. Error code: $?"
            echo "Worker debug output:"
            /usr/local/bin/worker --debug start ssh-keys-sync
        }
    fi

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
