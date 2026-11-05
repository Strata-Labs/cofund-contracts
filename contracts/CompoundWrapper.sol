// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal interface for Compound V3 (Comet) containing only the methods we need
interface IComet is IERC20 {
    /// @notice The base token that can be supplied/borrowed
    function baseToken() external view returns (address);

    /// @notice Supply an asset to the protocol on behalf of `dst`
    /// @param from The account to transfer the asset from
    /// @param dst The account to credit the supply to
    /// @param asset The asset to supply
    /// @param amount The amount to supply
    function supplyFrom(
        address from,
        address dst,
        address asset,
        uint amount
    ) external;

    /// @notice Withdraw an asset from the protocol on behalf of `src`
    /// @param src The account to debit the withdrawal from
    /// @param to The account to transfer the asset to
    /// @param asset The asset to withdraw
    /// @param amount The amount to withdraw
    function withdrawFrom(
        address src,
        address to,
        address asset,
        uint amount
    ) external;
}

/// @title CompoundWrapper
/// @notice Stateless orchestrator for Vault interactions with Compound V3 (Comet)
/// @dev Uses custodial pattern (Vault → Wrapper → Comet) matching AaveWrapper design
///      Supports USDC and WETH markets universally
///      Optional USDT support for Ethereum mainnet only
///
/// SECURITY MODEL:
/// - Wrapper temporarily holds tokens during supply operation
/// - Wrapper approves Comet for the exact supply amount
/// - Vault receives the Compound supply position (not the wrapper)
/// - No tokens remain in wrapper after transaction
///
/// AUTHORIZATION REQUIREMENTS:
/// Before supply: Vault must approve Wrapper for ERC20 tokens (via allowances array)
/// Before withdraw: Vault must grant Comet allowance via allow(wrapper, true)
contract CompoundWrapper {
    using SafeERC20 for IERC20;

    error InvalidAsset();
    error InvalidAmount();
    error UnsupportedFunc(string func);
    error AccountLiquidatable();
    error InsufficientBalance();
    error InsufficientAllowance();
    event Supplied(address indexed user, address indexed asset, uint256 amount);
    event Withdrawn(
        address indexed user,
        address indexed asset,
        uint256 amount
    );

    // Core Compound V3 markets (required)
    IComet public immutable usdcComet;
    IComet public immutable wethComet;
    
    // Optional USDT market (Ethereum mainnet only)
    IComet public immutable usdtComet;

    bytes32 constant SUPPLY_HASH = keccak256("supplyERC20");
    bytes32 constant WITHDRAW_HASH = keccak256("withdrawERC20");

    /// @notice Initialize CompoundWrapper with chain-specific Comet addresses
    /// @param _usdcComet Address of USDC Comet market (required)
    /// @param _wethComet Address of WETH Comet market (required)
    /// @param _usdtComet Address of USDT Comet market (optional, use address(0) to disable)
    constructor(address _usdcComet, address _wethComet, address _usdtComet) {
        require(_usdcComet != address(0), "Invalid USDC Comet address");
        require(_wethComet != address(0), "Invalid WETH Comet address");
        // Note: _usdtComet can be address(0) for chains without USDT Comet
        
        usdcComet = IComet(_usdcComet);
        wethComet = IComet(_wethComet);
        usdtComet = _usdtComet != address(0) ? IComet(_usdtComet) : IComet(address(0));
    }

    function getComet(address asset) internal view returns (IComet) {
        if (asset == usdcComet.baseToken()) {
            return usdcComet;
        } else if (asset == wethComet.baseToken()) {
            return wethComet;
        } else if (address(usdtComet) != address(0) && asset == usdtComet.baseToken()) {
            return usdtComet;
        } else {
            revert InvalidAsset();
        }
    }

    /// @notice Main entry point for Vault to execute Compound operations
    /// @param instructions ABI-encoded (function, amount, asset)
    /// @return bool True if operation succeeded
    ///
    /// @dev Called by Vault contract during execute() flow
    /// Expected Vault approvals BEFORE calling:
    /// - For supply: Vault.approve(Comet, amount) for ERC20 tokens
    /// - For withdraw: Vault.allow(Wrapper, true) for Comet allowance
    function routerWrapper(
        string calldata /* name */,
        bytes calldata instructions
    ) public returns (bool) {
        (string memory func, uint256 amount, address asset) = abi.decode(
            instructions,
            (string, uint256, address)
        );

        if (asset == address(0)) revert InvalidAsset();
        if (amount == 0) revert InvalidAmount();

        bytes32 funcHash = keccak256(bytes(func));

        if (funcHash == SUPPLY_HASH) {
            supplyERC20(asset, amount);
        } else if (funcHash == WITHDRAW_HASH) {
            withdrawERC20(asset, amount, msg.sender);
        } else {
            revert UnsupportedFunc(func);
        }

        return true;
    }

    /// @notice Supply assets to Compound using custodial pattern (matches AaveWrapper)
    /// @dev Vault → Wrapper → Comet flow for compatibility with allowances system
    /// @param asset The asset to supply
    /// @param amount The amount to supply
    ///
    /// REQUIREMENTS:
    /// - Vault MUST have approved Wrapper for ERC20 tokens (via allowances array)
    /// - Wrapper temporarily holds tokens and approves Comet
    /// - Vault is credited with the supply position
    function supplyERC20(address asset, uint256 amount) internal {
        IComet comet = getComet(asset);
        // HINT: The Vault's allowances array ensures it has approved this address(wrapper)
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        // HINT: Wrapper approves Comet to pull the tokens
        IERC20(asset).safeIncreaseAllowance(address(comet), amount);

        // HINT: Supply to Comet on behalf of the Vault
        // Vault receives the supply position credit, wrapper holds no position
        comet.supplyFrom(address(this), msg.sender, asset, amount);

        emit Supplied(msg.sender, asset, amount);
    }

    /// @notice Withdraw assets from Compound using delegation pattern with approve
    /// @dev Uses Compound V3's binary approval system with withdrawFrom
    /// @param asset The asset to withdraw
    /// @param amount The amount to withdraw
    /// @param to The recipient address (typically Vault itself)
    ///
    /// REQUIREMENTS:
    /// - Vault MUST have approved Wrapper for all comet tokens (via binary approve)
    /// - Vault MUST have sufficient supply balance in Comet
    /// - Compound V3 will revert if withdrawal would cause undercollateralization
    ///
    /// SAFETY:
    /// - Uses withdrawFrom which requires binary approval instead of allow
    /// - Vault's position is debited, assets sent directly to recipient
    /// - Compound V3 protocol handles all health checks and liquidation prevention
    function withdrawERC20(address asset, uint256 amount, address to) internal {
        IComet comet = getComet(asset);

        // Use withdrawFrom with the vault having approved the wrapper via binary approval
        comet.withdrawFrom(msg.sender, to, asset, amount);

        emit Withdrawn(msg.sender, asset, amount);
    }
}
