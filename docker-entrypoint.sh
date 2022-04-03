#!/bin/bash

# Copy default config files if removed
if [[ ! -e /config/ocserv.conf || ! -e /config/connect.sh || ! -e /config/disconnect.sh || \
	  ! -e /config/sp-metadata.xml || ! -e /config/sso.conf ]]; then
	echo "$(date) [err] Required config files are missing."
	echo "\t [err] Please see the documentation at https://github.com/morganonbass/docker-ocserv-saml"
	rsync -vzr --ignore-existing "/etc/default/ocserv/" "/config"
fi

chmod a+x /config/*.sh

##### Verify Variables #####

export LISTEN_PORT=$(echo "${LISTEN_PORT}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
# Check PROXY_SUPPORT env var
if [[ ! -z "${LISTEN_PORT}" ]]; then
	echo "$(date) [info] LISTEN_PORT defined as '${LISTEN_PORT}'"
else
	echo "$(date) [warn] LISTEN_PORT not defined,(via -e LISTEN_PORT), defaulting to '443'"
	export LISTEN_PORT="8443"
fi

##### Process Variables #####

if [ ${LISTEN_PORT} != "8443" ]; then
	echo "$(date) [info] Modifying the listening port"
	#Find TCP/UDP line numbers and use sed to replace the lines
	TCPLINE = $(grep -rne 'tcp-port =' ocserv.conf | grep -Eo '^[^:]+')
	UDPLINE = $(grep -rne 'udp-port =' ocserv.conf | grep -Eo '^[^:]+')
	sed -i "$(TCPLINE)s/.*/tcp-port = ${LISTEN_PORT}/" /config/ocserv.conf
	sed -i "$(UDPLINE)s/.*/tcp-port = ${LISTEN_PORT}/" /config/ocserv.conf
fi

if [[ ! -z "${HOSTNAME}" ]]; then
	sed -i "s/^hostname.*$/hostname = ${HOSTNAME}/" /config/ocserv.conf
	sed -i "s/https:\/\/[^\/?#]*/https:\/\/${HOSTNAME}/g" /config/sp-metadata.xml
fi

##### Generate certs if none exist #####
if [ ! -f /config/certs/server-key.pem ] || [ ! -f /config/certs/server-cert.pem ]; then
	# No certs found
	echo "$(date) [info] No certificates were found, creating them from provided or default values"
	
	# Check environment variables
	if [ -z "$CA_CN" ]; then
		CA_CN="VPN CA"
	fi

	if [ -z "$CA_ORG" ]; then
		CA_ORG="OCSERV"
	fi

	if [ -z "$CA_DAYS" ]; then
		CA_DAYS=9999
	fi

	if [ -z "$SRV_CN" ]; then
		SRV_CN="vpn.example.com"
	fi

	if [ -z "$SRV_ORG" ]; then
		SRV_ORG="MyCompany"
	fi

	if [ -z "$SRV_DAYS" ]; then
		SRV_DAYS=9999
	fi

	# Generate certs one
	mkdir /config/certs
	cd /config/certs
	certtool --generate-privkey --outfile ca-key.pem
	cat > ca.tmpl <<-EOCA
	cn = "$CA_CN"
	organization = "$CA_ORG"
	serial = 1
	expiration_days = $CA_DAYS
	ca
	signing_key
	cert_signing_key
	crl_signing_key
	EOCA
	certtool --generate-self-signed --load-privkey ca-key.pem --template ca.tmpl --outfile ca.pem
	certtool --generate-privkey --outfile server-key.pem 
	cat > server.tmpl <<-EOSRV
	cn = "$SRV_CN"
	organization = "$SRV_ORG"
	expiration_days = $SRV_DAYS
	signing_key
	encryption_key
	tls_www_server
	EOSRV
	certtool --generate-certificate --load-privkey server-key.pem --load-ca-certificate ca.pem --load-ca-privkey ca-key.pem --template server.tmpl --outfile server-cert.pem
else
	echo "$(date) [info] Using existing certificates in /config/certs"
fi

# Open ipv4 ip forward (done by default on alpine though, how kind)
# sysctl -w net.ipv4.ip_forward=1

# Enable NAT forwarding
iptables -t nat -A POSTROUTING -j MASQUERADE
iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Enable TUN device
mkdir -p /dev/net
mknod /dev/net/tun c 10 200
chmod 600 /dev/net/tun

chmod -R 777 /config

# Run OpenConnect Server
exec "$@"
