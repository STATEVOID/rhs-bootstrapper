# rhs-bootstrapper
# A public, generic zero-touch provisioning OS image based on almalinux-bootc-rpi.
# It reads rhs-config.json from the /boot/efi FAT32 partition or USB drives.

FROM quay.io/almalinuxorg/almalinux-bootc-rpi:latest

# Install the runtime packages used during first boot.
# (Raspberry Pi boot assets are natively handled by the AlmaLinux Pi base image)
RUN printf "[fedora]\nname=Fedora 40 - aarch64\nmetalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-40&arch=aarch64\nenabled=1\ngpgcheck=0\n" > /etc/yum.repos.d/fedora.repo

RUN dnf install -y \
      iputils \
      jq \
      NetworkManager \
      NetworkManager-wifi \
      openssh-server \
      uboot-images-armv8 \
      wpa_supplicant \
      wireless-regdb \
    && rm -f /etc/yum.repos.d/fedora.repo \
    && dnf clean all \
    && rm -rf /var/cache/dnf/*

# Copy the bootstrap script and service
COPY rhs-bootstrap.sh /usr/local/bin/rhs-bootstrap.sh
RUN chmod +x /usr/local/bin/rhs-bootstrap.sh

COPY rhs-bootstrap.service /etc/systemd/system/
RUN systemctl enable rhs-bootstrap.service
