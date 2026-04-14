# Templ Contracts v2

# Etherscan API key for contract verification on deploy.
# Same key is used in apps/workers/abi/wrangler.toml for ABI lookups.
ETHERSCAN_API_KEY ?= 8YE1VTIFTZWZGIYJ7YXBJR9B4VZDD5D4XY

.PHONY: help install update build test coverage fmt lint clean predict deploy verify publish

help:
	@echo "Usage:"
	@echo "  make install            Install dependencies (Soldeer)"
	@echo "  make update             Update dependencies"
	@echo "  make build              Compile contracts"
	@echo "  make test               Run tests"
	@echo "  make test-v             Run tests (verbose)"
	@echo "  make coverage           Coverage summary"
	@echo "  make coverage-html      Generate HTML report"
	@echo "  make fmt                Format code"
	@echo "  make lint               Run linter"
	@echo "  make abi-export         Export ABIs to abi/"
	@echo "  make snapshot           Generate gas snapshot"
	@echo "  make clean              Remove artifacts"
	@echo ""
	@echo "Publishing:"
	@echo "  make publish            Sync contracts to templ-fun/protocol repo"
	@echo "  make publish-fresh      Reset protocol repo to single commit with current state"
	@echo ""
	@echo "Deployment:"
	@echo "  make predict NETWORK=base_sepolia   Preview deterministic address"
	@echo "  make deploy NETWORK=base_sepolia    Deploy via CREATE2 + verify"
	@echo "  make verify NETWORK=base ADDRESS=0x... CONTRACT=src/Templ.sol:Templ"
	@echo ""
	@echo "Networks: localhost, base, base_sepolia, optimism, arbitrum, mainnet"

install:
	forge soldeer install

update:
	forge soldeer update

build:
	forge build

# Run tests. Use test-v to see stack traces and decoded logs on failure.
test:
	forge test

test-v:
	forge test -vvv

coverage:
	forge coverage

coverage-lcov:
	forge coverage --report lcov

coverage-html: coverage-lcov
	@which genhtml > /dev/null || (echo "Install lcov: brew install lcov" && exit 1)
	genhtml lcov.info -o coverage --branch-coverage --ignore-errors inconsistent --css-file coverage/coverage.css
	@echo "Coverage report: coverage/index.html"

fmt:
	forge fmt

fmt-check:
	forge fmt --check

lint:
	forge lint

snapshot:
	forge snapshot

abi-export: build
	@mkdir -p abi
	@jq '.abi' out/Templ.sol/Templ.json > abi/Templ.json
	@jq '.abi' out/Factory.sol/Factory.json > abi/Factory.json
	@jq '.abi' out/Treasury.sol/Treasury.json > abi/Treasury.json
	@jq '.abi' out/JoinWithNative.sol/JoinWithNative.json > abi/JoinWithNative.json
	@jq '.abi' out/Governance.sol/Governance.json > abi/Governance.json
	@jq '.abi' out/Democracy.sol/Democracy.json > abi/Democracy.json
	@jq '.abi' out/Council.sol/Council.json > abi/Council.json
	@echo "ABIs exported to abi/"

clean:
	forge clean
	find coverage -mindepth 1 ! -name 'coverage.css' -delete 2>/dev/null || true
	rm -f lcov.info

clean-all: clean
	rm -rf dependencies

anvil:
	anvil

predict:
ifndef NETWORK
	$(error NETWORK is required. Example: make predict NETWORK=base_sepolia)
endif
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(NETWORK) \
		-vvv

deploy:
ifndef NETWORK
	$(error NETWORK is required. Example: make deploy NETWORK=base_sepolia)
endif
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(NETWORK) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		-vvv

# Verify an already-deployed contract on Etherscan + Sourcify.
# No constructor args needed - Sourcify extracts them from the chain.
# Etherscan may need CONSTRUCTOR_ARGS for factory-deployed contracts.
# Usage: make verify NETWORK=base ADDRESS=0x... CONTRACT=src/Templ.sol:Templ
verify:
ifndef NETWORK
	$(error NETWORK is required. Example: make verify NETWORK=base)
endif
ifndef ADDRESS
	$(error ADDRESS is required. The deployed contract address.)
endif
ifndef CONTRACT
	$(error CONTRACT is required. Example: CONTRACT=src/governance/Governance.sol:Governance)
endif
	@echo "--- Etherscan ---"
	-forge verify-contract $(ADDRESS) $(CONTRACT) \
		--rpc-url $(NETWORK) \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--skip-is-verified-check \
		$(CONSTRUCTOR_ARGS) \
		--watch
	@echo "--- Sourcify ---"
	-ETHERSCAN_API_KEY="" forge verify-contract $(ADDRESS) $(CONTRACT) \
		--rpc-url $(NETWORK) \
		--verifier sourcify \
		--skip-is-verified-check

# Publish contracts to the standalone audit repo (templ-fun/protocol).
# Clones fresh, replaces all files with current state, commits and pushes.
PUBLISH_REPO ?= git@github.com:templ-fun/protocol.git

publish:
	@set -e; \
	TMPDIR=$$(mktemp -d); \
	COMMIT=$$(git rev-parse --short HEAD); \
	NAME=$$(git config user.name); \
	EMAIL=$$(git config user.email); \
	SIGNKEY=$$(git config user.signingkey); \
	echo "Cloning $(PUBLISH_REPO)..."; \
	git clone $(PUBLISH_REPO) $$TMPDIR/repo; \
	cd $$TMPDIR/repo && git config user.name "$$NAME"; \
	cd $$TMPDIR/repo && git config user.email "$$EMAIL"; \
	cd $$TMPDIR/repo && git config user.signingkey "$$SIGNKEY"; \
	cd $$TMPDIR/repo && git config gpg.format ssh; \
	cd $$TMPDIR/repo && find . -maxdepth 1 ! -name '.git' ! -name '.' -exec rm -rf {} +; \
	cp -r $(CURDIR)/src $(CURDIR)/test $(CURDIR)/script $(CURDIR)/abi \
		$(CURDIR)/foundry.toml $(CURDIR)/soldeer.lock $(CURDIR)/makefile \
		$(CURDIR)/package.json $(CURDIR)/README.md $(CURDIR)/.gitignore \
		$$TMPDIR/repo/; \
	cd $$TMPDIR/repo && git add -A; \
	if cd $$TMPDIR/repo && git diff --cached --quiet; then \
		echo "No changes to publish."; \
	else \
		cd $$TMPDIR/repo && git diff --cached --stat; \
		cd $$TMPDIR/repo && git commit -m "sync $$COMMIT"; \
		cd $$TMPDIR/repo && git push; \
		echo "Published to $(PUBLISH_REPO)"; \
	fi; \
	rm -rf $$TMPDIR

# Fresh publish: reset protocol repo to a single commit with current contract state.
publish-fresh:
	@set -e; \
	TMPDIR=$$(mktemp -d); \
	COMMIT=$$(git rev-parse --short HEAD); \
	NAME=$$(git config user.name); \
	EMAIL=$$(git config user.email); \
	SIGNKEY=$$(git config user.signingkey); \
	echo "Creating fresh repo from $(PUBLISH_REPO)..."; \
	mkdir -p $$TMPDIR/repo && cd $$TMPDIR/repo && git init; \
	cd $$TMPDIR/repo && git config user.name "$$NAME"; \
	cd $$TMPDIR/repo && git config user.email "$$EMAIL"; \
	cd $$TMPDIR/repo && git config user.signingkey "$$SIGNKEY"; \
	cd $$TMPDIR/repo && git config gpg.format ssh; \
	cp -r $(CURDIR)/src $(CURDIR)/test $(CURDIR)/script $(CURDIR)/abi \
		$(CURDIR)/foundry.toml $(CURDIR)/soldeer.lock $(CURDIR)/makefile \
		$(CURDIR)/package.json $(CURDIR)/README.md $(CURDIR)/.gitignore \
		$$TMPDIR/repo/; \
	cd $$TMPDIR/repo && git add -A; \
	cd $$TMPDIR/repo && git commit -m "Templ Protocol contracts ($$COMMIT)"; \
	cd $$TMPDIR/repo && git branch -M main; \
	cd $$TMPDIR/repo && git remote add origin $(PUBLISH_REPO); \
	cd $$TMPDIR/repo && git push --force origin main; \
	echo "Fresh publish to $(PUBLISH_REPO) complete."; \
	rm -rf $$TMPDIR
