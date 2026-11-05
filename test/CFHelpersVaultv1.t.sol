// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {CFHelpersVaultFactoryv1} from "../contracts/CFHelpersVaultFactoryv1.sol";
import {CFHelpersVaultTemplatev1} from "../contracts/CFHelpersVaultTemplatev1.sol";
import {MockToken} from "../contracts/MockToken.sol";
import {MockDeFi} from "../contracts/MockDeFi.sol";
import {MockWrapper} from "../contracts/MockWrapper.sol";

/// WP5 acceptance tests for the v1 vault: identity-resolved signers (rotation
/// and removal propagate with no policy re-issue), the enforced recipient
/// allowlist, `Allowance[]` as signed data, the guard-aware broadcaster gate,
/// and the stateless factory.
///
/// State is driven directly: gov / users / policies / sponsorGuard are plain
/// EOAs registered as helper contracts, so the vault runs against real State
/// v1 storage without the other helpers in the loop.
contract CFHelpersVaultv1Test is Test {
    /* ----------  frozen §4.2 type strings, re-derived independently  ---------- */

    bytes32 internal constant TR_TYPEHASH =
        keccak256(
            "Transfer(string company,string policyId,string messageType,uint256 amount,address token,address recipient,string authId)"
        );
    bytes32 internal constant TX_TYPEHASH =
        keccak256(
            "Transaction(string company,string policyId,string messageType,address wrapper,string func,Allowance[] allowances,bytes32 instructionsHash,string authId)Allowance(address asset,uint256 amount)"
        );
    bytes32 internal constant ALLOWANCE_TYPEHASH =
        keccak256("Allowance(address asset,uint256 amount)");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes32 internal constant APPROVAL_TOPIC =
        keccak256("Approval(address,address,uint256)");

    string internal constant COMPANY = "Acme";
    string internal constant POLICY_TYPE = "Operational_Expense";
    string internal constant TX_POLICY_TYPE = "Treasury_Management";

    /* ----------  actors  ---------- */

    uint256 internal constant PK_ALICE = uint256(keccak256("alice"));
    uint256 internal constant PK_BOB = uint256(keccak256("bob"));
    uint256 internal constant PK_CAROL = uint256(keccak256("carol"));
    uint256 internal constant PK_ALICE_NEW = uint256(keccak256("alice-new"));
    uint256 internal constant PK_OUTSIDER = uint256(keccak256("outsider"));

    address internal deployer; // Cofund admin + fee recipient
    address internal govEOA;
    address internal usersEOA;
    address internal policiesEOA;
    address internal guardEOA;
    address internal adminUser;
    address internal outsiderEOA;
    address internal r1;
    address internal r2;
    address internal r3;

    address internal alice;
    address internal bob;
    address internal carol;
    address internal aliceNew;
    address internal outsiderSigner;

    /* ----------  system under test  ---------- */

    CFHelpersStatev1 internal state;
    CFHelpersVaultFactoryv1 internal factory;
    CFHelpersVaultTemplatev1 internal vault;
    MockToken internal token;
    MockDeFi internal defi;
    MockWrapper internal wrapper;

    bytes32 internal clientId;

    function setUp() public {
        deployer = makeAddr("deployer");
        govEOA = makeAddr("gov");
        usersEOA = makeAddr("users");
        policiesEOA = makeAddr("policies");
        guardEOA = makeAddr("sponsorGuard");
        adminUser = makeAddr("acme-admin");
        outsiderEOA = makeAddr("outsider-eoa");
        r1 = makeAddr("r1");
        r2 = makeAddr("r2");
        r3 = makeAddr("r3");

        alice = vm.addr(PK_ALICE);
        bob = vm.addr(PK_BOB);
        carol = vm.addr(PK_CAROL);
        aliceNew = vm.addr(PK_ALICE_NEW);
        outsiderSigner = vm.addr(PK_OUTSIDER);

        clientId = sha256(bytes(COMPANY));

        token = new MockToken();
        defi = new MockDeFi(address(token));
        wrapper = new MockWrapper(address(defi));

        vm.prank(deployer);
        state = new CFHelpersStatev1(deployer);

        factory = new CFHelpersVaultFactoryv1(address(state));

        vm.prank(deployer);
        state.setGovHelperContract(govEOA);

        vm.startPrank(govEOA);
        state.setHelperContract("vaults", address(factory));
        state.setHelperContract("users", usersEOA);
        state.setHelperContract("policies", policiesEOA);
        state.setHelperContract("sponsorGuard", guardEOA);
        vm.stopPrank();

        // Onboard Acme. newClient installs the founding admin and deploys the
        // vault through the factory in one call.
        vm.prank(usersEOA);
        state.newClient(clientId, "admin", adminUser, "FREE");

        (address vaultAddr, ) = state.clientVaults(clientId);
        vault = CFHelpersVaultTemplatev1(vaultAddr);

        _addMember("alice", alice);
        _addMember("bob", bob);
        _addMember("carol", carol);

        token.mint(address(vault), 1_000_000);
    }

    /* ==================================================================
     *  fixture helpers
     * ================================================================== */

    function _addMember(string memory userId, address member) internal {
        vm.prank(usersEOA);
        state.addUser(clientId, userId, member, false, "eng");
    }

    function _ids1(string memory a) internal pure returns (string[] memory o) {
        o = new string[](1);
        o[0] = a;
    }

    function _ids2(
        string memory a,
        string memory b
    ) internal pure returns (string[] memory o) {
        o = new string[](2);
        o[0] = a;
        o[1] = b;
    }

    function _ids3(
        string memory a,
        string memory b,
        string memory c
    ) internal pure returns (string[] memory o) {
        o = new string[](3);
        o[0] = a;
        o[1] = b;
        o[2] = c;
    }

    function _activateTransfer(
        string memory policyId,
        string[] memory signerIds,
        uint256 threshold,
        uint256 maxAmount,
        address[] memory recipients
    ) internal {
        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId,
            policyId,
            POLICY_TYPE,
            string.concat("Policy ", policyId),
            signerIds,
            threshold,
            CFHelpersStatev1.Transaction({wrapper: address(0), func: ""}),
            CFHelpersStatev1.Transfer({
                maxAmount: maxAmount,
                token: address(token),
                recipients: recipients
            }),
            false
        );
    }

    function _activateTransfer(
        string memory policyId,
        string[] memory signerIds,
        uint256 threshold
    ) internal {
        _activateTransfer(
            policyId,
            signerIds,
            threshold,
            10_000,
            new address[](0)
        );
    }

    function _activateTransaction(
        string memory policyId,
        string[] memory signerIds,
        uint256 threshold
    ) internal {
        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId,
            policyId,
            TX_POLICY_TYPE,
            string.concat("Policy ", policyId),
            signerIds,
            threshold,
            CFHelpersStatev1.Transaction({
                wrapper: address(wrapper),
                func: "mint-token"
            }),
            CFHelpersStatev1.Transfer({
                maxAmount: 0,
                token: address(0),
                recipients: new address[](0)
            }),
            true
        );
    }

    /* ==================================================================
     *  EIP-712
     * ================================================================== */

    function _domainSeparator() internal view returns (bytes32) {
        (
            ,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            ,

        ) = vault.eip712Domain();
        return
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    keccak256(bytes(name)),
                    keccak256(bytes(version)),
                    chainId,
                    verifyingContract
                )
            );
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
            );
    }

    struct Tr {
        string company;
        string policyId;
        string messageType;
        uint256 amount;
        address token;
        address recipient;
        string authId;
    }

    function _tr(
        string memory policyId,
        uint256 amount,
        address recipient,
        string memory authId
    ) internal view returns (Tr memory) {
        return
            Tr({
                company: COMPANY,
                policyId: policyId,
                messageType: POLICY_TYPE,
                amount: amount,
                token: address(token),
                recipient: recipient,
                authId: authId
            });
    }

    function _trDigest(Tr memory t) internal view returns (bytes32) {
        return
            _digest(
                keccak256(
                    abi.encode(
                        TR_TYPEHASH,
                        keccak256(bytes(t.company)),
                        keccak256(bytes(t.policyId)),
                        keccak256(bytes(t.messageType)),
                        t.amount,
                        t.token,
                        t.recipient,
                        keccak256(bytes(t.authId))
                    )
                )
            );
    }

    struct Txn {
        string company;
        string policyId;
        string messageType;
        address wrapper;
        string func;
        bytes instructions;
        CFHelpersVaultTemplatev1.Allowance[] allowances;
        string authId;
    }

    function _txn(
        string memory policyId,
        bytes memory instructions,
        CFHelpersVaultTemplatev1.Allowance[] memory allowances,
        string memory authId
    ) internal view returns (Txn memory) {
        return
            Txn({
                company: COMPANY,
                policyId: policyId,
                messageType: TX_POLICY_TYPE,
                wrapper: address(wrapper),
                func: "mint-token",
                instructions: instructions,
                allowances: allowances,
                authId: authId
            });
    }

    function _hashAllowances(
        CFHelpersVaultTemplatev1.Allowance[] memory a
    ) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](a.length);
        for (uint256 i = 0; i < a.length; i++) {
            hashes[i] = keccak256(
                abi.encode(ALLOWANCE_TYPEHASH, a[i].asset, a[i].amount)
            );
        }
        // Empty array hashes to keccak256(""), the EIP-712 empty dynamic array.
        return keccak256(abi.encodePacked(hashes));
    }

    function _txnDigest(Txn memory t) internal view returns (bytes32) {
        return
            _digest(
                keccak256(
                    abi.encode(
                        TX_TYPEHASH,
                        keccak256(bytes(t.company)),
                        keccak256(bytes(t.policyId)),
                        keccak256(bytes(t.messageType)),
                        t.wrapper,
                        keccak256(bytes(t.func)),
                        _hashAllowances(t.allowances),
                        keccak256(t.instructions),
                        keccak256(bytes(t.authId))
                    )
                )
            );
    }

    /* ----------  signing: ascending by recovered address  ---------- */

    function _pks1(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1);
        o[0] = a;
    }

    function _pks2(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory o) {
        o = new uint256[](2);
        o[0] = a;
        o[1] = b;
    }

    function _sortByAddress(
        uint256[] memory pks
    ) internal pure returns (uint256[] memory) {
        for (uint256 i = 1; i < pks.length; i++) {
            uint256 key = pks[i];
            address keyAddr = vm.addr(key);
            uint256 j = i;
            while (j > 0 && vm.addr(pks[j - 1]) > keyAddr) {
                pks[j] = pks[j - 1];
                unchecked {
                    --j;
                }
            }
            pks[j] = key;
        }
        return pks;
    }

    function _sign(
        uint256[] memory pks,
        bytes32 digest
    ) internal pure returns (bytes[] memory sigs) {
        uint256[] memory sorted = _sortByAddress(pks);
        sigs = new bytes[](sorted.length);
        for (uint256 i = 0; i < sorted.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(sorted[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    /* ----------  broadcasting  ---------- */

    function _execTransfer(
        Tr memory t,
        bytes[] memory sigs,
        address broadcaster
    ) internal {
        vm.prank(broadcaster);
        vault.executeTransfer(
            t.company,
            t.policyId,
            t.messageType,
            t.amount,
            t.token,
            t.recipient,
            t.authId,
            sigs
        );
    }

    function _signAndTransfer(
        Tr memory t,
        uint256[] memory pks,
        address broadcaster
    ) internal {
        _execTransfer(t, _sign(pks, _trDigest(t)), broadcaster);
    }

    function _execTransaction(
        Txn memory t,
        bytes[] memory sigs,
        address broadcaster
    ) internal {
        vm.prank(broadcaster);
        vault.executeTransaction(
            t.company,
            t.policyId,
            t.messageType,
            t.wrapper,
            t.func,
            t.instructions,
            t.allowances,
            t.authId,
            sigs
        );
    }

    function _signAndTransact(
        Txn memory t,
        uint256[] memory pks,
        address broadcaster
    ) internal {
        _execTransaction(t, _sign(pks, _txnDigest(t)), broadcaster);
    }

    /// @dev The template's UnauthorizedCaller carries a reason string, so the
    ///      whole error has to be encoded — and the reason pins which branch
    ///      of the broadcaster gate (or of initialize) actually fired.
    function _unauthorized(
        string memory reason
    ) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                CFHelpersVaultTemplatev1.UnauthorizedCaller.selector,
                reason
            );
    }

    function _noAllowances()
        internal
        pure
        returns (CFHelpersVaultTemplatev1.Allowance[] memory)
    {
        return new CFHelpersVaultTemplatev1.Allowance[](0);
    }

    function _oneAllowance(
        address asset,
        uint256 amount
    ) internal pure returns (CFHelpersVaultTemplatev1.Allowance[] memory o) {
        o = new CFHelpersVaultTemplatev1.Allowance[](1);
        o[0] = CFHelpersVaultTemplatev1.Allowance({
            asset: asset,
            amount: amount
        });
    }

    /* ==================================================================
     *  rotation propagates to every policy
     * ================================================================== */

    function test_rotationPropagates_oldKeyOutNewKeyIn_policyUntouched()
        public
    {
        _activateTransfer("rot", _ids3("alice", "bob", "carol"), 2);

        CFHelpersStatev1.Policy memory policyBefore = state.getPolicy(
            clientId,
            "rot"
        );

        // 1. alice + bob execute against the live policy.
        _signAndTransfer(
            _tr("rot", 100, r1, "rot-1"),
            _pks2(PK_ALICE, PK_BOB),
            deployer
        );

        // 2. alice rotates her key. No policy is touched.
        vm.prank(usersEOA);
        state.rotateUser(clientId, "alice", aliceNew);

        // 3. The old key no longer resolves to an identity.
        Tr memory t2 = _tr("rot", 100, r1, "rot-2");
        bytes[] memory oldSigs = _sign(
            _pks2(PK_ALICE, PK_BOB),
            _trDigest(t2)
        );
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSigner.selector);
        _execTransfer(t2, oldSigs, deployer);

        // 4. The new key works immediately, with nothing re-issued.
        _signAndTransfer(
            _tr("rot", 100, r1, "rot-3"),
            _pks2(PK_ALICE_NEW, PK_BOB),
            deployer
        );

        CFHelpersStatev1.Policy memory afterRot = state.getPolicy(
            clientId,
            "rot"
        );
        assertEq(
            keccak256(abi.encode(afterRot.signerIds)),
            keccak256(abi.encode(policyBefore.signerIds)),
            "signer set changed"
        );
        assertEq(afterRot.threshold, policyBefore.threshold, "threshold changed");
        assertTrue(afterRot.active, "policy deactivated");
    }

    /* ==================================================================
     *  removal propagates to every policy
     * ================================================================== */

    function test_removalPropagates_removedSignerRejected() public {
        _activateTransfer("rem", _ids3("alice", "bob", "carol"), 2);

        vm.prank(usersEOA);
        state.removeUser(clientId, "admin", "bob");

        Tr memory t = _tr("rem", 100, r1, "rem-1");
        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _trDigest(t));
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSigner.selector);
        _execTransfer(t, sigs, deployer);

        // The remaining signers still satisfy the same untouched policy.
        _signAndTransfer(
            _tr("rem", 100, r1, "rem-2"),
            _pks2(PK_ALICE, PK_CAROL),
            deployer
        );
    }

    function test_removedMemberCannotBroadcast() public {
        _activateTransfer("rem", _ids3("alice", "bob", "carol"), 2);

        vm.prank(usersEOA);
        state.removeUser(clientId, "admin", "bob");

        Tr memory t = _tr("rem", 100, r1, "rem-3");
        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_CAROL), _trDigest(t));
        vm.expectRevert(_unauthorized("user inactive"));
        _execTransfer(t, sigs, bob);
    }

    /* ==================================================================
     *  recipient allowlist (§3.4)
     * ================================================================== */

    function _allowlistPolicies() internal {
        address[] memory allowed = new address[](2);
        allowed[0] = r1;
        allowed[1] = r2;
        _activateTransfer(
            "allowlist",
            _ids2("alice", "bob"),
            2,
            10_000,
            allowed
        );
        _activateTransfer("open", _ids2("alice", "bob"), 2);
    }

    function test_allowlist_listedRecipientPasses() public {
        _allowlistPolicies();
        _signAndTransfer(
            _tr("allowlist", 100, r1, "al-1"),
            _pks2(PK_ALICE, PK_BOB),
            deployer
        );
        assertEq(token.balanceOf(r1), 100);
    }

    function test_allowlist_unlistedRecipientReverts() public {
        _allowlistPolicies();
        Tr memory t = _tr("allowlist", 100, r3, "al-2");
        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _trDigest(t));
        vm.expectRevert(CFHelpersVaultTemplatev1.RecipientNotAllowed.selector);
        _execTransfer(t, sigs, deployer);
    }

    function test_allowlist_emptyListIsUnrestricted() public {
        _allowlistPolicies();
        _signAndTransfer(
            _tr("open", 100, r3, "al-3"),
            _pks2(PK_ALICE, PK_BOB),
            deployer
        );
        assertEq(token.balanceOf(r3), 100);
    }

    /* ==================================================================
     *  executeTransaction
     * ================================================================== */

    function test_transaction_approvesAllowancesAndResetsToZero() public {
        _activateTransaction("tx", _ids3("alice", "bob", "carol"), 2);

        Txn memory t = _txn(
            "tx",
            abi.encode(uint256(10)),
            _oneAllowance(address(token), 777),
            "tx-1"
        );

        vm.recordLogs();
        _signAndTransact(t, _pks2(PK_ALICE, PK_BOB), deployer);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawApproval;
        bool sawReset;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter != address(token) ||
                logs[i].topics.length != 3 ||
                logs[i].topics[0] != APPROVAL_TOPIC
            ) continue;
            if (
                address(uint160(uint256(logs[i].topics[1]))) != address(vault)
            ) continue;
            if (
                address(uint160(uint256(logs[i].topics[2]))) !=
                address(wrapper)
            ) continue;
            uint256 value = abi.decode(logs[i].data, (uint256));
            if (value == 777) sawApproval = true;
            if (value == 0) sawReset = true;
        }

        assertTrue(sawApproval, "allowance was never approved to the wrapper");
        assertTrue(sawReset, "allowance was never reset");
        assertEq(
            token.allowance(address(vault), address(wrapper)),
            0,
            "allowance left standing"
        );
    }

    function test_transaction_withNoAllowances() public {
        _activateTransaction("tx", _ids3("alice", "bob", "carol"), 2);
        _signAndTransact(
            _txn("tx", abi.encode(uint256(10)), _noAllowances(), "tx-2"),
            _pks2(PK_ALICE, PK_BOB),
            deployer
        );
    }

    function test_transaction_signatureOverDifferentAllowancesReverts()
        public
    {
        // Threshold 1: one recovered address can never trip the ascending
        // check first, so the failure mode is unambiguous.
        _activateTransaction("tx-solo", _ids1("alice"), 1);

        bytes memory instructions = abi.encode(uint256(10));
        Txn memory signed = _txn(
            "tx-solo",
            instructions,
            _oneAllowance(address(token), 777),
            "tx-3"
        );
        Txn memory executed = _txn(
            "tx-solo",
            instructions,
            _oneAllowance(address(token), 1),
            "tx-3"
        );

        bytes[] memory sigs = _sign(_pks1(PK_ALICE), _txnDigest(signed));
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSigner.selector);
        _execTransaction(executed, sigs, deployer);
    }

    function test_transaction_signatureOverDifferentInstructionsReverts()
        public
    {
        _activateTransaction("tx-solo", _ids1("alice"), 1);

        Txn memory signed = _txn(
            "tx-solo",
            abi.encode(uint256(10)),
            _noAllowances(),
            "tx-4"
        );
        Txn memory executed = _txn(
            "tx-solo",
            abi.encode(uint256(11)),
            _noAllowances(),
            "tx-4"
        );

        bytes[] memory sigs = _sign(_pks1(PK_ALICE), _txnDigest(signed));
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSigner.selector);
        _execTransaction(executed, sigs, deployer);
    }

    function test_transaction_wrapperMismatchReverts() public {
        _activateTransaction("tx", _ids3("alice", "bob", "carol"), 2);

        Txn memory t = _txn(
            "tx",
            abi.encode(uint256(10)),
            _noAllowances(),
            "tx-5"
        );
        t.wrapper = address(defi); // not the policy's wrapper

        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _txnDigest(t));
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidType.selector);
        _execTransaction(t, sigs, deployer);
    }

    /// @dev Round 4. `messageType` is in the digest the signers approved, so
    ///      leaving it unchecked let an approval be spent against a policy of
    ///      a different type. `executeTransfer` always bound the two; this is
    ///      the same check, and the pair below shows it is the type — not the
    ///      wrapper, the signatures or the threshold — that refuses.
    function test_transaction_messageTypeMismatchReverts() public {
        _activateTransaction("tx", _ids3("alice", "bob", "carol"), 2);

        Txn memory mismatched = _txn(
            "tx",
            abi.encode(uint256(10)),
            _noAllowances(),
            "tx-type-1"
        );
        mismatched.messageType = POLICY_TYPE; // a real type, the wrong one

        bytes[] memory sigs = _sign(
            _pks2(PK_ALICE, PK_BOB),
            _txnDigest(mismatched)
        );
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidPolicyType.selector);
        _execTransaction(mismatched, sigs, deployer);

        // Byte-identical call, the policy's own type: executes.
        _signAndTransact(
            _txn("tx", abi.encode(uint256(10)), _noAllowances(), "tx-type-2"),
            _pks2(PK_ALICE, PK_BOB),
            deployer
        );
    }

    function test_transaction_unregisteredMessageTypeReverts() public {
        // Equality with the policy's type, not membership of State's supported
        // set -- an unknown string is refused by the same check.
        _activateTransaction("tx", _ids3("alice", "bob", "carol"), 2);

        Txn memory t = _txn(
            "tx",
            abi.encode(uint256(10)),
            _noAllowances(),
            "tx-type-3"
        );
        t.messageType = "Not_A_Type";

        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _txnDigest(t));
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidPolicyType.selector);
        _execTransaction(t, sigs, deployer);
    }

    function test_transaction_emptyMessageTypeReverts() public {
        _activateTransaction("tx", _ids3("alice", "bob", "carol"), 2);

        Txn memory t = _txn(
            "tx",
            abi.encode(uint256(10)),
            _noAllowances(),
            "tx-type-4"
        );
        t.messageType = "";

        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _txnDigest(t));
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidPolicyType.selector);
        _execTransaction(t, sigs, deployer);
    }

    function test_transaction_onATransferPolicyReverts() public {
        _activateTransfer("not-a-tx", _ids2("alice", "bob"), 2);

        Txn memory t = _txn(
            "not-a-tx",
            abi.encode(uint256(10)),
            _noAllowances(),
            "tx-6"
        );
        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _txnDigest(t));
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidType.selector);
        _execTransaction(t, sigs, deployer);
    }

    /* ==================================================================
     *  broadcaster gate (§4.3 / §5)
     * ================================================================== */

    function test_gate_unknownEOACannotBroadcast() public {
        _activateTransfer("gate", _ids2("alice", "bob"), 2);

        Tr memory t = _tr("gate", 100, r1, "gate-1");
        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _trDigest(t));
        vm.expectRevert(_unauthorized("caller not mapped to user"));
        _execTransfer(t, sigs, outsiderEOA);
    }

    function test_gate_sponsorGuardMayBroadcast() public {
        _activateTransfer("gate", _ids2("alice", "bob"), 2);

        // The guard is recognized by its registration, never by an admin bit.
        assertFalse(
            state.isCofundAdmin(guardEOA),
            "guard must not be a Cofund admin"
        );
        assertEq(state.helperContracts("sponsorGuard"), guardEOA);

        _signAndTransfer(
            _tr("gate", 100, r1, "gate-2"),
            _pks2(PK_ALICE, PK_BOB),
            guardEOA
        );
        assertEq(token.balanceOf(r1), 100);
    }

    function test_gate_activeMemberMayBroadcast() public {
        _activateTransfer("gate", _ids2("alice", "bob"), 2);
        _signAndTransfer(
            _tr("gate", 100, r1, "gate-3"),
            _pks2(PK_ALICE, PK_BOB),
            alice
        );
    }

    function test_gate_nonSignerMemberMayBroadcast() public {
        _activateTransfer("gate", _ids2("alice", "bob"), 2);
        _signAndTransfer(
            _tr("gate", 100, r1, "gate-4"),
            _pks2(PK_ALICE, PK_BOB),
            carol
        );
    }

    function test_gate_cofundAdminMayBroadcast() public {
        _activateTransfer("gate", _ids2("alice", "bob"), 2);
        assertTrue(state.isCofundAdmin(deployer));
        _signAndTransfer(
            _tr("gate", 100, r1, "gate-5"),
            _pks2(PK_ALICE, PK_BOB),
            deployer
        );
    }

    /* ==================================================================
     *  signature set rules
     * ================================================================== */

    function test_sigs_thresholdNotMet() public {
        _activateTransfer("sigs", _ids3("alice", "bob", "carol"), 2);

        Tr memory t = _tr("sigs", 100, r1, "sig-1");
        bytes[] memory sigs = _sign(_pks1(PK_ALICE), _trDigest(t));
        vm.expectRevert(CFHelpersVaultTemplatev1.ThresholdNotMet.selector);
        _execTransfer(t, sigs, deployer);
    }

    function test_sigs_unsortedReverts() public {
        _activateTransfer("sigs", _ids3("alice", "bob", "carol"), 2);

        Tr memory t = _tr("sigs", 100, r1, "sig-2");
        bytes[] memory sorted = _sign(_pks2(PK_ALICE, PK_BOB), _trDigest(t));
        bytes[] memory reversed = new bytes[](2);
        reversed[0] = sorted[1];
        reversed[1] = sorted[0];

        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSignature.selector);
        _execTransfer(t, reversed, deployer);
    }

    function test_sigs_duplicateSignerReverts() public {
        _activateTransfer("sigs", _ids3("alice", "bob", "carol"), 2);

        Tr memory t = _tr("sigs", 100, r1, "sig-3");
        bytes[] memory one = _sign(_pks1(PK_ALICE), _trDigest(t));
        bytes[] memory dup = new bytes[](2);
        dup[0] = one[0];
        dup[1] = one[0];

        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSignature.selector);
        _execTransfer(t, dup, deployer);
    }

    function test_sigs_nonMemberReverts() public {
        _activateTransfer("sigs", _ids3("alice", "bob", "carol"), 2);

        Tr memory t = _tr("sigs", 100, r1, "sig-4");
        bytes[] memory sigs = _sign(
            _pks2(PK_ALICE, PK_OUTSIDER),
            _trDigest(t)
        );
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSigner.selector);
        _execTransfer(t, sigs, deployer);
    }

    function test_sigs_activeMemberNotOnPolicyReverts() public {
        _activateTransfer("narrow", _ids2("alice", "bob"), 2);

        Tr memory t = _tr("narrow", 100, r1, "sig-5");
        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_CAROL), _trDigest(t));
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSigner.selector);
        _execTransfer(t, sigs, deployer);
    }

    function test_sigs_overADifferentAmountReverts() public {
        _activateTransfer("solo", _ids1("alice"), 1);

        bytes[] memory sigs = _sign(
            _pks1(PK_ALICE),
            _trDigest(_tr("solo", 100, r1, "sig-6"))
        );
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSigner.selector);
        _execTransfer(_tr("solo", 999, r1, "sig-6"), sigs, deployer);
    }

    function test_sigs_overADifferentRecipientReverts() public {
        _activateTransfer("solo", _ids1("alice"), 1);

        bytes[] memory sigs = _sign(
            _pks1(PK_ALICE),
            _trDigest(_tr("solo", 100, r1, "sig-7"))
        );
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSigner.selector);
        _execTransfer(_tr("solo", 100, r2, "sig-7"), sigs, deployer);
    }

    /* ==================================================================
     *  policy binding and replay
     * ================================================================== */

    function test_bind_mismatchedCompanyReverts() public {
        _activateTransfer("bind", _ids2("alice", "bob"), 2, 500, new address[](0));

        Tr memory t = _tr("bind", 100, r1, "bind-1");
        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _trDigest(t));
        t.company = "NotAcme";

        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidCompany.selector);
        _execTransfer(t, sigs, deployer);
    }

    function test_bind_replayedAuthIdReverts() public {
        _activateTransfer("bind", _ids2("alice", "bob"), 2, 500, new address[](0));

        Tr memory t = _tr("bind", 100, r1, "bind-replay");
        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _trDigest(t));

        _execTransfer(t, sigs, deployer);

        vm.expectRevert(CFHelpersStatev1.KeyExists.selector);
        _execTransfer(t, sigs, deployer);
    }

    function test_bind_unknownPolicyReverts() public {
        Tr memory t = _tr("nope", 100, r1, "bind-2");
        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _trDigest(t));
        vm.expectRevert(CFHelpersVaultTemplatev1.InactivePolicy.selector);
        _execTransfer(t, sigs, deployer);
    }

    function test_bind_amountOverPolicyMaximumReverts() public {
        _activateTransfer("bind", _ids2("alice", "bob"), 2, 500, new address[](0));

        Tr memory t = _tr("bind", 501, r1, "bind-3");
        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _trDigest(t));
        vm.expectRevert(CFHelpersVaultTemplatev1.AmountExceedsPolicy.selector);
        _execTransfer(t, sigs, deployer);
    }

    function test_bind_wrongTokenReverts() public {
        _activateTransfer("bind", _ids2("alice", "bob"), 2, 500, new address[](0));
        MockToken other = new MockToken();

        Tr memory t = _tr("bind", 100, r1, "bind-4");
        t.token = address(other);
        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _trDigest(t));
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidToken.selector);
        _execTransfer(t, sigs, deployer);
    }

    function test_bind_messageTypeMismatchReverts() public {
        _activateTransfer("bind", _ids2("alice", "bob"), 2, 500, new address[](0));

        Tr memory t = _tr("bind", 100, r1, "bind-5");
        t.messageType = "Contractor_Stipend";
        bytes[] memory sigs = _sign(_pks2(PK_ALICE, PK_BOB), _trDigest(t));
        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidPolicyType.selector);
        _execTransfer(t, sigs, deployer);
    }

    /* ==================================================================
     *  subscription fee
     * ================================================================== */

    function test_fee_chargedOnTopOfPrincipal() public {
        _activateTransfer("fee", _ids2("alice", "bob"), 2);

        vm.prank(deployer);
        state.setSubscriptionTier(250, "FREE");
        address feeRecipient = state.cfFeeRecipientAddress();

        uint256 beforeRecipient = token.balanceOf(r1);
        uint256 beforeFee = token.balanceOf(feeRecipient);

        _signAndTransfer(
            _tr("fee", 1_000, r1, "fee-1"),
            _pks2(PK_ALICE, PK_BOB),
            deployer
        );

        // 1000 * 250 / 10000 = 25
        assertEq(token.balanceOf(r1) - beforeRecipient, 1_000, "principal");
        assertEq(token.balanceOf(feeRecipient) - beforeFee, 25, "fee");
    }

    function test_fee_roundsANonZeroFeeUpToOne() public {
        _activateTransfer("fee", _ids2("alice", "bob"), 2);

        vm.prank(deployer);
        state.setSubscriptionTier(250, "FREE");
        address feeRecipient = state.cfFeeRecipientAddress();
        uint256 beforeFee = token.balanceOf(feeRecipient);

        _signAndTransfer(
            _tr("fee", 1, r1, "fee-2"),
            _pks2(PK_ALICE, PK_BOB),
            deployer
        );

        assertEq(token.balanceOf(feeRecipient) - beforeFee, 1, "rounded fee");
    }

    function test_fee_zeroBpsTierChargesNothing() public {
        _activateTransfer("fee", _ids2("alice", "bob"), 2);

        vm.prank(deployer);
        state.setSubscriptionTier(0, "FREE");
        address feeRecipient = state.cfFeeRecipientAddress();

        uint256 beforeRecipient = token.balanceOf(r2);
        uint256 beforeFee = token.balanceOf(feeRecipient);

        _signAndTransfer(
            _tr("fee", 1_000, r2, "fee-3"),
            _pks2(PK_ALICE, PK_BOB),
            deployer
        );

        assertEq(token.balanceOf(r2) - beforeRecipient, 1_000, "principal");
        assertEq(token.balanceOf(feeRecipient) - beforeFee, 0, "no fee");
    }

    /* ==================================================================
     *  stateless factory and initialization
     * ================================================================== */

    function test_factory_predictMatchesStateRegistry() public view {
        (address registered, ) = state.clientVaults(clientId);
        assertEq(registered, address(vault));
        assertEq(
            factory.predictVault(clientId),
            registered,
            "prediction must match State's registry"
        );
    }

    function test_factory_onlyStateMayCreateVault() public {
        bytes32 otherId = sha256(bytes("Someone Else"));

        vm.expectRevert(CFHelpersVaultFactoryv1.UnauthorizedCaller.selector);
        vm.prank(outsiderEOA);
        factory.createVault(otherId);

        // Not even a Cofund admin gets to go around State.
        vm.expectRevert(CFHelpersVaultFactoryv1.UnauthorizedCaller.selector);
        vm.prank(deployer);
        factory.createVault(otherId);

        // Nor the users helper, which is what calls State's newClient.
        vm.expectRevert(CFHelpersVaultFactoryv1.UnauthorizedCaller.selector);
        vm.prank(usersEOA);
        factory.createVault(otherId);
    }

    function test_factory_newClientIsTheOnePathToAVault() public {
        bytes32 otherId = sha256(bytes("Someone Else"));
        address predicted = factory.predictVault(otherId);

        vm.prank(usersEOA);
        state.newClient(otherId, "admin", makeAddr("other-founder"), "FREE");

        (address created, string memory tier) = state.clientVaults(otherId);
        assertEq(created, predicted, "vault is the deterministic clone");
        assertEq(tier, "FREE");
        assertEq(CFHelpersVaultTemplatev1(created).clientId(), otherId);
    }

    function test_factory_secondNewClientForTheSameClientReverts() public {
        vm.expectRevert(CFHelpersStatev1.ClientExists.selector);
        vm.prank(usersEOA);
        state.newClient(
            clientId,
            "admin2",
            makeAddr("second-founder"),
            "FREE"
        );
    }

    function test_vault_bindsCloneToClientAndState() public view {
        assertEq(vault.clientId(), clientId);
        assertEq(address(vault.state()), address(state));
        assertEq(vault.expectedState(), address(state));
        assertEq(vault.factory(), address(factory));
    }

    function test_vault_cannotBeReinitialized() public {
        vm.expectRevert(_unauthorized("caller is not factory"));
        vm.prank(deployer);
        vault.initialize(clientId, address(state));
    }

    /// ERC-5267 in full. Round 6: a vault clone reports the SAME domain the
    /// two helpers do -- `("Cofund", "1", chainId, State)`. That is the whole
    /// point: Ledger clear signing registers one address per chain, and a new
    /// client's vault needs no descriptor of its own (§4.2).
    function test_vault_usesTheFrozenDomain() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = vault.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "Cofund");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(state));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
        assertTrue(verifyingContract != address(vault));
    }

    /// The round-6 change as a negative: a transfer signed under the OLD
    /// per-vault shape (`("Cofund Vault", "1", chainId, vault)`) recovers a
    /// stranger and is refused. Every positive path in this file would pass
    /// under either domain so long as both sides agreed, so this is the test
    /// that actually pins the verifying contract.
    function test_vault_rejectsASignatureUnderThePerVaultDomain() public {
        _activateTransfer("legacy-domain", _ids2("alice", "bob"), 1);

        Tr memory t = _tr("legacy-domain", 500, r1, "auth-legacy-domain");

        bytes32 legacyDomain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("Cofund Vault")),
                keccak256(bytes("1")),
                block.chainid,
                address(vault) // the pre-round-6 verifying contract
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                TR_TYPEHASH,
                keccak256(bytes(t.company)),
                keccak256(bytes(t.policyId)),
                keccak256(bytes(t.messageType)),
                t.amount,
                t.token,
                t.recipient,
                keccak256(bytes(t.authId))
            )
        );

        bytes[] memory legacySigs = _sign(
            _pks1(PK_ALICE),
            keccak256(abi.encodePacked("\x19\x01", legacyDomain, structHash))
        );

        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSigner.selector);
        _execTransfer(t, legacySigs, guardEOA);

        // Identical payload under the shared domain: it goes through. The
        // only difference above was the `verifyingContract`.
        _signAndTransfer(t, _pks1(PK_ALICE), guardEOA);
        assertEq(token.balanceOf(r1), 500);
    }
}
