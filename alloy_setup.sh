#!/bin/bash
# =============================================================================
# Grafana Alloy Installation Script for Linux Systems
# =============================================================================
#
# This script installs and configures Grafana Alloy for Linux systems using predefined configuration files from the repository.
#
# Automatic configuration selection based on system type:
#   - Standalone Linux: Full observability (logs + metrics)
#   - Proxmox VE Host: Full observability (logs + metrics)
#   - Proxmox VMs/Containers: Logs-only
#
# Note: Proxmox host metrics are collected by Alloy directly. Guest metrics are collected via pve-guest-exporter Service.
#
# Compatible with:
#   - Linux: Debian 10+, Ubuntu 18.04+
# Requirements: sudo access, internet connection
#
# Configuration files:
#   - Standalone Linux & Proxmox VE Host: aio-linux.alloy (logs + metrics)
#   - Proxmox VMs/Containers: aio-linux-logs.alloy (logs only)
#
# Note: For Windows installation, use the PowerShell script: alloy_setup_windows.ps1
# =============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Set non-interactive mode to prevent prompts
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ALLOY_CONFIG_PATH="/etc/alloy"

# Determine config filename from URL or default
get_config_filename() {
    local url="$1"
    # Extract filename from URL (after last slash)
    basename "$url"
}

ALLOY_CONFIG_FILE=""
GRAFANA_GPG_KEY_URL="https://apt.grafana.com/gpg.key"
GRAFANA_REPO_URL="https://apt.grafana.com"

# Cleanup function to revert needrestart modification
cleanup() {
    local needrestart_conf="/etc/needrestart/conf.d/50-alloy-setup.conf"
    if [[ -f "$needrestart_conf" ]]; then
        rm -f "$needrestart_conf"
        log_success "Cleanup completed."
    fi
}

# Trap for interruption and termination
trap 'log_error "Script interrupted by user (Ctrl+C)"; cleanup; exit 130' INT
trap 'log_error "Script terminated"; cleanup; exit 143' TERM
trap 'cleanup' EXIT

# Default configuration file paths (local, after git clone)
# Handle case when script is executed via curl (dirname "$0" would fail)
if [[ -f "$0" ]]; then
    DEFAULT_STANDALONE_CONFIG_PATH="$(dirname "$0")/aio-linux.alloy"
    DEFAULT_PROXMOX_CONFIG_PATH="$(dirname "$0")/aio-linux-logs.alloy"
else
    # Fallback URLs for when script is executed via curl
    DEFAULT_STANDALONE_CONFIG_PATH="https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/aio-linux.alloy"
    DEFAULT_PROXMOX_CONFIG_PATH="https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/aio-linux-logs.alloy"
fi

# User-provided endpoints (can be set via command line)
LOKI_URL=""
PROMETHEUS_URL=""
FORCE_FULL_INSTALL=false

# Platform detection
IS_LINUX=false

# Minimal logging for user-facing output
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}
log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}
log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}
log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}
# Spinner for long-running commands
run_with_spinner() {
    local cmd="$1"
    local msg="$2"
    local pid spinner delay spinstr status
    eval "$cmd" &
    pid=$!
    spinner=("|" "/" "-" "\\")
    delay=0.1
    i=0
    tput civis 2>/dev/null || true
    printed=0
    while kill -0 $pid 2>/dev/null; do
        printf "\r${BLUE}[INFO]${NC} $msg %s" "${spinner[$i]}"
        i=$(( (i+1) % 4 ))
        sleep $delay
        printed=1
    done
    wait $pid
    status=$?
    # If the command was too fast, print at least one [INFO] line
    if [[ $printed -eq 0 ]]; then
        printf "\r${BLUE}[INFO]${NC} $msg ..."
    fi
    printf "\r${BLUE}[INFO]${NC} $msg    \n"
    tput cnorm 2>/dev/null || true
    return $status
}

# Function to automatically add spinner for operations that might take longer than 500ms
auto_spinner() {
    local msg="$1"
    local cmd="$2"
    
    # For simple log messages, just output them directly
    if [[ -z "$cmd" ]]; then
        log "$msg"
        return 0
    fi
    
    # For commands, check if they're likely to take a long time
    case "$cmd" in
        # These commands are likely to be fast
        "mkdir"*)
            if [[ "$msg" == *"Creating"* ]] || [[ "$msg" == *"Creating system user"* ]]; then
                # User creation might take time
                run_with_spinner "$cmd" "$msg"
            else
                # Simple mkdir operations are fast
                log "$msg"
                eval "$cmd" || return $?
                log_success "${msg%...}"
            fi
            ;;
        "echo"*)
            # Echo commands are fast
            log "$msg"
            eval "$cmd" || return $?
            ;;
        "cat"*)
            # Cat commands are usually fast
            log "$msg"
            eval "$cmd" || return $?
            ;;
        "grep"*)
            # Grep commands are usually fast
            log "$msg"
            eval "$cmd" || return $?
            ;;
        "chmod"*|"chown"*)
            # Permission commands are usually fast
            log "$msg"
            eval "$cmd" || return $?
            log_success "${msg%...}"
            ;;
        *)
            # For other commands, use the spinner
            run_with_spinner "$cmd" "$msg"
            ;;
    esac
}

# Error handler
error_exit() {
    log_error "$1"
    exit 1
}

# Show usage information
show_usage() {
    echo "============================================="
    echo "    Grafana Alloy Linux Installation Script"
    echo "============================================="
    echo
    echo "Linux installation script with automatic configuration selection:"
    echo "  • Standalone Linux: Full observability (logs + metrics)"
    echo "  • Proxmox VE Host: Full observability (logs + metrics)"
    echo "  • Proxmox VMs/Containers: Logs-only (lightweight configuration)"
    echo
    echo "Usage:"
    echo "  $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -l, --loki-url URL           Loki endpoint URL"
    echo "  -c, --config-url URL         Custom configuration file URL"
    echo "  -p, --prometheus-url URL     Prometheus endpoint URL"
    echo "  -f, --force                  Force full observability install (ignore virtualization detection)"
    echo
    echo "Examples:"
    echo "  # Basic Linux installation (auto-detects system type):"
    echo "  sudo $0"
    echo
    echo "  # With custom Loki endpoint:"
    echo "  sudo $0 --loki-url 'https://loki.example.com/loki/api/v1/push'"
    echo
    echo "  # With custom configuration URL:"
    echo "  sudo $0 --config-url 'https://example.com/custom-config.alloy'"
    echo
    echo "Automatic configuration selection:"
    echo "  • Standalone Linux & Proxmox VE Host: aio-linux.alloy (logs + metrics)"
    echo "  • Proxmox VMs & Containers: aio-linux-logs.alloy (logs only)"
    echo "  • All configs pulled from: https://github.com/IT-BAER/alloy-aio"
    echo
    echo "Note: Proxmox host metrics are collected by Alloy directly. Guest metrics and prometheus-pve-exporter are not supported."
    echo
    echo "Note: For Windows installation, use the PowerShell script:"
    echo "      alloy_setup_windows.ps1"
    echo
}

# Configure non-interactive package handling
configure_noninteractive_mode() {
    # Create needrestart configuration directory if it exists
    if [[ -d /etc/needrestart ]] || mkdir -p /etc/needrestart/conf.d/; then
        cat > /etc/needrestart/conf.d/50-alloy-setup.conf << 'EOF'
# Automatic restart configuration for Alloy setup
# Restart services automatically without prompting
$nrconf{restart} = 'a';
EOF
    fi
    # Set debconf to non-interactive mode
    echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
    # Configure apt to not prompt for service restarts
    mkdir -p /etc/apt/apt.conf.d/
    cat > /etc/apt/apt.conf.d/50-alloy-setup << 'EOF'
// Automatic service restart configuration for Alloy setup
Dpkg::Options {
   "--force-confdef";
   "--force-confold";
}
DPkg::Post-Invoke { "test -f /var/run/reboot-required && echo 'Reboot required' || true"; };
EOF
    log_success "Non-interactive mode configured"
}

# Check if running with appropriate privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root (use sudo)"
    fi
}

# Check system compatibility
check_system() {
    # Only support Linux
    if [[ -f /etc/os-release ]]; then
        IS_LINUX=true
        source /etc/os-release
        case "$ID" in
            "debian"|"ubuntu")
                :
                ;;
            *)
                log_error "Unsupported Linux OS: $PRETTY_NAME. This script supports Debian and Ubuntu only."
                exit 1
                ;;
        esac
    else
        log_error "Cannot determine OS or unsupported system."
        log_error "This script only supports Debian and Ubuntu Linux systems."
        exit 1
    fi
}

# Detect if running on Proxmox VE host or in Proxmox container/VM
detect_proxmox() {
    IS_PROXMOX_HOST=false
    # Check for Proxmox VE host specific indicators
    if [[ -f /etc/pve/local/pve-ssl.pem ]] || \
       [[ -d /etc/pve ]] || \
       command -v pvesh >/dev/null 2>&1 || \
       systemctl is-active --quiet pve-cluster 2>/dev/null; then
        IS_PROXMOX_HOST=true
        export SYSTEM_TYPE="proxmox-host"
        export PROXMOX_NODE="$(hostname)"
        # Capture Proxmox version if available (local variable)
        local proxmox_version=""
        if command -v pveversion >/dev/null 2>&1; then
            proxmox_version="$(pveversion 2>/dev/null || true)"
        fi        
    elif [[ -f /proc/1/environ ]] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        IS_PROXMOX_HOST=true
        export SYSTEM_TYPE="proxmox-container"
    elif command -v systemd-detect-virt >/dev/null 2>&1; then
        local virt_type=$(systemd-detect-virt 2>/dev/null || echo "none")
        case "$virt_type" in
            "lxc")
                IS_PROXMOX_HOST=true
                export SYSTEM_TYPE="proxmox-container"
                ;;
            "kvm"|"qemu")
                IS_PROXMOX_HOST=true
                export SYSTEM_TYPE="proxmox-vm"
                ;;
            *)
                export SYSTEM_TYPE="standalone"
                ;;
        esac
    else
        export SYSTEM_TYPE="standalone"
    fi
    export IS_PROXMOX_HOST
    # Export a normalized PROXMOX_VERSION for use elsewhere in the script
    # If proxmox_version is empty, PROXMOX_VERSION will be empty as well
    export PROXMOX_VERSION="$proxmox_version"
    export DETECTED_SYSTEM_TYPE="$SYSTEM_TYPE"
}


# Compare Proxmox version numbers: returns 0 (true) if PROXMOX_VERSION >= argument
# Usage: proxmox_version_ge 9
proxmox_version_ge() {
    local target="$1"
    # If PROXMOX_VERSION is empty, treat as not greater/equal
    if [[ -z "${PROXMOX_VERSION:-}" ]]; then
        return 1
    fi
    # Extract the major version number (digits before first non-digit)
    local major
    major=$(echo "$PROXMOX_VERSION" | sed -n 's/^[^0-9]*\([0-9]\+\).*/\1/p' || true)
    if [[ -z "$major" ]]; then
        return 1
    fi
    if [[ $major -ge $target ]]; then
        return 0
    else
        return 1
    fi
}

# Update package lists
update_packages() {
    # Only run update if it hasn't been run recently (in the last hour)
    local apt_lists="/var/lib/apt/lists"
    if [[ -d "$apt_lists" ]]; then
        local last_update=$(stat -c %Y "$apt_lists" 2>/dev/null || echo 0)
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_update))
        
        # If lists are older than 1 hour (3600 seconds), update them
        if [[ $time_diff -gt 3600 ]]; then
            run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null 2>&1" "Updating package lists..." || error_exit "Failed to update package lists"
            log_success "Package lists updated"
        else
            log "Package lists are recent, skipping update"
        fi
    else
        run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null 2>&1" "Updating package lists..." || error_exit "Failed to update package lists"
        log_success "Package lists updated"
    fi
}


# Install prerequisites
install_prerequisites() {
    # Only install essential system packages for Python and system utilities
    # Application dependencies (flask, requests, gunicorn) are installed in the virtualenv below
    # Skip Python/venv/exporter dependencies for virtualized/container systems (logs only)
    if [[ "$SYSTEM_TYPE" == "proxmox-container" || "$SYSTEM_TYPE" == "proxmox-vm" ]]; then
        local user_packages=("gpg" "wget" "systemd" "acl")
        local dpkg_packages=("gnupg" "wget" "systemd" "acl")
    else
        local user_packages=("gpg" "wget" "systemd" "acl" "python3" "python3-venv")
        local dpkg_packages=("gnupg" "wget" "systemd" "acl" "python3" "python3-venv")
    fi
    local n=${#user_packages[@]}
    for ((i=0; i<n; i++)); do
        local user_name="${user_packages[$i]}"
        local dpkg_name="${dpkg_packages[$i]}"
        if dpkg-query -W -f='${Status}' $dpkg_name 2>/dev/null | grep -q "install ok installed"; then
            log_success "$user_name is already installed"
        else
            run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\" $dpkg_name > /dev/null 2>&1" "Installing $user_name..." || error_exit "Failed to install $user_name"
            log_success "$user_name installed successfully"
        fi
    done

    # For Proxmox hosts only, create a virtualenv for the exporter and install dependencies with pip
    if [[ "$SYSTEM_TYPE" == "proxmox-host" ]]; then
        local venv_dir="/etc/alloy/pve-guest-exporter/pve-guest-exporter-venv"
        if [[ ! -d "$venv_dir" ]]; then
            run_with_spinner "python3 -m venv $venv_dir" "Creating Python virtualenv for exporter..." || error_exit "Failed to create virtualenv for exporter"
        fi
        # Use the virtualenv's pip to install dependencies (best practice)
        run_with_spinner "$venv_dir/bin/pip install --upgrade pip > /dev/null 2>&1 && $venv_dir/bin/pip install gunicorn flask requests > /dev/null 2>&1" "Installing gunicorn, flask, requests in exporter virtualenv..." || error_exit "Failed to install gunicorn/flask/requests in exporter virtualenv"
        log_success "gunicorn, flask, requests installed in exporter virtualenv ($venv_dir)"
    fi
    log_success "Prerequisites installed"
}

# Setup Grafana repository
setup_grafana_repo() {
    log "Setting up Grafana repository..."
    
    # Create keyrings directory
    mkdir -p /etc/apt/keyrings/ || error_exit "Failed to create keyrings directory"
    
    # Download and install GPG key
    log "Downloading Grafana GPG key..."
    if ! wget -q -O - "$GRAFANA_GPG_KEY_URL" | gpg --dearmor | tee /etc/apt/keyrings/grafana.gpg > /dev/null; then
        error_exit "Failed to download or install Grafana GPG key"
    fi
    
    # Add repository
    log "Adding Grafana repository..."
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] $GRAFANA_REPO_URL stable main" | tee /etc/apt/sources.list.d/grafana.list > /dev/null || error_exit "Failed to add Grafana repository"
    
    # Update package lists with new repository (single update after all repos are configured)
    log "Updating package lists after all repositories are configured..."
    run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null 2>&1" "Updating package lists..." || error_exit "Failed to update package lists after adding Grafana repository"
    log_success "Grafana repository configured and package lists updated"
}

# Install Grafana Alloy
install_alloy() {
    log "Installing Grafana Alloy on Linux..."
    if run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\" alloy > /dev/null 2>&1" "Installing Grafana Alloy..."; then
        log_success "Grafana Alloy installed successfully"
    else
        error_exit "Failed to install Grafana Alloy"
    fi
    
    # Verify installation
    if command -v alloy &> /dev/null; then
        local version=$(alloy --version 2>&1 | head -n1 || echo "Unknown")
        log_success "Alloy installation verified: $version"
    else
        error_exit "Alloy installation verification failed"
    fi
}

# Install prometheus-pve-exporter for Proxmox guest metrics

# Ensure alloy system user exists
ensure_alloy_user() {
    if id "alloy" &>/dev/null; then
        log_success "alloy user already exists"
    else
        log "Creating system user: alloy"
        useradd --system --no-create-home --shell /usr/sbin/nologin alloy
        log_success "alloy system user created"
    fi
}

# Configure user permissions using ACL
setup_permissions() {
	ensure_alloy_user
	
	if command -v setfacl &> /dev/null; then
		log "Configuring ACL permissions for log files (current and future)..."
		
		# Grant read+execute access to /var/log directory for traversal
		run_with_spinner "setfacl -m u:alloy:rx /var/log/ > /dev/null 2>&1" "Setting ACL permissions for /var/log..." || error_exit "Failed to set ACL permissions for /var/log"
		
		# Grant read+execute access to all existing files and directories recursively
		# (directories need 'x' for traversal, files will ignore 'x' for reading)
		run_with_spinner "setfacl -R -m u:alloy:rx /var/log/ > /dev/null 2>&1" "Setting recursive ACL permissions for /var/log..." || error_exit "Failed to set recursive ACL permissions for /var/log"
		
		# Set default ACL on /var/log and all subdirectories so new files/directories 
		# automatically inherit alloy:rx permissions
		run_with_spinner "setfacl -d -m u:alloy:rx /var/log/ > /dev/null 2>&1" "Setting default ACL permissions for /var/log..." || error_exit "Failed to set default ACL permissions for /var/log"
		run_with_spinner "setfacl -R -d -m u:alloy:rx /var/log/ > /dev/null 2>&1" "Setting recursive default ACL permissions for /var/log..." || error_exit "Failed to set recursive default ACL permissions for /var/log"
		
		log_success "ACL permissions configured for current and future log files"
		
		# Verify ACL setup
		if getfacl /var/log 2>/dev/null | grep -q "user:alloy:r-x"; then
			log_success "✓ ACL verification: alloy user has access to /var/log"
		else
			log_warning "⚠ ACL verification: Could not verify alloy user access"
		fi
		
	else
		log_warning "setfacl command not available - ACL permissions cannot be configured"
		log_warning "Install 'acl' package: apt-get install acl"
	fi
	
	log_success "User permissions configured using ACL-only approach"
}


# Deploy configuration
deploy_configuration() {
    log "Deploying Linux configuration..."
    
    # Create configuration directory
    mkdir -p "$ALLOY_CONFIG_PATH" || error_exit "Failed to create configuration directory"
    
    local config_deployed=false
    # Determine which configuration to use based on system type
    if [[ "$SYSTEM_TYPE" == "proxmox-container" ]] || [[ "$SYSTEM_TYPE" == "proxmox-vm" ]]; then
        # Virtualized environments (containers/VMs) use logs-only config
        config_path="$DEFAULT_PROXMOX_CONFIG_PATH"
        log "Detected virtualized environment ($SYSTEM_TYPE) - using logs-only configuration"
    else
        # Standalone Linux systems and Proxmox hosts use full config (logs + metrics)
        config_path="$DEFAULT_STANDALONE_CONFIG_PATH"
        if [[ "$SYSTEM_TYPE" == "proxmox-host" ]]; then
            log "Detected Proxmox VE host - using full configuration (logs + metrics)"
        else
            log "Detected standalone Linux system - using full configuration (logs + metrics)"
        fi
    fi

    # Determine config filename and path
    local config_filename
    config_filename=$(basename "$config_path")
    ALLOY_CONFIG_FILE="$ALLOY_CONFIG_PATH/$config_filename"

    log "Copying configuration from: $config_path"
    # Check if config_path is a URL or local file
    if [[ "$config_path" == https://* ]] || [[ "$config_path" == http://* ]]; then
        # Download from URL
        if run_with_spinner "wget -q -O \"$ALLOY_CONFIG_FILE\" \"$config_path\"" "Downloading configuration file..."; then
            log_success "Configuration downloaded successfully as $ALLOY_CONFIG_FILE"
            config_deployed=true
        else
            log_error "Failed to download configuration from $config_path"
            error_exit "Configuration deployment failed - download failed"
        fi
    else
        # Copy local file
        if run_with_spinner "cp \"$config_path\" \"$ALLOY_CONFIG_FILE\"" "Copying configuration file..."; then
            log_success "Configuration copied successfully as $ALLOY_CONFIG_FILE"
            config_deployed=true
        else
            log_error "Failed to copy configuration from local repository"
            log_error "Please check that you have cloned the repository and all files are present"
            error_exit "Configuration deployment failed - file missing"
        fi
    fi
    
    if [[ "$config_deployed" == true ]]; then
        # Format the configuration file
        if command -v alloy &> /dev/null; then
            log "Formatting configuration file..."
            if alloy fmt --write "$ALLOY_CONFIG_FILE" 2>/dev/null; then
                log_success "Configuration file formatted successfully"
            else
                log_warning "Could not format configuration file, but continuing with deployment"
            fi
        fi
        
        # Replace placeholder URLs with custom endpoints if provided
        if [[ -n "$LOKI_URL" ]]; then
            log "Replacing Loki URL placeholder with: $LOKI_URL"
            if sed -i "s|https://your-loki-instance.com/loki/api/v1/push|$LOKI_URL|g" "$ALLOY_CONFIG_FILE"; then
                log_success "Updated Loki endpoint: $LOKI_URL"
                if grep -q "$LOKI_URL" "$ALLOY_CONFIG_FILE"; then
                    log_success "Loki URL replacement verified in config file"
                else
                    log_error "Loki URL replacement failed - URL not found in config file"
                fi
            else
                log_error "Failed to replace Loki URL placeholder"
            fi
        fi
        
        # Replace Prometheus endpoint if provided
        if [[ -n "$PROMETHEUS_URL" ]]; then
            log "Replacing Prometheus URL placeholder with: $PROMETHEUS_URL"
            if sed -i "s|https://your-prometheus-instance.com/api/v1/write|$PROMETHEUS_URL|g" "$ALLOY_CONFIG_FILE"; then
                log_success "Updated Prometheus endpoint: $PROMETHEUS_URL"
                if grep -q "$PROMETHEUS_URL" "$ALLOY_CONFIG_FILE"; then
                    log_success "Prometheus URL replacement verified in config file"
                else
                    log_error "Prometheus URL replacement failed - URL not found in config file"
                fi
            else
                log_error "Failed to replace Prometheus URL placeholder"
            fi
        fi
        
        # Set proper ownership and permissions
        chown root:alloy "$ALLOY_CONFIG_FILE" || error_exit "Failed to set configuration file ownership"
        chmod 640 "$ALLOY_CONFIG_FILE" || error_exit "Failed to set configuration file permissions"
        
        # Log which configuration was deployed
        case "$SYSTEM_TYPE" in
            "proxmox-container"|"proxmox-vm")
                log_success "Virtualized environment configuration deployed: $ALLOY_CONFIG_FILE"
                log "Configuration type: Logs-only (no metrics collection)"
                ;;
            "proxmox-host")
                log_success "Proxmox VE host configuration deployed: $ALLOY_CONFIG_FILE"
                log "Configuration type: Full observability (logs + metrics)"
                ;;
            "standalone")
                log_success "Standalone Linux configuration deployed: $ALLOY_CONFIG_FILE"
                log "Configuration type: Full observability (logs + metrics)"
                ;;
            *)
                log_success "Configuration deployed: $ALLOY_CONFIG_FILE"
                ;;
        esac
        
        # Configure the service to use our custom configuration file path
        configure_alloy_defaults
    else
        error_exit "Failed to deploy configuration file"
    fi
}

# Configure Alloy service defaults
configure_alloy_defaults() {
	log "Configuring Alloy service defaults..."
	local defaults_file="/etc/default/alloy"
	# Create or update the defaults file
	if [[ -f "$defaults_file" ]]; then
		log "Updating existing defaults file..."
		# Update existing CONFIG_FILE if it exists, otherwise add it
		if grep -q "^CONFIG_FILE=" "$defaults_file"; then
			sed -i "s|^CONFIG_FILE=.*|CONFIG_FILE=\"$ALLOY_CONFIG_FILE\"|" "$defaults_file"
		else
			echo "CONFIG_FILE=\"$ALLOY_CONFIG_FILE\"" >> "$defaults_file"
		fi
		
		# Update or add CUSTOM_ARGS with --disable-reporting
		if grep -q "^CUSTOM_ARGS=" "$defaults_file"; then
			sed -i "s|^CUSTOM_ARGS=.*|CUSTOM_ARGS=\"--disable-reporting\"|" "$defaults_file"
		else
			echo "CUSTOM_ARGS=\"--disable-reporting\"" >> "$defaults_file"
		fi
	else
		log "Creating new defaults file..."
		cat > "$defaults_file" << EOF
# Configuration file for Grafana Alloy
CONFIG_FILE="$ALLOY_CONFIG_FILE"

# Additional command-line arguments
CUSTOM_ARGS="--disable-reporting"
EOF
	fi

	# Add environment variables for runtime
	log "Adding environment variables to defaults file..."
	cat >> "$defaults_file" << EOF

# System type and configuration
SYSTEM_TYPE="$SYSTEM_TYPE"
EOF

	# Set proper permissions
	chmod 644 "$defaults_file" || error_exit "Failed to set permissions on defaults file"
	log_success "Alloy service defaults configured with --disable-reporting: $defaults_file"
}

# Helper: 5s spinner and stability check for a systemd service
check_service_stability_5s() {
    local svc="$1"
    local label="$2"
    local msg="Verifying $label service is running..."
    local spinner=("|" "/" "-" "\\")
    local delay=0.1
    local i=0
    tput civis 2>/dev/null || true
    for s in {1..50}; do
        printf "\r${BLUE}[INFO]${NC} $msg %s" "${spinner[$i]}"
        i=$(( (i+1) % 4 ))
        sleep $delay
    done
    printf "\r${BLUE}[INFO]${NC} $msg    \n"
    tput cnorm 2>/dev/null || true
    if systemctl is-active --quiet "$svc"; then
        # Check if the service is also in a failed state (can be both active and failed briefly)
        if systemctl is-failed --quiet "$svc"; then
            log_error "$label service is in a FAILED state after configuration!"
            log_error "Last 20 lines of service log:"
            journalctl -u "$svc" --no-pager --lines=20 || true
            exit 1
        else
            log_success "$label service is running after configuration."
        fi
    else
        if systemctl is-failed --quiet "$svc"; then
            log_error "$label service failed to start and is in a FAILED state!"
            log_error "Last 20 lines of service log:"
            journalctl -u "$svc" --no-pager --lines=20 || true
        else
            log_error "$label service failed to stay running for 5 seconds after start!"
            log_error "Last 20 lines of service log:"
            journalctl -u "$svc" --no-pager --lines=20 || true
        fi
        exit 1
    fi
}

# Unified systemd service management for Alloy and pve-guest-exporter
manage_service() {
    local svc_name="$1"
    local label="$2"
    local config_file="$3" # Optional: config file to check before starting

    # Check if the service unit exists
    if ! systemctl list-unit-files | grep -q "${svc_name}.service" \
        && ! [[ -f "/etc/systemd/system/${svc_name}.service" ]] \
        && ! [[ -f "/lib/systemd/system/${svc_name}.service" ]]; then
        log_warning "$label service unit not found, skipping start/check."
        return 0
    fi

    local was_running=false
    if systemctl is-active --quiet "$svc_name"; then
        was_running=true
        log "$label service is currently running - will restart after configuration"
    fi
    if systemctl enable "$svc_name"; then
        log_success "$label service enabled"
    else
        error_exit "Failed to enable $label service"
    fi
    # Only start/restart if config file is not required or exists
    if [[ -z "$config_file" || -f "$config_file" ]]; then
        if [[ "$was_running" == "true" ]]; then
            log "Restarting $label service with updated configuration..."
            systemctl restart "$svc_name"
        else
            log "Starting $label service..."
            systemctl start "$svc_name"
        fi
    else
        log_warning "Configuration file not found for $label, service not started"
        log_warning "Start the service manually after providing configuration: systemctl start $svc_name"
        return 1
    fi
    check_service_stability_5s "$svc_name" "$label"
}

# Configure systemd services for Alloy and pve-guest-exporter
configure_service() {
    log "Configuring systemd services..."
    manage_service "alloy" "Alloy" "$ALLOY_CONFIG_FILE"
    if [[ "$SYSTEM_TYPE" == "proxmox-host" ]]; then
        manage_service "pve-guest-exporter" "pve-guest-exporter" ""
    fi
}

# Verify installation
verify_installation() {
    log "Verifying installation..."

    # Check if Alloy service is running
    if systemctl is-active --quiet alloy; then
        log_success "Alloy service is running"
    elif [[ -f "$ALLOY_CONFIG_FILE" ]]; then
        log_warning "Alloy service is not running (may need configuration fix)"
        log "Recent service logs:"
        journalctl -u alloy --no-pager --lines=10
    else
        log_warning "Alloy service not started (configuration file missing)"
    fi

    # Check configuration file
    if [[ -f "$ALLOY_CONFIG_FILE" ]]; then
        log_success "Configuration file exists: $ALLOY_CONFIG_FILE"
    else
        log_warning "Configuration file missing: $ALLOY_CONFIG_FILE"
    fi

    # Improved check for pve-guest-exporter service
    if systemctl status pve-guest-exporter.service &>/dev/null; then
        if systemctl is-active --quiet pve-guest-exporter; then
            log_success "pve-guest-exporter service is running"
        else
            if systemctl is-failed --quiet pve-guest-exporter; then
                log_error "pve-guest-exporter service failed to start!"
                log "Recent service logs:"
                journalctl -u pve-guest-exporter --no-pager --lines=20
            else
                log_warning "pve-guest-exporter service is not running (may need configuration fix)"
                log "Recent service logs:"
                journalctl -u pve-guest-exporter --no-pager --lines=10
            fi
        fi
    else
        # Fallback: check if the unit file exists
        if [[ -f /etc/systemd/system/pve-guest-exporter.service ]] || systemctl list-unit-files | grep -q 'pve-guest-exporter.service'; then
            log_warning "pve-guest-exporter service unit exists but is not loaded. Try: systemctl daemon-reload && systemctl start pve-guest-exporter"
        else
            log_warning "pve-guest-exporter service is not installed (skipping check)"
        fi
    fi
}

# Print final status and instructions
print_final_status() {
    echo
    echo "============================================="
    log_success "Grafana Alloy Linux Installation Complete!"
    echo "============================================="
    echo

    if [[ -f "$ALLOY_CONFIG_FILE" ]] && systemctl is-active --quiet alloy; then
log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}
        case "$SYSTEM_TYPE" in
            "proxmox-container"|"proxmox-vm")
                log_success "✅  Alloy is installed and running (virtualized logs-only configuration)"
                log "Configuration: aio-linux-logs.alloy (logs only)"
                ;;
            "proxmox-host")
                log_success "✅  Alloy is installed and running (Proxmox VE host full configuration)"
                log "Configuration: aio-linux.alloy (logs + metrics)"
                ;;
            "standalone")
                log_success "✅  Alloy is installed and running (standalone full configuration)"
                log "Configuration: aio-linux.alloy (logs + metrics)"
                ;;
            *)
                log_success "✅  Alloy is installed and running"
                ;;
        esac
        log "Config file: $ALLOY_CONFIG_FILE"
    elif [[ -f "$ALLOY_CONFIG_FILE" ]]; then
        log_warning "⚠️  Alloy is installed but not running"
        log "Check configuration and start: systemctl start alloy"
        log "View logs: journalctl -u alloy"
    else
        log_warning "⚠️  Alloy is installed but needs configuration"
        log "1. Copy your config to: $ALLOY_CONFIG_FILE"
        log "2. Start the service: systemctl start alloy"
    fi
    
    echo
    log "Next Steps:"
    case "$SYSTEM_TYPE" in
        "proxmox-container"|"proxmox-vm")
            log "  1. Check your Loki instance for incoming log data"
            log "  2. Verify log filtering is working (WARNING+ only)"
            ;;
        "proxmox-host")
            log "  1. Check your Loki instance for incoming log data"
            log "  2. Verify metrics collection in Grafana/Prometheus"
            log "  3. Monitor both logs and system metrics"
            ;;
        "standalone")
            log "  1. Check your Loki instance for incoming log data"
            log "  2. Verify metrics collection in Grafana/Prometheus"
            log "  3. Monitor both logs and system metrics"
            ;;
        *)
            log "  1. Check your Loki instance for incoming log data"
            log "  2. Verify appropriate metrics collection based on your configuration"
            ;;
    esac
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -l|--loki-url)
                LOKI_URL="$2"
                shift 2
                ;;
            -p|--prometheus-url)
                PROMETHEUS_URL="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_FULL_INSTALL=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Log what endpoints will be used
    if [[ -n "$LOKI_URL" ]]; then
        log "Will configure Loki endpoint: $LOKI_URL"
    fi
    if [[ -n "$PROMETHEUS_URL" ]]; then
        log "Will configure Prometheus endpoint: $PROMETHEUS_URL"
    fi
    if [[ "$FORCE_FULL_INSTALL" == true ]]; then
        log "Force installation enabled: full observability will be configured regardless of virtualization"
    fi
}


# Proxmox API user/token automation for guest metrics exporter
setup_proxmox_exporter_user_and_token() {
    if [[ "$SYSTEM_TYPE" != "proxmox-host" ]]; then
        PROXMOX_OVERRIDE_GRANTED=""
        return 0
    fi
    log "Setting up Proxmox API user, role, and token for exporter..."
    local pve_user="alloy@pve"
    local token_id="$(hostname)"
    local env_file="/etc/alloy/pve-guest-exporter/pve-guest-exporter.env"
    local token_value=""
    PROXMOX_OVERRIDE_GRANTED="1" # Default: do all actions

    local privileges=""
    if proxmox_version_ge 9; then
        log "Proxmox version >= 9 detected - excluding deprecated VM.Monitor privilege"
        privileges="VM.Audit,Datastore.Audit,Sys.Audit,Pool.Audit"
    else
        log "Proxmox version < 9 detected - invcluding VM.Monitor privilege for compatibility"
        privileges="VM.Audit,VM.Monitor,Datastore.Audit,Sys.Audit,Pool.Audit"
    fi

    # Create custom AlloyMonitor role if it doesn't exist
    log "Creating custom AlloyMonitor role..."
    role_output=$(run_with_spinner "pveum role add AlloyMonitor -privs \"$privileges\" 2>&1" "Creating AlloyMonitor role..." || echo "ERROR") || true
    if echo "$role_output" | grep -qi 'already exists'; then
        log_success "AlloyMonitor role already exists"
    elif echo "$role_output" | grep -qi 'ERROR'; then
        log_error "Failed to create AlloyMonitor role: $role_output"
        PROXMOX_OVERRIDE_GRANTED="0"
        return 1
    else
        log_success "AlloyMonitor role created with required permissions"
    fi

    # Try to create user first, but do NOT prompt or override if it exists
    user_add_output=$(run_with_spinner "pveum user add \"$pve_user\" --comment \"Grafana Alloy Exporter\" --enable 1 2>&1" "Creating Proxmox user $pve_user..." || echo "ERROR") || true
    if echo "$user_add_output" | grep -qi 'already exists'; then
        log_success "Proxmox user $pve_user already exists. Continuing without override."
    elif echo "$user_add_output" | grep -qi 'ERROR'; then
        log_error "Failed to create Proxmox user $pve_user: $user_add_output"
        PROXMOX_OVERRIDE_GRANTED="0"
        return 1
    else
        log_success "Proxmox user $pve_user created"
    fi

    # If we reach here, override is granted or user is new
    PROXMOX_OVERRIDE_GRANTED="1"

    # Assign AlloyMonitor role to alloy@pve on root (cluster-wide read access)
    log "Assigning AlloyMonitor role to $pve_user on / ..."
    acl_output=$(run_with_spinner "pveum acl modify / -user \"$pve_user\" -role AlloyMonitor 2>&1" "Assigning AlloyMonitor role to $pve_user..." || echo "ERROR") || true
    if echo "$acl_output" | grep -qi 'already exists'; then
        log_success "AlloyMonitor role already assigned to $pve_user."
    elif echo "$acl_output" | grep -qi 'ERROR'; then
        log_error "Failed to assign AlloyMonitor role: $acl_output"
    else
        log_success "AlloyMonitor role assigned to $pve_user."
    fi

    # Force delete existing token if it exists (overwrite behavior)
    if pveum user token list "$pve_user" | grep '^│' | grep -v 'tokenid' | awk '{print $2}' | grep -Fxq "$token_id"; then
        log "Deleting existing API token $pve_user!$token_id to create fresh token..."
        run_with_spinner "pveum user token delete \"$pve_user\" \"$token_id\" 2>/dev/null" "Deleting existing API token..." || true
        log_success "Existing token deleted"
    fi

    token_output=$(run_with_spinner "pveum user token add \"$pve_user\" \"$token_id\" --privsep 0 2>&1" "Creating API token for $pve_user..." || echo "ERROR")
    # Try to extract the token value from the Proxmox table output
    token_value=""
    value_line=$(echo "$token_output" | grep -E '^│[[:space:]]*value[[:space:]]*│')
    if [[ -n "$value_line" ]]; then
        # Extract the value between the second and third pipe, trim whitespace
        token_value=$(echo "$value_line" | awk -F'│' '{gsub(/^ +| +$/,"",$3); print $3}')
    fi
    # Fallback: Try to extract a JWT (three dot-separated segments)
    if [[ -z "$token_value" ]]; then
        token_value=$(echo "$token_output" | grep -Eo '([A-Za-z0-9\-\._=]+\.[A-Za-z0-9\-\._=]+\.[A-Za-z0-9\-\._=]+)' | head -n1)
    fi
    # Fallback: Try to extract a UUID
    if [[ -z "$token_value" ]]; then
        token_value=$(echo "$token_output" | grep -Eo '([a-f0-9\-]{36})' | head -n1)
    fi
    if [[ -z "$token_value" ]]; then
        log_error "Failed to extract API token value for $pve_user!$token_id. Full output:"
        echo "$token_output"
        echo "[NOTICE] Please add the correct token manually to $env_file."
        PROXMOX_OVERRIDE_GRANTED="0"
        return 1
    fi
    log_success "API token $pve_user!$token_id created"

    # Store token securely in dedicated directory
    mkdir -p /etc/alloy/pve-guest-exporter
    local env_file="/etc/alloy/pve-guest-exporter/pve-guest-exporter.env"
    echo "PVE_API_TOKEN=$pve_user!$token_id=$token_value" > "$env_file"
    chown root:alloy "$env_file"
    chmod 640 "$env_file"
    log_success "API token stored securely in $env_file"


}

# Deploy the Proxmox guest metrics exporter files (Proxmox hosts only)
setup_proxmox_exporter_service() {
    if [[ "$SYSTEM_TYPE" != "proxmox-host" ]]; then
        return 0
    fi
    log "Setting up Proxmox guest metrics exporter systemd service..."

    # Create dedicated directory for pve-guest-exporter
    mkdir -p /etc/alloy/pve-guest-exporter

    # Handle case when script is executed via curl (dirname "$0" would fail)
    local exporter_py_src=""
    local service_file_src=""
    if [[ -f "$0" ]]; then
        exporter_py_src="$(dirname "$0")/pve-guest-exporter.py"
        service_file_src="$(dirname "$0")/pve-guest-exporter.service"
    else
        # Fallback URLs for when script is executed via curl
        exporter_py_src="https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/pve-guest-exporter.py"
        service_file_src="https://raw.githubusercontent.com/IT-BAER/alloy-aio/main/pve-guest-exporter.service"
    fi
    
    local exporter_py_dst="/etc/alloy/pve-guest-exporter/pve-guest-exporter.py"
    local service_file_dst="/etc/systemd/system/pve-guest-exporter.service"

    # Use local files (require git clone) or download from URL
    log "Copying exporter script from local repository..."
    if [[ -f "$exporter_py_src" ]]; then
        if run_with_spinner "cp \"$exporter_py_src\" \"$exporter_py_dst\"" "Copying exporter script..."; then
            log_success "Exporter script installed to $exporter_py_dst"
        else
            error_exit "Failed to copy exporter script from local repository"
        fi
    else
        # Download from URL
        if run_with_spinner "wget -q -O \"$exporter_py_dst\" \"$exporter_py_src\"" "Downloading exporter script..."; then
            log_success "Exporter script downloaded to $exporter_py_dst"
        else
            error_exit "Failed to download exporter script from $exporter_py_src"
        fi
    fi
    chown root:alloy "$exporter_py_dst"
    chmod 750 "$exporter_py_dst"

    log "Copying systemd unit from local repository..."
    if [[ -f "$service_file_src" ]]; then
        if run_with_spinner "cp \"$service_file_src\" \"$service_file_dst\"" "Copying systemd unit..."; then
            log_success "Systemd unit installed to $service_file_dst"
        else
            error_exit "Failed to copy systemd unit from local repository"
        fi
    else
        # Download from URL
        if run_with_spinner "wget -q -O \"$service_file_dst\" \"$service_file_src\"" "Downloading systemd unit..."; then
            log_success "Systemd unit downloaded to $service_file_dst"
        else
            error_exit "Failed to download systemd unit from $service_file_src"
        fi
    fi
    chown root:root "$service_file_dst"
    chmod 644 "$service_file_dst"

    # Reload systemd to pick up new unit
    run_with_spinner "systemctl daemon-reload" "Reloading systemd daemon..." || error_exit "Failed to reload systemd daemon"
    log_success "Systemd daemon reloaded"
}



# Main installation function
main() {
    parse_args "$@"
    echo "============================================="
    echo "    Grafana Alloy Linux Installation Script"
    echo "============================================="
    echo
    check_root
    check_system
    detect_proxmox
    if [[ "$FORCE_FULL_INSTALL" == true ]]; then
        if [[ "$SYSTEM_TYPE" == "proxmox-host" ]]; then
            log_warning "--force flag ignored for Proxmox hosts to preserve host-specific setup"
        else
            log_warning "--force flag active: overriding detected system type ($SYSTEM_TYPE) to standalone"
            SYSTEM_TYPE="standalone"
            IS_PROXMOX_HOST=false
        fi
    fi
    log "Detected system type: $SYSTEM_TYPE"
    if [[ -n "${DETECTED_SYSTEM_TYPE:-}" && "$DETECTED_SYSTEM_TYPE" != "$SYSTEM_TYPE" ]]; then
        log "Original detection: $DETECTED_SYSTEM_TYPE"
    fi
    configure_noninteractive_mode
    update_packages
    install_prerequisites
    setup_grafana_repo
    install_alloy
    # Only perform Proxmox user/token/permission actions if not a Proxmox host or override is granted
    if [[ "$SYSTEM_TYPE" == "proxmox-host" ]]; then
        setup_proxmox_exporter_user_and_token
        if [[ "$PROXMOX_OVERRIDE_GRANTED" == "1" ]]; then
            setup_permissions
        else
            log_warning "Skipping all Proxmox user, token, and permissions setup due to denied override."
        fi
        setup_proxmox_exporter_service
    else
        setup_permissions
    fi
    deploy_configuration
    configure_service
    verify_installation
    cleanup
    print_final_status
    
}

# Run main function (must be last line in file)
main "$@"
