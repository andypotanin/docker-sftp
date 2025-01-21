#!/usr/bin/env node
const fs = require('fs');
const yaml = require('js-yaml');
const path = require('path');

function convertToSupervisorConfig(services) {
    console.log('Converting services:', JSON.stringify(services, null, 2));
    let supervisordConfig = '';
    
    for (const service of services) {
        console.log(`Processing service: ${service.name}`);
        supervisordConfig += `[program:${service.name}]\n`;
        supervisordConfig += `command=${service.command}\n`;
        
        // Handle environment variable interpolation for autostart
        const autostart = service.autostart.replace(/\${([^}]+)}/g, (match, varName) => {
            console.log(`Replacing environment variable in autostart: ${varName}`);
            return `%(ENV_${varName})s`;
        });
        supervisordConfig += `autostart=${autostart}\n`;
        
        // Add standard supervisor options
        supervisordConfig += `startsecs=10\n`;
        supervisordConfig += `startretries=3\n`;
        supervisordConfig += `autorestart=${service.autorestart}\n`;
        supervisordConfig += `stopwaitsecs=30\n`;
        supervisordConfig += `killasgroup=true\n`;
        supervisordConfig += `stopasgroup=true\n`;
        
        if (service.user) {
            supervisordConfig += `user=${service.user}\n`;
        }
        
        if (service.directory) {
            supervisordConfig += `directory=${service.directory}\n`;
        }
        
        // Handle environment variables
        let envVars = [];
        if (service.envs && service.envs.length > 0) {
            envVars = service.envs.map(env => {
                if (env.includes('$')) {
                    console.log(`Processing environment variable: ${env}`);
                    return env.replace(/\${([^}]+)}/g, (match, varName) => {
                        console.log(`Replacing environment variable: ${varName}`);
                        return `%(ENV_${varName})s`;
                    });
                }
                return env;
            });
        }
        
        // Add service-specific environment variables
        envVars.push(`SERVICE_NAME=${service.name}`);
        
        if (envVars.length > 0) {
            supervisordConfig += 'environment=';
            supervisordConfig += envVars.join(',');
            supervisordConfig += '\n';
        }
        
        // Configure logging
        supervisordConfig += `stdout_logfile=/var/log/${service.name}.log\n`;
        supervisordConfig += `stderr_logfile=/var/log/${service.name}.log\n`;
        supervisordConfig += `stdout_logfile_maxbytes=50MB\n`;
        supervisordConfig += `stderr_logfile_maxbytes=50MB\n`;
        supervisordConfig += `stdout_logfile_backups=5\n`;
        supervisordConfig += `stderr_logfile_backups=5\n`;
        
        supervisordConfig += '\n';
    }
    
    console.log('Generated supervisord config:', supervisordConfig);
    return supervisordConfig;
}

async function main() {
    try {
        const servicesPath = process.argv[2];
        const outputPath = process.argv[3];
        
        if (!servicesPath || !outputPath) {
            console.error('Usage: convert-services.js <services.yml> <output.conf>');
            process.exit(1);
        }
        
        console.log('Reading services configuration from:', servicesPath);
        const yamlContent = fs.readFileSync(servicesPath, 'utf8');
        console.log('YAML content:', yamlContent);

        const parsedYaml = yaml.load(yamlContent);
        console.log('Parsed YAML:', JSON.stringify(parsedYaml, null, 2));

        if (!parsedYaml || !parsedYaml.services || !Array.isArray(parsedYaml.services)) {
            throw new Error('Invalid services.yml: missing or invalid services array');
        }

        if (parsedYaml.services.length === 0) {
            throw new Error('No services defined in services.yml');
        }

        const services = parsedYaml.services;
        console.log('Found services:', services.map(s => s.name).join(', '));
        
        const supervisordConfig = convertToSupervisorConfig(services);
        
        fs.writeFileSync(outputPath, supervisordConfig);
        console.log(`Successfully converted ${servicesPath} to ${outputPath}`);
        
    } catch (error) {
        console.error('Error:', error.message);
        process.exit(1);
    }
}

main();
