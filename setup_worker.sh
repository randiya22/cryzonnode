#!/bin/bash
set -e

NODE_NAME=$1
ONE_TIME_TOKEN=$2
NODE_SECRET=$3
MASTER_DOMAIN=$4
DISK_GB=$5
AGENT_URL=$6

echo "=========================================="
echo "⚡ Installing LXD & Setting Up Node Agent"
echo "=========================================="

export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y curl python3 python3-pip python3-venv snapd

snap install lxd --channel=latest/stable || true
lxd init --auto || true

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

@app.delete("/containers/{container_name}")
def delete_container(container_name: str, x_node_token: str = Header(...)):
    if x_node_token != NODE_SECRET:
        raise HTTPException(status_code=401, detail="Unauthorized")
    subprocess.run(["lxc", "delete", container_name, "--force"])
    return {"status": "deleted"}

@app.delete("/containers/reset_all")
def reset_all(x_node_token: str = Header(...)):
    if x_node_token != NODE_SECRET:
        raise HTTPException(status_code=401, detail="Unauthorized")
    
    containers = subprocess.run(["lxc", "list", "-c", "n", "--format", "csv"], capture_output=True, text=True).stdout.splitlines()
    for c in containers:
        if c.strip():
            subprocess.run(["lxc", "delete", c.strip(), "--force"])
    return {"status": "wiped"}
EOF

cat << EOF > /etc/systemd/system/node-agent.service
[Unit]
Description=LXC Node Agent Service
After=network.target

[Service]
Environment=NODE_SECRET=$NODE_SECRET
ExecStart=/opt/node_agent/venv/bin/uvicorn agent:app --host 127.0.0.1 --port 9090
WorkingDirectory=/opt/node_agent
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node-agent

# Register back via Cloudflare Master Domain Gateway
curl -s -X POST "$MASTER_DOMAIN/register_node" \
     -H "Content-Type: application/json" \
     -d "{\"node_name\": \"$NODE_NAME\", \"one_time_token\": \"$ONE_TIME_TOKEN\", \"node_agent_url\": \"$AGENT_URL\", \"node_secret_token\": \"$NODE_SECRET\", \"disk_gb\": $DISK_GB}"

echo ""
echo "=========================================="
echo "✅ Node $NODE_NAME is registered and online!"
echo "=========================================="
