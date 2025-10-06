#!/bin/bash
# Enable strict mode for robust error handling
set -euo pipefail
trap 'echo "failed: [line $LINENO: command \`$BASH_COMMAND\`]"; exit 1' ERR

# Function to print task titles
PRINT_TASK() {
    max_length=110
    task_title="$1"
    title_length=${#task_title}
    stars=$((max_length - title_length))
    echo "$task_title$(printf '*%.0s' $(seq 1 $stars))"
}

# Function to check result
run_command() {
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo "ok: $1"
    else
        echo "failed: $1"
        exit 1
    fi
}

# ------------------------------
# Step 0: 用户交互式输入基本参数
# ------------------------------
echo
PRINT_TASK "TASK [Collect user input for SNO configuration]"

read -p "请输入 OpenShift 版本 [默认: 4.16.20]: " OCP_VERSION
OCP_VERSION=${OCP_VERSION:-4.16.20}

read -p "请输入架构 [默认: x86_64]: " ARCH
ARCH=${ARCH:-x86_64}

read -p "请输入集群名称 [默认: sno]: " CLUSTER_NAME
CLUSTER_NAME=${CLUSTER_NAME:-sno}

read -p "请输入基础域名 (例如 example.com): " BASE_DOMAIN
BASE_DOMAIN=${BASE_DOMAIN:-example.com}

read -p "请输入 SNO 节点 IP 地址: " SNO_IP
read -p "请输入 网关 IP 地址: " SNO_GW
read -p "请输入 子网掩码 [默认: 255.255.255.0]: " SNO_NETMASK
SNO_NETMASK=${SNO_NETMASK:-255.255.255.0}

read -p "请输入 DNS 地址 [默认: 8.8.8.8]: " SNO_DNS
SNO_DNS=${SNO_DNS:-8.8.8.8}

read -p "请输入 安装磁盘设备路径 [默认: /dev/sda]: " SNO_DISK
SNO_DISK=${SNO_DISK:-/dev/sda}

read -p "请输入 网卡接口名称 [默认: ens192]: " SNO_INTERFACE
SNO_INTERFACE=${SNO_INTERFACE:-ens192}

read -p "请输入 客户端架构 (mac-arm64/mac/linux) [默认: mac-arm64]: " CLIENT_OS_ARCH
CLIENT_OS_ARCH=${CLIENT_OS_ARCH:-mac-arm64}

read -p "请输入 SSH 密钥路径 [默认: $HOME/.ssh]: " SSH_KEY_PATH
SSH_KEY_PATH=${SSH_KEY_PATH:-$HOME/.ssh}

read -p "请输入 Pull Secret 文件路径 [默认: $HOME/pull-secret]: " PULL_SECRET_PATH
PULL_SECRET_PATH=${PULL_SECRET_PATH:-$HOME/pull-secret}

echo
echo "================= 配置信息确认 ================="
echo "OpenShift 版本:       $OCP_VERSION"
echo "架构:                 $ARCH"
echo "集群名称:             $CLUSTER_NAME"
echo "基础域名:             $BASE_DOMAIN"
echo "SNO IP:               $SNO_IP"
echo "网关:                 $SNO_GW"
echo "子网掩码:             $SNO_NETMASK"
echo "DNS:                  $SNO_DNS"
echo "磁盘:                 $SNO_DISK"
echo "网卡:                 $SNO_INTERFACE"
echo "客户端架构:           $CLIENT_OS_ARCH"
echo "SSH 密钥路径:         $SSH_KEY_PATH"
echo "Pull Secret 路径:     $PULL_SECRET_PATH"
echo "================================================"
read -p "是否确认以上信息正确？(y/n): " confirm
[ "$confirm" != "y" ] && echo "已取消。" && exit 1

# ------------------------------
# Step 1: 清理旧资源
# ------------------------------
PRINT_TASK "TASK [Delete old SNO resources...]"
echo "info: [delete old sno resources...]"
rm -rf oc kubectl oc.tar.gz openshift-install openshift-install-$CLIENT_OS_ARCH.tar.gz ocp rhcos-live.iso README.md >/dev/null 2>&1 || true
echo

# ------------------------------
# Step 2: 下载 openshift 客户端工具
# ------------------------------
PRINT_TASK "TASK [Generating the installation ISO with coreos-installer]"

echo "info: [Preparing download of openshift-client tool]"
curl -s -k https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP_VERSION/openshift-client-$CLIENT_OS_ARCH.tar.gz -o oc.tar.gz
run_command "[Download openshift client tool]"

tar zxf oc.tar.gz >/dev/null 2>&1
run_command "[Install openshift client tool]"

chmod +x oc >/dev/null 2>&1
run_command "[Set permissions for oc client]"

echo "info: [Preparing download of openshift-install tool]"
curl -s -k https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP_VERSION/openshift-install-$CLIENT_OS_ARCH.tar.gz -o openshift-install-$CLIENT_OS_ARCH.tar.gz
run_command "[Download openshift install tool]"

tar -xzf openshift-install-$CLIENT_OS_ARCH.tar.gz >/dev/null 2>&1
run_command "[Install openshift install tool]"

chmod +x openshift-install >/dev/null 2>&1
run_command "[Set permissions for openshift install]"

# ------------------------------
# Step 3: 下载 RHCOS ISO 并生成配置
# ------------------------------
ISO_URL=$(./openshift-install coreos print-stream-json | grep location | grep $ARCH | grep iso | cut -d\" -f4)
echo "info: [Preparing download of rhcos-live.iso]"
curl -s -L $ISO_URL -o rhcos-live.iso >/dev/null 2>&1
run_command "[Download rhcos-live.iso]"

if [ ! -f "${SSH_KEY_PATH}/id_rsa" ] || [ ! -f "${SSH_KEY_PATH}/id_rsa.pub" ]; then
    rm -rf ${SSH_KEY_PATH} 
    mkdir -p ${SSH_KEY_PATH}
    ssh-keygen -t rsa -N '' -f ${SSH_KEY_PATH}/id_rsa >/dev/null 2>&1
    echo "ok: [Create ssh-key for accessing coreos]"
else
    echo "skipped: [Create ssh-key for accessing coreos]"
fi

export SSH_PUB_STR="$(cat ${SSH_KEY_PATH}/id_rsa.pub)"

mkdir ocp
run_command "[Create installation directory: ocp]"

cat << EOF > ocp/install-config.yaml
apiVersion: v1
baseDomain: $BASE_DOMAIN
compute:
- name: worker
  replicas: 0 
controlPlane:
  name: master
  replicas: 1 
metadata:
  name: $CLUSTER_NAME
networking: 
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16 
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
bootstrapInPlace:
  installationDisk: $SNO_DISK
pullSecret: '$(cat $PULL_SECRET_PATH)'
sshKey: '${SSH_PUB_STR}'
EOF
run_command "[Create ocp/install-config.yaml file]"

./openshift-install --dir=ocp create single-node-ignition-config >/dev/null 2>&1
run_command "[Create single-node-ignition-config]"

# ------------------------------
# Step 4: 制作可引导 ISO
# ------------------------------
podman run --privileged --pull always --rm -v /dev:/dev -v /run/udev:/run/udev -v $PWD:/data -w /data quay.io/coreos/coreos-installer:release iso ignition embed -fi ocp/bootstrap-in-place-for-live-iso.ign rhcos-live.iso >/dev/null 2>&1
run_command "[Embed ignition configuration into the coreos live iso]"

podman run --privileged --pull always --rm -v /dev:/dev -v /run/udev:/run/udev -v $PWD:/data -w /data quay.io/coreos/coreos-installer:release iso kargs modify -a "ip=$SNO_IP::$SNO_GW:$SNO_NETMASK:$CLUSTER_NAME.$BASE_DOMAIN:$SNO_INTERFACE:off:$SNO_DNS" rhcos-live.iso >/dev/null 2>&1
run_command "[Modify kernel arguments for network configuration]"

rm -rf oc.tar.gz kubectl openshift-install-$CLIENT_OS_ARCH.tar.gz README.md >/dev/null 2>&1 || true

PRINT_TASK "✅ All tasks completed successfully."
