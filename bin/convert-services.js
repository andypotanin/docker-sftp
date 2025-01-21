#!/usr/bin/env node
const fs = require('fs');
const yaml = require('js-yaml');
const path = require('path');

function convertToSupervisorConfig(services) {
    let supervisordConfig = '';
    
    for (const service of services) {
        supervisordConfig += `[program:${service.name}]\n`;
        supervisordConfig += `command=${service.command}\n`;
        supervisordConfig += `autostart=%(ENV_${service.autostart.replace(/[${}]/g, '')}s)\n`;
        supervisordConfig += `autorestart=${service.autorestart}\n`;
        
        if (service.user) {
            supervisordConfig += `user=${service.user}\n`;
        }
        
        if (service.directory) {
            supervisordConfig += `directory=${service.directory}\n`;
        }
        
        // Handle environment variables
        if (service.envs && service.envs.length > 0) {
            supervisordConfig += 'environment=';
            supervisordConfig += service.envs.join(',');
            supervisordConfig += '\n';
        }
        
        // Configure logging
        supervisordConfig += `stdout_logfile=/var/log/${service.name}.log\n`;
        supervisordConfig += `stderr_logfile=/var/log/${service.name}.log\n`;
        
        supervisordConfig += '\n';
    }
    
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
        
        const yamlContent = fs.readFileSync(servicesPath, 'utf8');
        const services = yaml.load(yamlContent).services;
        
        const supervisordConfig = convertToSupervisorConfig(services);
        
        fs.writeFileSync(outputPath, supervisordConfig);
        console.log(`Successfully converted ${servicesPath} to ${outputPath}`);
        
    } catch (error) {
        console.error('Error:', error.message);
        process.exit(1);
    }
}

main();
