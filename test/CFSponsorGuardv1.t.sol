// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {CFHelpersGovv1} from "../contracts/CFHelpersGovv1.sol";
import {CFSponsorGuardv1} from "../contracts/CFSponsorGuardv1.sol";
import {CFHelpersVaultFactoryv1} from "../contracts/CFHelpersVaultFactoryv1.sol";
import {
    MockRelayTarget,
    MockVaultImposter
} from "../contracts/MockRelayTarget.sol";

interface IVaultClientId {
    function clientId() external view returns (bytes32);
}

/// @dev The guard has no privilege of its own (§5): it is registered as
///      `helperContracts["sponsorGuard"]` and is never a Cofund admin. These
///      tests are about routing — which targets `relay` will reach — plus the
///      proof that reaching Gov buys an attacker nothing.
contract CFSponsorGuardv1Test is Test {
    CFHelpersStatev1 internal state;
    CFHelpersGovv1 internal gov;
    CFSponsorGuardv1 internal guard;
    CFHelpersVaultFactoryv1 internal factory;
    MockRelayTarget internal policiesTarget;

    address internal deployer = makeAddr("deployer");
    address internal sponsor = makeAddr("sponsor");
    address internal outsider = makeAddr("outsider");
    address internal attacker = makeAddr("attacker");
    address internal nobody = makeAddr("nobody");
    address internal usersEOA = makeAddr("usersEOA");
    address internal founder = makeAddr("founder");

    bytes32 internal constant CLIENT_ID = keccak256("client-one");
    /// @dev On no whitelist and in no ABI: the helper rule is about the target.
    bytes4 internal constant ARBITRARY_SELECTOR = 0xdeadbeef;

    address internal vault;

    event SponsorAdded(address indexed sponsor, address indexed by);
    event SponsorRemoved(address indexed sponsor, address indexed by);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event DirectCallRelayed(
        address indexed sponsor,
        address indexed target,
        bytes4 indexed selector
    );

    function setUp() public {
        state = new CFHelpersStatev1(deployer);
        gov = new CFHelpersGovv1(address(state));
        guard = new CFSponsorGuardv1(address(state));
        factory = new CFHelpersVaultFactoryv1(address(state));
        policiesTarget = new MockRelayTarget();

        vm.prank(deployer);
        state.setGovHelperContract(address(gov));

        vm.startPrank(deployer);
        gov.setHelperContract("vaults", address(factory));
        gov.setHelperContract("sponsorGuard", address(guard));
        gov.setHelperContract("users", usersEOA);
        gov.setHelperContract("policies", address(policiesTarget));
        gov.addSponsor(sponsor);
        vm.stopPrank();

        // A real client, and therefore a real vault, created by the users
        // helper. The founder is an active admin straight away -- there is no
        // invite to complete.
        vm.prank(usersEOA);
        state.newClient(CLIENT_ID, "admin", founder, "FREE");
        (vault, ) = state.clientVaults(CLIENT_ID);
        assertTrue(vault != address(0), "fixture: no vault");
        assertEq(state.getActiveAdmins(CLIENT_ID), 1, "fixture: founder not an active admin");
        assertEq(state.getUserIdByAddress(founder, CLIENT_ID), "admin", "fixture: founder unindexed");
    }

    /// @dev Relay without reverting the test, so a case can inspect the
    ///      revert data instead of only matching a selector.
    function _relay(address target, bytes memory data)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(sponsor);
        (ok, ret) = address(guard).call(
            abi.encodeCall(CFSponsorGuardv1.relay, (target, data))
        );
    }

    // ───────────────────────────── deployment ─────────────────────────────

    function test_Deployment() public view {
        assertEq(address(guard.state()), address(state));
        assertEq(guard.authorizedSponsorCount(), 1);
        assertFalse(guard.paused());
        assertTrue(guard.isAuthorizedSponsor(sponsor));
    }

    function test_Deployment_RevertsOnZeroState() public {
        vm.expectRevert(CFSponsorGuardv1.InvalidAddress.selector);
        new CFSponsorGuardv1(address(0));
    }

    /// @dev The whole point of round 2: registration is the role.
    function test_Deployment_GuardHoldsNoAdminBit() public view {
        assertFalse(state.isCofundAdmin(address(guard)));
        assertEq(state.helperContracts("sponsorGuard"), address(guard));
    }

    // ─────────────────────── management is gated to gov ───────────────────

    function test_Management_DirectCallsAreGovOnly() public {
        vm.startPrank(deployer);
        vm.expectRevert(CFSponsorGuardv1.UnauthorizedCaller.selector);
        guard.addSponsor(outsider);

        vm.expectRevert(CFSponsorGuardv1.UnauthorizedCaller.selector);
        guard.removeSponsor(sponsor);

        vm.expectRevert(CFSponsorGuardv1.UnauthorizedCaller.selector);
        guard.pause();

        vm.expectRevert(CFSponsorGuardv1.UnauthorizedCaller.selector);
        guard.unpause();
        vm.stopPrank();
    }

    function test_Management_SponsorLifecycleThroughGov() public {
        vm.expectEmit(true, true, false, true, address(guard));
        emit SponsorAdded(outsider, address(gov));
        vm.prank(deployer);
        gov.addSponsor(outsider);
        assertEq(guard.authorizedSponsorCount(), 2);

        vm.expectEmit(true, true, false, true, address(guard));
        emit SponsorRemoved(outsider, address(gov));
        vm.prank(deployer);
        gov.removeSponsor(outsider);
        assertEq(guard.authorizedSponsorCount(), 1);
    }

    function test_Management_PauseUnpauseThroughGov() public {
        vm.expectEmit(true, false, false, true, address(guard));
        emit Paused(address(gov));
        vm.prank(deployer);
        gov.pauseSponsorGuard();
        assertTrue(guard.paused());

        vm.expectEmit(true, false, false, true, address(guard));
        emit Unpaused(address(gov));
        vm.prank(deployer);
        gov.unpauseSponsorGuard();
        assertFalse(guard.paused());
    }

    // ──────────────────────── relay: allowed targets ──────────────────────

    function test_Relay_ToPoliciesHelperForwardsCalldataVerbatim() public {
        bytes memory data = abi.encodeCall(MockRelayTarget.record, (42));

        vm.expectEmit(true, true, true, false, address(guard));
        emit DirectCallRelayed(sponsor, address(policiesTarget), MockRelayTarget.record.selector);
        vm.prank(sponsor);
        guard.relay(address(policiesTarget), data);

        assertEq(policiesTarget.lastData(), data);
        assertEq(policiesTarget.lastCaller(), address(guard));
        assertEq(policiesTarget.callCount(), 1);
    }

    function test_Relay_ToHelperAllowsAnySelector() public {
        // Not in the helper's ABI and on no list anywhere: the rule is the
        // target, because the helper authorizes itself from its own calldata.
        bytes memory data = abi.encodePacked(ARBITRARY_SELECTOR, bytes32(uint256(1)));

        vm.expectEmit(true, true, true, false, address(guard));
        emit DirectCallRelayed(sponsor, address(policiesTarget), ARBITRARY_SELECTOR);
        vm.prank(sponsor);
        guard.relay(address(policiesTarget), data);

        assertEq(policiesTarget.lastData(), data);
    }

    function test_Relay_ToUsersHelper() public {
        // setUp registers an EOA as the users helper, so re-point it at a
        // recorder to prove the users branch routes exactly like policies.
        MockRelayTarget usersTarget = new MockRelayTarget();
        vm.prank(deployer);
        gov.setHelperContract("users", address(usersTarget));

        bytes memory data = abi.encodeCall(MockRelayTarget.record, (7));
        vm.prank(sponsor);
        guard.relay(address(usersTarget), data);

        assertEq(usersTarget.lastData(), data);
        assertEq(usersTarget.lastCaller(), address(guard));
    }

    function test_Relay_FollowsHelperReregistration() public {
        MockRelayTarget replacement = new MockRelayTarget();
        vm.prank(deployer);
        gov.setHelperContract("policies", address(replacement));

        bytes memory data = abi.encodeCall(MockRelayTarget.record, (1));

        vm.prank(sponsor);
        guard.relay(address(replacement), data);
        assertEq(replacement.callCount(), 1);

        // The retired helper is just another contract now.
        vm.expectRevert(CFSponsorGuardv1.CallNotAllowed.selector);
        vm.prank(sponsor);
        guard.relay(address(policiesTarget), data);

        assertEq(policiesTarget.callCount(), 0, "retired helper must not be reached");
    }

    function test_Relay_BubblesHelperRevertVerbatim() public {
        vm.expectRevert(abi.encodeWithSelector(MockRelayTarget.Boom.selector, uint256(99)));
        vm.prank(sponsor);
        guard.relay(address(policiesTarget), abi.encodeCall(MockRelayTarget.boom, (99)));
    }

    function test_Relay_ToKnownVault() public {
        bytes memory data = abi.encodeCall(IVaultClientId.clientId, ());

        vm.prank(sponsor);
        bytes memory ret = guard.relay(vault, data);

        assertEq(abi.decode(ret, (bytes32)), CLIENT_ID, "return value must pass through");
    }

    /// @dev Garbage calldata still reaches the vault: routing is the guard's
    ///      only job, and the vault rejects what it does not implement.
    function test_Relay_ToKnownVaultWithGarbageReachesTheVault() public {
        (bool ok, bytes memory ret) = _relay(vault, abi.encodePacked(ARBITRARY_SELECTOR));

        assertFalse(ok, "vault has no fallback, so it must reject this");
        assertTrue(
            ret.length == 0 || bytes4(ret) != CFSponsorGuardv1.CallNotAllowed.selector,
            "must be the vault's rejection, not the guard's"
        );
    }

    // ──────────────────────── relay: refused targets ──────────────────────

    /// @dev §1: every State write goes through gov or a helper.
    function test_Relay_ToStateIsRefused() public {
        vm.expectRevert(CFSponsorGuardv1.CallNotAllowed.selector);
        vm.prank(sponsor);
        guard.relay(
            address(state),
            abi.encodeCall(CFHelpersStatev1.setSupportedType, ("danger"))
        );
    }

    function test_Relay_ToGovIsRefused() public {
        vm.expectRevert(CFSponsorGuardv1.CallNotAllowed.selector);
        vm.prank(sponsor);
        guard.relay(
            address(gov),
            abi.encodeCall(CFHelpersGovv1.addCofundAdmin, (attacker))
        );
    }

    function test_Relay_ToUnregisteredAddressIsRefused() public {
        vm.expectRevert(CFSponsorGuardv1.CallNotAllowed.selector);
        vm.prank(sponsor);
        guard.relay(nobody, abi.encodePacked(ARBITRARY_SELECTOR));
    }

    function test_Relay_ToFactoryIsRefused() public {
        vm.expectRevert(CFSponsorGuardv1.CallNotAllowed.selector);
        vm.prank(sponsor);
        guard.relay(address(factory), abi.encodePacked(ARBITRARY_SELECTOR));
    }

    /// @dev `address(0)` must never match, including while a helper is unset:
    ///      without the explicit check it would equal `helperContracts("users")`
    ///      and a call to `address(0)` succeeds silently.
    function test_Relay_ZeroAddressNeverMatches() public {
        CFHelpersStatev1 bare = new CFHelpersStatev1(deployer);
        CFHelpersGovv1 bareGov = new CFHelpersGovv1(address(bare));
        CFSponsorGuardv1 bareGuard = new CFSponsorGuardv1(address(bare));

        vm.prank(deployer);
        bare.setGovHelperContract(address(bareGov));
        vm.startPrank(deployer);
        bareGov.setHelperContract("sponsorGuard", address(bareGuard));
        bareGov.addSponsor(sponsor);
        vm.stopPrank();

        assertEq(bare.helperContracts("users"), address(0));
        assertEq(bare.helperContracts("policies"), address(0));

        vm.expectRevert(CFSponsorGuardv1.CallNotAllowed.selector);
        vm.prank(sponsor);
        bareGuard.relay(address(0), abi.encodePacked(ARBITRARY_SELECTOR));
    }

    /// @dev State's `clientVaults` is the only vault registry: claiming a live
    ///      client's id is not enough, the registered address must be you.
    function test_Relay_ImposterClaimingALiveClientIsRefused() public {
        MockVaultImposter imposter = new MockVaultImposter(CLIENT_ID);
        assertTrue(address(imposter) != vault);

        vm.expectRevert(CFSponsorGuardv1.CallNotAllowed.selector);
        vm.prank(sponsor);
        guard.relay(address(imposter), abi.encodePacked(ARBITRARY_SELECTOR));
    }

    function test_Relay_ImposterClaimingAnUnknownClientIsRefused() public {
        MockVaultImposter imposter = new MockVaultImposter(keccak256("no-such-client"));

        vm.expectRevert(CFSponsorGuardv1.CallNotAllowed.selector);
        vm.prank(sponsor);
        guard.relay(address(imposter), abi.encodePacked(ARBITRARY_SELECTOR));
    }

    // ───────────────────────── relay: caller and pause ────────────────────

    function test_Relay_NonSponsorIsRefused() public {
        vm.expectRevert(CFSponsorGuardv1.UnauthorizedCaller.selector);
        vm.prank(outsider);
        guard.relay(address(policiesTarget), abi.encodeCall(MockRelayTarget.record, (1)));
    }

    function test_Relay_RevokedSponsorIsRefused() public {
        vm.prank(deployer);
        gov.removeSponsor(sponsor);

        vm.expectRevert(CFSponsorGuardv1.UnauthorizedCaller.selector);
        vm.prank(sponsor);
        guard.relay(address(policiesTarget), abi.encodeCall(MockRelayTarget.record, (1)));
    }

    function test_Relay_PausedIsRefused() public {
        vm.prank(deployer);
        gov.pauseSponsorGuard();

        vm.expectRevert(CFSponsorGuardv1.GuardPaused.selector);
        vm.prank(sponsor);
        guard.relay(address(policiesTarget), abi.encodeCall(MockRelayTarget.record, (1)));

        vm.prank(deployer);
        gov.unpauseSponsorGuard();

        vm.prank(sponsor);
        guard.relay(address(policiesTarget), abi.encodeCall(MockRelayTarget.record, (1)));
        assertEq(policiesTarget.callCount(), 1);
    }

    function test_Relay_ShortCalldataIsRefused() public {
        vm.expectRevert(CFSponsorGuardv1.InvalidCall.selector);
        vm.prank(sponsor);
        guard.relay(address(policiesTarget), hex"112233");
    }

    /// @dev Pause and the sponsor allowlist are checked before the target, so
    ///      a paused guard says so even for a target it would never allow.
    function test_Relay_PauseOutranksTargetCheck() public {
        vm.prank(deployer);
        gov.pauseSponsorGuard();

        vm.expectRevert(CFSponsorGuardv1.GuardPaused.selector);
        vm.prank(sponsor);
        guard.relay(address(gov), abi.encodeCall(CFHelpersGovv1.addCofundAdmin, (attacker)));
    }

    // ───────────────── the guard cannot escalate, by construction ──────────

    /// @dev Worst case: gov itself is registered as the users helper, so the
    ///      guard will happily route to it. It still buys nothing, because the
    ///      guard holds no admin bit for Gov's `onlyCofundAdmin` to accept.
    function test_Escalation_MisregisteredGovAsUsersHelperBuysNothing() public {
        vm.prank(deployer);
        gov.setHelperContract("users", address(gov));

        // Sponsor is authorized and the guard is unpaused, and gov is now a
        // helper target, so the only revert left to hit is Gov's own.
        vm.expectRevert(CFHelpersGovv1.UnauthorizedCaller.selector);
        vm.prank(sponsor);
        guard.relay(address(gov), abi.encodeCall(CFHelpersGovv1.addCofundAdmin, (attacker)));

        assertFalse(state.isCofundAdmin(attacker));
        assertFalse(state.isCofundAdmin(address(guard)));
        assertEq(state.cofundAdminCount(), 1);
    }

    /// @dev And the same call from a sponsor directly is refused too, so there
    ///      is no path from a leaked sponsor key to the admin set.
    function test_Escalation_SponsorCannotReachGovDirectly() public {
        vm.expectRevert(CFHelpersGovv1.UnauthorizedCaller.selector);
        vm.prank(sponsor);
        gov.addCofundAdmin(attacker);

        assertFalse(state.isCofundAdmin(attacker));
    }
}
