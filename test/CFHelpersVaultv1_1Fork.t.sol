// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {CFHelpersGovv1} from "../contracts/CFHelpersGovv1.sol";
import {CFHelpersUsersv1} from "../contracts/CFHelpersUsersv1.sol";
import {CFHelpersVaultFactoryv1_1} from "../contracts/CFHelpersVaultFactoryv1_1.sol";
import {DeployVaultV1_1} from "../script/DeployVaultV1_1.s.sol";

import {Eip712} from "./utils/Eip712.sol";
import {OzSignatureChecker} from "./utils/OzSignatureChecker.sol";

/// @notice USDC's FiatTokenV2_2: EIP-3009 with a `bytes` signature, which it
///         checks with ERC-1271 when `from` has code.
interface IFiatTokenV2_2 {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function TRANSFER_WITH_AUTHORIZATION_TYPEHASH() external view returns (bytes32);
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title  CFHelpersVaultv1_1ForkTest -- the v1.1 swap on the live v1 State.
///
/// @notice Opt-in, like `LombardWrapperFork.t.sol`: without an Ethereum fork
///         the suite skips itself. To run it:
///
///             forge test --fork-url ethereum --match-path test/CFHelpersVaultv1_1Fork.t.sol -vv
///
///         Deploys the v1.1 factory with the deploy script, registers it
///         through the live Gov, and onboards a new cofund through the live
///         users helper. Its vault answers a login and refuses USDC.
contract CFHelpersVaultv1_1ForkTest is Test {
    /// @dev `deployments/1.json`.
    address internal constant STATE = 0xD59eFC1803Fb72231Db0B6A872a9c22D8A0102C0;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev `forge inspect CFHelpersStatev1 storageLayout`: `isCofundAdmin`.
    uint256 internal constant IS_COFUND_ADMIN_SLOT = 1;

    bytes32 internal constant LOGIN_TYPEHASH =
        keccak256("SignMessage(string company,string message,uint256 deadline)");
    string internal constant COMPANY = "Cofund v1.1 fork test";
    string internal constant TEXT =
        "I have read and accept the Terms of Service and LBTC Product Terms on 2026-10-29T12:00:00Z. Nonce: 9f1c2a";

    /// @dev Fresh keys: anvil's default accounts carry EIP-7702 code on mainnet.
    uint256 internal constant PK_COFUND_ADMIN = uint256(keccak256("v1_1.fork.cofund-admin"));
    uint256 internal constant PK_FOUNDER = uint256(keccak256("v1_1.fork.founder"));

    CFHelpersStatev1 internal state = CFHelpersStatev1(STATE);
    CFHelpersVaultFactoryv1_1 internal factory;
    address internal vault;

    function setUp() public {
        if (block.chainid != 1 || STATE.code.length == 0) {
            vm.skip(true);
            return;
        }

        // A Cofund admin of our own: the Gov bit, written into State.
        address cofundAdmin = vm.addr(PK_COFUND_ADMIN);
        assertEq(cofundAdmin.code.length, 0, "fresh key has code");
        vm.deal(cofundAdmin, 1 ether);
        vm.store(STATE, keccak256(abi.encode(cofundAdmin, IS_COFUND_ADMIN_SLOT)), bytes32(uint256(1)));
        assertTrue(state.isCofundAdmin(cofundAdmin), "admin slot");

        // Rollout steps 1 and 2: deploy, then swap "vaults" through Gov.
        factory = new DeployVaultV1_1().deploy(STATE);
        CFHelpersGovv1 gov = CFHelpersGovv1(state.helperContracts("gov"));
        vm.prank(cofundAdmin);
        gov.setHelperContract("vaults", address(factory));
        assertEq(state.helperContracts("vaults"), address(factory), "registered");

        // A new cofund, onboarded the way the app does it.
        bytes32 clientId = sha256(bytes(COMPANY));
        uint256 expiresAt = block.timestamp + 1 hours;
        bytes memory founderSig = Eip712.sign(
            PK_FOUNDER,
            Eip712.digest(
                Eip712.domainSeparator(STATE),
                Eip712.hashStruct(Eip712.InviteUser(COMPANY, "founder", "founder", true, "admin", expiresAt, "v1_1-fork"))
            )
        );
        CFHelpersUsersv1 users = CFHelpersUsersv1(state.helperContracts("users"));
        address founder = vm.addr(PK_FOUNDER);
        vm.prank(cofundAdmin);
        users.createClient(clientId, COMPANY, "founder", founder, "FREE", expiresAt, "v1_1-fork", founderSig);

        (vault,) = state.clientVaults(clientId);
        assertEq(vault, factory.predictVault(clientId), "a v1.1 clone");
    }

    function _login(string memory text) internal view returns (bytes memory) {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(LOGIN_TYPEHASH, keccak256(bytes(COMPANY)), keccak256(bytes(text)), deadline));
        bytes memory sig = Eip712.sign(PK_FOUNDER, Eip712.digest(Eip712.domainSeparator(STATE), structHash));
        return abi.encode(COMPANY, text, deadline, sig);
    }

    function _personal(string memory text) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", vm.toString(bytes(text).length), text));
    }

    function test_fork_newVaultPassesSignatureChecker() public view {
        bytes memory sig = _login(TEXT);
        assertTrue(OzSignatureChecker.isValidSignatureNow(vault, _personal(TEXT), sig), "OZ SignatureChecker");
        assertEq(IERC1271(vault).isValidSignature(_personal(TEXT), sig), bytes4(0x1626ba7e));
    }

    /// @dev The founder signs a login whose text is USDC's digest. It's a valid
    ///      login for that text, and still no authorization for USDC.
    function test_fork_usdcTransferWithAuthorizationSignedAsLoginReverts() public {
        IFiatTokenV2_2 usdc = IFiatTokenV2_2(USDC);
        deal(USDC, vault, 1_000e6);
        address to = makeAddr("to");
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("v1_1-fork-nonce");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(usdc.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), vault, to, 1_000e6, 0, validBefore, nonce)
                )
            )
        );

        string memory text = vm.toString(digest);
        bytes memory sig = _login(text);
        assertEq(IERC1271(vault).isValidSignature(_personal(text), sig), bytes4(0x1626ba7e), "a valid login");
        assertEq(IERC1271(vault).isValidSignature(digest, sig), bytes4(0xffffffff), "not for USDC's digest");

        vm.expectRevert("FiatTokenV2: invalid signature");
        usdc.transferWithAuthorization(vault, to, 1_000e6, 0, validBefore, nonce, sig);

        assertEq(usdc.balanceOf(vault), 1_000e6, "vault balance");
        assertFalse(usdc.authorizationState(vault, nonce), "nonce unused");
    }
}
