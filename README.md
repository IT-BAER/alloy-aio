# AIO Grafana Alloy Configuration for Cross-Platform Systems

<div align="center">

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Grafana Alloy](https://img.shields.io/badge/Grafana-Alloy-orange.svg)](https://grafana.com/docs/alloy/)
[![Loki Compatible](https://img.shields.io/badge/Loki-Compatible-blue.svg)](https://grafana.com/oss/loki/)
[![Prometheus Compatible](https://img.shields.io/badge/Prometheus-Compatible-red.svg)](https://prometheus.io/)
![GitHub stars](https://img.shields.io/github/stars/it-baer/alloy-aio?style=social)

**Cross-Platform Grafana Alloy Install & Configuration with Platform-Optimized Monitoring**

</div>

## 📑 Table of Contents

<p align="center">
  <a href="#-key-features">✨ Features</a> •
  <a href="#-quick-install">🚀 Install</a> •
  <a href="#-management">🛠️ Management</a> •
  <a href="#-troubleshooting">🚨 Troubleshooting</a> •
  <a href="#-tested-systems">🖥️ Tested</a> •
  <a href="#-security">🔒 Security</a> •
  <a href="#-learn-more">📚 More</a> •
  <a href="#-license">📄 License</a> •
  <a href="#-support-development">💜 Support</a> •
  <a href="#-credits">👏 Credits</a>
</p>

<br>

## ✨ Key Features

> **Automatic Detection:** Installer automatically detects system type (Standalone, Proxmox Host, VM/Container) and configures Logs + Metrics or Logs-Only mode accordingly.

### 🐧 Linux
- **Standalone/Host**: Full logs + metrics monitoring
- **Virtualized**: Logs-only monitoring (kernel limitations)
- **Optional override**: Add `--force` to install full logs + metrics on virtual servers (for example, VPS instances)

### 🪟 Windows
- **Physical/Host**: Full logs + metrics monitoring
- **Virtualized**: Logs-only monitoring

### 🏢 Proxmox Guest Metrics Exporter
- Automated, secure metrics exporter for Proxmox guests
- Zero-configuration setup with automatic API user/token management
- Exposes guest metrics at `http://localhost:9221/pve`

<br>

## 🚀 Quick Install

> **⚠️ WARNING:** Running installation scripts can overwrite existing Alloy configurations. Back up your configuration if you have made manual changes.


### 🐧 Linux (Standalone/Host)
```bash
# One-liner installation (replace URLs with your endpoints)
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/alloy_setup.sh)" -- --loki-url "https://loki.yourdomain.com/loki/api/v1/push" --prometheus-url "https://prometheus.yourdomain.com/api/v1/write"

# Force full install on virtual machines (VPS, cloud instances)
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/alloy_setup.sh)" -- --force --loki-url "https://loki.yourdomain.com/loki/api/v1/push" --prometheus-url "https://prometheus.yourdomain.com/api/v1/write"
```

### 🪟 Windows
```powershell
# One-liner installation (replace Loki & Prom URLs)
powershell -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://github.com/IT-BAER/alloy-aio/raw/main/alloy_setup_windows.ps1' -OutFile 'alloy_setup_windows.ps1'; .\alloy_setup_windows.ps1 -LokiUrl 'https://loki.yourdomain.com/loki/api/v1/push' -PrometheusUrl 'https://prometheus.yourdomain.com/api/v1/write'"
```

### 📟 Proxmox CT Mass Deployment
```bash
# Deploy to all running containers (replace Loki URL)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/proxmox_ct_deploy.sh)" -- --loki-url "https://loki.yourdomain.com/loki/api/v1/push"
```
```bash
# Deploy to specific container (replace Loki URL & Container ID)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/proxmox_ct_deploy.sh)" -- --loki-url "https://loki.yourdomain.com/loki/api/v1/push" --container 100
```

> **📦 OCI Container Support:** Proxmox OCI containers (Docker images converted to LXC) are automatically detected. System containers with systemd are supported; Alpine Linux and application containers (no init system) are auto-skipped with a warning. See [OCI Container Logging](#-oci-container-logging) for how to collect logs from these containers.

### 🤖 Proxmox VM Mass Deployment
> **Note:** Requires QEMU Guest Agent on target VMs.

```bash
# Deploy to all running VMs (replace Loki URL)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/proxmox_vm_deploy.sh)" -- --loki-url "https://loki.yourdomain.com/loki/api/v1/push"
```
```bash
# Deploy to specific VM (replace Loki URL & VM ID)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/proxmox_vm_deploy.sh)" -- --loki-url "https://loki.yourdomain.com/loki/api/v1/push" --vm 100
```

### 📦 OCI Container Logging

> **For Docker/OCI containers on Proxmox** that cannot run Alloy directly (Alpine, nginx, Redis, etc.)

OCI containers (Docker images running on Proxmox LXC) don't have systemd, so Alloy cannot be installed inside them. Instead, logs are collected via the **host's journald**:

**How it works:**
1. Container's stdout/stderr is redirected to syslog via a wrapper script
2. Syslog socket is bind-mounted from host into container (`/dev/log`)
3. Logs appear in host journald with custom tags (e.g., `ct122_nginx`)
4. Host Alloy collects logs via journald integration

**Automatic setup during mass deployment:**
```bash
# Deploy Alloy + setup OCI logging for incompatible containers
bash -c "$(curl -fsSL https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/proxmox_ct_deploy.sh)" -- --loki-url "https://loki.yourdomain.com/loki/api/v1/push" --setup-oci
```

**Manual setup for specific OCI container:**
```bash
# Setup logging for a single OCI container
sudo bash proxmox_oci_logging_setup.sh --container 122

# Setup logging for all OCI containers
sudo bash proxmox_oci_logging_setup.sh --all

# List OCI containers that need logging setup
sudo bash proxmox_oci_logging_setup.sh --list

# Custom log tag (default: ct<ID>_<app>)
sudo bash proxmox_oci_logging_setup.sh --container 122 --tag "my-nginx"

# Revert changes (remove logging setup)
sudo bash proxmox_oci_logging_setup.sh --container 122 --revert
```

**After setup, logs appear in host journald:**
```bash
# View logs from OCI container
journalctl -t ct122_nginx -f

# All OCI container logs
journalctl | grep "ct[0-9]*_"
```

> **Note:** The Proxmox host must have Alloy installed to forward these logs to Loki.
<br>

## 🛠️ Management

### 🐧 Linux Service Control
```bash
sudo systemctl status alloy     # Check status
sudo journalctl -u alloy -f     # View logs
sudo systemctl restart alloy    # Restart service
```

### 🪟 Windows Service Control
```powershell
Get-Service "Alloy"             # Check status
Restart-Service "Alloy"         # Restart service
```
<br>

## 🚨 Troubleshooting

### Common Issues

**Service won't start:**
```bash
# Linux
sudo systemctl status alloy
sudo journalctl -u alloy --no-pager

# Windows
Get-Service "Alloy"
Get-WinEvent -LogName Application -Source "Alloy" | Select-Object -First 10
```

**Prometheus is not showing metrics:**

Make sure you add ```--web.enable-remote-write-receiver``` as ARG on your Prometheus instance.

**Permission errors (Linux):**
```bash
sudo usermod -aG adm,systemd-journal alloy
sudo setfacl -R -m u:alloy:rx /var/log/
sudo systemctl restart alloy
```

**Permission denied for NEW log files (after Alloy installation):**

> **Note:** As of the latest version, a permission fixer timer is installed **by default** during setup. This timer runs hourly and automatically fixes permissions for any new log files. If you're still seeing permission errors, run the fixer manually once:

```bash
sudo /usr/local/bin/alloy-fix-permissions
```

When you install new applications (like CrowdSec, fail2ban, etc.) after Alloy is already installed, their log files won't automatically have the correct permissions. You'll see errors like:
```
failed to tail the file: open /var/log/crowdsec-firewall-bouncer.log: permission denied
```

**Quick fix for specific file:**
```bash
sudo setfacl -m u:alloy:r /var/log/crowdsec-firewall-bouncer.log
sudo systemctl restart alloy
```

**Fix all log files at once:**
```bash
# Using the permission fixer (installed by default at /usr/local/bin)
sudo /usr/local/bin/alloy-fix-permissions

# Or using the script from the repo
sudo bash alloy_fix_permissions.sh

# Or manually fix all logs
sudo setfacl -R -m u:alloy:rx /var/log/
sudo setfacl -R -d -m u:alloy:rx /var/log/
sudo systemctl restart alloy
```

**Check timer status:**
```bash
# Verify the permission fixer timer is running
sudo systemctl status alloy-fix-permissions.timer
```

**Validate configuration:**
```bash
# Linux
sudo alloy fmt --test /etc/alloy/aio-linux.alloy

# Windows (run as Administrator)
& "C:\Program Files\GrafanaLabs\Alloy\alloy-windows-amd64.exe" fmt "C:\Program Files\GrafanaLabs\Alloy\aio-windows.alloy" --test
```
<br>

## 🖥️ Tested Systems

| OS Family | Distribution | Version | Logs | Metrics | Status |
|-----------|--------------|---------|------|---------|--------|
| **Proxmox** | Proxmox VE (Host) | 8.4.1 | ✅ | ✅ | ✅ |
| **Debian** | Debian | 10+ | ✅ | ✅/❌¹ | ✅ |
| **Debian** | Ubuntu | 18.04+ | ✅ | ✅/❌¹ | ✅ |
| **RHEL** | RHEL/CentOS Stream | 8+ | ✅ | ✅/❌¹ | ✅ |
| **RHEL** | Rocky Linux | 8+ | ✅ | ✅/❌¹ | ✅ |
| **RHEL** | AlmaLinux | 8+ | ✅ | ✅/❌¹ | ✅ |
| **RHEL** | Fedora | 36+ | ✅ | ✅/❌¹ | ✅ |
| **SUSE** | openSUSE Leap | 15+ | ✅ | ✅/❌¹ | ✅ |
| **SUSE** | SLES | 15+ | ✅ | ✅/❌¹ | ✅ |
| **Windows** | Windows 10/11 | 10+ | ✅ | ✅/❌¹ | ✅ |
| **Windows** | Windows Server | 2016+ | ✅ | ✅/❌¹ | ✅ |

> ¹ Metrics disabled on virtualized systems (VMs/containers) due to kernel limitations. Use `--force` to override.

### ⚠️ Unsupported Systems

| System | Reason | Alternative |
|--------|--------|-------------|
| **Alpine Linux** | Uses OpenRC instead of systemd | Use [OCI Container Logging](#-oci-container-logging) |
| **Docker/OCI App Containers** | No init system (single-process) | Use [OCI Container Logging](#-oci-container-logging) |
| **Devuan** | Uses sysvinit/OpenRC instead of systemd | - |
| **Gentoo (OpenRC)** | OpenRC variant not supported | - |

> **Note:** Proxmox mass deployment scripts automatically detect and skip unsupported containers. Use `--setup-oci` to configure logging for OCI containers.

<br>

## 🔒 Security

### 🐧 Linux Security
- 🛡️ **Non-root operation**: Alloy runs as Dedicated User
- 🔐 **Minimal permissions**: ACL-based log access only
- 📁 **Secure configuration**: 640 Permissions on Config Files

<br>

## 📚 Learn More

- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/)
- [Loki Documentation](https://grafana.com/docs/loki/)
- [Prometheus Documentation](https://prometheus.io/docs/)

<br>

## 📄 License

This project is licensed under the [AGPL-3.0](LICENSE) license.

<br>

## 💜 Support Development

If this project helps you, consider supporting this and future work, which heavily relies on coffee:

<div align="center">
<a href="https://www.buymeacoffee.com/itbaer" target="_blank"><img src="https://github.com/user-attachments/assets/64107f03-ba5b-473e-b8ad-f3696fe06002" alt="Buy Me A Coffee" style="height: 60px; max-width: 217px;"></a>
<br>
<a href="https://www.paypal.com/donate/?hosted_button_id=5XXRC7THMTRRS" target="_blank">Donate via PayPal</a>
</div>

<br>

## 👏 Credits

- [Grafana Labs](https://grafana.com/) - For the amazing Grafana Alloy project
- [Grafana Community](https://grafana.com/community/) - For continuous support and feedback
