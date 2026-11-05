// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./CFHelpersVaultTemplatev1.sol";

contract CFHelpersVaultFactoryv1 {
    using Clones for address;

    /* ----------  Immutables  ---------- */
    address public immutable template;
    address public immutable state; // same shared state for all vaults

    /* ----------  Events  ---------- */
    event VaultCreated(bytes32 indexed clientId, address vault);

    /* ----------  Errors  ---------- */
    error UnauthorizedCaller();

    constructor(address _state) {
        state = _state;
        template = address(new CFHelpersVaultTemplatev1(_state));
    }

    /* ----------  Public API  ---------- */

    /// @dev Deploys and initializes a client's vault. Stateless: State's
    ///      `clientVaults` is the only vault registry, and `state.newClient` is
    ///      the one path here. No idempotency — a second call for the same salt
    ///      reverts inside `Clones`, and State guards `ClientExists` long
    ///      before that. Anyone who needs the address predicts it.
    function createVault(bytes32 clientId) external returns (address vault) {
        if (msg.sender != state) revert UnauthorizedCaller();

        vault = template.cloneDeterministic(clientId); // salt = clientId
        CFHelpersVaultTemplatev1(vault).initialize(clientId, state);

        emit VaultCreated(clientId, vault);
    }

    /// @dev Pure prediction helper (no storage hit).
    function predictVault(bytes32 clientId) external view returns (address) {
        return template.predictDeterministicAddress(clientId, address(this));
    }
}
