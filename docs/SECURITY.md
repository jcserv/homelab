```
# automated updates of packages
sudo apt install unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades


mkdir .ssh

# on client
scp id_ed25519.pub USER@<device>:/home/USER/.ssh/authorized_keys
chown -R USER:USER .ssh

sudo systemctl restart ssh

# verify it works FIRST!

sudo vi /etc/ssh/sshd_config

# set PermitRootLogin to no
# set PasswordAuthentication to no

sudo systemctl restart ssh
sudo apt install ufw

ss -ltpn
ip addr show

sudo ufw allow from 10.2.1.0/24 to any port 22 proto tcp comment 'ssh from trusted vlan'
sudo ufw allow from 10.2.1.0/24 to any port 22 proto tcp comment 'ssh from homelab vlan'
sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp comment 'ssh from tailscale'
sudo ufw allow 80
sudo ufw allow 443
sudo ufw allow from 10.2.1.0/24 comment 'local network traffic'
sudo ufw allow from 100.64.0.0/10 comment 'tailscale network'

sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw enable

sudo apt install fail2ban
sudo systemctl enable fail2ban --now
sudo systemctl status fail2ban
```

EVENTUALLY: 
- 2fa/sso
