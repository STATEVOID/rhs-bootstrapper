# rhs-bootstrapper
# A public, generic zero-touch provisioning OS image based on fedora-bootc.
# It reads rhs-config.json from the /boot/efi FAT32 partition or USB drives.

FROM quay.io/fedora/fedora-bootc:40

# Install jq for parsing the JSON config file
RUN dnf install -y jq NetworkManager && dnf clean all

# Copy the bootstrap script and service
COPY rhs-bootstrap.sh /usr/local/bin/rhs-bootstrap.sh
RUN chmod +x /usr/local/bin/rhs-bootstrap.sh

COPY rhs-bootstrap.service /etc/systemd/system/
RUN systemctl enable rhs-bootstrap.service
