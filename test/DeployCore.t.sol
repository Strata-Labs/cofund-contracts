// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployCore} from "../script/DeployCore.s.sol";

import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";

/// @notice Calls `run` so that `run`'s `msg.sender` is the broadcaster.
/// @dev    Etched onto `DEFAULT_SENDER` by the suite below; see its notes.
contract RunCaller {
    function go(DeployCore script) external returns (DeployCore.Core memory) {
        return script.run();
    }
}

/// @title  DeployCoreTest -- the script's inputs, through `run` itself.
///
/// @notice `test/Relaunch.t.sol` proves the *wiring* by inheriting the script
///         and calling `deploy` under a prank. What it cannot reach is `run`:
///         the environment reads, the broadcast, and the optional
///         `FEE_RECIPIENT` step that only the broadcasting path performs --
///         the one thing standing between a mainnet deploy and a protocol fee
///         paid to the Ledger that signed it. That is what this suite covers,
///         so a mistake there fails here rather than on chain.
///
/// @dev    Driving `run` from a test takes one trick, because the two ways of
///         choosing a sender do not compose:
///
///         - `run` takes its admin from `msg.sender`, and its calls go out
///           under `vm.startBroadcast()`, which in a test sends them as
///           `DEFAULT_SENDER`. The two must agree -- as they do under
///           `forge script --sender` -- or every wiring call is made by an
///           account that does not hold State's admin bit.
///         - `vm.prank` cannot bridge the gap: a prank stays active for the
///           duration of the call it applies to, so `startBroadcast` inside
///           `run` aborts with "you have an active prank".
///
///         So the call into `run` is made *by* `DEFAULT_SENDER`: `RunCaller`'s
///         runtime code is etched there and invoked. No prank is involved,
///         `msg.sender` inside `run` is `DEFAULT_SENDER`, and the broadcast
///         sends as that same account.
///
///         **Both environment cases live in one test function, deliberately.**
///         `vm.setEnv` writes the real process environment, and the test
///         functions of a suite share it; two functions that set
///         `FEE_RECIPIENT` differently both observe whichever write landed
///         last. Sequencing the two deployments inside a single function is
///         what makes each one read the value it set.
contract DeployCoreTest is Test {
    DeployCore internal script;

    address internal constant SPONSOR = address(0x5907505);
    address internal constant TREASURY = address(0x77EA5);

    function setUp() public {
        script = new DeployCore();
        vm.etch(DEFAULT_SENDER, address(new RunCaller()).code);
        vm.deal(DEFAULT_SENDER, 100 ether);
    }

    /// @dev `feeRecipient == address(0)` is the "FEE_RECIPIENT unset" case.
    ///      No cheatcode removes an environment variable -- an empty value
    ///      leaves the previous one in place -- but the zero address is not a
    ///      stand-in for absence here: `vm.envOr("FEE_RECIPIENT", address(0))`
    ///      is exactly what the script reads, an absent variable yields that
    ///      same zero, and the zero is what `setFeeRecipient` must read as
    ///      "leave State's seeding alone".
    function _run(address feeRecipient) private returns (CFHelpersStatev1) {
        vm.setEnv("SPONSOR", vm.toString(SPONSOR));
        vm.setEnv("FEE_RECIPIENT", vm.toString(feeRecipient));

        DeployCore.Core memory core = RunCaller(DEFAULT_SENDER).go(script);
        return CFHelpersStatev1(core.state);
    }

    function test_run_feeRecipientEnv() public {
        // ── set: the broadcaster's last act moves the fee off itself ──────
        CFHelpersStatev1 state = _run(TREASURY);

        assertEq(state.cfFeeRecipientAddress(), TREASURY, "fee recipient not taken from FEE_RECIPIENT");
        assertTrue(state.cfFeeRecipientAddress() != DEFAULT_SENDER, "the fee must not sit on the deploying admin");
        // The admin bit itself is untouched: the point is to separate the fee
        // from the key, not to hand the treasury any privilege.
        assertTrue(state.isCofundAdmin(DEFAULT_SENDER), "the broadcaster is still the Cofund admin");
        assertTrue(!state.isCofundAdmin(TREASURY), "the fee recipient must hold no privilege");

        // The rest of the deployment is indifferent to the extra step.
        assertTrue(state.helperContracts("sponsorGuard") != address(0), "guard not registered");
        assertTrue(state.helperContracts("users") != address(0), "users not registered");
        assertTrue(state.helperContracts("vaults") != address(0), "vault factory not registered");

        // ── unset: nothing extra is sent, State keeps its seeding ─────────
        CFHelpersStatev1 plain = _run(address(0));

        assertEq(plain.cfFeeRecipientAddress(), DEFAULT_SENDER, "unset FEE_RECIPIENT should leave the admin in place");
        assertTrue(address(plain) != address(state), "the second run should be its own deployment");
    }

    /// Called directly, the helper is the same no-op for the zero address.
    /// That guard is the whole reason "unset" means "leave it alone" rather
    /// than a revert: `setFeeRecipientAddress` rejects zero itself.
    function test_setFeeRecipient_zeroIsANoOp() public {
        address admin = address(this);
        CFHelpersStatev1 state = new CFHelpersStatev1(admin);

        script.setFeeRecipient(address(state), address(0));
        assertEq(state.cfFeeRecipientAddress(), admin, "zero should not have touched State");
    }

    /// And a non-zero recipient reverts for anyone but the Cofund admin, so a
    /// misconfigured deploy fails loudly rather than deploying half-owned.
    function test_setFeeRecipient_requiresTheAdmin() public {
        CFHelpersStatev1 state = new CFHelpersStatev1(address(0xA11CE));

        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        script.setFeeRecipient(address(state), TREASURY);
    }
}
