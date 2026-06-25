# RHS Public OS Bootstrapper

The RHS Bootstrapper is a generic, "Zero-Touch" provisioning OS image. It allows anyone to flash a standard `.raw` disk image to their hardware, and have it automatically bootstrap itself into *any* custom immutable OS (using `bootc`), even if that custom OS is hosted on a private, authenticated registry.

This solves the "first boot" problem for IoT devices and drones, allowing you to seamlessly transition from a blank piece of hardware to a fully configured, zero-trust fleet device.

## Goal & Target
Provide a secure, automated, and lightweight mechanism to bootstrap bare-metal physical devices. It aims to completely automate Wi-Fi configuration, private container registry authentication, custom boot hooks, user account setup, SSH daemon enabling, and running the atomic `bootc switch` without requiring visual monitors or keyboards.

## How It Works
1. **Flash:** You flash the pre-built `rhs-bootstrapper-raspberrypi-arm64.raw.zst` image to your MicroSD card, NVMe drive, or eMMC.
2. **Configure:** You plug the drive into your PC. The `boot` partition (FAT32) mounts, and you drop a file named `rhs-config.json` into this partition.
3. **Boot:** You put the drive into your target hardware (e.g. Raspberry Pi 4/5) and boot.
4. **Provisioning:** The bootstrapper reads `rhs-config.json`, establishes a connection, provisions registry credentials, creates users/SSH keys, performs a `bootc switch`, and reboots into the custom OS.

## Configuration Details
Your `rhs-config.json` file is structured as follows:
```json
{
  "wifi_ssid": "My_IoT_Network",
  "wifi_psk": "SuperSecretPassword",
  "registry_auth": "BASE_64_ENCODED_CREDENTIALS",
  "target_image": "us-central1-docker.pkg.dev/my-project/my-repo/drone-os:latest",
  "admin_username": "admin",
  "admin_password": "PlaintextPassword",
  "ssh_authorized_key": "ssh-rsa AAAAB3NzaC1yc2E..."
}
```

## Security
Once the RHS Bootstrapper successfully provisions the target environment, it **securely shreds and deletes** the `rhs-config.json` file from the unencrypted boot partition. This ensures credentials are not left exposed on the physical media.

## Current State
- Includes complete Wi-Fi system-connection generation using NetworkManager.
- Supports GCP/AWS/Docker private registries via `/etc/ostree/auth.json` credential mapping.
- Supports admin user creation (mapped to RedHat `wheel` or Debian `sudo` groups) and SSH public key injection into `~/.ssh/authorized_keys`.
- Supports execution of custom shell hooks from `/boot/efi/bootstrap.d/` on startup.

## Technology Readiness Level (TRL)
**TRL 4 (Component validation in laboratory environment)**
The bootstrap service and provisioning script are buildable using GitHub Actions, producing a Raspberry Pi 4/5 arm64 raw SD-card artifact with Fedora-provided Pi boot assets and a SHA-256 checksum.

## Gaps & Future Work
- **Unencrypted Configuration Payload:** The `rhs-config.json` payload contains plain text Wi-Fi and registry secrets on the FAT32 partition. Although securely shredded on first boot, it resides unencrypted before provisioning. Future revisions should encrypt this payload using device-sealed TPM keys.
- **Limited Network Scenarios:** The bootstrapper handles standard Ethernet DHCP and Wi-Fi networks but lacks plug-and-play config mappings for static IP layouts, VLANs, enterprise Wi-Fi (802.1X), or cellular modems (LTE/5G).
- **Hook Verification:** Custom startup scripts inside `/boot/efi/bootstrap.d/` are executed automatically as root, raising a security threat if malicious hooks are loaded onto the physical drives. Hook files should require cryptographically signed validation before sourcing.
