# Modern Private Cloud

## Prerequisites

Die installation der benötigten Tools ist abhängig des verwendeten Rechners. Im Allgemeinen wird jedoch `make` vorausgesetzt.

> WSL2 Support ist hier experimental und darf gerne hinzugefügt werden!

### Tools

Die nötigen Tools werden je nach Umgebung (Linux|Mac) entsprechend automatisiert installiert.

Für Mac nutzen wir den Installationsmanager `brew` für die Installation von allen benötigten Komponenten.

- **MacOS**: wir nutzen hier `brew` für die Installation aller Tools
- **Linux**: in Anlehnung an alle verfügbaren Distros werden wir hier statische Binaries verwenden.

```bash
# Installation aller nötigen Tools
make install-tools
```

### MacOS

MacOS muss hier mit `colima` gestartet werden, da die Apple Container noch nicht so weit sind.
Diese muss einmal eingerichtet und gestartet werden. (Wir verwenden hier 8GB RAM und 4 CPUs)

```bash
# Starten der Colima instanz
make colima-start
```

### Linux

Wir müssen einmal die SystemSettings patchen. 

```bash
make patch-linux
```

Die verwendeten kubeconfigs werden hier immer im Repo (`.kube`) mit abgelegt werden. Die OrdnerStruktur wird definitiv mit angelegt, jedoch die kubeconfigs nie mit hochgeladen.

## Management Cluster

Das Management Cluster beinhaltet eine Rancher Installation zur Verwaltung der Cluster (Einfache Übersicht) und kamaji als Tenant ControlPlane hoster.

Das Starten des Management-Clusters ist hier sehr einfach gehalten:

```bash
make management-cluster
```

> Unter MacOS müssen wir einmal die Colima Engine Patchen, damit wir hier auch die richtigen Endpunkte bekommen.
> `make patch-colima` führt hier einmalig zum Ziel!

Danach werden noch die Tools des Management Clusters benötigt.
Folgende Tools werden hier installiert:

- cert-manager
- metallb (LoadBalancing)
- rancher
- kamaji
- gateway-api (Abhänhigkeit zu Kamaji, werden wir aber nicht nutzen)

```bash
make bootstrap-management-cluster
```

Nachdem Bootstrapping kann die Rancher Oberfläche unter `https://rancher.<ip>.sslip.io` erreicht werden. Die echte IP wird in der Konsole mit ausgegeben.

Kamaji Console wird ebenfalls als Deployment mit ausgegeben und ist ebenfalls über eine IP erreichbar.

### kubeconfigs

Die KubeConfig des Management Clusters ist hier zu finden `export KUBECONFIG=./.kube/management-cluster.yaml``

## Tenant Cluster `kubevirt`

Das Tenant Cluster `kubevirt` wird hier ebenfalls mittels MakeFile in Betrieb genommen. Hierfür wird eigens ein kleines nacktes `kind-Cluster` hochgezogen und konfiguriert.

Hierfür wird auf dem Management Cluster eine Tenant Control Plane installiert und für diese Tenant-Control-Plane ein eigener Ingress durch `metallb` angelegt.

Nach Anlegen der Control Plane wird ein `kind-Cluster` ohne ControlPlane deployed und mittels einmaligem Bootstrap Script der Control Plane gejoined.

Damit haben wir ein vollständiges Cluster erhalten.

Initial beinhaltet das Cluster damit lediglich:

- coredns
- flannel (cni)
- kube-proxy

```bash
make bootstrap-tenant-cluster
```

### Import in Rancher

Damit wir das Cluster in Rancher verwalten können, müssen wir das Tenant Cluster in die Rancher Umgebung als Exisiting Cluster importieren.

Dazu muss in der UI unter Cluster-Management ein Cluster importiert werden und der Registration Befehel (insecure) einmalig auf dem Neuen Cluster ausgeführt werden

#### Installation direkt auf dem Node

Die Installation direkt auf dem Node ist ohne umschweife möglich

```bash
# WICHTIG: HIER UNBEDINGT AUF DIE "" hinweisen...
docker exec -it tenant-node-1 sh -c "<hier der Befehl von Rancher insecure>"
```

#### Installation vom eigenen Client aus

Hierfür müssen wir die Kubeconfigs entsprechend joinen, dann haben wir auch die nötigen Kontexte.

```bash
export KUBECONFIG=./.kube/config.yaml
# Setze richtigen Context
kubectl config set-context kubernetes-admin@kubevirt
# Ausführen des Rancher Import befehls
<Rancher import Befehl>
```

### Installation von kubevirt

````bash
export KUBECONFIG=$(KUBECONFIG_DIR)/tenant-cluster.yaml
kustomize build ./kubevirt/vm | kubectl apply -f -
```
