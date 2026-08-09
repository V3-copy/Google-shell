#!/bin/bash

# Define colors for terminal output
GREEN='\033[0;32m'
CYAN='\033[1;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ==========================================
# CLEANUP FUNCTION (Triggered by Keypress/Ctrl+C/Timeout)
# ==========================================
cleanup() {
    echo -e "\n${YELLOW}[*] Shutting down and cleaning up resources...${NC}"
    
    # Kill background jobs and tunnel
    kill $(jobs -p) 2>/dev/null
    pkill -f cloudflared 2>/dev/null
    echo -e "${GREEN}[*] Cloudflare Tunnel stopped.${NC}"
    
    # Destroy container
    echo -e "${GREEN}[*] Terminating Kasm workspace container...${NC}"
    docker rm -f cyber-lab > /dev/null 2>&1
    
    echo -e "${GREEN}✅ Cleanup complete. Environment safely destroyed!${NC}"
    exit 0
}

trap cleanup SIGINT SIGTERM

# ==========================================
# IDLE MONITOR FUNCTION (15 min auto-teardown)
# ==========================================
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

# ==========================================
# MAIN DEPLOYMENT LOGIC
# ==========================================
echo -e "${GREEN}[*] Initializing Automated Cyber Lab Deployment...${NC}"

# Step 1: Clean up previous instances
docker rm -f cyber-lab > /dev/null 2>&1

# Step 2: Ensure persistent directory exists with open write permissions
mkdir -p /home/$USER/lab-data/kasm_home
chmod 777 /home/$USER/lab-data/kasm_home

# Step 3: Deploy Kasm Container
echo -e "${GREEN}[*] Launching Kasm workspace container...${NC}"
docker run -d --name cyber-lab \
  -p 8080:6901 \
  --shm-size=512m \
  -e VNC_PW=12345678 \
  -v /home/$USER/lab-data/kasm_home:/home/kasm-user \
  --privileged kasmweb/desktop:1.15.0 > /dev/null

# Step 4: Verify Container is Actively Running
echo -e "${GREEN}[*] Verifying container initialization...${NC}"
CONTAINER_READY=false
for i in {1..20}; do
    if [ "$(docker inspect -f '{{.State.Running}}' cyber-lab 2>/dev/null)" == "true" ]; then
        CONTAINER_READY=true
        break
    fi
    sleep 1
done

if [ "$CONTAINER_READY" != "true" ]; then
    echo -e "${RED}⚠️ Docker container failed to stay alive. Container logs:${NC}"
    docker logs --tail 20 cyber-lab
    cleanup
fi

# Step 5: Wait for Kasm VNC service to initialize before exec
echo -e "${GREEN}[*] Waiting for Kasm desktop core services to boot...${NC}"
for i in {1..30}; do
    if curl -k -s -o /dev/null --connect-timeout 2 https://127.0.0.1:8080; then
        echo -e "${GREEN}[*] Kasm web engine is live and healthy!${NC}"
        break
    fi
    sleep 2
done

# Step 6: Configure root access, passwordless sudo, and security tools
echo -e "${GREEN}[*] Configuring root access & installing pentesting tools...${NC}"
docker exec -u 0 cyber-lab bash -c "
    echo 'root:12345678' | chpasswd && \
    echo 'kasm-user:12345678' | chpasswd && \
    rm -f /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nmap wireshark sqlmap hydra sudo onboard > /dev/null 2>&1 && \
    usermod -aG sudo kasm-user && \
    echo 'kasm-user ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
"

# Step 7: Verify and install cloudflared
if ! command -v cloudflared &> /dev/null; then
    echo -e "${GREEN}[*] Installing Cloudflare Tunnel daemon...${NC}"
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    sudo dpkg -i cloudflared-linux-amd64.deb > /dev/null 2>&1
    rm -f cloudflared-linux-amd64.deb
fi

# Step 8: Establish HTTPS tunnel
echo -e "${GREEN}[*] Establishing Cloudflare HTTPS Tunnel...${NC}"
pkill -f cloudflared 2>/dev/null
> cloudflare-lab.log
nohup cloudflared tunnel --url https://127.0.0.1:8080 --no-tls-verify > cloudflare-lab.log 2>&1 &

echo -e "${GREEN}[*] Awaiting tunnel handshake...${NC}"
TUNNEL_URL=""
for i in {1..20}; do
    TUNNEL_URL=$(grep -aEo 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' cloudflare-lab.log | head -n 1)
    if [ -n "$TUNNEL_URL" ]; then
        break
    fi
    sleep 2
done

# Step 9: Print Dashboard & Block until Keypress
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
    echo -e "🔑 Password       : 12345678"
    echo "===================================================="
    echo -e "💾 Persisted Dir  : ~/lab-data/kasm_home (Full Home & GUI Configs)"
    echo -e "💡 Note           : Passwordless 'sudo' access is enabled in GUI terminal!"
    echo ""
    echo -e "${YELLOW}⏳ Idle Monitor Active: Auto-shutdown triggers after 15m of low CPU (<2%).${NC}"
    echo -e "${YELLOW}>>> PRESS ANY KEY OR [CTRL+C] TO STOP THE LAB AND DESTROY ENVIRONMENT <<<${NC}"
    
    monitor_idle &
    
    # Flush any previous buffered keystrokes so it doesn't close prematurely
    while read -e -t 0.1 -n 10000 discard; do : ; done 2>/dev/null
    
    # Wait for deliberate keypress to tear down
    read -n 1 -s -r
    cleanup
fi
