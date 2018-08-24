#!/bin/bash

# download RHEL 7.4 KVM guest image from https://access.redhat.com/downloads/content/69/ver=/rhel---7/7.4/x86_64/product-software 
wget http://REDACTED:/pub/rhel-server-7.5-update-1-x86_64-kvm.qcow2
mkdir ~/images
mv rhel-server-7.5-update-1-x86_64-kvm.qcow2 ~/images/rhel-7.5-gpu.qcow2

# customize the image
virt-customize --selinux-relabel -a ~/images/rhel-7.5-gpu.qcow2 --root-password password:redhat
virt-customize --selinux-relabel -a ~/images/rhel-7.5-gpu.qcow2 --run-command 'subscription-manager register --username=REDACTED --password=REDACTED'
virt-customize --selinux-relabel -a ~/images/rhel-7.5-gpu.qcow2 --run-command 'subscription-manager attach --pool=REDACTED'
virt-customize --selinux-relabel -a ~/images/rhel-7.5-gpu.qcow2 --run-command 'subscription-manager repos --disable=*'
virt-customize --selinux-relabel -a ~/images/rhel-7.5-gpu.qcow2 --run-command 'subscription-manager repos --enable=rhel-7-server-rpms --enable=rhel-7-server-extras-rpms --enable=rhel-7-server-rh-common-rpms --enable=rhel-7-server-optional-rpms'
virt-customize --selinux-relabel -a ~/images/rhel-7.5-gpu.qcow2 --run-command 'yum install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r) gcc pciutils wget'
virt-customize --selinux-relabel -a ~/images/rhel-7.5-gpu.qcow2 --update

# prepare the overcloud
source ~/overcloudrc
openstack image create --disk-format qcow2 --container-format bare --public --file ~/images/rhel-7.5-gpu.qcow2 rhel7.5-gpu

