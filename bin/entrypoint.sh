#!/bin/bash
set -e

cat << "EOF"
                   ╭───────────────────╮
                  ╱ ⋆             ⋆     ╲
                 ╱    ▄▄▄▄▄▄▄▄▄▄▄▄      ╲
                ╱   ▄█████████████▄      ╲
               ╱   ████▀▀▀▀▀▀▀████       ╲
              ╱    ███  ▄▄▄▄  ███        ╲
             |     ███  ████  ███         |
             |     ███▄▄████▄▄███         |
             |      ▀██████████▀          |
             |     ▄▄███▀▀▀███▄▄         |
             |    ████        ████        |
             |   ▐███   ★     ███▌       |
             |    ▀██▄  SWIFT ▄██▀       |
             |      ▀█▄      ▄█▀         |
             |        ▀ SILENT ▀          |
             |     ▄▄▄  ★★★  ▄▄▄        |
             |    ▀▀█▀▀ DEADLY ▀▀█▀▀     |
             |       ▀▀▀▀▀▀▀▀▀▀▀         |
              ╲    2ND RECON BN         ╱
               ╲  ⋆               ⋆    ╱
                ╰───────────────────╯
EOF

echo "Starting SFTP Gateway container..."

# Function to safely create/modify files as root
safe_touch() {
    if [ ! -f "$1" ]; then
        touch "$1" 2>/dev/null || true
    fi
    chmod 644 "$1" 2>/dev/null || true
    chown udx:udx "$1" 2>/dev/null || true
}

# Initialize log files
safe_touch /var/log/sshd.log
safe_touch /var/log/auth.log
safe_touch /var/log/k8gate.log
safe_touch /var/log/k8gate-events.log

# Generate SSH host keys if they don't exist
if [ ! -f "/etc/ssh/ssh_host_rsa_key" ]; then
    echo "Generating SSH host keys..."
    ssh-keygen -A
    chmod 600 /etc/ssh/ssh_host_*_key
    chmod 644 /etc/ssh/ssh_host_*_key.pub
    chown root:root /etc/ssh/ssh_host_*
fi

# Create .ssh directory for udx user if it doesn't exist
if [ ! -d "/home/udx/.ssh" ]; then
    mkdir -p /home/udx/.ssh
    chmod 700 /home/udx/.ssh
    touch /home/udx/.ssh/authorized_keys
    chmod 600 /home/udx/.ssh/authorized_keys
    chown -R udx:udx /home/udx/.ssh
fi

# Set up environment variables
export HOME=/home/udx
export USER=udx
export DEBUG=ssh*,sftp*,k8gate*,express*
export NODE_ENV=production
export NODE_PORT=8080

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

echo "Starting services..."

# Start SSHD service if enabled
if [[ "${SERVICE_ENABLE_SSHD}" != "false" ]]; then
    echo "Starting SSHD service..."
    # Run sshd in the foreground with debug output to stderr
    if [ "$(id -u)" != "0" ]; then
        echo "Warning: Not running as root, attempting to start sshd with sudo..."
        sudo /usr/sbin/sshd -D -e &
    else
        /usr/sbin/sshd -D -e &
    fi
    SSHD_PID=$!
fi

# Start API service if enabled
if [[ "${SERVICE_ENABLE_API}" != "false" ]]; then
    echo "Starting API service (k8gate)..."
    cd /opt/sources/rabbitci/rabbit-ssh && \
    runuser -u udx -- node server.js >> /var/log/k8gate.log 2>&1 &
    API_PID=$!
fi

# List running services
echo "Active services:"
ps aux | grep -E "sshd|node" | grep -v grep

# Monitor services
while true; do
    echo "Checking service status..."
    if [[ "${SERVICE_ENABLE_SSHD}" != "false" ]]; then
        if ! kill -0 $SSHD_PID 2>/dev/null; then
            echo "SSHD service died, restarting..."
            if [ "$(id -u)" != "0" ]; then
                echo "Warning: Not running as root, attempting to start sshd with sudo..."
                sudo /usr/sbin/sshd -D -e &
            else
                /usr/sbin/sshd -D -e &
            fi
            SSHD_PID=$!
        fi
    fi
    
    if [[ "${SERVICE_ENABLE_API}" != "false" ]]; then
        if ! kill -0 $API_PID 2>/dev/null; then
            echo "API service died, restarting..."
            cd /opt/sources/rabbitci/rabbit-ssh && \
            runuser -u udx -- node server.js >> /var/log/k8gate.log 2>&1 &
            API_PID=$!
        fi
    fi
    
    ps aux | grep -E "sshd|node" | grep -v grep
    sleep 60
done
