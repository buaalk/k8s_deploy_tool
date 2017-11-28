#!/bin/bash

WORK_DIR=$(cd `dirname $0`; pwd)
. ${WORK_DIR}/install_k8s.env
HOSTNAME=`hostname`

prepare_env() {
    mkdir -p ${TMP_DIR} ${CNI_BIN_DIR} ${FLANNEL_BIN_DIR}
    mkdir -p ${TMP_DIR} ${CNI_BIN_DIR} ${K8S_LOG_DIR} ${K8S_BIN_DIR} ${TARGET_CERT_DIR} ${NET_CONF_DIR}
    cp -f ${WORK_DIR}/k8s_bin/* ${K8S_BIN_DIR}/
    cp -f ${WORK_DIR}/k8s_pki/* ${TARGET_CERT_DIR}/
}

install_docker() {
    echo "Installing docker..."
    yum install -y ${PACKAGE_DIR}/${DOCKER_RPM_FILE}

    mkdir -p ${DOCKER_CONF_PATH}
    cat << EOT > ${DOCKER_CONF_PATH}/daemon.json
{
    "graph": "${DOCKER_DATA_PATH}",
    "insecure-registries":["$MASTER_ADVERTISE_IP:$DOCKER_REGISTRY_PORT"]
}
EOT

    systemctl enable docker
    systemctl start docker
}

install_cni() {
    echo "Installing cni..."
    tar zxf ${PACKAGE_DIR}/${CNI_TAR_FILE} -C ${TMP_DIR}
    cp -f ${TMP_DIR}/${CNI_TAR_FILE%.tar.gz}/* ${CNI_BIN_DIR}/
}

install_flannel() {
    tar zxf ${PACKAGE_DIR}/${FLANNEL_TAR_FILE} -C ${TMP_DIR}
    cp -f ${TMP_DIR}/flanneld ${FLANNEL_BIN_DIR}/

    echo "Installing flannel..."
    cat << EOT > ${NET_CONF_DIR}/10-flannel.conf
{
  "name": "cbr0",
  "type": "flannel",
  "delegate": {
    "isDefaultGateway": true
  }
}
EOT

    cat << EOT > /usr/lib/systemd/system/flannel.service
[Unit]
Description=flannel service

[Service]
ExecStart=${FLANNEL_BIN_DIR}/flanneld --etcd-endpoints=http://${MASTER_ADVERTISE_IP}:${ETCD_PORT} --ip-masq
Restart=on-failure
Type=notify
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOT

    systemctl enable flannel
    systemctl start flannel
}

install_kubelet() {
    echo "Installing kubelet..."
    cat << EOT > /usr/lib/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet Server
After=docker.service
Requires=docker.service

[Service]
EnvironmentFile=${K8S_CONF_DIR}/kubelet
ExecStart=${K8S_BIN_DIR}/kubelet \$KUBELET_ARGS
Restart=on-failure
User=root
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOT

    cat << EOT > ${K8S_CONF_DIR}/${KUBELET_CONF_FILE}
apiVersion: v1
clusters:
- cluster:
    certificate-authority: ${TARGET_CERT_DIR}/${CA_CERT_FILE}
    server: https://${MASTER_ADVERTISE_IP}:${API_SERVER_PORT}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: system:node:${HOSTNAME}
  name: system:node:${HOSTNAME}@kubernetes
current-context: system:node:${HOSTNAME}@kubernetes
kind: Config
preferences: {}
users:
- name: system:node:${HOSTNAME}
  user:
    client-certificate: ${TARGET_CERT_DIR}/${KUBELET_CERT_FILE}
    client-key: ${TARGET_CERT_DIR}/${KUBELET_CERT_KEY}
EOT

    cat << EOT > ${K8S_CONF_DIR}/kubelet
KUBELET_ARGS="--kubeconfig=${K8S_CONF_DIR}/${KUBELET_CONF_FILE} \
--require-kubeconfig=true \
--allow-privileged=true \
--cluster-dns=10.96.0.10 \
--cluster-domain=cluster.k8s.local \
--network-plugin=cni \
--authorization-mode=Webhook \
--client-ca-file=${TARGET_CERT_DIR}/${CA_CERT_FILE} \
--cadvisor-port=0 \
--pod-infra-container-image=${MASTER_ADVERTISE_IP}:${DOCKER_REGISTRY_PORT}/${PAUSE_IMAGE} \
--cgroup-driver=cgroupfs \
--feature-gates=Accelerators=true \
--logtostderr=false \
--log-dir=${K8S_LOG_DIR}"
EOT

    systemctl enable kubelet
    systemctl start kubelet
}

update_bridge() {
    grep "^net.bridge.bridge-nf-call-arptables" /etc/sysctl.conf >>/dev/null || echo "net.bridge.bridge-nf-call-arptables = 1" >> /etc/sysctl.conf
    grep "^net.bridge.bridge-nf-call-iptables" /etc/sysctl.conf >>/dev/null || echo "net.bridge.bridge-nf-call-iptables = 1" >> /etc/sysctl.conf
    grep "^net.bridge.bridge-nf-call-ip6tables" /etc/sysctl.conf >>/dev/null || echo "net.bridge.bridge-nf-call-ip6tables = 1" >> /etc/sysctl.conf
    sysctl -p >>/dev/null
}

create_ssl_cert() {
    cat << EOT > ${TARGET_CERT_DIR}/${KUBELET_CERT_CONF}
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn

[ dn ]
O = system:nodes
CN = system:node:${HOSTNAME}

[ v3_ext ]
keyUsage=keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth,clientAuth
EOT
    openssl genrsa -out ${TARGET_CERT_DIR}/${KUBELET_CERT_KEY} 2048
    openssl req -new -key ${TARGET_CERT_DIR}/${KUBELET_CERT_KEY} \
        -out ${TARGET_CERT_DIR}/${KUBELET_CERT_REQ} \
        -config ${TARGET_CERT_DIR}/${KUBELET_CERT_CONF}
    openssl x509 -req -in ${TARGET_CERT_DIR}/${KUBELET_CERT_REQ} \
        -CA ${TARGET_CERT_DIR}/${CA_CERT_FILE} \
        -CAkey ${TARGET_CERT_DIR}/${CA_KEY_FILE} \
        -CAcreateserial -out ${TARGET_CERT_DIR}/${KUBELET_CERT_FILE} \
        -days 10000 -extensions v3_ext \
        -extfile ${TARGET_CERT_DIR}/${KUBELET_CERT_CONF}
}

install_kubeproxy() {
    cat << EOT > /usr/lib/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube-Proxy Server
After=network.target

[Service]
EnvironmentFile=${K8S_CONF_DIR}/proxy
ExecStart=${K8S_BIN_DIR}/kube-proxy \$KUBE_PROXY_ARGS
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOT

    cat << EOT > ${K8S_CONF_DIR}/kube-proxy.conf
apiVersion: v1
clusters:
- cluster:
    certificate-authority: ${TARGET_CERT_DIR}/${CA_CERT_FILE}
    server: https://${MASTER_ADVERTISE_IP}:${API_SERVER_PORT}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: system:kube-proxy
  name: system:kube-proxy@kubernetes
current-context: system:kube-proxy@kubernetes
kind: Config
preferences: {}
users:
- name: system:kube-proxy
  user:
    client-certificate: ${TARGET_CERT_DIR}/${KUBEPROXY_CERT_FILE}
    client-key: ${TARGET_CERT_DIR}/${KUBEPROXY_CERT_KEY}
EOT

    cat << EOT > ${K8S_CONF_DIR}/proxy
KUBE_PROXY_ARGS="--proxy-mode iptables \
--kubeconfig=${K8S_CONF_DIR}/kube-proxy.conf \
--cluster-cidr=10.244.0.1/16 \
--logtostderr=false \
--log-dir=${K8S_LOG_DIR}"
EOT

    systemctl enable kube-proxy
    systemctl start kube-proxy
}

main() {
    [ "$(id -u)" != "0" ] && {
         echo "This script must be run as root" 1>&2
         exit 1
    }
    [ $# != 1 ] && {
         echo "Usage: `basename $0` MASTER_ADVERTISE_IP"
         exit 1
    }
    MASTER_ADVERTISE_IP=$1
    prepare_env
    update_bridge

    install_cni
    install_flannel
    install_docker
    create_ssl_cert
    install_kubelet
    install_kubeproxy
    rm -rf ${TMP_DIR}
}

main $@
