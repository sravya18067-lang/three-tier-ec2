# Three-Tier Dockerized App on AWS EC2 (Custom VPC)

## Architecture

```
Internet
   │  HTTP :80 (anywhere)          SSH :22 (ONLY your IP)
   ▼
┌─────────────────── Custom VPC 10.0.0.0/16 ───────────────────┐
│  PUBLIC subnet 10.0.1.0/24                                   │
│   ├─ Internet Gateway                                        │
│   ├─ NAT Gateway (outbound-only for the private subnet)      │
│   └─ EC2 "proxy/bastion" (nginx reverse proxy + SSH jump)    │
│            │ HTTP :80 / SSH :22  (SG-to-SG only)             │
│            ▼                                                 │
│  PRIVATE subnet 10.0.2.0/24   (no public IP)                 │
│   └─ EC2 "app" – Docker Compose:                             │
│        frontend (nginx :80) → backend (Node :5000) → Postgres│
│        (only :80 is published; 5000/5432 stay on Docker nets)│
└──────────────────────────────────────────────────────────────┘
```

Because the app host lives in a private subnet it has no public IP, so the
public subnet hosts a small nginx reverse proxy that is the single entry point.
The app host also pulls its bundle from a private S3 bucket through a free S3
gateway endpoint.

## Security group rules

| SG | Direction | Port | Source / Destination | Purpose |
|---|---|---|---|---|
| proxy-sg | in | 80 | 0.0.0.0/0 | Public HTTP |
| proxy-sg | in | 22 | `admin_cidr` (your /32) | Admin SSH only |
| proxy-sg | out | 80, 22 | app-sg | Forward traffic / SSH jump |
| proxy-sg | out | 80, 443 | 0.0.0.0/0 | Package install |
| app-sg | in | 80 | proxy-sg | App traffic from proxy only |
| app-sg | in | 22 | proxy-sg | SSH via bastion only |
| app-sg | out | 80, 443 | 0.0.0.0/0 (via NAT) | Docker Hub / packages |

Ports 5000 (backend) and 5432 (PostgreSQL) are **never** opened in any security group.

## Other hardening included
- `admin_cidr` validation rejects `0.0.0.0/0`
- IMDSv2 required, encrypted gp3 volumes
- Private S3 bucket (public access blocked), least-privilege IAM (`s3:GetObject` on one object)
- DB on an `internal: true` Docker network
- DB password is a sensitive variable, written to a `chmod 600` `.env`

## Prerequisites
- AWS account + credentials configured (`aws configure`)
- Terraform >= 1.5
- An existing EC2 key pair in your target region
- Your public IP: `curl ifconfig.me`

## 1. Test locally (optional)
```bash
cd app
cp .env.example .env
docker compose up --build
# open http://localhost
```

## 2. Deploy to AWS
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit: key_name, admin_cidr, db_password, region
terraform init
terraform plan
terraform apply
```
Wait ~3–5 minutes after apply for Docker to build the containers, then open the `app_url` output.

## 3. Verify
```bash
curl http://<bastion_public_ip>/api/health        # {"status":"ok","db":true}
curl http://<bastion_public_ip>:22 --max-time 3   # not HTTP; confirm SSH is blocked from other IPs
ssh -i key.pem -J ec2-user@<bastion_public_ip> ec2-user@<app_private_ip>
sudo docker compose -f /opt/app/docker-compose.yml ps
sudo tail -f /var/log/app-bootstrap.log
```

## 4. Clean up (NAT gateway + EIPs cost money)
```bash
terraform destroy
```

## Notes
- Cost: the NAT Gateway (~$0.045/hr + data) is the main expense. Destroy when done.
- Changing files under `app/` and re-running `terraform apply` rebuilds the app instance.
- Production upgrades: ALB + 2 AZs, RDS instead of a containerized DB, Secrets Manager, HTTPS (ACM), SSM Session Manager instead of SSH.
- Troubleshooting: if the page shows 502, the app is still building; check `/var/log/app-bootstrap.log` on the private host.
