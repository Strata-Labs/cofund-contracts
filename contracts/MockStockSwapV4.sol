// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Fixed-price math shared by the wrapper and quoter mocks so a quote is
/// always honoured by the swap. 100.00 USDG (6 dec) buys one whole share (18 dec).
library StockSwapMockMath {
    uint256 internal constant USDG_PER_SHARE = 100e6;
    uint256 internal constant SHARE = 1e18;

    function quote(address usdg, address tokenIn, uint256 amountIn) internal pure returns (uint256) {
        if (tokenIn == usdg) {
            return (amountIn * SHARE) / USDG_PER_SHARE;
        }
        return (amountIn * USDG_PER_SHARE) / SHARE;
    }
}

/// Localhost stand-in for the Robinhood mainnet stock-swap wrapper the webapp
/// targets (see apps/cofund/src/lib/robinhood/stock-pools.ts). It is aliased
/// onto the mainnet wrapper address with the node's setCode RPC (anvil_setCode),
/// which copies code and NOT storage — so it keeps no configuration: prices are
/// constants and its reserves are minted to the aliased address by the local
/// e2e seeding step.
/// Speaks the webapp's payload: routerWrapper("entry", abi.encode(tokenIn,
/// tokenOut, amountIn, minOut, fee, tickSpacing)), pulling tokenIn from the
/// calling vault (which approved it via the transaction's allowances).
contract MockStockSwapV4 {
    using SafeERC20 for IERC20;

    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    event Swapped(address indexed vault, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    error UnsupportedFunction(string name);
    error NotUsdgPair(address tokenIn, address tokenOut);
    error SlippageExceeded(uint256 amountOut, uint256 minOut);

    function routerWrapper(string calldata name, bytes calldata instructions) external returns (bool) {
        if (keccak256(bytes(name)) != keccak256(bytes("entry"))) {
            revert UnsupportedFunction(name);
        }
        (address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, , ) =
            abi.decode(instructions, (address, address, uint256, uint256, uint24, int24));
        if (tokenIn != USDG && tokenOut != USDG) {
            revert NotUsdgPair(tokenIn, tokenOut);
        }
        uint256 amountOut = StockSwapMockMath.quote(USDG, tokenIn, amountIn);
        if (amountOut < minOut) {
            revert SlippageExceeded(amountOut, minOut);
        }
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
        return true;
    }
}

/// Uniswap V4 Quoter stand-in for quoteExactInputSingle, aliased onto the
/// mainnet quoter address. Pure, so the webapp's staticCall works unchanged.
contract MockV4Quoter {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function quoteExactInputSingle(QuoteExactSingleParams calldata params)
        external
        pure
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        address tokenIn = params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1;
        return (StockSwapMockMath.quote(USDG, tokenIn, params.exactAmount), 0);
    }
}
