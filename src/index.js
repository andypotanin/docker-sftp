const KeyManagementService = require('./services/key-management');
const ApiServer = require('./services/api-server');
const events = require('./utils/events');

/**
 * Initialize and start the SSH gateway services
 * @param {Object} config Configuration object
 * @returns {Promise<Object>} The initialized services
 */
async function startGateway(config = {}) {
    // Initialize key management
    const keyManager = new KeyManagementService({
        keysPath: config.keysPath || '/etc/ssh/authorized_keys.d',
        passwordFile: config.passwordFile || '/etc/passwd',
        passwordTemplate: config.passwordTemplate || 'alpine.passwords',
        accessToken: config.accessToken || process.env.GITHUB_TOKEN
    });

    // Initialize API server
    const apiServer = new ApiServer(config, keyManager);
    
    // Start server
    await apiServer.start(config.port || process.env.NODE_PORT || 8080);

    return {
        keyManager,
        apiServer,
        events
    };
}

module.exports = {
    startGateway,
    KeyManagementService,
    ApiServer,
    events
};
