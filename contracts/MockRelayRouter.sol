// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Stand-in for the Relay router used when tests run without a
///         mainnet fork. Behaves like the live relayer's deposit step:
///         pulls the input tokens the RelayWrapper approved and emits the
///         intent.
contract MockRelayRouter {
    using SafeERC20 for IERC20;

    event DepositPulled(
        address indexed from,
        address indexed token,
        uint256 amount,
        uint256 value
    );

    function deposit(address token, uint256 amount) external payable {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit DepositPulled(msg.sender, token, amount, msg.value);
    }
}
