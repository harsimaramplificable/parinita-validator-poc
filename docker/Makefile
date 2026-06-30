.PHONY: help generate-keys setup-nodes start stop restart status logs validators \
        peers block monitoring-start monitoring-stop clean clean-keys destroy add-validator remove-validator

SHELL := /bin/bash
SCRIPTS := scripts

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n",$$1,$$2}' \
	  | sort

# Catch bare numbers passed as positional args (e.g. "make add-validator 2")
# and give a helpful message instead of the cryptic "No rule to make target" error.
.DEFAULT:
	@if echo "$@" | grep -qE '^[0-9]+$$'; then \
	  echo "ERROR: '$@' is not a Make target — Make arguments are key=value, not positional."; \
	  echo "  To add validators:    make add-validator COUNT=$@"; \
	  echo "  To remove validator:  make remove-validator NODE=$@"; \
	else \
	  echo "ERROR: No rule to make target '$@'. Run 'make help'."; \
	fi; exit 1

# ─── Initial setup (run once) ─────────────────────────────────────────────────

generate-keys: ## [1] Generate QBFT validator keys and genesis.json
	@chmod +x $(SCRIPTS)/1-generate-keys.sh
	@bash $(SCRIPTS)/1-generate-keys.sh

setup-nodes: ## [2] Distribute keys and create static-nodes.json
	@chmod +x $(SCRIPTS)/2-setup-nodes.sh
	@bash $(SCRIPTS)/2-setup-nodes.sh

init: generate-keys setup-nodes ## [1+2] Full initial setup in one step

# ─── Network operations ───────────────────────────────────────────────────────

_check-ready:
	@if [ ! -f config/genesis.json ] || [ -d config/genesis.json ]; then \
	  echo "ERROR: config/genesis.json missing. Run 'make init' first."; exit 1; fi
	@if [ ! -f nodes/validator-1/data/key ] || [ -d nodes/validator-1/data/key ]; then \
	  echo "ERROR: Node keys missing. Run 'make init' first."; exit 1; fi
	@if [ ! -f nodes/validator-1/data/static-nodes.json ] || [ -d nodes/validator-1/data/static-nodes.json ]; then \
	  echo "ERROR: static-nodes.json missing. Run 'make setup-nodes' first."; exit 1; fi

start: _check-ready ## Start all validator nodes
	@bash $(SCRIPTS)/manage.sh start

stop: ## Stop all validator nodes
	@bash $(SCRIPTS)/manage.sh stop

restart: ## Restart all validator nodes
	@bash $(SCRIPTS)/manage.sh restart

status: ## Show container status, block number, peer count
	@bash $(SCRIPTS)/manage.sh status

logs: ## Follow logs for all nodes (use NODE=N for a specific one)
ifdef NODE
	@bash $(SCRIPTS)/manage.sh logs $(NODE)
else
	@bash $(SCRIPTS)/manage.sh logs
endif

validators: ## Query current QBFT validator set from chain
	@bash $(SCRIPTS)/manage.sh validators

peers: ## Show peer count per node
	@bash $(SCRIPTS)/manage.sh peers

block: ## Show block number per node (should all agree)
	@bash $(SCRIPTS)/manage.sh block

# ─── Validator governance ─────────────────────────────────────────────────────

add-validator: ## Add validator(s). Usage: make add-validator COUNT=2
ifndef COUNT
	$(error COUNT is required. Usage: make add-validator COUNT=<number>  e.g. make add-validator COUNT=2)
endif
	@chmod +x $(SCRIPTS)/add-validator.sh
	@bash $(SCRIPTS)/add-validator.sh $(COUNT)

remove-validator: ## Remove a validator by node number. Usage: make remove-validator NODE=5
ifndef NODE
	$(error NODE is required. Usage: make remove-validator NODE=<number>  e.g. make remove-validator NODE=5)
endif
	@chmod +x $(SCRIPTS)/remove-validator.sh
	@bash $(SCRIPTS)/remove-validator.sh $(NODE)

# ─── Monitoring ───────────────────────────────────────────────────────────────

monitoring-start: ## Start Prometheus + Grafana
	docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d prometheus grafana
	@echo "Grafana → http://localhost:$$(grep GRAFANA_PORT .env | cut -d= -f2)  (admin / $$(grep GRAFANA_ADMIN_PASSWORD .env | cut -d= -f2))"
	@echo "Prometheus → http://localhost:$$(grep PROMETHEUS_PORT .env | cut -d= -f2)"

monitoring-stop: ## Stop Prometheus + Grafana
	docker compose -f docker-compose.yml -f docker-compose.monitoring.yml stop prometheus grafana

# ─── Cleanup ──────────────────────────────────────────────────────────────────

clean: ## Destroy containers and volumes (WARNING: blockchain data lost)
	@bash $(SCRIPTS)/manage.sh clean

clean-keys: ## Remove generated keys and genesis (allows re-running init)
	@echo "Removing generated keys and genesis..."
	@rm -rf config/network-files config/genesis.json
	@find nodes -name key -o -name key.pub -o -name static-nodes.json | xargs rm -f 2>/dev/null || true
	@echo "Done. Run 'make init' to regenerate."

destroy: ## COMPLETELY wipe chain: containers, volumes, all node data, keys, and genesis
	@echo "WARNING: This permanently deletes the entire chain — containers, volumes, keys, genesis, and all node data."
	@read -rp "Type 'yes' to confirm: " ans && [ "$$ans" = "yes" ] || { echo "Aborted."; exit 0; }
	@docker compose down -v 2>/dev/null || true
	@echo "Removing generated config (root-owned files removed via docker)..."
	@docker run --rm -v "$$(pwd)/config:/target" alpine sh -c "rm -rf /target/network-files /target/genesis.json"
	@echo "Removing extra validator node directories added by add-validator..."
	@find nodes -mindepth 1 -maxdepth 1 -type d | sort | tail -n +5 | xargs rm -rf
	@echo "Resetting base node data..."
	@find nodes -mindepth 1 -maxdepth 1 -type d | while read dir; do \
	  rm -rf "$$dir/data"; \
	  mkdir -p "$$dir/data"; \
	done
	@echo "Regenerating docker-compose.override.yml..."
	@bash $(SCRIPTS)/render-override.sh
	@echo "Chain completely removed. Run 'make init && make start' to create a fresh chain."
