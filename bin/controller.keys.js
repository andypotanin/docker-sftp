#!/usr/local/bin/node
/**
 * GitHub SSH Key Controller for Docker SFTP Gateway
 * 
 * This script synchronizes SSH access by:
 * 1. Getting running Docker applications and their GitHub IDs
 * 2. Fetching GitHub collaborators for each application
 * 3. Retrieving public SSH keys for each collaborator
 * 4. Generating SSH authorized_keys files and system user accounts
 * 
 * Environment Variables:
 * - DIRECTORY_KEYS_BASE: Base directory for authorized_keys (/etc/ssh/authorized_keys.d)
 * - PASSWORD_FILE: System password file (/etc/passwd)
 * - PASSWORDS_TEMPLATE: Template for password generation (alpine.passwords)
 * - CONTROLLER_KEYS_PATH: Optional state file path (/var/lib/rabbit-ssh/state.json)
 */

const axios = require('axios');
const async = require('async');
const Mustache = require('mustache');
const fs = require('fs');
const debug = require('debug')('update-ssh');
const _ = require('lodash');
const utility = require('../lib/utility');
const { KeyManagementService } = require('../src');

// Environment variables with defaults
const allowedRoles = process.env.ALLOW_SSH_ACCESS_ROLES || 'admin,maintain,write';
const productionBranch = process.env.PRODUCTION_BRANCH || 'production';
const allowedRolesForProd = process.env.ALLOW_SSH_ACCES_PROD_ROLES || 'admin';

/**
 * Update SSH keys and user accounts
 * @param {Object} options Configuration options
 * @param {string} options.keysPath Base directory for SSH keys
 * @param {string} options.passwordFile Path to password file
 * @param {string} options.passwordTemplate Template for password file
 * @param {string} options.accessToken GitHub access token
 * @param {Function} taskCallback Callback function
 */
module.exports.updateKeys = async function updateKeys(options, taskCallback) {
    // Set default callback if not provided
    taskCallback = typeof taskCallback === 'function' ? taskCallback : async () => {
        if (process.env.SLACK_NOTIFICACTION_URL && process.env.SLACK_NOTIFICACTION_URL.startsWith('https')) {
            try {
                await axios.post(process.env.SLACK_NOTIFICACTION_URL, {
                    channel: process.env.SLACK_NOTIFICACTION_CHANNEL,
                    username: 'SSH/Server',
                    text: `SSH Keys refreshed on ${process.env.HOSTNAME || process.env.HOST} has finished. \`\`\`kubectl -n ${process.env.KUBERNETES_CLUSTER_NAMESPACE} exec -it ${process.env.HOSTNAME || process.env.HOST} sh\`\`\``
                });
            } catch (err) {
                debug('Failed to send Slack notification:', err.message);
            }
        } else {
            debug('SLACK_NOTIFICACTION_URL not set or invalid');
        }
    };

    try {
        const keyManager = new KeyManagementService({
            keysPath: options.keysPath || process.env.DIRECTORY_KEYS_BASE || '/etc/ssh/authorized_keys.d',
            passwordFile: options.passwordFile || process.env.PASSWORD_FILE || '/etc/passwd',
            passwordTemplate: options.passwordTemplate || process.env.PASSWORDS_TEMPLATE || 'alpine.passwords',
            accessToken: options.accessToken || process.env.ACCESS_TOKEN,
            stateProvider: process.env.STATE_PROVIDER || 'kubernetes',
            kubernetesConfig: {
                endpoint: process.env.KUBERNETES_CLUSTER_ENDPOINT,
                namespace: process.env.KUBERNETES_CLUSTER_NAMESPACE,
                token: process.env.KUBERNETES_CLUSTER_USER_TOKEN
            }
        });

        const result = await keyManager.updateKeys();
        taskCallback(null, result);
        return result;
    } catch (err) {
        debug('Failed to update keys:', err);
        taskCallback(err);
        throw err;
    }

    var _applications = {}; // application to GitHub users
    var _allKeys = {}; // contains a GitHub User -> Array of Keys
    var _users = {}; // list of all users


    /**
     * Have Container List.
     *
     * @param err
     * @param resp
     * @param body
     */

    var _container_url = 'http://localhost:' + process.env.NODE_PORT + '/v1/pods';

    axios({
        method: 'get',
        url: _container_url,
        headers: { 'x-rabbit-internal-token': process.env.KUBERNETES_CLUSTER_USER_TOKEN }
    })
        .then(response => {
            let body = _.get(response, 'data', {});
            if (_.size(_.get(body, 'items', [])) === 0) {
                console.error('No response from container lookup at [%s].', _container_url);
                console.error('No pods found in response');
                //body = require('../static/fixtures/pods');
                return false;
            }

            var _containers = body = _.map(body.items, function (singleItem) {

                singleItem.Labels = _.get(singleItem, 'metadata.labels');

                // Prevents the application from being added to the list if it does not have the required labels
                if ( _.get(singleItem.Labels, 'name', false) && _.get(singleItem.Labels, 'ci.rabbit.ssh.user', false) ) {
                    singleItem.Labels['ci.rabbit.name'] = singleItem.Labels['name'];
                    singleItem.Labels['ci.rabbit.ssh.user'] = singleItem.Labels['ci.rabbit.ssh.user'] || null;
                    return singleItem;
                }

            });

            (_containers || []).forEach(function (containerInfo) {

                var _labels = _.get(containerInfo, 'metadata.labels', {});

                if (!_labels['ci.rabbit.ssh.user'] || null) {
                    return;
                }

                var _ssh_user = _labels['ci.rabbit.ssh.user'];

                // @todo May need to identify non-primary-branch apps here, or use a special label
                _applications[_ssh_user] = {
                    _id: (_labels['git.owner'] || _labels['git_owner']) + '/' + (_labels['git.name'] || _labels['git_name']),
                    sshUser: containerInfo.Labels['ci.rabbit.ssh.user'] || null,
                    //name: containerInfo.Names[0],
                    namespace: _.get(containerInfo, 'metadata.namespace'),
                    users: {},
                    containers: []
                };

            });

            _.each(_applications, function addConainers(application) {

                application.containers = _.map(_.filter(body, { Labels: { 'ci.rabbit.ssh.user': application.sshUser } }), function (foundContainer) {
                    return {
                        podName: _.get(foundContainer, 'metadata.name') || foundContainer.Labels['ci.rabbit.name'],
                        containerName: _.get(foundContainer, 'spec.containers[0].name')
                    };
                });

            });

            async.eachLimit(_.values(_applications), 3, function fetchCollaborators(data, callback) {
                // console.log( 'fetchCollaborators', data );

                var _token = _.get(options, 'accessToken');

                let requestOptions = {
                    method: 'get',
                    url: 'https://api.github.com/repos/' + data._id + '/collaborators',
                    headers: {
                        'Authorization': 'token ' + _token,
                        'User-Agent': 'wpCloud/Controller'
                    }
                };

                axios(requestOptions)
                    .then(res => {
                        let body = _.get(res, 'data', {});
                        debug('haveAppCollaborators [%s] using [%s] got code [%s]', requestOptions.url, _token, _.get(res, 'statusCode'));

                        if (_.get(res, 'headers.x-ratelimit-remaining') === '0') {
                            console.error('GitHub ratelimit exceeded using [%s] token.', requestOptions.headers.Authorization);
                        }

                        // get just the permissions, add users to application
                        ('object' === typeof body && body.length > 0 ? body : []).forEach(function (thisUser) {
                            // provide access only for users with roles: `maintain` and `admin`
                            if ((_.includes(_.split(allowedRoles, ','), thisUser.role_name) && (!data.sshUser.includes('.' + productionBranch)) || 
                            _.includes(_.split(allowedRolesForProd, ','), thisUser.role_name))) {
                                _applications[data.sshUser].users[thisUser.login] = {
                                    _id: thisUser.login,
                                    permissions: thisUser.permissions
                                };
                                _users[thisUser.login] = _users[thisUser.login] || [];
                                _users[thisUser.login].push(data._id);
                            }
                        });

                        callback();
                    })
                    .catch(err => {
                        console.error(' Error fetching collaborators for ' + data._id, err.message);
                        callback();
                    });

            }, haveCollaborators);

        })
        .catch(err => {
            console.log('getPods error: ', err.message);
            console.error('No response from container lookup at [%s].', _container_url);
            console.error('No pods found or error accessing Kubernetes API:', err.message);
            //console.error(" -headers ", _.get(resp, 'headers'));
            //body = require('../static/fixtures/pods');
            return false;
        });



    /**
     * Callback for when all collaborators have been collected from all the apps.
     *
     */
    function haveCollaborators() {
        console.log('haveCollaborators. Have [%d].', Object.keys(_users).length);

        _.each(_users, function eachCollaborator(collaboratorName) {
            //console.log( arguments );
        });

        getCollaboratorsKeys(haveAllKeys, _users);
    }

    /**
     * Fetch GitHub keys for a specific user from GitHub
     */
    function getCollaboratorsKeys(done, users) {
        debug('getCollaboratorsKeys');

        async.each(_.keys(users), function iterator(userName, singleComplete) {

            /**
             *
             * @todo Check that response is valid, not an error due to invalid user or whatever
             *
             * @param error
             * @param resp
             * @param body
             */

            axios({
                method: 'get',
                url: 'https://github.com/' + userName + '.keys'
            })
                .then(response => {
                    let body = _.get(response, 'data');
                    debug('gitHubCallback', userName);

                    var _userKeys = body.split('\n');

                    _allKeys[userName] = cleanArray(_userKeys);

                    singleComplete(null);
                })
                .catch(err => {
                    console.log('GitHub get keys error: ', err.message);
                    singleComplete(null);
                });

        }, function allDone() {
            debug('getCollaboratorsKeys:allDone');

            done(null, _allKeys);
        });

    }

    /**
     * Callback triggered when all the GitHub user keys are fetched
     * @param error
     * @param _allKeys
     */
    async function haveAllKeys(error, _allKeys) {
        debug('haveAllKeys [%d]', Object.keys(_allKeys).length);

        // Store keys using state provider
        if (_allKeys) {
            try {
                const stateProvider = utility.getStateProvider({
                    provider: process.env.STATE_PROVIDER || 'kubernetes',
                    options: {
                        kubernetes: {
                            endpoint: process.env.KUBERNETES_CLUSTER_ENDPOINT,
                            namespace: process.env.KUBERNETES_CLUSTER_NAMESPACE,
                            token: process.env.KUBERNETES_CLUSTER_USER_TOKEN
                        },
                        // Firebase provider removed - using Kubernetes or Local only
                        local: {
                            statePath: '/var/lib/k8gate/state.json',
                            keysPath: '/etc/ssh/authorized_keys.d'
                        }
                    }
                });

                await stateProvider.initialize();
                await stateProvider.saveState('keys', _allKeys);
                debug('Successfully stored keys using state provider');
            } catch (err) {
                console.error('Failed to store keys:', err.message);
                
                // Fallback to legacy file storage
                if (options.statePath) {
                    fs.writeFileSync(options.statePath, JSON.stringify({ keys: _allKeys }, null, 2), 'utf8');
                    debug('Stored keys using legacy file storage');
                }
            }
        }

        // create /etc/ssh/authorized_keys.d/{APP} directories
        _.keys(_applications).forEach(function createDirectory(appID) {

            if (!_applications[appID].sshUser) {
                console.log('Skipping [%s] because it does not have the \'ci.rabbit.ssh.user\' label.', appID);
                return;
            }

            var _path = (options.keysPath) + '/' + _applications[appID].sshUser;

            var writableKeys = [];

            debug('Creating SSH keys file for [%s] at [%s]/', appID, _path);

            _.values(_applications[appID].users).forEach(function (userData) {

                var _envs = {
                    application: appID,
                    namespace: _applications[appID].namespace,
                    containerName: _.get(_applications[appID], 'containers[0].containerName'),
                    podName: _.get(_applications[appID], 'containers[0].podName'),
                    user_data: userData._id,
                    CONNECTION_STRING: [_applications[appID].namespace, ' ', _.get(_applications[appID], 'containers[0].podName'), ' -c ', _.get(_applications[appID], 'containers[0].containerName')].join(' ')
                };

                _.get(_allKeys, userData._id, []).forEach(function (thisUsersKey) {
                    writableKeys.push('environment="ENV_VARS=' + _envs.CONNECTION_STRING + ';'+userData._id+'"   ' + thisUsersKey);
                });

            });

            if (writableKeys.length > 0) {

                fs.writeFile(_path, writableKeys.join('\n'), function (err) {

                    if (err) {
                        return console.error(err.message);
                    }

                    debug('Wrote SSH Key file for [%s] identified as [%s] user.', appID, _applications[appID].sshUser);
                    // console.log("The file was saved!");

                });

            } else {
                console.error('No keys returned [%s] not updated.', _path);
            }

            _.each(_applications[appID].containers, function (singleContainer) {

                var _container_path = (options.keysPath) + '/' + _.get(singleContainer, 'podName');

                if (writableKeys.length > 0) {
                    fs.writeFile(_container_path, writableKeys.join('\n'), function (err) {

                        if (err) {
                            return console.error(err.message);
                        }

                        console.log('Wrote SSH Key file for [%s] applications contianer [%s].', appID, _.get(singleContainer, 'podName'));
                        // console.log("The file was saved!");

                    });

                } else {
                    console.error('No keys returned [%s] not updated.', _container_path);

                }
            });

        });

        var _full_path = (options.passwordPath) + '' + (options.passwordTemplate) + '.mustache';

        // create /etc/passwd file
        fs.readFile(_full_path, 'utf8', function (err, source) {

            if (err) {
                return console.error(err.message);
            }

            var userFile = Mustache.render(source, {
                applications: _.values(_applications)
            });

            fs.writeFile(options.passwordFile, userFile, 'utf8', function (error) {
                console.log('Updated [%s] file with [%d] applications.', options.passwordFile, _.size(_applications));
                taskCallback(null, { ok: true, applications: _applications, users: _users });
            });
        });

    }

    /**
     * Helper to remove blank values from array.
     * @param actual
     * @returns {Array}
     */
    function cleanArray(actual) {
        var newArray = new Array();
        for (var i = 0; i < actual.length; i++) {
            if (actual[i]) {
                newArray.push(actual[i]);
            }
        }
        return newArray;
    }

};

if (!module.parent) {
    const keyManager = new KeyManagementService({
        keysPath: process.env.DIRECTORY_KEYS_BASE || '/etc/ssh/authorized_keys.d',
        passwordFile: process.env.PASSWORD_FILE || '/etc/passwd',
        passwordTemplate: process.env.PASSWORDS_TEMPLATE || 'alpine.passwords',
        accessToken: process.env.ACCESS_TOKEN,
        stateProvider: process.env.STATE_PROVIDER || 'kubernetes',
        kubernetesConfig: {
            endpoint: process.env.KUBERNETES_CLUSTER_ENDPOINT,
            namespace: process.env.KUBERNETES_CLUSTER_NAMESPACE,
            token: process.env.KUBERNETES_CLUSTER_USER_TOKEN
        }
    });

    keyManager.updateKeys().catch(err => {
        debug('Failed to update keys:', err);
        console.error('Error updating SSH keys:', err.message);
        process.exit(1);
    });
}
