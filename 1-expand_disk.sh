#!/bin/bash


if [ "$EUID" -ne 0 ]
    then echo "Please run this as root"
    exit

    else echo "Root User Detected"
fi

# List volumes
lvdisplay


echo Expanding the Volume now
# Expand
lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
echo Done.

echo
echo

echo Resizing the Filesystem now.
# Expand the filesystem
resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
echo Done.
echo

# Check it
df -h

