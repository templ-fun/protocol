# LinkContest plugin: deploy + verification targets.
#
# Included by the main makefile via `-include makefiles/*.mk` so the plugin's
# deploy tooling lives beside its own logic instead of growing the core
# makefile. Uses ETHERSCAN_API_KEY defined in the main makefile.

.PHONY: deploy-contest-factory verify-contest

# Deploy the LinkContestFactory and verify it on Etherscan.
# Usage: make deploy-contest-factory NETWORK=base
deploy-contest-factory:
ifndef NETWORK
	$(error NETWORK is required. Example: make deploy-contest-factory NETWORK=base)
endif
	forge script script/DeployContestFactory.s.sol:DeployContestFactory \
		--rpc-url $(NETWORK) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		-vvv

# Verify one factory-created LinkContest on Etherscan + Sourcify. Every contest
# shares identical runtime bytecode (LinkContest uses no `immutable`), so a
# single verification matches all future contests. Etherscan needs the
# constructor args for factory-deployed contracts; encode them with:
#   cast abi-encode \
#     "constructor(address,address,uint256,uint256,uint256,address)" \
#     <templ> <token> <fee> <roundDuration> <firstRoundStart> <owner>
# Usage:
#   make verify-contest NETWORK=base ADDRESS=0x... \
#     CONSTRUCTOR_ARGS="--constructor-args 0x..."
verify-contest:
ifndef NETWORK
	$(error NETWORK is required. Example: make verify-contest NETWORK=base)
endif
ifndef ADDRESS
	$(error ADDRESS is required. The deployed LinkContest address.)
endif
	@echo "--- Etherscan ---"
	-forge verify-contract $(ADDRESS) \
		src/plugins/link-contest/LinkContest.sol:LinkContest \
		--rpc-url $(NETWORK) \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--skip-is-verified-check \
		$(CONSTRUCTOR_ARGS) \
		--watch
	@echo "--- Sourcify ---"
	-ETHERSCAN_API_KEY="" forge verify-contract $(ADDRESS) \
		src/plugins/link-contest/LinkContest.sol:LinkContest \
		--rpc-url $(NETWORK) \
		--verifier sourcify \
		--skip-is-verified-check
