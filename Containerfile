# rhs-bootstrapper
# A public, generic zero-touch provisioning OS image based on fedora-bootc.
# It reads rhs-config.json from the /boot/efi FAT32 partition or USB drives.

FROM quay.io/fedora/fedora-bootc:40

# Install jq for config parsing, remove heavy unused container runtimes/tools, and clean caches
RUN dnf install -y jq && \
    dnf remove -y podman crun flatpak toolbox cockpit && \
    dnf clean all && \
    rm -rf /var/cache/dnf/* /var/log/dnf* /var/cache/yum/*

# Copy the bootstrap script and service
COPY rhs-bootstrap.sh /usr/local/bin/rhs-bootstrap.sh
RUN chmod +x /usr/local/bin/rhs-bootstrap.sh

COPY rhs-bootstrap.service /etc/systemd/system/
RUN systemctl enable rhs-bootstrap.service
