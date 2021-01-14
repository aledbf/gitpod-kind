#!/bin/bash

set -e
set -x

log() {
  echo "$(date -u +'%Y-%M-%dT%H:%M')" "$@"
}

log "Creating kind cluster and exposing ports 80 and 443..."

cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "proxy-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF

log "Updating helm repositories..."
helm repo add gitpod.io https://charts.gitpod.io
helm repo add smallstep  https://smallstep.github.io/helm-charts
helm repo update

log "Creating directory for hostPath storage (kind issue)..."
docker exec -it kind-control-plane bash -c 'mkdir -p /run/containerd/io.containerd.runtime.v1.linux/k8s.io'

log "Creating gitpod namespace..."
kubectl create namespace gitpod

log "Installing cert-manager (required for step-issuer)..."
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.1.0/cert-manager.yaml

log "Waiting for cert-manager..."
sleep 5
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

log "Installing step certificates..."
helm install -n gitpod step-certificates smallstep/step-certificates

log "Installing step-issuer deployment..."
kubectl apply -f https://raw.githubusercontent.com/smallstep/step-issuer/master/config/samples/deployment.yaml

log "Waiting for step-issuer controller..."
sleep 5
kubectl wait --namespace step-issuer-system \
  --for=condition=ready pod \
  --selector=control-plane=controller-manager \
  --timeout=90s

ROOT_CA=$(kubectl get -o jsonpath="{.data['root_ca\.crt']}" -n gitpod configmaps/step-certificates-certs | base64 -w0)
PROVISIONER_KID=$(kubectl get -o jsonpath="{.data['ca\.json']}" -n gitpod configmaps/step-certificates-config | jq .authority.provisioners[0].key.kid)

log "Creating StepIssuer..."
cat <<EOF | kubectl apply -f -
apiVersion: certmanager.step.sm/v1beta1
kind: StepIssuer
metadata:
  name: step-issuer
  namespace: gitpod
spec:
  url: https://step-certificates.gitpod.svc.cluster.local
  caBundle: $ROOT_CA
  provisioner:
    name: admin
    kid: $PROVISIONER_KID
    passwordRef:
      name: step-certificates-provisioner-password
      key: password
EOF

log "Creating initial certificate with step cli (https://smallstep.com/cli)..."
step certificate create --no-password --insecure --csr kind.local internal.csr internal.key

STEP_CSR=$(cat internal.csr | base64 -w0)

log "Creating CertificateRequest using CSR from step cli..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1alpha2
kind: CertificateRequest
metadata:
  name: internal-smallstep-com
  namespace: gitpod
spec:
  csr: $STEP_CSR
  duration: 24h
  isCA: false
  issuerRef:
    group: certmanager.step.sm
    name: step-issuer
EOF

log "Creating required SSL certificates for gitpod..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1alpha2
kind: Certificate
metadata:
  name: https-certificates
  namespace: gitpod
spec:
  secretName: https-certificates
  commonName: kind.local
  dnsNames:
    - "*.kind.local"
    - "*.ws.kind.local"
  ipAddresses:
    - "127.0.0.1"
  duration: 24h
  renewBefore: 8h
  issuerRef:
    group: certmanager.step.sm
    kind: CertificateRequest
    name: step-issuer
EOF

log "Installing gitpod..."
cat << EOF | helm template --namespace gitpod gitpod gitpod.io/gitpod --namespace gitpod --values - | kubectl apply --namespace gitpod -f -
hostname: kind.local
ingressMode: pathAndHost
imagePullPolicy: IfNotPresent
components:
  imageBuilder:
    registry:
      bypassProxy: true
  proxy:
    serviceType: NodePort
    ports:
      http:
        expose: true
        containerPort: 80
      https:
        expose: true
        containerPort: 443
certificatesSecret:
  certManager: true
EOF

sleep 5

log "Patching gitpod proxy deployment..."
kubectl patch deployment -n gitpod proxy --patch="$(cat patch-proxy.json)"

log "Patching NGINX SSL configuration..."
kubectl patch configmap -n gitpod proxy-config-nginx --patch="$(cat patch-proxy-config-nginx.json)"
kubectl delete \
  --namespace gitpod pod \
  --selector=component=proxy

kubectl get -o jsonpath="{.data['root_ca\.crt']}" -n gitpod configmaps/step-certificates-certs > internal.crt

step certificate install --all internal.crt

log "done."
