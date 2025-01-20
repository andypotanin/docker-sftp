const _ = require('lodash');
const debug = require('debug')('ssh');
const KubernetesProvider = require('./providers/KubernetesProvider');
const LocalProvider = require('./providers/LocalProvider');

/**
 * Get a state provider instance based on configuration
 * @param {Object} config Configuration object
 * @returns {import('./providers/StateProvider')} Configured state provider
 */
module.exports.getStateProvider = function getStateProvider(config) {
    debug('Creating state provider:', config.provider);
  
    switch(config.provider) {
    case 'kubernetes':
        return new KubernetesProvider(config.options.kubernetes);
    case 'local':
        return new LocalProvider(config.options.local);
    default:
        debug('No provider specified, defaulting to local');
        return new LocalProvider(config.options.local || {
            statePath: '/var/lib/k8gate/state.json',
            keysPath: '/etc/ssh/authorized_keys.d'
        });
    }
};

module.exports.updateKeys = function updateKeys(options, callback) {
    debug('updateKeys', options);

    var updateKeysOptions = {
        keysPath: options.keysPath || '/etc/ssh/authorized_keys.d',
        passwordFile: options.passwordFile || '/etc/passwd',
        passwordTemplate: options.passwordTemplate || 'alpine.passwords',
        accessToken: options.accessToken || ''
    };

    if (require('fs').existsSync(updateKeysOptions.keysPath)) {
        debug('updateKeys', 'controllerKeys.updateKeys');
        require('../bin/controller.keys').updateKeys(updateKeysOptions, callback);
        debug('controllerKeys.updateKeys');
    } else {
        debug('updateKeys - Missing directory [%s].', updateKeysOptions.keysPath);
    }
};
