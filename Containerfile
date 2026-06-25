# rhs-bootstrapper
# A public, generic zero-touch provisioning OS image based on fedora-bootc.
# It reads rhs-config.json from the /boot/efi FAT32 partition or USB drives.

FROM quay.io/fedora/fedora-bootc:40

# Install the runtime packages used during first boot and the Fedora-provided
# Raspberry Pi boot assets copied into the generated SD-card image by CI.
RUN dnf install -y \
      bcm283x-firmware \
      grub2-efi-aa64 \
      iputils \
      jq \
      linux-firmware \
      NetworkManager \
      NetworkManager-wifi \
      openssh-server \
      shim-aa64 \
      uboot-images-armv8 \
      wpa_supplicant \
      wireless-regdb \
    && dnf clean all \
    && rm -rf /var/cache/dnf/*

# Copy the bootstrap script and service
COPY rhs-bootstrap.sh /usr/local/bin/rhs-bootstrap.sh
RUN chmod +x /usr/local/bin/rhs-bootstrap.sh

COPY rhs-bootstrap.service /etc/systemd/system/
RUN systemctl enable rhs-bootstrap.service
