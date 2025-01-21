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
worker_path="/usr/local/bin/worker"
if [ ! -x "$worker_path" ]; then
    echo "Error: worker binary not found or not executable at $worker_path"
    ls -la /usr/local/bin/worker* || true
    echo "PATH=$PATH"
    exit 1
fi

# Set debug environment for worker
export WORKER_DEBUG=true
export DEBUG="${DEBUG:-*},worker:*"

# Verify worker installation
echo "Worker binary: $worker_path ($(ls -l $worker_path))"
echo "Worker version: $($worker_path --version)"

# Verify services configuration exists and is readable
config_file="/etc/worker/services.yml"
if [ ! -f "$config_file" ]; then
    echo "Error: services.yml not found at $config_file"
    ls -la /etc/worker/
    exit 1
fi

# Verify configuration file permissions and ownership
chown root:root "$config_file"
chmod 644 "$config_file"

# Show configuration contents for debugging
echo "Services configuration contents:"
cat "$config_file"

# Ensure proper permissions on config file
chmod 644 "$config_file"
chown root:root "$config_file"

# Validate services configuration
echo "Validating services configuration..."
$worker_path validate "$config_file" || {
    echo "Error: Invalid services configuration"
    echo "Configuration contents:"
    cat "$config_file"
    echo "Worker debug output:"
    $worker_path validate "$config_file" --debug 2>&1
    exit 1
}

# Initialize worker daemon
echo "Initializing worker daemon..."
$worker_path init || {
    echo "Failed to initialize worker daemon"
    $worker_path init --debug 2>&1
    exit 1
}

# List available services
echo "Available services:"
$worker_path list || {
    echo "Error: Failed to list services"
    echo "Service listing output:"
    $worker_path list --debug 2>&1
    echo "Current configuration:"
    ls -la /etc/worker/
    cat "$config_file"
    exit 1
}

# Function to start a service with enhanced debugging
start_service() {
    local service_name="$1"
    local process_name="$2"
    local log_file="$3"
    local health_check="$4"
    
    echo "Starting ${service_name} service..."
    
    # Show service configuration before starting
    echo "Service configuration for ${service_name}:"
    $worker_path show "${service_name}" --debug || true
    
    # Ensure log file exists and has proper permissions
    touch "${log_file}" 2>/dev/null || true
    chmod 644 "${log_file}" 2>/dev/null || true
    chown udx:udx "${log_file}" 2>/dev/null || true
    
    # Start the service with debug output
    $worker_path start "${service_name}" --debug || {
        echo "ERROR: Failed to start ${service_name} service"
        echo "Service configuration:"
        $worker_path show "${service_name}" --debug || true
        echo "Available services:"
        $worker_path list --debug || true
        echo "Process status:"
        ps aux | grep "${process_name}" || true
        if [ -f "${log_file}" ]; then
            echo "${service_name} logs:"
            tail -n 50 "${log_file}" || true
        else
            echo "Warning: Log file ${log_file} not found"
        fi
        echo "Worker debug output:"
        WORKER_DEBUG=true $worker_path status --debug || true
        echo "Configuration file contents:"
        cat "$config_file"
        return 1
    }

    # Wait for service to be ready with improved debugging
    echo "Waiting for ${service_name} to be ready..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if eval "${health_check}"; then
            echo "${service_name} is ready"
            return 0
        fi
        echo "Health check failed, retrying in 1s (${retries} attempts left)"
        if [ -f "${log_file}" ]; then
            echo "Last 5 lines of ${service_name} logs:"
            tail -n 5 "${log_file}" || true
        fi
        retries=$((retries - 1))
        sleep 1
    done
    
    echo "ERROR: ${service_name} failed health check"
    echo "Full service logs:"
    cat "${log_file}" || true
    return 1
}

# Initialize worker daemon with debug output
echo "Initializing worker daemon..."
$worker_path init --debug || {
    echo "Failed to initialize worker daemon"
    echo "Worker debug output:"
    $worker_path init --debug
    exit 1
}

# List available services before starting
echo "Available services before startup:"
$worker_path list --debug || {
    echo "Error: Failed to list services"
    echo "Worker debug output:"
    $worker_path list --debug
    exit 1
}

# Start all services with proper error handling
if [ -f "/etc/worker/services.yml" ]; then
    # Start SSHD service if enabled
    if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
        echo "Starting SSHD services..."
        start_service "sshd" "sshd" "/var/log/sshd.log" "pgrep -f '/usr/sbin/sshd -D'" || exit 1
        start_service "ssh_keys_sync" "controller.keys" "/var/log/ssh-keys-sync.log" "pgrep -f 'controller.keys.js'" || exit 1
    fi

    # Start API service if enabled
    if [[ "${SERVICE_ENABLE_API}" == "true" ]]; then
        echo "Starting API service..."
        start_service "k8gate" "node.*server.js" "/var/log/k8gate.log" "curl -s http://localhost:8080/health > /dev/null" || exit 1
    fi

    # Verify all services started successfully
    echo "Verifying all services..."
    $worker_path status --debug || {
        echo "ERROR: Service verification failed"
        echo "Worker debug output:"
        $worker_path status --debug
        echo "Process status:"
        ps aux | grep -E "sshd|controller.keys|server.js" || true
        echo "Log files:"
        tail -n 50 /var/log/*.log || true
        exit 1
    }

    # Verify all services are running
    echo "Verifying service status..."
    $worker_path status --debug || {
        echo "ERROR: Service status check failed"
        $worker_path list --debug
        exit 1
    }

    # Monitor logs with improved filtering and health checks
    echo "All services started successfully. Starting log monitoring..."
    
    # Function to check service health with environment checks
    check_service_health() {
        local all_healthy=true
        
        # Check SSHD
        if [[ "${SERVICE_ENABLE_SSHD}" == "true" ]]; then
            if ! pgrep -f "/usr/sbin/sshd -D" > /dev/null; then
                echo "ERROR: SSHD not running"
                all_healthy=false
            else
                echo "SSHD: healthy"
            fi
            
            # Check key sync service
            if ! pgrep -f "controller.keys.js" > /dev/null; then
                echo "ERROR: Key sync service not running"
                all_healthy=false
            else
                echo "Key sync: healthy"
            fi
        fi
        
        # Check API server
        if [[ "${SERVICE_ENABLE_API}" == "true" ]]; then
            if ! curl -s http://localhost:8080/health > /dev/null; then
                echo "ERROR: API server not responding"
                all_healthy=false
            else
                echo "API server: healthy"
            fi
        fi
        
        # Show worker status
        echo "Worker service status:"
        $worker_path status --debug || true
        
        $all_healthy
    }
    
    # Start health check loop in background
    (
        while true; do
            if ! check_service_health; then
                echo "Critical service failure detected!"
                kill -TERM 1  # Signal main process to shutdown
                exit 1
            fi
            sleep 30
        done
    ) &
    
    # Monitor all relevant logs
    exec tail -F /var/log/sshd.log /var/log/k8gate.log /var/log/ssh-keys-sync.log /var/log/auth.log | grep --line-buffered -E "error|warn|debug|info|ERROR|WARN|DEBUG|INFO"
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
