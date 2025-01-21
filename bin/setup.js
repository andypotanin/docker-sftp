/**
 * Setup Script for Docker SFTP Gateway
 * 
 * This script handles the initial setup of the container:
 * - Generates SSH host keys (RSA and DSA) with proper permissions
 * - Configures Kubernetes cluster access if enabled
 * - Installs Node.js dependencies
 * 
 * Environment Variables:
 * - SERVICE_ENABLE_K8S: Enable Kubernetes setup
 * - KUBERNETES_CLUSTER_*: Kubernetes configuration variables
 * 
 * Usage:
 * This script is called by entrypoint.sh during container initialization
 * It uses the debug module for logging with namespace 'k8gate:setup'
 */

const fs = require('fs');
const { execSync } = require('child_process');
const debug = require('debug')('k8gate:setup');
const _ = require('lodash');

function setupSSHKeys() {
    debug('Setting up SSH keys...');
    
    // Generate RSA key if needed
    if (!fs.existsSync('/etc/ssh/ssh_host_rsa_key')) {
        debug('Generating RSA key...');
        execSync('ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N ""');
        fs.chmodSync('/etc/ssh/ssh_host_rsa_key', '0600');
    }

    // Generate DSA key if needed
    if (!fs.existsSync('/etc/ssh/ssh_host_dsa_key')) {
        debug('Generating DSA key...');
        execSync('ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N ""');
        fs.chmodSync('/etc/ssh/ssh_host_dsa_key', '0600');
    }
}

function setupKubernetes() {
    if ( _.get(process, 'env.SERVICE_ENABLE_K8S') !== 'true') {
        debug('Kubernetes setup disabled');
        return;
    }

    debug('Setting up Kubernetes configuration...');
    
    const kubeConfig = {
        apiVersion: 'v1',
        kind: 'Config',
        clusters: [{
            cluster: {
                'certificate-authority-data': _.get(process, 'env.KUBERNETES_CLUSTER_CERTIFICATE'),
                server: _.get(process, 'env.KUBERNETES_CLUSTER_ENDPOINT')
            },
            name: _.get(process, 'env.KUBERNETES_CLUSTER_NAME')
        }],
        contexts: [{
            context: {
                cluster: _.get(process, 'env.KUBERNETES_CLUSTER_NAME'),
                user: _.get(process, 'env.KUBERNETES_CLUSTER_USER_TOKEN')
            },
            name: _.get(process, 'env.KUBERNETES_CLUSTER_CONTEXT')
        }],
        'current-context': _.get(process, 'env.KUBERNETES_CLUSTER_CONTEXT'),
        users: [{
            name: _.get(process, 'env.KUBERNETES_CLUSTER_USER_TOKEN'),
            user: {
                token: _.get(process, 'env.KUBERNETES_CLUSTER_USER_SECRET')
            }
        }]
    };

    // Create kube config directory
    if (!fs.existsSync('/root/.kube')) {
        fs.mkdirSync('/root/.kube', { recursive: true });
    }

    // Write config file
    fs.writeFileSync('/root/.kube/config', JSON.stringify(kubeConfig, null, 2));
    fs.chmodSync('/root/.kube/config', '0600');
}

function setupDependencies() {
    debug('Installing dependencies...');
    process.chdir('/opt/app');
    execSync('npm install google-gax', { stdio: 'inherit' });
    execSync('npm install', { stdio: 'inherit' });
}

function main() {
    try {
        setupSSHKeys();
        setupKubernetes();
        setupDependencies();
        debug('Setup completed successfully');
    } catch (error) {
        console.error('Setup failed:', error);
        process.exit(1);
    }
}

main();
