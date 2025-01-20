#!/bin/sh
# User Creation Script for Docker SFTP Gateway
#
# This script:
# - Creates system users for each key in /etc/ssh/authorized_keys.d/
# - Ensures SSH log file exists with proper permissions
# - Unlocks user accounts for SSH access
#
# Usage:
# This script is called by entrypoint.sh when initializing the container
# Users are created based on the presence of their public keys

# Create log file with proper permissions
touch /var/log/sshd.log
chmod 777 /var/log/sshd.log

# Create users for each key file
for f in $(ls /etc/ssh/authorized_keys.d/); do
  id  -u $f &> /dev/null || {
      adduser -D $f
      passwd -u $f
  }
done