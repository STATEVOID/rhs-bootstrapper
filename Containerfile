# rhs-bootstrapper
# A public, generic zero-touch provisioning OS image based on almalinux-bootc-rpi.
# It reads rhs-config.json from the /boot/efi FAT32 partition or USB drives.

FROM quay.io/almalinuxorg/almalinux-bootc-rpi:9

# Install runtime packages exclusively from the AlmaLinux repositories. The Pi
# kernel and FAT synchronization tooling are supplied by the Pi bootc base.
RUN dnf install -y \
      iputils \
      jq \
      NetworkManager \
      NetworkManager-wifi \
      openssh-server \
      wpa_supplicant \
      wireless-regdb \
    && dnf clean all \
    && rm -rf /var/cache/dnf/* \
    && rpm -q raspberrypi2-kernel4 \
    && test -n "$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -print -quit)" \
    && test -n "$(find /usr/share -name bcm2711-rpi-4-b.dtb -print -quit)" \
    && test -d /usr/lib/ostree-boot \
    && test -n "$(find /usr/lib/ostree-boot -mindepth 1 -print -quit)" \
    && test -x /usr/bin/rpi-bootc-bootloader \
    && test -f /usr/lib/systemd/system/ostree-finalize-staged.service.d/rpi-bootc-bootloader.conf

# Copy the bootstrap script and service
COPY rhs-bootstrap.sh /usr/local/bin/rhs-bootstrap.sh
RUN chmod +x /usr/local/bin/rhs-bootstrap.sh

COPY rhs-bootstrap.service /etc/systemd/system/
RUN systemctl enable rhs-bootstrap.service
