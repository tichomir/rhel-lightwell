# Image Mode Train Service - developer tasks.
#
# Container and host operations live in scripts/, not here, because they take
# arguments you should be forced to think about.

.DEFAULT_GOAL := help
VENV := .venv
PY   := $(VENV)/bin/python
PIP  := $(VENV)/bin/pip

.PHONY: help pincheck venv dev run test test-vulnerable test-remediated deps clean

help:
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-18s %s\\n", $$1, $$2}'

pincheck: ## Step 1: does the pinned dependency install and work on this Python?
	./scripts/pincheck.sh

venv: ## Create the virtualenv and install runtime dependencies
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	$(PIP) install -r requirements.txt

dev: venv ## Install development dependencies too
	$(PIP) install -r requirements-dev.txt

run: ## Run the app locally on :8080
	$(PY) -m app.main

test: ## Full suite, inferring the expected CVE state from the installed version
	$(VENV)/bin/pytest -v

test-vulnerable: ## Assert the pre-remediation state (Act 2)
	$(VENV)/bin/pytest -v --expect=vulnerable

test-remediated: ## Assert the post-remediation state (Act 4)
	$(VENV)/bin/pytest -v --expect=remediated

deps: ## Show what is installed, and whether it is a Lightwell build
	@$(PY) -c "from app.sysinfo import dependency_versions, lightwell_state; \
	import json; print(json.dumps({\"versions\": dependency_versions(), \\
	\"lightwell\": lightwell_state()}, indent=2))"

clean: ## Remove the venv and caches
	rm -rf $(VENV) .pytest_cache dist build
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
