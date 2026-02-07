.PHONY: clean clean-test clean-pyc clean-build help
.DEFAULT_GOAL := help

define PRINT_HELP_PYSCRIPT
import re, sys

for line in sys.stdin:
	match = re.match(r'^([a-zA-Z_-]+):.*?## (.*)$$', line)
	if match:
		target, help = match.groups()
		print("%-20s %s" % (target, help))
endef
export PRINT_HELP_PYSCRIPT

help:
	@python -c "$$PRINT_HELP_PYSCRIPT" < $(MAKEFILE_LIST)

clean: clean-build clean-pyc clean-test ## remove all build, test, coverage and Python artifacts

clean-build: ## remove build artifacts
	rm -fr build/
	rm -fr dist/
	rm -rf .eggs/
	find . -maxdepth 1 -name '*.egg-info' -exec rm -fr {} +
	find . -maxdepth 1 -name '*.egg' -exec rm -f {} +

clean-pyc: ## remove Python file artifacts
	find . -name '*.pyc' -exec rm -f {} +
	find . -name '*.pyo' -exec rm -f {} +
	find . -name '*~' -exec rm -f {} +
	find . -name '__pycache__' -exec rm -fr {} +

clean-test: ## remove test and coverage artifacts
	rm -f .coverage
	rm -fr htmlcov/

lint: ## check style with ruff
	ruff format d2d tests
	ruff check --fix d2d tests
	cython-lint d2d/
	mypy d2d tests

test: ## run tests quickly with the default Python
	pytest tests -s -v

install: clean ## install the package to the active Python's site-packages
	python setup.py install

dev:
	python setup.py build_ext --inplace --cython --lexbor

dev-static: clean-build
	python setup.py build_ext --inplace --cython --static --disable-modest