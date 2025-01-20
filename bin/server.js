/**
 * API Server for Docker SFTP Gateway
 * 
 * This server provides:
 * - SSH/SFTP connection management
 * - Health checks for Kubernetes and Cloud Run
 * - User management endpoints
 * - Pod/container management
 * - Rate limiting and access control
 * 
 * Key Features:
 * - Health monitoring of SSH daemon and state provider
 * - User authentication and authorization
 * - Container lifecycle management
 * - Firebase integration for container cleanup
 * 
 * Environment Variables:
 * - ACCESS_TOKEN: Authentication token from worker.yml
 * - NODE_PORT: Server port (default: 8080)
 * - KUBERNETES_CLUSTER_ENDPOINT: K8s API endpoint
 * - STATE_PROVIDER: State management backend (default: kubernetes)
 * 
 * Endpoints:
 * - GET /health: Health check
 * - GET /users/: List users
 * - GET /v1/pods: List pods
 * - DELETE /flushFirebaseContainers: Cleanup old containers
 */

const axios = require('axios');
const _ = require('lodash');
const express = require('express');
const https = require('https');
const debug = require('debug')('sftp:server');
const { exec } = require('child_process');
const app = express();
const utility = require('../lib/utility');
const md5 = require('md5');

/**
 * Parse JSON safely
 * @param {string} data Data to parse
 * @returns {any} Parsed data or original if parsing fails
 */
function json_parse(data) {
    try {
        return JSON.parse(data);
    } catch (error) {
        debug('JSON parse error:', error);
        return data;
    }
}

/**
 * Converts Docker event message into a normalized container object.
 * @param {string} type Event type
 * @param {string} action Event action
 * @param {Object} data Event data
 * @returns {Object|null} Normalized container object or null
 */
function normalizeMessage(type, action, data) {
    if (action.indexOf('exec_start') === 0 || 
        action.indexOf('exec_create') === 0 || 
        type !== 'container') {
        return null;
    }

    const _attributes = _.get(data, 'Actor.Attributes', {});
    const _normalized = {
        _id: null,
        _type: 'container',
        host: (process.env.HOSTNAME || process.env.HOST || require('os').hostname()),
        fields: [],
        updated: _.get(data, 'timeNano'),
        lastAction: _.get(data, 'Action')
    };

    if (_attributes && type === 'container') {
        _.forEach(_attributes, (value, key) => {
            const _field = {
                key,
                value,
                type: 'string'
            };

            if (key === 'annotation.io.kubernetes.container.ports') {
                _field.value = json_parse(value);
                _field.type = 'object';
            }

            _normalized.fields.push(_field);
        });
    }

    if (_.get(data, 'Actor.ID')) {
        _normalized._id = _.get(data, 'Actor.ID', '').substring(0, 16);
    }

    return _normalized._id ? _normalized : null;
}
const rateLimit = require('../lib/rate-limit');
const events = require('../lib/events');

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
    app.close(() => {
        debug('HTTP server closed');
        process.exit(0);
    });
});

// Access token from worker.yml secrets
const accessToken = process.env.ACCESS_TOKEN;

// Configure axios defaults
axios.defaults.timeout = 10000; // 10 second timeout
axios.defaults.maxRedirects = 5;
axios.defaults.httpsAgent = new https.Agent({ keepAlive: true });

// Basic error handling middleware
app.use((err, req, res, next) => {
    debug('Error: %O', err);
    res.status(500).json({
        status: 'error',
        message: err.message
    });
});

// Error handling middleware
app.use((err, req, res, next) => {
    debug('Error: %O', err);
    res.status(500).json({
        status: 'error',
        message: err.message,
        stack: process.env.NODE_ENV === 'development' ? err.stack : undefined
    });
});

// Health check endpoint with comprehensive checks
app.get(['/health', '/_health'], async (req, res) => {
    try {
        // Check SSH daemon
        const sshStatus = await new Promise((resolve) => {
            exec('pgrep sshd', (error) => {
                resolve(error ? false : true);
            });
        });

        // Check Kubernetes connectivity if enabled
        let k8sStatus = false;
        if (process.env.KUBERNETES_CLUSTER_ENDPOINT) {
            try {
                const k8sResponse = await axios({
                    method: 'get',
                    url: `${process.env.KUBERNETES_CLUSTER_ENDPOINT}/api/v1/pods`,
                    headers: {
                        'Authorization': `Bearer ${process.env.KUBERNETES_CLUSTER_USER_TOKEN}`,
                        'Accept': 'application/json'
                    },
                    timeout: 5000
                });
                k8sStatus = k8sResponse.status === 200;
            } catch (err) {
                debug('Kubernetes health check failed: %O', err);
            }
        }

        // Overall health status
        const isHealthy = sshStatus && (process.env.KUBERNETES_CLUSTER_ENDPOINT ? k8sStatus : true);

        res.status(isHealthy ? 200 : 503).json({
            status: isHealthy ? 'healthy' : 'unhealthy',
            timestamp: new Date().toISOString(),
            checks: {
                ssh: sshStatus ? 'up' : 'down',
                kubernetes: process.env.KUBERNETES_CLUSTER_ENDPOINT ? (k8sStatus ? 'up' : 'down') : 'disabled'
            },
            version: process.env.npm_package_version || 'unknown'
        });
    } catch (error) {
        debug('Health check failed: %O', error);
        res.status(500).json({
            status: 'error',
            error: error.message
        });
    }
});

app.get('/_cat/connection-string/:user', singleUserEndpoint);

// list of all containers
// Health check endpoint for Cloud Run
// Removed this endpoint as it's now combined with /health

app.get('/users', userEndpoint);
app.get('/apps', appEndpoint);
app.get('/v1/pods', getPods);
// Removed Firebase endpoint
app.use(singleEndpoint);

// Listen on configured port with health check support and error handling
const port = process.env.PORT || process.env.NODE_PORT || 8080;
debug('Starting server initialization...');
const server = app.listen(port, '0.0.0.0', () => {
    debug('k8-container-gate-server listening on port %d', port);
    debug('Server environment:', {
        NODE_ENV: process.env.NODE_ENV,
        DEBUG: process.env.DEBUG,
        NODE_PORT: process.env.NODE_PORT,
        HOME: process.env.HOME,
        USER: process.env.USER
    });
    
    serverOnline().then(() => {
        debug('Server initialization complete');
    }).catch(err => {
        debug('Server online initialization failed: %O', err);
        console.error('Fatal error during server initialization:', err);
        process.exit(1);
    });
});

// Handle process signals properly
process.on('SIGTERM', () => {
    debug('SIGTERM received, shutting down gracefully');
    server.close(() => {
        debug('HTTP server closed');
        process.exit(0);
    });
});

process.on('SIGINT', () => {
    debug('SIGINT received, shutting down gracefully');
    server.close(() => {
        debug('HTTP server closed');
        process.exit(0);
    });
});

// Keep track of container state
let _containersStateHash = '';

// Configure TLS (consider removing in production)
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

// Container state update interval
const updateInterval = setInterval(async () => {
    try {
        const _container_url = process.env.KUBERNETES_CLUSTER_ENDPOINT ? 
            `${process.env.KUBERNETES_CLUSTER_ENDPOINT}/api/v1/pods` :
            `http://localhost:${process.env.NODE_PORT}/v1/pods`;

        const response = await axios({
            method: 'get',
            url: _container_url,
            headers: { 'x-rabbit-internal-token': process.env.KUBERNETES_CLUSTER_USER_TOKEN }
        });

        const body = _.get(response, 'data', {});
        if (_.size(_.get(body, 'items', [])) === 0) {
            debug('No response from container lookup at [%s]', _container_url);
            debug('Headers: %O', _.get(response, 'headers'));
            return;
        }

        const _containers = body.items.map(singleItem => ({
            ...singleItem,
            Labels: {
                ..._.get(singleItem, 'metadata.labels'),
                'ci.rabbit.name': _.get(singleItem, 'metadata.labels.name'),
                'ci.rabbit.ssh.user': _.get(singleItem, 'metadata.labels.ci.rabbit.ssh.user')
            }
        }));

        const _checkString = _containers.map(container => 
            _.get(container, 'metadata.name', '')).join('');

        if (_containersStateHash === md5(_checkString)) {
            debug('SSH keys are up to date');
        } else {
            debug('Updating SSH keys');
            await utility.updateKeys({
                containers: _containers,
                accessToken: accessToken
            });
            _containersStateHash = md5(_checkString);
        }
    } catch (error) {
        debug('Container state update failed: %O', error);
    }
}, 5000);

// Cleanup on exit
process.on('exit', () => {
    clearInterval(updateInterval);
    server.close();
});

/**
 *
 * curl localhost:8080/users/
 *
 * @param req
 * @param res
 */
function userEndpoint(req, res) {

    res.send({ items: app.get('sshUser') });

}

/**
 *
 * curl localhost:7010/v1/pods
 * @param req
 * @param res
 */
function getPods(req, res) {
    debug('getPods', req.url);

    // Use Kubernetes endpoint and token from worker.yml secrets
    axios({
        method: 'get',
        url: process.env.KUBERNETES_CLUSTER_ENDPOINT + '/api/v1/pods',
        headers: {
            'Authorization': 'Bearer ' + process.env.KUBERNETES_CLUSTER_USER_TOKEN,
            'Accept': 'application/json',
            'Content-Type': 'application/json'
        },
        timeout: 10000, // 10 second timeout
        // Support for custom CA certificates
        ...(process.env.KUBERNETES_CLUSTER_CERTIFICATE && {
            httpsAgent: new https.Agent({
                ca: process.env.KUBERNETES_CLUSTER_CERTIFICATE
            })
        })
    })
        .then(response => {
            res.send(response.data);
        })
        .catch(err => {
            console.log('getPods error: ', err.message);
        });

}

// Removed Firebase container cleanup endpoint

function appEndpoint(req, res) {

    res.send({
        items: _.map(app.get('sshUser'), function (someUser) {
            return {
                _id: someUser._id,
                sshUser: _.get(someUser, 'meta.sshUser'),
                connectionString: ['ssh ', _.get(someUser, 'meta.sshUser'), '@ssh.rabbit.ci'].join(''),
                pod: _.get(someUser, 'metadata.labels', {})['io.kubernetes.pod.name']
            };
        })
    });

}

/**
 *
 *
 * @param req
 * @param res
 */
function singleUserEndpoint(req, res) {
    // Check rate limits before processing request
    const check = rateLimit.checkLimit(req.params.user, 'any');
    if (!check.allowed) {
        res.status(429).send('Too many requests');
        return;
    }

    // Emit auth event for tracking
    events.emitLogin(req.params.user, 'any');

    var _result = _.find(app.get('sshUser'), function (someUser) {

        var _ssh = _.get(someUser, 'metadata.labels', {})['ci.rabbit.ssh.user'];
        var _pod = _.get(someUser, 'metadata.labels', {})['io.kubernetes.pod.name'];

        if (_ssh === req.params.user) {
            return true;
        }

        if (_pod === req.params.user) {
            return true;
        }

    });

    if (!_result) {
        res.set(404);
    }

    var _connection_string = [];

    if (_result) {

        _connection_string = [
            '-n',
            _.get(_result, 'metadata.labels', {})['io.kubernetes.pod.namespace'],
            'exec ',
            _.get(_result, 'metadata.labels', {})['io.kubernetes.pod.name']
        ];

    }

    res.send(_connection_string.join(' '));
}

function singleEndpoint(req, res) {
    console.log('default', req.url);
    res.send('ok!');
}

async function serverOnline() {
    console.log('k8-container-gate-server online!');

    var sshUser = app.get('sshUser') || {};

    // Initialize state provider
    const stateProvider = utility.getStateProvider({
        provider: process.env.STATE_PROVIDER || 'kubernetes',
        options: {
            kubernetes: {
                endpoint: process.env.KUBERNETES_CLUSTER_ENDPOINT,
                namespace: process.env.KUBERNETES_CLUSTER_NAMESPACE,
                token: process.env.KUBERNETES_CLUSTER_USER_TOKEN
            },

            local: {
                statePath: '/var/lib/k8gate/state.json',
                keysPath: '/etc/ssh/authorized_keys.d'
            }
        }
    });

    // Load and watch state
    async function initializeState() {
        try {
            await stateProvider.initialize();
            const keys = await stateProvider.loadState('keys');
            if (keys) {
                app.set('sshUser', keys);
                debug('Loaded SSH keys from state provider');
            }

            // Set up state watching if supported
            if (stateProvider.supportsRealtime()) {
                stateProvider.watchState('keys', (updatedKeys) => {
                    if (updatedKeys) {
                        app.set('sshUser', updatedKeys);
                        debug('Updated SSH keys from state provider');
                    }
                });
            }
        } catch (err) {
            console.error('Failed to initialize state provider:', err.message);
            
            // Firebase fallback removed - using state provider only
        }
    }

    // Initialize state management
    await initializeState();

    // detect non-kubernetes
    if (process.env.KUBERNETES_CLUSTER_ENDPOINT) {
        utility.updateKeys({
            keysPath: '/etc/ssh/authorized_keys.d',
            passwordFile: '/etc/passwd',
            passwordTemplate: 'alpine.passwords',
            accessToken: accessToken
        }, function keysUpdated(error, data) {
            console.log('Updated state with [%s] SSH keys.', error || _.size(data.users));
            app.set('sshUser', data.users);
        });
    }

    if (process.env.SLACK_NOTIFICACTION_URL && process.env.SLACK_NOTIFICACTION_URL.indexOf('https') === 0) {
        axios({
            method: 'post', //you can set what request you want to be
            url: process.env.SLACK_NOTIFICACTION_URL,
            data: {
                channel: process.env.SLACK_NOTIFICACTION_CHANNEL,
                username: 'SSH/Server',
                text: 'Container ' + (process.env.HOSTNAME || process.env.HOST) + ' is up. ```kubectl -n k8gate logs -f ' + (process.env.HOSTNAME || process.env.HOST) + '```'
            }
        });
    } else {
        console.log('process.env.SLACK_NOTIFICACTION_URL isn\'t set');
    }

}
