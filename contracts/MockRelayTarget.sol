// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Test-only stand-ins for the contract roles WP2 has to exercise but that no
// real contract can stand in for: a v1 helper behind `CFSponsorGuardv1.relay`,
// a contract that holds the Cofund-admin bit and calls `CFHelpersGovv1`, and a
// contract that claims to be a vault it is not. All live here to keep WP2 to a
// single extra file.

/// @title MockRelayTarget
/// @notice Stand-in for a v1 helper registered as
///         `state.helperContracts("users")` / `("policies")`.
/// @dev Records the last calldata it was handed so a test can prove the guard
///      forwards verbatim, for any selector -- including selectors that are on
///      no whitelist and are not even in this ABI.
contract MockRelayTarget {
    /// @dev Reverted by `boom`, to check the guard bubbles a helper revert.
    error Boom(uint256 code);

    /// @notice Calldata of the most recent call, selector included.
    bytes public lastData;
    /// @notice Caller of the most recent call (the guard, when relayed).
    address public lastCaller;
    /// @notice Number of calls received.
    uint256 public callCount;

    event Recorded(address indexed caller, bytes data);

    /// @notice Named entrypoint, so a test can build calldata through the ABI.
    function record(uint256 value) external returns (uint256) {
        _record();
        return value;
    }

    /// @notice Always reverts, so a test can watch the revert cross the guard.
    function boom(uint256 code) external pure {
        revert Boom(code);
    }

    /// @dev Catches every other selector -- the helper rule allows all of them.
    fallback() external {
        _record();
    }

    function _record() private {
        lastData = msg.data;
        lastCaller = msg.sender;
        callCount++;
        emit Recorded(msg.sender, msg.data);
    }
}

/// @title MockVaultImposter
/// @notice Answers `clientId()` with an id of its choosing, like a real vault.
/// @dev The guard resolves that id through `state.clientVaults` and compares
///      the registered address with the caller's target, so an imposter is
///      refused whether it claims a live client's id or an unknown one.
contract MockVaultImposter {
    bytes32 public clientId;

    constructor(bytes32 _clientId) {
        clientId = _clientId;
    }
}

/// @title MockAdminCaller
/// @notice Minimal contract account, used as a Cofund admin.
/// @dev Proxy for a 7702-delegated admin EOA: what matters is only that
///      `msg.sender` at the gov helper has code. v0's `_enforceEOA` rejected
///      such a caller outright; v1 has no `code.length` gate.
contract MockAdminCaller {
    /// @notice Forward one call to `target`, bubbling its revert verbatim so a
    ///         test can still match the target's own custom errors.
    function forward(address target, bytes calldata data)
        external
        payable
        returns (bytes memory)
    {
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}
