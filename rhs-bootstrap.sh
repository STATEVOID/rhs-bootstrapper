#!/bin/bash
set -e

# Log everything for debugging
exec > /var/log/rhs-bootstrap.log 2>&1

echo "==============================================="
echo "Starting RHS Zero-Touch Bootstrapper"
echo "==============================================="

CONFIG_FILE=""

# 1. Search for rhs-config.json
# Look in the EFI Boot partition (FAT32, mounted automatically)
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

if [ -z "$TARGET_IMAGE" ]; then
    echo "ERROR: target_image must be specified in $CONFIG_FILE"
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
