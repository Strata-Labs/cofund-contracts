// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Local stand-in for a Compound V3 (Comet) market covering the
///         surface CompoundWrapper and its tests use: baseToken,
///         supplyFrom, withdrawFrom, balanceOf, and the (binary)
///         approve-based permission system.
///
/// Supplied balances accrue interest per block (tiny linear rate, so a
/// same-block read still equals the supplied amount exactly). Unlike the
/// real Comet there is no principal-conversion rounding: supplies are
/// credited 1:1.
contract MockComet {
    using SafeERC20 for IERC20;

    address private immutable _baseToken;

    mapping(address => uint256) private _principal;
    mapping(address => uint256) private _lastAccrualBlock;
    mapping(address => mapping(address => uint256)) private _allowance;
    uint256 private _totalPrincipal;

    // principal / RATE_DIVISOR accrued per block.
    uint256 private constant RATE_DIVISOR = 10_000_000;

    constructor(address base) {
        _baseToken = base;
    }

    function baseToken() external view returns (address) {
        return _baseToken;
    }

    function _pending(address account) private view returns (uint256) {
        uint256 p = _principal[account];
        if (p == 0) return 0;
        return (p * (block.number - _lastAccrualBlock[account])) / RATE_DIVISOR;
    }

    function _accrue(address account) private {
        _principal[account] += _pending(account);
        _lastAccrualBlock[account] = block.number;
    }

    function _hasPermission(address owner_, address manager) private view returns (bool) {
        return owner_ == manager || _allowance[owner_][manager] != 0;
    }

    function supplyFrom(
        address from,
        address dst,
        address asset,
        uint256 amount
    ) external {
        require(asset == _baseToken, "MockComet: wrong asset");
        require(_hasPermission(from, msg.sender), "MockComet: not permitted");
        IERC20(asset).safeTransferFrom(from, address(this), amount);
        _accrue(dst);
        _principal[dst] += amount;
        _totalPrincipal += amount;
    }

    function withdrawFrom(
        address src,
        address to,
        address asset,
        uint256 amount
    ) external {
        require(asset == _baseToken, "MockComet: wrong asset");
        require(_hasPermission(src, msg.sender), "MockComet: not permitted");
        _accrue(src);
        require(_principal[src] >= amount, "MockComet: insufficient balance");
        _principal[src] -= amount;
        _totalPrincipal = _totalPrincipal >= amount ? _totalPrincipal - amount : 0;
        IERC20(asset).safeTransfer(to, amount);
    }

    // ---- ERC20 surface (IComet extends IERC20) ----

    function balanceOf(address account) external view returns (uint256) {
        return _principal[account] + _pending(account);
    }

    function totalSupply() external view returns (uint256) {
        return _totalPrincipal;
    }

    /// @dev Comet treats approve as a binary permission grant.
    function approve(address spender, uint256 amount) external returns (bool) {
        _allowance[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowance[owner_][spender];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _accrue(msg.sender);
        _accrue(to);
        require(_principal[msg.sender] >= amount, "MockComet: insufficient balance");
        _principal[msg.sender] -= amount;
        _principal[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_hasPermission(from, msg.sender), "MockComet: not permitted");
        _accrue(from);
        _accrue(to);
        require(_principal[from] >= amount, "MockComet: insufficient balance");
        _principal[from] -= amount;
        _principal[to] += amount;
        return true;
    }
}
