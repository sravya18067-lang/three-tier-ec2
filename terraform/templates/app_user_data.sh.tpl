#!/bin/bash
# bundle: ${bundle_md5}   (changes here force instance replacement when the app changes)
set -euxo pipefail
exec > >(tee /var/log/app-bootstrap.log) 2>&1

dnf install -y docker unzip
systemctl enable --now docker
usermod -aG docker ec2-user

# Docker Compose v2 plugin
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fSL https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Fetch the app bundle from S3 (via VPC endpoint)
mkdir -p /opt/app && cd /opt/app
aws s3 cp s3://${bucket}/app.zip /tmp/app.zip --region ${region}
unzip -o /tmp/app.zip -d /opt/app

cat > /opt/app/.env <<ENVEOF
DB_NAME=appdb
DB_USER=appuser
DB_PASSWORD=${db_password}
ENVEOF
chmod 600 /opt/app/.env

cd /opt/app
docker compose up -d --build
echo "Bootstrap finished"
