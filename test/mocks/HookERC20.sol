// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITokensReceivedHook {
  function tokensReceived(
    address from,
    uint256 amount
  ) external;
}

/// @dev ERC20 with an ERC777-style "tokensReceived" callback to the recipient.
///      Models the cross-contract reentrancy threat that the security review
///      flagged: when TOKEN has receive hooks and the protocol forwards a
///      slice of an entry fee to a contract, that contract's hook runs
///      synchronously inside the transfer, before the splitter finishes.
///
///      For testing only. Not a faithful ERC777 - just enough to exercise the
///      hook reentrancy path on `transfer` to a contract recipient that has
///      opted in via `setHookEnabled`.
contract HookERC20 {
  string public name = "Hook Token";
  string public symbol = "HOOK";
  uint8 public decimals = 18;

  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;
  mapping(address => bool) public hookEnabled;

  /// @notice Opt a contract recipient in to receive `tokensReceived` callbacks
  ///         on inbound transfers.
  function setHookEnabled(
    address recipient,
    bool enabled
  ) external {
    hookEnabled[recipient] = enabled;
  }

  function mint(
    address to,
    uint256 amount
  ) external {
    balanceOf[to] += amount;
  }

  function approve(
    address spender,
    uint256 amount
  ) external returns (bool) {
    allowance[msg.sender][spender] = amount;
    return true;
  }

  function transfer(
    address to,
    uint256 amount
  ) external returns (bool) {
    balanceOf[msg.sender] -= amount;
    balanceOf[to] += amount;
    if (hookEnabled[to]) {
      ITokensReceivedHook(to).tokensReceived(msg.sender, amount);
    }
    return true;
  }

  function transferFrom(
    address from,
    address to,
    uint256 amount
  ) external returns (bool) {
    allowance[from][msg.sender] -= amount;
    balanceOf[from] -= amount;
    balanceOf[to] += amount;
    if (hookEnabled[to]) {
      ITokensReceivedHook(to).tokensReceived(from, amount);
    }
    return true;
  }
}
