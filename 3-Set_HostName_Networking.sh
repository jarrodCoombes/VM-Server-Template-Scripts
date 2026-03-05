#!/bin/bash

# Variables

netScript1="/etc/netplan/01-netcfg.yaml"
netScript2="/etc/hosts"

# Function calculates number of bit in a netmask
#
mask2cidr() {
    nbits=0
    IFS=.
    for dec in $1 ; do
        case $dec in
            255) let nbits+=8;;
            254) let nbits+=7 ; break ;;
            252) let nbits+=6 ; break ;;
            248) let nbits+=5 ; break ;;
            240) let nbits+=4 ; break ;;
            224) let nbits+=3 ; break ;;
            192) let nbits+=2 ; break ;;
            128) let nbits+=1 ; break ;;
            0);;
            *) echo "Error: $dec is not recognised"; exit 1
        esac
    done
    echo "$nbits"
}


#Check to make sure we are being run as root.
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

clear
 
echo -e '
'"This script will run you through the network setup process."
echo -e "Please be prepared to specify the VM's IP Address and related"
echo -e "network information. You can re-run this script if you make"
echo -e "mistakes or want to change this information in the future." 
echo -e "                                                   v1.0" '
'

echo -e  '
'"Please specify the VM's Fully Qualified Domain Name (FQDN)."
echo -e "example: server01.mpcsd.org"
read fqdn
 
echo -e "Please specify the VM's IP address:"
read ipAddr
 
echo -e  '
'"Please specify the subnet mask:"
echo -e "Press enter to use the default of 255.255.255.0"
read subnetMask
	if [ -n $subnetMask ]; then
   	    subnetMask="255.255.255.0"
	fi
	cidr=$(mask2cidr $subnetMask)

echo -e  '
'"Please specify the network gateway:"
echo -e "Press enter to use the default gateway of 10.1.1.1"
read defaultGW
	if [ -n $defaultGW ]; then
		defaultGW="10.1.1.1"
	fi
 
echo -e  '

'"Please specify a primary DNS server:"
echo -e "Press enter to use the default DNS server of 10.1.1.205"
read priDNS
	if [ -n $priDNS ]; then
		priDNS="10.1.1.205"
	fi
 
echo -e  '

'"Please specify a secondary DNS server:"
echo -e "Press enter to use the default DNS server of 10.1.1.213"
read secDNS
	if [ -n $priDNS ]; then
		secDNS="10.1.1.213"
	fi

echo -e '

'"Please specify your NTP Time server."
echo -e "Press enter to use the default NTP server of time.mpcsd.org"
read timeServer
  	if [ -n $timeServer ]; then
		timeServer="time.mpcsd.org"
	fi

# Extract Hostname and domain name from the FQDN.  
hostName=${fqdn%%.*}
domainName=${fqdn#*.}
  
echo -e  '
'"You have provided the following information:"'
'
echo -e "-------------------"
echo -e "IP Address: " $ipAddr
echo -e "Subnet Mask: " $subnetMask
echo -e "Gateway: " $defaultGW
echo -e "DNS Servers: " $priDNS"," $secDNS
echo -e "FQDN: " $fqdn  "(hostname: $hostName and Domain name: $domainName)"
echo -e "Time Server: " $timeServer
echo -e "-------------------"  '
'
echo -e "Is this correct?  Press enter to conmmit changes  or CTRL+C to exit"  '
'
read
 
echo -e "Setting up networking.  This will only take a moment."  '
'
 
 
echo -e "Setting "$netScript1
 
	echo -e '# This file describes the network interfaces available on your system' > $netScript1
	echo -e '# For more information, see netplan(5). ' >> $netScript1
	echo -e 'network: ' >> $netScript1
	echo -e '  version: 2 ' >> $netScript1
	echo -e '  renderer: networkd ' >> $netScript1
	echo -e '  ethernets: ' >> $netScript1
	echo -e '    enX0: ' >> $netScript1
	echo -e '      addresses: ['$ipAddr'/'$cidr'] ' >> $netScript1
	echo -e '      nameservers: ' >> $netScript1
	echo -e '          search: ['$domainName'] ' >> $netScript1
	echo -e '          addresses: ['$priDNS', '$secDNS'] ' >> $netScript1
	echo -e '      routes: ' >> $netScript1
	echo -e '        - to: default' >> $netScript1
	echo -e '          via: '$defaultGW' ' >> $netScript1


echo -e "Setting "$netScript2

	echo -e '127.0.0.1     localhost' > $netScript2
	echo -e $ipAddr '   ' $fqdn '   ' $hostName >> $netScript2
	echo -e '' >> $netScript2
	echo -e '# The following lines are desirable for IPv6 capable hosts' >> $netScript2
	echo -e '::1     localhost ip6-localhost ip6-loopback' >> $netScript2
	echo -e 'ff02::1    ip6-allnodes' >> $netScript2
	echo -e 'ff02::2    ip6-allrouters' >> $netScript2

echo -e "Setting hostname"
   
#   hostname $fqdn > /dev/null
    hostnamectl set-hostname $hostName
 
echo -e "Restarting network serices"
    echo -e "      Running netplan apply"
    netplan apply

    echo -e "      Testing connectivity."
    ping -q -c 1 $defaultGW > /dev/null
    if [[ $? -ne 0 ]]
    then
	echo -e "      WARNING: Could not connect, trying to reset networking again, this time with debug output"
	netplan --debug apply
        ping -q -c 1 $defaultGW > /dev/null
    fi
    if [[ $? -ne 0 ]]
    then
        echo -e "ERROR: Network is unreachable."
        echo -e "Please verify the network configuration of this host and re-run the script."
        exit 1
    fi
 
echo -e "Network connection established successfully!"

echo -e "Syncronizing time with domain"
 
    ntpdate $timeServer
 
echo -e "Grabbing latest software updates"
 
   apt update
   apt upgrade
 
echo -e ''
echo -e "Initial setup is complete.  It is recommended that you restart"
echo -e "the VM now.  Press enter restart, or CTRL+C to exit."

read
 
reboot
