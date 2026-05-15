#!/bin/bash
#
GW_IP=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}}|{{end}}' | awk -F'|' '{print $(NF-1)}')
NET_IP=$(echo ${GW_IP} | sed -E 's|^([0-9]+\.[0-9]+)\..*$|\1|g')
cat << EOF | sed -E "s|172.19|${NET_IP}|g" | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-ip-pool
  namespace: metallb-system
spec:
  addresses:
  - 172.19.1.200-172.19.1.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: emtpy
  namespace: metallb-system
EOF
