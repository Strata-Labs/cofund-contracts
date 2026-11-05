// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";

/// @notice aToken stand-in minted/burned 1:1 by MockAavePool.
contract MockAToken is ERC20 {
    address public immutable pool;

    modifier onlyPool() {
        require(msg.sender == pool, "MockAToken: only pool");
        _;
    }

    constructor(address _pool) ERC20("Mock aToken", "maTKN") {
        pool = _pool;
    }

    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }
}

/// @notice Local stand-in for the slice of Aave v3's Pool used by
///         AaveWrapper: supply / withdraw / getReserveData. aTokens are
///         minted 1:1 with the supplied underlying (no interest).
contract MockAavePool {
    using SafeERC20 for IERC20;

    mapping(address => address) public aTokens; // underlying -> aToken

    function initReserve(address asset) external returns (address aToken) {
        require(aTokens[asset] == address(0), "MockAavePool: reserve exists");
        aToken = address(new MockAToken(address(this)));
        aTokens[asset] = aToken;
    }

    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 /* referralCode */
    ) external {
        address aToken = aTokens[asset];
        require(aToken != address(0), "MockAavePool: no reserve");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        MockAToken(aToken).mint(onBehalfOf, amount);
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256) {
        address aToken = aTokens[asset];
        require(aToken != address(0), "MockAavePool: no reserve");
        uint256 amt = amount == type(uint256).max
            ? MockAToken(aToken).balanceOf(msg.sender)
            : amount;
        MockAToken(aToken).burn(msg.sender, amt);
        IERC20(asset).safeTransfer(to, amt);
        return amt;
    }

    function getReserveData(
        address asset
    ) external view returns (DataTypes.ReserveData memory data) {
        data.aTokenAddress = aTokens[asset];
    }
}

/// @notice Resolves MockAavePool for AaveWrapper's constructor.
contract MockPoolAddressesProvider {
    address private immutable _pool;

    constructor(address pool_) {
        _pool = pool_;
    }

    function getPool() external view returns (address) {
        return _pool;
    }
}
