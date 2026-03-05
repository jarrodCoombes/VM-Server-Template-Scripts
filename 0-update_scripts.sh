#!/bin/bash
echo +------------------------------------+
echo Pulling latest Disk Expansion Script
curl -s -O https://raw.githubusercontent.com/jarrodCoombes/VM-Server-Template-Scripts/master/0-update_scripts.sh 
echo +------------------------------------+

echo
echo


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

echo +------------------------------------+
echo Pulling latest Host Name and Network Script
curl -s -O https://raw.githubusercontent.com/jarrodCoombes/VM-Server-Template-Scripts/master/3-Set_HostName_Networking.sh
echo +------------------------------------+

echo
echo

echo Making scripts executable
chmod +x 0-update_scripts.sh
chmod +x 1-expand_disk.sh
chmod +x 2-reset_ssh_keys
chmod +x 3-Set_HostName_Networking.sh

echo Done

