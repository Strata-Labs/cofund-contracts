// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {CFHelpersVaultFactoryv1} from "../contracts/CFHelpersVaultFactoryv1.sol";
import {CFHelpersVaultTemplatev1} from "../contracts/CFHelpersVaultTemplatev1.sol";
import {CFHelpersVaultFactoryv1_1} from "../contracts/CFHelpersVaultFactoryv1_1.sol";
import {CFHelpersVaultTemplatev1_1} from "../contracts/CFHelpersVaultTemplatev1_1.sol";
import {MockToken} from "../contracts/MockToken.sol";
import {MockDeFi} from "../contracts/MockDeFi.sol";
import {MockWrapper} from "../contracts/MockWrapper.sol";

import {Eip712} from "./utils/Eip712.sol";
import {OzSignatureChecker as SignatureChecker} from "./utils/OzSignatureChecker.sol";

/// @title CFHelpersVaultv1_1Test -- the v1.1 vault's ERC-1271 logins.
///
/// @notice State is driven directly, as in `CFHelpersVaultv1.t.sol`: the
///         helpers are EOAs registered on real State v1 storage. "Legacy" is
///         onboarded through v1's factory before the swap to v1.1's, as on
///         mainnet; "Acme" and "Other" get v1.1 vaults after it.
contract CFHelpersVaultv1_1Test is Test {
    /// @dev Re-derived from docs/erc1271/README.md, not read off the contract.
    bytes32 internal constant LOGIN_TYPEHASH =
        keccak256("SignMessage(string company,string message,uint256 deadline)");
    bytes4 internal constant YES = 0x1626ba7e;
    bytes4 internal constant NO = 0xffffffff;

    string internal constant COMPANY = "Acme";
    string internal constant OTHER = "Other";
    string internal constant LEGACY = "Legacy";
    /// @dev Lombard's challenge, in shape.
    string internal constant TEXT =
        "I have read and accept the Terms of Service and LBTC Product Terms on 2026-10-29T12:00:00Z. Account 0x5bdE80F61216F2D6977D360694E2D468Ea5D744B. Nonce: 9f1c2a";

    uint256 internal constant PK_ADMIN = uint256(keccak256("v1_1.admin"));
    uint256 internal constant PK_ADMIN2 = uint256(keccak256("v1_1.admin2"));
    uint256 internal constant PK_MEMBER = uint256(keccak256("v1_1.member"));
    uint256 internal constant PK_OTHER_ADMIN = uint256(keccak256("v1_1.other-admin"));
    uint256 internal constant PK_LEGACY_ADMIN = uint256(keccak256("v1_1.legacy-admin"));
    uint256 internal constant PK_OUTSIDER = uint256(keccak256("v1_1.outsider"));

    address internal deployer = makeAddr("deployer");
    address internal govEOA = makeAddr("gov");
    address internal usersEOA = makeAddr("users");
    address internal policiesEOA = makeAddr("policies");

    CFHelpersStatev1 internal state;
    CFHelpersVaultFactoryv1_1 internal factory;
    CFHelpersVaultTemplatev1_1 internal vault;
    CFHelpersVaultTemplatev1_1 internal otherVault;
    address internal legacyVault;
    MockToken internal token;
    MockWrapper internal wrapper;

    bytes32 internal clientId = sha256(bytes(COMPANY));

    function setUp() public {
        vm.prank(deployer);
        state = new CFHelpersStatev1(deployer);
        vm.prank(deployer);
        state.setGovHelperContract(govEOA);
        vm.startPrank(govEOA);
        state.setHelperContract("users", usersEOA);
        state.setHelperContract("policies", policiesEOA);
        state.setHelperContract("vaults", address(new CFHelpersVaultFactoryv1(address(state))));
        vm.stopPrank();

        legacyVault = _newClient(LEGACY, PK_LEGACY_ADMIN);

        // The swap: Gov points "vaults" at the v1.1 factory.
        factory = new CFHelpersVaultFactoryv1_1(address(state));
        vm.prank(govEOA);
        state.setHelperContract("vaults", address(factory));

        vault = CFHelpersVaultTemplatev1_1(_newClient(COMPANY, PK_ADMIN));
        otherVault = CFHelpersVaultTemplatev1_1(_newClient(OTHER, PK_OTHER_ADMIN));

        vm.startPrank(usersEOA);
        state.addUser(clientId, "admin2", vm.addr(PK_ADMIN2), true, "cfo");
        state.addUser(clientId, "member", vm.addr(PK_MEMBER), false, "eng");
        vm.stopPrank();

        token = new MockToken();
        wrapper = new MockWrapper(address(new MockDeFi(address(token))));
        token.mint(address(vault), 1_000_000);
    }

    /* ----------  fixture helpers  ---------- */

    function _newClient(string memory company, uint256 pk) internal returns (address v) {
        bytes32 id = sha256(bytes(company)); // before the prank: sha256 is a call
        vm.prank(usersEOA);
        state.newClient(id, "admin", vm.addr(pk), "FREE");
        (v,) = state.clientVaults(id);
    }

    function _loginDigest(string memory company, string memory text, uint256 deadline) internal view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(LOGIN_TYPEHASH, keccak256(bytes(company)), keccak256(bytes(text)), deadline));
        return Eip712.digest(Eip712.domainSeparator(address(state)), structHash);
    }

    function _login(uint256 pk, string memory company, string memory text, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(company, text, deadline, Eip712.sign(pk, _loginDigest(company, text, deadline)));
    }

    function _login(uint256 pk, string memory text) internal view returns (bytes memory) {
        return _login(pk, COMPANY, text, block.timestamp + 1 hours);
    }

    /// @dev `personal_sign`'s hash, built by hand rather than with MessageHashUtils.
    function _personal(string memory text) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", vm.toString(bytes(text).length), text));
    }

    function _answer(string memory text, bytes memory sig) internal view returns (bytes4) {
        return vault.isValidSignature(_personal(text), sig);
    }

    /* ==================================================================
     *  a valid login
     * ================================================================== */

    function test_login_activeAdminPasses() public view {
        bytes memory sig = _login(PK_ADMIN, TEXT);
        assertEq(_answer(TEXT, sig), YES);
        assertTrue(vault.validLogin(_personal(TEXT), sig));
        assertTrue(SignatureChecker.isValidSignatureNow(address(vault), _personal(TEXT), sig), "OZ SignatureChecker");
        assertEq(_answer(TEXT, _login(PK_ADMIN2, TEXT)), YES, "any one active admin");
    }

    /* ==================================================================
     *  plain text only
     * ================================================================== */

    function test_text_emptyRefused() public view {
        assertEq(_answer("", _login(PK_ADMIN, "")), NO);
    }

    function test_text_32BytesRefused() public view {
        string memory b31 = "abcdefghijklmnopqrstuvwxyz01234";
        string memory b32 = "abcdefghijklmnopqrstuvwxyz012345";
        string memory b33 = "abcdefghijklmnopqrstuvwxyz0123456";
        assertEq(_answer(b31, _login(PK_ADMIN, b31)), YES, "31 bytes");
        assertEq(_answer(b32, _login(PK_ADMIN, b32)), NO, "32 bytes");
        assertEq(_answer(b33, _login(PK_ADMIN, b33)), YES, "33 bytes");

        // eth_sign: a raw digest dressed up as a message.
        string memory digest = string(abi.encodePacked(keccak256("a permit")));
        assertEq(_answer(digest, _login(PK_ADMIN, digest)), NO, "a hash as text");
    }

    /// @dev Every C0 byte and DEL: only tab, LF and CR pass.
    function test_text_controlBytesRefused() public view {
        for (uint256 b; b <= 0x7f; b = b == 0x1f ? 0x7f : b + 1) {
            string memory text = string(abi.encodePacked("line one", bytes1(uint8(b)), "line two"));
            bool allowed = b == 0x09 || b == 0x0a || b == 0x0d;
            assertEq(_answer(text, _login(PK_ADMIN, text)), allowed ? YES : NO, vm.toString(b));
        }
    }

    function test_text_multibyteUtf8Passes() public view {
        string memory text = unicode"Grüße — 日本語のログイン ✓ 🚀\r\n\tSign in to the dapp.";
        assertEq(_answer(text, _login(PK_ADMIN, text)), YES);
    }

    /* ==================================================================
     *  the hash is the text's personal_sign hash
     * ================================================================== */

    function test_hash_mismatchRefused() public view {
        bytes memory sig = _login(PK_ADMIN, TEXT);
        uint256 deadline = block.timestamp + 1 hours;
        assertEq(vault.isValidSignature(_personal("another text"), sig), NO, "another text");
        assertEq(vault.isValidSignature(keccak256(bytes(TEXT)), sig), NO, "unprefixed");
        assertEq(vault.isValidSignature(_loginDigest(COMPANY, TEXT, deadline), sig), NO, "the typed-data digest");
    }

    /* ==================================================================
     *  the signer: one active admin of this cofund
     * ================================================================== */

    function test_signer_inactiveAdminRefused() public {
        bytes memory sig = _login(PK_ADMIN2, TEXT);
        assertEq(_answer(TEXT, sig), YES);

        vm.prank(usersEOA);
        state.removeUser(clientId, "admin", "admin2");
        assertEq(_answer(TEXT, sig), NO, "removed admin");
    }

    function test_signer_memberRefused() public view {
        assertEq(_answer(TEXT, _login(PK_MEMBER, TEXT)), NO, "non-admin member");
        assertEq(_answer(TEXT, _login(PK_OUTSIDER, TEXT)), NO, "unmapped key");
    }

    /// @dev An unmapped key reads as userId "", which State lets a user hold.
    function test_signer_unmappedKeyIsNotTheEmptyUserId() public {
        vm.prank(usersEOA);
        state.addUser(clientId, "", makeAddr("empty-id admin"), true, "admin");
        assertEq(_answer(TEXT, _login(PK_OUTSIDER, TEXT)), NO);
    }

    function test_signer_rotatedAdminFollowsTheNewKey() public {
        uint256 pkNew = uint256(keccak256("v1_1.admin2-new"));
        vm.prank(usersEOA);
        state.rotateUser(clientId, "admin2", vm.addr(pkNew));
        assertEq(_answer(TEXT, _login(PK_ADMIN2, TEXT)), NO, "old key");
        assertEq(_answer(TEXT, _login(pkNew, TEXT)), YES, "new key");
    }

    /* ==================================================================
     *  deadline: [now, now + 7 days]
     * ================================================================== */

    function test_deadline_bounds() public {
        vm.warp(1_800_000_000);
        uint256 t = block.timestamp;
        assertEq(_answer(TEXT, _login(PK_ADMIN, COMPANY, TEXT, t)), YES, "exactly now");
        assertEq(_answer(TEXT, _login(PK_ADMIN, COMPANY, TEXT, t + 7 days)), YES, "exactly now + 7 days");
        assertEq(_answer(TEXT, _login(PK_ADMIN, COMPANY, TEXT, t - 1)), NO, "expired");
        assertEq(_answer(TEXT, _login(PK_ADMIN, COMPANY, TEXT, t + 7 days + 1)), NO, "too far ahead");

        bytes memory sig = _login(PK_ADMIN, COMPANY, TEXT, t + 1 hours);
        vm.warp(t + 1 hours + 1);
        assertEq(_answer(TEXT, sig), NO, "lapsed");
    }

    /* ==================================================================
     *  the company binds the login to one cofund
     * ================================================================== */

    function test_company_wrongCompanyRefused() public view {
        uint256 deadline = block.timestamp + 1 hours;
        assertEq(_answer(TEXT, _login(PK_ADMIN, OTHER, TEXT, deadline)), NO, "another cofund's name");
        assertEq(_answer(TEXT, _login(PK_ADMIN, "acme", TEXT, deadline)), NO, "case matters");
    }

    function test_company_otherCofundsAdminRefused() public view {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory forAcme = _login(PK_OTHER_ADMIN, COMPANY, TEXT, deadline);
        assertEq(_answer(TEXT, forAcme), NO, "signed for Acme");

        bytes memory forOther = _login(PK_OTHER_ADMIN, OTHER, TEXT, deadline);
        assertEq(otherVault.isValidSignature(_personal(TEXT), forOther), YES, "valid on its own vault");
        assertEq(_answer(TEXT, forOther), NO, "replayed on Acme's vault");
    }

    /// @dev Each signed field is bound: a login can't be re-pointed at
    ///      another text or deadline, or signed under another domain.
    function test_binding_signatureCoversTextDeadlineAndDomain() public view {
        uint256 deadline = block.timestamp + 1 hours;
        (,,, bytes memory inner) = abi.decode(_login(PK_ADMIN, TEXT), (string, string, uint256, bytes));

        assertEq(_answer("Another login", abi.encode(COMPANY, "Another login", deadline, inner)), NO, "text");
        assertEq(_answer(TEXT, abi.encode(COMPANY, TEXT, deadline + 1, inner)), NO, "deadline");

        bytes32 structHash =
            keccak256(abi.encode(LOGIN_TYPEHASH, keccak256(bytes(COMPANY)), keccak256(bytes(TEXT)), deadline));
        bytes memory perVault = Eip712.sign(PK_ADMIN, Eip712.digest(Eip712.domainSeparator(address(vault)), structHash));
        assertEq(_answer(TEXT, abi.encode(COMPANY, TEXT, deadline, perVault)), NO, "per-vault domain");
    }

    /* ==================================================================
     *  malformed input answers no, and never reverts
     * ================================================================== */

    function test_malformed_bytesAnswerNo() public {
        bytes memory valid = _login(PK_ADMIN, TEXT);
        bytes memory truncated = new bytes(valid.length - 32);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = valid[i];
        }
        bytes[4] memory cases = [bytes(""), hex"deadbeef", abi.encode(uint256(1)), truncated];
        for (uint256 i; i < cases.length; ++i) {
            assertEq(vault.isValidSignature(_personal(TEXT), cases[i]), NO, vm.toString(i));
            // The refusal comes from the caught revert, not from a rule.
            vm.expectRevert();
            vault.validLogin(_personal(TEXT), cases[i]);
        }
    }

    function test_malformed_badEcdsaAnswersNo() public view {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK_ADMIN, _loginDigest(COMPANY, TEXT, deadline));
        bytes32 highS = bytes32(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - uint256(s));

        bytes[5] memory sigs = [
            abi.encodePacked(r, s), // 64 bytes
            abi.encodePacked(r, s, v, uint8(0)), // 66 bytes
            abi.encodePacked(r, s, uint8(29)), // bad v
            abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27)), // malleable twin
            abi.encodePacked(bytes32(0), bytes32(0), uint8(27)) // recovers to nothing
        ];
        assertEq(_answer(TEXT, abi.encode(COMPANY, TEXT, deadline, abi.encodePacked(r, s, v))), YES, "control");
        for (uint256 i; i < sigs.length; ++i) {
            assertEq(_answer(TEXT, abi.encode(COMPANY, TEXT, deadline, sigs[i])), NO, vm.toString(i));
        }
    }

    function test_malformed_emptySignatureAnswersNo() public view {
        uint256 deadline = block.timestamp + 1 hours;
        assertEq(_answer(TEXT, abi.encode(COMPANY, TEXT, deadline, bytes(""))), NO, "empty inner signature");
        assertEq(_answer(TEXT, ""), NO, "empty signature bytes");
    }

    /* ==================================================================
     *  the template is v1 plus logins
     * ================================================================== */

    function test_template_newFactoryClonesV1_1() public {
        (address registered,) = state.clientVaults(clientId);
        assertEq(factory.predictVault(clientId), registered, "prediction matches State");
        assertEq(CFHelpersVaultTemplatev1_1(factory.template()).factory(), address(factory));
        assertEq(vault.clientId(), clientId);
        assertEq(address(vault.state()), address(state));

        bytes32 otherId = sha256("Someone Else");
        vm.expectRevert(CFHelpersVaultFactoryv1_1.UnauthorizedCaller.selector);
        factory.createVault(otherId);
    }

    function test_template_executesAV1Transfer() public {
        string[] memory signers = new string[](1);
        signers[0] = "admin";
        address recipient = makeAddr("recipient");
        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId,
            "pay",
            "Operational_Expense",
            "Pay",
            signers,
            1,
            CFHelpersStatev1.Transaction(address(0), ""),
            CFHelpersStatev1.Transfer(10_000, address(token), new address[](0)),
            false
        );

        bytes32 digest = Eip712.digest(
            Eip712.domainSeparator(address(state)),
            Eip712.hashStruct(
                Eip712.Transfer(COMPANY, "pay", "Operational_Expense", 1_000, address(token), recipient, "tr-1")
            )
        );
        vm.prank(vm.addr(PK_ADMIN));
        vault.executeTransfer(
            COMPANY,
            "pay",
            "Operational_Expense",
            1_000,
            address(token),
            recipient,
            "tr-1",
            Eip712.one(Eip712.sign(PK_ADMIN, digest))
        );
        assertEq(token.balanceOf(recipient), 1_000);
    }

    function test_template_executesAV1Transaction() public {
        string[] memory signers = new string[](1);
        signers[0] = "admin";
        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId,
            "tx",
            "Treasury_Management",
            "Tx",
            signers,
            1,
            CFHelpersStatev1.Transaction(address(wrapper), "mint-token"),
            CFHelpersStatev1.Transfer(0, address(0), new address[](0)),
            true
        );

        Eip712.Allowance[] memory allowances = new Eip712.Allowance[](1);
        allowances[0] = Eip712.Allowance(address(token), 777);
        bytes memory instructions = abi.encode(uint256(10));
        bytes32 digest = Eip712.digest(
            Eip712.domainSeparator(address(state)),
            Eip712.hashStruct(
                Eip712.Transaction(
                    COMPANY,
                    "tx",
                    "Treasury_Management",
                    address(wrapper),
                    "mint-token",
                    allowances,
                    keccak256(instructions),
                    "tx-1"
                )
            )
        );
        CFHelpersVaultTemplatev1.Allowance[] memory vaultAllowances = new CFHelpersVaultTemplatev1.Allowance[](1);
        vaultAllowances[0] = CFHelpersVaultTemplatev1.Allowance(address(token), 777);

        vm.expectEmit(address(vault));
        emit CFHelpersVaultTemplatev1.TransactionExecuted("tx", "Treasury_Management", "mint-token", address(wrapper), "tx-1");
        vm.prank(vm.addr(PK_ADMIN));
        vault.executeTransaction(
            COMPANY,
            "tx",
            "Treasury_Management",
            address(wrapper),
            "mint-token",
            instructions,
            vaultAllowances,
            "tx-1",
            Eip712.one(Eip712.sign(PK_ADMIN, digest))
        );
        assertEq(token.balanceOf(address(wrapper)), 10, "wrapper ran");
        assertEq(token.allowance(address(vault), address(wrapper)), 0, "allowance reset");
    }

    /// @dev A vault created before the swap stays v1: no ERC-1271 at all.
    function test_template_v1VaultHasNoIsValidSignature() public view {
        bytes memory sig = _login(PK_LEGACY_ADMIN, LEGACY, TEXT, block.timestamp + 1 hours);
        (bool ok,) = legacyVault.staticcall(abi.encodeCall(IERC1271.isValidSignature, (_personal(TEXT), sig)));
        assertFalse(ok, "v1 answers isValidSignature");
        assertFalse(SignatureChecker.isValidSignatureNow(legacyVault, _personal(TEXT), sig));
        assertNotEq(keccak256(legacyVault.code), keccak256(address(vault).code), "different templates");
    }
}
