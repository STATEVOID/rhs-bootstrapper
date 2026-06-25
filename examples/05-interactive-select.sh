#!/bin/bash
# Example Hook: 05-interactive-select.sh
# Put this script inside the FAT32 boot partition at /bootstrap.d/05-interactive-select.sh
# 
# This hook runs during the bootstrapper boot sequence. It prompts the user
# on the attached monitor/keyboard (TTY1) to choose which OS version and
# capabilities they want to deploy.

# Redirect stdin/stdout/stderr to /dev/tty1 to interact with the console
exec < /dev/tty1 > /dev/tty1 2>&1

clear
echo "======================================================"
echo "    RHS ZERO-TOUCH PROVISIONING OS WIZARD"
echo "======================================================"
echo ""
echo "Select the base OS profile to deploy on this hardware:"
echo "1) Production (Stable)"
echo "2) Beta / Staging (Testing)"
echo "3) Custom Image URL"
echo ""
read -p "Enter choice [1-3] (Default: 1): " choice
choice=${choice:-1}

case $choice in
    1)
        TARGET_IMAGE="quay.io/my-org/drone-os:stable"
        echo "Selected: Production (Stable)"
        ;;
    2)
        TARGET_IMAGE="quay.io/my-org/drone-os:beta"
        echo "Selected: Beta / Staging"
        ;;
    3)
        echo ""
        read -p "Enter custom OCI Image URL: " custom_url
        if [ -n "$custom_url" ]; then
            TARGET_IMAGE="$custom_url"
            echo "Selected: Custom Image ($TARGET_IMAGE)"
        else
            echo "No URL provided. Falling back to default."
        fi
        ;;
esac

echo ""
echo "Select optional hardware/runtime capabilities:"
read -p "Enable CUDA/GPU support? [y/N]: " cuda_choice
read -p "Enable ROS2 robotics framework? [y/N]: " ros2_choice

# Dynamically modify the target image tag/URL based on selected capabilities
TAG_SUFFIX=""
if [[ "$cuda_choice" =~ ^[Yy]$ ]]; then
    TAG_SUFFIX="${TAG_SUFFIX}-cuda"
fi
if [[ "$ros2_choice" =~ ^[Yy]$ ]]; then
    TAG_SUFFIX="${TAG_SUFFIX}-ros2"
fi

if [ -n "$TAG_SUFFIX" ]; then
    # e.g., converts quay.io/my-org/drone-os:stable to quay.io/my-org/drone-os:stable-cuda-ros2
    TARGET_IMAGE="${TARGET_IMAGE}${TAG_SUFFIX}"
    echo "Dynamic capabilities added! New target: $TARGET_IMAGE"
fi

echo ""
echo "Provisioning will proceed using target: $TARGET_IMAGE"
echo "Connecting to network and pulling blocks in 3 seconds..."
sleep 3
clear
