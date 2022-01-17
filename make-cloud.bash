#!/usr/bin/env bash

export HOME="${HOME:-~/}"
export THT="${THT:-/usr/share/openstack-tripleo-heat-templates}"
export NTP_SERVER="${NTP_SERVER:-time.google.com}"
export VIRT_TYPE="${VIRT_TYPE:-$([ $(egrep -c '(vmx|svm)' /proc/cpuinfo) = 0 ] && echo qemu || echo kvm)}"
export STACK_NAME="${STACK_NAME:-rk-openstack-0}"
export NFS_SERVER="${NFS_SERVER:-172.16.27.211}"
export TENANT_VLAN="${TENANT_VLAN:-204}"


function create-stack-user {
  sudo useradd --comment "OpenStack user" --create-home --user-group --groups wheel stack
  if [[ ! -d "/etc/sudoers.d/" ]]; then
    mkdir -p /etc/sudoers.d
  fi
  echo '%wheel ALL=(ALL) NOPASSWD: ALL' | sudo tee -a /etc/sudoers.d/stack
}


function tmux-execute {
  tmux new-session -d -s deploy-tripleo -n deploy-tripleo || true
  tmux new-window -n deploy -t 0 || true
  tmux send-keys "${1}" C-m
}


function process-templates {
  source ${HOME}/stackrc
  eval "${THT}/tools/process-templates.py -p ${THT} -r ${THT}/roles_data.yaml -n ${HOME}/net-data.yaml -o /tmp/templates/"
}


function upgrade-undercloud {
  sudo tripleo-repos -b master current-tripleo
  sudo dnf -y update python-tripleoclient* openstack-tripleo-common openstack-tripleo-heat-templates

  source ${HOME}/stackrc

  openstack tripleo container image prepare default \
            --local-push-destination \
            --output-env-file ${HOME}/containers-prepare-parameter.yaml

  openstack undercloud upgrade --yes
}


function upgrade-overcloud {
  process-templates

  echo "execute: openstack overcloud upgrade prepare"
  openstack overcloud upgrade prepare --yes --templates ${THT} \
                                            --roles-file ${THT}/roles_data.yaml \
                                            --stack ${STACK_NAME} \
                                            --environment-file ${THT}/environments/disable-telemetry.yaml \
                                            --environment-file ${THT}/environments/enable-swap.yaml \
                                            --environment-file ${THT}/environments/storage/glance-nfs.yaml \
                                            --environment-file ${THT}/environments/storage/cinder-nfs.yaml \
                                            --environment-file /tmp/templates/environments/deployed-server-environment.yaml \
                                            --environment-file ${HOME}/parameters.yaml \
                                            --environment-file ${HOME}/overcloud-baremetal-deployed.yaml \
                                            --environment-file ${HOME}/init-repo.yaml \
                                            --networks-file ${HOME}/net-data.yaml \
                                            --config-download-timeout 1024 \
                                            --timeout 1024 \
                                            --deployed-server \
                                            --disable-validations \
                                            --validation-errors-nonfatal \
                                            --ntp-server ${NTP_SERVER} \
                                            --log-file ${HOME}/deploy.log \
                                            --libvirt-type ${VIRT_TYPE}

  echo "execute: openstack overcloud upgrade run Controller"
  openstack overcloud upgrade run --yes --limit 'Controller' \
                                        --skip-tags validation \
                                        --stack ${STACK_NAME}

  echo "execute: openstack overcloud upgrade run Compute"
  openstack overcloud upgrade run --yes --limit '!Controller' \
                                        --skip-tags validation \
                                        --stack ${STACK_NAME}

  echo "execute: openstack overcloud upgrade converge"
  openstack overcloud upgrade converge --yes --templates ${THT} \
                                             --roles-file ${THT}/roles_data.yaml \
                                             --stack ${STACK_NAME} \
                                             --environment-file ${THT}/environments/disable-telemetry.yaml \
                                             --environment-file ${THT}/environments/enable-swap.yaml \
                                             --environment-file ${THT}/environments/storage/glance-nfs.yaml \
                                             --environment-file ${THT}/environments/storage/cinder-nfs.yaml \
                                             --environment-file /tmp/templates/environments/deployed-server-environment.yaml \
                                             --environment-file ${HOME}/parameters.yaml \
                                             --environment-file ${HOME}/overcloud-baremetal-deployed.yaml \
                                             --environment-file ${HOME}/init-repo.yaml \
                                             --networks-file ${HOME}/net-data.yaml \
                                             --config-download-timeout 1024 \
                                             --timeout 1024 \
                                             --deployed-server \
                                             --disable-validations \
                                             --validation-errors-nonfatal \
                                             --ntp-server ${NTP_SERVER} \
                                             --log-file ${HOME}/deploy.log \
                                             --libvirt-type ${VIRT_TYPE}
}


function setup-standalone-multi-nic {
    export IP="${IP:-192.168.24.2}"
    export NETMASK="${NETMASK:-24}"
    export INTERFACE="${INTERFACE:-eth1}"
    export MTU="$(cat /sys/class/net/${INTERFACE}/mtu)"
    export BRIDGE="br-ctlplane"

    cat <<EOF > $HOME/standalone_parameters.yaml
parameter_defaults:
  CloudName: ${IP}
  ControlPlaneStaticRoutes: []
  Debug: true
  DeploymentUser: ${USER}
  DnsServers:
    - 1.1.1.1
    - 8.8.8.8
  DockerInsecureRegistryAddress:
    - ${IP}:8787
  NeutronPublicInterface: ${INTERFACE}
  # domain name used by the host
  CloudDomain: localdomain
  NeutronDnsDomain: localdomain
  # re-use ctlplane bridge for public net, defined in the standalone
  # net config (do not change unless you know what you're doing)
  NeutronBridgeMappings: datacentre:${BRIDGE}
  NeutronPhysicalBridge: ${BRIDGE}
  # enable to force metadata for public net
  #NeutronEnableForceMetadata: true
  StandaloneEnableRoutedNetworks: false
  StandaloneHomeDir: ${HOME}
  InterfaceLocalMtu: ${MTU}
  # Needed if running in a VM, not needed if on baremetal
  NovaComputeLibvirtType: ${VIRT_TYPE}
EOF

}


function setup-standalone-single-nic {
    export INTERFACE="$(ip -o r g 1 | awk '{print $5}')"
    export CIDR=$(ip -o -4 a l | grep -w "${INTERFACE}\s" | awk '{print $4}' | head -n 1)
    export IP=$(echo ${CIDR} | awk -F'/' '{print $1}')
    export NETMASK=$(echo ${CIDR} | awk -F'/' '{print $2}')
    export GATEWAY="$(ip -o r g 1 | awk '{print $3}')"
    export MTU="$(cat /sys/class/net/${INTERFACE}/mtu)"
    export BRIDGE="br-ctlplane"

    sudo dd of=/etc/sysconfig/network-scripts/route-${BRIDGE} <<EOF
default via ${GATEWAY} dev ${BRIDGE}
EOF
    cat <<EOF > ${HOME}/standalone_parameters.yaml
parameter_defaults:
  CloudName: ${IP}
  # default gateway
  ControlPlaneStaticRoutes:
    - ip_netmask: 0.0.0.0/0
      next_hop: ${GATEWAY}
      default: true
  Debug: true
  DeploymentUser: ${USER}
  DnsServers:
    - 1.1.1.1
    - 8.8.8.8
  # needed for vip & pacemaker
  KernelIpNonLocalBind: 1
  DockerInsecureRegistryAddress:
    - ${IP}:8787
  NeutronPublicInterface: ${INTERFACE}
  # domain name used by the host
  CloudDomain: localdomain
  NeutronDnsDomain: localdomain
  # re-use ctlplane bridge for public net, defined in the standalone
  # net config (do not change unless you know what you're doing)
  NeutronBridgeMappings: datacentre:${BRIDGE}
  NeutronPhysicalBridge: ${BRIDGE}
  # enable to force metadata for public net
  #NeutronEnableForceMetadata: true
  StandaloneEnableRoutedNetworks: false
  StandaloneHomeDir: ${HOME}
  InterfaceLocalMtu: ${MTU}
  # Needed if running in a VM, not needed if on baremetal
  NovaComputeLibvirtType: ${VIRT_TYPE}
EOF

}


function build-patched-packages {
    cat <<EOF > playbook.yaml
---
- name: Build packages
  hosts: localhost
  connection: local
  vars:
    ansible_user: "$(whoami)"
  roles:
    - role: cloudnull.ansible_tripleo_sdk
      tripleo_sdk_developer_patches:
        - url: "https://review.opendev.org/openstack/tripleo-heat-templates"
          refs: "refs/changes/67/772967/4"
          version: FETCH_HEAD
        - url: "https://review.opendev.org/openstack/python-tripleoclient"
          refs: "refs/changes/84/773284/3"
          version: FETCH_HEAD
        - url: "https://review.opendev.org/openstack/tripleo-common"
          refs: refs/changes/82/773482/1
          version: FETCH_HEAD
EOF
    ansible-galaxy install cloudnull.ansible_tripleo_sdk --force
    rm -fv ${HOME}/tripleo-sdk/packages.created
    ansible-playbook -i localhost, playbook.yaml
}


function get-overcloud-images {
  mkdir -p ${HOME}/images
  pushd ${HOME}/images
    IMAGE_URL="https://images.rdoproject.org/centos8/master/rdo_trunk/current-tripleo/"
    curl "${IMAGE_URL}/ironic-python-agent.tar" -o ironic-python-agent.tar
    tar xf ironic-python-agent.tar
    curl "${IMAGE_URL}/overcloud-full.tar" -o overcloud-full.tar
    tar xf overcloud-full.tar
    openstack --os-cloud undercloud overcloud image upload --update-existing --local
  popd
  sudo chown 42422:42422 /var/lib/ironic/images/*
}


function build-overcloud-images {
  source ${HOME}/stackrc

  mkdir -p ${HOME}/images
  pushd ${HOME}/images
    mkdir -p ${HOME}/elements
    pushd ${HOME}/elements
      git clone https://opendev.org/openstack/tripleo-puppet-elements || true
      git clone https://opendev.org/openstack/tripleo-image-elements || true
      git clone https://opendev.org/openstack/heat-agents || true
      git clone https://opendev.org/openstack/ironic-python-agent-builder || true
      git clone https://opendev.org/openstack/instack-undercloud || true
    popd
    export ELEMENTS_PATH="${HOME}/elements/tripleo-puppet-elements/elements:${HOME}/elements/tripleo-image-elements/elements:${HOME}/elements/heat-agents:${HOME}/elements/ironic-python-agent-builder/dib/"
    export DIB_DEBUG_TRACE=1
    export DIB_YUM_REPO_CONF="/etc/yum.repos.d/*"
    grep -rnil '\#\!.*python*' "${HOME}/elements" | xargs -n 1 pathfix.py -i $(which python3) -p -n
    openstack --os-cloud undercloud overcloud image build
    openstack --os-cloud undercloud overcloud image upload --update-existing --local
  popd

  sudo chown 42422:42422 /var/lib/ironic/images/*
}


function generate-roles {
  cp -r /usr/share/openstack-tripleo-heat-templates/roles ${HOME}/tripleo-roles
  openstack --os-cloud undercloud overcloud roles generate \
            --output ${HOME}/generated-roles-data.yaml \
            --roles-path ${HOME}/tripleo-roles \
            $(openstack --os-cloud undercloud overcloud role list)
  echo -e "The generated roles data in [ ${HOME}/generated-roles-data.yaml ] needs to be customized before being used. When ready to deploy, rename the file [ roles-data.yaml ]."
}


function network-provision {
  process-templates
  openstack --os-cloud undercloud overcloud network provision \
                                                    --yes \
                                                    --output ${HOME}/overcloud-networks-deployed.yaml \
                                                    ${HOME}/net-data.yaml
  openstack --os-cloud undercloud overcloud network vip provision \
                                                        --yes \
                                                        --stack ${STACK_NAME} \
                                                        --output ${HOME}/overcloud-vip-deployed.yaml \
                                                        ${HOME}/network-vips.yaml
}


function baremetal-unprovision {
  source ${HOME}/stackrc
  metalsmith list | awk "/${STACK_NAME}/ {print $2}" | xargs -n 1 metalsmith undeploy
  openstack --os-cloud undercloud baremetal node delete $(openstack baremetal node list -f value | awk '{print $1}')
}


function baremetal-import {
  openstack --os-cloud undercloud overcloud node import instackenv.yaml
}


function baremetal-inspect {
  openstack --os-cloud undercloud overcloud node introspect \
            --all-manageable \
            --provide \
            --concurrency 2
}


function baremetal-provision {
  openstack --os-cloud undercloud overcloud node provision \
            --stack ${STACK_NAME} \
            --network-config \
            --output ${HOME}/overcloud-baremetal-deployed.yaml \
            ${HOME}/baremetal-config.yaml
}


function apply-workarounds {
  bash -x ${HOME}/workarounds/*
}


function make-swap {
  if [[ ! -f /swapfile ]]; then
    sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
    sudo sysctl -w vm.swappiness=10 > /etc/sysctl.d/99-swap.conf
  fi
}


function pre-build {
  make-swap
  sudo hostnamectl set-hostname $(hostname -s).localdomain
  sudo hostnamectl set-hostname $(hostname -s).localdomain --transient

  # Prune interface files to match only our active networks
  ls -1 /etc/sysconfig/network-scripts/ | grep -w 'ifcfg' | sed 's/ifcfg-//g' | xargs -i -n 1 bash -c "(ip link show {} || sudo rm -f /etc/sysconfig/network-scripts/ifcfg-{})"

  [ -f ${HOME}/.ssh/id_rsa.pub ] || ssh-keygen -t rsa -f ${HOME}/.ssh/id_rsa -q -P ""

  curl https://trunk.rdoproject.org/centos8/current/delorean.repo | sudo tee /etc/yum.repos.d/delorean.repo

  sudo dnf install -y 'python*tripleo-repos'

  sudo tripleo-repos -b master current-tripleo

  sudo dnf -y install NetworkManager qemu-guest-agent vim network-scripts patch git patchutils iptables-services \
                      python*-virtualenv tmux OpenIPMI ipmitool python*tripleoclient patch git patchutils \
                      iptables-services python*tripleoclient
}


function deploy-overcloud {
  openstack --os-cloud undercloud overcloud deploy --stack ${STACK_NAME} \
                                                   --templates ${THT} \
                                                   --environment-file ${THT}/environments/enable-swap.yaml \
                                                   --environment-file ${THT}/environments/storage/glance-nfs.yaml \
                                                   --environment-file ${THT}/environments/storage/cinder-nfs.yaml \
                                                   --environment-file ${HOME}/overcloud-baremetal-deployed.yaml \
                                                   --environment-file ${HOME}/overcloud-networks-deployed.yaml \
                                                   --environment-file ${HOME}/overcloud-vip-deployed.yaml \
                                                   --environment-file ${HOME}/parameters.yaml \
                                                   --roles-file ${HOME}/roles-data.yaml \
                                                   --config-download-timeout 1024 \
                                                   --timeout 1024 \
                                                   --disable-validations \
                                                   --validation-errors-nonfatal \
                                                   --ntp-server ${NTP_SERVER} \
                                                   --log-file ${HOME}/deploy.log \
                                                   --libvirt-type ${VIRT_TYPE}
}


function deploy-standalone {
  openstack tripleo container image prepare default --output-env-file ${HOME}/containers-prepare-parameters.yaml

  export VIP="192.168.25.2"

  sudo openstack tripleo deploy --templates \
                                --local-ip=${IP}/${NETMASK} \
                                --control-virtual-ip ${VIP} \
                                -r /usr/share/openstack-tripleo-heat-templates/roles/Standalone.yaml \
                                --environment-file /usr/share/openstack-tripleo-heat-templates/environments/standalone/standalone-tripleo.yaml \
                                --environment-file ${HOME}/containers-prepare-parameters.yaml \
                                --environment-file ${HOME}/standalone_parameters.yaml \
                                --standalone-role Standalone \
                                --output-dir ${HOME} \
                                --stack ${STACK_NAME}
}


function deploy-undercloud {
  sudo modprobe br-netfilter

  [ -f "/etc/sysconfig/network-scripts/ifcfg-vlan-vlan${TENANT_VLAN}" ] || \
      sudo nmcli connection add type vlan ifname "vlan${TENANT_VLAN}" \
      dev $(ip -o route get 1 | awk '{print $5}') \
      id "${TENANT_VLAN}" \
      ip4 172.16.4.2/24 \
      gw4 172.16.4.1

  echo "br_netfilter" | sudo tee /etc/modules-load.d/99-netfilter.conf
  process-templates
  openstack undercloud install --no-validations
}


function cloud-teardown {
  baremetal-unprovision
  openstack --os-cloud undercloud overcloud delete --yes "${STACK_NAME}"
  openstack --os-cloud undercloud port list -f value | awk "/${STACK_NAME}/ {print \$1}"| xargs -n 1 openstack --os-cloud undercloud port delete
  openstack --os-cloud undercloud subnet list -f value | grep -v ctlplane | awk '{print $1}' | xargs -n 1 openstack subnet delete
  openstack --os-cloud undercloud network list -f value | grep -v ctlplane | awk '{print $1}' | xargs -n 1 openstack network delete
}


function post-deploy {
  sudo mount -t nfs ${NFS_SERVER}:/mnt/storage/media/rhv /mnt

  . ${HOME}/${STACK_NAME}rc

  for NAME in ubuntu-focal-server-cloudimg-amd64-disk-kvm.img \
              ubuntu-bionic-server-cloudimg-amd64.img \
              Fedora-Cloud-Base-33-1.2.x86_64.qcow2 \
              CentOS-8-stream-x86_64.qcow2 \
              CentOS-Stream-GenericCloud-9.qcow2 \
              rhel-8-x86_64-kvm.qcow2; do
    openstack image create --disk-format qcow2 --container-format bare --public --file /mnt/images/${NAME} ${NAME}
    openstack image set --property hw_scsi_model=virtio-scsi \
                        --property hw_disk_bus=scsi \
                        --property hw_vif_multiqueue_enabled=true \
                        --property hw_qemu_guest_agent=yes \
                        --property hypervisor_type=kvm \
                        --property os_require_quiesce=yes \
                        --property img_config_drive=optional \
                        ${NAME}
  done

  openstack flavor create --ram 2048 --disk 16 --ephemeral 0 --swap 8 --vcpus 2 --public k0.small
  openstack flavor create --ram 4096 --disk 32 --ephemeral 0 --swap 8 --vcpus 6 --public k0.tester
  openstack flavor create --ram 8192 --disk 64 --ephemeral 16 --swap 8 --vcpus 8 --public k0.medium
  openstack flavor create --ram 16384 --disk 96 --ephemeral 16 --swap 8 --vcpus 16 --public k0.tripleo

  openstack network create --provider-network-type vlan \
                           --external \
                           --provider-physical-network datacentre \
                           --provider-segment "${TENANT_VLAN}" \
                           --share \
                           "os-${TENANT_VLAN}"
  openstack network create internal

  openstack subnet create --dhcp \
                          --subnet-range 172.16.4.0/24 \
                          --allocation-pool 'start=172.16.4.150,end=172.16.4.200' \
                          --gateway 172.16.4.1 \
                          --dns-nameserver 8.8.8.8 \
                          --network "os-${TENANT_VLAN}" \
                          "os-${TENANT_VLAN}_subnet"
  openstack subnet create --dhcp \
                          --subnet-range 10.0.10.0/24 \
                          --dns-nameserver 8.8.8.8 \
                          --network internal \
                          internal_subnet

  openstack router create internal_router
  openstack router set --external-gateway "os-${TENANT_VLAN}" internal_router
  openstack router add subnet internal_router internal_subnet

  GROUP_ID=$(openstack security group list --project admin | awk '/default/ {print $2}')
  openstack security group rule create --project admin --proto ANY --remote-ip '0.0.0.0/0' --ethertype IPv4 "${GROUP_ID}"
  openstack security group rule create --project admin --proto ANY --remote-ip '::/0' --ethertype IPv6 "${GROUP_ID}"
}
