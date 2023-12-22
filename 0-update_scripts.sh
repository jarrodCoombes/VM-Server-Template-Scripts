#!/bin/bash

echo +------------------------------------+
echo Pulling latest Disk Expansion Script
curl -s -O https://raw.githubusercontent.com/jarrodCoombes/VM-Server-Template-Scripts/master/1-expand_disk.sh 
echo +------------------------------------+

echo
echo

echo +------------------------------------+
echo Pulling latest SSH Key Reset Script
curl -s -O https://raw.githubusercontent.com/jarrodCoombes/VM-Server-Template-Scripts/master/2-reset_ssh_keys
echo +------------------------------------+

echo
echo

echo Making both scripts executable
chmod +x 1-expand_disk.sh
chmod +x 2-reset_ssh_keys
