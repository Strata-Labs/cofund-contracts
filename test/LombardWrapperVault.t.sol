// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {CFHelpersVaultFactoryv1} from "../contracts/CFHelpersVaultFactoryv1.sol";
import {CFHelpersVaultTemplatev1} from "../contracts/CFHelpersVaultTemplatev1.sol";
import {LombardWrapper} from "../contracts/LombardWrapper.sol";
import {MockLBTC} from "../contracts/MockLBTC.sol";
import {Eip712} from "./utils/Eip712.sol";
import {LombardPayload} from "./utils/LombardPayload.sol";

/// @title  LombardWrapperVaultTest -- BTC in and back out of a real v1 vault.
///
/// @notice The deposit leg is a notarized `MockLBTC.mint` to the vault, which
///         anyone may submit. The exit is the vault's own `executeTransaction`
///         on a call policy bound to `LombardWrapper`, with a two-of-three
///         EIP-712 approval over the instructions and the LBTC allowance.
///
/// @dev    Same fixture as test/CFHelpersVaultv1.t.sol: real State v1, the
///         real factory and vault clone, and the other helpers as plain EOAs.
contract LombardWrapperVaultTest is Test {
    event MessageSent(
        bytes32 indexed destinationLChainId, address indexed msgSender, bytes32 indexed recipient, bytes payload
    );

    string internal constant COMPANY = "Acme";
    string internal constant TX_POLICY_TYPE = "Treasury_Management";
    string internal constant POLICY = "btc-exit";
    string internal constant FUNC = "redeemForBtc";

    uint256 internal constant NOTARY_KEY = uint256(keccak256("lombard-notary"));
    uint256 internal constant PK_ALICE = uint256(keccak256("alice"));
    uint256 internal constant PK_BOB = uint256(keccak256("bob"));
    uint256 internal constant PK_CAROL = uint256(keccak256("carol"));

    uint256 internal constant FEE = 10_000;
    /// @dev 0.5 BTC in, 0.1 LBTC out.
    uint256 internal constant DEPOSIT = 50_000_000;
    uint256 internal constant AMOUNT = 10_000_000;

    bytes internal constant P2TR = hex"5120a60869f0dbcf1dc659c9cecbaf8050135ea9e8cdc487053f1dc6880949dc684c";
    bytes internal constant OTHER_P2TR = hex"512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

    CFHelpersStatev1 internal state;
    CFHelpersVaultTemplatev1 internal vault;
    MockLBTC internal lbtc;
    LombardWrapper internal wrapper;

    address internal policiesEOA;
    address internal broadcaster;
    address internal treasury;
    bytes32 internal clientId;

    function setUp() public {
        address deployer = makeAddr("deployer");
        address govEOA = makeAddr("gov");
        address usersEOA = makeAddr("users");
        policiesEOA = makeAddr("policies");
        broadcaster = makeAddr("acme-admin");
        treasury = makeAddr("lombard-treasury");
        clientId = Eip712.companyId(COMPANY);

        lbtc = new MockLBTC(vm.addr(NOTARY_KEY), treasury);
        wrapper = new LombardWrapper(address(lbtc));

        vm.prank(deployer);
        state = new CFHelpersStatev1(deployer);
        CFHelpersVaultFactoryv1 factory = new CFHelpersVaultFactoryv1(address(state));
        vm.prank(deployer);
        state.setGovHelperContract(govEOA);

        vm.startPrank(govEOA);
        state.setHelperContract("vaults", address(factory));
        state.setHelperContract("users", usersEOA);
        state.setHelperContract("policies", policiesEOA);
        state.setHelperContract("sponsorGuard", makeAddr("sponsorGuard"));
        vm.stopPrank();

        vm.startPrank(usersEOA);
        state.newClient(clientId, "admin", broadcaster, "FREE");
        state.addUser(clientId, "alice", vm.addr(PK_ALICE), false, "eng");
        state.addUser(clientId, "bob", vm.addr(PK_BOB), false, "eng");
        state.addUser(clientId, "carol", vm.addr(PK_CAROL), false, "eng");
        vm.stopPrank();

        (address vaultAddr,) = state.clientVaults(clientId);
        vault = CFHelpersVaultTemplatev1(vaultAddr);

        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId,
            POLICY,
            TX_POLICY_TYPE,
            "BTC exit",
            Eip712.ids("alice", "bob", "carol"),
            2,
            CFHelpersStatev1.Transaction({wrapper: address(wrapper), func: FUNC}),
            CFHelpersStatev1.Transfer({maxAmount: 0, token: address(0), recipients: new address[](0)}),
            true
        );

        // BTC -> LBTC: the notarized deposit lands in the vault, no signer needed.
        bytes memory payload = LombardPayload.mint(7, address(lbtc), address(lbtc), address(vault), DEPOSIT);
        lbtc.mint(payload, LombardPayload.proof(NOTARY_KEY, payload));
    }

    /* ----------  the signed call  ---------- */

    struct Call {
        string policyId;
        bytes instructions;
        uint256 allowance;
        string authId;
    }

    function _signedBy(Call memory c, uint256[] memory pks) internal view returns (bytes[] memory) {
        Eip712.Allowance[] memory allowances = new Eip712.Allowance[](1);
        allowances[0] = Eip712.Allowance({asset: address(lbtc), amount: c.allowance});
        bytes32 structHash = Eip712.hashStruct(
            Eip712.Transaction({
                company: COMPANY,
                policyId: c.policyId,
                messageType: TX_POLICY_TYPE,
                wrapper: address(wrapper),
                func: FUNC,
                allowances: allowances,
                instructionsHash: keccak256(c.instructions),
                authId: c.authId
            })
        );
        return Eip712.sign(pks, Eip712.digest(Eip712.domainSeparator(address(state)), structHash));
    }

    function _execute(Call memory c, bytes[] memory sigs) internal {
        CFHelpersVaultTemplatev1.Allowance[] memory allowances = new CFHelpersVaultTemplatev1.Allowance[](1);
        allowances[0] = CFHelpersVaultTemplatev1.Allowance({asset: address(lbtc), amount: c.allowance});
        vm.prank(broadcaster);
        vault.executeTransaction(
            COMPANY, c.policyId, TX_POLICY_TYPE, address(wrapper), FUNC, c.instructions, allowances, c.authId, sigs
        );
    }

    function _call(bytes memory scriptPubkey, uint256 amount, uint256 allowance, string memory authId)
        internal
        pure
        returns (Call memory)
    {
        return Call({
            policyId: POLICY, instructions: abi.encode(FUNC, scriptPubkey, amount), allowance: allowance, authId: authId
        });
    }

    /* ----------  tests  ---------- */

    function test_vault_redeemsToTheSignedP2TRScript() public {
        Call memory c = _call(P2TR, AMOUNT, AMOUNT, "exit-1");
        bytes[] memory sigs = _signedBy(c, Eip712.keys(PK_ALICE, PK_BOB));

        vm.expectEmit(true, true, true, true, address(lbtc));
        emit MessageSent(
            LombardPayload.LEDGER_CHAIN_ID,
            address(lbtc),
            LombardPayload.BTC_STAKING_MODULE,
            LombardPayload.redeem(0, address(lbtc), address(lbtc), address(wrapper), P2TR, AMOUNT - FEE)
        );
        _execute(c, sigs);

        assertEq(lbtc.balanceOf(address(vault)), DEPOSIT - AMOUNT, "vault paid exactly the amount");
        assertEq(lbtc.balanceOf(treasury), FEE, "redeem fee");
        assertEq(lbtc.totalSupply(), DEPOSIT - AMOUNT + FEE, "net burn");
        assertEq(lbtc.balanceOf(address(wrapper)), 0, "wrapper holds LBTC");
        assertEq(lbtc.allowance(address(vault), address(wrapper)), 0, "allowance left standing");
    }

    /// @dev The destination is in `instructionsHash`: swap the script after
    ///      signing and the approval no longer recovers to a signer. A
    ///      one-signer policy, so the failure is the signer check and nothing
    ///      else (two stray recoveries could trip the ordering check first).
    function test_vault_refusesAScriptTheSignersDidNotSign() public {
        vm.prank(policiesEOA);
        state.activatePolicy(
            clientId,
            "btc-exit-solo",
            TX_POLICY_TYPE,
            "BTC exit (solo)",
            Eip712.ids("alice", "bob", "carol"),
            1,
            CFHelpersStatev1.Transaction({wrapper: address(wrapper), func: FUNC}),
            CFHelpersStatev1.Transfer({maxAmount: 0, token: address(0), recipients: new address[](0)}),
            true
        );
        Call memory signed = _call(P2TR, AMOUNT, AMOUNT, "exit-2");
        signed.policyId = "btc-exit-solo";
        Call memory swapped = _call(OTHER_P2TR, AMOUNT, AMOUNT, "exit-2");
        swapped.policyId = "btc-exit-solo";
        bytes[] memory sigs = _signedBy(signed, Eip712.keys(PK_ALICE));

        vm.expectRevert(CFHelpersVaultTemplatev1.InvalidSigner.selector);
        _execute(swapped, sigs);

        assertEq(lbtc.balanceOf(address(vault)), DEPOSIT, "nothing moved");
    }

    /// @dev The wrapper can pull no more than the signed allowance.
    function test_vault_refusesAnAmountAboveTheSignedAllowance() public {
        Call memory c = _call(P2TR, AMOUNT, AMOUNT - 1, "exit-3");
        bytes[] memory sigs = _signedBy(c, Eip712.keys(PK_ALICE, PK_BOB));

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(wrapper), AMOUNT - 1, AMOUNT
            )
        );
        _execute(c, sigs);
    }

    function test_vault_refusesBelowThreshold() public {
        Call memory c = _call(P2TR, AMOUNT, AMOUNT, "exit-4");
        bytes[] memory sigs = _signedBy(c, Eip712.keys(PK_CAROL));

        vm.expectRevert(CFHelpersVaultTemplatev1.ThresholdNotMet.selector);
        _execute(c, sigs);
    }
}
