// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Aave v3 core interfaces (Pool & Provider)
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";

// Aave v3 periphery interface (ETH helper)
import {IWrappedTokenGatewayV3} from "@aave/periphery-v3/contracts/misc/interfaces/IWrappedTokenGatewayV3.sol";

contract AaveWrapper {
    using SafeERC20 for IERC20;

    // Custom errors for better debugging
    error UnsupportedFunction(string func);
    error InsufficientBalance(address asset, uint256 requested, uint256 available);
    error WithdrawalFailed(address asset, uint256 amount);
    error InvalidAmount();
    error InvalidAsset();

    IPoolAddressesProvider public immutable provider;
    IPool public immutable pool;

    /// @param _provider Chain’s PoolAddressesProvider (resolves the current Pool)
    constructor(address _provider) {
        provider = IPoolAddressesProvider(_provider);
        pool = IPool(provider.getPool());
    }

    function routerWrapper(
        string calldata /* name */,
        bytes calldata instructions
    ) external returns (bool) {
        (string memory func, uint256 amount, address asset) = abi.decode(
            instructions,
            (string, uint256, address)
        );

        // Input validation
        if (asset == address(0)) revert InvalidAsset();
        if (amount == 0) revert InvalidAmount();

        if (keccak256(bytes(func)) == keccak256(bytes("supplyERC20"))) {
            supplyERC20(asset, amount, msg.sender);
        } else if (
            keccak256(bytes(func)) == keccak256(bytes("withdrawERC20"))
        ) {
            withdrawERC20(asset, amount, msg.sender);
        } else {
            revert UnsupportedFunction(func);
        }

        return true;
    }

    // ---------------- ERC20 supply / withdraw ----------------

    /// @notice Supply any ERC20 supported by Aave v3.
    /// @param asset      underlying token (e.g., USDC, DAI, WETH)
    /// @param amount     amount in underlying units
    /// @param onBehalfOf who receives aTokens (the vault that called this wrapper)
    function supplyERC20(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) internal {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).safeIncreaseAllowance(address(pool), amount);
        // Supply on behalf of the calling vault so the vault holds the aTokens
        pool.supply(asset, amount, onBehalfOf, 0); // referralCode = 0
    }

    /// @notice Withdraw underlying back to a recipient.
    /// @dev The vault (msg.sender) must approve the Pool to burn aTokens BEFORE calling this
    /// @param asset  underlying token
    /// @param amount amount to withdraw; use type(uint256).max to withdraw all
    /// @param to     recipient
    /// @return withdrawn The actual amount withdrawn
    function withdrawERC20(
        address asset,
        uint256 amount,
        address to
    ) internal returns (uint256 withdrawn) {
        // Get the aToken address for this asset
        address aTokenAddress = pool.getReserveData(asset).aTokenAddress;
        if (aTokenAddress == address(0)) revert InvalidAsset();
        
        // Check aToken balance of the calling vault (msg.sender)
        uint256 aTokenBalance = IERC20(aTokenAddress).balanceOf(msg.sender);
        
        // If withdrawing max, use the full balance
        uint256 withdrawAmount = amount;
        if (amount == type(uint256).max) {
            withdrawAmount = aTokenBalance;
        }
        
        // Check if the vault has sufficient aTokens
        if (aTokenBalance < withdrawAmount) {
            revert InsufficientBalance(asset, withdrawAmount, aTokenBalance);
        }
        
        // Transfer aTokens from vault to wrapper
        // The wrapper will then be the owner that Aave burns from
        IERC20(aTokenAddress).safeTransferFrom(msg.sender, address(this), withdrawAmount);
        
        // Approve the Pool to burn our aTokens
        IERC20(aTokenAddress).safeIncreaseAllowance(address(pool), withdrawAmount);
        
        // Perform the withdrawal - Pool will burn aTokens from this wrapper
        try pool.withdraw(asset, withdrawAmount, to) returns (uint256 actualWithdrawn) {
            withdrawn = actualWithdrawn;
        } catch {
            revert WithdrawalFailed(asset, withdrawAmount);
        }
    }
}
