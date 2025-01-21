const { exec } = require('child_process');
const util = require('util');
const execAsync = util.promisify(exec);
const { describe, test, expect, beforeAll } = require('@jest/globals');

describe('Container Environment Tests', () => {
    const containerName = process.env.TEST_CONTAINER_NAME || 'udx-sftp-test-container';

    test('View container environment variables', async () => {
        const command = `docker exec ${containerName} /bin/bash -c 'env'`;
        try {
            const { stdout } = await execAsync(command);
            console.log('Container environment variables:');
            console.log(stdout);
            expect(stdout).toBeTruthy();
        } catch (error) {
            console.error('Failed to execute command:', error);
            throw error;
        }
    });
});