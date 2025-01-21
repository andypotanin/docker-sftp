const _ = require('lodash');
const async = require('async');
const axios = require('axios');
const Mustache = require('mustache');
const fs = require('fs').promises;
const debug = require('debug')('k8gate:keys');
const events = require('../utils/events');

/**
 * Key Management Service
 * Handles SSH key synchronization and user management
 */
class KeyManagementService {
    /**
     * Create a new key management service
     * @param {Object} config Configuration
     * @param {string} config.keysPath Base directory for SSH keys
     * @param {string} config.passwordFile Path to password file
     * @param {string} config.passwordTemplate Template for password file
     * @param {string} config.accessToken GitHub access token
     */
    constructor(config) {
        this.config = {
            keysPath: config.keysPath || '/etc/ssh/authorized_keys.d',
            passwordFile: config.passwordFile || '/etc/passwd',
            passwordTemplate: config.passwordTemplate || 'alpine.passwords',
            accessToken: config.accessToken
        };
    }

    /**
     * Update SSH keys and user accounts
     * @returns {Promise<Object>} Result of the update
     */
    async updateKeys() {
        if (!this.config.accessToken) {
            throw new Error('Missing GitHub access token');
        }

        // Verify keys directory exists
        try {
            await fs.access(this.config.keysPath);
        } catch (err) {
            throw new Error(`Keys directory ${this.config.keysPath} does not exist`);
        }

        const applications = {};
        const allKeys = {};
        const users = {};

        // Get running containers from Kubernetes
        const containers = await this.getRunningContainers();
        
        // Process containers and extract application info
        for (const container of containers) {
            const labels = _.get(container, 'metadata.labels', {});
            const sshUser = labels['ci.rabbit.ssh.user'];
            
            if (!sshUser) continue;

            applications[sshUser] = {
                _id: `${labels['git.owner'] || labels['git_owner']}/${labels['git.name'] || labels['git_name']}`,
                sshUser,
                namespace: _.get(container, 'metadata.namespace'),
                users: {},
                containers: []
            };

            // Add container info
            applications[sshUser].containers.push({
                podName: _.get(container, 'metadata.name') || labels['ci.rabbit.name'],
                containerName: _.get(container, 'spec.containers[0].name')
            });
        }

        // Fetch collaborators for each application
        await async.eachLimit(Object.values(applications), 3, async (app) => {
            try {
                const response = await axios({
                    method: 'get',
                    url: `https://api.github.com/repos/${app._id}/collaborators`,
                    headers: {
                        'Authorization': `token ${this.config.accessToken}`,
                        'User-Agent': 'wpCloud/Controller'
                    }
                });

                const allowedRoles = (process.env.ALLOW_SSH_ACCESS_ROLES || 'admin,maintain,write').split(',');
                const prodRoles = (process.env.ALLOW_SSH_ACCES_PROD_ROLES || 'admin').split(',');
                const prodBranch = process.env.PRODUCTION_BRANCH || 'production';

                for (const user of response.data) {
                    const isProdBranch = app.sshUser.includes('.' + prodBranch);
                    const hasAllowedRole = isProdBranch ? 
                        prodRoles.includes(user.role_name) :
                        allowedRoles.includes(user.role_name);

                    if (hasAllowedRole) {
                        applications[app.sshUser].users[user.login] = {
                            _id: user.login,
                            permissions: user.permissions
                        };
                        users[user.login] = users[user.login] || [];
                        users[user.login].push(app._id);
                    }
                }
            } catch (err) {
                debug(`Error fetching collaborators for ${app._id}:`, err.message);
            }
        });

        // Fetch SSH keys for each user
        await async.each(Object.keys(users), async (userName) => {
            try {
                const response = await axios.get(`https://github.com/${userName}.keys`);
                allKeys[userName] = response.data.split('\n').filter(Boolean);
                events.emitKeyRotation(userName, allKeys[userName].length);
            } catch (err) {
                debug(`Error fetching keys for ${userName}:`, err.message);
            }
        });

        // Write authorized_keys files
        await Promise.all(Object.entries(applications).map(async ([sshUser, app]) => {
            if (!app.sshUser) {
                debug(`Skipping ${sshUser} - missing ci.rabbit.ssh.user label`);
                return;
            }

            const keyPath = `${this.config.keysPath}/${app.sshUser}`;
            const keys = [];

            Object.values(app.users).forEach(userData => {
                const envVars = {
                    application: app._id,
                    namespace: app.namespace,
                    containerName: _.get(app, 'containers[0].containerName'),
                    podName: _.get(app, 'containers[0].podName'),
                    user_data: userData._id,
                    CONNECTION_STRING: `${app.namespace} ${_.get(app, 'containers[0].podName')} -c ${_.get(app, 'containers[0].containerName')}`
                };

                (allKeys[userData._id] || []).forEach(key => {
                    keys.push(`environment="ENV_VARS=${envVars.CONNECTION_STRING};${userData._id}"   ${key}`);
                });
            });

            if (keys.length > 0) {
                await fs.writeFile(keyPath, keys.join('\n'));
                debug(`Updated SSH keys for ${app.sshUser}`);

                // Also write keys for each container
                await Promise.all(app.containers.map(async container => {
                    const containerPath = `${this.config.keysPath}/${container.podName}`;
                    await fs.writeFile(containerPath, keys.join('\n'));
                    debug(`Updated SSH keys for container ${container.podName}`);
                }));
            }
        }));

        // Update password file
        const templatePath = `${process.env.PASSWORDS_PATH || '/opt/sources/rabbitci/rabbit-ssh/static/templates/'}${this.config.passwordTemplate}.mustache`;
        const template = await fs.readFile(templatePath, 'utf8');
        const passwordFile = Mustache.render(template, { applications: Object.values(applications) });
        await fs.writeFile(this.config.passwordFile, passwordFile, 'utf8');

        return { applications, users };
    }

    /**
     * Get running containers from Kubernetes
     * @private
     */
    async getRunningContainers() {
        try {
            const response = await axios({
                method: 'get',
                url: `http://localhost:${process.env.NODE_PORT}/v1/pods`,
                headers: { 'x-rabbit-internal-token': process.env.KUBERNETES_CLUSTER_USER_TOKEN }
            });

            return _.get(response, 'data.items', []);
        } catch (err) {
            debug('Error fetching containers:', err.message);
            return [];
        }
    }
}

module.exports = KeyManagementService;
