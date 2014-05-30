#!/bin/bash

IPPREFIX=${IPPREFIX:-192.168.0.}
IPSTART=${IPSTART:-101}
VPSIP=${VPSIP:-1.2.3.4}
SSLPORTOFFSET=${SSLPORTOFFSET:-1000}
HAPROXYPASS=${HAPROXYPASS:-CHANGEME}

LANFILE=${LANFILE:-lan-haproxy.cfg}
VPSFILE=${VPSFILE:-vps-haproxy.cfg}
IPLIST=${IPLIST:-iplist.txt}
DNSMASQFILE=${DNSMASQFILE:-dnsmasq.conf}

function parseSubdomain()
{
    LANIP=$(echo "$1" | cut -d\  -f1)
    VPSPORT=$(echo "$1" | cut -d: -f2 | cut -d\  -f1)
    SUBDOMAIN=$(echo "$1" | cut -d\( -f2 | cut -d\) -f1)
}

# LAN file

cat > "$LANFILE" << EOF
# Check the HAProxy documentation for information about the configuration keywords.
# Make sure to use (compile) the latest HAProxy version from the current development branch or some features may not work!

global
  daemon
  maxconn 20000
  user haproxy
  group haproxy
  stats socket /var/run/haproxy.sock mode 0600 level admin
  log /dev/log  local0 debug
  pidfile /var/run/haproxy.pid
  spread-checks 5

defaults
  maxconn 19500
  log global
  mode http
  option httplog
  option abortonclose
  option http-server-close
  option persist
  option accept-invalid-http-response

  timeout connect 20s
  timeout server 120s
  timeout client 120s
  timeout check 10s
  retries 3

listen stats    # Website with useful statistics about our HAProxy frontends and backends
  bind *:6969
  mode http
  stats enable
  stats realm HAProxy
  stats uri /
  stats auth haproxy:${HAPROXYPASS}

# SNI catchall ------------------------------------------------------------------------
# We're trying to save as many IP addresses as possible that's why we're running as many backends as possible on one IP address.
# Obviously, we're using SNI on the 443 frontend only

frontend f_sni_catchall
  mode http
  bind ${IPPREFIX}${IPSTART}:80
  log global
  option httplog
  option accept-invalid-http-request

  capture request  header Host len 50
  capture request  header User-Agent len 150

  #--- netflix 
EOF

while read line
do
    parseSubdomain "$line"
    echo "  use_backend b_sni_catchall     if { hdr(host) -i ${SUBDOMAIN} }" >> "$LANFILE"
done < <(cat "$IPLIST" | grep -v "^#")

cat >> "$LANFILE" << EOF

  default_backend b_sni_deadend

backend b_sni_catchall
  log global
  mode http
  option httplog
  option http-server-close

  #--- netflix
EOF
while read line
do
    parseSubdomain "$line"
    echo "  use-server ${SUBDOMAIN}            if { hdr(host) -i ${SUBDOMAIN} }" >> "$LANFILE"
    echo "  server ${SUBDOMAIN} ${VPSIP}:80" >> "$LANFILE"
    echo "" >> "$LANFILE"
done < <(cat "$IPLIST" | grep -v "^#")

cat >> "$LANFILE" << EOF
frontend f_sni_catchall_ssl
  bind ${IPPREFIX}${IPSTART}:443
  mode tcp
  log global
  option tcplog
  no option http-server-close

  tcp-request inspect-delay 5s
  tcp-request content accept         if { req_ssl_hello_type 1 }

  #--- netflix
EOF

while read line
do
    parseSubdomain "$line"
    echo "  use_backend b_sni_catchall_ssl     if { req_ssl_sni -i ${SUBDOMAIN} }" >> "$LANFILE"
done < <(cat "$IPLIST" | grep -v "^#")

cat >> "$LANFILE" << EOF

  default_backend b_deadend_ssl

backend b_sni_catchall_ssl
  log global
  option tcplog
  mode tcp
  no option http-server-close
  no option accept-invalid-http-response

  #--- netflix
EOF

while read line
do
    parseSubdomain "$line"
    echo "  use-server ${SUBDOMAIN}                    if { req_ssl_sni -i ${SUBDOMAIN} }" >> "$LANFILE"
    echo "  server ${SUBDOMAIN} ${VPSIP}:443" >> "$LANFILE"
    echo "" >> "$LANFILE"
done < <(cat "$IPLIST" | grep -v "^#")

CURRIP=$IPSTART
while read line
do
    let CURRIP=$CURRIP+1
    parseSubdomain "$line"
    let CURRPORT=$VPSPORT+$SSLPORTOFFSET
    cat >> "$LANFILE" << EOF
# ${SUBDOMAIN}  ------------------------------------------------------------------------

frontend f_netflix_${CURRIP}
  log global
  option httplog
  bind ${IPPREFIX}${CURRIP}:80
  mode http
  capture request  header Host len 50
  capture request  header User-Agent len 150
  default_backend b_netflix_${CURRIP}

backend b_netflix_${CURRIP}
  log global
  option httplog
  mode http
  server ${SUBDOMAIN} ${VPSIP}:${VPSPORT}

frontend f_netflix_${CURRIP}_ssl
  log global
  option tcplog
  bind ${IPPREFIX}${CURRIP}:443
  mode tcp
  default_backend b_netflix_${CURRIP}_ssl

backend b_netflix_${CURRIP}_ssl
  log global
  option tcplog
  no option accept-invalid-http-response
  mode tcp
  server ${SUBDOMAIN} ${VPSIP}:${CURRPORT}


EOF
done < <(cat "$IPLIST" | grep -v "^$IPSTART \|^#")


cat >> "$LANFILE" << EOF
# deadend  ------------------------------------------------------------------------

backend b_sni_deadend
  mode http
  log global
  option httplog

backend b_deadend_ssl
  mode tcp
  log global
  option tcplog
  no option accept-invalid-http-response
  no option http-server-close
EOF

# VPS file

cat > "$VPSFILE" << EOF
# Check the HAProxy documentation for information about the configuration keywords.
# Make sure to use (compile) the latest HAProxy version from the current development branch or some features may not work!

global
  daemon
  maxconn 20000
  user haproxy
  group haproxy
  stats socket /var/run/haproxy.sock mode 0600 level admin
  log /dev/log  local0 debug
  pidfile /var/run/haproxy.pid
  spread-checks 5

defaults
  maxconn 19500
  log global
  mode http
  option httplog
  option abortonclose
  option http-server-close
  option persist
  option accept-invalid-http-response

  timeout connect 20s
  timeout server 120s
  timeout client 120s
  timeout check 10s
  retries 3

listen stats    # Website with useful statistics about our HAProxy frontends and backends
  bind *:6969
  mode http
  stats enable
  stats realm HAProxy
  stats uri /
  stats auth haproxy:${HAPROXYPASS}

# SNI catchall ------------------------------------------------------------------------
# We're trying to save as many IP addresses as possible that's why we're running as many backends as possible on one IP address.
# Obviously, we're using SNI on the 443 frontend only

frontend f_sni_catchall
  mode http
  bind ${VPSIP}:80
  log global
  option httplog
  option accept-invalid-http-request

  capture request  header Host len 50
  capture request  header User-Agent len 150

  #--- netflix 
EOF

while read line
do
    parseSubdomain "$line"
    echo "  use_backend b_sni_catchall     if { hdr(host) -i ${SUBDOMAIN} }" >> "$VPSFILE"
done < <(cat "$IPLIST" | grep -v "^#")

cat >> "$VPSFILE" << EOF

  default_backend b_sni_deadend

backend b_sni_catchall
  log global
  mode http
  option httplog
  option http-server-close

  #--- netflix
EOF
while read line
do
    parseSubdomain "$line"
    echo "  use-server ${SUBDOMAIN}            if { hdr(host) -i ${SUBDOMAIN} }" >> "$VPSFILE"
    echo "  server ${SUBDOMAIN} ${SUBDOMAIN}:80" >> "$VPSFILE"
    echo "" >> "$VPSFILE"
done < <(cat "$IPLIST" | grep -v "^#")

cat >> "$VPSFILE" << EOF
frontend f_sni_catchall_ssl
  bind ${VPSIP}:443
  mode tcp
  log global
  option tcplog
  no option http-server-close

  tcp-request inspect-delay 5s
  tcp-request content accept         if { req_ssl_hello_type 1 }

  #--- netflix
EOF

while read line
do
    parseSubdomain "$line"
    echo "  use_backend b_sni_catchall_ssl     if { req_ssl_sni -i ${SUBDOMAIN} }" >> "$VPSFILE"
done < <(cat "$IPLIST" | grep -v "^#")

cat >> "$VPSFILE" << EOF

  default_backend b_deadend_ssl

backend b_sni_catchall_ssl
  log global
  option tcplog
  mode tcp
  no option http-server-close
  no option accept-invalid-http-response

  #--- netflix
EOF

while read line
do
    parseSubdomain "$line"
    echo "  use-server ${SUBDOMAIN}                    if { req_ssl_sni -i ${SUBDOMAIN} }" >> "$VPSFILE"
    echo "  server ${SUBDOMAIN} ${SUBDOMAIN}:443" >> "$VPSFILE"
    echo "" >> "$VPSFILE"
done < <(cat "$IPLIST" | grep -v "^#")

CURRIP=$IPSTART
while read line
do
    let CURRIP=$CURRIP+1
    parseSubdomain "$line"
    let CURRPORT=$VPSPORT+$SSLPORTOFFSET
    cat >> "$VPSFILE" << EOF
# ${SUBDOMAIN}  ------------------------------------------------------------------------

frontend f_netflix_${CURRIP}
  log global
  option httplog
  bind ${VPSIP}:${VPSPORT}
  mode http
  capture request  header Host len 50
  capture request  header User-Agent len 150
  default_backend b_netflix_${CURRIP}

backend b_netflix_${CURRIP}
  log global
  option httplog
  mode http
  server ${SUBDOMAIN} ${SUBDOMAIN}:80

frontend f_netflix_${CURRIP}_ssl
  log global
  option tcplog
  bind ${VPSIP}:${CURRPORT}
  mode tcp
  default_backend b_netflix_${CURRIP}_ssl

backend b_netflix_${CURRIP}_ssl
  log global
  option tcplog
  no option accept-invalid-http-response
  mode tcp
  server ${SUBDOMAIN} ${SUBDOMAIN}:443


EOF
done < <(cat "$IPLIST" | grep -v "^$IPSTART \|^#")


cat >> "$VPSFILE" << EOF
# deadend  ------------------------------------------------------------------------

backend b_sni_deadend
  mode http
  log global
  option httplog

backend b_deadend_ssl
  mode tcp
  log global
  option tcplog
  no option accept-invalid-http-response
  no option http-server-close
EOF

# dnsmasq file

cat > "$DNSMASQFILE" << EOF
domain-needed
bogus-priv

EOF
while read line
do
    parseSubdomain "$line"
    echo "address=/${SUBDOMAIN}/${IPPREFIX}${LANIP}" >> "$DNSMASQFILE"
done < <(cat "$IPLIST" | grep -v "^#")

