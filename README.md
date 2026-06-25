# RHS Public OS Bootstrapper

The RHS Bootstrapper is a generic, "Zero-Touch" provisioning OS image. It allows anyone to flash a standard `.raw` disk image to their hardware, and have it automatically bootstrap itself into *any* custom immutable OS (using `bootc`), even if that custom OS is hosted on a private, authenticated registry.

This solves the "first boot" problem for IoT devices and drones, allowing you to seamlessly transition from a blank piece of hardware to a fully configured, zero-trust fleet device.

## How It Works

1. **Flash:** You flash the pre-built `rhs-bootstrapper.raw.zst` image (available in GitHub Releases) to your MicroSD card, NVMe drive, or eMMC.
2. **Configure:** You plug the drive into your Mac/Windows PC. The `boot` partition will mount automatically as a standard USB drive (it's FAT32). You drop a file named `rhs-config.json` into this partition.
3. **Boot:** You put the drive into your target hardware (e.g., a Raspberry Pi 4/5) and turn it on.
4. **Zero-Touch Provisioning:** The RHS Bootstrapper reads your `rhs-config.json`, connects to your Wi-Fi, authenticates against your private Docker/GCP/AWS registry, and runs `bootc switch` to download and reboot into your actual operating system.

## Configuration

Your `rhs-config.json` file should look like this:

```json
{
  "wifi_ssid": "My_IoT_Network",
  "wifi_psk": "SuperSecretPassword",
  "registry_auth": "BASE_64_ENCODED_CREDENTIALS",
  "target_image": "us-central1-docker.pkg.dev/my-project/my-repo/drone-os:latest"
}
```

### Obtaining the `registry_auth` string
The `registry_auth` string is exactly what would normally go into a container runtime's `auth.json` file.
For Google Cloud Artifact Registry using a Service Account JSON Key, you encode it like this:
```bash
echo -n "_json_key:$(cat my-sa-key.json)" | base64 -w0
```

## Security
Once the RHS Bootstrapper successfully reads your `rhs-config.json` and provisions the system, it will **securely shred and delete** the file from the unencrypted boot partition. This ensures your Wi-Fi passwords and registry credentials are not left sitting in plaintext on the disk.

## Building from Source
If you want to build the `.raw` images yourself, you can use the provided GitHub Actions workflow, or build it locally using `podman` on a Linux host (Docker Desktop for Mac is not supported due to macOS kernel virtualization limitations regarding `memfd` execution).
