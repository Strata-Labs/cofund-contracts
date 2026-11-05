// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {CFHelpersVaultFactoryv1_1} from "../contracts/CFHelpersVaultFactoryv1_1.sol";

/// @title  DeployVaultV1_1 -- the v1.1 vault factory and its template, on one chain.
///
/// @notice One input, `STATE`: the chain's v1 State. The factory's constructor
///         deploys the template. The swap is a Gov call from the Cofund admin;
///         this script prints it and does not make it.
///
///         | chain     | State                                        |
///         |-----------|----------------------------------------------|
///         | Ethereum  | `0xD59eFC1803Fb72231Db0B6A872a9c22D8A0102C0` |
///         | Robinhood | `0xF3B43952BcC2560789be8076529df8F908cEf535` |
///
///         Usage (dry run; add `--broadcast` and a signer to send):
///
///             STATE=0xD59eFC1803Fb72231Db0B6A872a9c22D8A0102C0 \
///             forge script script/DeployVaultV1_1.s.sol:DeployVaultV1_1 \
///               --rpc-url ethereum
contract DeployVaultV1_1 is Script {
    function run() external returns (CFHelpersVaultFactoryv1_1 factory) {
        // Read and checked before the broadcast, so a wrong address deploys nothing.
        address state = vm.envAddress("STATE");
        require(state.code.length != 0, "STATE has no code on this chain");
        address gov = CFHelpersStatev1(state).helperContracts("gov");
        require(gov != address(0), "STATE has no gov");

        vm.startBroadcast();
        factory = deploy(state);
        vm.stopBroadcast();

        console2.log("");
        console2.log("=== v1.1 vault factory deployed ===");
        console2.log("  chainId                   ", block.chainid);
        console2.log("  State                     ", state);
        console2.log("  CFHelpersVaultFactoryv1_1 ", address(factory));
        console2.log("  CFHelpersVaultTemplatev1_1", factory.template());
        console2.log("  vaults (current)          ", CFHelpersStatev1(state).helperContracts("vaults"));
        console2.log("");
        console2.log("Follow-up, from the Cofund admin (not sent here):");
        console2.log(
            string.concat(
                "  cast send ", vm.toString(gov), ' "setHelperContract(string,address)" vaults ', vm.toString(address(factory))
            )
        );
    }

    function deploy(address state) public returns (CFHelpersVaultFactoryv1_1) {
        return new CFHelpersVaultFactoryv1_1(state);
    }
}
