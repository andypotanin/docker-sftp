const _ = require('lodash');
const debug = require('debug')('k8gate:normalize');

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

module.exports = normalizeMessage;
