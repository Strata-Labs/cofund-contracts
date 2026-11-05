// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {CFHelpersGovv1} from "../contracts/CFHelpersGovv1.sol";
import {CFSponsorGuardv1} from "../contracts/CFSponsorGuardv1.sol";
import {CFHelpersVaultFactoryv1} from "../contracts/CFHelpersVaultFactoryv1.sol";
import {MockAdminCaller, MockRelayTarget} from "../contracts/MockRelayTarget.sol";

/// @dev Gov is called straight from a Ledger, so `deployer` and the other
///      admins are EOAs and every gov call is pranked from one. The one
///      deliberate exception is the contract-caller section.
contract CFHelpersGovv1Test is Test {
    CFHelpersStatev1 internal state;
    CFHelpersGovv1 internal gov;
    CFSponsorGuardv1 internal guard;
    CFHelpersVaultFactoryv1 internal factory;
    MockRelayTarget internal policiesTarget;

    address internal deployer = makeAddr("deployer");
    address internal admin1 = makeAddr("admin1");
    address internal admin2 = makeAddr("admin2");
    address internal admin3 = makeAddr("admin3");
    address internal nonAdmin = makeAddr("nonAdmin");
    address internal sponsor = makeAddr("sponsor");
    address internal usersEOA = makeAddr("usersEOA");

    // Mirrors of the events under test, so vm.expectEmit has something to match.
    event CofundAdminAdded(address indexed newAdmin, address indexed addedBy);
    event CofundAdminRemoved(address indexed admin, address indexed removedBy);
    event CofundAdminRotated(address indexed oldAdmin, address indexed newAdmin);
    event HelperContractSet(
        string contractType,
        address indexed contractAddress,
        address indexed setBy
    );
    event SponsorAdded(address indexed sponsor, address indexed by);
    event SponsorRemoved(address indexed sponsor, address indexed by);
    event SponsorGuardPaused(address indexed by);
    event SponsorGuardUnpaused(address indexed by);

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
    }

    // ───────────────────────────── deployment ─────────────────────────────

    function test_Deployment_StateReference() public view {
        assertEq(address(gov.stateContract()), address(state));
    }

    function test_Deployment_AdminCountStartsAtOne() public view {
        assertEq(state.cofundAdminCount(), 1);
        assertEq(gov.adminCount(), 1);
    }

    function test_Deployment_DeployerIsInitialAdmin() public view {
        assertTrue(state.isCofundAdmin(deployer));
        assertTrue(gov.isAdmin(deployer));
        assertFalse(gov.isAdmin(nonAdmin));
    }

    /// @dev §5: the guard's role is its registration, never an admin bit.
    function test_Deployment_GuardIsNotACofundAdmin() public view {
        assertFalse(state.isCofundAdmin(address(guard)));
        assertEq(state.helperContracts("sponsorGuard"), address(guard));
    }

    // ──────────────────────────── addCofundAdmin ───────────────────────────

    function test_AddCofundAdmin() public {
        vm.prank(deployer);
        gov.addCofundAdmin(admin1);

        assertTrue(state.isCofundAdmin(admin1));
        assertEq(gov.adminCount(), 2);
    }

    function test_AddCofundAdmin_EmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(gov));
        emit CofundAdminAdded(admin1, deployer);

        vm.prank(deployer);
        gov.addCofundAdmin(admin1);
    }

    function test_AddCofundAdmin_RevertsForNonAdmin() public {
        vm.expectRevert(CFHelpersGovv1.UnauthorizedCaller.selector);
        vm.prank(nonAdmin);
        gov.addCofundAdmin(admin1);
    }

    function test_AddCofundAdmin_RevertsOnZeroAddress() public {
        vm.expectRevert(CFHelpersGovv1.InvalidAddress.selector);
        vm.prank(deployer);
        gov.addCofundAdmin(address(0));
    }

    function test_AddCofundAdmin_RevertsOnExistingAdmin() public {
        vm.startPrank(deployer);
        gov.addCofundAdmin(admin1);
        vm.expectRevert(CFHelpersGovv1.AdminExists.selector);
        gov.addCofundAdmin(admin1);
        vm.stopPrank();
    }

    function test_AddCofundAdmin_AllowsSeveral() public {
        vm.startPrank(deployer);
        gov.addCofundAdmin(admin1);
        gov.addCofundAdmin(admin2);
        gov.addCofundAdmin(admin3);
        vm.stopPrank();

        assertEq(gov.adminCount(), 4);
        assertTrue(gov.isAdmin(admin1));
        assertTrue(gov.isAdmin(admin2));
        assertTrue(gov.isAdmin(admin3));
    }

    function test_AddCofundAdmin_NewAdminCanAddOthers() public {
        vm.prank(deployer);
        gov.addCofundAdmin(admin1);

        vm.expectEmit(true, true, false, true, address(gov));
        emit CofundAdminAdded(admin2, admin1);
        vm.prank(admin1);
        gov.addCofundAdmin(admin2);

        assertTrue(gov.isAdmin(admin2));
    }

    // ─────────────────────────── removeCofundAdmin ─────────────────────────

    function test_RemoveCofundAdmin() public {
        vm.startPrank(deployer);
        gov.addCofundAdmin(admin1);
        assertEq(gov.adminCount(), 2);

        vm.expectEmit(true, true, false, true, address(gov));
        emit CofundAdminRemoved(admin1, deployer);
        gov.removeCofundAdmin(admin1);
        vm.stopPrank();

        assertFalse(gov.isAdmin(admin1));
        assertEq(gov.adminCount(), 1);
    }

    function test_RemoveCofundAdmin_RevertsForNonAdmin() public {
        vm.prank(deployer);
        gov.addCofundAdmin(admin1);

        vm.expectRevert(CFHelpersGovv1.UnauthorizedCaller.selector);
        vm.prank(nonAdmin);
        gov.removeCofundAdmin(admin1);
    }

    function test_RemoveCofundAdmin_RevertsOnSelfRemoval() public {
        vm.expectRevert(CFHelpersGovv1.SelfRemoval.selector);
        vm.prank(deployer);
        gov.removeCofundAdmin(deployer);
    }

    function test_RemoveCofundAdmin_RevertsOnNonAdminTarget() public {
        vm.expectRevert(CFHelpersGovv1.NotAdmin.selector);
        vm.prank(deployer);
        gov.removeCofundAdmin(nonAdmin);
    }

    /// @dev The sole admin cannot be removed: SelfRemoval catches the only
    ///      caller who could try, which is why `LastAdmin` needs the test below.
    function test_RemoveCofundAdmin_SoleAdminIsProtected() public {
        vm.startPrank(deployer);
        gov.addCofundAdmin(admin2);
        vm.stopPrank();

        vm.prank(admin2);
        gov.removeCofundAdmin(deployer);
        assertEq(gov.adminCount(), 1);

        vm.expectRevert(CFHelpersGovv1.SelfRemoval.selector);
        vm.prank(admin2);
        gov.removeCofundAdmin(admin2);
    }

    /// @dev `LastAdmin` is defence in depth: NotAdmin and SelfRemoval shadow it
    ///      in every reachable state, so the count has to be forced to expose it.
    function test_RemoveCofundAdmin_LastAdminGuard() public {
        vm.prank(deployer);
        gov.addCofundAdmin(admin1);

        uint256 countSlot = 2; // CFHelpersStatev1.cofundAdminCount
        vm.store(address(state), bytes32(countSlot), bytes32(uint256(1)));
        assertEq(state.cofundAdminCount(), 1, "cofundAdminCount slot moved");

        vm.expectRevert(CFHelpersGovv1.LastAdmin.selector);
        vm.prank(deployer);
        gov.removeCofundAdmin(admin1);
    }

    function test_RemoveCofundAdmin_RemovedAdminLosesAccess() public {
        vm.startPrank(deployer);
        gov.addCofundAdmin(admin1);
        gov.removeCofundAdmin(admin1);
        vm.stopPrank();

        vm.expectRevert(CFHelpersGovv1.UnauthorizedCaller.selector);
        vm.prank(admin1);
        gov.addCofundAdmin(admin2);
    }

    function test_RemoveCofundAdmin_AdminsCanRemoveEachOther() public {
        vm.startPrank(deployer);
        gov.addCofundAdmin(admin1);
        gov.addCofundAdmin(admin2);
        vm.stopPrank();

        vm.expectEmit(true, true, false, true, address(gov));
        emit CofundAdminRemoved(admin2, admin1);
        vm.prank(admin1);
        gov.removeCofundAdmin(admin2);

        assertFalse(gov.isAdmin(admin2));
    }

    function test_RemoveCofundAdmin_ReAddWorks() public {
        vm.startPrank(deployer);
        gov.addCofundAdmin(admin1);
        gov.removeCofundAdmin(admin1);
        assertFalse(gov.isAdmin(admin1));
        gov.addCofundAdmin(admin1);
        vm.stopPrank();

        assertTrue(gov.isAdmin(admin1));
    }

    // ─────────────────────────── rotateCofundAdmin ─────────────────────────

    function test_RotateCofundAdmin() public {
        vm.expectEmit(true, true, false, true, address(gov));
        emit CofundAdminRotated(deployer, admin1);
        vm.prank(deployer);
        gov.rotateCofundAdmin(admin1);

        assertFalse(gov.isAdmin(deployer));
        assertTrue(gov.isAdmin(admin1));
        assertEq(gov.adminCount(), 1, "rotation must not change the count");
    }

    function test_RotateCofundAdmin_OldKeyLosesAccessNewKeyGains() public {
        vm.prank(deployer);
        gov.rotateCofundAdmin(admin1);

        vm.expectRevert(CFHelpersGovv1.UnauthorizedCaller.selector);
        vm.prank(deployer);
        gov.addCofundAdmin(admin2);

        vm.prank(admin1);
        gov.addCofundAdmin(admin2);
        assertTrue(gov.isAdmin(admin2));
    }

    function test_RotateCofundAdmin_RevertsForNonAdmin() public {
        vm.expectRevert(CFHelpersGovv1.UnauthorizedCaller.selector);
        vm.prank(nonAdmin);
        gov.rotateCofundAdmin(admin1);
    }

    function test_RotateCofundAdmin_RevertsOnExistingAdmin() public {
        vm.startPrank(deployer);
        gov.addCofundAdmin(admin1);
        vm.expectRevert(CFHelpersGovv1.AdminExists.selector);
        gov.rotateCofundAdmin(admin1);
        vm.stopPrank();
    }

    function test_RotateCofundAdmin_RevertsOnZeroAddress() public {
        vm.expectRevert(CFHelpersGovv1.InvalidAddress.selector);
        vm.prank(deployer);
        gov.rotateCofundAdmin(address(0));
    }

    function test_RotateCofundAdmin_Chains() public {
        vm.prank(deployer);
        gov.rotateCofundAdmin(admin1);
        vm.prank(admin1);
        gov.rotateCofundAdmin(admin2);
        vm.prank(admin2);
        gov.rotateCofundAdmin(admin3);

        assertTrue(gov.isAdmin(admin3));
        assertFalse(gov.isAdmin(admin1));
        assertFalse(gov.isAdmin(admin2));
        assertFalse(gov.isAdmin(deployer));
        assertEq(gov.adminCount(), 1);
    }

    function test_RotateCofundAdmin_RotatesBack() public {
        vm.prank(deployer);
        gov.rotateCofundAdmin(admin1);
        vm.prank(admin1);
        gov.rotateCofundAdmin(deployer);

        assertTrue(gov.isAdmin(deployer));
        assertFalse(gov.isAdmin(admin1));
    }

    /// @dev Rotation is the sole admin's only exit; removal is not.
    function test_RotateCofundAdmin_SoleAdminMayRotate() public {
        assertEq(gov.adminCount(), 1);
        vm.prank(deployer);
        gov.rotateCofundAdmin(admin1);

        assertEq(gov.adminCount(), 1);
        assertTrue(gov.isAdmin(admin1));
    }

    // ──────────────── contract callers (the _enforceEOA removal) ───────────

    /// @dev A contract account stands in for an admin EOA carrying an EIP-7702
    ///      delegation: all Gov sees is that msg.sender has code, which is
    ///      exactly what v0's `_enforceEOA` rejected.
    function test_ContractCaller_AdminCanRunAdminOperation() public {
        MockAdminCaller caller = new MockAdminCaller();

        vm.prank(deployer);
        gov.addCofundAdmin(address(caller));
        assertTrue(gov.isAdmin(address(caller)));

        vm.expectEmit(true, true, false, true, address(gov));
        emit CofundAdminAdded(admin1, address(caller));
        caller.forward(address(gov), abi.encodeCall(CFHelpersGovv1.addCofundAdmin, (admin1)));

        assertTrue(gov.isAdmin(admin1));
        assertEq(gov.adminCount(), 3);
    }

    function test_ContractCaller_NonAdminStillRejected() public {
        MockAdminCaller caller = new MockAdminCaller();

        // The only gate left is isCofundAdmin; having code neither helps nor hurts.
        vm.expectRevert(CFHelpersGovv1.UnauthorizedCaller.selector);
        caller.forward(address(gov), abi.encodeCall(CFHelpersGovv1.addCofundAdmin, (admin1)));
    }

    function test_ContractCaller_CanSetHelpersAndRotateItselfOut() public {
        MockAdminCaller caller = new MockAdminCaller();

        vm.prank(deployer);
        gov.addCofundAdmin(address(caller));

        caller.forward(
            address(gov),
            abi.encodeCall(CFHelpersGovv1.setHelperContract, ("policies", admin2))
        );
        assertEq(state.helperContracts("policies"), admin2);

        caller.forward(
            address(gov),
            abi.encodeCall(CFHelpersGovv1.rotateCofundAdmin, (admin3))
        );
        assertFalse(gov.isAdmin(address(caller)));
        assertTrue(gov.isAdmin(admin3));
    }

    // ───────────────────────── state contract integration ──────────────────

    function test_State_AdminWritesAreGovOnly() public {
        vm.startPrank(deployer);
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.setCofundAdmin(admin1, true);

        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.incrementCofundAdminCount();

        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.decrementCofundAdminCount();
        vm.stopPrank();
    }

    function test_State_AdminCountGettersAgree() public {
        assertEq(state.getCofundAdminCount(), state.cofundAdminCount());

        vm.prank(deployer);
        gov.addCofundAdmin(admin1);
        assertEq(state.getCofundAdminCount(), 2);
        assertEq(state.cofundAdminCount(), 2);
    }

    // ──────────────────────────── setHelperContract ────────────────────────

    function test_SetHelperContract() public {
        vm.expectEmit(true, true, false, true, address(gov));
        emit HelperContractSet("policies", admin1, deployer);
        vm.prank(deployer);
        gov.setHelperContract("policies", admin1);

        assertEq(state.helperContracts("policies"), admin1);
    }

    function test_SetHelperContract_RevertsForNonAdmin() public {
        vm.expectRevert(CFHelpersGovv1.UnauthorizedCaller.selector);
        vm.prank(nonAdmin);
        gov.setHelperContract("policies", admin1);
    }

    function test_SetHelperContract_RevertsOnZeroAddress() public {
        vm.expectRevert(CFHelpersGovv1.InvalidAddress.selector);
        vm.prank(deployer);
        gov.setHelperContract("policies", address(0));
    }

    function test_SetHelperContract_RevertsOnEmptyType() public {
        vm.expectRevert(CFHelpersGovv1.InvalidType.selector);
        vm.prank(deployer);
        gov.setHelperContract("", admin1);
    }

    function test_SetHelperContract_Updates() public {
        vm.startPrank(deployer);
        gov.setHelperContract("vaults", admin1);
        assertEq(state.helperContracts("vaults"), admin1);
        gov.setHelperContract("vaults", admin2);
        vm.stopPrank();

        assertEq(state.helperContracts("vaults"), admin2);
    }

    function test_State_SetHelperContractIsGovOnly() public {
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        vm.prank(deployer);
        state.setHelperContract("policies", admin1);
    }

    // ───────────────────── setGovHelperContract (bootstrap) ────────────────

    function test_Bootstrap_SetGovHelperContract() public {
        CFHelpersStatev1 fresh = new CFHelpersStatev1(deployer);
        assertEq(fresh.helperContracts("gov"), address(0));

        vm.prank(deployer);
        fresh.setGovHelperContract(address(gov));
        assertEq(fresh.helperContracts("gov"), address(gov));
    }

    function test_Bootstrap_RevertsForNonAdmin() public {
        CFHelpersStatev1 fresh = new CFHelpersStatev1(deployer);

        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        vm.prank(nonAdmin);
        fresh.setGovHelperContract(address(gov));
    }

    function test_Bootstrap_RevertsOnZeroAddress() public {
        CFHelpersStatev1 fresh = new CFHelpersStatev1(deployer);

        vm.expectRevert(CFHelpersStatev1.InvalidAddress.selector);
        vm.prank(deployer);
        fresh.setGovHelperContract(address(0));
    }

    function test_Bootstrap_IsOnceOnly() public {
        CFHelpersStatev1 fresh = new CFHelpersStatev1(deployer);

        vm.startPrank(deployer);
        fresh.setGovHelperContract(address(gov));
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        fresh.setGovHelperContract(admin2);
        vm.stopPrank();
    }

    function test_Bootstrap_GovCanReplaceItself() public {
        CFHelpersStatev1 fresh = new CFHelpersStatev1(deployer);
        CFHelpersGovv1 firstGov = new CFHelpersGovv1(address(fresh));
        CFHelpersGovv1 secondGov = new CFHelpersGovv1(address(fresh));

        vm.prank(deployer);
        fresh.setGovHelperContract(address(firstGov));

        vm.prank(deployer);
        firstGov.setHelperContract("gov", address(secondGov));
        assertEq(fresh.helperContracts("gov"), address(secondGov));

        // The retired gov no longer passes state's onlyGov ...
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        vm.prank(deployer);
        firstGov.setHelperContract("policies", admin1);

        // ... and the new one does.
        vm.prank(deployer);
        secondGov.setHelperContract("policies", admin1);
        assertEq(fresh.helperContracts("policies"), admin1);
    }

    // ───────────────────────── sponsor guard management ────────────────────

    function test_Sponsor_AddThroughGov() public {
        vm.expectEmit(true, true, false, true, address(gov));
        emit SponsorAdded(admin1, deployer);
        vm.prank(deployer);
        gov.addSponsor(admin1);

        assertTrue(guard.isAuthorizedSponsor(admin1));
        assertEq(guard.authorizedSponsorCount(), 2); // `sponsor` was added in setUp
    }

    function test_Sponsor_RemoveThroughGov() public {
        vm.expectEmit(true, true, false, true, address(gov));
        emit SponsorRemoved(sponsor, deployer);
        vm.prank(deployer);
        gov.removeSponsor(sponsor);

        assertFalse(guard.isAuthorizedSponsor(sponsor));
        assertEq(guard.authorizedSponsorCount(), 0);
    }

    function test_Sponsor_RejectsZeroAddressAndDuplicates() public {
        vm.startPrank(deployer);
        vm.expectRevert(CFSponsorGuardv1.InvalidAddress.selector);
        gov.addSponsor(address(0));

        vm.expectRevert(CFSponsorGuardv1.AlreadySponsor.selector);
        gov.addSponsor(sponsor);

        vm.expectRevert(CFSponsorGuardv1.NotASponsor.selector);
        gov.removeSponsor(admin1);
        vm.stopPrank();
    }

    function test_Sponsor_RejectsNonAdminCaller() public {
        vm.expectRevert(CFHelpersGovv1.UnauthorizedCaller.selector);
        vm.prank(nonAdmin);
        gov.addSponsor(admin1);

        vm.expectRevert(CFHelpersGovv1.UnauthorizedCaller.selector);
        vm.prank(nonAdmin);
        gov.pauseSponsorGuard();
    }

    function test_Sponsor_PauseAndUnpauseThroughGov() public {
        vm.expectEmit(true, false, false, true, address(gov));
        emit SponsorGuardPaused(deployer);
        vm.prank(deployer);
        gov.pauseSponsorGuard();
        assertTrue(guard.paused());

        vm.expectEmit(true, false, false, true, address(gov));
        emit SponsorGuardUnpaused(deployer);
        vm.prank(deployer);
        gov.unpauseSponsorGuard();
        assertFalse(guard.paused());
    }

    function test_Sponsor_RevertsWhenGuardUnregistered() public {
        CFHelpersStatev1 fresh = new CFHelpersStatev1(deployer);
        CFHelpersGovv1 freshGov = new CFHelpersGovv1(address(fresh));

        vm.prank(deployer);
        fresh.setGovHelperContract(address(freshGov));

        vm.expectRevert(CFHelpersGovv1.SponsorGuardNotSet.selector);
        vm.prank(deployer);
        freshGov.addSponsor(sponsor);
    }
}
