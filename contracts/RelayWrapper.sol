// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RelayWrapper
/// @notice Stateless wrapper that lets a Cofund vault execute a Relay
///         (https://relay.link) cross-chain swap+bridge by dispatching the
///         calldata returned from Relay's /quote endpoint.
///
/// Flow per executeTransaction call:
///   1. Vault has approved this wrapper for `amount` of `inputToken` via the
///      `allowances` array on the vault.
///   2. Wrapper pulls `inputToken` from the vault (msg.sender) into itself.
///   3. Wrapper approves the Relay router (`target`) for the same amount.
///   4. Wrapper invokes `target.call{value: msg.value}(data)` — the Relay
///      relayer pulls the tokens via the allowance and emits the cross-chain
///      intent.
///   5. Any leftover input dust is swept back to the vault and the approval
///      to `target` is reset to 0.
contract RelayWrapper {
    using SafeERC20 for IERC20;

    error InvalidTarget();
    error InvalidAmount();
    error InvalidToken();
    error UnsupportedFunc(string func);
    error RelayCallFailed(bytes reason);

    event RelayDispatched(
        address indexed vault,
        address indexed target,
        address indexed inputToken,
        uint256 amount,
        bytes32 dataHash
    );

    bytes32 private constant ENTRY_HASH = keccak256("entry");

    /// @notice Main entry point invoked by the vault during executeTransaction.
    /// @param  instructions  abi.encode(string func, address inputToken,
    ///                                  uint256 amount, address target,
    ///                                  bytes data) where `func` must be
    ///                       "entry".
    function routerWrapper(
        string calldata /* name */,
        bytes calldata instructions
    ) external payable returns (bool) {
        (
            string memory func,
            address inputToken,
            uint256 amount,
            address target,
            bytes memory data
        ) = abi.decode(
            instructions,
            (string, address, uint256, address, bytes)
        );

        if (keccak256(bytes(func)) != ENTRY_HASH) {
            revert UnsupportedFunc(func);
        }

        if (inputToken == address(0)) revert InvalidToken();
        if (amount == 0) revert InvalidAmount();
        if (target == address(0)) revert InvalidTarget();

        // 1. Pull tokens from the vault (uses the vault's allowance to wrapper).
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), amount);

        // 2. Approve the Relay router for the exact amount.
        IERC20(inputToken).forceApprove(target, amount);

        // 3. Dispatch the calldata returned by Relay's /quote endpoint.
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) revert RelayCallFailed(ret);

        // 4. Sweep leftover dust (most of the time the relayer takes the full
        //    amount, but be defensive) and clear the approval.
        uint256 leftover = IERC20(inputToken).balanceOf(address(this));
        if (leftover != 0) {
            IERC20(inputToken).safeTransfer(msg.sender, leftover);
        }
        IERC20(inputToken).forceApprove(target, 0);

        emit RelayDispatched(
            msg.sender,
            target,
            inputToken,
            amount,
            keccak256(data)
        );
        return true;
    }

    /// @notice Allow the wrapper to receive ETH refunds from Relay if any
    ///         (e.g. native fee overpayment).
    receive() external payable {}
}
