ROOT_DIR := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
KUBECONFIG_DIR := ./.kube
ARCH := $(shell uname -m)

.PHONY: help colima-start management-cluster stop-management-cluster bootstrap-management-cluster rancher cert-manager metallb kamaji tenant-cp tenant-cluster stop-tenant-cluster

help: ## Shows this Help Message
	@echo "Commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

install-mac:
	brew upgrade docker docker-credential-helper kind kustomize helm kubectl jq virtctl

colima-stop: ## stop colima (MAC)
	colima stop
	colima delete

colima-start: ## start colima with containerd runtime (MAC)
	colima start --runtime docker --memory 8 --cpu 4 --network-address --nested-virtualization --vm-type vz

patch-colima: ## patch colima network rules for kind (MAC)
	# Colima Network Rules
	$(eval KIND_NET=$(shell docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}|{{end}}' | awk -F'|' '{print $$(NF-1)}'))
	$(eval COLIMA_IP=$(shell colima ls -j | jq '.address' -r))
	colima ssh -- sudo iptables -I FORWARD 1 -j ACCEPT
	colima ssh -- sudo iptables -t nat -A POSTROUTING -j MASQUERADE
	sudo route -n delete -net $(KIND_NET) || true
	sudo route -n add -net $(KIND_NET) $(COLIMA_IP)
	@echo "Patch Colima..."
	colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=1024
	colima ssh -- sudo sysctl -w fs.inotify.max_user_watches=1048576
	colima ssh -- sudo modprobe br_netfilter
	colima ssh -- sudo sh -c 'echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables'

management-cluster: ## start management cluster
	kind create cluster --config management/kind-config.yaml
	kind get kubeconfig --name management-cluster > $(KUBECONFIG_DIR)/management-cluster.yaml
	export KUBECONFIG=$(KUBECONFIG_DIR)/management-cluster.yaml

stop-management-cluster: ## stop management cluster
	kind delete cluster -n management-cluster

bootstrap-management-cluster: cert-manager metallb rancher kamaji ## Boostrap management cluster and install toolings needed
	kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

rancher: ## install Rancher into the management Cluster (needs a management-cluster with metallb and cert-manager installed)
	helm repo add rancher-stable 'https://releases.rancher.com/server-charts/stable'
	helm repo update
	export KUBECONFIG=$(KUBECONFIG_DIR)/management-cluster.yaml
	## first IP
	$(eval RANCHER_IP=$(shell kubectl get ipaddresspool kind-ip-pool -n metallb-system -ojsonpath='{.spec.addresses[0]}' | awk -F'-' '{print $$1}' | awk -F'.' '{print $$1"."$$2"."$$3"."$$4+0}'))
	helm upgrade --install rancher rancher-stable/rancher --namespace cattle-system --create-namespace --set hostname="rancher.$(RANCHER_IP).sslip.io" --set bootstrapPassword="cloudland" --set replicas=1 --set service.type=LoadBalancer
	kubectl patch svc -n cattle-system rancher -p '{"spec": {"loadBalancerIP": "$(RANCHER_IP)"}}'
	@echo "\n-------\nRancher will be available at https://rancher.$(RANCHER_IP).sslip.io\n-------\n"

cert-manager: ## install cert-manager into the management Cluster
	helm repo add jetstack "https://charts.jetstack.io"
	helm repo update
	export KUBECONFIG=$(KUBECONFIG_DIR)/management-cluster.yaml
	helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true
	kubectl wait --namespace cert-manager --for=condition=ready pod --selector=app.kubernetes.io/instance=cert-manager --timeout=90s

metallb: ## install metallb into the management Cluster
	export KUBECONFIG=$(KUBECONFIG_DIR)/management-cluster.yaml
	kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
	kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=90s
	sh ./management/metallb-config.sh

kamaji: ## install kamaji [with console] into the management Cluster (needs a management-cluster with metallb and cert-manager installed)
	export KUBECONFIG=$(KUBECONFIG_DIR)/management-cluster.yaml
	echo "Installing Kamaji"
	helm repo add clastix https://clastix.github.io/charts
	helm repo update
	helm upgrade --install kamaji clastix/kamaji --namespace kamaji-system --create-namespace --set 'resources=null' --version 0.0.0+latest
	echo "installing kamaji-console"
	$(eval KAMAJI_IP=$(shell kubectl get ipaddresspool kind-ip-pool -n metallb-system -ojsonpath='{.spec.addresses[0]}' | awk -F'-' '{print $$1}' | awk -F'.' '{print $$1"."$$2"."$$3"."$$4+10}'))
	$(eval CONSOLE_URL=https://kamaji.$(KAMAJI_IP).sslip.io)
	kubectl create secret generic kamaji-console \
	  --namespace kamaji-system \
	  --from-literal=ADMIN_EMAIL="kamaji@cloud.land" \
	  --from-literal=ADMIN_PASSWORD="cloud.land" \
	  --from-literal=JWT_SECRET="secretme" \
	  --from-literal=NEXTAUTH_URL="$(CONSOLE_URL)" \
	  --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install console clastix/kamaji-console --namespace kamaji-system --set replicaCount=1 --set service.type=LoadBalancer
	kubectl patch svc -n kamaji-system console-kamaji-console -p '{"spec": {"loadBalancerIP": "$(KAMAJI_IP)"}}'
	@echo "\n-------\nKamaji will be available at https://kamaji.$(KAMAJI_IP).sslip.io\n-------\n"

bootstrap-tenant-cluster: tenant-cp tenant-cluster ## Bootstrap tenant cluster with a control-plane and a worker-node

tenant-cp: ## create a tenant control-plane in kamaji on management-cluster
	export KUBECONFIG=$(KUBECONFIG_DIR)/management-cluster.yaml
	kustomize build tenant/control-plane | kubectl apply -f -
	@while ! kubectl get secret kubevirt-admin-kubeconfig -n kubevirt >/dev/null 2>&1; do \
			echo "Secret noch nicht erstellt... warte 3s"; \
			sleep 10; \
		done
	@echo "Export Secret..."
	kubectl get secret kubevirt-admin-kubeconfig -n kubevirt -ojsonpath='{.data.admin\.conf}' | base64 -d > $(KUBECONFIG_DIR)/tenant-cluster.yaml
	@echo "Merge Kubeconfigs..."
	KUBECONFIG=$(KUBECONFIG_DIR)/management-cluster.yaml:$(KUBECONFIG_DIR)/tenant-cluster.yaml kubectl config view --raw > $(KUBECONFIG_DIR)/config.yaml
	export KUBECONFIG=$(KUBECONFIG_DIR)/config.yaml

tenant-cluster: ## create a worker-node for the tenant-cluster
	@echo "Start tenant-node-1..."
	$(eval RANCHER_IP=$(shell kubectl get svc -n cattle-system rancher -ojsonpath='{.status.loadBalancer.ingress[0].ip}'))
	docker run -d --name tenant-node-1 \
	--privileged \
	--network kind \
	-v /lib/modules:/lib/modules:ro \
	-v /var \
	-v $(ROOT_DIR)/.kube/tenant-cluster.yaml:/kubeconfig.yaml \
	-v $(ROOT_DIR)/tenant/node/kubelet:/etc/default/kubelet \
	-v $(ROOT_DIR)/tenant/node/bootstrap-node.sh:/usr/local/bin/bootstrap-node.sh \
	-e KUBECONFIG=/kubeconfig.yaml \
	-e KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER \
	-e RANCHER_IP=$(RANCHER_IP) \
	--hostname tenant-node-1 \
	--tmpfs /tmp \
	--tmpfs /run \
	-p 2224:2224 \
	kindest/node:v1.34.0
	docker exec -it tenant-node-1 /usr/local/bin/bootstrap-node.sh

stop-tenant-cluster: ## stop the worker-node for the tenant-cluster
	nerdctl stop tenant-node-1 -t 1
	nerdctl rm tenant-node-1

### KUBEVIRT PART
deploy-kubevirt:
	export KUBECONFIG=$(KUBECONFIG_DIR)/tenant-cluster.yaml
	@echo "Deploying kubevirt operator"
	kubectl apply -f "./kubevirt/kubevirt-operator.yaml"
	@echo "Deploy kubevirt"
	kubectl apply -f "./kubevirt/kubevirt-cr.yaml"
ifeq ($(ARCH),arm64)
	@echo "Patching kubevirt to use qemu for ARM64"
	kubectl patch kubevirt kubevirt -n kubevirt --type merge --patch '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":false}}}}'
endif

deploy-vm:
	export KUBECONFIG=$(KUBECONFIG_DIR)/tenant-cluster.yaml
	kubectl apply -f "./kubevirt/vm/vm.yaml"