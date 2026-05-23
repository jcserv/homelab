.PHONY: help setup-hooks setup-repos build-deps update-deps install-infra install-monitoring deploy-all install-all status logs backup backup-immich-db backup-homeassistant drain uncordon seal-secret upgrade-service lint fix

# Global helm flags applied to every install/upgrade.
# values/network.yaml is the single source of truth for IP/network config —
# see docs/runbooks/ISP_MIGRATION.md.
HELM_GLOBAL_FLAGS := $(if $(wildcard values/network.yaml),-f values/network.yaml)

# Default target
help:
	@echo "Homelab K8s Makefile"
	@echo ""
	@echo "Setup Commands:"
	@echo "  make setup-hooks        Install git pre-commit hook (secret scan, lint, version bump)"
	@echo "  make setup-repos        Add all required Helm repositories"
	@echo "  make build-deps         Build chart dependencies from Chart.lock"
	@echo "  make update-deps        Update dependencies and regenerate Chart.lock files"
	@echo "  make install-infra      Install infrastructure (MetalLB, cert-manager, etc.)"
	@echo "  make install-monitoring Install monitoring stack (Prometheus, Grafana, Loki, Alloy)"
	@echo "  make deploy-all   		 Deploy all application services"
	@echo "  make install-all        Install everything (infra + monitoring + services)"
	@echo ""
	@echo "Management Commands:"
	@echo "  make status             Show cluster status (nodes, pods, services)"
	@echo "  make logs SERVICE=<name> View logs for a service"
	@echo "  make upgrade SERVICE=<name> [NAMESPACE=<namespace>] Upgrade a service"
	@echo "  make backup             Trigger manual Restic backup job"
	@echo "  make backup-immich-db   Trigger manual Immich database backup"
	@echo "  make backup-homeassistant Trigger manual Home Assistant backup"
	@echo "  make seal-secret CHART=<name> SECRET=<name> Seal a secret (pipe kubectl output)"
	@echo "  make sync-local-values    Sync all values.local.yaml files to GitHub secrets"
	@echo ""
	@echo "Maintenance Commands:"
	@echo "  make drain NODE=<name>  Drain a node for maintenance"
	@echo "  make uncordon NODE=<name> Uncordon a node after maintenance"
	@echo "  make kill-svclb         Remove svclb DaemonSets and pods"
	@echo ""
	@echo "Linting Commands:"
	@echo "  make lint [FILE=<path>]     Lint YAML file(s) (all files if FILE not specified)"
	@echo "  make fix [FILE=<path>]      Auto-fix YAML formatting issues (all files if FILE not specified)"
	@echo ""
	@echo "Examples:"
	@echo "  make logs SERVICE=immich"
	@echo "  make upgrade SERVICE=pihole"
	@echo "  make upgrade SERVICE=alloy NAMESPACE=monitoring"
	@echo "  make drain NODE=pi5-01"
	@echo "  make lint                    # Lint all YAML files"
	@echo "  make lint FILE=charts/nginx-ingress/Chart.yaml"
	@echo "  make fix                     # Fix all YAML files"
	@echo "  kubectl create secret generic test --from-literal=key=val --dry-run=client -o yaml | make seal-secret CHART=immich SECRET=test"

# Setup Commands
setup-hooks:
	@echo "Installing git pre-commit hook..."
	@cp scripts/pre-commit.sh .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "✓ Pre-commit hook installed (secret scan, yamllint, helm lint, hygiene, version bump)"

setup-repos:
	@echo "Adding Helm repositories..."
	helm repo add metallb https://metallb.github.io/metallb
	helm repo add jetstack https://charts.jetstack.io
	helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo add infisical-helm-charts https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/
	helm repo update
	@echo "✓ Repositories added and updated"

build-deps:
	@echo "Building chart dependencies..."
	helm dependency build ./charts/metallb
	helm dependency build ./charts/cert-manager
	helm dependency build ./charts/sealed-secrets
	helm dependency build ./charts/nginx-ingress
	helm dependency build ./charts/kube-prometheus-stack
	helm dependency build ./charts/loki
	helm dependency build ./charts/alloy
	helm dependency build ./charts/infisical
	helm dependency build ./charts/infisical-secrets-operator
	@echo "✓ Dependencies built"

update-deps:
	@echo "Updating chart dependencies and regenerating Chart.lock files..."
	helm dependency update ./charts/metallb
	helm dependency update ./charts/cert-manager
	helm dependency update ./charts/sealed-secrets
	helm dependency update ./charts/nginx-ingress
	helm dependency update ./charts/kube-prometheus-stack
	helm dependency update ./charts/loki
	helm dependency update ./charts/alloy
	helm dependency update ./charts/infisical
	helm dependency update ./charts/infisical-secrets-operator
	@echo "✓ Dependencies updated and Chart.lock files regenerated"

install-infra:
	@echo "Installing infrastructure components..."
	helm upgrade --install metallb ./charts/metallb -n metallb-system --create-namespace $(HELM_GLOBAL_FLAGS)
	helm upgrade --install cert-manager ./charts/cert-manager -n cert-manager --create-namespace $(HELM_GLOBAL_FLAGS)
	helm upgrade --install sealed-secrets ./charts/sealed-secrets -n kube-system $(HELM_GLOBAL_FLAGS)
	helm upgrade --install nginx-ingress ./charts/nginx-ingress -n default $(HELM_GLOBAL_FLAGS)
	helm upgrade --install infisical-secrets-operator ./charts/infisical-secrets-operator -n infisical-secrets-operator --create-namespace $(HELM_GLOBAL_FLAGS)
	@echo "✓ Infrastructure installed"

install-monitoring:
	@echo "Installing monitoring stack..."
	helm upgrade --install kube-prometheus-stack ./charts/kube-prometheus-stack -n monitoring --create-namespace $(HELM_GLOBAL_FLAGS)
	@echo "Waiting for Prometheus Operator to be ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-operator -n monitoring --timeout=120s
	helm upgrade --install loki ./charts/loki -n monitoring $(HELM_GLOBAL_FLAGS)
	@echo "Waiting for Loki to be ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=loki -n monitoring --timeout=120s
	helm upgrade --install alloy ./charts/alloy -n monitoring $(HELM_GLOBAL_FLAGS)
	@echo "✓ Monitoring stack installed"
	@echo ""
	@echo "Access Grafana at: https://grafana.home"
	@echo "  Default credentials: admin / admin"
	@echo ""

deploy-all:
	@echo "Installing application services..."
	helm upgrade --install valkey ./charts/valkey $(HELM_GLOBAL_FLAGS)
	@echo "Waiting for Valkey to be ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=valkey --timeout=120s
	helm upgrade --install unbound ./charts/unbound $(HELM_GLOBAL_FLAGS)
	@echo "Waiting for Unbound to be ready..."
	@kubectl wait --for=condition=ready pod -l app=unbound --timeout=120s
	helm upgrade --install pihole ./charts/pihole $(HELM_GLOBAL_FLAGS)
	helm upgrade --install immich ./charts/immich $(HELM_GLOBAL_FLAGS)
	helm upgrade --install authentik ./charts/authentik $(HELM_GLOBAL_FLAGS)
	helm upgrade --install infisical ./charts/infisical $(HELM_GLOBAL_FLAGS)
	helm upgrade --install home-assistant ./charts/home-assistant $(HELM_GLOBAL_FLAGS)
	helm upgrade --install restic-backup ./charts/restic-backup $(HELM_GLOBAL_FLAGS)
	helm upgrade --install immich-db-backup ./charts/immich-db-backup $(HELM_GLOBAL_FLAGS)
	helm upgrade --install home-assistant-backup ./charts/home-assistant-backup $(HELM_GLOBAL_FLAGS)
	@echo "✓ Services installed"

install-all: setup-repos build-deps install-infra install-monitoring deploy-all
	@echo ""
	@echo "✓ Complete installation finished!"
	@echo "  Configure your router DNS to the pihole loadBalancerIP (see values/network.yaml)"
	@echo "  Access Grafana at: https://grafana.home (admin/admin)"

# Management Commands
status:
	@echo "=== Cluster Nodes ==="
	@kubectl get nodes
	@echo ""
	@echo "=== All Pods ==="
	@kubectl get pods --all-namespaces
	@echo ""
	@echo "=== Services with LoadBalancers ==="
	@kubectl get svc --all-namespaces | grep LoadBalancer || echo "No LoadBalancer services found"
	@echo ""
	@echo "=== Persistent Volume Claims ==="
	@kubectl get pvc --all-namespaces

logs:
ifndef SERVICE
	@echo "Error: SERVICE parameter required"
	@echo "Usage: make logs SERVICE=<service-name>"
	@echo "Example: make logs SERVICE=immich"
	@exit 1
endif
	@echo "Showing logs for $(SERVICE)..."
	kubectl logs -l app=$(SERVICE) --tail=100 -f

upgrade:
ifndef SERVICE
	@echo "Error: SERVICE parameter required"
	@echo "Usage: make upgrade SERVICE=<service-name> [NAMESPACE=<namespace>]"
	@echo "Example: make upgrade SERVICE=immich"
	@echo "Example: make upgrade SERVICE=alloy NAMESPACE=monitoring"
	@exit 1
endif
ifndef NAMESPACE
	$(eval NAMESPACE=default)
endif
	@echo "Upgrading $(SERVICE) in namespace $(NAMESPACE)..."
	helm upgrade $(SERVICE) ./charts/$(SERVICE) -n $(NAMESPACE) \
		$(HELM_GLOBAL_FLAGS) \
		$(if $(wildcard ./charts/$(SERVICE)/values.local.yaml),-f ./charts/$(SERVICE)/values.local.yaml)
	@echo "✓ $(SERVICE) upgraded in namespace $(NAMESPACE)"

backup:
	@echo "Creating manual backup job..."
	kubectl create job --from=cronjob/restic-backup manual-backup-$(shell date +%Y%m%d-%H%M%S)
	@echo "✓ Backup job created"
	@echo "  Monitor with: kubectl logs -l app=restic-backup -f"

backup-immich-db:
	@echo "Creating manual Immich database backup job..."
	kubectl create job --from=cronjob/immich-db-backup manual-immich-db-backup-$(shell date +%Y%m%d-%H%M%S)
	@echo "✓ Immich database backup job created"
	@echo "  Monitor with: kubectl logs -l app.kubernetes.io/name=immich-db-backup -f"

backup-homeassistant:
	@echo "Creating manual Home Assistant backup job..."
	kubectl create job --from=cronjob/home-assistant-backup manual-homeassistant-backup-$(shell date +%Y%m%d-%H%M%S)
	@echo "✓ Home Assistant backup job created"
	@echo "  Monitor with: kubectl logs -l app.kubernetes.io/name=home-assistant-backup -f"

seal-secret:
ifndef CHART
	@echo "Error: CHART parameter required"
	@echo "Usage: kubectl create secret ... --dry-run=client -o yaml | make seal-secret CHART=<chart> SECRET=<name>"
	@exit 1
endif
ifndef SECRET
	@echo "Error: SECRET parameter required"
	@echo "Usage: kubectl create secret ... --dry-run=client -o yaml | make seal-secret CHART=<chart> SECRET=<name>"
	@exit 1
endif
	@./scripts/seal-secret.sh $(CHART) $(SECRET)

# Maintenance Commands
drain:
ifndef NODE
	@echo "Error: NODE parameter required"
	@echo "Usage: make drain NODE=<node-name>"
	@echo "Example: make drain NODE=pi5-01"
	@exit 1
endif
	@echo "Draining node $(NODE)..."
	kubectl cordon $(NODE)
	kubectl drain $(NODE) --ignore-daemonsets --delete-emptydir-data
	@echo "  Uncordon with: make uncordon NODE=$(NODE)"

uncordon:
ifndef NODE
	@echo "Error: NODE parameter required"
	@echo "Usage: make uncordon NODE=<node-name>"
	@echo "Example: make uncordon NODE=pi5-01"
	@exit 1
endif
	@echo "Uncordoning node $(NODE)..."
	kubectl uncordon $(NODE)
	@echo "✓ Node $(NODE) is now schedulable"

sync-local-values:
	@echo "Syncing values.local.yaml files to GitHub secrets..."
	@for f in charts/*/values.local.yaml; do \
		if [ -f "$$f" ]; then \
			chart=$$(echo "$$f" | cut -d/ -f2); \
			secret_name=$$(echo "$${chart}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')_VALUES_LOCAL; \
			echo "  Syncing $$f → secret $$secret_name"; \
			gh secret set "$$secret_name" < "$$f"; \
		fi; \
	done
	@echo "✓ Local values synced to GitHub secrets"

kill-svclb:
	@echo "Removing svclb DaemonSets and pods..."
	@kubectl get daemonset -n kube-system -o name | grep svclb | xargs -r kubectl delete -n kube-system || echo "No svclb DaemonSets found"
	@kubectl get pods -n kube-system -o name | grep svclb | xargs -r kubectl delete -n kube-system || echo "No svclb pods found"
	@echo "✓ svclb resources removed"

# Linting Commands
lint:
	@if command -v yamllint >/dev/null 2>&1; then \
		if [ -z "$(FILE)" ]; then \
			echo "Linting all YAML files..."; \
			yamllint charts/ k8s/ docker/ *.yaml *.yml 2>/dev/null || true; \
		else \
			echo "Linting $(FILE)..."; \
			yamllint $(FILE); \
		fi \
	else \
		echo "Error: yamllint not found. Install with: pip install yamllint"; \
		exit 1; \
	fi

fix:
	@if [ -z "$(FILE)" ]; then \
		echo "Auto-fixing all YAML files..."; \
		if command -v yamlfix >/dev/null 2>&1; then \
			find charts k8s docker -name "*.yaml" -o -name "*.yml" | while read f; do \
				echo "Fixing $$f..."; \
				yamlfix "$$f" 2>/dev/null || true; \
			done; \
			find . -maxdepth 1 -name "*.yaml" -o -name "*.yml" | while read f; do \
				echo "Fixing $$f..."; \
				yamlfix "$$f" 2>/dev/null || true; \
			done; \
		elif command -v yamlfmt >/dev/null 2>&1; then \
			find charts k8s docker -name "*.yaml" -o -name "*.yml" | while read f; do \
				echo "Fixing $$f..."; \
				yamlfmt "$$f" 2>/dev/null || true; \
			done; \
			find . -maxdepth 1 -name "*.yaml" -o -name "*.yml" | while read f; do \
				echo "Fixing $$f..."; \
				yamlfmt "$$f" 2>/dev/null || true; \
			done; \
		else \
			echo "Installing yamlfix..."; \
			pip install yamlfix; \
			find charts k8s docker -name "*.yaml" -o -name "*.yml" | while read f; do \
				echo "Fixing $$f..."; \
				yamlfix "$$f" 2>/dev/null || true; \
			done; \
			find . -maxdepth 1 -name "*.yaml" -o -name "*.yml" | while read f; do \
				echo "Fixing $$f..."; \
				yamlfix "$$f" 2>/dev/null || true; \
			done; \
		fi; \
		echo "✓ All YAML files fixed"; \
	else \
		echo "Auto-fixing YAML formatting in $(FILE)..."; \
		if command -v yamlfix >/dev/null 2>&1; then \
			yamlfix $(FILE); \
			echo "✓ Fixed $(FILE)"; \
		elif command -v yamlfmt >/dev/null 2>&1; then \
			yamlfmt $(FILE); \
			echo "✓ Fixed $(FILE)"; \
		else \
			echo "Installing yamlfix..."; \
			pip install yamlfix; \
			yamlfix $(FILE); \
			echo "✓ Fixed $(FILE)"; \
		fi; \
	fi
