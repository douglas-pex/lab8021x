#!/bin/bash
# =====================================================================
# LNX_02_SUPLICANTE e LNX_03_SUPLICANTE: preparação do suplicante 802.1X
#
# Uso (Fase 0, com internet):
#   bash setup_suplicante.sh <hostname> [IP_DO_FREERADIUS_NA_FASE0]
#   Ex.: bash setup_suplicante.sh lnx02-suplicante 192.168.1.50
#
# O IP do FreeRADIUS é o que ele recebeu por DHCP na Fase 0; serve para
# baixar o certificado da CA (no LNX_01 rode antes: bash setup_freeradius.sh servir-ca).
# Depois, no lab, para autenticar:  bash /root/conectar.sh aluno1
# =====================================================================
set -e

NOME="${1:?Informe o hostname. Ex.: bash $0 lnx02-suplicante 192.168.1.50}"
RAD_FASE0="${2:-}"
IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
WPA=/etc/wpa_supplicant
CA=$WPA/lab-ca.pem

passo() { echo; echo "==== $* ===="; }

passo "Hostname, fuso e espelho do apt"
hostnamectl set-hostname "$NOME"
timedatectl set-timezone America/Sao_Paulo
shopt -s nullglob
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] && sed -i -E 's#https?://mirrors\.tuna\.tsinghua\.edu\.cn/ubuntu#http://br.archive.ubuntu.com/ubuntu#g' "$f"
done
shopt -u nullglob

passo "Rede (DHCP da Fase 0) na interface $IFACE"
ip -4 addr show "$IFACE" | grep -q "inet " || dhclient -v "$IFACE"
ip -br addr show "$IFACE"

passo "Pacotes"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y wpasupplicant isc-dhcp-client tcpdump curl
mkdir -p $WPA

passo "Certificado da CA do FreeRADIUS"
if [ -n "$RAD_FASE0" ]; then
    if curl -fsS "http://$RAD_FASE0:8000/lab-ca.pem" -o $CA; then
        echo "CA baixada em $CA"
        openssl x509 -in $CA -noout -subject -enddate
    else
        rm -f $CA
        echo "ATENÇÃO: não consegui baixar a CA de $RAD_FASE0:8000."
        echo "Confira se o LNX_01 está rodando 'bash setup_freeradius.sh servir-ca' e rode este script de novo."
    fi
else
    echo "Sem IP do FreeRADIUS: os perfis ficam SEM validação do servidor (só para teste)."
fi

passo "Perfis do wpa_supplicant"
perfil() {   # perfil <nome_arquivo> <usuario> <senha>
    {
        echo "ctrl_interface=/var/run/wpa_supplicant"
        echo "ap_scan=0"
        echo
        echo "network={"
        echo "    key_mgmt=IEEE8021X"
        echo "    eap=PEAP"
        echo "    identity=\"$2\""
        echo "    password=\"$3\""
        echo "    phase2=\"auth=MSCHAPV2\""
        if [ -f $CA ]; then echo "    ca_cert=\"$CA\""; fi
        echo "    eapol_flags=0"
        echo "}"
    } > $WPA/wired-$1.conf
    chmod 600 $WPA/wired-$1.conf
    echo "  $WPA/wired-$1.conf"
}
perfil aluno1      aluno1    'Senha@123'
perfil visitante   visitante 'Visit@123'
perfil senhaerrada aluno1    'SenhaErrada'

passo "Script de conexão (/root/conectar.sh)"
cat > /root/conectar.sh << 'EOF'
#!/bin/bash
# Uso: bash /root/conectar.sh [aluno1|visitante|senhaerrada]
PERFIL="${1:-aluno1}"
IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
CONF=/etc/wpa_supplicant/wired-$PERFIL.conf
[ -f "$CONF" ] || { echo "Perfil inexistente: $CONF"; exit 1; }

pkill wpa_supplicant 2>/dev/null; sleep 1
dhclient -r "$IFACE" 2>/dev/null
ip addr flush dev "$IFACE"
ip link set "$IFACE" up

echo "Autenticando com o perfil $PERFIL em $IFACE..."
wpa_supplicant -B -D wired -i "$IFACE" -c "$CONF" -f /var/log/wpa_$PERFIL.log
sleep 8
wpa_cli -i "$IFACE" status | grep -E "Supplicant PAE state|suppPortStatus|EAP state|selectedMethod"

echo "Pedindo IP..."
timeout 20 dhclient -v "$IFACE" || echo "Sem IP (esperado se a autenticação falhou)"
ip -br addr show "$IFACE"
echo "Log completo: /var/log/wpa_$PERFIL.log"
EOF
chmod +x /root/conectar.sh

echo
echo "Pronto. Quando a rede do lab estiver montada:"
echo "  bash /root/conectar.sh aluno1       (esperado: VLAN 10, rede 10.10.10.0/24)"
echo "  bash /root/conectar.sh visitante    (esperado: VLAN 20, rede 10.10.20.0/24)"
echo "  bash /root/conectar.sh senhaerrada  (esperado: falha, sem IP)"
