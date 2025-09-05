# Cowrie SSH Honeypot + Port‑Knocking — Automated Setup Script

A one‑shot Bash script that installs and configures a **Cowrie SSH honeypot** and **port knocking** to hide your real SSH daemon. Attackers who hit TCP/22 get Cowrie; after you perform the knock sequence, TCP/22 is transparently redirected to your **real SSH port** (default `22222`) **for your IP only**. Includes systemd service, iptables persistence, and monthly log cleanup via logrotate.

---

## Features

* Automated install of Cowrie (Python venv), dependencies, and service files
* Listens on a dedicated honeypot port (`HONEYPOT_PORT`, default `2223`)
* NAT rules so **default inbound 22 → Cowrie**; port‑knock to flip **22 → real SSH** for your IP
* `knockd` configured with open/close sequences (customizable)
* `systemd` service for Cowrie (`cowrie.service`)
* `logrotate` policy for minimal retention (monthly truncate; no archives)
* Uses `iptables-persistent` to keep NAT rules across reboots

---

## Checklist (do this first)

**Avoid locking yourself out.**

1. **Move your real SSH daemon to `REAL_SSH_PORT` (default `22222`).**

   * Edit `/etc/ssh/sshd_config` and set:

     ```
     Port 22222
     # optionally keep a second line temporarily while migrating:
     # Port 22
     ```
   * Reload and test from **another terminal** before closing your current session:

     ```bash
     sudo systemctl restart ssh
     ssh -p 22222 user@server
     ```
   * Once confirmed, **remove** any leftover `Port 22` lines and restart SSH again.

2. Make sure you have **console/VM access** or a recovery path in case of firewall misconfigs.

3. If you already run UFW/Firewalld, ensure they won’t override the iptables rules placed by this script.

---

## 📦 What the script installs/configures

* Packages: `git python3 python3-venv python3-pip libssl-dev libffi-dev build-essential knockd iptables-persistent`
* User & directories: creates user `cowrie`, sets up `/opt/cowrie` and clones Cowrie there
* Python venv: `cowrie-env` with Cowrie requirements installed
* Cowrie config: copies `cowrie.cfg.dist → cowrie.cfg` and sets listen on `HONEYPOT_PORT`
* systemd unit: `/etc/systemd/system/cowrie.service` (enabled + started)
* logrotate: `/etc/logrotate.d/cowrie` with **monthly rotation, keep 0 archives** (minimize disk usage)
* iptables: flush NAT, set **PREROUTING** rule to redirect TCP/22 → `HONEYPOT_PORT` (default), drop direct access to `REAL_SSH_PORT`
* knockd: `/etc/knockd.conf` with **open** and **close** sequences; enabled on boot

---

## 🔧 Config Variables (edit at the top of the script)

```bash
REAL_SSH_PORT=22222       # your real SSH port (where sshd listens)
HONEYPOT_PORT=2223        # Cowrie honeypot listener port
KNOCK_SEQ_OPEN="1111,2222,3333"   # TCP knocks to OPEN real SSH (for your IP)
KNOCK_SEQ_CLOSE="3333,2222,1111"  # TCP knocks to CLOSE (back to honeypot)
COWRIE_USER="cowrie"              # dedicated system user for Cowrie
COWRIE_DIR="/opt/cowrie"          # install prefix
```

**Notes:**

* Knock sequences can be **any number of ports** separated by commas. More ports = harder to brute‑force. The script sets `seq_timeout = 5` seconds to complete the whole sequence.
* The knocks are **TCP SYN** (see `tcpflags = syn`). Use the client with **TCP mode**.
* Ensure your real `sshd` is already listening on `REAL_SSH_PORT` before running the script.

---

## 🚀 Quick Start

1. **Clone the repo** (use SSH if you’ve set up keys):

   ```bash
   git clone https://github.com/pb2106/Cowock.git
   cd Cowock
   ```
2. **Review & edit config** at the top of `cowock.sh` if desired.
3. **Run the installer**:

   ```bash
   sudo ./cowock.sh
   ```
4. **Test Cowrie service**:

   ```bash
   systemctl status cowrie
   tail -f /opt/cowrie/cowrie/var/log/cowrie/cowrie.log
   ```
5. **Open real SSH via knock (from your client machine):**

   * Install a knock client (Debian/Ubuntu: package name often `knockd`, provides `knock`).
   * Send the **open** sequence using **TCP**:

     ```bash
     knock -t <server-ip> 1111 2222 3333
     # now SSH to 22 goes to your REAL_SSH_PORT (22222) for YOUR IP
     ssh <user>@<server-ip>      # port 22 works for you
     # or explicitly:
     ssh -p 22 <user>@<server-ip>
     ```
6. **Close access** (flip 22 back to Cowrie for everyone):

   ```bash
   knock -t <server-ip> 3333 2222 1111
   ```

---

## 🧩 Service & Logs

**Cowrie**

```bash
sudo systemctl status cowrie
sudo systemctl restart cowrie

# Logs (plain and JSON)
ls -l /opt/cowrie/cowrie/var/log/cowrie/
 tail -f /opt/cowrie/cowrie/var/log/cowrie/cowrie.log
 tail -f /opt/cowrie/cowrie/var/log/cowrie/cowrie.json
```

**knockd**

```bash
sudo systemctl status knockd
sudo journalctl -u knockd -e
```

**iptables (NAT PREROUTING)**

```bash
sudo iptables -t nat -L PREROUTING -n --line-numbers
```

## 🧱 Log Rotation (minimal logs)

The script installs `/etc/logrotate.d/cowrie`:

```conf
/opt/cowrie/cowrie/var/log/cowrie/*.log /opt/cowrie/cowrie/var/log/cowrie/*.json {
    monthly
    rotate 0
    missingok
    notifempty
    create 0640 cowrie cowrie
    sharedscripts
    postrotate
        systemctl reload cowrie >/dev/null 2>&1 || true
    endscript
}
```

* `monthly` + `rotate 0` ≙ **no archives kept** (logs are truncated on rotation). Change to `rotate 12` + `compress` if you want a 1‑year history.

---

## 🔍 Troubleshooting

* **I locked myself out of SSH**

  * Use console/VM access. Temporarily disable NAT redirect:

    ```bash
    sudo iptables -t nat -F
    sudo netfilter-persistent save
    ```
  * Or manually point 22 → real SSH (until you fix knocking):

    ```bash
    sudo iptables -t nat -R PREROUTING 1 -p tcp --dport 22 -j REDIRECT --to-port 22222
    sudo netfilter-persistent save
    ```

* **Knock doesn’t open**

  * Ensure you used **TCP knocks**: `knock -t <ip> 7000 8000 9000`
  * Check that `knockd` is running and `tcpflags = syn` exists in `/etc/knockd.conf`.
  * Verify that the PREROUTING rule actually swaps for **your source IP** (`-s <your.ip>` appears after opening).

* **Cowrie won’t start**

  * Check `systemctl status cowrie` and `journalctl -u cowrie -e`.
  * Rebuild the venv as the `cowrie` user:

    ```bash
    sudo -u cowrie bash -lc '
      cd /opt/cowrie/cowrie && \
      rm -rf cowrie-env && \
      python3 -m venv cowrie-env && \
      cowrie-env/bin/pip install --upgrade pip && \
      cowrie-env/bin/pip install -r requirements.txt'
    sudo systemctl restart cowrie
    ```

* **Using nftables/UFW**

  * This script uses raw `iptables`. If your distro defaults to nftables, the `iptables` wrapper typically still works. Avoid mixing firewalls (e.g., UFW rules may override).

---

## ♻️ Updating Cowrie later

```bash
sudo -u cowrie bash -lc '
  cd /opt/cowrie/cowrie && git pull && \
  cowrie-env/bin/pip install -r requirements.txt'
sudo systemctl restart cowrie
```

---

## 🗑️ Uninstall / Rollback

```bash
# stop services
sudo systemctl disable --now cowrie knockd

# remove systemd unit
sudo rm -f /etc/systemd/system/cowrie.service
sudo systemctl daemon-reload

# clear NAT rules
sudo iptables -t nat -F
sudo netfilter-persistent save

# (optional) remove cowrie files and user
sudo rm -rf /opt/cowrie
sudo userdel -r cowrie 2>/dev/null || true
```

If you changed your SSH daemon to a non‑default port, remember to **restore** `Port 22` in `/etc/ssh/sshd_config` if desired.

---

## 🙌 Credits

* [Cowrie](https://github.com/cowrie/cowrie) — SSH/Telnet honeypot.
* This repo’s script wires Cowrie with port‑knocking and minimal‑log defaults for ease of deployment.
