#!/bin/bash

WORK_DIR=$(cd `dirname $0`; pwd)
. ${WORK_DIR}/install_k8s.env
HOSTNAME=`hostname`

detect_advertise_ip() {
    if [ -z "$MASTER_ADVERTISE_IP" ]; then
        ips=$(ip -4 -o addr show|grep eth|awk '{print $4}')
        for i in $ips; do
            ret=$(echo $i|grep -E '^(192\.168|10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.)[^ /]+' -o)
            [ -n "$ret" ] && MASTER_ADVERTISE_IP="$ret" && break
        done
    fi

    if [ -z "$MASTER_ADVERTISE_IP" ]; then
        echo "Failed to detect private ip. Will let kubeadm decide which ip to advertise."
    else
        echo "Using $MASTER_ADVERTISE_IP as advertise ip"
    fi
}

prepare_env() {
    mkdir -p ${TMP_DIR} ${CNI_BIN_DIR} ${K8S_CONF_DIR} ${K8S_LOG_DIR} ${K8S_BIN_DIR} ${TARGET_CERT_DIR} ${KUBE_CONF_DIR}
    cp -f ${WORK_DIR}/k8s_bin/* ${K8S_BIN_DIR}/
    cp -f ${WORK_DIR}/k8s_conf/* ${K8S_CONF_DIR}/
    cp -f ${WORK_DIR}/k8s_pki/* ${TARGET_CERT_DIR}/
    sed -i "s/API_SERVER_ADDRESS/https:\/\/${MASTER_ADVERTISE_IP}:${API_SERVER_PORT}/" ${K8S_CONF_DIR}/${CONTROLLER_MANAGER_CONF_FILE}
    sed -i "s/API_SERVER_ADDRESS/https:\/\/${MASTER_ADVERTISE_IP}:${API_SERVER_PORT}/" ${K8S_CONF_DIR}/${ADMIN_CONF_FILE}
    sed -i "s/API_SERVER_ADDRESS/https:\/\/${MASTER_ADVERTISE_IP}:${API_SERVER_PORT}/" ${K8S_CONF_DIR}/${SCHEDULER_CONF_FILE}
    cp -f ${K8S_CONF_DIR}/${ADMIN_CONF_FILE} ${KUBE_CONF_DIR}/config
}

install_etcd() {
    tar zxf ${PACKAGE_DIR}/${ETCD_TAR_FILE} -C ${TMP_DIR}
    cp -f ${TMP_DIR}/${ETCD_TAR_FILE%.tar.gz}/etcd ${ETCD_BIN_DIR}
    cp -f ${TMP_DIR}/${ETCD_TAR_FILE%.tar.gz}/etcdctl ${ETCD_BIN_DIR}

    cat <<-END
Installing etcd...
etcd bin dir: ${ETCD_BIN_DIR}, lib dir: ${ETCD_LIB_DIR}, conf dir: ${ETCD_CONF_DIR}.
END
    mkdir -p ${ETCD_BIN_DIR} $ETCD_LIB_DIR $ETCD_CONF_DIR

    groupadd -r etcd
    useradd -r -g etcd -d $ETCD_LIB_DIR -s /sbin/nologin -c "etcd user" etcd
    chown -R etcd:etcd $ETCD_LIB_DIR

    cat << EOT > /usr/lib/systemd/system/etcd.service
[Unit]
Description=etcd service
After=network.target

[Service]
Type=notify
WorkingDirectory=$ETCD_LIB_DIR
EnvironmentFile=${ETCD_CONF_DIR}/etcd.conf
User=etcd
ExecStart=${ETCD_BIN_DIR}/etcd
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOT

    cat << EOT > ${ETCD_CONF_DIR}/etcd.conf
 # [member]
 ETCD_NAME=k8s-cluster-etcd
 ETCD_DATA_DIR="${ETCD_LIB_DIR}/default.etcd"
 ETCD_LISTEN_CLIENT_URLS="http://${MASTER_ADVERTISE_IP}:${ETCD_PORT}"
 ETCD_ADVERTISE_CLIENT_URLS="http://${MASTER_ADVERTISE_IP}:${ETCD_PORT}"
EOT

    systemctl enable etcd
    systemctl start etcd
    echo "etcd installed.\n"
}

install_apiserver() {
    cat << EOT > /usr/lib/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
After=etcd.service
Wants=etcd.service

[Service]
EnvironmentFile=${K8S_CONF_DIR}/apiserver
ExecStart=${K8S_BIN_DIR}/kube-apiserver \$KUBE_API_ARGS
Restart=on-failure
User=root
Type=notify
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOT

    cat << EOT > ${K8S_CONF_DIR}/apiserver
KUBE_API_ARGS="--etcd-servers=http://${MASTER_ADVERTISE_IP}:${ETCD_PORT} \
 --allow-privileged=true \
 --tls-cert-file=${TARGET_CERT_DIR}/${API_SERVER_CERT_FILE} \
 --tls-private-key-file=${TARGET_CERT_DIR}/${API_SERVER_KEY_FILE} \
 --kubelet-client-certificate=${TARGET_CERT_DIR}/${API_SERVER_CLIENT_CERT_FILE} \
 --secure-port=${API_SERVER_PORT} \
 --admission-control=Initializers,NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,DefaultTolerationSeconds,NodeRestriction,ResourceQuota \
 --service-cluster-ip-range=${SERVICE_IP_RANGE_PREFFIX}0/12 \
 --insecure-port=0 \
 --feature-gates=Accelerators=true \
 --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname \
 --client-ca-file=${TARGET_CERT_DIR}/${CA_CERT_FILE} \
 --kubelet-client-key=${TARGET_CERT_DIR}/${API_SERVER_CLIENT_KEY_FILE} \
 --service-account-key-file=${TARGET_CERT_DIR}/${SERVICE_ACCOUNT_PUB_KEY_FILE} \
 --experimental-bootstrap-token-auth=true \
 --authorization-mode=Node,RBAC \
 --advertise-address=${MASTER_ADVERTISE_IP} \
 --logtostderr=false \
 --log-dir=${K8S_LOG_DIR}"
EOT

    systemctl enable kube-apiserver
    systemctl start kube-apiserver
}

install_controller_manager() {
    cat << EOT > /usr/lib/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
After=kube-apiserver.service
Requires=kube-apiserver.service

[Service]
EnvironmentFile=${K8S_CONF_DIR}/controller-manager
ExecStart=${K8S_BIN_DIR}/kube-controller-manager \$KUBE_CONTROLLER_MANAGER_ARGS
User=root
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOT

    cat << EOT > ${K8S_CONF_DIR}/controller-manager
KUBE_CONTROLLER_MANAGER_ARGS="--cluster-signing-cert-file=${TARGET_CERT_DIR}/${CA_CERT_FILE} \
--leader-elect=true \
--use-service-account-credentials=true \
--kubeconfig=${K8S_CONF_DIR}/${CONTROLLER_MANAGER_CONF_FILE} \
--root-ca-file=${TARGET_CERT_DIR}/${CA_CERT_FILE} \
--service-account-private-key-file=${TARGET_CERT_DIR}/${SERVICE_ACCOUNT_PRI_KEY_FILE} \
--address=${MASTER_ADVERTISE_IP} \
--controllers=* \
--cluster-signing-key-file=${TARGET_CERT_DIR}/${CA_KEY_FILE} \
--cluster-cidr=10.244.0.0/16 \
--logtostderr=false \
--log-dir=${K8S_LOG_DIR}"
EOT

    systemctl enable kube-controller-manager
    systemctl start kube-controller-manager
}

install_scheduler() {
    cat << EOT > /usr/lib/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
After=kube-apiserver.service
Requires=kube-apiserver.service

[Service]
EnvironmentFile=${K8S_CONF_DIR}/scheduler
ExecStart=${K8S_BIN_DIR}/kube-scheduler \$KUBE_SCHEDULER_ARGS
Restart=on-failure
User=root
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOT

cat << EOT > ${K8S_CONF_DIR}/scheduler
KUBE_SCHEDULER_ARGS="--address=${MASTER_ADVERTISE_IP} \
--leader-elect=true \
--kubeconfig=${K8S_CONF_DIR}/${SCHEDULER_CONF_FILE} \
--logtostderr=false \
--log-dir=${K8S_LOG_DIR}"
EOT

    systemctl enable kube-scheduler
    systemctl start kube-scheduler
}

install_docker() {
    echo "Installing docker...\n"
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

install_docker_registry() {
    docker load < ${PACKAGE_DIR}/${DOCKER_REGISTRY_TAR}
    docker run -d -p ${DOCKER_REGISTRY_PORT}:${DOCKER_REGISTRY_PORT} --name registry -v ${DOCKER_REGISTRY_DATA_DIR}:/var/lib/registry registry:2
    # push the pause image to local registry.
    docker load < ${PACKAGE_DIR}/${PAUSE_IMAGE_TAR}
    docker tag ${PAUSE_IMAGE_NAME} ${MASTER_ADVERTISE_IP}:${DOCKER_REGISTRY_PORT}/${PAUSE_IMAGE}
    docker push ${MASTER_ADVERTISE_IP}:${DOCKER_REGISTRY_PORT}/${PAUSE_IMAGE}
}

set_flannel_ip_range() {
    etcdctl --endpoint=http://${MASTER_ADVERTISE_IP}:${ETCD_PORT} set /coreos.com/network/config '{"Network":"10.244.0.0/16","SubnetLen":24,"Backend":{"Type":"vxlan","VNI":0}}'
}

update_bridge() {
    grep "^net.bridge.bridge-nf-call-arptables" /etc/sysctl.conf >>/dev/null || echo "net.bridge.bridge-nf-call-arptables = 1" >> /etc/sysctl.conf
    grep "^net.bridge.bridge-nf-call-iptables" /etc/sysctl.conf >>/dev/null || echo "net.bridge.bridge-nf-call-iptables = 1" >> /etc/sysctl.conf
    grep "^net.bridge.bridge-nf-call-ip6tables" /etc/sysctl.conf >>/dev/null || echo "net.bridge.bridge-nf-call-ip6tables = 1" >> /etc/sysctl.conf
    sysctl -p >>/dev/null
}

set_node_auth() {
    # wait for the api-server
    sleep 30
    kubectl --kubeconfig ${K8S_CONF_DIR}/admin.conf patch clusterrolebinding system:node -p '{"subjects":[{"apiGroup": "rbac.authorization.k8s.io","kind":"Group","name":"system:nodes"}]}'
    systemctl restart kube-apiserver
}

create_ssl_cert() {
    cat << EOT > ${TARGET_CERT_DIR}/${API_SERVER_CERT_CONF}
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn

[ dn ]
CN = kube-apiserver

[ alt_names ]
DNS.1 = ${HOSTNAME}
IP.1 = ${MASTER_ADVERTISE_IP}
IP.2 = ${SERVICE_IP_RANGE_PREFFIX}1

[ v3_ext ]
keyUsage=keyEncipherment,dataEncipherment
basicConstraints=CA:FALSE
extendedKeyUsage=serverAuth
subjectAltName=@alt_names
EOT
    openssl genrsa -out ${TARGET_CERT_DIR}/${API_SERVER_KEY_FILE} 2048
    openssl req -new -key ${TARGET_CERT_DIR}/${API_SERVER_KEY_FILE} \
        -out ${TARGET_CERT_DIR}/${API_SERVER_CERT_REQ} \
        -config ${TARGET_CERT_DIR}/${API_SERVER_CERT_CONF}
    openssl x509 -req -in ${TARGET_CERT_DIR}/${API_SERVER_CERT_REQ} \
        -CA ${TARGET_CERT_DIR}/${CA_CERT_FILE} \
        -CAkey ${TARGET_CERT_DIR}/${CA_KEY_FILE} \
        -CAcreateserial -out ${TARGET_CERT_DIR}/${API_SERVER_CERT_FILE} \
        -days 10000 -extensions v3_ext \
        -extfile ${TARGET_CERT_DIR}/${API_SERVER_CERT_CONF}

    cat << EOT > ${TARGET_CERT_DIR}/${API_SERVER_CLIENT_CERT_CONF}
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn

[ dn ]
O = system:masters
CN = kube-apiserver-kubelet-client

[ v3_ext ]
keyUsage=keyEncipherment,dataEncipherment
extendedKeyUsage=clientAuth
EOT
    openssl genrsa -out ${TARGET_CERT_DIR}/${API_SERVER_CLIENT_KEY_FILE} 2048
    openssl req -new -key ${TARGET_CERT_DIR}/${API_SERVER_CLIENT_KEY_FILE} \
        -out ${TARGET_CERT_DIR}/${API_SERVER_CLIENT_CERT_REQ} \
        -config ${TARGET_CERT_DIR}/${API_SERVER_CLIENT_CERT_CONF}
    openssl x509 -req -in ${TARGET_CERT_DIR}/${API_SERVER_CLIENT_CERT_REQ} \
        -CA ${TARGET_CERT_DIR}/${CA_CERT_FILE} \
        -CAkey ${TARGET_CERT_DIR}/${CA_KEY_FILE} \
        -CAcreateserial -out ${TARGET_CERT_DIR}/${API_SERVER_CLIENT_CERT_FILE} \
        -days 10000 -extensions v3_ext \
        -extfile ${TARGET_CERT_DIR}/${API_SERVER_CLIENT_CERT_CONF}
}

main() {
    [ "$(id -u)" != "0" ] && {
         echo "This script must be run as root.\n" 1>&2
         exit 1
    }
    detect_advertise_ip
    prepare_env
    update_bridge

    install_etcd
    set_flannel_ip_range
    install_docker
    install_docker_registry
    create_ssl_cert
    install_apiserver
    install_controller_manager
    install_scheduler
    set_node_auth
    rm -rf ${TMP_DIR}
    echo "\nKubernetes master is installed.\n"
}

main
