#!/bin/bash

# Check internet connectivity
echo "Checking internet connectivity..."
if ! ping -q -c 1 -W 2 8.8.8.8 >/dev/null; then
    echo "No internet connection. Please connect to the internet and try again."
    exit 1
fi

# Disk input (use lsblk to find disk)
read -p "Enter the disk (e.g. /dev/sdX for the main disk): " DISK
read -p "Enter the EFI partition (e.g. /dev/sdX1 for EFI): " EFI_PART
read -p "Enter the root partition (e.g. /dev/sdX2 for Root): " ROOT_PART

# Locale and timezone with defaults
read -p "Enter your locale (default: en_US.UTF-8): " LOCALE
LOCALE=${LOCALE:-en_US.UTF-8}

read -p "Enter your timezone (default: America/Los_Angeles): " TIMEZONE
TIMEZONE=${TIMEZONE:-America/Los_Angeles}

# Username
read -p "Enter the user username: " USERNAME

# Hostname
read -p "Enter the system hostname: " HOSTNAME

# Root and user password
read -s -p "Enter root password: " ROOT_PASS
echo  # Newline for formatting after password input
read -s -p "Enter password for $USERNAME: " USER_PASS
echo  # Newline for formatting after password input

# Encryption password
read -s -p "Enter encryption password for the root partition: " ENC_PASS
echo  # Newline for formatting after password input

# Disk Wiping Step
read -p "Do you want to wipe $DISK with random data before installation? (y/n): " confirm
if [[ $confirm == "y" ]]; then
    echo "Wiping $DISK with random data. This may take a while..."
    dd if=/dev/urandom of="$DISK" bs=1M status=progress
    echo "Disk wipe complete."
else
    echo "Skipping disk wipe."
fi

# Disk Partitioning
echo "Creating partitions on $DISK..."
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 "$DISK" # EFI Partition
sgdisk -n 2:0:0 -t 2:8300 "$DISK"   # Root Partition

# Formatting Partitions
echo "Formatting EFI and root partitions..."
mkfs.fat -F32 "$EFI_PART"
echo -n "$ENC_PASS" | cryptsetup luksFormat "$ROOT_PART" -
echo -n "$ENC_PASS" | cryptsetup open "$ROOT_PART" cryptroot -
mkfs.ext4 /dev/mapper/cryptroot

# Mounting Partitions
mount /dev/mapper/cryptroot /mnt
mkdir /mnt/boot
mount "$EFI_PART" /mnt/boot

# Configure Pacman for Faster Downloads
echo "Configuring Pacman for faster downloads..."
sed -i 's/^#\(ParallelDownloads\)/\1/' /etc/pacman.conf
sed -i 's/^#\(VerbosePkgLists\)/\1/' /etc/pacman.conf

# Update mirrors and install essentials
echo "Updating mirrorlist and installing base packages..."
pacman -Sy reflector --noconfirm
reflector -c "US" -f 12 -l 10 -n 12 --save /etc/pacman.d/mirrorlist
pacstrap /mnt base base-devel linux linux-firmware networkmanager lvm2 cryptsetup grub efibootmgr nano vim

# fstab and chroot setup
genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt /bin/bash <<EOF

# Install additional packages for Hyprland
pacman -S --noconfirm gtk2 gtk3 gtk4 kitty hyprland

# System Configuration
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname
cat <<EOT >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOT

# Set Root Password
echo "Setting root password..."
echo "root:$ROOT_PASS" | chpasswd

# User setup
useradd -m -G wheel -s /bin/bash $USERNAME
echo "Setting password for $USERNAME..."
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Initramfs
sed -i 's/block filesystems/block encrypt lvm2 filesystems/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader setup
grub-install --efi-directory=/boot --bootloader-id=GRUB "$DISK"
UUID=\$(blkid -s UUID -o value "$ROOT_PART")
ROOT_UUID=\$(blkid -s UUID -o value /dev/mapper/cryptroot)
sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"quiet cryptdevice=UUID=\$UUID:cryptroot root=UUID=\$ROOT_UUID\"|" /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Enable NetworkManager
systemctl enable NetworkManager

EOF

# Finishing up
umount -R /mnt
cryptsetup close cryptroot
echo "Installation complete! Please reboot."
