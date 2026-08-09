#!/bin/bash

# Define colors for terminal output
GREEN='\033[0;32m'
CYAN='\033[1;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
    echo -e "\n${YELLOW}[*] Shutting down and cleaning up resources...${NC}"
    kill $(jobs -p) 2>/dev/null
    pkill -f cloudflared 2>/dev/null
    echo -e "${GREEN}[*] Cloudflare Tunnel stopped.${NC}"
    echo -e "${GREEN}[*] Terminating Kasm workspace container...${NC}"
    docker rm -f cyber-lab > /dev/null 2>&1
    echo -e "${GREEN}✅ Cleanup complete. Environment safely destroyed!${NC}"
    exit 0
}

trap cleanup SIGINT SIGTERM

monitor_idle() {
    local IDLE_TIME=0
    local MAX_IDLE=900 # 15 minutes
    while true; do
        sleep 60
        CPU_LOAD=$(docker stats cyber-lab --no-stream --format "{{.CPUPerc}}" 2>/dev/null | sed 's/%//')
        IS_IDLE=$(echo "$CPU_LOAD" | awk '{if ($1 < 2.0) print 1; else print 0}')
        if [ "$IS_IDLE" -eq 1 ]; then
            IDLE_TIME=$((IDLE_TIME + 60))
            if [ "$IDLE_TIME" -ge "$MAX_IDLE" ]; then
                echo -e "\n\n${RED}⏰ [TIMEOUT] Container idle for 15 minutes (<2% CPU). Auto-cleaning...${NC}"
                kill -SIGTERM $$
                break
            fi
        else
            IDLE_TIME=0
        fi
    done
}

echo -e "${GREEN}[*] Initializing Automated Cyber Lab Deployment...${NC}"
docker rm -f cyber-lab > /dev/null 2>&1

mkdir -p /home/$USER/lab-data/persistent_data
chmod -R 777 /home/$USER/lab-data/persistent_data

echo -e "${GREEN}[*] Deploying Kasm workspace on port 8080...${NC}"
docker run -d --name cyber-lab \
  -p 8080:6901 \
  --shm-size=512m \
  -e VNC_PW=1234 \
  -v /home/$USER/lab-data/persistent_data:/persistent_data \
  kasmweb/desktop:1.15.0 > /dev/null

echo -e "${GREEN}[*] Verifying container startup...${NC}"
RUNNING=false
for i in {1..20}; do
    if [ "$(docker inspect -f '{{.State.Running}}' cyber-lab 2>/dev/null)" == "true" ]; then
        RUNNING=true
        break
    fi
    sleep 1
done

if [ "$RUNNING" != "true" ]; then
    echo -e "${RED}⚠️ Docker container failed to stay alive.${NC}"
    docker logs --tail 20 cyber-lab
    cleanup
fi

echo -e "${GREEN}[*] Configuring root access, tools & symlinks...${NC}"
docker exec -u 0 cyber-lab bash -c "
    echo 'root:1234' | chpasswd && \
    echo 'kasm-user:1234' | chpasswd && \
    mkdir -p /home/kasm-user/Desktop && \
    ln -sfn /persistent_data /home/kasm-user/Desktop/persistent_data && \
    chown -R kasm-user:kasm-user /home/kasm-user/Desktop /persistent_data && \
    rm -f /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nmap wireshark sqlmap hydra sudo onboard > /dev/null 2>&1 && \
    usermod -aG sudo kasm-user && \
    echo 'kasm-user ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
"

if ! command -v cloudflared &> /dev/null; then
    echo -e "${GREEN}[*] Installing Cloudflare Tunnel daemon...${NC}"
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    sudo dpkg -i cloudflared-linux-amd64.deb > /dev/null 2>&1
    rm -f cloudflared-linux-amd64.deb
fi

echo -e "${GREEN}[*] Waiting for Kasm internal web service to respond...${NC}"
for i in {1..30}; do
    if curl -k -s --connect-timeout 2 https://127.0.0.1:8080/#/login >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

echo -e "${GREEN}[*] Establishing Cloudflare HTTPS Tunnel...${NC}"
pkill -f cloudflared 2>/dev/null
> cloudflare-lab.log
nohup cloudflared tunnel --url https://127.0.0.1:8080 --no-tls-verify > cloudflare-lab.log 2>&1 &

echo -e "${GREEN}[*] Awaiting tunnel handshake...${NC}"
TUNNEL_URL=""
for i in {1..15}; do
    TUNNEL_URL=$(grep -aEo 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' cloudflare-lab.log | head -n 1)
    if [ -n "$TUNNEL_URL" ]; then
        break
    fi
    sleep 2
done

if [ -z "$TUNNEL_URL" ]; then
    echo -e "${RED}\n⚠️ ERROR: Tunnel failed to generate a URL. Check 'cat cloudflare-lab.log' for details.${NC}"
    cleanup
else
    echo ""
    echo "===================================================="
    echo -e "${GREEN}✅ CYBER LAB IS LIVE AND READY!${NC}"
    echo "===================================================="
    echo -e "🔗 GUI Access URL : ${CYAN}$TUNNEL_URL${NC}"
    echo -e "👤 Username       : kasm_user (or root)"
    echo -e "🔑 Password       : 1234"
    echo "===================================================="
    echo -e "💾 Persisted Dir  : ~/lab-data/persistent_data (Desktop Shortcut)"
    echo -e "💡 Note           : Passwordless 'sudo' access is enabled in GUI terminal!"
    echo ""
    echo -e "${YELLOW}⏳ Idle Monitor Active: Auto-shutdown triggers after 15m of low CPU (<2%).${NC}"
    echo -e "${YELLOW}>>> PRESS ANY KEY OR [CTRL+C] TO STOP THE LAB AND DESTROY ENVIRONMENT <<<${NC}"
    
    monitor_idle &
    
    # Clear residual keyboard buffer
    while read -e -t 0.1 -n 10000 discard; do : ; done 2>/dev/null
    
    # Wait for intentional key press
    read -n 1 -s -r
    cleanup
fi
