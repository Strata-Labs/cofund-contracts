// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CFHelpersVaultTemplatev1_1} from "./CFHelpersVaultTemplatev1_1.sol";

/// @notice v1's factory, cloning the v1.1 template. v1's factory can't be
///         reused: its constructor deploys the v1 template, and a template
///         only lets its deployer initialize clones.
contract CFHelpersVaultFactoryv1_1 {
    using Clones for address;

    address public immutable template;
    address public immutable state;

    event VaultCreated(bytes32 indexed clientId, address vault);

    error UnauthorizedCaller();

    constructor(address _state) {
        state = _state;
        template = address(new CFHelpersVaultTemplatev1_1(_state));
    }

    /// @dev State's `newClient` is the one caller; salt = clientId.
    function createVault(bytes32 clientId) external returns (address vault) {
        if (msg.sender != state) revert UnauthorizedCaller();

        vault = template.cloneDeterministic(clientId);
        CFHelpersVaultTemplatev1_1(vault).initialize(clientId, state);

        emit VaultCreated(clientId, vault);
    }

    function predictVault(bytes32 clientId) external view returns (address) {
        return template.predictDeterministicAddress(clientId, address(this));
    }
}
