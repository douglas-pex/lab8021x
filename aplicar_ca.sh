#!/bin/bash
# =====================================================================
# Aplica a CA/certificados do lab, baixando do GitHub (sem porta 8000).
#
# No LNX_01 (FreeRADIUS):   bash aplicar_ca.sh freeradius
# Nos suplicantes:          bash aplicar_ca.sh suplicante
# =====================================================================
set -e
BASE="https://raw.githubusercontent.com/douglas-pex/lab8021x/main"
MODO="${1:-}"

baixa() { curl -fsS "$BASE/$1" -o "$2"; }

case "$MODO" in
freeradius)
    DIR=/etc/freeradius/3.0/certs/lab
    mkdir -p "$DIR"
    baixa ca.txt     "$DIR/ca.pem"
    baixa server_pem.txt "$DIR/server.pem"
    baixa server_key.txt "$DIR/server.key"
    chown -R root:freerad "$DIR" 2>/dev/null || chown -R root:root "$DIR"
    chmod 750 "$DIR"; chmod 640 "$DIR"/*.key
    echo "Certificados aplicados em $DIR:"
    openssl verify -CAfile "$DIR/ca.pem" "$DIR/server.pem"
    echo "Reiniciando e testando o FreeRADIUS..."
    systemctl restart freeradius
    sleep 2
    radtest aluno1 'Senha@123' 127.0.0.1 0 testing123 | grep -E "Access-(Accept|Reject)|Tunnel-Private" || true
    ;;
suplicante)
    baixa ca.txt /etc/wpa_supplicant/lab-ca.pem
    echo "CA baixada em /etc/wpa_supplicant/lab-ca.pem"
    openssl x509 -in /etc/wpa_supplicant/lab-ca.pem -noout -subject -enddate
    # garante que os perfis apontem para a CA
    for p in /etc/wpa_supplicant/wired-*.conf; do
        grep -q 'ca_cert=' "$p" || sed -i 's#eapol_flags=0#ca_cert="/etc/wpa_supplicant/lab-ca.pem"\n    eapol_flags=0#' "$p"
    done
    echo "Perfis atualizados com ca_cert."
    ;;
*)
    echo "Uso: bash aplicar_ca.sh freeradius | suplicante"
    exit 1
    ;;
esac
