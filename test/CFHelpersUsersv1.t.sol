// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {CFHelpersUsersv1} from "../contracts/CFHelpersUsersv1.sol";
import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {CFHelpersGovv1} from "../contracts/CFHelpersGovv1.sol";
import {MockVaultFactory} from "../contracts/MockVaultFactory.sol";
import {Eip712} from "./utils/Eip712.sol";

/**
 * CFHelpersUsersv1 -- membership in four functions, no invite code.
 *
 * A seat is written in one transaction and nothing is ever pending on chain.
 * Three things bind it (§4.4): the admin's signature over `InviteUser`, which
 * they give once before the member has a wallet; the platform's authentication
 * of the `userId`, which the contract turns into a rule by requiring the call
 * to arrive through the sponsor guard or a Cofund admin; and the member's own
 * signature over the same digest.
 *
 * So `guardEOA` sends almost everything here. That it is the sender authorizes
 * nothing by itself -- every seat still needs both signatures -- but a caller
 * that is neither the guard nor Cofund cannot onboard at all.
 */
contract CFHelpersUsersv1Test is Test {
    CFHelpersStatev1 internal state;
    CFHelpersGovv1 internal gov;
    CFHelpersUsersv1 internal users;
    MockVaultFactory internal vaultFactory;

    // Cofund side
    address internal cofundAdmin;
    /// Registered as `helperContracts["sponsorGuard"]`; relays onboarding.
    address internal guardEOA;
    /// Neither the guard nor Cofund.
    address internal stranger;

    // Client side -- everyone signs, so everyone needs a key.
    uint256 internal founderPk;
    uint256 internal adminBPk;
    uint256 internal adminCPk;
    uint256 internal adminDPk;
    uint256 internal memberPk;
    uint256 internal inviteePk;
    uint256 internal outsiderPk;
    address internal founder;
    address internal adminB;
    address internal adminC;
    address internal adminD;
    address internal member;
    address internal invitee;
    address internal outsider;

    string internal constant COMPANY = "Acme";
    string internal constant OTHER_COMPANY = "Globex";
    string internal constant FOUNDER_ID = "admin";
    string internal constant TIER = "FREE";

    /// Precomputed: `sha256` is a precompile CALL, and evaluating one after
    /// `vm.expectRevert` would consume the expectation.
    bytes32 internal CLIENT_ID;
    bytes32 internal OTHER_CLIENT_ID;

    uint256 internal nextAuth = 1;

    /// Admins of the fixture client, in the order they were seated.
    uint256[] internal rosterPk;
    string[] internal rosterId;

    // ══════════════════════════════════════════════════════════════════
    //                             fixture
    // ══════════════════════════════════════════════════════════════════

    function setUp() public {
        // Foundry starts at timestamp 1; the window is absolute unix time.
        vm.warp(1_700_000_000);

        cofundAdmin = makeAddr("cofundAdmin");
        guardEOA = makeAddr("guardEOA");
        stranger = makeAddr("stranger");

        (founder, founderPk) = makeAddrAndKey("founder");
        (adminB, adminBPk) = makeAddrAndKey("adminB");
        (adminC, adminCPk) = makeAddrAndKey("adminC");
        (adminD, adminDPk) = makeAddrAndKey("adminD");
        (member, memberPk) = makeAddrAndKey("member");
        (invitee, inviteePk) = makeAddrAndKey("invitee");
        (outsider, outsiderPk) = makeAddrAndKey("outsider");

        CLIENT_ID = Eip712.companyId(COMPANY);
        OTHER_CLIENT_ID = Eip712.companyId(OTHER_COMPANY);

        state = new CFHelpersStatev1(cofundAdmin);
        gov = new CFHelpersGovv1(address(state));
        vm.prank(cofundAdmin);
        state.setGovHelperContract(address(gov));

        users = new CFHelpersUsersv1(address(state));
        vaultFactory = new MockVaultFactory();

        vm.startPrank(cofundAdmin);
        gov.setHelperContract("users", address(users));
        gov.setHelperContract("vaults", address(vaultFactory));
        gov.setHelperContract("sponsorGuard", guardEOA);
        vm.stopPrank();

        _createClient(guardEOA, CLIENT_ID, COMPANY, founder, founderPk);

        rosterPk.push(founderPk);
        rosterId.push(FOUNDER_ID);
    }

    // ══════════════════════════════════════════════════════════════════
    //                        signing / plumbing
    // ══════════════════════════════════════════════════════════════════

    function _defaultExpiry() internal view returns (uint256) {
        return block.timestamp + 1 days;
    }

    function _auth() internal returns (string memory) {
        return string.concat("auth-", vm.toString(nextAuth++));
    }

    /// State's public `clientVaults` getter returns a tuple, not the struct.
    function _vaultOf(bytes32 clientId) internal view returns (address vault) {
        (vault, ) = state.clientVaults(clientId);
    }

    /**
     * The round-3 `InviteUser` type, re-derived here from §4.2 rather than read
     * off the contract, so a typo on either side shows up as a failed recovery.
     *
     * NOT `Eip712.hashStruct(Eip712.InviteUser)`: the shared library still
     * carries the round-2 type, which had a `bytes32 inviteHash` between
     * `userPosition` and `expiresAt`. The invite code is gone (§4.4), so that
     * copy is stale and this suite cannot use it.
     */
    bytes32 internal constant INVITE_USER_TYPEHASH_R3 =
        keccak256(
            "InviteUser(string company,string callerId,string userId,bool userIsAdmin,string userPosition,uint256 expiresAt,string authId)"
        );

    function _inviteDigest(
        CFHelpersUsersv1.AddUserArgs memory a
    ) internal view returns (bytes32) {
        return
            Eip712.digest(
                Eip712.domainSeparator(address(state)),
                keccak256(
                    abi.encode(
                        INVITE_USER_TYPEHASH_R3,
                        keccak256(bytes(a.company)),
                        keccak256(bytes(a.callerId)),
                        keccak256(bytes(a.userId)),
                        a.isAdmin,
                        keccak256(bytes(a.userPosition)),
                        a.expiresAt,
                        keccak256(bytes(a.authId))
                    )
                )
            );
    }

    function _removeDigest(
        string memory removedUserId,
        string memory authId
    ) internal view returns (bytes32) {
        return
            Eip712.digest(
                Eip712.domainSeparator(address(state)),
                Eip712.hashStruct(
                    Eip712.RemoveUser({
                        company: COMPANY,
                        removedUserId: removedUserId,
                        authId: authId
                    })
                )
            );
    }

    function _rotateDigest(
        string memory userId,
        address newAddress,
        string memory authId
    ) internal view returns (bytes32) {
        return
            Eip712.digest(
                Eip712.domainSeparator(address(state)),
                Eip712.hashStruct(
                    Eip712.RotateUser({
                        company: COMPANY,
                        userId: userId,
                        newAddress: newAddress,
                        authId: authId
                    })
                )
            );
    }

    /// Memory structs are reference types: `b = a` aliases `a`, and mutating
    /// `b` would silently rewrite the payload under test. Copy.
    function _copy(
        CFHelpersUsersv1.AddUserArgs memory a
    ) internal pure returns (CFHelpersUsersv1.AddUserArgs memory) {
        return
            CFHelpersUsersv1.AddUserArgs({
                clientId: a.clientId,
                company: a.company,
                callerId: a.callerId,
                userId: a.userId,
                isAdmin: a.isAdmin,
                userPosition: a.userPosition,
                expiresAt: a.expiresAt,
                authId: a.authId
            });
    }

    // ══════════════════════════════════════════════════════════════════
    //                          flow helpers
    // ══════════════════════════════════════════════════════════════════

    function _args(
        string memory callerId,
        string memory userId,
        bool isAdmin,
        string memory position
    ) internal returns (CFHelpersUsersv1.AddUserArgs memory) {
        return
            CFHelpersUsersv1.AddUserArgs({
                clientId: CLIENT_ID,
                company: COMPANY,
                callerId: callerId,
                userId: userId,
                isAdmin: isAdmin,
                userPosition: position,
                expiresAt: _defaultExpiry(),
                authId: _auth()
            });
    }

    /// The founder signs `InviteUser` over themselves; the platform relays.
    function _createClient(
        address caller,
        bytes32 clientId,
        string memory company,
        address who,
        uint256 whoPk
    ) internal {
        uint256 expiresAt = _defaultExpiry();
        string memory authId = _auth();
        bytes32 d = _inviteDigest(
            CFHelpersUsersv1.AddUserArgs({
                clientId: clientId,
                company: company,
                callerId: FOUNDER_ID,
                userId: FOUNDER_ID,
                isAdmin: true,
                userPosition: "admin",
                expiresAt: expiresAt,
                authId: authId
            })
        );
        vm.prank(caller);
        users.createClient(
            clientId,
            company,
            FOUNDER_ID,
            who,
            TIER,
            expiresAt,
            authId,
            Eip712.sign(whoPk, d)
        );
    }

    function _addUser(
        CFHelpersUsersv1.AddUserArgs memory a,
        uint256 adminPk,
        uint256[] memory coSignerPks,
        address who,
        uint256 whoPk
    ) internal {
        _addUserFrom(guardEOA, a, adminPk, coSignerPks, who, whoPk);
    }

    function _addUserFrom(
        address caller,
        CFHelpersUsersv1.AddUserArgs memory a,
        uint256 adminPk,
        uint256[] memory coSignerPks,
        address who,
        uint256 whoPk
    ) internal {
        bytes32 d = _inviteDigest(a);
        vm.prank(caller);
        users.addUser(
            a,
            Eip712.sign(adminPk, d),
            Eip712.sign(coSignerPks, d),
            who,
            Eip712.sign(whoPk, d)
        );
    }

    function _seat(
        string memory userId,
        bool isAdmin,
        address who,
        uint256 whoPk,
        uint256[] memory coSignerPks
    ) internal {
        _addUser(
            _args(FOUNDER_ID, userId, isAdmin, isAdmin ? "admin" : "engineer"),
            founderPk,
            coSignerPks,
            who,
            whoPk
        );
    }

    function _registerMember() internal {
        _seat("m1", false, member, memberPk, _noKeys());
    }

    /// Grows the client to `n` active admins, satisfying the rule at each step.
    function _growToAdmins(uint256 n) internal {
        address[3] memory pool = [adminB, adminC, adminD];
        uint256[3] memory poolPk = [adminBPk, adminCPk, adminDPk];
        while (rosterPk.length < n) {
            uint256 required = users.requiredAdminInviteSignatures(CLIENT_ID);
            uint256 coCount = required > 1 ? required - 1 : 0;
            uint256[] memory co = new uint256[](coCount);
            for (uint256 i = 0; i < coCount; i++) co[i] = rosterPk[i + 1];

            uint256 idx = rosterPk.length - 1;
            string memory id = string.concat("admin-", vm.toString(idx + 1));
            _seat(id, true, pool[idx], poolPk[idx], co);
            rosterPk.push(poolPk[idx]);
            rosterId.push(id);
        }
    }

    function _noKeys() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    /// Closes the fixture client's onboarding phase, which is what puts the
    /// admin-seat ceremony -- all active admins but one -- in force (§4.3,
    /// round 5). `completeOnboarding` is signature-authorized, so the founder
    /// (an active admin) is enough and the relayer is irrelevant.
    ///
    /// Every ceremony test below calls this FIRST and on purpose: a fresh
    /// client's phase is open, and while it is open ONE signature seats an
    /// admin whatever the roster looks like, so a ceremony test that skipped
    /// this would be asserting nothing.
    function _lockOnboarding() internal {
        _lock(guardEOA, founderPk, _auth());
    }

    // ══════════════════════════════════════════════════════════════════
    //                       the fixture itself
    // ══════════════════════════════════════════════════════════════════

    function test_CreateClient_SeatsTheFounderAndTheVault() public view {
        assertEq(CLIENT_ID, sha256(bytes(COMPANY)));
        assertTrue(_vaultOf(CLIENT_ID) != address(0));

        CFHelpersStatev1.User memory u = state.getUser(CLIENT_ID, FOUNDER_ID);
        assertEq(u.addr, founder);
        assertEq(u.position, "admin");
        assertTrue(u.isAdmin);
        assertTrue(u.active);
        assertEq(state.getUserIdByAddress(founder, CLIENT_ID), FOUNDER_ID);
        assertEq(state.getActiveAdmins(CLIENT_ID), 1);
    }

    // ══════════════════════════════════════════════════════════════════
    //                     platform gating (§4.4)
    // ══════════════════════════════════════════════════════════════════

    function test_CreateClient_FromTheSponsorGuard() public {
        vm.expectEmit(true, false, false, true, address(state));
        emit CFHelpersStatev1.NewClientCreated(
            OTHER_CLIENT_ID,
            FOUNDER_ID,
            adminB
        );
        _createClient(guardEOA, OTHER_CLIENT_ID, OTHER_COMPANY, adminB, adminBPk);

        assertEq(state.getUser(OTHER_CLIENT_ID, FOUNDER_ID).addr, adminB);
        assertTrue(_vaultOf(OTHER_CLIENT_ID) != address(0));
        assertEq(state.getActiveAdmins(OTHER_CLIENT_ID), 1);
    }

    function test_CreateClient_FromACofundAdmin() public {
        _createClient(
            cofundAdmin,
            OTHER_CLIENT_ID,
            OTHER_COMPANY,
            adminB,
            adminBPk
        );
        assertEq(state.getUser(OTHER_CLIENT_ID, FOUNDER_ID).addr, adminB);
    }

    function test_CreateClient_RevertsForARandomEOA() public {
        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        _createClient(stranger, OTHER_CLIENT_ID, OTHER_COMPANY, adminB, adminBPk);
    }

    function test_CreateClient_RevertsForAClientAdmin() public {
        // Being an admin of a client is not being Cofund.
        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        _createClient(founder, OTHER_CLIENT_ID, OTHER_COMPANY, adminB, adminBPk);
    }

    function test_AddUser_FromACofundAdmin() public {
        _addUserFrom(
            cofundAdmin,
            _args(FOUNDER_ID, "m1", false, "engineer"),
            founderPk,
            _noKeys(),
            member,
            memberPk
        );
        assertEq(state.getUser(CLIENT_ID, "m1").addr, member);
    }

    function test_AddUser_RevertsForARandomEOA() public {
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        _addUserFrom(stranger, a, founderPk, _noKeys(), member, memberPk);
    }

    function test_AddUser_RevertsForAClientAdminRelayingThemselves() public {
        // Even the authorizing admin cannot relay their own authorization: the
        // platform's authentication of the member is the missing factor.
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        _addUserFrom(founder, a, founderPk, _noKeys(), member, memberPk);
    }

    // ══════════════════════════════════════════════════════════════════
    //             completeOnboarding -- locking the phase (§4.3)
    // ══════════════════════════════════════════════════════════════════
    //
    // Round 4, revised: the LOCK IS ADMIN-SIGNED, not platform-gated. Any one
    // active admin may close their own client's onboarding phase, and the
    // founder is one, so a client never waits on Cofund to tighten its own
    // rules. `msg.sender` authorizes nothing -- as in `removeUser` and
    // `rotateUser`, the signature is the whole authorization and anybody may
    // broadcast it.
    //
    // What it closes is a rule in the POLICIES helper (one admin may activate
    // a policy while the phase is open), so this suite proves who may sign,
    // that `msg.sender` is irrelevant, and that State records it exactly once.

    function _onboardingSig(
        uint256 pk,
        string memory authId
    ) internal view returns (bytes memory) {
        return
            Eip712.signCompleteOnboarding(
                pk,
                Eip712.domainSeparator(address(state)),
                COMPANY,
                authId
            );
    }

    /// `caller` is deliberately a parameter everywhere: it must never matter.
    function _lock(
        address caller,
        uint256 pk,
        string memory authId
    ) internal {
        vm.prank(caller);
        users.completeOnboarding(
            CLIENT_ID,
            COMPANY,
            authId,
            _onboardingSig(pk, authId)
        );
    }

    function test_CompleteOnboarding_OnTheFoundersSignature() public {
        assertFalse(state.onboardingComplete(CLIENT_ID), "phase starts open");

        vm.expectEmit(true, false, false, false, address(state));
        emit CFHelpersStatev1.OnboardingCompleted(CLIENT_ID);
        vm.prank(guardEOA);
        assertTrue(
            users.completeOnboarding(
                CLIENT_ID,
                COMPANY,
                "auth-lock",
                _onboardingSig(founderPk, "auth-lock")
            )
        );

        assertTrue(state.onboardingComplete(CLIENT_ID), "phase not locked");
    }

    function test_CompleteOnboarding_OnASecondAdminsSignature() public {
        _growToAdmins(2);

        // Any ONE active admin, not a consensus: the permission being given up
        // is the signer's own, and the lock only ever tightens the rules.
        _lock(guardEOA, rosterPk[1], "auth-lock");
        assertTrue(state.onboardingComplete(CLIENT_ID));
    }

    function test_CompleteOnboarding_IsNotPlatformGated() public {
        // The point of the revision. `createClient` and `addUser` turn on the
        // platform's authentication of a PERSON, which the contract cannot
        // see. An admin signing for their own client is something it can check
        // outright, so no relay is privileged here and none is required.
        _lock(stranger, founderPk, "auth-lock-stranger");
        assertTrue(
            state.onboardingComplete(CLIENT_ID),
            "a stranger holding a valid signature could not relay it"
        );
    }

    function test_CompleteOnboarding_FromTheAdminsOwnAddress() public {
        // The founder paying their own gas, with no relay in the picture.
        _lock(founder, founderPk, "auth-lock-self");
        assertTrue(state.onboardingComplete(CLIENT_ID));
    }

    function test_CompleteOnboarding_FromACofundAdmin() public {
        // Cofund may still broadcast it -- but only carrying a client admin's
        // signature. The bit buys nothing on its own; see the negative below.
        _lock(cofundAdmin, founderPk, "auth-lock-cofund");
        assertTrue(state.onboardingComplete(CLIENT_ID));
    }

    function test_CompleteOnboarding_RevertsForACofundAdminSigningForItself()
        public
    {
        // Being Cofund is not being an admin of this client, and the signature
        // is the authorization -- so a platform key is just a stranger's key.
        (, uint256 cofundPk) = makeAddrAndKey("cofundAdminWithAKey");
        bytes memory sig = _onboardingSig(cofundPk, "auth-lock-nope");

        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        vm.prank(cofundAdmin);
        users.completeOnboarding(CLIENT_ID, COMPANY, "auth-lock-nope", sig);

        assertFalse(state.onboardingComplete(CLIENT_ID));
    }

    function test_CompleteOnboarding_RevertsInvalidSignerForAMember() public {
        _registerMember();

        bytes memory sig = _onboardingSig(memberPk, "auth-lock");
        vm.expectRevert(CFHelpersUsersv1.InvalidSigner.selector);
        vm.prank(guardEOA);
        users.completeOnboarding(CLIENT_ID, COMPANY, "auth-lock", sig);

        assertFalse(state.onboardingComplete(CLIENT_ID));
    }

    function test_CompleteOnboarding_RevertsInactiveSignerForARemovedAdmin()
        public
    {
        _growToAdmins(2);
        // Removal leaves the reverse index in place, so the key is still
        // mapped -- it is liveness, not membership, that it fails on.
        _remove("admin-1", "auth-rm", Eip712.keys(founderPk, rosterPk[1]));
        assertFalse(state.getUser(CLIENT_ID, "admin-1").active);

        bytes memory sig = _onboardingSig(rosterPk[1], "auth-lock");
        vm.expectRevert(CFHelpersUsersv1.InactiveSigner.selector);
        vm.prank(guardEOA);
        users.completeOnboarding(CLIENT_ID, COMPANY, "auth-lock", sig);

        assertFalse(state.onboardingComplete(CLIENT_ID));
    }

    function test_CompleteOnboarding_RevertsUnauthorizedCallerForAnUnmappedKey()
        public
    {
        // A key this client has never seen is not a bad signer, it is a
        // stranger -- the same error `addUser` gives for the same thing.
        bytes memory sig = _onboardingSig(outsiderPk, "auth-lock");
        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        vm.prank(guardEOA);
        users.completeOnboarding(CLIENT_ID, COMPANY, "auth-lock", sig);

        assertFalse(state.onboardingComplete(CLIENT_ID));
    }

    function test_CompleteOnboarding_RevertsInvalidCompany() public {
        // Acme's storage key, Globex's name. Locking the wrong client's phase
        // is exactly the mistake the binding is there to catch.
        bytes memory sig = _onboardingSig(founderPk, "auth-lock");
        vm.expectRevert(CFHelpersUsersv1.InvalidCompany.selector);
        vm.prank(guardEOA);
        users.completeOnboarding(CLIENT_ID, OTHER_COMPANY, "auth-lock", sig);

        assertFalse(state.onboardingComplete(CLIENT_ID));
    }

    function test_CompleteOnboarding_RevertsInvalidParamsOnEmptyAuthId()
        public
    {
        bytes memory sig = _onboardingSig(founderPk, "");
        vm.expectRevert(CFHelpersUsersv1.InvalidParams.selector);
        vm.prank(guardEOA);
        users.completeOnboarding(CLIENT_ID, COMPANY, "", sig);
    }

    function test_CompleteOnboarding_RevertsInvalidSignatureOnGarbage()
        public
    {
        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        vm.prank(guardEOA);
        users.completeOnboarding(
            CLIENT_ID,
            COMPANY,
            "auth-lock",
            hex"deadbeef"
        );
    }

    function test_CompleteOnboarding_RevertsOnAReplayedAuthId() public {
        _lock(guardEOA, founderPk, "auth-lock");

        // The authId is spent before the flag is written, so a replay is
        // KeyExists rather than OnboardingAlreadyComplete.
        bytes memory sig = _onboardingSig(founderPk, "auth-lock");
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        vm.prank(guardEOA);
        users.completeOnboarding(CLIENT_ID, COMPANY, "auth-lock", sig);
    }

    function test_CompleteOnboarding_AuthIdSharesTheUsersHelperStore() public {
        _registerMember();
        _remove("m1", "shared-auth", Eip712.keys(founderPk));

        // One replay store per (client, helper): an authId spent removing a
        // member cannot be spent again locking the phase.
        bytes memory sig = _onboardingSig(founderPk, "shared-auth");
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        vm.prank(guardEOA);
        users.completeOnboarding(CLIENT_ID, COMPANY, "shared-auth", sig);
    }

    function test_CompleteOnboarding_RevertsOnASecondLock() public {
        _lock(guardEOA, founderPk, "auth-lock-1");

        // A FRESH authId, so the replay store is not what refuses this: the
        // lock is irreversible and State is what says so.
        bytes memory sig = _onboardingSig(founderPk, "auth-lock-2");
        vm.expectRevert(CFHelpersStatev1.OnboardingAlreadyComplete.selector);
        vm.prank(guardEOA);
        users.completeOnboarding(CLIENT_ID, COMPANY, "auth-lock-2", sig);

        assertTrue(state.onboardingComplete(CLIENT_ID));
    }

    function test_CompleteOnboarding_RevertsForAClientThatDoesNotExist()
        public
    {
        // Globex was never created, so it has no admins and no key can bind to
        // it. The admin binding refuses it before State's own `InvalidClient`
        // is reached -- which is why that check is now defensive rather than
        // reachable through this helper (the State suite still covers it).
        bytes memory sig = Eip712.signCompleteOnboarding(
            founderPk,
            Eip712.domainSeparator(address(state)),
            OTHER_COMPANY,
            "auth-lock"
        );
        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        vm.prank(guardEOA);
        users.completeOnboarding(
            OTHER_CLIENT_ID,
            OTHER_COMPANY,
            "auth-lock",
            sig
        );
    }

    function test_CompleteOnboarding_DigestMatchesALocallyComputedOne()
        public
        view
    {
        assertEq(
            users.completeOnboardingDigest(COMPANY, "auth-parity"),
            Eip712.digest(
                Eip712.domainSeparator(address(state)),
                Eip712.hashStruct(
                    Eip712.CompleteOnboarding({
                        company: COMPANY,
                        authId: "auth-parity"
                    })
                )
            )
        );
        assertEq(
            users.COMPLETE_ONBOARDING_TYPEHASH(),
            keccak256("CompleteOnboarding(string company,string authId)")
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                        the window (§4.3)
    // ══════════════════════════════════════════════════════════════════

    function test_AddUser_RevertsInviteExpiredOnAPastWindow() public {
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        a.expiresAt = block.timestamp - 1;
        vm.expectRevert(CFHelpersUsersv1.InviteExpired.selector);
        _addUser(a, founderPk, _noKeys(), member, memberPk);
    }

    function test_AddUser_SucceedsExactlyAtExpiry() public {
        // Both bounds are inclusive: a seat may be taken in the second it dies.
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        a.expiresAt = block.timestamp;
        _addUser(a, founderPk, _noKeys(), member, memberPk);
        assertEq(state.getUser(CLIENT_ID, "m1").addr, member);
    }

    function test_AddUser_SucceedsExactlyAtTheCap() public {
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        a.expiresAt = block.timestamp + 30 days;
        _addUser(a, founderPk, _noKeys(), member, memberPk);
        assertEq(state.getUser(CLIENT_ID, "m1").addr, member);
    }

    function test_AddUser_RevertsInvalidParamsBeyondTheCap() public {
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        a.expiresAt = block.timestamp + 30 days + 1;
        vm.expectRevert(CFHelpersUsersv1.InvalidParams.selector);
        _addUser(a, founderPk, _noKeys(), member, memberPk);
    }

    function test_AddUser_RevertsInviteExpiredWhenTheWindowPassesBeforeRelay()
        public
    {
        // The admin authorized a real window; the member took too long.
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        vm.warp(a.expiresAt + 1);
        vm.expectRevert(CFHelpersUsersv1.InviteExpired.selector);
        _addUser(a, founderPk, _noKeys(), member, memberPk);
    }

    function _createClientAt(
        uint256 expiresAt
    ) internal returns (string memory authId, bytes32 d) {
        authId = _auth();
        d = _inviteDigest(
            CFHelpersUsersv1.AddUserArgs({
                clientId: OTHER_CLIENT_ID,
                company: OTHER_COMPANY,
                callerId: FOUNDER_ID,
                userId: FOUNDER_ID,
                isAdmin: true,
                userPosition: "admin",
                expiresAt: expiresAt,
                authId: authId
            })
        );
    }

    function test_CreateClient_RevertsInviteExpiredOnAPastWindow() public {
        uint256 expiresAt = block.timestamp - 1;
        (string memory authId, bytes32 d) = _createClientAt(expiresAt);
        bytes memory sig = Eip712.sign(adminBPk, d);

        vm.expectRevert(CFHelpersUsersv1.InviteExpired.selector);
        vm.prank(guardEOA);
        users.createClient(
            OTHER_CLIENT_ID,
            OTHER_COMPANY,
            FOUNDER_ID,
            adminB,
            TIER,
            expiresAt,
            authId,
            sig
        );
    }

    function test_CreateClient_RevertsInvalidParamsBeyondTheCap() public {
        uint256 expiresAt = block.timestamp + 30 days + 1;
        (string memory authId, bytes32 d) = _createClientAt(expiresAt);
        bytes memory sig = Eip712.sign(adminBPk, d);

        vm.expectRevert(CFHelpersUsersv1.InvalidParams.selector);
        vm.prank(guardEOA);
        users.createClient(
            OTHER_CLIENT_ID,
            OTHER_COMPANY,
            FOUNDER_ID,
            adminB,
            TIER,
            expiresAt,
            authId,
            sig
        );
    }

    function test_CreateClient_SucceedsExactlyAtTheCap() public {
        uint256 expiresAt = block.timestamp + 30 days;
        (string memory authId, bytes32 d) = _createClientAt(expiresAt);

        vm.prank(guardEOA);
        users.createClient(
            OTHER_CLIENT_ID,
            OTHER_COMPANY,
            FOUNDER_ID,
            adminB,
            TIER,
            expiresAt,
            authId,
            Eip712.sign(adminBPk, d)
        );
        assertEq(state.getUser(OTHER_CLIENT_ID, FOUNDER_ID).addr, adminB);
    }

    // ══════════════════════════════════════════════════════════════════
    //                     createClient -- the founder
    // ══════════════════════════════════════════════════════════════════

    function test_CreateClient_RevertsInvalidSignatureFromAnotherKey() public {
        uint256 expiresAt = _defaultExpiry();
        (string memory authId, bytes32 d) = _createClientAt(expiresAt);
        bytes memory wrong = Eip712.sign(outsiderPk, d);

        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        vm.prank(guardEOA);
        users.createClient(
            OTHER_CLIENT_ID,
            OTHER_COMPANY,
            FOUNDER_ID,
            adminB, // the named founder ...
            TIER,
            expiresAt,
            authId,
            wrong // ... but somebody else signed
        );
    }

    function test_CreateClient_RevertsInvalidParamsOnAZeroFounder() public {
        uint256 expiresAt = _defaultExpiry();
        (string memory authId, bytes32 d) = _createClientAt(expiresAt);
        bytes memory sig = Eip712.sign(adminBPk, d);

        vm.expectRevert(CFHelpersUsersv1.InvalidParams.selector);
        vm.prank(guardEOA);
        users.createClient(
            OTHER_CLIENT_ID,
            OTHER_COMPANY,
            FOUNDER_ID,
            address(0),
            TIER,
            expiresAt,
            authId,
            sig
        );
    }

    function test_CreateClient_RevertsInvalidCompany() public {
        uint256 expiresAt = _defaultExpiry();
        (string memory authId, bytes32 d) = _createClientAt(expiresAt);
        bytes memory sig = Eip712.sign(adminBPk, d);

        vm.expectRevert(CFHelpersUsersv1.InvalidCompany.selector);
        vm.prank(guardEOA);
        users.createClient(
            CLIENT_ID, // Acme's key ...
            OTHER_COMPANY, // ... Globex's name
            FOUNDER_ID,
            adminB,
            TIER,
            expiresAt,
            authId,
            sig
        );
    }

    function test_CreateClient_RevertsInvalidParamsOnEmptyAuthId() public {
        uint256 expiresAt = _defaultExpiry();
        bytes32 d = _inviteDigest(
            CFHelpersUsersv1.AddUserArgs({
                clientId: OTHER_CLIENT_ID,
                company: OTHER_COMPANY,
                callerId: FOUNDER_ID,
                userId: FOUNDER_ID,
                isAdmin: true,
                userPosition: "admin",
                expiresAt: expiresAt,
                authId: ""
            })
        );
        bytes memory sig = Eip712.sign(adminBPk, d);

        vm.expectRevert(CFHelpersUsersv1.InvalidParams.selector);
        vm.prank(guardEOA);
        users.createClient(
            OTHER_CLIENT_ID,
            OTHER_COMPANY,
            FOUNDER_ID,
            adminB,
            TIER,
            expiresAt,
            "",
            sig
        );
    }

    function test_CreateClient_RevertsClientExistsOnASecondCall() public {
        vm.expectRevert(CFHelpersStatev1.ClientExists.selector);
        _createClient(guardEOA, CLIENT_ID, COMPANY, adminB, adminBPk);
    }

    // ══════════════════════════════════════════════════════════════════
    //                      addUser -- admin binding
    // ══════════════════════════════════════════════════════════════════

    function test_AddUser_SeatsAMember() public {
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );

        vm.expectEmit(true, false, false, true, address(state));
        emit CFHelpersStatev1.UserAdded(CLIENT_ID, "m1", member);
        _addUser(a, founderPk, _noKeys(), member, memberPk);

        CFHelpersStatev1.User memory u = state.getUser(CLIENT_ID, "m1");
        assertEq(u.addr, member);
        assertEq(u.position, "engineer");
        assertFalse(u.isAdmin);
        assertTrue(u.active);
        assertEq(state.getUserIdByAddress(member, CLIENT_ID), "m1");
        assertEq(state.getActiveAdmins(CLIENT_ID), 1);
    }

    function test_AddUser_RevertsUnauthorizedCallerForAStrangerSignature()
        public
    {
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        _addUser(a, outsiderPk, _noKeys(), member, memberPk);
    }

    function test_AddUser_RevertsUnauthorizedCallerOnAWrongCallerId() public {
        _registerMember();
        // The founder signs, but claims to be "m1".
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            "m1",
            "m2",
            false,
            "engineer"
        );
        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        _addUser(a, founderPk, _noKeys(), invitee, inviteePk);
    }

    function test_AddUser_RevertsInvalidSignerForARegisteredNonAdmin() public {
        _registerMember();
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            "m1",
            "m2",
            false,
            "engineer"
        );
        vm.expectRevert(CFHelpersUsersv1.InvalidSigner.selector);
        _addUser(a, memberPk, _noKeys(), invitee, inviteePk);
    }

    function test_AddUser_RevertsInactiveSignerForARemovedAdmin() public {
        _growToAdmins(2);
        // Unseat adminB; their address still resolves to "admin-1".
        _remove("admin-1", _auth(), Eip712.keys(founderPk, adminBPk));
        assertFalse(state.getUser(CLIENT_ID, "admin-1").active);
        assertEq(state.getUserIdByAddress(adminB, CLIENT_ID), "admin-1");

        CFHelpersUsersv1.AddUserArgs memory a = _args(
            "admin-1",
            "m1",
            false,
            "engineer"
        );
        vm.expectRevert(CFHelpersUsersv1.InactiveSigner.selector);
        _addUser(a, adminBPk, _noKeys(), member, memberPk);
    }

    function test_AddUser_RevertsInvalidCompany() public {
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        a.company = OTHER_COMPANY; // clientId still Acme's
        vm.expectRevert(CFHelpersUsersv1.InvalidCompany.selector);
        _addUser(a, founderPk, _noKeys(), member, memberPk);
    }

    function test_AddUser_RevertsInvalidParamsOnEmptyAuthId() public {
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        a.authId = "";
        vm.expectRevert(CFHelpersUsersv1.InvalidParams.selector);
        _addUser(a, founderPk, _noKeys(), member, memberPk);
    }

    // ── tamper: every field is inside the admin's signature ──────────────

    /// Submits `tampered` while the admin signed `signed`.
    function _expectTamperRejected(
        CFHelpersUsersv1.AddUserArgs memory signed,
        CFHelpersUsersv1.AddUserArgs memory tampered
    ) internal {
        bytes32 signedDigest = _inviteDigest(signed);
        bytes32 sentDigest = _inviteDigest(tampered);

        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        vm.prank(guardEOA);
        users.addUser(
            tampered,
            Eip712.sign(founderPk, signedDigest),
            Eip712.none(),
            member,
            Eip712.sign(memberPk, sentDigest)
        );
    }

    function test_AddUser_RevertsWhenExpiresAtIsTamperedAfterSigning() public {
        CFHelpersUsersv1.AddUserArgs memory signed = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        CFHelpersUsersv1.AddUserArgs memory tampered = _copy(signed);
        tampered.expiresAt = signed.expiresAt + 1 hours;
        _expectTamperRejected(signed, tampered);
    }

    function test_AddUser_RevertsWhenUserIdIsTamperedAfterSigning() public {
        CFHelpersUsersv1.AddUserArgs memory signed = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        CFHelpersUsersv1.AddUserArgs memory tampered = _copy(signed);
        tampered.userId = "m2";
        _expectTamperRejected(signed, tampered);
    }

    function test_AddUser_RevertsWhenIsAdminIsTamperedAfterSigning() public {
        CFHelpersUsersv1.AddUserArgs memory signed = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        CFHelpersUsersv1.AddUserArgs memory tampered = _copy(signed);
        tampered.isAdmin = true;
        _expectTamperRejected(signed, tampered);
    }

    function test_AddUser_RevertsWhenPositionIsTamperedAfterSigning() public {
        CFHelpersUsersv1.AddUserArgs memory signed = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        CFHelpersUsersv1.AddUserArgs memory tampered = _copy(signed);
        tampered.userPosition = "cfo";
        _expectTamperRejected(signed, tampered);
    }

    // ── the member's key ─────────────────────────────────────────────────

    function test_AddUser_RevertsInvalidSignatureOnAnInviteeMismatch() public {
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        bytes32 d = _inviteDigest(a);

        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        vm.prank(guardEOA);
        users.addUser(
            a,
            Eip712.sign(founderPk, d),
            Eip712.none(),
            member, // the address the platform names ...
            Eip712.sign(inviteePk, d) // ... a different key signed
        );
    }

    function test_AddUser_RevertsInvalidSignatureOnAZeroInvitee() public {
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        bytes32 d = _inviteDigest(a);

        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        vm.prank(guardEOA);
        users.addUser(
            a,
            Eip712.sign(founderPk, d),
            Eip712.none(),
            address(0),
            Eip712.sign(memberPk, d)
        );
    }

    function test_AddUser_RevertsWhenTheMemberSignedADifferentSeat() public {
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        CFHelpersUsersv1.AddUserArgs memory other = _copy(a);
        other.userId = "m2";

        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        vm.prank(guardEOA);
        users.addUser(
            a,
            Eip712.sign(founderPk, _inviteDigest(a)),
            Eip712.none(),
            member,
            Eip712.sign(memberPk, _inviteDigest(other))
        );
    }

    // ── replay and State's own invariants ────────────────────────────────

    function test_AddUser_AuthIdIsSingleUse() public {
        CFHelpersUsersv1.AddUserArgs memory first = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        _addUser(first, founderPk, _noKeys(), member, memberPk);

        CFHelpersUsersv1.AddUserArgs memory second = _copy(first);
        second.userId = "m2";
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        _addUser(second, founderPk, _noKeys(), invitee, inviteePk);
    }

    function test_AddUser_RevertsUserExistsOnADuplicateUserId() public {
        _registerMember();
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m1",
            false,
            "engineer"
        );
        vm.expectRevert(CFHelpersStatev1.UserExists.selector);
        _addUser(a, founderPk, _noKeys(), invitee, inviteePk);
    }

    function test_AddUser_RevertsAddressExistsOnADuplicateAddress() public {
        _registerMember();
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "m2",
            false,
            "engineer"
        );
        vm.expectRevert(CFHelpersStatev1.AddressExists.selector);
        _addUser(a, founderPk, _noKeys(), member, memberPk);
    }

    // ══════════════════════════════════════════════════════════════════
    //                            digest parity
    // ══════════════════════════════════════════════════════════════════

    function test_InviteDigest_MatchesALocallyComputedDigest() public view {
        CFHelpersUsersv1.AddUserArgs memory a = CFHelpersUsersv1.AddUserArgs({
            clientId: CLIENT_ID,
            company: COMPANY,
            callerId: FOUNDER_ID,
            userId: "m1",
            isAdmin: false,
            userPosition: "engineer",
            expiresAt: 1_800_000_000,
            authId: "auth-parity"
        });

        assertEq(
            users.inviteDigest(
                a.company,
                a.callerId,
                a.userId,
                a.isAdmin,
                a.userPosition,
                a.expiresAt,
                a.authId
            ),
            _inviteDigest(a)
        );
        assertEq(users.INVITE_TYPEHASH(), INVITE_USER_TYPEHASH_R3);
    }

    // ══════════════════════════════════════════════════════════════════
    //                      the removed surface
    // ══════════════════════════════════════════════════════════════════

    function test_RemovedSurface_TheInviteTrioIsGone() public view {
        bytes4[3] memory gone = [
            bytes4(
                keccak256(
                    "inviteUser(bytes32,string,string,string,bool,string,bytes32,uint256,string,bytes,bytes[])"
                )
            ),
            bytes4(
                keccak256(
                    "completeInvite(bytes32,string,bytes32,uint256,string,string,address,bytes)"
                )
            ),
            bytes4(
                keccak256(
                    "inviteAndCompleteUser(bytes32,string,string,string,bool,string,bytes32,uint256,string,bytes,bytes[],uint256,address,bytes)"
                )
            )
        ];

        bytes memory code = address(users).code;
        for (uint256 i = 0; i < gone.length; i++) {
            assertFalse(
                _codeContains(code, gone[i]),
                "an old invite selector is still routable"
            );
        }
        // The scan itself works: a selector that IS there is found.
        assertTrue(_codeContains(code, users.addUser.selector));
        assertTrue(_codeContains(code, users.createClient.selector));
    }

    /// Searches the runtime bytecode for the 4-byte dispatcher constant.
    function _codeContains(
        bytes memory code,
        bytes4 selector
    ) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= code.length; i++) {
            if (
                code[i] == selector[0] &&
                code[i + 1] == selector[1] &&
                code[i + 2] == selector[2] &&
                code[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    // ══════════════════════════════════════════════════════════════════
    //      the onboarding phase -- admin seats skip the ceremony (§4.3)
    // ══════════════════════════════════════════════════════════════════
    //
    // Round 5. While `state.onboardingComplete(clientId)` is false, an admin
    // seat takes ONE signature -- the inviting admin's own -- whatever the
    // roster looks like. The product seats the co-admins during onboarding,
    // and under the ceremony alone the founder inviting the team one seat at
    // a time would need each new admin to come back and co-sign the next.
    //
    // This widens nothing. The phase ALREADY lets a single admin activate any
    // policy alone (Policies, round 4), so an admin who can spend the vault by
    // themselves gains no new power by seating a co-admin by themselves. What
    // the phase lowers is the COUNT, never the checks: the tests below pin a
    // co-signature supplied during the phase to the same recovery and
    // active-admin rules it faces after the lock.

    function test_Onboarding_RequiredSigsIsOneWhateverTheRoster() public {
        assertEq(users.requiredAdminInviteSignatures(CLIENT_ID), 1);

        _growToAdmins(3);
        assertEq(state.getActiveAdmins(CLIENT_ID), 3);
        // The ceremony would answer 2 here.
        assertEq(users.requiredAdminInviteSignatures(CLIENT_ID), 1);

        _growToAdmins(4);
        assertEq(state.getActiveAdmins(CLIENT_ID), 4);
        // ...and 3 here.
        assertEq(users.requiredAdminInviteSignatures(CLIENT_ID), 1);
    }

    function test_Onboarding_ThreeAdminsSeatAFourthOnTheInviterAlone() public {
        _growToAdmins(3);
        assertEq(state.getActiveAdmins(CLIENT_ID), 3);

        // After the lock this exact call is `ThresholdNotMet` -- see
        // `test_Consensus_RevertsThresholdNotMetWithoutACoSignature`.
        _seat("admin-x", true, adminD, adminDPk, _noKeys());

        assertEq(state.getActiveAdmins(CLIENT_ID), 4);
        assertTrue(state.getUser(CLIENT_ID, "admin-x").isAdmin);
    }

    function test_Onboarding_AndAFifthOnTheInviterAlone() public {
        _growToAdmins(3);
        _seat("admin-x", true, adminD, adminDPk, _noKeys());
        assertEq(state.getActiveAdmins(CLIENT_ID), 4);

        // Still one signature at four admins, where the ceremony wants three.
        // The admin pool is spent, so the fifth seat borrows the spare key.
        _seat("admin-y", true, invitee, inviteePk, _noKeys());

        assertEq(state.getActiveAdmins(CLIENT_ID), 5);
        assertTrue(state.getUser(CLIENT_ID, "admin-y").isAdmin);
    }

    function test_Onboarding_AValidCoSignatureIsStillAccepted() public {
        _growToAdmins(3);
        // Supplying one anyway is fine: it is verified and counted, and the
        // seat needed none of it.
        _seat("admin-x", true, adminD, adminDPk, Eip712.keys(rosterPk[1]));
        assertEq(state.getActiveAdmins(CLIENT_ID), 4);
    }

    function test_Onboarding_ANonAdminCoSignerIsStillRejected() public {
        _growToAdmins(3);
        _registerMember();

        // The phase lowers the required count to one; it does not stop the
        // helper from checking what it is handed. This seat would have gone
        // through with no co-signature at all -- a bad one still sinks it.
        vm.expectRevert(CFHelpersUsersv1.InvalidSigner.selector);
        _seat("admin-x", true, adminD, adminDPk, Eip712.keys(memberPk));
    }

    function test_Onboarding_AnUnregisteredCoSignerIsStillRejected() public {
        _growToAdmins(3);
        vm.expectRevert(CFHelpersUsersv1.InvalidSigner.selector);
        _seat("admin-x", true, adminD, adminDPk, Eip712.keys(outsiderPk));
    }

    function test_Onboarding_TheLockRaisesTheBarOnTheSameRoster() public {
        _growToAdmins(3);
        assertEq(users.requiredAdminInviteSignatures(CLIENT_ID), 1);

        _lockOnboarding();

        // Same three admins, a different rule.
        assertEq(state.getActiveAdmins(CLIENT_ID), 3);
        assertEq(users.requiredAdminInviteSignatures(CLIENT_ID), 2);
    }

    // ══════════════════════════════════════════════════════════════════
    //   admin-seat consensus (all active admins but one), after the lock
    // ══════════════════════════════════════════════════════════════════
    //
    // Every test here opens with `_lockOnboarding()` on purpose: it is the
    // post-onboarding ceremony they assert, and a fresh client's phase is
    // open, where one signature seats any admin (see the section above).

    function test_RequiredAdminInviteSignatures_Is1Then1Then2Then3() public {
        _lockOnboarding();

        assertEq(state.getActiveAdmins(CLIENT_ID), 1);
        assertEq(users.requiredAdminInviteSignatures(CLIENT_ID), 1);

        _growToAdmins(2);
        assertEq(state.getActiveAdmins(CLIENT_ID), 2);
        assertEq(users.requiredAdminInviteSignatures(CLIENT_ID), 1);

        _growToAdmins(3);
        assertEq(state.getActiveAdmins(CLIENT_ID), 3);
        assertEq(users.requiredAdminInviteSignatures(CLIENT_ID), 2);

        _growToAdmins(4);
        assertEq(state.getActiveAdmins(CLIENT_ID), 4);
        assertEq(users.requiredAdminInviteSignatures(CLIENT_ID), 3);
    }

    function test_Consensus_SoloFounderSeatsAnAdminAlone() public {
        _lockOnboarding();
        _seat("admin-1", true, adminB, adminBPk, _noKeys());
        assertEq(state.getActiveAdmins(CLIENT_ID), 2);
        assertTrue(state.getUser(CLIENT_ID, "admin-1").isAdmin);
    }

    function test_Consensus_OneOfTwoAdminsSeatsAThirdAlone() public {
        _lockOnboarding();
        _growToAdmins(2);
        _seat("admin-x", true, adminC, adminCPk, _noKeys());
        assertEq(state.getActiveAdmins(CLIENT_ID), 3);
    }

    function test_Consensus_ThreeAdminsNeedOneCoSignature() public {
        _lockOnboarding();
        _growToAdmins(3);
        _seat("admin-x", true, adminD, adminDPk, Eip712.keys(rosterPk[1]));
        assertEq(state.getActiveAdmins(CLIENT_ID), 4);
    }

    function test_Consensus_RevertsThresholdNotMetWithoutACoSignature()
        public
    {
        _lockOnboarding();
        _growToAdmins(3);
        vm.expectRevert(CFHelpersUsersv1.ThresholdNotMet.selector);
        _seat("admin-x", true, adminD, adminDPk, _noKeys());
    }

    function test_Consensus_MemberSeatsAreUntouched() public {
        _lockOnboarding();
        _growToAdmins(3);
        _seat("m1", false, member, memberPk, _noKeys());
        assertEq(state.getActiveAdmins(CLIENT_ID), 3);
        assertEq(state.getUser(CLIENT_ID, "m1").addr, member);
    }

    function test_Consensus_RevertsInvalidSignerForANonAdminCoSigner() public {
        _lockOnboarding();
        _growToAdmins(3);
        _registerMember();
        vm.expectRevert(CFHelpersUsersv1.InvalidSigner.selector);
        _seat("admin-x", true, adminD, adminDPk, Eip712.keys(memberPk));
    }

    function test_Consensus_RevertsInvalidSignerForAnUnregisteredCoSigner()
        public
    {
        _lockOnboarding();
        _growToAdmins(3);
        vm.expectRevert(CFHelpersUsersv1.InvalidSigner.selector);
        _seat("admin-x", true, adminD, adminDPk, Eip712.keys(outsiderPk));
    }

    function test_Consensus_RevertsInvalidSignatureWhenInviterCoSignsOwn()
        public
    {
        _lockOnboarding();
        _growToAdmins(3);
        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        _seat("admin-x", true, adminD, adminDPk, Eip712.keys(founderPk));
    }

    function test_Consensus_RevertsInvalidSignatureOnUnsortedCoSignatures()
        public
    {
        _lockOnboarding();
        _growToAdmins(4);
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "admin-x",
            true,
            "admin"
        );
        bytes32 d = _inviteDigest(a);
        bytes[] memory sorted = Eip712.sign(
            Eip712.keys(rosterPk[1], rosterPk[2]),
            d
        );
        bytes[] memory reversed = new bytes[](2);
        reversed[0] = sorted[1];
        reversed[1] = sorted[0];

        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        vm.prank(guardEOA);
        users.addUser(
            a,
            Eip712.sign(founderPk, d),
            reversed,
            invitee,
            Eip712.sign(inviteePk, d)
        );
    }

    function test_Consensus_RevertsInvalidSignatureWhenOneAdminCoSignsTwice()
        public
    {
        _lockOnboarding();
        _growToAdmins(4);
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "admin-x",
            true,
            "admin"
        );
        bytes32 d = _inviteDigest(a);
        bytes[] memory twice = new bytes[](2);
        twice[0] = Eip712.sign(rosterPk[1], d);
        twice[1] = twice[0];

        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        vm.prank(guardEOA);
        users.addUser(
            a,
            Eip712.sign(founderPk, d),
            twice,
            invitee,
            Eip712.sign(inviteePk, d)
        );
    }

    function test_Consensus_RejectsACoSignatureForADifferentSeat() public {
        _lockOnboarding();
        _growToAdmins(3);
        CFHelpersUsersv1.AddUserArgs memory a = _args(
            FOUNDER_ID,
            "admin-x",
            true,
            "admin"
        );
        CFHelpersUsersv1.AddUserArgs memory other = _copy(a);
        other.userId = "someone-else";

        bytes32 d = _inviteDigest(a);
        vm.expectRevert(CFHelpersUsersv1.InvalidSigner.selector);
        vm.prank(guardEOA);
        users.addUser(
            a,
            Eip712.sign(founderPk, d),
            Eip712.sign(Eip712.keys(rosterPk[1]), _inviteDigest(other)),
            adminD,
            Eip712.sign(adminDPk, d)
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                              removeUser
    // ══════════════════════════════════════════════════════════════════

    function _remove(
        string memory removedUserId,
        string memory authId,
        uint256[] memory pks
    ) internal {
        vm.prank(guardEOA);
        users.removeUser(
            CLIENT_ID,
            COMPANY,
            removedUserId,
            authId,
            Eip712.sign(pks, _removeDigest(removedUserId, authId))
        );
    }

    function test_RemoveUser_OneAdminRemovesAMemberAndIsNamedTheActor()
        public
    {
        _registerMember();

        vm.expectEmit(true, false, false, true, address(state));
        emit CFHelpersStatev1.UserRemoved(CLIENT_ID, FOUNDER_ID, "m1");
        _remove("m1", "auth-rm", Eip712.keys(founderPk));

        assertFalse(state.getUser(CLIENT_ID, "m1").active);
    }

    function test_RemoveUser_AuthIdIsSingleUse() public {
        _registerMember();
        _seat("m2", false, invitee, inviteePk, _noKeys());

        _remove("m1", "shared-auth", Eip712.keys(founderPk));

        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        _remove("m2", "shared-auth", Eip712.keys(founderPk));
    }

    function test_RemoveUser_AnAdminTargetTakesTwoSignatures() public {
        _growToAdmins(3);

        vm.expectRevert(CFHelpersUsersv1.ThresholdNotMet.selector);
        _remove("admin-2", "auth-rm", Eip712.keys(founderPk));

        _remove("admin-2", "auth-rm", Eip712.keys(founderPk, rosterPk[1]));
        assertFalse(state.getUser(CLIENT_ID, "admin-2").active);
        assertEq(state.getActiveAdmins(CLIENT_ID), 2);
    }

    function test_RemoveUser_RevertsInvalidSignerForARegisteredNonAdmin()
        public
    {
        _registerMember();
        vm.expectRevert(CFHelpersUsersv1.InvalidSigner.selector);
        _remove("m1", "auth-rm", Eip712.keys(memberPk));
    }

    function test_RemoveUser_RevertsInvalidSignerForAnUnregisteredSigner()
        public
    {
        _registerMember();
        vm.expectRevert(CFHelpersUsersv1.InvalidSigner.selector);
        _remove("m1", "auth-rm", Eip712.keys(outsiderPk));
    }

    function test_RemoveUser_RevertsInvalidSignatureOnUnsortedSignatures()
        public
    {
        _growToAdmins(3);
        bytes[] memory sorted = Eip712.sign(
            Eip712.keys(founderPk, rosterPk[1]),
            _removeDigest("admin-2", "auth-rm")
        );
        bytes[] memory reversed = new bytes[](2);
        reversed[0] = sorted[1];
        reversed[1] = sorted[0];

        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        vm.prank(guardEOA);
        users.removeUser(CLIENT_ID, COMPANY, "admin-2", "auth-rm", reversed);
    }

    function test_RemoveUser_RevertsInvalidSignatureWhenOneAdminSignsTwice()
        public
    {
        _growToAdmins(3);
        bytes memory one = Eip712.sign(
            rosterPk[1],
            _removeDigest("admin-2", "auth-rm")
        );
        bytes[] memory twice = new bytes[](2);
        twice[0] = one;
        twice[1] = one;

        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        vm.prank(guardEOA);
        users.removeUser(CLIENT_ID, COMPANY, "admin-2", "auth-rm", twice);
    }

    function test_RemoveUser_RevertsThresholdNotMetOnNoSignatures() public {
        _registerMember();
        vm.expectRevert(CFHelpersUsersv1.ThresholdNotMet.selector);
        _remove("m1", "auth-rm", _noKeys());
    }

    function test_RemoveUser_RevertsInvalidParamsOnEmptyAuthId() public {
        _registerMember();
        vm.expectRevert(CFHelpersUsersv1.InvalidParams.selector);
        _remove("m1", "", Eip712.keys(founderPk));
    }

    function test_RemoveUser_RevertsInvalidCompany() public {
        _registerMember();
        vm.expectRevert(CFHelpersUsersv1.InvalidCompany.selector);
        vm.prank(guardEOA);
        users.removeUser(
            CLIENT_ID,
            OTHER_COMPANY,
            "m1",
            "auth-rm",
            Eip712.none()
        );
    }

    /// Remove and rotate are member-authorized, not platform-relayed: they
    /// carry admin signatures and need no sponsor-guard sender.
    function test_RemoveUser_NeedsNoPlatformSender() public {
        _registerMember();
        string memory authId = "auth-rm";
        vm.prank(stranger);
        users.removeUser(
            CLIENT_ID,
            COMPANY,
            "m1",
            authId,
            Eip712.sign(Eip712.keys(founderPk), _removeDigest("m1", authId))
        );
        assertFalse(state.getUser(CLIENT_ID, "m1").active);
    }

    // ══════════════════════════════════════════════════════════════════
    //                              rotateUser
    // ══════════════════════════════════════════════════════════════════

    function _rotate(
        string memory userId,
        address newAddress,
        string memory authId,
        bytes memory currentKeySig,
        bytes memory newKeySig,
        uint256[] memory adminPks
    ) internal {
        vm.prank(guardEOA);
        users.rotateUser(
            CLIENT_ID,
            COMPANY,
            userId,
            newAddress,
            authId,
            currentKeySig,
            newKeySig,
            Eip712.sign(adminPks, _rotateDigest(userId, newAddress, authId))
        );
    }

    function test_RotateUser_SelfPathHandsTheSeatToAKeyThatSignsForItself()
        public
    {
        _registerMember();
        (address newKey, uint256 newPk) = makeAddrAndKey("newKey");
        bytes32 d = _rotateDigest("m1", newKey, "auth-rot");

        vm.expectEmit(true, false, false, true, address(state));
        emit CFHelpersStatev1.UserRotated(CLIENT_ID, "m1", newKey);
        _rotate(
            "m1",
            newKey,
            "auth-rot",
            Eip712.sign(memberPk, d),
            Eip712.sign(newPk, d),
            _noKeys()
        );

        CFHelpersStatev1.User memory u = state.getUser(CLIENT_ID, "m1");
        assertEq(u.addr, newKey);
        assertTrue(u.active);
        assertEq(state.getUserIdByAddress(newKey, CLIENT_ID), "m1");
        assertEq(state.getUserIdByAddress(member, CLIENT_ID), "");
    }

    function test_RotateUser_RecoveryPathWithTwoAdmins() public {
        _growToAdmins(2);
        _registerMember();
        (address newKey, uint256 newPk) = makeAddrAndKey("newKey");
        bytes32 d = _rotateDigest("m1", newKey, "auth-rot");

        _rotate(
            "m1",
            newKey,
            "auth-rot",
            "", // no current key -- that is the point
            Eip712.sign(newPk, d),
            Eip712.keys(founderPk, rosterPk[1])
        );

        assertEq(state.getUserIdByAddress(newKey, CLIENT_ID), "m1");
    }

    function test_RotateUser_RecoveryPathWithASoloAdmin() public {
        _registerMember();
        (address newKey, uint256 newPk) = makeAddrAndKey("newKey");
        bytes32 d = _rotateDigest("m1", newKey, "auth-rot");

        _rotate(
            "m1",
            newKey,
            "auth-rot",
            "",
            Eip712.sign(newPk, d),
            Eip712.keys(founderPk)
        );
        assertEq(state.getUserIdByAddress(newKey, CLIENT_ID), "m1");
    }

    function test_RotateUser_RevertsThresholdNotMetWithTooFewAdmins() public {
        _growToAdmins(2);
        _registerMember();
        (address newKey, uint256 newPk) = makeAddrAndKey("newKey");
        bytes32 d = _rotateDigest("m1", newKey, "auth-rot");

        vm.expectRevert(CFHelpersUsersv1.ThresholdNotMet.selector);
        _rotate(
            "m1",
            newKey,
            "auth-rot",
            "",
            Eip712.sign(newPk, d),
            Eip712.keys(rosterPk[1])
        );
    }

    function test_RotateUser_RevertsInvalidSignerForANonAdminRecoverySigner()
        public
    {
        _registerMember();
        (address newKey, uint256 newPk) = makeAddrAndKey("newKey");
        bytes32 d = _rotateDigest("m1", newKey, "auth-rot");

        vm.expectRevert(CFHelpersUsersv1.InvalidSigner.selector);
        _rotate(
            "m1",
            newKey,
            "auth-rot",
            "",
            Eip712.sign(newPk, d),
            Eip712.keys(outsiderPk)
        );
    }

    function test_RotateUser_RevertsWithoutANewKeySignature() public {
        _registerMember();
        (address newKey, ) = makeAddrAndKey("newKey");
        bytes32 d = _rotateDigest("m1", newKey, "auth-rot");

        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        _rotate(
            "m1",
            newKey,
            "auth-rot",
            Eip712.sign(memberPk, d),
            "",
            _noKeys()
        );
    }

    function test_RotateUser_RevertsWhenTheNewKeySignsForAnotherAddress()
        public
    {
        _registerMember();
        (address newKey, ) = makeAddrAndKey("newKey");
        (, uint256 impostorPk) = makeAddrAndKey("impostor");
        bytes32 d = _rotateDigest("m1", newKey, "auth-rot");

        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        _rotate(
            "m1",
            newKey,
            "auth-rot",
            Eip712.sign(memberPk, d),
            Eip712.sign(impostorPk, d),
            _noKeys()
        );
    }

    function test_RotateUser_RevertsWhenTheCurrentKeyIsNotTheUsers() public {
        // v0 let a self-rotate through on nothing but being the caller. Here
        // the current key must sign the new address it hands over to.
        _registerMember();
        (address newKey, uint256 newPk) = makeAddrAndKey("newKey");
        bytes32 d = _rotateDigest("m1", newKey, "auth-rot");

        vm.expectRevert(CFHelpersUsersv1.InvalidSignature.selector);
        _rotate(
            "m1",
            newKey,
            "auth-rot",
            Eip712.sign(outsiderPk, d),
            Eip712.sign(newPk, d),
            _noKeys()
        );
    }

    function test_RotateUser_RevertsInvalidParamsWhenBothPathsAreSupplied()
        public
    {
        _registerMember();
        (address newKey, uint256 newPk) = makeAddrAndKey("newKey");
        bytes32 d = _rotateDigest("m1", newKey, "auth-rot");

        vm.expectRevert(CFHelpersUsersv1.InvalidParams.selector);
        _rotate(
            "m1",
            newKey,
            "auth-rot",
            Eip712.sign(memberPk, d),
            Eip712.sign(newPk, d),
            Eip712.keys(founderPk)
        );
    }

    function test_RotateUser_RevertsThresholdNotMetWhenNeitherPathIsSupplied()
        public
    {
        _registerMember();
        (address newKey, uint256 newPk) = makeAddrAndKey("newKey");
        bytes32 d = _rotateDigest("m1", newKey, "auth-rot");

        vm.expectRevert(CFHelpersUsersv1.ThresholdNotMet.selector);
        _rotate("m1", newKey, "auth-rot", "", Eip712.sign(newPk, d), _noKeys());
    }

    function test_RotateUser_RevertsInvalidParamsOnEmptyAuthId() public {
        _registerMember();
        (address newKey, uint256 newPk) = makeAddrAndKey("newKey");
        bytes32 d = _rotateDigest("m1", newKey, "");

        vm.expectRevert(CFHelpersUsersv1.InvalidParams.selector);
        _rotate(
            "m1",
            newKey,
            "",
            Eip712.sign(memberPk, d),
            Eip712.sign(newPk, d),
            _noKeys()
        );
    }

    function test_RotateUser_RevertsInvalidCompany() public {
        _registerMember();
        (address newKey, ) = makeAddrAndKey("newKey");
        vm.expectRevert(CFHelpersUsersv1.InvalidCompany.selector);
        vm.prank(guardEOA);
        users.rotateUser(
            CLIENT_ID,
            OTHER_COMPANY,
            "m1",
            newKey,
            "auth-rot",
            "",
            "",
            Eip712.none()
        );
    }

    function test_RotateUser_AuthIdIsSingleUse() public {
        _registerMember();
        (address first, uint256 firstPk) = makeAddrAndKey("firstKey");
        (address second, uint256 secondPk) = makeAddrAndKey("secondKey");

        bytes32 d1 = _rotateDigest("m1", first, "shared-auth");
        _rotate(
            "m1",
            first,
            "shared-auth",
            Eip712.sign(memberPk, d1),
            Eip712.sign(firstPk, d1),
            _noKeys()
        );

        bytes32 d2 = _rotateDigest("m1", second, "shared-auth");
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        _rotate(
            "m1",
            second,
            "shared-auth",
            Eip712.sign(firstPk, d2),
            Eip712.sign(secondPk, d2),
            _noKeys()
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  The shared EIP-712 domain (§4.2, round 6)
    // ══════════════════════════════════════════════════════════════════
    //
    // Every signature in this file is built over
    // `Eip712.domainSeparator(address(state))`, so the happy paths already
    // fail if the helper disagrees. What they cannot show is that the
    // difference matters: a suite and a contract that both used
    // `address(users)` would pass identically. These two pin the domain
    // itself -- the shape State reports, and the refusal of the shape the
    // helper used before round 6.

    /// ERC-5267 in full: fields `0x0f`, `("Cofund", "1", chainId, State)`,
    /// no salt, no extensions. State's address is the one a Ledger descriptor
    /// registers per chain, and it is deliberately NOT this helper's -- that
    /// is what lets an unspent authorization survive a
    /// `setHelperContract("users", ...)` swap (§4.4).
    function test_Eip712DomainReportsTheSharedCofundDomain() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = users.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "Cofund");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(state));
        assertTrue(verifyingContract != address(users));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    /// A removal signed under the OLD per-helper shape
    /// (`("Cofund Users", "1", chainId, users)`) recovers a stranger, so the
    /// signer check refuses it -- `InvalidSigner`, the same answer an
    /// outsider's signature gets, because to the helper that is what it is.
    /// The identical payload under the shared domain goes through, so the
    /// `verifyingContract` is the only thing that changed.
    function test_RemoveUser_RevertsForASignatureUnderTheHelperAddressDomain()
        public
    {
        _registerMember();

        bytes32 legacyDomain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("Cofund Users")),
                keccak256(bytes("1")),
                block.chainid,
                address(users) // the pre-round-6 verifying contract
            )
        );
        bytes32 structHash = Eip712.hashStruct(
            Eip712.RemoveUser({
                company: COMPANY,
                removedUserId: "m1",
                authId: "auth-legacy-domain"
            })
        );

        uint256[] memory signer = new uint256[](1);
        signer[0] = founderPk;

        vm.expectRevert(CFHelpersUsersv1.InvalidSigner.selector);
        vm.prank(guardEOA);
        users.removeUser(
            CLIENT_ID,
            COMPANY,
            "m1",
            "auth-legacy-domain",
            Eip712.sign(signer, Eip712.digest(legacyDomain, structHash))
        );

        vm.prank(guardEOA);
        users.removeUser(
            CLIENT_ID,
            COMPANY,
            "m1",
            "auth-legacy-domain",
            Eip712.sign(
                signer,
                Eip712.digest(
                    Eip712.domainSeparator(address(state)),
                    structHash
                )
            )
        );
        assertFalse(state.getUser(CLIENT_ID, "m1").active);
    }
}
