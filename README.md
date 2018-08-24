# Deploying GPUs in OpenStack Newton via Tripleo

Instructions for configuring OpenStack Platform 10 director to deploy instances with Nvidia GPUs enabled via PCI Passthrough.

## Basic workflow
1. Deploy undercloud and import overcloud servers to Ironic
2. Enable IOMMU in server BIOS to support PCI passthrough
3. Deploy overcloud with templates that configure: iommu in grub, pci device aliases, pci device whitelist, and PciPassthrough filter enabled in nova.conf
4. Customize RHEL 7.4 image with kernel headers/devel and gcc
5. Create custom Nova flavor with PCI device alias
6. Configure cloud-init to install cuda at instance boot time
7. Launch instance from flavor + cloud-init + image via Heat
8. Run sample codes


## Resources
- [GPU support in Red Hat OpenStack Platform](https://access.redhat.com/solutions/3080471)
- [Bugzilla RFE for documentation on confiuring GPUs via PCI passthrough in OpenStack Platform](https://bugzilla.redhat.com/show_bug.cgi?id=1430337)
- [OpenStack Nova Configure PCI Passthrough](https://docs.openstack.org/nova/pike/admin/pci-passthrough.html)
- [KVM virtual machine GPU configuration](https://access.redhat.com/documentation/en-US/Red_Hat_Enterprise_Linux/7/html/Virtualization_Deployment_and_Administration_Guide/chap-Guest_virtual_machine_device_configuration.html#sect-device-GPU)
- [Nvidia Cuda Linux installation guide](http://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#runfile-installation)
- [DKMS support in Red Hat Enterprise Linux](https://access.redhat.com/solutions/1132653)
- [Deploying TripleO artifacts](http://hardysteven.blogspot.com/2016/08/tripleo-deploy-artifacts-and-puppet.html)


## Create TripleO environment files

Create TripleO environment files to configure nova.conf on the overcloud nodes running nova-compute and nova-scheduler.

```
cat templates/environments/20-compute-params.yaml 
parameter_defaults:

  NovaPCIPassthrough:
        - vendor_id: "10de"
          product_id: "13f2"

cat templates/environments/20-controller-params.yaml 
parameter_defaults:

  NovaSchedulerDefaultFilters: ['AvailabilityZoneFilter','RamFilter','ComputeFilter','ComputeCapabilitiesFilter','ImagePropertiesFilter','ServerGroupAntiAffinityFilter','ServerGroupAffinityFilter', 'PciPassthroughFilter', 'NUMATopologyFilter', 'AggregateInstanceExtraSpecsFilter']

  ControllerExtraConfig:
    nova::api::pci_alias:
      -  name: a1
         product_id: '13f2'
         vendor_id: '10de'
      -  name: a2
         product_id: '13f2'
         vendor_id: '10de'

```

In the above example, the controller node aliases two M60 cards with the names a1 and a2. Depending on the flavor, either or both cards can be assigned to an instance.

The environment files require the vendor ID and product ID for each passthrough device type. You can find these by running **lspci** on the physical server with the PCI cards.

```
    # lspci -nn | grep -i nvidia
    3d:00.0 VGA compatible controller [0300]: NVIDIA Corporation GM204GL [Tesla M60] [10de:13f2] (rev a1)
    3e:00.0 VGA compatible controller [0300]: NVIDIA Corporation GM204GL [Tesla M60] [10de:13f2] (rev a1)
```

The vendor ID is the first 4 digit hexadecimal number following the device name. The product ID is the second.

lspci is installed by the **pciutils** package.

iommu must be enabled at boot time on the compute nodes as well. This is accomplished through a the firstboot extraconfig hook.

```
cat templates/environments/10-firstboot-environment.yaml 
resource_registry:
  OS::TripleO::NodeUserData: /home/stack/templates/firstboot/first-boot.yaml

cat templates/firstboot/first-boot.yaml 
heat_template_version: 2014-10-16


resources:
  userdata:
    type: OS::Heat::MultipartMime
    properties:
      parts:
      - config: {get_resource: compute_kernel_args}


  # Verify the logs on /var/log/cloud-init.log on the overcloud node
  compute_kernel_args:
    type: OS::Heat::SoftwareConfig
    properties:
      config: |
        #!/bin/bash
        set -x

        # Set grub parameters
        if hostname | grep compute >/dev/null
        then
                sed -i.orig 's/quiet"$/quiet intel_iommu=on iommu=pt"/' /etc/default/grub
                grub2-mkconfig -o /etc/grub2.cfg
                systemctl stop os-collect-config.service
                /sbin/reboot
        fi

outputs:
  OS::stack_id:
    value: {get_resource: userdata}
```

The kernel arguments will be added to the Compute nodes at deploy time. This can be verified after deployment by checking /proc/cmdline on the compute node:

```
    $ ssh -l heat-admin 172.16.0.31 cat /proc/cmdline
    BOOT_IMAGE=/boot/vmlinuz-3.10.0-862.6.3.el7.x86_64 root=UUID=7aa9d695-b9c7-416f-baf7-7e8f89c1a3bc ro console=tty0 console=ttyS0,115200n8 crashkernel=auto rhgb quiet intel_iommu=on iommu=pt
```

Direct  IO virtualization must also be enabled in the server BIOS. This feature  can be called VT-d, VT-Direct, or Global SR_IOV Enable.

## Customize the RHEL 7.5 image

Download the RHEL 7.5 KVM guest image and customize it. This image will be used to launch the guest instance.

```
    $ virt-customize --selinux-relabel -a ~/images/rhel7.5-gpu.qcow2 --root-password password:redhat
    $ virt-customize --selinux-relabel -a ~/images/rhel7.5-gpu.qcow2 --run-command 'subscription-manager register --username=REDACTED --password=REDACTED'
    $ virt-customize --selinux-relabel -a ~/images/rhel7.5-gpu.qcow2 --run-command 'subscription-manager attach --pool=REDACTED'
    $ virt-customize --selinux-relabel -a ~/images/rhel7.5-gpu.qcow2 --run-command 'subscription-manager repos --disable=\*'
    $ virt-customize --selinux-relabel -a ~/images/rhel7.5-gpu.qcow2 --run-command 'subscription-manager repos --enable=rhel-7-server-rpms --enable=rhel-7-server-extras-rpms --enable=rhel-7-server-rh-common-rpms --enable=rhel-7-server-optional-rpms'
    $ virt-customize --selinux-relabel -a ~/images/rhel7.5-gpu.qcow2 --run-command 'yum install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r) gcc pciutils wget'
    $ virt-customize --selinux-relabel -a ~/images/rhel7.5-gpu.qcow2 --update
```

In this example we set a root password, register the server to CDN, subscribe only to the rhel-7-server-rpms, rhel-7-server-extras-rpms, rhel-7-server-rh-common-rpms, and rhel-7-server-optional-rpms channels. We also install the kernel-devel and kernel-headers packages along with gcc. These packages are required to build a kernel specific version of the Nvidia driver. Finally, we update the installed packages to the latest versions available from CDN.

After the image has been customized, we upload the image to Glance in the overcloud:

```
    $ source ~/overcloudrc
    $ openstack image create --disk-format qcow2 --container-format bare --public --file images/rhel7.5-gpu.qcow2 rhel75-gpu
```

## Deploy test Heat stack

The github repository includes Heat templates that:

1. Creates a flavor tagged with the PCI alias
2. Creates a test tenant and network with external access via floating IP addresses
3. Launches an instance from the image and flavor
4. Associated a floating IP and keypair with the instance
5. Installs the Cuda drivers and sample code on the instance via  Heat softwareConfig script

Run the Heat stack gpu_admin in the overcloud admin tenant to create the project, user, flavor, and networks.

```
    $ source ~/overcloudrc
    $ openstack stack create -t heat/gpu_admin.yaml gpu_admin
    $ openstack stack resource list gpu_admin
    +-------------------+-------------------------------------------------------------------------------------+------------------------------+-----------------+----------------------+
    | resource_name     | physical_resource_id                                                                | resource_type                | resource_status | updated_time         |
    +-------------------+-------------------------------------------------------------------------------------+------------------------------+-----------------+----------------------+
    | openstack_user    | 1f9c8342662a43ba99271348cdbf746c                                                    | OS::Keystone::User           | CREATE_COMPLETE | 2018-08-24T02:44:39Z |
    | instance_flavor1  | b695c9d3-cdcf-4a6f-bac2-0ce0b3cd3fb3                                                | OS::Nova::Flavor             | CREATE_COMPLETE | 2018-08-24T02:44:39Z |
    | internal_net      | f6db7c39-c6c4-4151-9582-00bfeab8a9cb                                                | OS::Neutron::Net             | CREATE_COMPLETE | 2018-08-24T02:44:39Z |
    | public_network    | 62a6a934-decc-4c20-aaa4-fa5f8c580f6c                                                | OS::Neutron::ProviderNet     | CREATE_COMPLETE | 2018-08-24T02:44:39Z |
    | router_interface  | d1c229bc-747b-4609-b425-953ca5e607f9:subnet_id=6ae36310-63c9-4eb8-885b-a1ba6977ff39 | OS::Neutron::RouterInterface | CREATE_COMPLETE | 2018-08-24T02:44:39Z |
    | openstack_project | 08fc17dbfe474d5bb37ea5af5140100c                                                    | OS::Keystone::Project        | CREATE_COMPLETE | 2018-08-24T02:44:39Z |
    | internal_router   | d1c229bc-747b-4609-b425-953ca5e607f9                                                | OS::Neutron::Router          | CREATE_COMPLETE | 2018-08-24T02:44:39Z |
    | public_subnet     | 05ba13f6-4518-47c1-858b-070ecc54343e                                                | OS::Neutron::Subnet          | CREATE_COMPLETE | 2018-08-24T02:44:39Z |
    | internal_subnet   | 6ae36310-63c9-4eb8-885b-a1ba6977ff39                                                | OS::Neutron::Subnet          | CREATE_COMPLETE | 2018-08-24T02:44:39Z |
    +-------------------+-------------------------------------------------------------------------------------+------------------------------+-----------------+----------------------+
```

Run the Heat stack gpu_user as the tenant user to luanch the instance and associate a floating IP address.

```
    $ sed -e 's/OS_USERNAME=admin/OS_USERNAME=user1/' -e 's/OS_PROJECT_NAME=admin/OS_PROJECT_NAME=tenant1/' -e 's/OS_PASSWORD=.*/OS_PASSWORD=redhat/' overcloudrc > ~/user1.rc
    $ source ~/user1.rc
    $ openstack stack create -t heat/gpu_user.yaml gpu_user
    $ openstack stack resource list gpu_user
    +---------------------+--------------------------------------+----------------------------+-----------------+----------------------+
    | resource_name       | physical_resource_id                 | resource_type              | resource_status | updated_time         |
    +---------------------+--------------------------------------+----------------------------+-----------------+----------------------+
    | server_init         | b69f7004-7341-4906-99d3-96b09075b0e5 | OS::Heat::MultipartMime    | CREATE_COMPLETE | 2018-08-24T02:47:33Z |
    | server1_port        | cd19ce2c-39f2-42bd-aac9-290ff3ad57b8 | OS::Neutron::Port          | CREATE_COMPLETE | 2018-08-24T02:47:33Z |
    | cuda_init           | aa3c84e3-fbe5-4b92-9ad1-34f5af9af704 | OS::Heat::SoftwareConfig   | CREATE_COMPLETE | 2018-08-24T02:47:33Z |
    | server1             | 9600ea1a-31fb-463d-abd0-0c4044b8517c | OS::Nova::Server           | CREATE_COMPLETE | 2018-08-24T02:47:33Z |
    | tenant_key_pair     | generated key pair                   | OS::Nova::KeyPair          | CREATE_COMPLETE | 2018-08-24T02:47:33Z |
    | security_group      | a13707fb-5fd6-4934-afda-355a44a85096 | OS::Neutron::SecurityGroup | CREATE_COMPLETE | 2018-08-24T02:47:33Z |
    | server1_floating_ip | 50626288-639b-430a-b378-8ccfe021f579 | OS::Neutron::FloatingIP    | CREATE_COMPLETE | 2018-08-24T02:47:33Z |
    +---------------------+--------------------------------------+----------------------------+-----------------+----------------------+
```

The Keystone key pair is automatically generated. Export the Heat output to a file.

```
    $ openstack stack output show -f value gpu_user private_key | tail -n +3 > gpukey.pem

    $ chmod 600 gpukey.pem
    $ cat gpukey.pem
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEAtrF2+mO7lOsFSJmF0rXGZZ5jpZFMvwc7GdZ9YNJ140jDD/Y7
    LXixwpFdxwRZwt1eHTzPcGuE7SjA9kyisk6D5lPYs1wQbJnnTpk5oOkkdlpwZwdY
    ...
    HajSgbDyjkHVxLFLzQ/HG9w0c6Ab3ewJDH+VHGHVXfMOzDP+8aFN1AGRXechXBlH
    omV/xFg9EW/1W6pkqDPaZQ9I9QAGRpzi6JYtFfPOU/FIkVRkEmof
    -----END RSA PRIVATE KEY-----
```

### Configure Cuda drivers and utilities

The Cuda drivers and utilities are installed by the following OS::Heat::SoftwareConfig resource:

```
    $ grep -A 18 cuda_init: heat/gpu_user.yaml
      cuda_init:
        type: OS::Heat::SoftwareConfig
        properties:
          config: |
            #!/bin/bash
            echo "installing repos" > /tmp/cuda_init.log
            rpm -ivh https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
            rpm -ivh https://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/cuda-repo-rhel7-8.0.61-1.x86_64.rpm
            echo "installing cuda and samples" >> /tmp/cuda_init.log
            yum install -y cuda && /usr/local/cuda-9.2/bin/cuda-install-samples-9.2.sh /home/cloud-user
            echo "building cuda samples" >> /tmp/cuda_init.log
            make -j $(grep -c Skylake /proc/cpuinfo) -C /home/cloud-user/NVIDIA_CUDA-9.2_Samples -Wno-deprecated-gpu-targets
            shutdown -r now

      server_init:
        type: OS::Heat::MultipartMime
        properties:
          parts:
          - config: { get_resource: cuda_init }
```

> **NOTE**: Cuda is a proprietary driver that requires DKMS to build the kernel modules. DKMS is available from EPEL. Neither the Cuda drivers nor DKMS are supported by Red Hat.

Verify the cards are recognized by the instance: 

```
    $ openstack server list
    +--------------------------------------+------+--------+-----------------------------------------+-------------+
    | ID                                   | Name | Status | Networks                                | Image Name  |
    +--------------------------------------+------+--------+-----------------------------------------+-------------+
    | 9600ea1a-31fb-463d-abd0-0c4044b8517c | vm1  | ACTIVE | internal_net=192.168.0.12, 172.16.0.214 | rhel7.5-gpu |
    +--------------------------------------+------+--------+-----------------------------------------+-------------+

    $ ssh -l cloud-user -i gpukey.pem 172.16.0.214 sudo lspci | grep -i nvidia
    00:06.0 VGA compatible controller: NVIDIA Corporation GM204GL [Tesla M60] (rev a1)
    00:07.0 VGA compatible controller: NVIDIA Corporation GM204GL [Tesla M60] (rev a1)
```

Verify that the drivers are built correctly:

```
    $ ssh -l cloud-user -i gpukey.pem 192.168.122.104 sudo lsmod | grep -i nvidia
    nvidia_drm             39689  0
    nvidia_modeset       1086183  1 nvidia_drm
    nvidia              14037782  1 nvidia_modeset
    drm_kms_helper        177166  2 cirrus,nvidia_drm
    drm                   397988  5 ttm,drm_kms_helper,cirrus,nvidia_drm
    i2c_core               63151  4 drm,i2c_piix4,drm_kms_helper,nvidia
    ipmi_msghandler        46607  2 ipmi_devintf,nvidia
```

> **NOTE**: It may take several minutes for the Nvidia drivers to build.

## Run sample codes

Verify PCI passthrough and Cuda and properly configured by running sample benchmarks included with the distribution:

```
    $ ssh -l cloud-user -i gpukey.pem 192.168.122.104
    Last login: Sat Aug 18 14:23:58 2018 from undercloud.redhat.local

    $  cat /proc/driver/nvidia/version
    NVRM version: NVIDIA UNIX x86_64 Kernel Module  396.44  Wed Jul 11 16:51:49 PDT 2018
    GCC version:  gcc version 4.8.5 20150623 (Red Hat 4.8.5-28) (GCC) 
```

Run the sample codes installed in the cloud-user home directory. In this example we run a simple Stream test of memory bandwidth and a floating point matrix multiply.

```
    $ ls ~/NVIDIA_CUDA-9.2_Samples/
    0_Simple  1_Utilities  2_Graphics  3_Imaging  4_Finance  5_Simulations  6_Advanced  7_CUDALibraries  bin  common  EULA.txt  Makefile

    $ ~/NVIDIA_CUDA-9.2_Samples/0_Simple/simpleStreams/simpleStreams
    [ simpleStreams ]
    Device synchronization method set to = 0 (Automatic Blocking)
    Setting reps to 100 to demonstrate steady state
    > GPU Device 0: "Tesla M60" with compute capability 5.2
    Device: <Tesla M60> canMapHostMemory: Yes
    > CUDA Capable: SM 5.2 hardware
    > 16 Multiprocessor(s) x 128 (Cores/Multiprocessor) = 2048 (Cores)
    > scale_factor = 1.0000
    > array_size   = 16777216
    > Using CPU/GPU Device Synchronization method (cudaDeviceScheduleAuto)
    > mmap() allocating 64.00 Mbytes (generic page-aligned system memory)
    > cudaHostRegister() registering 64.00 Mbytes of generic allocated system memory
    Starting Test
    memcopy:        8.83
    kernel:         5.77
    non-streamed:   11.08
    4 streams:      5.41
    -------------------------------
    
    $ ~/NVIDIA_CUDA-9.2_Samples/0_Simple/matrixMul/matrixMul
    [Matrix Multiply Using CUDA] - Starting...
    GPU Device 0: "Tesla M60" with compute capability 5.2
    MatrixA(320,320), MatrixB(640,320)
    Computing result using CUDA Kernel...
    done
    Performance= 309.81 GFlop/s, Time= 0.423 msec, Size= 131072000 Ops, WorkgroupSize= 1024 threads/block
    Checking computed result for correctness: Result = PASS
    NOTE: The CUDA Samples are not meant for performancemeasurements. Results may vary when GPU Boost is enabled.
```

Manual instructions for installing Cuda drivers and utilities are found in the Nvidia Cuda Linux installation guide.

## Resources

1. [GPU support in Red Hat OpenStack Platform](https://access.redhat.com/solutions/3080471)
2. [Bugzilla RFE for documentation on confiuring GPUs via PCI passthrough in OpenStack Platform](https://bugzilla.redhat.com/show_bug.cgi?id=1430337)
3. [OpenStack Nova Configure PCI Passthrough](https://docs.openstack.org/nova/queens/admin/pci-passthrough.html)
4. [KVM virtual machine GPU configuration](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/virtualization_deployment_and_administration_guide/chap-guest_virtual_machine_device_configuration#sect-device-GPU)
5. [Nvidia Cuda Linux installation guide](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#runfile-installation)
6. [DKMS support in Red Hat Enterprise Linux](https://access.redhat.com/solutions/1132653)
