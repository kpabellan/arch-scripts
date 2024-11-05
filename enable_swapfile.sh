#!/bin/bash

# Variables
SWAPFILE_SIZE_MB=17408                 # Swapfile size in MB
ROOT_PART="/dev/mapper/cryptroot"      # Root partition for UUID lookup
SWAPFILE_PATH="/swapfile"              # Path for the swapfile
FSTAB_FILE="/etc/fstab"                # fstab file path
GRUB_FILE="/etc/default/grub"          # GRUB configuration file path
MKINITCPIO_CONF="/etc/mkinitcpio.conf" # mkinitcpio configuration file path

# Check if any swapfiles or partitions are already in use
echo "Checking for existing swapfiles..."
if swapon -s | grep -q "$SWAPFILE_PATH"; then
    echo "Existing swap devices found. Turning off all swap devices..."
    sudo swapoff -a
else
    echo "No swap devices found."
fi

# Create swapfile
echo "Creating a ${SWAPFILE_SIZE_MB}MB swapfile at $SWAPFILE_PATH..."
sudo dd if=/dev/zero of="$SWAPFILE_PATH" bs=1M count="$SWAPFILE_SIZE_MB" status=progress

# Secure and enable the swapfile
echo "Securing and enabling the swapfile..."
sudo chmod 600 "$SWAPFILE_PATH"
sudo mkswap "$SWAPFILE_PATH"
sudo swapon "$SWAPFILE_PATH"

# Make the swapfile persistent by adding it to /etc/fstab if not already present
echo "Checking if swapfile entry is already in $FSTAB_FILE..."
FSTAB_ENTRY="$SWAPFILE_PATH none swap defaults 0 0"
if grep -Fxq "$FSTAB_ENTRY" "$FSTAB_FILE"; then
    echo "Swapfile entry already exists in $FSTAB_FILE."
else
    echo "Adding swapfile entry to $FSTAB_FILE..."
    echo "$FSTAB_ENTRY" | sudo tee -a "$FSTAB_FILE"
fi

# Verify /etc/fstab changes
echo "Verifying $FSTAB_FILE changes..."
if sudo mount -a; then
    echo "Swapfile successfully mounted."
else
    echo "Error mounting swapfile."
fi

# Enable Hibernation and Update GRUB

# Find the UUID of the root partition
echo "Finding the UUID of the root partition..."
ROOT_UUID=$(sudo blkid -s UUID -o value "$ROOT_PART")
echo "Root partition UUID is: $ROOT_UUID"

# Find the physical offset of the swapfile
echo "Finding the physical offset of the swapfile..."
SWAPFILE_OFFSET=$(sudo filefrag -v "$SWAPFILE_PATH" | awk 'NR==4 {print $4}' | cut -d'.' -f1)
echo "Physical offset of swapfile is: $SWAPFILE_OFFSET"

# Backup the current GRUB configuration
echo "Backing up current GRUB configuration..."
sudo cp "$GRUB_FILE" "$GRUB_FILE.backup"

# Edit the GRUB configuration
echo "Updating GRUB configuration..."
if grep -q "resume=UUID=" "$GRUB_FILE"; then
    # Replace existing 'resume' and 'resume_offset'
    sudo sed -i "s/\(resume=UUID=\)[^ ]*/\1$ROOT_UUID/" "$GRUB_FILE"
    sudo sed -i "s/\(resume_offset=\)[^ ]*/\1$SWAPFILE_OFFSET/" "$GRUB_FILE"
else
    # Add 'resume' and 'resume_offset' if they don't exist
    sudo sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\".*\)\"/\1 resume=UUID=$ROOT_UUID resume_offset=$SWAPFILE_OFFSET\"/" "$GRUB_FILE"
fi

# Ensure the ending quote is present by appending it if missing
sudo sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\".*\)\([^\"]*\)$/\1\2\"/" "$GRUB_FILE"

# Regenerate the GRUB configuration
echo "Regenerating GRUB configuration..."
sudo grub-mkconfig -o /boot/grub/grub.cfg

# Check and add resume hook to mkinitcpio.conf if missing
echo "Checking for resume hook in $MKINITCPIO_CONF..."
if grep -q "resume" "$MKINITCPIO_CONF"; then
    echo "The resume hook is already present in $MKINITCPIO_CONF."
else
    echo "Adding resume hook to $MKINITCPIO_CONF..."
    sudo sed -i '/^HOOKS=/ s/\(filesystems\)/resume \1/' "$MKINITCPIO_CONF"
fi

# Regenerate the initramfs
echo "Regenerating the initramfs..."
sudo mkinitcpio -P

echo "Rebooting the system to apply changes..."
sudo reboot