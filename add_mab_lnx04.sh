#!/bin/bash
# Adiciona o LNX_04 (MAC 00501a000b00) como dispositivo MAB na VLAN 30 no FreeRADIUS.
set -e
AUTH=/etc/freeradius/3.0/mods-config/files/authorize
if grep -q "00501a000b00" "$AUTH"; then
  echo "MAC 00501a000b00 ja esta cadastrado."
else
  cp "$AUTH" "$AUTH.bak2"
  cat > /tmp/mab_lnx04 << 'BLOCO'
00501a000b00 Cleartext-Password := "00501a000b00"
            Tunnel-Type = VLAN,
            Tunnel-Medium-Type = IEEE-802,
            Tunnel-Private-Group-Id = "30"

BLOCO
  cat /tmp/mab_lnx04 "$AUTH" > /tmp/authorize.new && mv /tmp/authorize.new "$AUTH"
  echo "MAC 00501a000b00 adicionado na VLAN 30."
fi
echo "--- verificando config ---"
freeradius -XC 2>&1 | tail -2
echo "Pronto. Agora rode para ver o MAB ao vivo:  systemctl stop freeradius && freeradius -X"
