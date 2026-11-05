// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockStockSwap
/// @notice Demo wrapper contract that swaps WETH for mock stock tokens (and vice versa).
///         The contract holds a reserve of stock tokens; callers send WETH and receive
///         stock tokens at a fixed exchange rate set by the owner.
///         Designed to be called via the Cofund vault's executeTransaction flow.
contract MockStockSwap {
    using SafeERC20 for IERC20;

    error UnsupportedFunction(string func);
    error InvalidAmount();
    error InvalidAsset();
    error InsufficientReserve(address stockToken, uint256 requested, uint256 available);
    error StockTokenNotRegistered(address stockToken);

    /// @notice WETH contract on the target chain
    IERC20 public immutable weth;

    /// @notice Owner / deployer – can set rates and withdraw reserves
    address public owner;

    /// @notice Exchange rate: how many stock-token base-units per 1 WETH (1e18)
    /// e.g. if AMZN token has 18 decimals and rate = 5e18, 1 WETH buys 5 AMZN tokens
    mapping(address stockToken => uint256 rate) public exchangeRates;

    /// @notice Whether a stock token is registered
    mapping(address stockToken => bool) public registeredTokens;

    event StockPurchased(
        address indexed buyer,
        address indexed stockToken,
        uint256 wethSpent,
        uint256 stockReceived
    );

    event StockSold(
        address indexed seller,
        address indexed stockToken,
        uint256 stockSpent,
        uint256 wethReceived
    );

    event ExchangeRateUpdated(address indexed stockToken, uint256 newRate);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    /// @param _weth Address of the WETH contract on this chain
    constructor(address _weth) {
        weth = IERC20(_weth);
        owner = msg.sender;
    }

    // ─── Admin ───────────────────────────────────────────────────────────

    /// @notice Register a stock token and set its exchange rate
    /// @param stockToken The ERC-20 mock stock token address
    /// @param rate       Stock-token base-units received per 1e18 WETH
    function setExchangeRate(address stockToken, uint256 rate) external onlyOwner {
        require(rate > 0, "Rate must be > 0");
        exchangeRates[stockToken] = rate;
        registeredTokens[stockToken] = true;
        emit ExchangeRateUpdated(stockToken, rate);
    }

    /// @notice Withdraw any ERC-20 held by this contract (admin utility)
    function withdrawToken(address token, uint256 amount, address to) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    // ─── Router (called by vault.executeTransaction) ─────────────────────

    /// @notice Entry point called by the Cofund vault via executeTransaction
    /// @param instructions ABI-encoded (string func, uint256 amount, address stockToken)
    function routerWrapper(
        string calldata /* name */,
        bytes calldata instructions
    ) external returns (bool) {
        (string memory func, uint256 amount, address stockToken) = abi.decode(
            instructions,
            (string, uint256, address)
        );

        if (stockToken == address(0)) revert InvalidAsset();
        if (amount == 0) revert InvalidAmount();
        if (!registeredTokens[stockToken]) revert StockTokenNotRegistered(stockToken);

        if (keccak256(bytes(func)) == keccak256(bytes("buyStock"))) {
            _buyStock(amount, stockToken, msg.sender);
        } else if (keccak256(bytes(func)) == keccak256(bytes("sellStock"))) {
            _sellStock(amount, stockToken, msg.sender);
        } else {
            revert UnsupportedFunction(func);
        }

        return true;
    }

    // ─── Internal ────────────────────────────────────────────────────────

    /// @notice Swap WETH → stock token
    /// @param wethAmount Amount of WETH to spend (in wei)
    /// @param stockToken The stock token to receive
    /// @param buyer      The vault address that sends WETH and receives stock tokens
    function _buyStock(uint256 wethAmount, address stockToken, address buyer) internal {
        uint256 rate = exchangeRates[stockToken];
        uint256 stockOut = (wethAmount * rate) / 1e18;

        uint256 reserve = IERC20(stockToken).balanceOf(address(this));
        if (reserve < stockOut) {
            revert InsufficientReserve(stockToken, stockOut, reserve);
        }

        // Pull WETH from the vault
        weth.safeTransferFrom(buyer, address(this), wethAmount);

        // Send stock tokens to the vault
        IERC20(stockToken).safeTransfer(buyer, stockOut);

        emit StockPurchased(buyer, stockToken, wethAmount, stockOut);
    }

    /// @notice Swap stock token → WETH
    /// @param stockAmount Amount of stock tokens to sell
    /// @param stockToken  The stock token being sold
    /// @param seller      The vault address that sends stock tokens and receives WETH
    function _sellStock(uint256 stockAmount, address stockToken, address seller) internal {
        uint256 rate = exchangeRates[stockToken];
        uint256 wethOut = (stockAmount * 1e18) / rate;

        uint256 wethReserve = weth.balanceOf(address(this));
        if (wethReserve < wethOut) {
            revert InsufficientReserve(address(weth), wethOut, wethReserve);
        }

        // Pull stock tokens from the vault
        IERC20(stockToken).safeTransferFrom(seller, address(this), stockAmount);

        // Send WETH to the vault
        weth.safeTransfer(seller, wethOut);

        emit StockSold(seller, stockToken, stockAmount, wethOut);
    }
}
