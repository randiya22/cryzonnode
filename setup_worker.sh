#!/bin/bash
set -e

NODE_NAME=$1
ONE_TIME_TOKEN=$2
NODE_SECRET=$3
MASTER_DOMAIN=$4

echo "=========================================="
echo "⚡ Installing LXD & Setting Up Node Agent"
echo "=========================================="

# 1. Update Packages & Install Dependencies + Python venv
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y curl python3 python3-pip python3-venv snapd

# Setup LXD
snap install lxd --channel=latest/stable || true
lxd init --auto || true

# 2. Setup Node Agent inside an isolated Virtual Environment
mkdir -p /opt/node_agent
cd /opt/node_agent

python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install fastapi uvicorn pylxd requests

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

# 3. Systemd Service targeting the Virtual Environment uvicorn
cat << EOF > /etc/systemd/system/node-agent.service
[Unit]
Description=LXC Node Agent Service
After=network.target

[Service]
Environment=NODE_SECRET=$NODE_SECRET
ExecStart=/opt/node_agent/venv/bin/uvicorn agent:app --host 0.0.0.0 --port 9090
WorkingDirectory=/opt/node_agent
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node-agent

# Get Public IP of worker node
WORKER_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')

# 4. Callback to Master Gateway
curl -s -X POST "$MASTER_DOMAIN/register_node" \
     -H "Content-Type: application/json" \
     -d "{\"node_name\": \"$NODE_NAME\", \"one_time_token\": \"$ONE_TIME_TOKEN\", \"node_agent_url\": \"http://$WORKER_IP:9090\", \"node_secret_token\": \"$NODE_SECRET\"}"

echo ""
echo "=========================================="
echo "✅ Node $NODE_NAME is registered and online!"
echo "=========================================="
