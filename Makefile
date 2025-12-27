SHELL := /bin/zsh

SWIFT := swift
CONFIG ?= release
ARGS ?=

.DEFAULT_GOAL := help

.PHONY: help build run test lint clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_%-]+:.*##/ {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build ($(CONFIG))
	$(SWIFT) build -c $(CONFIG)

run: ## Run (ARGS='...')
	$(SWIFT) run -c $(CONFIG) PhotosExport -- $(ARGS)

test: ## Run unit tests
	$(SWIFT) test

# Minimal, dependency-free lint: treat compiler warnings as errors.
lint: ## Lint (warnings-as-errors)
	$(SWIFT) build -Xswiftc -warnings-as-errors

clean: ## Clean build artifacts
	$(SWIFT) package clean
