#!/bin/bash
set -e

# ---------- CONFIG ----------
REAL_SSH_PORT=22222       # your real SSH port
HONEYPOT_PORT=2223        # Cowrie will listen here
KNOCK_SEQ_OPEN="7000,8000,9000"
KNOCK_SEQ_CLOSE="9000,8000,7000"
COWRIE_USER="cowrie"
COWRIE_DIR="/opt/cowrie"
# ----------------------------

echo "📦 Installing dependencies..."
sudo apt update
sudo apt install -y git python3 python3-venv python3-pip libssl-dev libffi-dev build-essential knockd iptables-persistent

# ---------------- Cowrie Setup ----------------
if ! id -u $COWRIE_USER >/dev/null 2>&1; then
    echo "👤 Creating user: $COWRIE_USER"
    sudo adduser --disabled-password --gecos "" $COWRIE_USER
fi

echo "📂 Setting up Cowrie in $COWRIE_DIR ..."
sudo mkdir -p $COWRIE_DIR
sudo chown -R $COWRIE_USER:$COWRIE_USER $COWRIE_DIR

if [ ! -d "$COWRIE_DIR/cowrie" ]; then
    sudo -u $COWRIE_USER git clone https://github.com/cowrie/cowrie $COWRIE_DIR/cowrie
fi

cd $COWRIE_DIR/cowrie
sudo -u $COWRIE_USER python3 -m venv cowrie-env
sudo -u $COWRIE_USER cowrie-env/bin/pip install --upgrade pip
sudo -u $COWRIE_USER cowrie-env/bin/pip install -r requirements.txt

echo "⚙️ Configuring Cowrie to run on port $HONEYPOT_PORT ..."
sudo -u $COWRIE_USER cp cowrie.cfg.dist cowrie.cfg
sudo -u $COWRIE_USER sed -i "s/^listen_endpoints =.*/listen_endpoints = tcp:$HONEYPOT_PORT:interface=0.0.0.0/" cowrie.cfg

# ---------------- Cowrie systemd Service ----------------
echo "📝 Creating Cowrie systemd service..."
sudo tee /etc/systemd/system/cowrie.service > /dev/null <<EOF
[Unit]
Description=Cowrie SSH/Telnet Honeypot
After=network.target

[Service]
User=$COWRIE_USER
WorkingDirectory=$COWRIE_DIR/cowrie
ExecStart=$COWRIE_DIR/cowrie/cowrie-env/bin/python $COWRIE_DIR/cowrie/src/cowrie/main.py start
ExecStop=$COWRIE_DIR/cowrie/cowrie-env/bin/python $COWRIE_DIR/cowrie/src/cowrie/main.py stop
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cowrie
sudo systemctl start cowrie

# ---------------- Logrotate for Cowrie ----------------
echo "🗑️ Setting up monthly log cleanup for Cowrie..."
sudo tee /etc/logrotate.d/cowrie > /dev/null <<EOF
$COWRIE_DIR/cowrie/var/log/cowrie/*.log $COWRIE_DIR/cowrie/var/log/cowrie/*.json {
    monthly
    rotate 0
    missingok
    notifempty
    create 0640 $COWRIE_USER $COWRIE_USER
    sharedscripts
    postrotate
        systemctl reload cowrie >/dev/null 2>&1 || true
    endscript
}
EOF

# ---------------- iptables + knockd ----------------
echo "⚙️ Setting up iptables rules..."

# Flush old rules
sudo iptables -F
sudo iptables -t nat -F

# Default: send port 22 traffic → Cowrie
sudo iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port $HONEYPOT_PORT

# Drop direct access to real SSH port (hidden)
sudo iptables -A INPUT -p tcp --dport $REAL_SSH_PORT -j DROP

echo "💾 Saving iptables rules..."
sudo netfilter-persistent save

echo "⚙️ Writing knockd configuration..."
sudo tee /etc/knockd.conf > /dev/null <<EOF
[options]
    UseSyslog

[openSSH]
    sequence    = $KNOCK_SEQ_OPEN
    seq_timeout = 5
    command     = /sbin/iptables -t nat -R PREROUTING 1 -p tcp --dport 22 -s %IP% -j REDIRECT --to-port $REAL_SSH_PORT
    tcpflags    = syn

[closeSSH]
    sequence    = $KNOCK_SEQ_CLOSE
    seq_timeout = 5
    command     = /sbin/iptables -t nat -R PREROUTING 1 -p tcp --dport 22 -j REDIRECT --to-port $HONEYPOT_PORT
    tcpflags    = syn
EOF

echo "📝 Enabling knockd..."
sudo sed -i 's/^START_KNOCKD=.*/START_KNOCKD=1/' /etc/default/knockd
sudo sed -i 's|^KNOCKD_OPTS=.*|KNOCKD_OPTS="-i any"|' /etc/default/knockd

sudo systemctl enable knockd
sudo systemctl restart knockd

echo "✅ Setup complete!"
echo "🔒 Default: attackers hitting port 22 see Cowrie."
echo "🔑 Run: knock <server-ip> $KNOCK_SEQ_OPEN   → port 22 goes to REAL SSH ($REAL_SSH_PORT) for your IP."
echo "❌ Run: knock <server-ip> $KNOCK_SEQ_CLOSE  → port 22 goes back to Cowrie honeypot."
