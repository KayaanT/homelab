.DEFAULT_GOAL := help
SHELL := /bin/bash

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

configure: ## Bake homelab.env values into the manifests
	./scripts/configure.sh

status: ## One-screen health check
	@echo "── nodes ─────────"; kubectl get nodes -o wide
	@echo "── memory ────────"; free -h
	@echo "── argocd ────────"; kubectl -n argocd get applications
	@echo "── ceph ──────────"; kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s 2>/dev/null || echo "toolbox not up"
	@echo "── kube-proxy ────"; kubectl get pods -A | grep -c kube-proxy || echo "0 (correct)"

openstack: ## Park the platform and boot the OpenStack guest
	./scripts/openstack-mode.sh

k8s: ## Shut down OpenStack and restore the platform
	./scripts/k8s-mode.sh

rebuild: ## DESTRUCTIVE. Wipe the cluster and restore it from Git.
	@echo "This destroys the cluster. Ceph data on p4/p5 survives only if you"
	@echo "answer 'no' to wiping disks. Ctrl-C now if unsure."
	@read -p "Type REBUILD to continue: " c && [ "$$c" = "REBUILD" ]
	sudo kubeadm reset -f
	sudo rm -rf /etc/cni/net.d /var/lib/rook
	./host/phase1-cluster-init.sh
	kubectl create namespace argocd
	kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
	kubectl apply -f bootstrap/root-app.yaml
	@echo "Restore the sealed-secrets key backup, or committed secrets stay undecryptable."

.PHONY: help configure status openstack k8s rebuild
