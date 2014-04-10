#!/bin/bash

################################################################################
# User-data script to configure amazon linux to run as a 
# Network Address Translator (NAT) to provide Internet connectivity 
# to private instances. 
# Always up to date and never stored in account so save on AMI charges
# Not quite HA, can have periods of 5-10 min of interruption, but auto recovers
# 
# Resilient NAT 
# @author - Nic Branker
# @date - 4/9/2014
# @params myRouteTable - change to be your route table
#
################################################################################

#insert your route table value
myRouteTable=rtb-65a2880e

#set default region and create config stub
mkdir ~/.aws
echo "[default]" > ~/.aws/config
echo region = us-east-1 >> ~/.aws/config

#get instanceId
this_InstanceId=`wget -q -O - http://169.254.169.254/latest/dynamic/instance-identity/document \
| grep instanceId | awk '/instanceId/ {print $3}' | sed 's/\"//' | sed 's/\",//'`

#add instance tags
aws ec2 create-tags --resources $this_InstanceId --tags Key=Name,Value=ae-nat-prod
aws ec2 create-tags --resources $this_InstanceId --tags Key=Environment,Value=OPS
aws ec2 create-tags --resources $this_InstanceId --tags Key=BU,Value=OPS


#disable source/dest checking
aws ec2 modify-instance-attribute --instance-id $this_InstanceId --no-source-dest-check

#update NAT route in route table
aws ec2 replace-route --route-table-id $myRouteTable --destination-cidr-block 0.0.0.0/0 --instance-id $this_InstanceId

set -x
echo "Determining the MAC address on eth0"
ETH0_MAC=`/sbin/ifconfig  | /bin/grep eth0 | awk '{print tolower($5)}' | grep '^[0-9a-f]\{2\}\(:[0-9a-f]\{2\}\)\{5\}$'`
if [ $? -ne 0 ] ; then
   echo "Unable to determine MAC address on eth0" | logger -t "ec2"
   exit 1
fi
echo "Found MAC: ${ETH0_MAC} on eth0" | logger -t "ec2"


VPC_CIDR_URI="http://169.254.169.254/latest/meta-data/network/interfaces/macs/${ETH0_MAC}/vpc-ipv4-cidr-block"
echo "Metadata location for vpc ipv4 range: ${VPC_CIDR_URI}" | logger -t "ec2"

VPC_CIDR_RANGE=`curl --retry 3 --retry-delay 0 --silent --fail ${VPC_CIDR_URI}`
if [ $? -ne 0 ] ; then
   echo "Unable to retrive VPC CIDR range from meta-data. Using 0.0.0.0/0 instead. PAT may not function correctly" | logger -t "ec2"
   VPC_CIDR_RANGE="0.0.0.0/0"
else
   echo "Retrived the VPC CIDR range: ${VPC_CIDR_RANGE} from meta-data" |logger -t "ec2"
fi

echo 1 >  /proc/sys/net/ipv4/ip_forward && \
   echo 0 >  /proc/sys/net/ipv4/conf/eth0/send_redirects && \
   /sbin/iptables -t nat -A POSTROUTING -o eth0 -s ${VPC_CIDR_RANGE} -j MASQUERADE

if [ $? -ne 0 ] ; then
   echo "Configuration of PAT failed" | logger -t "ec2"
   exit 0
fi

echo "Configuration of PAT complete" |logger -t "ec2"
exit 0
