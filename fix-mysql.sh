#!/bin/bash

# Remove the existing mysql.gpg file if it exists
sudo rm /etc/apt/trusted.gpg.d/mysql.gpg

# Download the MySQL GPG key
wget https://repo.mysql.com/RPM-GPG-KEY-mysql-2023

# Move the GPG key to the trusted directory
sudo mv RPM-GPG-KEY-mysql-2023 /etc/apt/trusted.gpg.d/mysql.asc

# Add MySQL repository configuration to the sources list
echo "deb http://repo.mysql.com/apt/ubuntu jammy mysql-apt-config
deb http://repo.mysql.com/apt/ubuntu jammy mysql-8.0
deb http://repo.mysql.com/apt/ubuntu jammy mysql-tools
deb http://repo.mysql.com/apt/ubuntu jammy mysql-tools-preview" | sudo tee /etc/apt/sources.list.d/mysql.list

# Update the package list
sudo apt-get update
