SHELL := /bin/bash
RUSTC := $(shell command -v rustc 2> /dev/null)

ifndef RUSTC
  $(error "Rust is not available on your system, please install it using: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh")
endif

.PHONY: help docker clean

include .env
export

.DEFAULT_GOAL := help

## Colors
YELLOW := $(shell tput -Txterm setaf 3)
RESET := $(shell tput -Txterm sgr0)

## Help documentation
help:
	@echo "${YELLOW}Available commands:${RESET}"
	@echo
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

## Docker compose up
docker: ## Run docker compose up
	docker-compose -f docker/docker-compose.yml up -d
	@echo "Waiting for the infra to be ready..."
	@while ! docker exec -it pg pg_isready -U postgres > /dev/null 2>&1; do sleep 1; done
	@echo "Database is up and running"
	@sleep 1
	@echo "Creating database and applying migrations..."
	@docker exec -it pg psql -U postgres -c "CREATE DATABASE mydatabase;" > /dev/null 2>&1 || true
	@docker exec -i pg psql -U postgres -d mydatabase < assistants-core/src/migrations.sql > /dev/null 2>&1 || true
	@docker exec pg psql -U postgres -d mydatabase -c "SELECT * FROM runs;" > /dev/null 2>&1 || (echo "Database is not ready" && exit 1)
	@echo "Database is ready"

## Stop and remove containers
clean: ## Stop and remove docker-postgres-1, docker-redis-1, docker-minio-1 containers
	docker stop $$(docker ps -a -q --filter name=pg --filter name=redis --filter name=minio1) > /dev/null 2>&1 || echo "No containers to stop"
	docker rm $$(docker ps -a -q --filter name=pg --filter name=redis --filter name=minio1) > /dev/null 2>&1 || true 
	docker volume rm $$(docker volume ls -q --filter name=pg --filter name=redis --filter name=minio1) > /dev/null 2>&1 || true

## Clean and run docker compose up
reboot: clean docker ## Clean and run docker compose up

## Run the consumer
consumer: ## Run the consumer
	@source .env && cargo run --package assistants-core --bin run_consumer


## Run the server
server: ## Run the server
	@source .env && cargo run --package assistants-api-communication

## Run consumer, server, and dockers
all:
	@source .env && $(MAKE) -j2 consumer server


## Test all
test: ## Run all tests
	@source .env && RUST_TEST_THREADS=1 cargo test --features ci


VENV_PATH ?= ${HOME}/Documents/FastChat/env
# LLM_PATH ?= "open-orca/mistral-7b-openorca"
LLM_PATH ?= "Intel/neural-chat-7b-v3-2"
run_llm: ## Start all services, stop them on SIGINT
	@echo "Starting services..."
	@source $(VENV_PATH)/bin/activate && \
	(python3 -m fastchat.serve.controller & echo $$! > controller.pid) && \
	(python3 -m fastchat.serve.model_worker --model-path ${LLM_PATH} --device mps --load-8bit & echo $$! > model_worker.pid) && \
	(python3 -m fastchat.serve.openai_api_server --host localhost --port 8000 & echo $$! > openai_api_server.pid)
	@echo "Services started. Press Ctrl+C to stop."
	@trap 'echo "Stopping services..."; \
	kill `cat controller.pid` && rm controller.pid || true; \
	kill `cat model_worker.pid` && rm model_worker.pid || true; \
	kill `cat openai_api_server.pid` && rm openai_api_server.pid || true; \
	echo "Services stopped."' SIGINT
	@while true; do sleep 1; done


##@ Development
## Check db/queue content
check: ## Check db/queue content
	@echo "Here's a one-liner Docker CLI command to display the content of the runs table:"
	@echo "docker exec -it pg psql -U postgres -d mydatabase -c \"SELECT * FROM runs;\""
	@echo "Here's a one-liner Docker CLI command to display the content of your Redis instance:"
	@echo "docker exec -it redis redis-cli LRANGE run_queue 0 -1"
	
# Build the Docker image locally for Mac M1/M2
docker-build: ## Build the Docker image locally for Mac M1/M2
	docker-compose -f docker/docker-compose.yml up -d postgres
	while ! docker exec -it pg pg_isready -U postgres; do sleep 1; done
	docker exec -it pg psql -U postgres -c "CREATE DATABASE mydatabase;" > /dev/null 2>&1 || echo "Database already exists"
	docker exec -i pg psql -U postgres -d mydatabase < assistants-core/src/migrations.sql > /dev/null 2>&1 || echo "Migrations already applied"
	cargo build --target aarch64-apple-darwin --release --bin run_consumer
	cargo build --target aarch64-apple-darwin --release --bin assistants-api-communication
	docker build --platform linux/arm64 -f docker/Dockerfile -t assistants .
	$(MAKE) clean > /dev/null 2>&1 || true

## Build the Docker image locally for Linux amd64
docker-build-amd64: ## Build the Docker image locally for Linux amd64
	docker-compose -f docker/docker-compose.yml up -d postgres
	while ! docker exec -it pg pg_isready -U postgres; do sleep 1; done
	docker exec -it pg psql -U postgres -c "CREATE DATABASE mydatabase;" > /dev/null 2>&1 || echo "Database already exists"
	docker exec -i pg psql -U postgres -d mydatabase < assistants-core/src/migrations.sql > /dev/null 2>&1 || echo "Migrations already applied"
	cargo build --target x86_64-unknown-linux-gnu --release --bin run_consumer
	cargo build --target x86_64-unknown-linux-gnu --release --bin assistants-api-communication
	docker build --platform linux/amd64 -f docker/Dockerfile -t assistants .
	$(MAKE) clean > /dev/null 2>&1 || true

# Run the Docker image
docker-run: ## Run the Docker image
	docker run -p 8080:8080 assistants

# Run everything for development (need rust and docker)
dev-all: reboot
	@docker-compose -f docker/docker-compose.yml -f docker/docker-compose.override.yml up -d
	@$(MAKE) -j2 consumer server

## Build the Docker image for the code interpreter
docker-build-code-interpreter-amd64: ## Build the Docker image for the code interpreter for Linux amd64
	docker build --platform linux/amd64 -f docker/Dockerfile.code-interpreter -t code-interpreter-amd64 .

docker-push-code-interpreter-amd64: ## Push the Docker image for the code interpreter to DockerHub for Linux amd64
	docker tag code-interpreter-amd64:latest louis030195/assistants-code-interpreter:latest
	docker push louis030195/assistants-code-interpreter:latest

## Run remote Docker image of Assistants plus the databases
docker-run-remote: ## Run remote Docker image of Assistants plus the databases
	docker-compose -f docker/docker-compose.yml up -d
	@echo "Waiting for the databases to be ready..."
	@while ! docker exec -it pg pg_isready -U postgres; do sleep 1; done
	@docker exec -it pg psql -U postgres -c "CREATE DATABASE mydatabase;" > /dev/null 2>&1 || echo "Database already exists"
	@docker exec -i pg psql -U postgres -d mydatabase < assistants-core/src/migrations.sql > /dev/null 2>&1 || echo "Migrations already applied"
	docker run --platform linux/arm64 --env-file .env -p 8080:8080 ghcr.io/stellar-amenities/assistants/assistants:latest

clean-js:
	rm -rf node_modules package-lock.json package.json

