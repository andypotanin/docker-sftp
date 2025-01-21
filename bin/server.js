#!/usr/bin/env node

/**
 * API Server for Docker SFTP Gateway
 * 
 * This server provides SSH/SFTP connection management, health checks,
 * user management, and container lifecycle management.
 * 
 * Environment Variables:
 * - ACCESS_TOKEN: Authentication token from worker.yml
 * - NODE_PORT: Server port (default: 8080)
 * - KUBERNETES_CLUSTER_ENDPOINT: K8s API endpoint
 * - STATE_PROVIDER: State management backend (default: kubernetes)
 */

const { startGateway } = require('../src');
const debug = require('debug')('sftp:server');

// Configure error handling for uncaught exceptions and rejections

// Uncaught exception handler
process.on('uncaughtException', (err) => {
    debug('Uncaught Exception: %O', err);
    // Give time for logs to flush
    setTimeout(() => process.exit(1), 1000);
});

// Unhandled rejection handler
process.on('unhandledRejection', (reason, promise) => {
    debug('Unhandled Rejection at: %O\nreason: %O', promise, reason);
});

// Graceful shutdown handler
process.on('SIGTERM', () => {
    debug('SIGTERM received, shutting down gracefully');
    server.close(() => {
        debug('HTTP server closed');
        process.exit(0);
    });
});

// Start the gateway with environment-based configuration
startGateway({
    keysPath: process.env.DIRECTORY_KEYS_BASE || '/etc/ssh/authorized_keys.d',
    passwordFile: process.env.PASSWORD_FILE || '/etc/passwd',
    passwordTemplate: process.env.PASSWORDS_TEMPLATE || 'alpine.passwords',
    accessToken: process.env.ACCESS_TOKEN,
    port: process.env.PORT || process.env.NODE_PORT || 8080,
    stateProvider: process.env.STATE_PROVIDER || 'kubernetes',
    kubernetesConfig: {
        endpoint: process.env.KUBERNETES_CLUSTER_ENDPOINT,
        namespace: process.env.KUBERNETES_CLUSTER_NAMESPACE,
        token: process.env.KUBERNETES_CLUSTER_USER_TOKEN
    }
}).catch(err => {
    debug('Failed to start gateway:', err);
    console.error('Fatal error during server initialization:', err);
    process.exit(1);
});

// All endpoints have been moved to src/services/api-server.js

// All functionality has been moved to src/services/api-server.js and src/services/key-management.js
