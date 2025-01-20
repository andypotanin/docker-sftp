module.exports = {
  apps: [{
    name: 'sftp-gateway',
    script: '/opt/sources/rabbitci/rabbit-ssh/bin/server.js',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '1G',
    env: {
      NODE_ENV: 'production',
      DEBUG: 'ssh*,sftp*,k8gate*',
      SERVICE_ENABLE_SSHD: 'true',
      SERVICE_ENABLE_API: 'true',
      NODE_PORT: '8080'
    },
    merge_logs: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z'
  }]
};
