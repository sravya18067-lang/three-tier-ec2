#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/proxy-bootstrap.log) 2>&1

dnf install -y nginx

cat > /etc/nginx/nginx.conf <<'NGINXEOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    server_tokens off;

    server {
        listen 80 default_server;
        server_name _;
        location / {
            proxy_pass http://${app_private_ip}:80;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_connect_timeout 5s;
        }
    }
}
NGINXEOF

systemctl enable --now nginx
