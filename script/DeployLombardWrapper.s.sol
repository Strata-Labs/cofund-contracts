// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LombardWrapper} from "../contracts/LombardWrapper.sol";

/// @title  DeployLombardWrapper -- the LBTC -> BTC exit wrapper, on one chain.
///
/// @notice One input, `LBTC`: the chain's LBTC token. The wrapper has no owner
///         and no setter, so this is the whole deployment.
///
///         | chain    | LBTC                                         |
///         |----------|----------------------------------------------|
///         | Ethereum | `0x8236a87084f8B84306f72007F36F2618A5634494` |
///         | Sepolia  | `0x107Fc7d90484534704dD2A9e24c7BD45DB4dD1B5` |
///
///         Usage (dry run; add `--broadcast` and a signer to send):
///
///             LBTC=0x8236a87084f8B84306f72007F36F2618A5634494 \
///             forge script script/DeployLombardWrapper.s.sol:DeployLombardWrapper \
///               --rpc-url ethereum
contract DeployLombardWrapper is Script {
    function run() external returns (LombardWrapper wrapper) {
        // Read and checked before the broadcast, so a wrong address deploys nothing.
        address lbtc = vm.envAddress("LBTC");
        require(lbtc.code.length != 0, "LBTC has no code on this chain");

        vm.startBroadcast();
        wrapper = deploy(lbtc);
        vm.stopBroadcast();

        console2.log("");
        console2.log("=== LombardWrapper deployed ===");
        console2.log("  chainId        ", block.chainid);
        console2.log("  LBTC           ", lbtc);
        console2.log("  LombardWrapper ", address(wrapper));
    }

    function deploy(address lbtc) public returns (LombardWrapper) {
        return new LombardWrapper(lbtc);
    }
}
