// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockVaultFactory {
    mapping(bytes32 => address) public vaultOf;  // clientId => vault

    /// @dev Records (or returns existing) a stand-in vault address for a client.
    function createVault(bytes32 clientId) external returns (address vault) {
        if (vaultOf[clientId] != address(0)) return vaultOf[clientId];

        vault = address(uint160(uint256(keccak256(abi.encodePacked("vault", clientId)))));
        vaultOf[clientId] = vault;
    }
}
