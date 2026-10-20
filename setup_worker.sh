#!/bin/bash
set -e

NODE_NAME=$1
ONE_TIME_TOKEN=$2
NODE_SECRET=$3
MASTER_DOMAIN=$4

echo "=========================================="
echo "⚡ Installing LXD & Setting Up Node Agent"
echo "=========================================="

# 1. Install Snap & LXD
sudo apt update -y
sudo apt install -y curl python3 python3-pip snapd
sudo snap install lxd --channel=latest/stable
sudo lxd init --auto

# 2. Setup Node Agent REST API
mkdir -p /opt/node_agent
cat << 'EOF' > /opt/node_agent/agent.py
from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel
import subprocess
import os

app = FastAPI()
NODE_SECRET = os.getenv("NODE_SECRET")

class ContainerReq(BaseModel):
    container_name: str
    ram_gb: int

@app.post("/containers/create")
def create_container(req: ContainerReq, x_node_token: str = Header(...)):
    if x_node_token != NODE_SECRET:
        raise HTTPException(status_code=401, detail="Unauthorized")
    
    ram = f"{req.ram_gb}GB"
    subprocess.run(["lxc", "launch", "ubuntu:24.04", req.container_name, "--config", f"limits.memory={ram}"], check=True)
    return {"status": "created", "ram": ram}
EOF

pip3 install fastapi uvicorn pylxd requests

# 3. Service Daemon Setup
cat << EOF > /etc/systemd/system/node-agent.service
[Unit]
Description=LXC Node Agent Service
After=network.target

[Service]
Environment=NODE_SECRET=$NODE_SECRET
ExecStart=/usr/local/bin/uvicorn agent:app --host 0.0.0.0 --port 9090
WorkingDirectory=/opt/node_agent
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node-agent

# Get Public IP of this worker node
WORKER_IP=$(curl -s https://api.ipify.org)

# 4. Ping Back to Master Cloudflare Gateway (botnode.cryzoncloud.fun)
curl -X POST "$MASTER_DOMAIN/register_node" \
     -H "Content-Type: application/json" \
     -d "{\"node_name\": \"$NODE_NAME\", \"one_time_token\": \"$ONE_TIME_TOKEN\", \"node_agent_url\": \"http://$WORKER_IP:9090\", \"node_secret_token\": \"$NODE_SECRET\"}"

echo ""
echo "=========================================="
echo "✅ Node $NODE_NAME is registered and online!"
echo "=========================================="
