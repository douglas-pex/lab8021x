#!/bin/bash
# =====================================================================
# LNX_01_FREERADIUS: instalação e configuração do FreeRADIUS (lab 802.1X)
#
# Uso:
#   bash setup_freeradius.sh install <MAC_DO_VPC_MAB>
#       Fase 0 (com internet). Ex.: bash setup_freeradius.sh install 00:50:79:66:68:01
#   bash setup_freeradius.sh ip-lab
#       Depois de instalar tudo: troca o IP para 10.10.99.10/24 (rede do lab)
#   bash setup_freeradius.sh servir-ca
#       Ainda na Fase 0: publica o certificado da CA para os suplicantes baixarem
# =====================================================================
set -e

MODO="${1:-install}"
RADDB=/etc/freeradius/3.0
RAD_SECRET='Lab8021x!'
SW_IP=10.10.99.2
RAD_IP=10.10.99.10
IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')

passo() { echo; echo "==== $* ===="; }

trocar_espelho() {
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] && sed -i -E 's#https?://mirrors\.tuna\.tsinghua\.edu\.cn/ubuntu#http://br.archive.ubuntu.com/ubuntu#g' "$f"
    done
}

case "$MODO" in

install)
    MAC_MAB=$(echo "${2:-}" | tr 'A-F' 'a-f' | tr -d ':.-')
    if [ ${#MAC_MAB} -ne 12 ]; then
        echo "Informe o MAC do VPC_MAB. Ex.: bash $0 install 00:50:79:66:68:01"
        echo "(no console do VPCS: comando 'show ip')"
        exit 1
    fi

    passo "Hostname, fuso e espelho do apt"
    hostnamectl set-hostname lnx01-freeradius
    timedatectl set-timezone America/Sao_Paulo
    trocar_espelho

    passo "Rede (DHCP da Fase 0) na interface $IFACE"
    ip -4 addr show "$IFACE" | grep -q "inet " || dhclient -v "$IFACE"
    ip -br addr show "$IFACE"

    passo "Pacotes"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y freeradius freeradius-utils tcpdump openssl
    systemctl stop freeradius || true

    passo "Switch como cliente RADIUS (clients.conf)"
    if ! grep -q "client sw01-auth" $RADDB/clients.conf; then
        cat >> $RADDB/clients.conf << EOF

client sw01-auth {
    ipaddr    = $SW_IP
    secret    = $RAD_SECRET
    shortname = sw01-auth
}
EOF
    fi

    passo "Usuários, MAB ($MAC_MAB) e VLAN dinâmica (authorize)"
    AUTH=$RADDB/mods-config/files/authorize
    if ! grep -q "^aluno1" $AUTH; then
        cp $AUTH $AUTH.bak
        cat > /tmp/usuarios_lab << EOF
aluno1      Cleartext-Password := "Senha@123"
            Tunnel-Type = VLAN,
            Tunnel-Medium-Type = IEEE-802,
            Tunnel-Private-Group-Id = "10"

visitante   Cleartext-Password := "Visit@123"
            Tunnel-Type = VLAN,
            Tunnel-Medium-Type = IEEE-802,
            Tunnel-Private-Group-Id = "20"

$MAC_MAB Cleartext-Password := "$MAC_MAB"
            Tunnel-Type = VLAN,
            Tunnel-Medium-Type = IEEE-802,
            Tunnel-Private-Group-Id = "30"

EOF
        cat /tmp/usuarios_lab $AUTH.bak > $AUTH
    fi

    passo "VLAN de dentro do túnel PEAP (inner-tunnel: if (0) -> if (1))"
    sed -i '/Instead of "use_tunneled_reply"/,/^\s*if (0)/ s/^\(\s*\)if (0)/\1if (1)/' $RADDB/sites-available/inner-tunnel
    grep -n -A1 'Instead of "use_tunneled_reply"' $RADDB/sites-available/inner-tunnel | head -4
    grep -n "^\s*if (1)" $RADDB/sites-available/inner-tunnel || echo "ATENÇÃO: bloco if (1) não encontrado, confira o inner-tunnel"

    passo "PEAP como método padrão"
    sed -i -E 's/^(\s*default_eap_type\s*=\s*)md5/\1peap/' $RADDB/mods-available/eap
    grep -n "default_eap_type" $RADDB/mods-available/eap

    passo "Certificados próprios do lab (CA + servidor)"
    CERT=$RADDB/certs/lab
    mkdir -p $CERT
    cd $CERT
    if [ ! -f ca.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
            -keyout ca.key -out ca.pem \
            -subj "/C=BR/O=UNISINOS Lab 8021X/CN=Lab 8021X CA"
        openssl req -newkey rsa:2048 -nodes \
            -keyout server.key -out server.csr \
            -subj "/C=BR/O=UNISINOS Lab 8021X/CN=lnx01-freeradius"
        printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" > server.ext
        openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
            -days 365 -out server.pem -extfile server.ext
    fi
    chown -R root:freerad $CERT
    chmod 750 $CERT
    chmod 640 $CERT/*.key
    cd /

    EAP=$RADDB/mods-available/eap
    sed -i -E "s#^(\s*)private_key_file\s*=.*#\1private_key_file = $CERT/server.key#" $EAP
    sed -i -E "s#^(\s*)certificate_file\s*=.*#\1certificate_file = $CERT/server.pem#" $EAP
    sed -i -E "s#^(\s*)ca_file\s*=.*#\1ca_file = $CERT/ca.pem#" $EAP
    grep -n -E "^\s*(private_key_file|certificate_file|ca_file)\s*=" $EAP

    mkdir -p /root/pub
    cp $CERT/ca.pem /root/pub/lab-ca.pem

    passo "Checagem da configuração"
    freeradius -XC | tail -3

    passo "Teste local com radtest"
    systemctl start freeradius
    sleep 2
    radtest aluno1 'Senha@123' 127.0.0.1 0 testing123 || true
    radtest aluno1 'SenhaErrada' 127.0.0.1 0 testing123 || true
    systemctl stop freeradius

    echo
    echo "Esperado acima: Access-Accept com Tunnel-Private-Group-Id = \"10\" e depois Access-Reject."
    echo "Próximo passo (ainda com internet): bash $0 servir-ca"
    ;;

servir-ca)
    IP_ATUAL=$(ip -4 -o addr show "$IFACE" | awk '{print $4}' | cut -d/ -f1)
    echo "Nos suplicantes, rode:  bash setup_suplicante.sh <hostname> $IP_ATUAL"
    echo "Servindo /root/pub/lab-ca.pem na porta 8000 (Ctrl+C para parar depois que os dois baixarem)"
    cd /root/pub && python3 -m http.server 8000
    ;;

ip-lab)
    passo "IP fixo do lab: $RAD_IP/24 na interface $IFACE"
    if command -v netplan >/dev/null 2>&1; then
        mkdir -p /etc/netplan/bak
        mv /etc/netplan/*.yaml /etc/netplan/bak/ 2>/dev/null || true
        cat > /etc/netplan/99-lab.yaml << EOF
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: false
      addresses: [$RAD_IP/24]
      gateway4: $SW_IP
EOF
        dhclient -r "$IFACE" 2>/dev/null || true
        netplan apply
    else
        cat > /etc/network/interfaces.d/lab << EOF
auto $IFACE
iface $IFACE inet static
    address $RAD_IP/24
    gateway $SW_IP
EOF
        dhclient -r "$IFACE" 2>/dev/null || true
        ip addr flush dev "$IFACE"
        ifup "$IFACE" || systemctl restart networking
    fi
    ip -br addr show "$IFACE"
    echo "Para o lab: systemctl stop freeradius && freeradius -X"
    ;;

*)
    echo "Modos: install <MAC_VPC_MAB> | servir-ca | ip-lab"
    exit 1
    ;;
esac
