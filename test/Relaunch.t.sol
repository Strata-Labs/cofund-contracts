// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DeployCore} from "../script/DeployCore.s.sol";
import {Eip712} from "./utils/Eip712.sol";

import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {CFHelpersGovv1} from "../contracts/CFHelpersGovv1.sol";
import {CFHelpersPoliciesv1} from "../contracts/CFHelpersPoliciesv1.sol";
import {CFHelpersUsersv1} from "../contracts/CFHelpersUsersv1.sol";
import {CFHelpersVaultFactoryv1} from "../contracts/CFHelpersVaultFactoryv1.sol";
import {CFHelpersVaultTemplatev1} from "../contracts/CFHelpersVaultTemplatev1.sol";
import {CFSponsorGuardv1} from "../contracts/CFSponsorGuardv1.sol";
import {MockDeFi} from "../contracts/MockDeFi.sol";
import {MockToken} from "../contracts/MockToken.sol";
import {MockWrapper} from "../contracts/MockWrapper.sol";

/// @title  Relaunch -- the v1 stack end to end, through the sponsor relay.
///
/// @notice The acceptance suite for `docs/v1-relaunch-design.md`. Every other
///         `.t.sol` drives one contract with the rest stubbed out as EOAs; this
///         one deploys the real six, wires them with the real deploy script,
///         and pushes a client from "does not exist" to "moves money" using
///         only what the webapp will actually send: `vm.prank(sponsor);
///         guard.relay(target, calldata)`, with EIP-712 signatures as the sole
///         authorization.
///
/// @dev    Three things make this the acceptance test rather than a twelfth
///         unit suite:
///
///         1. **The deploy script is the fixture.** `setUp` calls
///            `DeployCore.deploy` -- the same function `run` broadcasts -- so a
///            wiring mistake in the script fails here rather than on a chain.
///            The test inherits `DeployCore` so that the script's calls to
///            State and Gov originate from the test contract and
///            `vm.startPrank(cofundAdmin)` reaches them; a prank does not
///            follow an external call into another contract.
///         2. **Rotation and removal are proved at the point of execution**
///            (§2, §3.3), not at the point of registration: the same policy,
///            untouched and byte-identical, accepts the new key and refuses the
///            old one on the very next transfer.
///         3. **Onboarding is one call per seat** (§1, §4.4). An invite is the
///            admin's signed `InviteUser` authorization, spent by the member in
///            a single platform-relayed `addUser` that also carries the
///            member's own signature over the same digest. There is no invite
///            code, no pending invite on chain, and no completion step -- so
///            "half-onboarded" is not a state this suite can reach.
///         4. **The client passes through the onboarding phase** (§4.3, rounds
///            4 and 5). `setUp` walks the real order: found the client, seat
///            the members, seat the co-admins on the founder's signature alone
///            -- which only the open phase allows from the fourth admin on --
///            stand the first policy up on ONE admin signature, likewise, and
///            then relay an admin-signed `completeOnboarding`, after which
///            both bars are back under the standing consensus rules.
///            Section 14 pins both halves; everything below `setUp` runs with
///            the phase locked. The lock is the client's own to give: one
///            active admin signs `CompleteOnboarding` and anybody may
///            broadcast it.
///
///         Conventions: the Cofund admin (`cofundAdmin`) is the deployment's
///         privileged key and State's initial fee recipient; Acme's founder
///         (`adminAddr`, userId `"admin"`) is a client user and has no Cofund
///         privilege whatsoever. Signature arrays are ascending by recovered
///         address, which is every multi-signature surface's uniqueness check.
///         Calldata for a reverting call is always built into a local BEFORE
///         `vm.expectRevert`: `sha256` is a precompile, and a staticcall to it
///         would satisfy the expectation instead of the call under test.
contract RelaunchTest is Test, DeployCore {
    /* ═══════════════════════════  fixture constants  ══════════════════════ */

    string internal constant COMPANY = "Acme";
    string internal constant TIER = "FREE";

    string internal constant POLICY_TYPE = "Operational_Expense";
    string internal constant POLICY_TITLE = "Operations";
    string internal constant OPS_POLICY = "ops";
    string internal constant ALLOWLIST_POLICY = "ops-allowlist";
    uint256 internal constant MAX_AMOUNT = 1_000_000e18;

    string internal constant TX_POLICY_TYPE = "Treasury_Management";
    string internal constant TX_POLICY_TITLE = "Treasury";
    string internal constant TX_POLICY = "treasury";
    string internal constant TX_FUNC = "mint-token";

    /// @dev The authId spent adding alice; re-spent in the replay test.
    string internal constant AUTH_ADD_ALICE = "add-alice";

    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    /* ═══════════════════════════════  actors  ════════════════════════════ */

    address internal cofundAdmin; // the deploying Ledger; State's fee recipient
    address internal sponsor; // the webapp's 4337 account
    address internal attacker;
    address internal outsider; // an EOA with no relationship to the client
    address internal r1;
    address internal r2;

    address internal adminAddr;
    uint256 internal adminKey;
    address internal alice;
    uint256 internal aliceKey;
    address internal aliceNew;
    uint256 internal aliceNewKey;
    address internal bob;
    uint256 internal bobKey;
    address internal carol;
    uint256 internal carolKey;
    address internal dana;
    uint256 internal danaKey;
    address internal erin;
    uint256 internal erinKey;
    address internal frank;
    uint256 internal frankKey;

    /* ═════════════════════════  system under test  ═══════════════════════ */

    CFHelpersStatev1 internal state;
    CFHelpersGovv1 internal gov;
    CFHelpersPoliciesv1 internal policies;
    CFHelpersUsersv1 internal users;
    CFHelpersVaultFactoryv1 internal factory;
    CFSponsorGuardv1 internal guard;
    CFHelpersVaultTemplatev1 internal vault;

    MockToken internal token;
    MockDeFi internal defi;
    MockWrapper internal wrapper;

    bytes32 internal clientId;
    bytes32 internal dsUsers;
    bytes32 internal dsPolicies;
    bytes32 internal dsVault;

    uint256 internal founderExpiresAt;

    /// @dev `requiredPolicyActivationSignatures` as it stood in `setUp`, with
    ///      two admins seated and the onboarding phase still open. Captured
    ///      there because the phase is locked before `setUp` returns, so a
    ///      test cannot read it back -- and asserting it beats relying on the
    ///      one-signature activation merely not having reverted.
    uint256 internal onboardingActivationBar;

    /// @dev `requiredAdminInviteSignatures` as it stood in `setUp` with THREE
    ///      admins seated and the phase still open (round 5). Captured for the
    ///      same reason: the phase is closed before `setUp` returns, and this
    ///      is the reading the ceremony would not have given.
    uint256 internal onboardingInviteBar;

    /* ═══════════════════════════════  setUp  ═════════════════════════════ */

    function setUp() public {
        cofundAdmin = makeAddr("cofund-admin");
        sponsor = makeAddr("sponsor");
        attacker = makeAddr("attacker");
        outsider = makeAddr("outsider");
        r1 = makeAddr("recipient-1");
        r2 = makeAddr("recipient-2");

        (adminAddr, adminKey) = makeAddrAndKey("acme-admin");
        (alice, aliceKey) = makeAddrAndKey("alice");
        (aliceNew, aliceNewKey) = makeAddrAndKey("alice-rotated");
        (bob, bobKey) = makeAddrAndKey("bob");
        (carol, carolKey) = makeAddrAndKey("carol");
        (dana, danaKey) = makeAddrAndKey("dana");
        (erin, erinKey) = makeAddrAndKey("erin");
        (frank, frankKey) = makeAddrAndKey("frank");

        // The deploy script IS the fixture. Pranked as the Cofund admin,
        // because `deploy` performs its wiring as its caller.
        vm.startPrank(cofundAdmin);
        Core memory core = deploy(cofundAdmin, sponsor);
        vm.stopPrank();

        state = CFHelpersStatev1(core.state);
        gov = CFHelpersGovv1(core.gov);
        policies = CFHelpersPoliciesv1(core.policies);
        users = CFHelpersUsersv1(core.users);
        factory = CFHelpersVaultFactoryv1(core.factory);
        guard = CFSponsorGuardv1(core.guard);

        token = new MockToken();
        defi = new MockDeFi(address(token));
        wrapper = new MockWrapper(address(defi));

        clientId = Eip712.companyId(COMPANY);
        // §4.2 round 6: three names for one separator. The three stay as
        // separate fields so every signing site below still reads as "the
        // domain the users helper checks" / "...the vault checks", and so
        // the assertion that they are the same value has something to say.
        dsUsers = Eip712.domainSeparator(core.state);
        dsPolicies = Eip712.domainSeparator(core.state);

        _createClient();
        dsVault = Eip712.domainSeparator(core.state);

        // Members first, then the co-admins: the inviting admin's own
        // signature carries an admin seat with no co-signature.
        _addUser("alice", false, "member", alice, aliceKey, AUTH_ADD_ALICE);
        _addUser("bob", false, "member", bob, bobKey, "add-bob");
        _addUser("carol", false, "member", carol, carolKey, "add-carol");
        _addUser("dana", true, "admin", dana, danaKey, "add-dana");

        // Round 5, the same phase seen from the users helper. The founder
        // seats the team one admin at a time on their own signature --
        // `_addUser` passes no co-signatures at all. frank is the seat that
        // moves the arithmetic: at three admins the ceremony wants two
        // signatures for the NEXT one, so dana or frank would have to come
        // back before the founder could finish onboarding the team. While the
        // phase is open the bar stays 1, which is what this reading captures.
        _addUser("frank", true, "admin", frank, frankKey, "add-frank");
        onboardingInviteBar = users.requiredAdminInviteSignatures(clientId);

        // Round 4, the onboarding phase (§4.3). Acme now has three admins, so
        // the standing rule would demand two signatures on any activation --
        // and dana or frank would have to come back before Acme could have a
        // policy at all. While the phase is open the bar is one, and the
        // founder stands the first policy up alone.
        onboardingActivationBar = policies.requiredPolicyActivationSignatures(clientId, 2);
        _activateTransferPolicy(
            OPS_POLICY,
            Eip712.ids("alice", "bob", "carol"),
            2,
            Eip712.addrs(),
            "auth-policy-ops",
            Eip712.keys(adminKey)
        );

        // The platform closes the phase the moment its onboarding flow ends.
        // Everything below this line runs under the standing consensus rule.
        _completeOnboarding();
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  1 -- a client exists only because the sponsor relayed it into being
     * ═════════════════════════════════════════════════════════════════════ */

    function test_ClientCreationOnlyThroughTheRelayToTheUsersHelper() public {
        (address registered, string memory tier) = state.clientVaults(clientId);

        assertEq(registered, address(vault), "vault not registered in State");
        assertEq(registered, factory.predictVault(clientId), "vault off its predicted address");
        assertEq(tier, TIER, "client tier");
        assertEq(vault.clientId(), clientId, "vault bound to the wrong client");
        assertTrue(registered.code.length != 0, "vault has no code");

        // Onboarding is platform-relayed (§4.4): the contract has no notion of
        // the person, so it requires the call to arrive from the party that
        // authenticated them.
        uint256 expiresAt = block.timestamp + 1 days;
        bytes32 founderDigest = _inviteDigest("admin", "admin", true, "admin", expiresAt, "outside");

        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        vm.prank(outsider);
        users.createClient(
            clientId,
            COMPANY,
            "admin",
            adminAddr,
            TIER,
            expiresAt,
            "outside",
            Eip712.sign(adminKey, founderDigest)
        );

        // State is not a relay target at all -- every State write goes through
        // gov or a helper (§5).
        bytes memory atState = abi.encodeCall(CFHelpersStatev1.setSupportedType, ("Anything"));
        vm.expectRevert(CFSponsorGuardv1.CallNotAllowed.selector);
        vm.prank(sponsor);
        guard.relay(address(state), atState);

        // The ClientExists invariant lives in State now, not in the guard. A
        // fresh authId, so the replay store is not what refuses this.
        bytes32 againDigest = _inviteDigest("admin", "admin", true, "admin", expiresAt, "create-again");
        bytes memory again = abi.encodeCall(
            CFHelpersUsersv1.createClient,
            (
                clientId,
                COMPANY,
                "admin",
                adminAddr,
                TIER,
                expiresAt,
                "create-again",
                Eip712.sign(adminKey, againDigest)
            )
        );
        vm.expectRevert(CFHelpersStatev1.ClientExists.selector);
        vm.prank(sponsor);
        guard.relay(address(users), again);
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  2 -- the founder is an active admin the moment the client exists
     * ═════════════════════════════════════════════════════════════════════ */

    function test_FounderIsAnActiveAdminFromCreation() public view {
        // Round 3: `createClient` carries the founder's own signature, so
        // there is no pending seat and no second transaction. The key that
        // signed is the key that is registered.
        assertEq(state.getUserIdByAddress(adminAddr, clientId), "admin", "reverse index");

        CFHelpersStatev1.User memory user = state.getUser(clientId, "admin");
        assertEq(user.addr, adminAddr, "founder address");
        assertEq(user.position, "admin", "founder position");
        assertTrue(user.isAdmin, "founder is not admin");
        assertTrue(user.active, "founder inactive");

        // The founder is a client user, not a Cofund admin.
        assertFalse(state.isCofundAdmin(adminAddr), "client admin must hold no Cofund privilege");
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  3 -- members, and two more admins on the inviter's signature alone
     * ═════════════════════════════════════════════════════════════════════ */

    function test_MembersAndTwoMoreAdmins() public {
        assertEq(state.getUserIdByAddress(alice, clientId), "alice");
        assertEq(state.getUserIdByAddress(bob, clientId), "bob");
        assertEq(state.getUserIdByAddress(carol, clientId), "carol");
        assertEq(state.getUserIdByAddress(dana, clientId), "dana");

        assertFalse(state.getUser(clientId, "alice").isAdmin, "alice must be a plain member");
        assertFalse(state.getUser(clientId, "bob").isAdmin, "bob must be a plain member");
        assertFalse(state.getUser(clientId, "carol").isAdmin, "carol must be a plain member");
        assertTrue(state.getUser(clientId, "dana").isAdmin, "dana must be an admin");
        assertTrue(state.getUser(clientId, "frank").isAdmin, "frank must be an admin");
        assertTrue(state.getUser(clientId, "alice").active, "alice inactive");

        assertEq(state.getActiveAdmins(clientId), 3, "active admins");

        // Both admin seats were authorized while the onboarding phase was open,
        // where the inviter's own signature is the whole requirement whatever
        // the roster (round 5) -- and neither carried a co-signature.
        assertEq(onboardingInviteBar, 1, "invite bar while the phase was open");

        // The lock raises it on the same roster: three admins, so the ceremony
        // is all of them but one. A fourth seat now needs a co-signature.
        assertEq(users.requiredAdminInviteSignatures(clientId), 2, "admin invite bar after the lock");

        // The same platform-relay rule as `createClient`: a stranger holding
        // both signatures still cannot seat anybody.
        (
            CFHelpersUsersv1.AddUserArgs memory args,
            bytes memory adminSig,
            bytes memory memberSig
        ) = _addUserParts("erin", false, "member", erinKey, block.timestamp + 7 days, "add-erin");

        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        vm.prank(outsider);
        users.addUser(args, adminSig, Eip712.none(), erin, memberSig);
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  4 -- a policy stands up only on admin consensus, and stores identities
     * ═════════════════════════════════════════════════════════════════════ */

    function test_PolicyActivationByAdminConsensusThroughTheRelay() public {
        CFHelpersStatev1.Policy memory policy = state.getPolicy(clientId, OPS_POLICY);
        assertTrue(policy.active, "policy inactive");
        assertEq(policy.threshold, 2, "threshold");
        assertEq(policy.signerIds.length, 3, "signer count");
        assertEq(policy.policyType, POLICY_TYPE, "policy type");

        assertTrue(state.isPolicySigner(clientId, OPS_POLICY, keccak256("alice")), "alice");
        assertTrue(state.isPolicySigner(clientId, OPS_POLICY, keccak256("bob")), "bob");
        assertTrue(state.isPolicySigner(clientId, OPS_POLICY, keccak256("carol")), "carol");
        assertFalse(state.isPolicySigner(clientId, OPS_POLICY, keccak256("dana")), "dana");

        // Identities, not addresses: nothing in the policy record names a key.
        assertEq(policy.signerIds[0], keccak256("alice"), "signerIds are hashed userIds");

        // With two admins on the client, one admin cannot stand a policy up
        // alone -- the whole point of the activation consensus.
        assertEq(policies.requiredPolicyActivationSignatures(clientId, 2), 2, "required signatures");

        bytes memory solo = _activationCalldata(
            "ops-solo",
            Eip712.ids("alice", "bob", "carol"),
            2,
            Eip712.addrs(),
            "auth-policy-solo",
            Eip712.keys(adminKey)
        );
        vm.expectRevert(CFHelpersPoliciesv1.SignerCountMismatch.selector);
        vm.prank(sponsor);
        guard.relay(address(policies), solo);
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  5 -- money moves, and the tier fee goes with it
     * ═════════════════════════════════════════════════════════════════════ */

    function test_TransferThroughTheRelay() public {
        uint256 amount = 1_000e18;
        uint256 fee = _fee(amount);
        assertGt(fee, 0, "FREE tier should charge a fee");

        _fund(amount + fee);

        _relay(
            address(vault),
            _signedTransfer(Eip712.keys(aliceKey, bobKey), OPS_POLICY, amount, r1, "tr-1")
        );

        assertEq(token.balanceOf(r1), amount, "recipient");
        assertEq(token.balanceOf(state.cfFeeRecipientAddress()), fee, "fee recipient");
        assertEq(token.balanceOf(address(vault)), 0, "vault should be drained exactly");
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  6 -- THE acceptance test: rotation reaches execution, policy untouched
     * ═════════════════════════════════════════════════════════════════════ */

    function test_RotationPropagatesToExecution() public {
        bytes32 signerIdsBefore = keccak256(
            abi.encode(state.getPolicy(clientId, OPS_POLICY).signerIds)
        );

        _rotateAlice();

        bytes32 signerIdsAfter = keccak256(
            abi.encode(state.getPolicy(clientId, OPS_POLICY).signerIds)
        );
        assertEq(signerIdsAfter, signerIdsBefore, "rotation must not touch the policy");

        assertEq(state.getUserIdByAddress(aliceNew, clientId), "alice", "new key is alice");
        assertEq(state.getUserIdByAddress(alice, clientId), "", "old key must be unmapped");
        assertEq(state.getUser(clientId, "alice").addr, aliceNew, "user record");

        uint256 amount = 100e18;
        _fund((amount + _fee(amount)) * 2);

        // The compromised key can no longer sign for alice...
        bytes memory stale = _signedTransfer(
            Eip712.keys(aliceKey, bobKey),
            OPS_POLICY,
            amount,
            r1,
            "rotate-stale"
        );
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSigner.selector);
        vm.prank(sponsor);
        guard.relay(address(vault), stale);

        // ...and the new one can, with nothing re-issued.
        _relay(
            address(vault),
            _signedTransfer(Eip712.keys(aliceNewKey, bobKey), OPS_POLICY, amount, r1, "rotate-live")
        );
        assertEq(token.balanceOf(r1), amount, "rotated key could not move funds");
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  7 -- removal reaches execution the same way
     * ═════════════════════════════════════════════════════════════════════ */

    function test_RemovalPropagatesToExecution() public {
        _rotateAlice();

        bytes32 digest = Eip712.digest(
            dsUsers,
            Eip712.hashStruct(
                Eip712.RemoveUser({company: COMPANY, removedUserId: "bob", authId: "remove-bob"})
            )
        );
        _relay(
            address(users),
            abi.encodeCall(
                CFHelpersUsersv1.removeUser,
                (clientId, COMPANY, "bob", "remove-bob", Eip712.one(Eip712.sign(adminKey, digest)))
            )
        );

        assertFalse(state.getUser(clientId, "bob").active, "bob still active");
        // The policy still lists bob -- it is liveness, not membership, that
        // changed, and the vault resolves liveness at execution time.
        assertTrue(state.isPolicySigner(clientId, OPS_POLICY, keccak256("bob")), "policy untouched");

        uint256 amount = 50e18;
        _fund((amount + _fee(amount)) * 2);

        bytes memory withBob = _signedTransfer(
            Eip712.keys(aliceNewKey, bobKey),
            OPS_POLICY,
            amount,
            r1,
            "removed-1"
        );
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSigner.selector);
        vm.prank(sponsor);
        guard.relay(address(vault), withBob);

        _relay(
            address(vault),
            _signedTransfer(Eip712.keys(aliceNewKey, carolKey), OPS_POLICY, amount, r1, "removed-2")
        );
        assertEq(token.balanceOf(r1), amount, "remaining signers could not move funds");
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  8 -- the recipient allowlist is enforced, not decorative
     * ═════════════════════════════════════════════════════════════════════ */

    function test_RecipientAllowlistIsEnforced() public {
        _activateTransferPolicy(
            ALLOWLIST_POLICY,
            Eip712.ids("alice", "bob", "carol"),
            2,
            Eip712.addrs(r1),
            "auth-policy-allowlist"
        );

        uint256 amount = 10e18;
        _fund((amount + _fee(amount)) * 2);

        bytes memory offList = _signedTransfer(
            Eip712.keys(aliceKey, bobKey),
            ALLOWLIST_POLICY,
            amount,
            r2,
            "allow-1"
        );
        vm.expectRevert(CFHelpersVaultTemplatev1.RecipientNotAllowed.selector);
        vm.prank(sponsor);
        guard.relay(address(vault), offList);

        _relay(
            address(vault),
            _signedTransfer(Eip712.keys(aliceKey, bobKey), ALLOWLIST_POLICY, amount, r1, "allow-2")
        );
        assertEq(token.balanceOf(r1), amount, "allowlisted recipient");
        assertEq(token.balanceOf(r2), 0, "off-list recipient must receive nothing");
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  9 -- deactivation stops execution
     * ═════════════════════════════════════════════════════════════════════ */

    function test_DeactivationStopsExecution() public {
        bytes32 digest = Eip712.digest(
            dsPolicies,
            Eip712.hashStruct(
                Eip712.PolicyDeactivation({
                    company: COMPANY,
                    policyId: OPS_POLICY,
                    authId: "deactivate-ops"
                })
            )
        );
        _relay(
            address(policies),
            abi.encodeCall(
                CFHelpersPoliciesv1.deactivatePolicy,
                (clientId, COMPANY, OPS_POLICY, "deactivate-ops", Eip712.sign(adminKey, digest))
            )
        );
        assertFalse(state.getPolicy(clientId, OPS_POLICY).active, "policy still active");

        uint256 amount = 1e18;
        _fund(amount + _fee(amount));

        bytes memory afterDeactivation = _signedTransfer(
            Eip712.keys(aliceKey, bobKey),
            OPS_POLICY,
            amount,
            r1,
            "post-deactivation"
        );
        vm.expectRevert(CFHelpersVaultTemplatev1.InactivePolicy.selector);
        vm.prank(sponsor);
        guard.relay(address(vault), afterDeactivation);
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  10 -- the guard holds no privilege of its own
     * ═════════════════════════════════════════════════════════════════════ */

    function test_GuardHoldsNoPrivilege() public {
        assertEq(state.helperContracts("sponsorGuard"), address(guard), "guard registration");
        assertFalse(state.isCofundAdmin(address(guard)), "guard must never be a Cofund admin");
        assertEq(state.cofundAdminCount(), 1, "the deploy must create exactly one Cofund admin");

        // Gov is not a relay target: the guard cannot route to it at all.
        bytes memory atGov = abi.encodeCall(CFHelpersGovv1.addCofundAdmin, (attacker));
        vm.expectRevert(CFSponsorGuardv1.CallNotAllowed.selector);
        vm.prank(sponsor);
        guard.relay(address(gov), atGov);

        // And even reaching Gov from the guard's own address changes nothing,
        // because the address carries no admin bit.
        vm.expectRevert(CFHelpersGovv1.UnauthorizedCaller.selector);
        vm.prank(address(guard));
        gov.addCofundAdmin(attacker);

        assertFalse(state.isCofundAdmin(attacker), "attacker gained privilege");
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  11 -- the broadcaster gate is anti-griefing, not authorization
     * ═════════════════════════════════════════════════════════════════════ */

    function test_BroadcasterGate() public {
        uint256 amount = 5e18;
        _fund((amount + _fee(amount)) * 3);

        // (a) the sponsor's relay is the production path.
        _relay(
            address(vault),
            _signedTransfer(Eip712.keys(aliceKey, bobKey), OPS_POLICY, amount, r1, "gate-sponsor")
        );
        assertEq(token.balanceOf(r1), amount, "sponsored transfer");

        // (b) a stranger cannot broadcast even a perfectly signed transfer.
        bytes[] memory sigs = Eip712.sign(
            Eip712.keys(aliceKey, bobKey),
            _transferDigest(OPS_POLICY, amount, r1, "gate-stranger")
        );
        bytes memory expected = abi.encodeWithSelector(
            CFHelpersVaultTemplatev1.UnauthorizedCaller.selector,
            "caller not mapped to user"
        );
        vm.expectRevert(expected);
        vm.prank(outsider);
        vault.executeTransfer(
            COMPANY,
            OPS_POLICY,
            POLICY_TYPE,
            amount,
            address(token),
            r1,
            "gate-stranger",
            sigs
        );

        // (c) a member paying her own gas needs no sponsor at all.
        bytes[] memory ownGas = Eip712.sign(
            Eip712.keys(aliceKey, bobKey),
            _transferDigest(OPS_POLICY, amount, r2, "gate-self")
        );
        vm.prank(alice);
        vault.executeTransfer(
            COMPANY,
            OPS_POLICY,
            POLICY_TYPE,
            amount,
            address(token),
            r2,
            "gate-self",
            ownGas
        );
        assertEq(token.balanceOf(r2), amount, "self-broadcast transfer");
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  12 -- a wrapper transaction, allowances signed as data
     * ═════════════════════════════════════════════════════════════════════ */

    function test_TransactionThroughTheRelay() public {
        _activateTransactionPolicy(
            TX_POLICY,
            Eip712.ids("alice", "bob", "carol"),
            2,
            "auth-policy-treasury"
        );

        CFHelpersStatev1.Policy memory policy = state.getPolicy(clientId, TX_POLICY);
        assertTrue(policy.isTransaction, "policy is not a transaction policy");
        assertEq(policy.transactionDetails.wrapper, address(wrapper), "wrapper");
        assertEq(policy.transferDetails.token, address(0), "transfer half must be zeroed");

        uint256 minted = 42e18;
        uint256 allowanceAmount = 777e18;
        bytes memory instructions = abi.encode(minted);
        _fund(allowanceAmount);

        vm.recordLogs();
        _relay(
            address(vault),
            _signedTransaction(
                Eip712.keys(aliceKey, bobKey),
                TX_POLICY,
                instructions,
                allowanceAmount,
                "tx-1"
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The wrapper ran: MockWrapper routed "mint-token" into MockDeFi, which
        // minted to its caller -- the wrapper.
        assertEq(token.balanceOf(address(wrapper)), minted, "wrapper was never called");

        // The allowance was really granted and then really withdrawn. Checking
        // only the final zero would pass on a vault that never approved at all.
        (bool sawApproval, bool sawReset) = _scanApprovals(logs, allowanceAmount);
        assertTrue(sawApproval, "allowance was never approved to the wrapper");
        assertTrue(sawReset, "allowance was never reset");
        assertEq(
            token.allowance(address(vault), address(wrapper)),
            0,
            "allowance left standing after the call"
        );
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  13 -- replay, company binding, the authorization window
     * ═════════════════════════════════════════════════════════════════════ */

    function test_AuthIdCannotBeReplayedOnTheSameHelper() public {
        // `AUTH_ADD_ALICE` was spent seating alice through this helper.
        bytes memory replayed = _addUserCalldata(
            "erin",
            false,
            "member",
            erin,
            erinKey,
            block.timestamp + 7 days,
            AUTH_ADD_ALICE
        );

        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        vm.prank(sponsor);
        guard.relay(address(users), replayed);
    }

    /// Round 6 (§4.2), end to end: the two helpers and the client's vault --
    /// three separately deployed contracts -- report one domain, and its
    /// `verifyingContract` is State. One Ledger descriptor, one registration
    /// per chain, forever.
    function test_OneDomainAcrossHelpersAndVault() public view {
        address[3] memory signing = [address(users), address(policies), address(vault)];
        for (uint256 i = 0; i < signing.length; i++) {
            // Each exposes the same ERC-5267 tuple; the interface is identical
            // across the three, so one decode covers them all.
            (
                bytes1 fields,
                string memory name,
                string memory version,
                uint256 chainId,
                address verifyingContract,
                bytes32 salt,
                uint256[] memory extensions
            ) = CFHelpersVaultTemplatev1(signing[i]).eip712Domain();
            assertEq(fields, hex"0f");
            assertEq(name, "Cofund");
            assertEq(version, "1");
            assertEq(chainId, block.chainid);
            assertEq(verifyingContract, address(state));
            assertEq(salt, bytes32(0));
            assertEq(extensions.length, 0);
            assertTrue(verifyingContract != signing[i], "never address(this)");
        }

        // And it is the separator every signature in this file is built over.
        bytes32 shared = Eip712.domainSeparator(address(state));
        assertEq(dsUsers, shared);
        assertEq(dsPolicies, shared);
        assertEq(dsVault, shared);
    }

    /// Round 6 (§4.2). Every vault clone on a chain now reports the same
    /// EIP-712 domain -- `("Cofund", "1", chainId, State)` -- so a `Transfer`
    /// signed for Acme produces a digest that is perfectly valid at Globex's
    /// vault too. What stops it is not the domain but the struct: `company`
    /// is inside the signed message, and every entrypoint checks
    /// `sha256(bytes(company)) == clientId`. This is the test that says so
    /// out loud, because the domain is no longer doing that job.
    function test_TransferSignedForAcmeIsRefusedByAnotherClientsVault() public {
        _lockASecondClientFromAStranger();
        (address globexVault, ) = state.clientVaults(Eip712.companyId("Globex"));
        assertTrue(globexVault != address(vault), "the second client needs its own vault");

        // Both vaults report one and the same domain: that is the round-6
        // claim, and it is what makes the cross-vault replay worth refusing.
        (, , , , address globexVerifying, , ) = CFHelpersVaultTemplatev1(
            globexVault
        ).eip712Domain();
        (, , , , address acmeVerifying, , ) = vault.eip712Domain();
        assertEq(globexVerifying, address(state), "a clone must verify against State");
        assertEq(acmeVerifying, globexVerifying, "two vaults, one domain");

        uint256 amount = 1_000e18;
        _fund(amount + _fee(amount));
        token.mint(globexVault, amount + _fee(amount));

        // Signed for Acme, by Acme's signers, against Acme's policy -- then
        // aimed at Globex's vault.
        bytes memory payload = _signedTransfer(
            Eip712.keys(aliceKey, bobKey),
            OPS_POLICY,
            amount,
            r1,
            "cross-vault-replay"
        );

        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidCompany.selector);
        vm.prank(sponsor);
        guard.relay(globexVault, payload);

        // The same bytes at Acme's own vault go through, so the only thing
        // that refused it above was the company binding.
        vm.prank(sponsor);
        guard.relay(address(vault), payload);
        assertEq(token.balanceOf(r1), amount, "recipient");
    }

    /// The other half of the round-6 pair. The replay store is keyed
    /// `(clientId, authId)` and by nothing else, so an `authId` the vault
    /// spent on a `Transfer` is spent for every other type too -- a
    /// `Transaction` for the same client cannot pick it up, even though it is
    /// a different typehash, a different policy and a different code path.
    function test_VaultAuthIdIsSpentAcrossTypesForTheSameClient() public {
        _activateTransactionPolicy(
            TX_POLICY,
            Eip712.ids("alice", "bob", "carol"),
            2,
            "auth-policy-treasury-replay"
        );

        uint256 amount = 100e18;
        _fund(amount + _fee(amount));
        _relay(
            address(vault),
            _signedTransfer(Eip712.keys(aliceKey, bobKey), OPS_POLICY, amount, r1, "one-shot")
        );
        assertTrue(
            state.getClientContractAuthID(clientId, "one-shot"),
            "the transfer should have burned the id"
        );

        uint256 allowanceAmount = 5e18;
        _fund(allowanceAmount);
        bytes memory txPayload = _signedTransaction(
            Eip712.keys(aliceKey, bobKey),
            TX_POLICY,
            abi.encode(uint256(1e18)),
            allowanceAmount,
            "one-shot"
        );

        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        vm.prank(sponsor);
        guard.relay(address(vault), txPayload);
    }

    function test_WrongCompanyStringIsRefused() public {
        bytes32 removeDigest = Eip712.digest(
            dsUsers,
            Eip712.hashStruct(
                Eip712.RemoveUser({
                    company: "NotAcme",
                    removedUserId: "bob",
                    authId: "wrong-company"
                })
            )
        );
        bytes memory atUsers = abi.encodeCall(
            CFHelpersUsersv1.removeUser,
            (
                clientId,
                "NotAcme",
                "bob",
                "wrong-company",
                Eip712.one(Eip712.sign(adminKey, removeDigest))
            )
        );
        vm.expectRevert(CFHelpersUsersv1.InvalidCompany.selector);
        vm.prank(sponsor);
        guard.relay(address(users), atUsers);

        uint256 amount = 1e18;
        _fund(amount + _fee(amount));
        bytes[] memory sigs = Eip712.sign(
            Eip712.keys(aliceKey, bobKey),
            _transferDigest(OPS_POLICY, amount, r1, "wrong-company-vault")
        );
        bytes memory atVault = abi.encodeCall(
            CFHelpersVaultTemplatev1.executeTransfer,
            (
                "NotAcme",
                OPS_POLICY,
                POLICY_TYPE,
                amount,
                address(token),
                r1,
                "wrong-company-vault",
                sigs
            )
        );
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidCompany.selector);
        vm.prank(sponsor);
        guard.relay(address(vault), atVault);
    }

    /// @dev The window's near end. There is no pending invite to go stale any
    ///      more -- the admin's authorization is what expires, and it expires
    ///      in the helper, because State holds no time logic (§6).
    function test_AuthorizationPastItsExpiryIsRefused() public {
        bytes memory stale = _addUserCalldata(
            "erin",
            false,
            "member",
            erin,
            erinKey,
            block.timestamp - 1,
            "add-erin-stale"
        );

        vm.expectRevert(CFHelpersUsersv1.InviteExpired.selector);
        vm.prank(sponsor);
        guard.relay(address(users), stale);
    }

    /// @dev The window's far end: an admin cannot sign a seat open forever.
    function test_AuthorizationBeyondTheCapIsRefused() public {
        assertEq(users.MAX_INVITE_LIFETIME(), 30 days, "authorization window cap");

        bytes memory overCap = _addUserCalldata(
            "erin",
            false,
            "member",
            erin,
            erinKey,
            block.timestamp + 30 days + 1,
            "add-erin-far"
        );

        vm.expectRevert(CFHelpersUsersv1.InvalidParams.selector);
        vm.prank(sponsor);
        guard.relay(address(users), overCap);
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  14 -- the onboarding phase, and the platform locking it (§4.3)
     * ═════════════════════════════════════════════════════════════════════ */

    function test_OnboardingPhaseLetsOneAdminStandUpTheFirstPolicy() public view {
        // dana and frank were already seated when `setUp` activated
        // OPS_POLICY, so the standing rule would have demanded a second admin
        // -- and Acme could not have had a policy until one of them came back
        // to co-sign. One signature carried it because the phase was still
        // open, which is what the phase is for: the product invites co-admins
        // before the first policy exists.
        assertEq(state.getActiveAdmins(clientId), 3, "the co-admins were seated first");
        assertEq(onboardingActivationBar, 1, "activation bar while onboarding");
        assertTrue(state.getPolicy(clientId, OPS_POLICY).active, "first policy never stood up");
    }

    function test_OnboardingIsLockedByAnAdminSignatureAndIsIrreversible()
        public
    {
        assertTrue(state.onboardingComplete(clientId), "setUp must lock the phase");

        // Not platform-gated (unlike `createClient` / `addUser`): the
        // authorization is an active admin's signature, so `msg.sender` is
        // irrelevant in both directions. A stranger with no admin signature
        // is refused -- erin was never seated, so her key is unmapped here.
        // Built before `vm.expectRevert`: `vm.sign` would consume it.
        bytes memory notAnAdmin = Eip712.signCompleteOnboarding(
            erinKey,
            dsUsers,
            COMPANY,
            "lock-outsider"
        );
        vm.expectRevert(CFHelpersUsersv1.UnauthorizedCaller.selector);
        vm.prank(outsider);
        users.completeOnboarding(clientId, COMPANY, "lock-outsider", notAnAdmin);

        // ...and a stranger HOLDING a valid admin signature is not: on a
        // fresh client, with no relay and no privilege, dana's signature is
        // the whole authorization.
        _lockASecondClientFromAStranger();

        // One way only, and it is State that says so. A fresh authId, so the
        // replay store is not what refuses this.
        bytes memory again = _completeOnboardingCalldata(adminKey, "lock-again");
        vm.expectRevert(CFHelpersStatev1.OnboardingAlreadyComplete.selector);
        vm.prank(sponsor);
        guard.relay(address(users), again);

        assertTrue(state.onboardingComplete(clientId), "the phase must stay locked");
    }

    /// @dev Acme's phase is already locked in `setUp`, so the "anyone may
    ///      broadcast a valid signature" half is shown on a second client the
    ///      sponsor creates and an unrelated EOA then locks.
    function _lockASecondClientFromAStranger() internal {
        string memory company = "Globex";
        bytes32 otherId = Eip712.companyId(company);
        uint256 expiresAt = block.timestamp + 1 days;

        bytes32 founderDigest = Eip712.digest(
            dsUsers,
            Eip712.hashStruct(
                Eip712.InviteUser({
                    company: company,
                    callerId: "admin",
                    userId: "admin",
                    userIsAdmin: true,
                    userPosition: "admin",
                    expiresAt: expiresAt,
                    authId: "create-globex"
                })
            )
        );
        _relay(
            address(users),
            abi.encodeCall(
                CFHelpersUsersv1.createClient,
                (
                    otherId,
                    company,
                    "admin",
                    dana,
                    TIER,
                    expiresAt,
                    "create-globex",
                    Eip712.sign(danaKey, founderDigest)
                )
            )
        );
        assertFalse(state.onboardingComplete(otherId), "a new client starts open");

        // `outsider` is neither the sponsor, nor Cofund, nor a user of this
        // client -- and carries dana's signature, which is enough.
        vm.prank(outsider);
        users.completeOnboarding(
            otherId,
            company,
            "lock-globex",
            Eip712.signCompleteOnboarding(danaKey, dsUsers, company, "lock-globex")
        );
        assertTrue(state.onboardingComplete(otherId), "a valid signature was refused");
    }

    function test_AfterTheLockAnActivationNeedsBothAdmins() public {
        assertEq(
            policies.requiredPolicyActivationSignatures(clientId, 2),
            2,
            "the standing rule is back"
        );

        // The very call `setUp` made -- one admin, same shape -- no longer
        // carries a policy.
        bytes memory solo = _activationCalldata(
            "ops-locked",
            Eip712.ids("alice", "bob", "carol"),
            2,
            Eip712.addrs(),
            "auth-policy-locked-solo",
            Eip712.keys(adminKey)
        );
        vm.expectRevert(CFHelpersPoliciesv1.SignerCountMismatch.selector);
        vm.prank(sponsor);
        guard.relay(address(policies), solo);

        // Both admins do.
        _activateTransferPolicy(
            "ops-locked",
            Eip712.ids("alice", "bob", "carol"),
            2,
            Eip712.addrs(),
            "auth-policy-locked"
        );
        assertTrue(state.getPolicy(clientId, "ops-locked").active, "two admins were refused");
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  15 -- executeTransaction binds messageType to the policy's type
     * ═════════════════════════════════════════════════════════════════════ */

    /// @dev Round 4 (§10). `messageType` is inside the digest the signers
    ///      approved, so leaving it unchecked let an approval be spent against
    ///      a policy of another type. `executeTransfer` always bound the two.
    function test_TransactionWithTheWrongMessageTypeIsRefused() public {
        _activateTransactionPolicy(
            TX_POLICY,
            Eip712.ids("alice", "bob", "carol"),
            2,
            "auth-policy-treasury"
        );

        uint256 minted = 7e18;
        uint256 allowanceAmount = 100e18;
        bytes memory instructions = abi.encode(minted);
        _fund(allowanceAmount);

        // A real, registered policy type -- just not this policy's.
        bytes memory wrongType = _signedTransaction(
            Eip712.keys(aliceKey, bobKey),
            TX_POLICY,
            instructions,
            allowanceAmount,
            "tx-wrong-type",
            POLICY_TYPE
        );
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidPolicyType.selector);
        vm.prank(sponsor);
        guard.relay(address(vault), wrongType);

        assertEq(token.balanceOf(address(wrapper)), 0, "the wrapper must not have run");

        // The same transaction under the policy's own type executes, so it is
        // the type check that refused above and nothing else.
        _relay(
            address(vault),
            _signedTransaction(
                Eip712.keys(aliceKey, bobKey),
                TX_POLICY,
                instructions,
                allowanceAmount,
                "tx-right-type"
            )
        );
        assertEq(token.balanceOf(address(wrapper)), minted, "wrapper was never called");
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  onboarding helpers -- everything below goes through the relay
     * ═════════════════════════════════════════════════════════════════════ */

    function _relay(address target, bytes memory data) internal returns (bytes memory) {
        vm.prank(sponsor);
        return guard.relay(target, data);
    }

    /// @dev One transaction: the founder signs `InviteUser` over themselves,
    ///      the platform relays it, and the client, its vault and its first
    ///      active admin all exist when it returns.
    function _createClient() internal {
        founderExpiresAt = block.timestamp + 1 days;
        bytes32 digest = _inviteDigest(
            "admin",
            "admin",
            true,
            "admin",
            founderExpiresAt,
            "create-acme"
        );

        _relay(
            address(users),
            abi.encodeCall(
                CFHelpersUsersv1.createClient,
                (
                    clientId,
                    COMPANY,
                    "admin",
                    adminAddr,
                    TIER,
                    founderExpiresAt,
                    "create-acme",
                    Eip712.sign(adminKey, digest)
                )
            )
        );

        (address vaultAddress, ) = state.clientVaults(clientId);
        vault = CFHelpersVaultTemplatev1(vaultAddress);
    }

    function _addUser(
        string memory userId,
        bool isAdmin,
        string memory position,
        address who,
        uint256 key,
        string memory authId
    ) internal {
        _relay(
            address(users),
            _addUserCalldata(userId, isAdmin, position, who, key, block.timestamp + 7 days, authId)
        );
    }

    /// @dev The admin's authorization and the member's acceptance, over one
    ///      digest (§4.4). Returned as pieces so a test can either relay the
    ///      call or make it directly.
    function _addUserParts(
        string memory userId,
        bool isAdmin,
        string memory position,
        uint256 key,
        uint256 expiresAt,
        string memory authId
    )
        internal
        view
        returns (CFHelpersUsersv1.AddUserArgs memory args, bytes memory adminSig, bytes memory memberSig)
    {
        args = CFHelpersUsersv1.AddUserArgs({
            clientId: clientId,
            company: COMPANY,
            callerId: "admin",
            userId: userId,
            isAdmin: isAdmin,
            userPosition: position,
            expiresAt: expiresAt,
            authId: authId
        });

        bytes32 digest = _inviteDigest("admin", userId, isAdmin, position, expiresAt, authId);
        adminSig = Eip712.sign(adminKey, digest);
        memberSig = Eip712.sign(key, digest);
    }

    /// @dev One call seats one member. The co-signature array is empty: it is
    ///      only consulted for an admin seat, and while Acme has one admin the
    ///      bar is one signature.
    function _addUserCalldata(
        string memory userId,
        bool isAdmin,
        string memory position,
        address who,
        uint256 key,
        uint256 expiresAt,
        string memory authId
    ) internal view returns (bytes memory) {
        (
            CFHelpersUsersv1.AddUserArgs memory args,
            bytes memory adminSig,
            bytes memory memberSig
        ) = _addUserParts(userId, isAdmin, position, key, expiresAt, authId);

        return
            abi.encodeCall(
                CFHelpersUsersv1.addUser,
                (args, adminSig, Eip712.none(), who, memberSig)
            );
    }

    function _inviteDigest(
        string memory callerId,
        string memory userId,
        bool isAdmin,
        string memory position,
        uint256 expiresAt,
        string memory authId
    ) internal view returns (bytes32) {
        return
            Eip712.digest(
                dsUsers,
                Eip712.hashStruct(
                    Eip712.InviteUser({
                        company: COMPANY,
                        callerId: callerId,
                        userId: userId,
                        userIsAdmin: isAdmin,
                        userPosition: position,
                        expiresAt: expiresAt,
                        authId: authId
                    })
                )
            );
    }

    /// @dev The client locking its own onboarding phase (§4.3). One active
    ///      admin signs `CompleteOnboarding`; nothing is platform-gated, so
    ///      `msg.sender` is irrelevant and the sponsor relays it only because
    ///      that is how the webapp broadcasts everything.
    function _completeOnboarding() internal {
        _relay(address(users), _completeOnboardingCalldata(adminKey, "lock-onboarding"));
    }

    function _completeOnboardingCalldata(
        uint256 signerKey,
        string memory authId
    ) internal view returns (bytes memory) {
        return
            abi.encodeCall(
                CFHelpersUsersv1.completeOnboarding,
                (
                    clientId,
                    COMPANY,
                    authId,
                    Eip712.signCompleteOnboarding(signerKey, dsUsers, COMPANY, authId)
                )
            );
    }

    /// @dev Self-rotation: the current key hands over and the new key proves
    ///      possession; no admin is involved and none may be (§4.5).
    function _rotateAlice() internal {
        bytes32 digest = Eip712.digest(
            dsUsers,
            Eip712.hashStruct(
                Eip712.RotateUser({
                    company: COMPANY,
                    userId: "alice",
                    newAddress: aliceNew,
                    authId: "rotate-alice"
                })
            )
        );
        _relay(
            address(users),
            abi.encodeCall(
                CFHelpersUsersv1.rotateUser,
                (
                    clientId,
                    COMPANY,
                    "alice",
                    aliceNew,
                    "rotate-alice",
                    Eip712.sign(aliceKey, digest),
                    Eip712.sign(aliceNewKey, digest),
                    Eip712.none()
                )
            )
        );
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  policy helpers
     * ═════════════════════════════════════════════════════════════════════ */

    /// @dev Both of Acme's admins sign, which is what the standing rule asks
    ///      for once the onboarding phase is locked.
    function _activateTransferPolicy(
        string memory policyId,
        string[] memory signerIds,
        uint256 threshold,
        address[] memory recipients,
        string memory authId
    ) internal {
        _activateTransferPolicy(
            policyId,
            signerIds,
            threshold,
            recipients,
            authId,
            Eip712.keys(adminKey, danaKey)
        );
    }

    function _activateTransferPolicy(
        string memory policyId,
        string[] memory signerIds,
        uint256 threshold,
        address[] memory recipients,
        string memory authId,
        uint256[] memory signerKeys
    ) internal {
        _relay(
            address(policies),
            _activationCalldata(
                policyId,
                signerIds,
                threshold,
                recipients,
                authId,
                signerKeys
            )
        );
    }

    function _activationCalldata(
        string memory policyId,
        string[] memory signerIds,
        uint256 threshold,
        address[] memory recipients,
        string memory authId,
        uint256[] memory signerKeys
    ) internal view returns (bytes memory) {
        CFHelpersPoliciesv1.TransferPolicyArgs memory args = CFHelpersPoliciesv1.TransferPolicyArgs({
            clientId: clientId,
            company: COMPANY,
            policyId: policyId,
            title: POLICY_TITLE,
            policyType: POLICY_TYPE,
            signerIds: signerIds,
            threshold: threshold,
            token: address(token),
            maxAmount: MAX_AMOUNT,
            recipients: recipients
        });

        bytes32 digest = Eip712.digest(
            dsPolicies,
            Eip712.hashStruct(
                Eip712.TransferPolicyActivation({
                    company: COMPANY,
                    policyId: policyId,
                    title: POLICY_TITLE,
                    policyType: POLICY_TYPE,
                    signerIds: signerIds,
                    threshold: threshold,
                    token: address(token),
                    maxAmount: MAX_AMOUNT,
                    recipients: recipients,
                    authId: authId
                })
            )
        );

        return
            abi.encodeCall(
                CFHelpersPoliciesv1.activateTransferPolicy,
                (args, authId, Eip712.sign(signerKeys, digest))
            );
    }

    function _activateTransactionPolicy(
        string memory policyId,
        string[] memory signerIds,
        uint256 threshold,
        string memory authId
    ) internal {
        CFHelpersPoliciesv1.TransactionPolicyArgs memory args = CFHelpersPoliciesv1
            .TransactionPolicyArgs({
                clientId: clientId,
                company: COMPANY,
                policyId: policyId,
                title: TX_POLICY_TITLE,
                policyType: TX_POLICY_TYPE,
                signerIds: signerIds,
                threshold: threshold,
                wrapper: address(wrapper),
                func: TX_FUNC
            });

        bytes32 digest = Eip712.digest(
            dsPolicies,
            Eip712.hashStruct(
                Eip712.TransactionPolicyActivation({
                    company: COMPANY,
                    policyId: policyId,
                    title: TX_POLICY_TITLE,
                    policyType: TX_POLICY_TYPE,
                    signerIds: signerIds,
                    threshold: threshold,
                    wrapper: address(wrapper),
                    func: TX_FUNC,
                    authId: authId
                })
            )
        );

        _relay(
            address(policies),
            abi.encodeCall(
                CFHelpersPoliciesv1.activateTransactionPolicy,
                (args, authId, Eip712.sign(Eip712.keys(adminKey, danaKey), digest))
            )
        );
    }

    /* ══════════════════════════════════════════════════════════════════════
     *  execution helpers
     * ═════════════════════════════════════════════════════════════════════ */

    function _transferDigest(
        string memory policyId,
        uint256 amount,
        address recipient,
        string memory authId
    ) internal view returns (bytes32) {
        return
            Eip712.digest(
                dsVault,
                Eip712.hashStruct(
                    Eip712.Transfer({
                        company: COMPANY,
                        policyId: policyId,
                        messageType: POLICY_TYPE,
                        amount: amount,
                        token: address(token),
                        recipient: recipient,
                        authId: authId
                    })
                )
            );
    }

    function _signedTransfer(
        uint256[] memory signerKeys,
        string memory policyId,
        uint256 amount,
        address recipient,
        string memory authId
    ) internal view returns (bytes memory) {
        bytes[] memory sigs = Eip712.sign(
            signerKeys,
            _transferDigest(policyId, amount, recipient, authId)
        );
        return
            abi.encodeCall(
                CFHelpersVaultTemplatev1.executeTransfer,
                (COMPANY, policyId, POLICY_TYPE, amount, address(token), recipient, authId, sigs)
            );
    }

    /// @dev The signed `Allowance[]` and the one the vault executes are built
    ///      separately from the same numbers -- the library's message type and
    ///      the vault's ABI struct are different types that must agree, which
    ///      is exactly what tier A of §4.2 is for.
    function _signedTransaction(
        uint256[] memory signerKeys,
        string memory policyId,
        bytes memory instructions,
        uint256 allowanceAmount,
        string memory authId
    ) internal view returns (bytes memory) {
        return
            _signedTransaction(
                signerKeys,
                policyId,
                instructions,
                allowanceAmount,
                authId,
                TX_POLICY_TYPE
            );
    }

    /// @dev `messageType` is a parameter because round 4 made the vault check
    ///      it against the policy's own type. The signers sign whatever is
    ///      passed, so a mismatch test exercises the vault's check rather than
    ///      tripping the signature check on the way there.
    function _signedTransaction(
        uint256[] memory signerKeys,
        string memory policyId,
        bytes memory instructions,
        uint256 allowanceAmount,
        string memory authId,
        string memory messageType
    ) internal view returns (bytes memory) {
        Eip712.Allowance[] memory signed = new Eip712.Allowance[](1);
        signed[0] = Eip712.Allowance({asset: address(token), amount: allowanceAmount});

        bytes32 digest = Eip712.digest(
            dsVault,
            Eip712.hashStruct(
                Eip712.Transaction({
                    company: COMPANY,
                    policyId: policyId,
                    messageType: messageType,
                    wrapper: address(wrapper),
                    func: TX_FUNC,
                    allowances: signed,
                    instructionsHash: keccak256(instructions),
                    authId: authId
                })
            )
        );

        CFHelpersVaultTemplatev1.Allowance[] memory executed = new CFHelpersVaultTemplatev1.Allowance[](1);
        executed[0] = CFHelpersVaultTemplatev1.Allowance({
            asset: address(token),
            amount: allowanceAmount
        });

        return
            abi.encodeCall(
                CFHelpersVaultTemplatev1.executeTransaction,
                (
                    COMPANY,
                    policyId,
                    messageType,
                    address(wrapper),
                    TX_FUNC,
                    instructions,
                    executed,
                    authId,
                    Eip712.sign(signerKeys, digest)
                )
            );
    }

    /// @dev Did the vault approve `amount` to the wrapper, and then zero it?
    function _scanApprovals(
        Vm.Log[] memory logs,
        uint256 amount
    ) internal view returns (bool sawApproval, bool sawReset) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(token)) continue;
            if (logs[i].topics.length != 3 || logs[i].topics[0] != APPROVAL_TOPIC) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != address(vault)) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != address(wrapper)) continue;

            uint256 value = abi.decode(logs[i].data, (uint256));
            if (value == amount) sawApproval = true;
            if (value == 0) sawReset = true;
        }
    }

    function _fund(uint256 amount) internal {
        token.mint(address(vault), amount);
    }

    /// @dev The vault's own arithmetic: bps of the principal, rounded down but
    ///      never to zero while the tier charges anything at all.
    function _fee(uint256 amount) internal view returns (uint256) {
        uint256 raw = amount * uint256(state.subscriptionTierBps(TIER));
        if (raw == 0) return 0;
        uint256 fee = raw / 10_000;
        return fee == 0 ? 1 : fee;
    }
}
