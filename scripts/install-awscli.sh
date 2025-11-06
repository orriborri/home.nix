#!/bin/bash
# Install AWS CLI v2 directly from Amazon

set -e

echo "Installing AWS CLI v2..."

# Download AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"

# Extract
unzip awscliv2.zip

# Install
sudo ./aws/install

# Cleanup
rm -rf awscliv2.zip aws/

echo "AWS CLI v2 installed successfully!"
aws --version