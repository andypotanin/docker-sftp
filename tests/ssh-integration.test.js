const { exec } = require('child_process');
const util = require('util');
const execAsync = util.promisify(exec);
const { describe, test, expect, beforeAll } = require('@jest/globals');

describe('SSH Integration Tests', () => {
    const sshConfig = {
        host: process.env.TEST_SSH_HOST || 'localhost',
        port: process.env.TEST_SSH_PORT || 2222,
        user: process.env.TEST_SSH_USER || 'udx',
        keyPath: process.env.TEST_SSH_KEY_PATH || '/tmp/test_ssh_key'
    };

    const testCommands = [
        'ls -la',
        'pwd',
        'whoami'
    ];

    beforeAll(async () => {
        // Wait for SSH service to be ready
        await new Promise(resolve => setTimeout(resolve, 15000));
        
        // Debug SSH setup
        console.log('SSH Config:', {
            host: sshConfig.host,
            port: sshConfig.port,
            user: sshConfig.user,
            keyPath: sshConfig.keyPath
        });
        
        try {
            // Verify SSH key permissions
            await execAsync(`chmod 600 ${sshConfig.keyPath}`);
            
            // Add test key to container
            const containerName = process.env.TEST_CONTAINER_NAME || 'udx-sftp-test-container';
            const pubKey = await execAsync(`cat ${sshConfig.keyPath}.pub`);
            await execAsync(`docker exec ${containerName} /bin/bash -c 'mkdir -p /home/udx/.ssh && echo "${pubKey.stdout}" >> /home/udx/.ssh/authorized_keys && chmod 700 /home/udx/.ssh && chmod 600 /home/udx/.ssh/authorized_keys && chown -R udx:udx /home/udx/.ssh'`);
            
            // Test SSH connection with verbose output
            const sshCmd = `ssh -v -i ${sshConfig.keyPath} -p ${sshConfig.port} -o StrictHostKeyChecking=no ${sshConfig.user}@${sshConfig.host} "echo Test Connection"`;
            console.log('Testing SSH connection with:', sshCmd);
            
            const { stdout } = await execAsync(sshCmd, { timeout: 30000 });
            console.log('SSH Connection Test:', stdout);
        } catch (err) {
            console.error('SSH Connection Test Failed:', err.message);
            console.error('Error Details:', err);
            console.error('Command Output:', err.stdout, err.stderr);
        }
    });

    test('SSH connection and command execution', async () => {
        for (const cmd of testCommands) {
            console.log(`Executing SSH command: ${cmd}`);
            try {
                const sshCmd = `ssh -i ${sshConfig.keyPath} -p ${sshConfig.port} -o StrictHostKeyChecking=no ${sshConfig.user}@${sshConfig.host} "${cmd}"`;
                const { stdout } = await execAsync(sshCmd);
                console.log(`Command output:`, stdout);
                expect(stdout).toBeTruthy();
            } catch (error) {
                console.error(`Failed to execute command: ${cmd}`);
                console.error('Error:', error);
                throw error;
            }
        }
    });

    test('SFTP file transfer', async () => {
        try {
            // Create test file
            const testFile = '/tmp/test-file.txt';
            await execAsync(`echo "Test content" > ${testFile}`);

            console.log('Executing SFTP commands...');
            const sftpCommands = `put ${testFile}\nls -l\nrm ${testFile}\nexit\n`;
            const sftpCmd = `sftp -i ${sshConfig.keyPath} -P ${sshConfig.port} -o StrictHostKeyChecking=no ${sshConfig.user}@${sshConfig.host}`;
            
            const { stdout } = await execAsync(sftpCmd, { input: sftpCommands });
            console.log('SFTP output:', stdout);
            expect(stdout).toContain(testFile);
        } catch (error) {
            console.error('SFTP test failed:', error);
            throw error;
        }
    });
});
