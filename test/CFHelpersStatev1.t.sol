// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {MockVaultFactory} from "../contracts/MockVaultFactory.sol";

contract CFHelpersStatev1Test is Test {
    CFHelpersStatev1 internal state;
    MockVaultFactory internal factory;

    // The client v0 seeded at construction; v1 seeds nothing.
    bytes32 internal constant V0_BOOTSTRAP_CLIENT_ID =
        0x16cbd0716887fd9259f39d403e19eb3436e3bdf3c17a37035cf0f8f0d7851e0b;
    // Any non-zero token address: State never touches the token, the vault does.
    address internal constant TOKEN = address(0xff);

    address internal deployer = makeAddr("deployer"); // initial Cofund admin
    address internal govEOA = makeAddr("gov");
    address internal usersEOA = makeAddr("users");
    address internal policiesEOA = makeAddr("policies");
    address internal clientAdmin = makeAddr("clientAdmin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal mallory = makeAddr("mallory");
    address internal rotated = makeAddr("rotated");

    // clientId is sha256(bytes(company)), as every v1 entrypoint verifies.
    bytes32 internal clientId;

    function setUp() public {
        vm.warp(1_700_000_000);
        clientId = sha256(bytes("Acme"));

        factory = new MockVaultFactory();

        vm.prank(deployer);
        state = new CFHelpersStatev1(deployer);

        // Wire gov / users / policies / vaults to plain EOAs and a mock factory
        // so State can be exercised in isolation.
        vm.prank(deployer);
        state.setGovHelperContract(govEOA);
        vm.startPrank(govEOA);
        state.setHelperContract("users", usersEOA);
        state.setHelperContract("policies", policiesEOA);
        state.setHelperContract("vaults", address(factory));
        vm.stopPrank();
    }

    // ---- fixtures -------------------------------------------------------

    function _idHash(string memory userId) internal pure returns (bytes32) {
        return keccak256(bytes(userId));
    }

    /// @dev The only way a v1 client comes into existence: the Users helper
    ///      opens it and the founder is its first active admin.
    function _foundClient() internal {
        vm.prank(usersEOA);
        state.newClient(clientId, "admin", clientAdmin, "FREE");
    }

    /// @dev Members are seats the Users helper has already authorized.
    function _registerMember(string memory userId, address member) internal {
        vm.prank(usersEOA);
        state.addUser(clientId, userId, member, false, "eng");
    }

    function _setupClient() internal {
        _foundClient();
        _registerMember("alice", alice);
        _registerMember("bob", bob);
        _registerMember("carol", carol);
    }

    // ---- argument builders ----------------------------------------------

    function _ids(string memory a) internal pure returns (string[] memory ids) {
        ids = new string[](1);
        ids[0] = a;
    }

    function _ids(string memory a, string memory b) internal pure returns (string[] memory ids) {
        ids = new string[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _ids(string memory a, string memory b, string memory c)
        internal
        pure
        returns (string[] memory ids)
    {
        ids = new string[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
    }

    function _addrs() internal pure returns (address[] memory a) {
        a = new address[](0);
    }

    function _addrs(address a0) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = a0;
    }

    function _addrs(address a0, address a1) internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = a0;
        a[1] = a1;
    }

    function _noTx() internal pure returns (CFHelpersStatev1.Transaction memory) {
        return CFHelpersStatev1.Transaction({wrapper: address(0), func: ""});
    }

    function _txDetails(string memory func) internal pure returns (CFHelpersStatev1.Transaction memory) {
        return CFHelpersStatev1.Transaction({wrapper: TOKEN, func: func});
    }

    function _noTransfer() internal pure returns (CFHelpersStatev1.Transfer memory) {
        return CFHelpersStatev1.Transfer({maxAmount: 0, token: address(0), recipients: _addrs()});
    }

    function _transfer(address[] memory recipients)
        internal
        pure
        returns (CFHelpersStatev1.Transfer memory)
    {
        return CFHelpersStatev1.Transfer({maxAmount: 2500, token: TOKEN, recipients: recipients});
    }

    // ---- constructor ----------------------------------------------------

    function test_ConstructorCreatesNoUsers() public view {
        // v0 seeded user "0" of a hard-coded client id; v1 seeds neither.
        assertEq(state.getUser(V0_BOOTSTRAP_CLIENT_ID, "0").addr, address(0));
        assertEq(state.getUser(clientId, "0").addr, address(0));
        assertEq(state.getUserIdByAddress(deployer, V0_BOOTSTRAP_CLIENT_ID), "");
        assertEq(state.getActiveAdmins(V0_BOOTSTRAP_CLIENT_ID), 0);
        assertEq(state.getActiveAdmins(clientId), 0);
    }

    function test_ConstructorGrantsCofundAdminAndFeeRecipient() public view {
        assertTrue(state.isCofundAdmin(deployer));
        assertEq(state.getCofundAdminCount(), 1);
        assertEq(state.cfFeeRecipientAddress(), deployer);
        // The "signatures" no-op write is gone; the key is simply unset.
        assertEq(state.helperContracts("signatures"), address(0));
    }

    function test_ConstructorSeedsTypesAndTiers() public view {
        assertTrue(state.isSupportedType("Contractor_Stipend"));
        assertTrue(state.isSupportedType("Treasury_Management"));
        assertTrue(state.subscriptionTierExists("FREE"));
        assertEq(state.subscriptionTierBps("FREE"), 75);
        assertTrue(state.subscriptionTierExists("TEAM"));
        assertEq(state.subscriptionTierBps("TEAM"), 50);
        assertTrue(state.subscriptionTierExists("BUSINESS_NEW"));
        assertEq(state.subscriptionTierBps("BUSINESS_NEW"), 25);
        assertTrue(state.subscriptionTierExists("BUSINESS"));
        assertEq(state.subscriptionTierBps("BUSINESS"), 0);
    }

    // ---- newClient ------------------------------------------------------

    function test_NewClientRecordsFounderAndVault() public {
        vm.expectEmit(true, false, false, true, address(state));
        emit CFHelpersStatev1.NewClientCreated(clientId, "admin", clientAdmin);
        vm.prank(usersEOA);
        state.newClient(clientId, "admin", clientAdmin, "FREE");

        (address vaultAddress, string memory vaultTier) = state.clientVaults(clientId);
        assertEq(vaultAddress, factory.vaultOf(clientId));
        assertTrue(vaultAddress != address(0));
        assertEq(vaultTier, "FREE");

        // The founder is an active admin immediately; there is no pending state.
        CFHelpersStatev1.User memory admin = state.getUser(clientId, "admin");
        assertEq(admin.addr, clientAdmin);
        assertEq(admin.position, "admin");
        assertTrue(admin.isAdmin);
        assertTrue(admin.active);
        assertEq(state.getUserIdByAddress(clientAdmin, clientId), "admin");
        assertEq(state.getActiveAdmins(clientId), 1);
    }

    function test_NewClientAllowsTheSameFounderOnAnotherClient() public {
        _foundClient();

        // usersByAddress is keyed per client, so one key can found two orgs.
        bytes32 otherClientId = sha256(bytes("Beta"));
        vm.prank(usersEOA);
        state.newClient(otherClientId, "admin", clientAdmin, "FREE");

        assertEq(state.getUserIdByAddress(clientAdmin, otherClientId), "admin");
        assertEq(state.getActiveAdmins(otherClientId), 1);
        assertTrue(state.getUser(otherClientId, "admin").active);
        // The first client is untouched.
        assertEq(state.getActiveAdmins(clientId), 1);
    }

    function test_RevertWhen_NewClientCalledByCofundAdmin() public {
        // The Cofund admin bit no longer opens clients; the Users helper does.
        vm.prank(deployer);
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.newClient(clientId, "admin", clientAdmin, "FREE");
    }

    function test_RevertWhen_NewClientCalledByRandomSigner() public {
        vm.prank(mallory);
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.newClient(clientId, "admin", clientAdmin, "FREE");
    }

    function test_RevertWhen_NewClientOnExistingClient() public {
        _foundClient();

        vm.prank(usersEOA);
        vm.expectRevert(CFHelpersStatev1.ClientExists.selector);
        state.newClient(clientId, "admin2", alice, "FREE");
    }

    function test_RevertWhen_NewClientTierIsUnknown() public {
        vm.prank(usersEOA);
        vm.expectRevert(CFHelpersStatev1.InvalidTier.selector);
        state.newClient(clientId, "admin", clientAdmin, "PLATINUM");
    }

    function test_RevertWhen_NewClientFounderIsZero() public {
        vm.prank(usersEOA);
        vm.expectRevert(CFHelpersStatev1.InvalidAddress.selector);
        state.newClient(clientId, "admin", address(0), "FREE");
    }

    // ---- setOnboardingComplete ------------------------------------------
    // A one-way flag and nothing else. State records that the platform said
    // onboarding finished; the rule it feeds -- one admin may activate a
    // policy while it is false -- lives in the policies helper (§4.3), and the
    // decision to flip it lives in the users helper. No time logic here.

    function test_OnboardingStartsFalseForAFreshClient() public {
        _foundClient();
        assertFalse(state.onboardingComplete(clientId));
    }

    function test_SetOnboardingCompleteSetsTheFlagAndEmits() public {
        _foundClient();

        vm.expectEmit(true, false, false, false, address(state));
        emit CFHelpersStatev1.OnboardingCompleted(clientId);
        vm.prank(usersEOA);
        state.setOnboardingComplete(clientId);

        assertTrue(state.onboardingComplete(clientId));
    }

    function test_RevertWhen_OnboardingIsCompletedTwice() public {
        _foundClient();

        vm.prank(usersEOA);
        state.setOnboardingComplete(clientId);

        // Irreversible, and not re-assertable either: the second call is an
        // error rather than a silent no-op, so a webapp that would lock an
        // already-locked client finds out.
        vm.prank(usersEOA);
        vm.expectRevert(CFHelpersStatev1.OnboardingAlreadyComplete.selector);
        state.setOnboardingComplete(clientId);

        assertTrue(state.onboardingComplete(clientId));
    }

    function test_RevertWhen_OnboardingCompletedForAnUnknownClient() public {
        // No vault registered means no client -- a typo in the id cannot leave
        // a flag standing for a client that is later created.
        bytes32 unknown = sha256(bytes("Nobody"));
        vm.prank(usersEOA);
        vm.expectRevert(CFHelpersStatev1.InvalidClient.selector);
        state.setOnboardingComplete(unknown);

        assertFalse(state.onboardingComplete(unknown));
    }

    function test_RevertWhen_OnboardingCompletedByARandomSigner() public {
        _foundClient();

        vm.prank(mallory);
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.setOnboardingComplete(clientId);

        assertFalse(state.onboardingComplete(clientId));
    }

    function test_RevertWhen_OnboardingCompletedByACofundAdmin() public {
        _foundClient();

        // The Cofund-admin bit reaches this through the users helper or not at
        // all, exactly as `newClient` and `addUser` do.
        vm.prank(deployer);
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.setOnboardingComplete(clientId);
    }

    function test_RevertWhen_OnboardingCompletedByThePoliciesHelper() public {
        _foundClient();

        // The helper that READS the flag is not the helper that writes it.
        vm.prank(policiesEOA);
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.setOnboardingComplete(clientId);
    }

    function test_OnboardingIsPerClient() public {
        _foundClient();

        bytes32 otherClientId = sha256(bytes("Beta"));
        vm.prank(usersEOA);
        state.newClient(otherClientId, "admin", alice, "FREE");

        vm.prank(usersEOA);
        state.setOnboardingComplete(clientId);

        assertTrue(state.onboardingComplete(clientId));
        // A client created later starts its own phase open.
        assertFalse(state.onboardingComplete(otherClientId));
    }

    // ---- addUser --------------------------------------------------------

    function test_AddUserRecordsAnActiveMember() public {
        _foundClient();

        vm.expectEmit(true, false, false, true, address(state));
        emit CFHelpersStatev1.UserAdded(clientId, "alice", alice);
        vm.prank(usersEOA);
        state.addUser(clientId, "alice", alice, false, "eng");

        CFHelpersStatev1.User memory member = state.getUser(clientId, "alice");
        assertEq(member.addr, alice);
        assertEq(member.position, "eng");
        assertFalse(member.isAdmin);
        assertTrue(member.active);
        assertEq(state.getUserIdByAddress(alice, clientId), "alice");
        // Non-admin members do not change the admin count.
        assertEq(state.getActiveAdmins(clientId), 1);
    }

    function test_AddUserIncrementsActiveAdminsForAnAdmin() public {
        _foundClient();

        vm.prank(usersEOA);
        state.addUser(clientId, "alice", alice, true, "finance");

        assertTrue(state.getUser(clientId, "alice").isAdmin);
        assertEq(state.getActiveAdmins(clientId), 2);
    }

    function test_RevertWhen_AddUserIdExists() public {
        _foundClient();
        _registerMember("alice", alice);

        vm.prank(usersEOA);
        vm.expectRevert(CFHelpersStatev1.UserExists.selector);
        state.addUser(clientId, "alice", bob, false, "eng");
    }

    function test_RevertWhen_AddUserAddressIsTaken() public {
        _foundClient();
        _registerMember("alice", alice);

        vm.prank(usersEOA);
        vm.expectRevert(CFHelpersStatev1.AddressExists.selector);
        state.addUser(clientId, "alice2", alice, false, "eng");
    }

    function test_RevertWhen_AddUserAddressIsZero() public {
        _foundClient();

        vm.prank(usersEOA);
        vm.expectRevert(CFHelpersStatev1.InvalidAddress.selector);
        state.addUser(clientId, "alice", address(0), false, "eng");
    }

    function test_RevertWhen_AddUserCalledByCofundAdmin() public {
        _foundClient();

        vm.prank(deployer);
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.addUser(clientId, "alice", alice, false, "eng");
    }

    function test_RevertWhen_AddUserCalledByRandomSigner() public {
        _foundClient();

        vm.prank(mallory);
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.addUser(clientId, "alice", alice, false, "eng");
    }

    // ---- activatePolicy -------------------------------------------------

    function test_ActivatePolicyStoresHashedIdsAndMembership() public {
        _setupClient();

        vm.expectEmit(true, false, false, true, address(state));
        emit CFHelpersStatev1.PolicyActivated(clientId, "p-happy");
        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId,
            "p-happy",
            "Contractor_Stipend",
            "Payroll",
            _ids("alice", "bob"),
            2,
            _noTx(),
            _transfer(_addrs(carol)),
            false
        );

        CFHelpersStatev1.Policy memory policy = state.getPolicy(clientId, "p-happy");
        assertTrue(policy.active);
        assertEq(policy.title, "Payroll");
        assertEq(policy.policyType, "Contractor_Stipend");
        assertEq(policy.threshold, 2);
        assertFalse(policy.isTransaction);

        bytes32[] memory expected = new bytes32[](2);
        expected[0] = _idHash("alice");
        expected[1] = _idHash("bob");
        assertEq(policy.signerIds, expected);
        assertEq(policy.transferDetails.recipients, _addrs(carol));

        assertTrue(state.isPolicySigner(clientId, "p-happy", _idHash("alice")));
        assertTrue(state.isPolicySigner(clientId, "p-happy", _idHash("bob")));
        assertFalse(state.isPolicySigner(clientId, "p-happy", _idHash("carol")));
    }

    function test_ActivatePolicyAcceptsEmptyRecipientList() public {
        _setupClient();

        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId, "p-open", "Contractor_Stipend", "Open", _ids("alice"), 1, _noTx(), _transfer(_addrs()), false
        );

        assertEq(state.getPolicy(clientId, "p-open").transferDetails.recipients.length, 0);
    }

    function test_ActivateTransactionPolicy() public {
        _setupClient();

        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId,
            "p-tx",
            "Treasury_Management",
            "Treasury Ops",
            _ids("alice", "carol"),
            2,
            _txDetails("mint-token"),
            _noTransfer(),
            true
        );

        CFHelpersStatev1.Policy memory policy = state.getPolicy(clientId, "p-tx");
        assertTrue(policy.isTransaction);
        assertEq(policy.transactionDetails.func, "mint-token");

        bytes32[] memory expected = new bytes32[](2);
        expected[0] = _idHash("alice");
        expected[1] = _idHash("carol");
        assertEq(policy.signerIds, expected);
    }

    function test_ActivatePolicyDoesNotCheckRecipientsOnTransaction() public {
        _setupClient();

        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId,
            "p-tx-zero-recipient",
            "Treasury_Management",
            "Treasury Ops",
            _ids("alice"),
            1,
            _txDetails("mint-token"),
            CFHelpersStatev1.Transfer({maxAmount: 0, token: address(0), recipients: _addrs(address(0))}),
            true
        );

        assertTrue(state.getPolicy(clientId, "p-tx-zero-recipient").isTransaction);
    }

    function test_ActivatePolicyAcceptsUnsupportedType() public {
        _setupClient();

        // The isSupportedType check moved to the Policies helper: State stores
        // whatever type it is handed.
        assertFalse(state.isSupportedType("Not_A_Type"));

        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId, "p-type", "Not_A_Type", "Odd", _ids("alice"), 1, _noTx(), _transfer(_addrs()), false
        );

        assertEq(state.getPolicy(clientId, "p-type").policyType, "Not_A_Type");
    }

    function test_RevertWhen_ActivatePolicySignerIsUnknown() public {
        _setupClient();

        vm.prank(policiesEOA);
        vm.expectRevert(CFHelpersStatev1.InvalidPolicySigner.selector);
        state.activatePolicy(
            clientId,
            "p-unknown",
            "Contractor_Stipend",
            "Payroll",
            _ids("alice", "nobody"),
            2,
            _noTx(),
            _transfer(_addrs()),
            false
        );
    }

    function test_RevertWhen_ActivatePolicySignerIsInactive() public {
        _setupClient();
        _registerMember("dave", dave);
        vm.prank(usersEOA);
        state.removeUser(clientId, "admin", "dave");

        vm.prank(policiesEOA);
        vm.expectRevert(CFHelpersStatev1.InvalidPolicySigner.selector);
        state.activatePolicy(
            clientId,
            "p-inactive",
            "Contractor_Stipend",
            "Payroll",
            _ids("alice", "dave"),
            2,
            _noTx(),
            _transfer(_addrs()),
            false
        );
    }

    function test_RevertWhen_ActivatePolicyHasDuplicateSigner() public {
        _setupClient();

        vm.prank(policiesEOA);
        vm.expectRevert(CFHelpersStatev1.DuplicatePolicySigner.selector);
        state.activatePolicy(
            clientId,
            "p-duplicate",
            "Contractor_Stipend",
            "Payroll",
            _ids("alice", "bob", "alice"),
            2,
            _noTx(),
            _transfer(_addrs()),
            false
        );
    }

    function test_RevertWhen_ActivatePolicyHasZeroRecipient() public {
        _setupClient();

        vm.prank(policiesEOA);
        vm.expectRevert(CFHelpersStatev1.InvalidRecipient.selector);
        state.activatePolicy(
            clientId,
            "p-zero-recipient",
            "Contractor_Stipend",
            "Payroll",
            _ids("alice"),
            1,
            _noTx(),
            _transfer(_addrs(carol, address(0))),
            false
        );
    }

    function test_RevertWhen_ActivatePolicyIdExists() public {
        _setupClient();

        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId, "p-happy", "Contractor_Stipend", "Payroll", _ids("alice"), 1, _noTx(), _transfer(_addrs()), false
        );

        vm.prank(policiesEOA);
        vm.expectRevert(CFHelpersStatev1.InvalidPolicy.selector);
        state.activatePolicy(
            clientId, "p-happy", "Contractor_Stipend", "Payroll 2", _ids("carol"), 1, _noTx(), _transfer(_addrs()), false
        );
    }

    function test_RevertWhen_ActivatePolicyCallerIsNotPoliciesHelper() public {
        _setupClient();

        vm.prank(mallory);
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.activatePolicy(
            clientId, "p-caller", "Contractor_Stipend", "Payroll", _ids("alice"), 1, _noTx(), _transfer(_addrs()), false
        );

        vm.prank(usersEOA);
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.activatePolicy(
            clientId, "p-caller", "Contractor_Stipend", "Payroll", _ids("alice"), 1, _noTx(), _transfer(_addrs()), false
        );
    }

    function test_DeactivatePolicyKeepsMembership() public {
        _setupClient();

        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId, "p-open", "Contractor_Stipend", "Open", _ids("alice"), 1, _noTx(), _transfer(_addrs()), false
        );

        vm.expectEmit(true, false, false, true, address(state));
        emit CFHelpersStatev1.PolicyDeactivated(clientId, "p-open");
        vm.prank(policiesEOA);
        state.deactivatePolicy(clientId, "p-open");

        assertFalse(state.getPolicy(clientId, "p-open").active);
        assertTrue(state.isPolicySigner(clientId, "p-open", _idHash("alice")));
    }

    // ---- resolvePolicySigner --------------------------------------------

    function _activateResolvePolicy() internal {
        _setupClient();
        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId,
            "p-resolve",
            "Contractor_Stipend",
            "Payroll",
            _ids("alice", "bob"),
            2,
            _noTx(),
            _transfer(_addrs()),
            false
        );
    }

    function test_ResolveUnmappedAddress() public {
        _activateResolvePolicy();

        (bool ok, bytes32 signerId) = state.resolvePolicySigner(clientId, "p-resolve", mallory);
        assertFalse(ok);
        assertEq(signerId, bytes32(0));
    }

    function test_ResolveActiveUserNotOnPolicy() public {
        _activateResolvePolicy();

        (bool ok, bytes32 signerId) = state.resolvePolicySigner(clientId, "p-resolve", carol);
        assertFalse(ok);
        assertEq(signerId, _idHash("carol"));
    }

    function test_ResolveActiveUserOnPolicy() public {
        _activateResolvePolicy();

        (bool ok, bytes32 signerId) = state.resolvePolicySigner(clientId, "p-resolve", alice);
        assertTrue(ok);
        assertEq(signerId, _idHash("alice"));
    }

    function test_ResolveUnknownPolicyId() public {
        _activateResolvePolicy();

        (bool ok, bytes32 signerId) = state.resolvePolicySigner(clientId, "p-does-not-exist", alice);
        assertFalse(ok);
        assertEq(signerId, _idHash("alice"));
    }

    // ---- rotation and removal -------------------------------------------

    function _activateLivePolicy() internal {
        _setupClient();
        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId,
            "p-live",
            "Contractor_Stipend",
            "Payroll",
            _ids("alice", "bob"),
            2,
            _noTx(),
            _transfer(_addrs()),
            false
        );
    }

    function test_RotateUserMovesThePolicySeat() public {
        _activateLivePolicy();

        vm.prank(usersEOA);
        state.rotateUser(clientId, "alice", rotated);

        (bool newOk, bytes32 newId) = state.resolvePolicySigner(clientId, "p-live", rotated);
        assertTrue(newOk);
        assertEq(newId, _idHash("alice"));

        (bool oldOk, bytes32 oldId) = state.resolvePolicySigner(clientId, "p-live", alice);
        assertFalse(oldOk);
        assertEq(oldId, bytes32(0));

        // The policy itself was never re-issued.
        bytes32[] memory expected = new bytes32[](2);
        expected[0] = _idHash("alice");
        expected[1] = _idHash("bob");
        assertEq(state.getPolicy(clientId, "p-live").signerIds, expected);
    }

    function test_RemoveUserRevokesThePolicySeat() public {
        _activateLivePolicy();

        (bool beforeOk,) = state.resolvePolicySigner(clientId, "p-live", bob);
        assertTrue(beforeOk);

        vm.prank(usersEOA);
        state.removeUser(clientId, "admin", "bob");

        (bool ok, bytes32 signerId) = state.resolvePolicySigner(clientId, "p-live", bob);
        assertFalse(ok);
        assertEq(signerId, bytes32(0));

        // Membership is not liveness: the id is still on the policy.
        assertTrue(state.isPolicySigner(clientId, "p-live", _idHash("bob")));
    }

    // ---- setClientContractAuthID ----------------------------------------

    function test_SetClientContractAuthIDAcceptsPoliciesHelper() public {
        // Round 6 dropped the consumer's address from the event with the key.
        vm.expectEmit(false, false, false, true, address(state));
        emit CFHelpersStatev1.SetClientContractAuthID(clientId, "policies-auth-1", true);
        vm.prank(policiesEOA);
        state.setClientContractAuthID(clientId, "policies-auth-1");

        assertTrue(state.getClientContractAuthID(clientId, "policies-auth-1"));
    }

    function test_RevertWhen_SetClientContractAuthIDReplayed() public {
        vm.prank(policiesEOA);
        state.setClientContractAuthID(clientId, "policies-auth-1");

        vm.prank(policiesEOA);
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        state.setClientContractAuthID(clientId, "policies-auth-1");
    }

    /// Round 6, and the reason the EIP-712 domain may bind to State instead
    /// of to whichever contract verifies a signature (§4.1, §4.2): the store
    /// is keyed `(clientId, authId)` and by nothing else, so an `authId` the
    /// users helper spent is already gone when the policies helper -- or the
    /// client's own vault -- reaches for it. Before this change each consumer
    /// had its own namespace, which is exactly what a signature replayed onto
    /// a successor helper would have exploited.
    function test_SetClientContractAuthIDIsSingleUseAcrossConsumers() public {
        // Give the client a vault so the third allowed caller is real.
        _foundClient();
        (address vault, ) = state.clientVaults(clientId);

        vm.prank(usersEOA);
        state.setClientContractAuthID(clientId, "shared-auth");

        vm.prank(policiesEOA);
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        state.setClientContractAuthID(clientId, "shared-auth");

        vm.prank(vault);
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        state.setClientContractAuthID(clientId, "shared-auth");

        // ...and the other way round: what the vault spends, the helpers
        // cannot re-spend.
        vm.prank(vault);
        state.setClientContractAuthID(clientId, "vault-auth");

        vm.prank(usersEOA);
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        state.setClientContractAuthID(clientId, "vault-auth");

        vm.prank(policiesEOA);
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        state.setClientContractAuthID(clientId, "vault-auth");
    }

    /// The read side of the same key: no `msg.sender` dependence at all, so
    /// every caller -- consumer, stranger, off-chain indexer -- sees the one
    /// answer the three consumers write.
    function test_GetClientContractAuthIDDoesNotDependOnTheCaller() public {
        _foundClient();
        (address vault, ) = state.clientVaults(clientId);

        vm.prank(usersEOA);
        state.setClientContractAuthID(clientId, "shared-auth");

        assertTrue(state.getClientContractAuthID(clientId, "shared-auth"));
        vm.prank(usersEOA);
        assertTrue(state.getClientContractAuthID(clientId, "shared-auth"));
        vm.prank(policiesEOA);
        assertTrue(state.getClientContractAuthID(clientId, "shared-auth"));
        vm.prank(vault);
        assertTrue(state.getClientContractAuthID(clientId, "shared-auth"));
        vm.prank(mallory);
        assertTrue(state.getClientContractAuthID(clientId, "shared-auth"));

        // Unspent stays unspent, for everyone.
        vm.prank(mallory);
        assertFalse(state.getClientContractAuthID(clientId, "never-spent"));
    }

    /// Per client, though: the key's first half still isolates one company's
    /// `authId` namespace from another's.
    function test_SetClientContractAuthIDIsStillScopedPerClient() public {
        bytes32 otherClientId = sha256(bytes("Globex"));

        vm.prank(usersEOA);
        state.setClientContractAuthID(clientId, "shared-auth");

        vm.prank(usersEOA);
        state.setClientContractAuthID(otherClientId, "shared-auth");

        assertTrue(state.getClientContractAuthID(clientId, "shared-auth"));
        assertTrue(state.getClientContractAuthID(otherClientId, "shared-auth"));
    }

    function test_RevertWhen_SetClientContractAuthIDCallerIsUnknown() public {
        vm.prank(mallory);
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.setClientContractAuthID(clientId, "mallory-auth");

        vm.prank(deployer);
        vm.expectRevert(CFHelpersStatev1.UnauthorizedCaller.selector);
        state.setClientContractAuthID(clientId, "admin-auth");
    }

    // ---- removed surface ------------------------------------------------

    function test_RemovedFunctionsAreNotCallable() public {
        // Exact v0 / round-1 / round-2 signatures, so each selector is real.
        string[18] memory sigs = [
            "migrateClient(bytes32,address,string,string)",
            "migrateUser(bytes32,string,address,string,bool,bool)",
            "migratePolicy(bytes32,string,(bool,string,string,address[],uint256,(address,string),(uint256,address,address[]),bool))",
            "migrateClientsBatch((bytes32,address,string,string)[])",
            "migrateUsersBatch((bytes32,string,address,string,bool,bool)[])",
            "migratePoliciesBatch((bytes32,string,(bool,string,string,address[],uint256,(address,string),(uint256,address,address[]),bool))[])",
            "finalizeMigration()",
            // Getters: if present these would return, so absence is exact.
            "isMigrationComplete()",
            "migrationComplete()",
            // v0 shapes.
            "newClient(bytes32,bytes32,string,string)",
            "newClientMultiAdmin(bytes32,(bytes32,string)[],string)",
            "addUserInvite(bytes32,bytes32,string,string,bool,string,address)",
            "completeUserInvite(bytes32,bytes32,uint256,address)",
            // The whole invite subsystem, as it stood at the end of round 2.
            "newClient(bytes32,bytes32,string,string,uint256)",
            "addUserInvite(bytes32,bytes32,string,string,bool,string,address,uint256)",
            "completeUserInvite(bytes32,bytes32,address)",
            "getInvite(bytes32,bytes32)",
            "invites(bytes32,bytes32)"
        ];

        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(state).call(abi.encodeWithSelector(bytes4(keccak256(bytes(sigs[i])))));
            assertFalse(ok, sigs[i]);
        }
    }

    function test_RemovedCallShapesAreNotDispatchable() public {
        bytes32 inviteHash = keccak256("an-invite");

        // Well formed under the round-2 signature and sent by the authorized
        // caller: this call would have succeeded, so it can only fail because
        // the function is gone.
        vm.prank(usersEOA);
        (bool newClientOk,) = address(state).call(
            abi.encodeWithSignature(
                "newClient(bytes32,bytes32,string,string,uint256)",
                clientId,
                inviteHash,
                "admin",
                "FREE",
                block.timestamp + 1 days
            )
        );
        assertFalse(newClientOk);

        _foundClient();

        vm.prank(usersEOA);
        (bool addInviteOk,) = address(state).call(
            abi.encodeWithSignature(
                "addUserInvite(bytes32,bytes32,string,string,bool,string,address,uint256)",
                clientId,
                inviteHash,
                "admin",
                "alice",
                false,
                "eng",
                clientAdmin,
                block.timestamp + 1 days
            )
        );
        assertFalse(addInviteOk);

        // A view that would simply have returned.
        (bool invitesOk,) =
            address(state).call(abi.encodeWithSignature("invites(bytes32,bytes32)", clientId, inviteHash));
        assertFalse(invitesOk);
    }

    function test_FrozenSelectors() public view {
        // Other packages hard-code these; pin them here.
        assertEq(state.newClient.selector, bytes4(keccak256("newClient(bytes32,string,address,string)")));
        assertEq(state.addUser.selector, bytes4(keccak256("addUser(bytes32,string,address,bool,string)")));
        assertEq(
            state.resolvePolicySigner.selector, bytes4(keccak256("resolvePolicySigner(bytes32,string,address)"))
        );
        assertEq(state.isPolicySigner.selector, bytes4(keccak256("isPolicySigner(bytes32,string,bytes32)")));
    }
}
