#!/bin/bash

# Step 1: Display current swap information
echo "Current swap information:"
sudo swapon --show
free -h
df -h

# Step 2: Create a 1GB swap file
echo "Creating swap file..."
sudo fallocate -l 1G /swapfile

# Step 3: Check swap file creation
ls -lh /swapfile

# Step 4: Set the correct permissions for the swap file
sudo chmod 600 /swapfile
ls -lh /swapfile

# Step 5: Set up the swap space
sudo mkswap /swapfile
sudo swapon /swapfile

# Step 6: Verify swap is active
echo "Swap is now active:"
sudo swapon --show
free -h

# Step 7: Make swap permanent by adding it to /etc/fstab
echo "Backing up /etc/fstab..."
sudo cp /etc/fstab /etc/fstab.bak
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Step 8: Set swappiness to 10 (less aggressive swapping)
echo "Setting swappiness to 10..."
cat /proc/sys/vm/swappiness
sudo sysctl vm.swappiness=10

# Step 9: Persist swappiness setting in sysctl.conf
echo "Updating sysctl.conf to set vm.swappiness=10..."
echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf

# Step 10: Set the vfs_cache_pressure to 50 (less aggressive cache dropping)
echo "Setting vfs_cache_pressure to 50..."
cat /proc/sys/vm/vfs_cache_pressure
sudo sysctl vm.vfs_cache_pressure=50

# Step 11: Persist vfs_cache_pressure setting in sysctl.conf
echo "Updating sysctl.conf to set vm.vfs_cache_pressure=50..."
echo "vm.vfs_cache_pressure=50" | sudo tee -a /etc/sysctl.conf

# Step 12: Reload sysctl settings
sudo sysctl -p

echo "Swap file creation and configuration complete."