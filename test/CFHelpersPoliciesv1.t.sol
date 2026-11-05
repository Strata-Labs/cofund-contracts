// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CFHelpersPoliciesv1} from "../contracts/CFHelpersPoliciesv1.sol";
import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {MockVaultFactory} from "../contracts/MockVaultFactory.sol";
import {Eip712} from "./utils/Eip712.sol";

// ─────────────────────────────────────────────────────────────────────────────
// CFHelpersPoliciesv1 — WP4 of docs/v1-relaunch-design.md, round 2.
//
// Port of test/CFHelpersPoliciesv1.ts (kept as reference until WP6). What this
// suite holds down:
//
//   * There is no forwarder and no caller check. The admin consensus
//     signatures are the authorization, so several tests submit from accounts
//     that are not client users at all.
//   * Policies name identities (`string[] signerIds`), not addresses. State
//     stores `keccak256(bytes(id))`, so the assertions compare hashed ids.
//   * Replay protection lives in State (`setClientContractAuthID`), keyed by
//     `(clientId, authId)` since round 6 — a replay reverts `KeyExists` from
//     State, and a users-authId cannot collide with a policies-authId.
//   * `company` is a string in every signed payload, bound to the storage key
//     by `sha256(bytes(company)) == clientId`.
//   * The supported-type gate is enforced by the HELPER now, not by State.
//     `test_StateNoLongerEnforcesPolicyType` documents where the rule lives.
//
// The digests below are rebuilt here from the literal §4.2 type strings rather
// than borrowed from the contract, so a field-order drift shows up as a failed
// recovery rather than as two copies of the same mistake agreeing.
//
// No Users helper is deployed: `helperContracts["users"]` points at a plain
// EOA which drives State's user table directly. WP4 is about the policies
// helper; pulling in WP3's contract would couple the packages.
// ─────────────────────────────────────────────────────────────────────────────

contract CFHelpersPoliciesv1Test is Test {
    // ── the frozen §4.2 type strings, and their hashes as independent anchors
    string constant TRANSFER_TYPE_STRING =
        "TransferPolicyActivation(string company,string policyId,string title,string policyType,string[] signerIds,uint256 threshold,address token,uint256 maxAmount,address[] recipients,string authId)";
    string constant TRANSACTION_TYPE_STRING =
        "TransactionPolicyActivation(string company,string policyId,string title,string policyType,string[] signerIds,uint256 threshold,address wrapper,string func,string authId)";
    string constant DEACTIVATION_TYPE_STRING =
        "PolicyDeactivation(string company,string policyId,string authId)";

    bytes32 constant TRANSFER_TYPEHASH_ANCHOR =
        0x0326bf5769a811ba22e292efd4a06b2bc2d530aa05215ee4b2c8daeb05e33d27;
    bytes32 constant TRANSACTION_TYPEHASH_ANCHOR =
        0xc6b41fdc03b133d7c0149656f6c6b5c836b1d070507ac7f5dddf8740503c6f63;
    bytes32 constant DEACTIVATION_TYPEHASH_ANCHOR =
        0x43230260f8814d32cb265b1563af7692f8742da197f3c6290d1a455285000e83;

    string constant COMPANY = "Acme";
    string constant POLICY_TYPE = "Treasury_Management";

    // The helper never calls these — it only checks `token`/`wrapper` are
    // non-zero and hands them to State — so fixed addresses keep the fixture
    // free of unrelated deployments.
    address constant TOKEN = 0x1111111111111111111111111111111111111111;
    address constant WRAPPER = 0x2222222222222222222222222222222222222222;
    address constant RECIPIENT_A = 0x3333333333333333333333333333333333333333;
    address constant RECIPIENT_B = 0x4444444444444444444444444444444444444444;

    uint256 constant DEPLOYER_PK = 0xD1;
    uint256 constant ALICE_PK = 0xA11CE;
    uint256 constant BOB_PK = 0xB0B;
    uint256 constant CAROL_PK = 0xCA401;
    uint256 constant DAVE_PK = 0xDA7E;
    uint256 constant STRANGER_PK = 0x57A;

    CFHelpersStatev1 internal state;
    CFHelpersPoliciesv1 internal policies;
    MockVaultFactory internal vaultFactory;

    address internal deployer; // Cofund admin, client user "0" (admin)
    address internal alice; // client user "1" (admin)
    address internal bob; // client user "2" (member)
    address internal carol; // client user "3" (member)
    address internal dave; // client user "4" (admin), added only where needed
    address internal stranger; // not a client user at all

    address internal govEOA = makeAddr("gov");
    address internal usersEOA = makeAddr("usersHelper");
    address internal policiesEOA = makeAddr("policiesHelperStandIn");

    bytes32 internal CLIENT_ID;
    bytes32 internal DOMAIN_SEPARATOR;

    // Local copies so the tests can pin State's events.
    event PolicyActivated(bytes32 indexed clientId, string policyId);
    event PolicyDeactivated(bytes32 indexed clientId, string policyId);

    // ═════════════════════════════════════════════════════════════════════════
    //  Fixture
    // ═════════════════════════════════════════════════════════════════════════

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        alice = vm.addr(ALICE_PK);
        bob = vm.addr(BOB_PK);
        carol = vm.addr(CAROL_PK);
        dave = vm.addr(DAVE_PK);
        stranger = vm.addr(STRANGER_PK);

        // The company string IS the clientId: every signed payload carries
        // `company` and the helper checks `sha256(bytes(company)) == clientId`.
        CLIENT_ID = sha256(bytes(COMPANY));

        state = new CFHelpersStatev1(deployer);
        policies = new CFHelpersPoliciesv1(address(state));
        vaultFactory = new MockVaultFactory();

        // Bootstrap gov onto an EOA so the wiring below needs no CFHelpersGovv1.
        vm.prank(deployer);
        state.setGovHelperContract(govEOA);

        vm.startPrank(govEOA);
        state.setHelperContract("vaults", address(vaultFactory));
        state.setHelperContract("users", usersEOA);
        state.setHelperContract("policies", address(policies));
        vm.stopPrank();

        vm.prank(deployer);
        state.setSupportedType(POLICY_TYPE);

        // State ships with no users: `newClient` creates the client and its
        // founding admin in one call. Leaves `deployer` as user "0", an active
        // admin, with `getActiveAdmins == 1`.
        vm.prank(usersEOA);
        state.newClient(CLIENT_ID, "0", deployer, "FREE");

        _addClientUser("1", alice, true, "admin");
        _addClientUser("2", bob, false, "engineer");
        _addClientUser("3", carol, false, "contractor");

        // §4.2 round 6: one domain for the whole stack, and its
        // `verifyingContract` is STATE -- not this helper. Re-derived here
        // from the literal field values rather than read off the contract, so
        // a drift on either side shows up as a failed recovery.
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("Cofund")),
                keccak256(bytes("1")),
                block.chainid,
                address(state)
            )
        );
    }

    /// Registers a client user straight through State, the way the users
    /// helper would.
    function _addClientUser(
        string memory userId,
        address userAddress,
        bool isAdmin,
        string memory position
    ) internal {
        vm.prank(usersEOA);
        state.addUser(CLIENT_ID, userId, userAddress, isAdmin, position);
    }

    function _removeUser(string memory userId) internal {
        vm.prank(usersEOA);
        state.removeUser(CLIENT_ID, "0", userId);
    }

    /// Closes the fixture client's onboarding phase, which is what puts the v0
    /// activation rule back in force (§4.3, round 4). In production the
    /// platform does this through `Users.completeOnboarding`; here
    /// `helperContracts["users"]` is `usersEOA`, so it writes State directly.
    ///
    /// Every test below that asserts the v0 rule calls this FIRST and on
    /// purpose: a fresh client's phase is open, and while it is open one
    /// signature carries any activation, so a v0-rule test that skipped this
    /// would be asserting nothing.
    function _lockOnboarding() internal {
        vm.prank(usersEOA);
        state.setOnboardingComplete(CLIENT_ID);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Typed-data helpers — built from the literal type strings above
    // ═════════════════════════════════════════════════════════════════════════

    function _hashStrings(
        string[] memory arr
    ) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            h[i] = keccak256(bytes(arr[i]));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
            );
    }

    function _transferDigest(
        CFHelpersPoliciesv1.TransferPolicyArgs memory a,
        string memory authId
    ) internal view returns (bytes32) {
        return _digest(_transferStructHash(a, authId));
    }

    /// The struct hash alone, so the round-6 domain test can put one payload
    /// under two different domains.
    function _transferStructHash(
        CFHelpersPoliciesv1.TransferPolicyArgs memory a,
        string memory authId
    ) internal pure returns (bytes32) {
        bytes memory head = abi.encode(
            TRANSFER_TYPEHASH_ANCHOR,
            keccak256(bytes(a.company)),
            keccak256(bytes(a.policyId)),
            keccak256(bytes(a.title)),
            keccak256(bytes(a.policyType))
        );
        bytes memory tail = abi.encode(
            _hashStrings(a.signerIds),
            a.threshold,
            a.token,
            a.maxAmount,
            keccak256(abi.encodePacked(a.recipients)),
            keccak256(bytes(authId))
        );
        return keccak256(bytes.concat(head, tail));
    }

    function _transactionDigest(
        CFHelpersPoliciesv1.TransactionPolicyArgs memory a,
        string memory authId
    ) internal view returns (bytes32) {
        bytes memory head = abi.encode(
            TRANSACTION_TYPEHASH_ANCHOR,
            keccak256(bytes(a.company)),
            keccak256(bytes(a.policyId)),
            keccak256(bytes(a.title)),
            keccak256(bytes(a.policyType))
        );
        bytes memory tail = abi.encode(
            _hashStrings(a.signerIds),
            a.threshold,
            a.wrapper,
            keccak256(bytes(a.func)),
            keccak256(bytes(authId))
        );
        return _digest(keccak256(bytes.concat(head, tail)));
    }

    function _deactivationDigest(
        string memory company,
        string memory policyId,
        string memory authId
    ) internal view returns (bytes32) {
        return
            _digest(
                keccak256(
                    abi.encode(
                        DEACTIVATION_TYPEHASH_ANCHOR,
                        keccak256(bytes(company)),
                        keccak256(bytes(policyId)),
                        keccak256(bytes(authId))
                    )
                )
            );
    }

    function _sign(
        uint256 pk,
        bytes32 digest
    ) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Signatures ordered ascending by signer address, which is the helper's
    /// uniqueness check.
    function _sorted(
        uint256[] memory pks,
        bytes32 digest
    ) internal pure returns (bytes[] memory sigs) {
        uint256 n = pks.length;
        address[] memory addrs = new address[](n);
        sigs = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            addrs[i] = vm.addr(pks[i]);
            sigs[i] = _sign(pks[i], digest);
        }
        for (uint256 i = 1; i < n; i++) {
            address a = addrs[i];
            bytes memory s = sigs[i];
            uint256 j = i;
            while (j > 0 && addrs[j - 1] > a) {
                addrs[j] = addrs[j - 1];
                sigs[j] = sigs[j - 1];
                j--;
            }
            addrs[j] = a;
            sigs[j] = s;
        }
    }

    function _signTransfer(
        uint256[] memory pks,
        CFHelpersPoliciesv1.TransferPolicyArgs memory a,
        string memory authId
    ) internal view returns (bytes[] memory) {
        return _sorted(pks, _transferDigest(a, authId));
    }

    function _signTransaction(
        uint256[] memory pks,
        CFHelpersPoliciesv1.TransactionPolicyArgs memory a,
        string memory authId
    ) internal view returns (bytes[] memory) {
        return _sorted(pks, _transactionDigest(a, authId));
    }

    // ── small array builders ──────────────────────────────────────────────────

    function _pks(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _pks(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _pks(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _ids(string memory a) internal pure returns (string[] memory r) {
        r = new string[](1);
        r[0] = a;
    }

    function _ids(
        string memory a,
        string memory b
    ) internal pure returns (string[] memory r) {
        r = new string[](2);
        r[0] = a;
        r[1] = b;
    }

    function _ids(
        string memory a,
        string memory b,
        string memory c
    ) internal pure returns (string[] memory r) {
        r = new string[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _addrs(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _addrs(
        address a,
        address b
    ) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    // ── arg builders ──────────────────────────────────────────────────────────

    function _transferArgs(
        string memory policyId
    )
        internal
        view
        returns (CFHelpersPoliciesv1.TransferPolicyArgs memory a)
    {
        a.clientId = CLIENT_ID;
        a.company = COMPANY;
        a.policyId = policyId;
        a.title = "Ops transfers";
        a.policyType = POLICY_TYPE;
        a.signerIds = _ids("0", "2");
        a.threshold = 1;
        a.token = TOKEN;
        a.maxAmount = 2500;
        a.recipients = new address[](0);
    }

    function _transactionArgs(
        string memory policyId
    )
        internal
        view
        returns (CFHelpersPoliciesv1.TransactionPolicyArgs memory a)
    {
        a.clientId = CLIENT_ID;
        a.company = COMPANY;
        a.policyId = policyId;
        a.title = "Aave supply";
        a.policyType = POLICY_TYPE;
        a.signerIds = _ids("0", "2");
        a.threshold = 1;
        a.wrapper = WRAPPER;
        a.func = "supply";
    }

    /// Activates `policyId` with the two founding admins, for tests that need
    /// a live policy to act on.
    function _activate(string memory policyId, string memory authId) internal {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs(
            policyId
        );
        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK, ALICE_PK), a, authId)
        );
    }

    function _idHash(string memory userId) internal pure returns (bytes32) {
        return keccak256(bytes(userId));
    }

    /// Solidity's dispatcher emits each external selector as a PUSH4 constant,
    /// so a selector absent from the runtime code is absent from the ABI.
    function _codeHasSelector(bytes4 sel) internal view returns (bool) {
        bytes memory code = address(policies).code;
        for (uint256 i = 0; i + 4 <= code.length; i++) {
            if (
                code[i] == sel[0] &&
                code[i + 1] == sel[1] &&
                code[i + 2] == sel[2] &&
                code[i + 3] == sel[3]
            ) return true;
        }
        return false;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  1-4  The v0 surface that is gone
    // ═════════════════════════════════════════════════════════════════════════

    function test_NoERC2771Surface() public view {
        // Positive controls first, so an always-false scan cannot pass this.
        assertTrue(
            _codeHasSelector(
                CFHelpersPoliciesv1.activateTransferPolicy.selector
            ),
            "scan is broken: v1 selector missing"
        );
        assertTrue(
            _codeHasSelector(
                CFHelpersPoliciesv1.activateTransactionPolicy.selector
            ),
            "scan is broken: v1 selector missing"
        );

        assertFalse(
            _codeHasSelector(bytes4(keccak256("isTrustedForwarder(address)")))
        );
        assertFalse(_codeHasSelector(bytes4(keccak256("trustedForwarder()"))));

        (bool ok, ) = address(policies).staticcall(
            abi.encodeWithSignature("isTrustedForwarder(address)", address(1))
        );
        assertFalse(ok, "isTrustedForwarder is still callable");
    }

    function test_NoLocalReplayStore() public view {
        assertFalse(
            _codeHasSelector(bytes4(keccak256("usedAuthId(bytes32,string)")))
        );

        (bool ok, ) = address(policies).staticcall(
            abi.encodeWithSignature(
                "usedAuthId(bytes32,string)",
                CLIENT_ID,
                "x"
            )
        );
        assertFalse(ok, "usedAuthId is still callable");
    }

    function test_NoV0Entrypoints() public view {
        assertFalse(
            _codeHasSelector(
                bytes4(
                    keccak256(
                        "activatePolicyWithAdminConsensus((bytes32,string,string,string,address[],uint256,(address,string),(uint256,address,address[]),bool),string,bytes[])"
                    )
                )
            )
        );
        assertFalse(
            _codeHasSelector(
                bytes4(keccak256("deactivatePolicyWrapper(bytes32,string)"))
            )
        );
        assertFalse(
            _codeHasSelector(
                bytes4(
                    keccak256(
                        "activatePolicyWrapper(bytes32,string,string,string,address[],uint256)"
                    )
                )
            )
        );
    }

    function test_ExposesV1Domain() public view {
        (
            ,
            string memory name,
            string memory version,
            uint256 cid,
            address verifyingContract,
            ,

        ) = policies.eip712Domain();
        assertEq(name, "Cofund");
        assertEq(version, "1");
        assertEq(cid, block.chainid);
        assertEq(verifyingContract, address(state));
    }

    /// ERC-5267 in full: fields `0x0f` (name|version|chainId|verifyingContract),
    /// no salt, no extensions -- the shape a Ledger descriptor is written
    /// against, and the one State address it registers per chain (§4.2).
    function test_Eip712DomainReportsTheSharedCofundDomain() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 cid,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = policies.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "Cofund");
        assertEq(version, "1");
        assertEq(cid, block.chainid);
        assertEq(verifyingContract, address(state));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);

        // And it is the separator this suite actually signs under.
        assertEq(DOMAIN_SEPARATOR, Eip712.domainSeparator(address(state)));
    }

    /// The round-6 change stated as a negative: the identical activation,
    /// signed under the OLD per-contract shape (`verifyingContract ==
    /// policies`, name "Cofund Policies"), recovers a different address and is
    /// refused. Without this the domain swap would be untested -- every
    /// positive path passes under either shape so long as both sides agree.
    function testRevert_SignedUnderTheHelperAddressDomain() public {
        bytes32 legacyDomain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("Cofund Policies")),
                keccak256(bytes("1")),
                block.chainid,
                address(policies) // the pre-round-6 verifying contract
            )
        );

        string memory authId = "auth-legacy-domain";
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("90");

        // Same struct hash both times; only the domain differs. Recover the
        // struct hash from the shared-domain digest so there is exactly one
        // encoding of the payload in this test.
        bytes32 structHash = _transferStructHash(a, authId);

        bytes[] memory legacySigs = _sorted(
            _pks(DEPLOYER_PK, ALICE_PK),
            keccak256(abi.encodePacked("\x19\x01", legacyDomain, structHash))
        );

        vm.expectRevert(CFHelpersPoliciesv1.InvalidSigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, legacySigs);

        // The very same payload under the shared domain goes through, so the
        // only thing that changed above was the `verifyingContract`.
        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _sorted(_pks(DEPLOYER_PK, ALICE_PK), _digest(structHash))
        );
        assertTrue(state.getPolicy(CLIENT_ID, "90").active);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  5-7  The frozen §4.2 type strings
    // ═════════════════════════════════════════════════════════════════════════
    //
    // The anchors are hard-coded hashes of the literal strings in §4.2. Every
    // signature in this file is built over them, so if the contract's typehash
    // drifted, recovery would yield a junk address and the happy paths would
    // fail. These three pin the strings themselves.

    function test_TransferTypeStringIsFrozen() public pure {
        assertEq(
            keccak256(bytes(TRANSFER_TYPE_STRING)),
            TRANSFER_TYPEHASH_ANCHOR
        );
        assertEq(
            TRANSFER_TYPE_STRING,
            "TransferPolicyActivation(string company,string policyId,string title,string policyType,string[] signerIds,uint256 threshold,address token,uint256 maxAmount,address[] recipients,string authId)"
        );
    }

    function test_TransactionTypeStringIsFrozen() public pure {
        assertEq(
            keccak256(bytes(TRANSACTION_TYPE_STRING)),
            TRANSACTION_TYPEHASH_ANCHOR
        );
        assertEq(
            TRANSACTION_TYPE_STRING,
            "TransactionPolicyActivation(string company,string policyId,string title,string policyType,string[] signerIds,uint256 threshold,address wrapper,string func,string authId)"
        );
    }

    function test_DeactivationTypeStringIsFrozen() public pure {
        assertEq(
            keccak256(bytes(DEACTIVATION_TYPE_STRING)),
            DEACTIVATION_TYPEHASH_ANCHOR
        );
        assertEq(
            DEACTIVATION_TYPE_STRING,
            "PolicyDeactivation(string company,string policyId,string authId)"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  8-11  requiredPolicyActivationSignatures — after the onboarding lock,
    //        the v0 rule, unchanged
    // ═════════════════════════════════════════════════════════════════════════

    function test_RequiredSigs_UnknownClient() public view {
        // A client that does not exist has an open phase and no admins, so
        // both rules answer 1. Nothing can be activated for it regardless:
        // State rejects every signer id.
        bytes32 unknown = keccak256("no-such-client");
        assertEq(policies.requiredPolicyActivationSignatures(unknown, 2), 1);
    }

    function test_RequiredSigs_SingleAdmin() public {
        _lockOnboarding();
        _removeUser("1");
        assertEq(state.getActiveAdmins(CLIENT_ID), 1);
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 1), 1);
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 5), 1);
    }

    function test_RequiredSigs_TwoAdmins() public {
        _lockOnboarding();
        assertEq(state.getActiveAdmins(CLIENT_ID), 2);
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 1), 2);
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 2), 2);
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 3), 2);
    }

    function test_RequiredSigs_ThreeAdmins() public {
        _lockOnboarding();
        _addClientUser("4", dave, true, "admin");
        assertEq(state.getActiveAdmins(CLIENT_ID), 3);
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 1), 3);
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 2), 2);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  The onboarding phase (§4.3, round 4)
    //
    //  Until the platform locks it, ONE admin signature carries any
    //  activation, whatever the roster and whatever the threshold. It exists
    //  because the product seats co-admins before the first policy: under the
    //  standing rule alone, the second admin's seat would deadlock the client
    //  until that admin came back to co-sign. The cost is that a single admin
    //  can stand up ANY policy while the phase is open, so these tests pin
    //  both halves — the permission, and the lock that ends it.
    // ═════════════════════════════════════════════════════════════════════════

    function test_Onboarding_StartsOpenForAFreshClient() public view {
        assertFalse(state.onboardingComplete(CLIENT_ID));
    }

    function test_Onboarding_RequiredSigsIsOneForTwoAdmins() public view {
        assertEq(state.getActiveAdmins(CLIENT_ID), 2);
        // The v0 rule would answer 2 at every threshold here.
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 1), 1);
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 2), 1);
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 3), 1);
    }

    function test_Onboarding_RequiredSigsIsOneForThreeAdmins() public {
        _addClientUser("4", dave, true, "admin");
        assertEq(state.getActiveAdmins(CLIENT_ID), 3);
        // The v0 rule would answer 3 at threshold 1 and 2 above it.
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 1), 1);
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 2), 1);
    }

    function test_Onboarding_OneAdminActivatesThresholdOneAlone() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("60");
        string memory authId = "onboarding-t1";

        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK), a, authId)
        );
        assertTrue(state.getPolicy(CLIENT_ID, "60").active);
    }

    function test_Onboarding_OneAdminActivatesThresholdTwoAlone() public {
        // The very shape the v0 rule refuses: a 2-of-2 stood up by one admin.
        // Allowed only while the phase is open, which is the whole risk the
        // platform takes on by not locking promptly.
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("61");
        a.threshold = 2;
        string memory authId = "onboarding-t2";

        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK), a, authId)
        );
        assertTrue(state.getPolicy(CLIENT_ID, "61").active);
        assertEq(state.getPolicy(CLIENT_ID, "61").threshold, 2);
    }

    function test_Onboarding_ThreeAdminsAndOneSignatureStillCarries() public {
        _addClientUser("4", dave, true, "admin");

        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("62");
        string memory authId = "onboarding-three";

        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(ALICE_PK), a, authId)
        );
        assertTrue(state.getPolicy(CLIENT_ID, "62").active);
    }

    function test_Onboarding_TheLoneSignerMustStillBeAnActiveAdmin() public {
        // The phase lowers the COUNT, not the bar on who counts. A member's
        // signature, or an outsider's, carries nothing.
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("63");
        string memory authId = "onboarding-member";
        bytes[] memory memberSig = _signTransfer(_pks(BOB_PK), a, authId);

        vm.expectRevert(CFHelpersPoliciesv1.InvalidSigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, memberSig);

        bytes[] memory strangerSig = _signTransfer(_pks(STRANGER_PK), a, authId);
        vm.expectRevert(CFHelpersPoliciesv1.InvalidSigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, strangerSig);
    }

    function test_Onboarding_NoSignaturesIsStillRefused() public {
        // The floor is one signature in both phases: the phase never makes an
        // activation caller-authorized.
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("64");
        vm.expectRevert(CFHelpersPoliciesv1.SignerCountMismatch.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, "onboarding-none", new bytes[](0));
    }

    function test_Onboarding_TheLockPutsTheV0RuleBack() public {
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 2), 1);

        _lockOnboarding();

        assertTrue(state.onboardingComplete(CLIENT_ID));
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 1), 2);
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 2), 2);

        // One signature no longer carries an activation...
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("65");
        string memory authId = "onboarding-locked";
        bytes[] memory solo = _signTransfer(_pks(DEPLOYER_PK), a, authId);

        vm.expectRevert(CFHelpersPoliciesv1.SignerCountMismatch.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, solo);

        // ...and two do.
        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK, ALICE_PK), a, authId)
        );
        assertTrue(state.getPolicy(CLIENT_ID, "65").active);
    }

    function test_Onboarding_TheLockIsPerClient() public {
        _lockOnboarding();

        // A second client opened later runs its own phase, still open.
        bytes32 otherClientId = sha256(bytes("Globex"));
        vm.prank(usersEOA);
        state.newClient(otherClientId, "0", deployer, "FREE");
        vm.prank(usersEOA);
        state.addUser(otherClientId, "1", alice, true, "admin");

        assertEq(state.getActiveAdmins(otherClientId), 2);
        assertEq(
            policies.requiredPolicyActivationSignatures(otherClientId, 2),
            1
        );
        assertEq(policies.requiredPolicyActivationSignatures(CLIENT_ID, 2), 2);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  12-16  activateTransferPolicy — happy path
    // ═════════════════════════════════════════════════════════════════════════

    function test_Transfer_StoresIdsThresholdAndAllowlist() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("10");
        a.signerIds = _ids("0", "2", "3");
        a.threshold = 2;
        a.recipients = _addrs(RECIPIENT_A, RECIPIENT_B);
        string memory authId = "transfer-activate-1";

        vm.expectEmit(true, false, false, true, address(state));
        emit PolicyActivated(CLIENT_ID, "10");

        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK, ALICE_PK), a, authId)
        );

        CFHelpersStatev1.Policy memory p = state.getPolicy(CLIENT_ID, "10");
        assertTrue(p.active);
        assertEq(p.title, "Ops transfers");
        assertEq(p.policyType, POLICY_TYPE);
        assertFalse(p.isTransaction);
        assertEq(p.threshold, 2);

        // Identities, not addresses (§3.1).
        assertEq(p.signerIds.length, 3);
        assertEq(p.signerIds[0], _idHash("0"));
        assertEq(p.signerIds[1], _idHash("2"));
        assertEq(p.signerIds[2], _idHash("3"));

        assertEq(p.transferDetails.token, TOKEN);
        assertEq(p.transferDetails.maxAmount, 2500);
        assertEq(p.transferDetails.recipients.length, 2);
        assertEq(p.transferDetails.recipients[0], RECIPIENT_A);
        assertEq(p.transferDetails.recipients[1], RECIPIENT_B);

        // The transaction option group is zeroed, so nothing of it reached a
        // signer's device and nothing of it is stored.
        assertEq(p.transactionDetails.wrapper, address(0));
        assertEq(p.transactionDetails.func, "");
    }

    function test_Transfer_MarksExactlyTheNamedIds() public {
        _activate("11", "transfer-activate-signers");

        assertTrue(state.isPolicySigner(CLIENT_ID, "11", _idHash("0")));
        assertTrue(state.isPolicySigner(CLIENT_ID, "11", _idHash("2")));
        // "1" (alice) co-signed the activation but is not on the policy.
        assertFalse(state.isPolicySigner(CLIENT_ID, "11", _idHash("1")));
    }

    function test_Transfer_EmptyRecipientListIsUnrestricted() public {
        _activate("12", "transfer-activate-open");
        CFHelpersStatev1.Policy memory p = state.getPolicy(CLIENT_ID, "12");
        assertEq(p.transferDetails.recipients.length, 0);
    }

    function test_Transfer_NoCallerCheck() public {
        // The v1 change: the sponsor smart account (and, in tests, any
        // account) submits; the consensus signatures are the authorization.
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("13");
        string memory authId = "transfer-activate-stranger";

        vm.prank(stranger);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK, ALICE_PK), a, authId)
        );

        assertTrue(state.getPolicy(CLIENT_ID, "13").active);
    }

    function test_Transfer_ConsumesAuthIdInState() public {
        string memory authId = "transfer-activate-consumed";
        _activate("14", authId);

        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("15");
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  17-18  activateTransactionPolicy — happy path
    // ═════════════════════════════════════════════════════════════════════════

    function test_Transaction_StoresWrapperWithTransferZeroed() public {
        CFHelpersPoliciesv1.TransactionPolicyArgs memory a = _transactionArgs(
            "20"
        );
        a.threshold = 2;
        string memory authId = "transaction-activate-1";

        vm.expectEmit(true, false, false, true, address(state));
        emit PolicyActivated(CLIENT_ID, "20");

        vm.prank(deployer);
        policies.activateTransactionPolicy(
            a,
            authId,
            _signTransaction(_pks(DEPLOYER_PK, ALICE_PK), a, authId)
        );

        CFHelpersStatev1.Policy memory p = state.getPolicy(CLIENT_ID, "20");
        assertTrue(p.active);
        assertTrue(p.isTransaction);
        assertEq(p.threshold, 2);
        assertEq(p.transactionDetails.wrapper, WRAPPER);
        assertEq(p.transactionDetails.func, "supply");
        assertEq(p.signerIds.length, 2);
        assertEq(p.signerIds[0], _idHash("0"));
        assertEq(p.signerIds[1], _idHash("2"));

        assertEq(p.transferDetails.token, address(0));
        assertEq(p.transferDetails.maxAmount, 0);
        assertEq(p.transferDetails.recipients.length, 0);
        assertTrue(state.isPolicySigner(CLIENT_ID, "20", _idHash("2")));
    }

    function test_Transaction_ApprovalDoesNotCarryToTransfer() public {
        // The two activations have different typehashes, so a transaction
        // approval recovers to nobody useful when replayed as a transfer.
        CFHelpersPoliciesv1.TransactionPolicyArgs memory txArgs = _transactionArgs(
            "21"
        );
        string memory authId = "variant-crossover";
        bytes[] memory sigs = _signTransaction(
            _pks(DEPLOYER_PK, ALICE_PK),
            txArgs,
            authId
        );

        CFHelpersPoliciesv1.TransferPolicyArgs memory trArgs = _transferArgs(
            "21"
        );
        vm.expectRevert(CFHelpersPoliciesv1.InvalidSigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(trArgs, authId, sigs);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  19-23  Admin consensus — the standing rule, after the onboarding lock
    //
    //  Every test here opens with `_lockOnboarding()` on purpose: it is the
    //  post-onboarding rule they assert, and a fresh client's phase is open,
    //  where one signature carries everything (see the onboarding section).
    // ═════════════════════════════════════════════════════════════════════════

    function test_Consensus_OneAdminSignsAlone() public {
        _lockOnboarding();
        _removeUser("1");

        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("30");
        string memory authId = "consensus-solo-admin";

        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK), a, authId)
        );
        assertTrue(state.getPolicy(CLIENT_ID, "30").active);
    }

    function test_Consensus_TwoAdminsThresholdOneNeedsBoth() public {
        _lockOnboarding();

        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("31");
        string memory authId = "consensus-two-t1";

        vm.expectRevert(CFHelpersPoliciesv1.SignerCountMismatch.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK), a, authId)
        );

        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK, ALICE_PK), a, authId)
        );
        assertTrue(state.getPolicy(CLIENT_ID, "31").active);
    }

    function test_Consensus_TwoAdminsThresholdTwoNeedsTwo() public {
        // The vector this rule exists for: a rogue admin invites a puppet
        // member, names them the second signer of a 2-of-2 and activates alone.
        // Open exactly this way during onboarding, which is why the platform
        // must lock the phase as soon as its flow finishes.
        _lockOnboarding();

        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("32");
        a.threshold = 2;
        string memory authId = "consensus-two-t2";

        vm.expectRevert(CFHelpersPoliciesv1.SignerCountMismatch.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK), a, authId)
        );

        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK, ALICE_PK), a, authId)
        );
        assertTrue(state.getPolicy(CLIENT_ID, "32").active);
    }

    function test_Consensus_ThreeAdminsThresholdOneNeedsAll() public {
        _lockOnboarding();
        _addClientUser("4", dave, true, "admin");

        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("33");
        string memory authId = "consensus-three-t1";

        vm.expectRevert(CFHelpersPoliciesv1.SignerCountMismatch.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK, ALICE_PK), a, authId)
        );

        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(DEPLOYER_PK, ALICE_PK, DAVE_PK), a, authId)
        );
        assertTrue(state.getPolicy(CLIENT_ID, "33").active);
    }

    function test_Consensus_ThreeAdminsThresholdTwoNeedsTwo() public {
        _lockOnboarding();
        _addClientUser("4", dave, true, "admin");

        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("34");
        a.threshold = 2;
        string memory authId = "consensus-three-t2";

        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            authId,
            _signTransfer(_pks(ALICE_PK, DAVE_PK), a, authId)
        );
        assertTrue(state.getPolicy(CLIENT_ID, "34").active);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  24-35  Signature-set negatives
    // ═════════════════════════════════════════════════════════════════════════

    function testRevert_NoSignaturesAtAll() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("40");
        vm.expectRevert(CFHelpersPoliciesv1.SignerCountMismatch.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, "sigs-none", new bytes[](0));
    }

    function testRevert_CoSignerIsMemberNotAdmin() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("41");
        string memory authId = "sigs-member";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, BOB_PK),
            a,
            authId
        );
        vm.expectRevert(CFHelpersPoliciesv1.InvalidSigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    function testRevert_CoSignerIsNotAClientUser() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("42");
        string memory authId = "sigs-stranger";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, STRANGER_PK),
            a,
            authId
        );
        vm.expectRevert(CFHelpersPoliciesv1.InvalidSigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    function testRevert_SurplusNonAdminSignature() public {
        // The count check is `>=`, but every signature in the batch is checked.
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("43");
        string memory authId = "sigs-surplus";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK, STRANGER_PK),
            a,
            authId
        );
        vm.expectRevert(CFHelpersPoliciesv1.InvalidSigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    function testRevert_SignaturesNotSortedAscending() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("44");
        string memory authId = "sigs-unsorted";
        bytes[] memory sorted = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );
        bytes[] memory unsorted = new bytes[](2);
        unsorted[0] = sorted[1];
        unsorted[1] = sorted[0];

        vm.expectRevert(CFHelpersPoliciesv1.InvalidSignature.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, unsorted);
    }

    function testRevert_OneAdminSignsTwice() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("45");
        string memory authId = "sigs-duplicate";
        bytes memory sig = _sign(DEPLOYER_PK, _transferDigest(a, authId));
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = sig;
        sigs[1] = sig;

        vm.expectRevert(CFHelpersPoliciesv1.InvalidSignature.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    function testRevert_MalformedSignatureBytes() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("46");
        string memory authId = "sigs-garbage";
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(DEPLOYER_PK, _transferDigest(a, authId));
        // v = 1 is not a legal recovery id, so ecrecover yields address(0).
        sigs[1] = abi.encodePacked(
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            uint8(1)
        );

        vm.expectRevert(CFHelpersPoliciesv1.InvalidSignature.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    function testRevert_PayloadTamperedAfterSigning() public {
        // The digest commits to every field, so a submitter cannot collect
        // approvals for one policy and store another.
        CFHelpersPoliciesv1.TransferPolicyArgs memory signedArgs = _transferArgs(
            "47"
        );
        signedArgs.maxAmount = 100;
        string memory authId = "sigs-tampered";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            signedArgs,
            authId
        );

        signedArgs.maxAmount = 1_000_000;
        vm.expectRevert(CFHelpersPoliciesv1.InvalidSigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(signedArgs, authId, sigs);
    }

    function testRevert_ThresholdSwappedAfterSigning() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("48");
        a.threshold = 2;
        string memory authId = "sigs-threshold-swap";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );

        a.threshold = 1;
        vm.expectRevert(CFHelpersPoliciesv1.InvalidSigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    function testRevert_RecipientAllowlistWidenedAfterSigning() public {
        // v0 hid recipients behind `trRecipientsHash`; they are signed data
        // now, and they are still committed.
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("49");
        a.recipients = _addrs(RECIPIENT_A);
        string memory authId = "sigs-recipients-swap";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );

        a.recipients = _addrs(RECIPIENT_A, RECIPIENT_B);
        vm.expectRevert(CFHelpersPoliciesv1.InvalidSigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    function testRevert_SignerSetSwappedAfterSigning() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("50");
        a.signerIds = _ids("0", "2");
        string memory authId = "sigs-signerids-swap";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );

        a.signerIds = _ids("0", "3");
        vm.expectRevert(CFHelpersPoliciesv1.InvalidSigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    function testRevert_AdminRemovedAfterSigning() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("51");
        string memory authId = "sigs-admin-removed";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );

        _removeUser("1");

        vm.expectRevert(CFHelpersPoliciesv1.InvalidSigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  36-45  Input validation in the helper
    // ═════════════════════════════════════════════════════════════════════════

    function testRevert_CompanyDoesNotHashToClientId() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("60");
        a.company = "Acme Inc";
        vm.expectRevert(CFHelpersPoliciesv1.InvalidCompany.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, "input-company", new bytes[](0));
    }

    function testRevert_ClientIdDoesNotMatchCompany() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("61");
        a.clientId = sha256(bytes("Other"));
        vm.expectRevert(CFHelpersPoliciesv1.InvalidCompany.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, "input-clientid", new bytes[](0));
    }

    function testRevert_CompanyMismatchOnTransactionVariant() public {
        CFHelpersPoliciesv1.TransactionPolicyArgs memory a = _transactionArgs(
            "62"
        );
        a.company = "acme";
        vm.expectRevert(CFHelpersPoliciesv1.InvalidCompany.selector);
        vm.prank(deployer);
        policies.activateTransactionPolicy(
            a,
            "input-company-tx",
            new bytes[](0)
        );
    }

    function testRevert_EmptyTitle() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("63");
        a.title = "";
        vm.expectRevert(CFHelpersPoliciesv1.InvalidTitle.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, "input-title", new bytes[](0));
    }

    function testRevert_ZeroThreshold() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("64");
        a.threshold = 0;
        vm.expectRevert(CFHelpersPoliciesv1.InvalidThreshold.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, "input-threshold", new bytes[](0));
    }

    function testRevert_EmptySignerList() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("65");
        a.signerIds = new string[](0);
        vm.expectRevert(CFHelpersPoliciesv1.SignersLength.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            "input-signers-empty",
            new bytes[](0)
        );
    }

    function testRevert_FewerSignersThanThreshold() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("66");
        a.signerIds = _ids("0");
        a.threshold = 2;
        vm.expectRevert(CFHelpersPoliciesv1.SignersLength.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(
            a,
            "input-signers-short",
            new bytes[](0)
        );
    }

    function testRevert_TransferTokenIsZero() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("67");
        a.token = address(0);
        vm.expectRevert(CFHelpersPoliciesv1.InvalidType.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, "input-token-zero", new bytes[](0));
    }

    function testRevert_TransactionWrapperIsZero() public {
        CFHelpersPoliciesv1.TransactionPolicyArgs memory a = _transactionArgs(
            "68"
        );
        a.wrapper = address(0);
        vm.expectRevert(CFHelpersPoliciesv1.InvalidType.selector);
        vm.prank(deployer);
        policies.activateTransactionPolicy(
            a,
            "input-wrapper-zero",
            new bytes[](0)
        );
    }

    function testRevert_TransactionVariantSharesShapeChecks() public {
        CFHelpersPoliciesv1.TransactionPolicyArgs memory a = _transactionArgs(
            "69"
        );
        a.title = "";
        vm.expectRevert(CFHelpersPoliciesv1.InvalidTitle.selector);
        vm.prank(deployer);
        policies.activateTransactionPolicy(
            a,
            "input-tx-title",
            new bytes[](0)
        );

        CFHelpersPoliciesv1.TransactionPolicyArgs memory b = _transactionArgs(
            "70"
        );
        b.signerIds = new string[](0);
        vm.expectRevert(CFHelpersPoliciesv1.SignersLength.selector);
        vm.prank(deployer);
        policies.activateTransactionPolicy(
            b,
            "input-tx-signers",
            new bytes[](0)
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  46-51  Validation State owns (§3.2, §3.4), plus the type gate that moved
    // ═════════════════════════════════════════════════════════════════════════

    function testRevert_UnknownSignerId() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("80");
        a.signerIds = _ids("0", "nobody");
        string memory authId = "state-unknown-signer";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );
        vm.expectRevert(CFHelpersStatev1.InvalidPolicySigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    function testRevert_RemovedSignerId() public {
        _addClientUser("4", dave, false, "contractor");
        _removeUser("4");

        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("81");
        a.signerIds = _ids("0", "4");
        string memory authId = "state-removed-signer";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );
        vm.expectRevert(CFHelpersStatev1.InvalidPolicySigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    function testRevert_DuplicateSignerId() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("82");
        a.signerIds = _ids("0", "0");
        a.threshold = 2;
        string memory authId = "state-duplicate-signer";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );
        vm.expectRevert(CFHelpersStatev1.DuplicatePolicySigner.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    function testRevert_ZeroAddressInAllowlist() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("83");
        a.recipients = _addrs(RECIPIENT_A, address(0));
        string memory authId = "state-zero-recipient";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );
        vm.expectRevert(CFHelpersStatev1.InvalidRecipient.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    /// Round 2: the supported-type gate is enforced by the HELPER, before the
    /// authId is consumed and before any signature is looked at.
    function testRevert_UnsupportedPolicyType() public {
        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("84");
        a.policyType = "Not_A_Type";
        vm.expectRevert(CFHelpersPoliciesv1.InvalidPolicyType.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, "state-bad-type", new bytes[](0));
    }

    function testRevert_PolicyIdAlreadyTaken() public {
        _activate("85", "state-policy-first");

        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("85");
        a.title = "Second try";
        string memory authId = "state-policy-second";
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );
        vm.expectRevert(CFHelpersStatev1.InvalidPolicy.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    /// Documents where the supported-type rule now lives: State is a storage
    /// layer and will accept any type from its registered policies helper. The
    /// gate above is the only thing standing between a caller and a policy of
    /// an unregistered type, which is why it is tested on the helper.
    function test_StateNoLongerEnforcesPolicyType() public {
        vm.prank(govEOA);
        state.setHelperContract("policies", policiesEOA);

        vm.prank(policiesEOA);
        state.activatePolicy(
            CLIENT_ID,
            "999",
            "Not_A_Type",
            "bogus",
            _ids("0"),
            1,
            CFHelpersStatev1.Transaction({wrapper: address(0), func: ""}),
            CFHelpersStatev1.Transfer({
                maxAmount: 1,
                token: TOKEN,
                recipients: new address[](0)
            }),
            false
        );

        CFHelpersStatev1.Policy memory p = state.getPolicy(CLIENT_ID, "999");
        assertTrue(p.active);
        assertEq(p.policyType, "Not_A_Type");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  52-54  Replay protection (§4.1)
    // ═════════════════════════════════════════════════════════════════════════

    function testRevert_AuthIdReused() public {
        string memory authId = "replay-shared";
        _activate("90", authId);

        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("91");
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    /// Round 6 inverts this. The store is keyed `(clientId, authId)` and by
    /// nothing else, so an id the users helper burned is burned for policies
    /// too: one `authId`, one use, per client, across every consumer (§4.1).
    /// That is what makes it safe for the EIP-712 domain to name State rather
    /// than the verifying contract -- a signature spent on one helper cannot
    /// be replayed on its successor.
    function testRevert_AuthIdBurnedByAnotherConsumer() public {
        string memory authId = "replay-namespaced";
        vm.prank(usersEOA);
        state.setClientContractAuthID(CLIENT_ID, authId);

        CFHelpersPoliciesv1.TransferPolicyArgs memory a = _transferArgs("92");
        bytes[] memory sigs = _signTransfer(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        vm.prank(deployer);
        policies.activateTransferPolicy(a, authId, sigs);
    }

    function testRevert_AuthIdBurnedAcrossVariants() public {
        string memory authId = "replay-across-variants";
        _activate("93", authId);

        CFHelpersPoliciesv1.TransactionPolicyArgs memory a = _transactionArgs(
            "94"
        );
        bytes[] memory sigs = _signTransaction(
            _pks(DEPLOYER_PK, ALICE_PK),
            a,
            authId
        );
        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        vm.prank(deployer);
        policies.activateTransactionPolicy(a, authId, sigs);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  55-62  deactivatePolicy
    // ═════════════════════════════════════════════════════════════════════════

    function test_Deactivate_OnOneActiveAdminSignature() public {
        _activate("100", "deactivate-setup-100");
        string memory authId = "deactivate-ok";
        bytes memory sig = _sign(
            ALICE_PK,
            _deactivationDigest(COMPANY, "100", authId)
        );

        vm.expectEmit(true, false, false, true, address(state));
        emit PolicyDeactivated(CLIENT_ID, "100");

        vm.prank(stranger);
        policies.deactivatePolicy(CLIENT_ID, COMPANY, "100", authId, sig);

        assertFalse(state.getPolicy(CLIENT_ID, "100").active);
    }

    function testRevert_DeactivateBySignerWhoIsAMember() public {
        _activate("100", "deactivate-setup-100");
        string memory authId = "deactivate-member";
        bytes memory sig = _sign(
            BOB_PK,
            _deactivationDigest(COMPANY, "100", authId)
        );

        vm.expectRevert(CFHelpersPoliciesv1.InvalidAdmin.selector);
        vm.prank(deployer);
        policies.deactivatePolicy(CLIENT_ID, COMPANY, "100", authId, sig);
    }

    function testRevert_DeactivateBySignerWhoIsNotAClientUser() public {
        _activate("100", "deactivate-setup-100");
        string memory authId = "deactivate-stranger";
        bytes memory sig = _sign(
            STRANGER_PK,
            _deactivationDigest(COMPANY, "100", authId)
        );

        vm.expectRevert(CFHelpersPoliciesv1.UnauthorizedCaller.selector);
        vm.prank(deployer);
        policies.deactivatePolicy(CLIENT_ID, COMPANY, "100", authId, sig);
    }

    function testRevert_DeactivateBySignerWhoWasRemoved() public {
        _activate("100", "deactivate-setup-100");
        string memory authId = "deactivate-removed";
        bytes memory sig = _sign(
            ALICE_PK,
            _deactivationDigest(COMPANY, "100", authId)
        );
        _removeUser("1");

        vm.expectRevert(CFHelpersPoliciesv1.InactiveUser.selector);
        vm.prank(deployer);
        policies.deactivatePolicy(CLIENT_ID, COMPANY, "100", authId, sig);
    }

    function testRevert_DeactivateCompanyMismatch() public {
        _activate("100", "deactivate-setup-100");
        string memory authId = "deactivate-company";
        bytes memory sig = _sign(
            ALICE_PK,
            _deactivationDigest("Acme Inc", "100", authId)
        );

        vm.expectRevert(CFHelpersPoliciesv1.InvalidCompany.selector);
        vm.prank(deployer);
        policies.deactivatePolicy(CLIENT_ID, "Acme Inc", "100", authId, sig);
    }

    function testRevert_DeactivateApprovalIsBoundToItsPolicy() public {
        // v0 deactivated on a `ForwardRequest` that named no policy at all.
        _activate("100", "deactivate-setup-100");
        _activate("101", "deactivate-setup-101");

        string memory authId = "deactivate-wrong-policy";
        bytes memory sigForHundred = _sign(
            ALICE_PK,
            _deactivationDigest(COMPANY, "100", authId)
        );

        vm.expectRevert(CFHelpersPoliciesv1.UnauthorizedCaller.selector);
        vm.prank(deployer);
        policies.deactivatePolicy(
            CLIENT_ID,
            COMPANY,
            "101",
            authId,
            sigForHundred
        );
    }

    function testRevert_DeactivateConsumesItsAuthId() public {
        _activate("100", "deactivate-setup-100");
        string memory authId = "deactivate-replay";

        vm.prank(deployer);
        policies.deactivatePolicy(
            CLIENT_ID,
            COMPANY,
            "100",
            authId,
            _sign(ALICE_PK, _deactivationDigest(COMPANY, "100", authId))
        );

        _activate("102", "deactivate-setup-102");

        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        vm.prank(deployer);
        policies.deactivatePolicy(
            CLIENT_ID,
            COMPANY,
            "102",
            authId,
            _sign(ALICE_PK, _deactivationDigest(COMPANY, "102", authId))
        );
    }

    function testRevert_DeactivateAnAlreadyInactivePolicy() public {
        _activate("100", "deactivate-setup-100");

        vm.prank(deployer);
        policies.deactivatePolicy(
            CLIENT_ID,
            COMPANY,
            "100",
            "deactivate-once",
            _sign(
                ALICE_PK,
                _deactivationDigest(COMPANY, "100", "deactivate-once")
            )
        );

        vm.expectRevert(CFHelpersStatev1.InvalidPolicy.selector);
        vm.prank(deployer);
        policies.deactivatePolicy(
            CLIENT_ID,
            COMPANY,
            "100",
            "deactivate-twice",
            _sign(
                ALICE_PK,
                _deactivationDigest(COMPANY, "100", "deactivate-twice")
            )
        );
    }
}
