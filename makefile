# Templ Contracts v2

# Etherscan API key for contract verification on deploy.
ETHERSCAN_API_KEY ?=

.PHONY: help install update build test coverage fmt lint clean predict deploy verify

# Plugin-specific deploy/verify targets live in each plugin's own .mk file,
# co-located with the plugin's contracts under src/plugins/<name>/.
-include src/plugins/*/*.mk

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
	@jq '.abi' out/MemberPool.sol/MemberPool.json > abi/MemberPool.json
	@jq '.abi' out/JoinWithNative.sol/JoinWithNative.json > abi/JoinWithNative.json
	@jq '.abi' out/Governance.sol/Governance.json > abi/Governance.json
	@jq '.abi' out/Democracy.sol/Democracy.json > abi/Democracy.json
	@jq '.abi' out/Council.sol/Council.json > abi/Council.json
	@jq '.abi' out/GovernanceDeployer.sol/GovernanceDeployer.json > abi/GovernanceDeployer.json
	@jq '.abi' out/DemocracyDeployer.sol/DemocracyDeployer.json > abi/DemocracyDeployer.json
	@jq '.abi' out/CouncilDeployer.sol/CouncilDeployer.json > abi/CouncilDeployer.json
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

