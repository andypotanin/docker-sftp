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
    // Firebase provider removed
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

/**
 * Converts Docker event message into a normalized container object.
 *
 * @param type
 * @param action
 * @param data
 * @returns {*}
 */
module.exports.normalizeMessage = function normalizeMessage(type, action, data) {

    if (action.indexOf('exec_start') === 0) {
        return null;
    }

    if (action.indexOf('exec_create') === 0) {
        return null;
    }

    if (type !== 'container') {
        return null;
    }

    var _attributes = _.get(data, 'Actor.Attributes', {});

    var _normalized = {
        _id: null,
        //_type: [ type, action ].join('-'),
        _type: 'container',
        host: (process.env.HOSTNAME || process.env.HOST || require('os').hostname()),
        fields: [],
        updated: _.get(data, 'timeNano'),
        lastAction: _.get(data, 'Action')
    };

    if (_attributes && type === 'container') {
        _.forEach(_attributes, function (value, key) {

            var _field = {
                key: key,
                value: value,
                type: 'string'
            };

            // serialized JSON
            if (key === 'annotation.io.kubernetes.container.ports') {
                _field.value = module.exports.json_parse(value);
                _field.type = 'object';
            }

            _normalized.fields.push(_field);

        });

    }

    if (_.get(data, 'Actor.ID')) {
        _normalized._id = _.get(data, 'Actor.ID', '').substring(0, 16);
    }

    // only containers for now.
    if (!_normalized._id) {
        return null;
    }

    return _normalized;

};

module.exports.json_parse = function json_parse(data) {

    try {

        return JSON.parse(data);

    } catch (error) {
        debug('JSON parse error:', error);
        return data;
    }

};

// Firebase-related functions removed - using state provider instead

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
