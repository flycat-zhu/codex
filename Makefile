# Codex CLI Docker Makefile

# Default values
IMAGE_NAME ?= codex-rs
IMAGE_TAG ?= latest
PLATFORM ?= linux/amd64
WORK_DIR ?= $(PWD)

# Docker image full name
FULL_IMAGE_NAME = $(IMAGE_NAME):$(IMAGE_TAG)

# Help target
.PHONY: help
help: ## Show this help message
	@echo "Codex CLI Docker Commands"
	@echo "========================="
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "Environment Variables:"
	@echo "  IMAGE_NAME    Docker image name (default: codex-rs)"
	@echo "  IMAGE_TAG     Docker image tag (default: latest)"
	@echo "  PLATFORM      Build platform (default: linux/amd64)"
	@echo "  WORK_DIR      Work directory to mount (default: current directory)"
	@echo ""
	@echo "Examples:"
	@echo "  make build"
	@echo "  make run"
	@echo "  make build IMAGE_NAME=myregistry/codex IMAGE_TAG=v1.0.0"
	@echo "  make multi-build"
	@echo "  make compose-up"

# Build targets
.PHONY: build
build: ## Build Docker image
	./build-docker.sh --name $(IMAGE_NAME) --tag $(IMAGE_TAG) --platform $(PLATFORM)

.PHONY: build-no-cache
build-no-cache: ## Build Docker image without cache
	./build-docker.sh --name $(IMAGE_NAME) --tag $(IMAGE_TAG) --platform $(PLATFORM) --no-cache

.PHONY: multi-build
multi-build: ## Build multi-platform Docker image
	./build-docker.sh --name $(IMAGE_NAME) --tag $(IMAGE_TAG) --multi-platform

.PHONY: build-push
build-push: ## Build and push Docker image
	./build-docker.sh --name $(IMAGE_NAME) --tag $(IMAGE_TAG) --platform $(PLATFORM) --push

.PHONY: multi-build-push
multi-build-push: ## Build multi-platform and push Docker image
	./build-docker.sh --name $(IMAGE_NAME) --tag $(IMAGE_TAG) --multi-platform --push

# Run targets
.PHONY: run
run: ## Run Codex interactively
	./run-docker.sh --image $(FULL_IMAGE_NAME) --work-dir $(WORK_DIR)

.PHONY: run-help
run-help: ## Show Codex help
	./run-docker.sh --image $(FULL_IMAGE_NAME) --work-dir $(WORK_DIR) --no-interactive "codex --help"

.PHONY: run-version
run-version: ## Show Codex version
	./run-docker.sh --image $(FULL_IMAGE_NAME) --work-dir $(WORK_DIR) --no-interactive "codex --version"

.PHONY: run-exec
run-exec: ## Run Codex exec with command (usage: make run-exec CMD="your command")
	./run-docker.sh --image $(FULL_IMAGE_NAME) --work-dir $(WORK_DIR) --no-interactive "codex exec '$(CMD)'"

.PHONY: shell
shell: ## Open shell in container
	./run-docker.sh --image $(FULL_IMAGE_NAME) --work-dir $(WORK_DIR) "bash"

# Docker Compose targets
.PHONY: compose-build
compose-build: ## Build using docker-compose
	docker-compose build

.PHONY: compose-up
compose-up: ## Start main service with docker-compose
	docker-compose up codex

.PHONY: compose-up-dev
compose-up-dev: ## Start development service
	docker-compose --profile dev up codex-dev

.PHONY: compose-up-mcp
compose-up-mcp: ## Start MCP server
	docker-compose --profile mcp up codex-mcp-server

.PHONY: compose-down
compose-down: ## Stop all docker-compose services
	docker-compose down

.PHONY: compose-logs
compose-logs: ## Show docker-compose logs
	docker-compose logs -f

.PHONY: compose-shell
compose-shell: ## Open shell in main compose service
	docker-compose exec codex bash

# Cleanup targets
.PHONY: clean
clean: ## Remove Docker image
	docker rmi $(FULL_IMAGE_NAME) || true

.PHONY: clean-all
clean-all: ## Remove all Codex Docker images and containers
	docker ps -a --filter "name=codex" --format "{{.ID}}" | xargs -r docker rm -f
	docker images --filter "reference=$(IMAGE_NAME)" --format "{{.ID}}" | xargs -r docker rmi -f
	docker-compose down --volumes --remove-orphans

.PHONY: clean-volumes
clean-volumes: ## Remove Docker volumes
	docker-compose down --volumes

# Development targets
.PHONY: dev-build
dev-build: ## Build development image
	./build-docker.sh --name $(IMAGE_NAME) --tag dev

.PHONY: dev-shell
dev-shell: ## Open development shell
	docker-compose --profile dev run --rm codex-dev bash

.PHONY: dev-test
dev-test: ## Run tests in development container
	docker-compose --profile dev run --rm codex-dev cargo test

.PHONY: dev-clippy
dev-clippy: ## Run clippy in development container
	docker-compose --profile dev run --rm codex-dev cargo clippy

.PHONY: dev-fmt
dev-fmt: ## Run rustfmt in development container
	docker-compose --profile dev run --rm codex-dev cargo fmt

# Utility targets
.PHONY: check-env
check-env: ## Check environment setup
	@echo "Checking environment..."
	@if [ -z "$$OPENAI_API_KEY" ] && [ ! -f .env ]; then \
		echo "❌ OPENAI_API_KEY not set and .env file not found"; \
		echo "   Copy env.example to .env and set your API key"; \
		exit 1; \
	fi
	@if command -v docker >/dev/null 2>&1; then \
		echo "✅ Docker is installed"; \
	else \
		echo "❌ Docker is not installed"; \
		exit 1; \
	fi
	@if docker info >/dev/null 2>&1; then \
		echo "✅ Docker daemon is running"; \
	else \
		echo "❌ Docker daemon is not running"; \
		exit 1; \
	fi
	@echo "✅ Environment check passed"

.PHONY: setup
setup: ## Initial setup (copy env file, check requirements)
	@echo "Setting up Codex Docker environment..."
	@if [ ! -f .env ]; then \
		cp env.example .env; \
		echo "📝 Created .env file from template"; \
		echo "   Please edit .env and set your OPENAI_API_KEY"; \
	else \
		echo "✅ .env file already exists"; \
	fi
	@echo "UID=$$(id -u)" >> .env.tmp
	@echo "GID=$$(id -g)" >> .env.tmp
	@if ! grep -q "^UID=" .env; then \
		cat .env.tmp >> .env; \
		echo "📝 Added UID/GID to .env file"; \
	fi
	@rm -f .env.tmp
	@$(MAKE) check-env

.PHONY: info
info: ## Show Docker image and container information
	@echo "Docker Image Information:"
	@echo "========================"
	@echo "Image Name: $(FULL_IMAGE_NAME)"
	@echo "Platform: $(PLATFORM)"
	@echo "Work Dir: $(WORK_DIR)"
	@echo ""
	@if docker image inspect $(FULL_IMAGE_NAME) >/dev/null 2>&1; then \
		echo "✅ Image exists locally"; \
		docker image inspect $(FULL_IMAGE_NAME) --format "Size: {{.Size}} bytes ({{.VirtualSize}} virtual)"; \
		docker image inspect $(FULL_IMAGE_NAME) --format "Created: {{.Created}}"; \
	else \
		echo "❌ Image not found locally"; \
	fi
	@echo ""
	@echo "Running Containers:"
	@docker ps --filter "ancestor=$(FULL_IMAGE_NAME)" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" || true

# Quick start target
.PHONY: quick-start
quick-start: setup build run ## Quick start: setup, build, and run

# Default target
.DEFAULT_GOAL := help
