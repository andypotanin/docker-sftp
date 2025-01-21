const express = require('express');
const axios = require('axios');
const _ = require('lodash');
const debug = require('debug')('k8gate:server');
const md5 = require('md5');
const events = require('../utils/events');
const https = require('https');

/**
 * API Server Service
 * Handles HTTP endpoints and SSH connection management
 */
class ApiServer {
    /**
     * Create a new API server
     * @param {Object} config Configuration
     * @param {Object} keyManager Key management service instance
     */
    constructor(config, keyManager) {
        this.config = config;
        this.keyManager = keyManager;
        this.app = express();
        this.sshUsers = new Map();
        this.containersStateHash = '';
        this.setupRoutes();
    }

    /**
     * Set up Express routes
     * @private
     */
    setupRoutes() {
        // Connection string endpoint
        this.app.get('/_cat/connection-string/:user', this.handleConnectionString.bind(this));
        
        // User management endpoints
        this.app.get('/users', this.handleUsers.bind(this));
        this.app.get('/apps', this.handleApps.bind(this));
        
        // Kubernetes integration
        this.app.get('/v1/pods', this.handlePods.bind(this));
        
        // Default route
        this.app.use(this.handleDefault.bind(this));
    }

    /**
     * Start the server
     * @param {number} port Port to listen on
     */
    async start(port = process.env.NODE_PORT || 8080) {
        // Initial key update
        if (process.env.KUBERNETES_CLUSTER_ENDPOINT) {
            try {
                const result = await this.keyManager.updateKeys();
                this.sshUsers = new Map(Object.entries(result.users));
                debug('Initial key update complete');
            } catch (err) {
                debug('Initial key update failed:', err.message);
            }
        }

        // Start periodic key updates
        this.startKeyUpdateInterval();

        // Start server
        return new Promise((resolve) => {
            this.server = this.app.listen(port, '0.0.0.0', () => {
                debug(`Server listening on port ${port}`);
                this.notifyStartup();
                resolve();
            });
        });
    }

    /**
     * Stop the server
     */
    async stop() {
        if (this.server) {
            return new Promise((resolve) => {
                this.server.close(resolve);
            });
        }
    }

    /**
     * Start periodic key updates
     * @private
     */
    startKeyUpdateInterval() {
        setInterval(async () => {
            try {
                const pods = await this.getPods();
                const checkString = pods.map(pod => _.get(pod, 'metadata.name', '')).join('');
                const hash = md5(checkString);

                if (this.containersStateHash !== hash) {
                    debug('Container state changed, updating SSH keys');
                    const result = await this.keyManager.updateKeys();
                    this.sshUsers = new Map(Object.entries(result.users));
                    this.containersStateHash = hash;
                }
            } catch (err) {
                debug('Key update failed:', err.message);
            }
        }, 60000);
    }

    /**
     * Handle connection string requests
     * @private
     */
    handleConnectionString(req, res) {
        const user = req.params.user;
        const sshUser = Array.from(this.sshUsers.values())
            .find(u => u.sshUser === user || u.podName === user);

        if (!sshUser) {
            return res.sendStatus(404);
        }

        const connectionString = [
            '-n',
            _.get(sshUser, 'metadata.labels.io.kubernetes.pod.namespace'),
            'exec',
            _.get(sshUser, 'metadata.labels.io.kubernetes.pod.name')
        ].join(' ');

        res.send(connectionString);
        events.emitLogin(user, _.get(sshUser, 'metadata.labels.git.name'));
    }

    /**
     * Handle users endpoint
     * @private
     */
    handleUsers(req, res) {
        res.send({ items: Array.from(this.sshUsers.values()) });
    }

    /**
     * Handle apps endpoint
     * @private
     */
    handleApps(req, res) {
        const items = Array.from(this.sshUsers.values()).map(user => ({
            _id: user._id,
            sshUser: _.get(user, 'meta.sshUser'),
            connectionString: `ssh ${_.get(user, 'meta.sshUser')}@ssh.rabbit.ci`,
            pod: _.get(user, 'metadata.labels.io.kubernetes.pod.name')
        }));
        res.send({ items });
    }

    /**
     * Handle Kubernetes pods endpoint
     * @private
     */
    async handlePods(req, res) {
        try {
            const pods = await this.getPods();
            res.send({ items: pods });
        } catch (err) {
            debug('Error fetching pods:', err.message);
            res.status(500).send({ error: 'Failed to fetch pods' });
        }
    }

    /**
     * Handle default route
     * @private
     */
    handleDefault(req, res) {
        debug('Default route:', req.url);
        res.send('ok!');
    }

    /**
     * Get pods from Kubernetes
     * @private
     */
    async getPods() {
        const response = await axios({
            method: 'get',
            url: `${process.env.KUBERNETES_CLUSTER_ENDPOINT}/api/v1/pods`,
            headers: {
                'Authorization': `Bearer ${process.env.KUBERNETES_CLUSTER_USER_TOKEN}`
            }
        });
        return response.data.items || [];
    }

    /**
     * Notify startup via Slack
     * @private
     */
    async notifyStartup() {
        if (process.env.SLACK_NOTIFICACTION_URL && process.env.SLACK_NOTIFICACTION_URL.startsWith('https')) {
            try {
                await axios.post(process.env.SLACK_NOTIFICACTION_URL, {
                    channel: process.env.SLACK_NOTIFICACTION_CHANNEL,
                    username: 'SSH/Server',
                    text: `Container ${process.env.HOSTNAME || process.env.HOST} is up. \`\`\`kubectl -n rabbit-system logs -f ${process.env.HOSTNAME || process.env.HOST}\`\`\``
                });
            } catch (err) {
                debug('Failed to send Slack notification:', err.message);
            }
        }
    }
}

module.exports = ApiServer;
