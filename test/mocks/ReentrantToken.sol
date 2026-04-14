// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev ERC20 that reenters an arbitrary target during transfer/transferFrom.
///      For testing reentrancy guards only.
contract ReentrantToken {
  string public name = "Reentrant Token";
  string public symbol = "REENTER";
  uint8 public decimals = 18;

  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;

  address public attackTarget;
  bytes public attackCalldata;
  bool public attacking;

  /// @dev Arm the token to reenter `_target` with `_data` on next transfer
  function setAttack(
    address _target,
    bytes calldata _data
  ) external {
    attackTarget = _target;
    attackCalldata = _data;
    attacking = true;
  }

  function disableAttack() external {
    attacking = false;
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

    if (attacking) {
      attacking = false;
      (bool ok,) = attackTarget.call(attackCalldata);
      // Swallow result - reentrancy guard should revert
      ok;
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

    if (attacking) {
      attacking = false;
      (bool ok,) = attackTarget.call(attackCalldata);
      ok;
    }

    return true;
  }
}
