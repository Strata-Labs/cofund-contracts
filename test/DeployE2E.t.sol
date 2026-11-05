// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";

import {DeployE2E} from "../script/DeployE2E.s.sol";

import {RelayWrapper} from "../contracts/RelayWrapper.sol";
import {MockLBTC} from "../contracts/MockLBTC.sol";
import {LombardWrapper} from "../contracts/LombardWrapper.sol";
import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {CFHelpersVaultFactoryv1_1} from "../contracts/CFHelpersVaultFactoryv1_1.sol";

/// @notice Calls `deployAll` from the broadcaster, as `RunCaller` does for
///         `DeployCore.run` (see `test/DeployCore.t.sol` for why).
contract DeployAllCaller {
    function go(DeployE2E script) external {
        script.deployAll();
    }
}

/// @title DeployE2ETest -- the e2e chain's late additions: RelayWrapper, Lombard, v1.1 vaults, then Base.
contract DeployE2ETest is Test {
    /// @dev The webapp's liquidity-monitor refills bind their policies to the
    ///      RelayWrapper. It must be RelayWrapper itself, deployed once, and be
    ///      followed only by the Lombard pair, the v1.1 vault factories and
    ///      the Base core: every address `.env.e2e` bakes in is a function of
    ///      the deployer's nonce, so nothing may land before them.
    function test_deployAll_deploysTheRelayWrapperThenLombardThenV1_1VaultsThenBase() public {
        DeployE2E script = new DeployE2E();
        vm.etch(DEFAULT_SENDER, address(new DeployAllCaller()).code);

        vm.startStateDiffRecording();
        DeployAllCaller(DEFAULT_SENDER).go(script);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        address[] memory creates = new address[](accesses.length);
        uint256 n;
        for (uint256 i = 0; i < accesses.length; i++) {
            if (accesses[i].kind == VmSafe.AccountAccessKind.Create) creates[n++] = accesses[i].account;
        }

        bytes32 relayCode = keccak256(type(RelayWrapper).runtimeCode);
        uint256 wrappers;
        for (uint256 i = 0; i < n; i++) {
            if (keccak256(creates[i].code) == relayCode) wrappers++;
        }
        assertEq(wrappers, 1, "exactly one RelayWrapper");
        // The Base core (six contracts and the v1 template), then its v1.1
        // factory and template, close the run; the two other v1.1 factories
        // and their templates come just before it.
        uint256 base = n - 9;
        uint256 last = base - 4;
        assertEq(keccak256(creates[last - 3].code), relayCode, "RelayWrapper is third before the v1.1 vaults");

        // Then the Lombard pair: the mock, then the wrapper bound to it.
        MockLBTC lbtc = MockLBTC(creates[last - 2]);
        LombardWrapper wrapper = LombardWrapper(creates[last - 1]);
        assertEq(wrapper.lbtc(), address(lbtc), "wrapper bound to the mock");
        assertEq(lbtc.notary(), vm.addr(uint256(keccak256("cofund.e2e.lombard.notary"))), "published notary key");
        assertEq(lbtc.decimals(), 8);

        // Each v1.1 factory, then the template it deploys, registered as
        // "vaults" on its own State.
        address ethState = CFHelpersVaultFactoryv1_1(creates[last]).state();
        address rhState = CFHelpersVaultFactoryv1_1(creates[last + 2]).state();
        assertTrue(ethState != rhState, "one factory per State");
        for (uint256 i = last; i < base; i += 2) {
            CFHelpersVaultFactoryv1_1 factory = CFHelpersVaultFactoryv1_1(creates[i]);
            assertEq(factory.template(), creates[i + 1], "template follows its factory");
            assertEq(CFHelpersStatev1(factory.state()).helperContracts("vaults"), address(factory), "registered");
        }

        // Base: a third State, wired like the others, with its own v1.1
        // factory registered as "vaults".
        CFHelpersStatev1 baseState = CFHelpersStatev1(creates[base]);
        assertTrue(address(baseState) != ethState && address(baseState) != rhState, "a third State");
        assertEq(baseState.helperContracts("gov"), creates[base + 1], "gov follows State");
        assertTrue(baseState.helperContracts("sponsorGuard") != address(0), "guard registered");
        CFHelpersVaultFactoryv1_1 baseVaults = CFHelpersVaultFactoryv1_1(creates[n - 2]);
        assertEq(baseVaults.state(), address(baseState), "Base factory on Base State");
        assertEq(baseVaults.template(), creates[n - 1], "template follows its factory");
        assertEq(baseState.helperContracts("vaults"), address(baseVaults), "registered");
    }
}
