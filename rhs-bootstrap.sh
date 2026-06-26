#!/bin/bash
set -e

# Log everything for debugging
exec > /var/log/rhs-bootstrap.log 2>&1

echo "==============================================="
echo "Starting RHS Zero-Touch Bootstrapper"
echo "==============================================="

CONFIG_FILE=""

# Ensure the boot partition is mounted at /boot/efi.  On standard
# Fedora bootc images the ESP is auto-mounted by systemd-gpt-auto-
# generator, but we change the partition type to Microsoft Basic Data
# for desktop OS compatibility (Finder, Nautilus, etc.), so the auto-
# discovery may not trigger.  Fall back to mounting the first FAT32
# partition we find.
if ! mountpoint -q /boot/efi 2>/dev/null; then
    echo "Boot partition not auto-mounted at /boot/efi, scanning for FAT32 partition..."
    for dev in $(lsblk -bnrpo PATH,FSTYPE 2>/dev/null | awk '$2 ~ /^(vfat|fat)/ {print $1}'); do
        mkdir -p /boot/efi
        if mount "$dev" /boot/efi 2>/dev/null; then
            echo "Mounted $dev at /boot/efi"
            break
        fi
    done
fi

# 1. Search for rhs-config.json
# Look in the boot partition (FAT32, mounted at /boot/efi)
if [ -f "/boot/efi/rhs-config.json" ]; then
    echo "Found config at /boot/efi/rhs-config.json"
    CONFIG_FILE="/boot/efi/rhs-config.json"
fi

if [ -z "$CONFIG_FILE" ]; then
    echo "ERROR: rhs-config.json not found on the boot partition!"
    echo "Please plug the SD card into your computer, copy rhs-config.json"
    echo "into the FAT32 'boot' partition, and try again."
    exit 1
fi

# 2. Parse the configuration
echo "Parsing $CONFIG_FILE..."
WIFI_SSID=$(jq -r '.wifi_ssid // empty' "$CONFIG_FILE")
WIFI_PSK=$(jq -r '.wifi_psk // empty' "$CONFIG_FILE")
REGISTRY_AUTH=$(jq -r '.registry_auth // empty' "$CONFIG_FILE")
TARGET_IMAGE=$(jq -r '.target_image // empty' "$CONFIG_FILE")

# Execute custom bootstrap hooks (if any exist on the boot partition)
HOOKS_DIR="/boot/efi/bootstrap.d"
if [ -d "$HOOKS_DIR" ]; then
    echo "Found custom bootstrap hooks at $HOOKS_DIR. Executing..."
    for hook in $(find "$HOOKS_DIR" -maxdepth 1 -type f | sort); do
        echo "Running hook: $hook"
        export WIFI_SSID WIFI_PSK REGISTRY_AUTH TARGET_IMAGE CONFIG_FILE
        # Sourcing ensures hooks can modify variables in this environment.
        # We redirect stdin/stdout to the active screen terminal (/dev/tty1) if available,
        # so interactive selection menus are displayed properly to the user.
        if [ -c /dev/tty1 ]; then
            source "$hook" < /dev/tty1 > /dev/tty1 2>&1 || echo "Warning: Hook $hook exited with error"
        else
            source "$hook" || echo "Warning: Hook $hook exited with error"
        fi
    done
fi

if [ -z "$TARGET_IMAGE" ]; then
    echo "ERROR: target_image must be specified in $CONFIG_FILE or selected by a bootstrap hook"
    exit 1
fi

# 3. Setup Wi-Fi (if provided)
if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PSK" ]; then
    echo "Configuring Wi-Fi for SSID: $WIFI_SSID"
    
    cat <<EOF > /etc/NetworkManager/system-connections/rhs-wifi.nmconnection
[connection]
id=rhs-wifi
uuid=$(cat /proc/sys/kernel/random/uuid)
type=wifi
interface-name=wlan0

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=$WIFI_PSK

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto
EOF
    chmod 600 /etc/NetworkManager/system-connections/rhs-wifi.nmconnection
    
    # Reload NetworkManager to apply the connection immediately
    systemctl reload NetworkManager
    nmcli connection up rhs-wifi || echo "Failed to bring up Wi-Fi immediately, will wait for network."
fi

# 4. Wait for Internet
echo "Waiting for internet connection..."
until ping -c 1 8.8.8.8 &> /dev/null; do
    sleep 5
done
echo "Internet connected!"

# 5. Setup Registry Authentication (if provided)
if [ -n "$REGISTRY_AUTH" ]; then
    echo "Configuring private registry authentication..."
    # The registry_auth should be the base64 encoded auth string
    # For GCP, it's "_json_key:{YOUR_JSON_KEY}" base64 encoded
    
    # Extract the registry domain from the target image
    REGISTRY_DOMAIN=$(echo "$TARGET_IMAGE" | cut -d'/' -f1)
    
    mkdir -p /etc/ostree
    cat <<EOF > /etc/ostree/auth.json
{
  "auths": {
    "$REGISTRY_DOMAIN": {
      "auth": "$REGISTRY_AUTH"
    }
  }
}
EOF
    chmod 600 /etc/ostree/auth.json
fi

# 5a. Setup Admin User & SSH Keys (if provided)
ADMIN_USERNAME=$(jq -r '.admin_username // empty' "$CONFIG_FILE")
ADMIN_PASSWORD=$(jq -r '.admin_password // empty' "$CONFIG_FILE")
SSH_AUTHORIZED_KEY=$(jq -r '.ssh_authorized_key // empty' "$CONFIG_FILE")

if [ -n "$ADMIN_USERNAME" ] || [ -n "$SSH_AUTHORIZED_KEY" ]; then
    # Default to "admin" if no username specified but SSH key/password is provided
    if [ -z "$ADMIN_USERNAME" ]; then
        ADMIN_USERNAME="admin"
    fi
    
    echo "Configuring admin user: $ADMIN_USERNAME"
    
    # Create user if not exists
    if ! id "$ADMIN_USERNAME" &>/dev/null; then
        # Check if wheel or sudo group exists
        GROUPS_ARG=""
        if getent group wheel &>/dev/null; then
            GROUPS_ARG="-G wheel"
        elif getent group sudo &>/dev/null; then
            GROUPS_ARG="-G sudo"
        fi
        useradd -m $GROUPS_ARG -s /bin/bash "$ADMIN_USERNAME" || echo "Warning: Failed to create user $ADMIN_USERNAME"
    fi
    
    # Set password if provided
    if [ -n "$ADMIN_PASSWORD" ] && id "$ADMIN_USERNAME" &>/dev/null; then
        echo "Setting password for $ADMIN_USERNAME..."
        echo "$ADMIN_USERNAME:$ADMIN_PASSWORD" | chpasswd || echo "Warning: Failed to set password for $ADMIN_USERNAME"
    fi
    
    # Set up SSH authorized keys if provided
    if [ -n "$SSH_AUTHORIZED_KEY" ] && id "$ADMIN_USERNAME" &>/dev/null; then
        echo "Injecting SSH authorized key for $ADMIN_USERNAME..."
        USER_HOME=$(eval echo "~$ADMIN_USERNAME")
        mkdir -p "$USER_HOME/.ssh"
        echo "$SSH_AUTHORIZED_KEY" >> "$USER_HOME/.ssh/authorized_keys"
        chmod 700 "$USER_HOME/.ssh"
        chmod 600 "$USER_HOME/.ssh/authorized_keys"
        chown -R "$ADMIN_USERNAME:$ADMIN_USERNAME" "$USER_HOME/.ssh"
    fi
    
    # Enable and start SSH daemon
    echo "Enabling sshd..."
    systemctl enable --now sshd || echo "Warning: Failed to enable sshd"
fi

# 6. Perform the Bootc Switch
echo "Switching bootc to target image: $TARGET_IMAGE"
bootc switch "$TARGET_IMAGE"

echo "==============================================="
echo "Switch complete! The device will now reboot into the custom OS."
echo "==============================================="

# Delete the config so secrets aren't left on the unencrypted boot partition
echo "Shredding $CONFIG_FILE for security..."
shred -u "$CONFIG_FILE" || rm -f "$CONFIG_FILE"

# 7. Reboot
sleep 5
systemctl reboot
