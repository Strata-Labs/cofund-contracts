// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// LombardWrapper against MockLBTC, plus the mock's own mainnet fidelity.
//
// A plain test address ("vault") stands in for a Cofund vault: it holds LBTC,
// approves the wrapper for exactly the amount, and calls `routerWrapper`, which
// is what `executeTransaction` does. test/LombardWrapperVault.t.sol runs the
// same redeem through a real v1 vault; test/LombardWrapperFork.t.sol runs it
// against Lombard's mainnet contracts.

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {LombardWrapper} from "../contracts/LombardWrapper.sol";
import {MockLBTC} from "../contracts/MockLBTC.sol";
import {LombardPayload} from "./utils/LombardPayload.sol";

/// @dev An LBTC whose redeem burns one sat less than asked, so the wrapper
///      would keep a sat. The wrapper must refuse it.
contract ShortBurnLBTC is ERC20 {
    constructor() ERC20("Short", "SHORT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function redeemForBtc(bytes calldata, uint256 amount) external {
        _burn(msg.sender, amount - 1);
    }
}

contract LombardWrapperTest is Test {
    event MessageSent(
        bytes32 indexed destinationLChainId, address indexed msgSender, bytes32 indexed recipient, bytes payload
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    uint256 internal constant NOTARY_KEY = uint256(keccak256("lombard-notary"));
    uint256 internal constant FEE = 10_000;
    uint256 internal constant MIN_AFTER_FEE = 3_300;
    /// @dev 0.01 LBTC.
    uint256 internal constant AMOUNT = 1_000_000;

    /// @dev OP_1 PUSH32 <x-only key>: a P2TR output.
    bytes internal constant P2TR = hex"5120a60869f0dbcf1dc659c9cecbaf8050135ea9e8cdc487053f1dc6880949dc684c";
    /// @dev OP_0 PUSH20: P2WPKH. OP_0 PUSH32: P2WSH.
    bytes internal constant P2WPKH = hex"0014751e76e8199196d454941c45d1b3a323f1433bd6";
    bytes internal constant P2WSH = hex"00201863143c14c5166804bd19203356da136c985678cd4d27a1b8c6329604903262";
    /// @dev P2PKH -- Lombard does not pay to it.
    bytes internal constant P2PKH = hex"76a91462e907b15cbf27d5425399ebf6f0fb50ebb88f1888ac";

    MockLBTC internal lbtc;
    LombardWrapper internal wrapper;
    address internal notary;
    address internal treasury;
    address internal vault;
    uint256 internal mintNonce;

    function setUp() public {
        notary = vm.addr(NOTARY_KEY);
        treasury = makeAddr("treasury");
        vault = makeAddr("vault");

        lbtc = new MockLBTC(notary, treasury);
        wrapper = new LombardWrapper(address(lbtc));

        _deposit(vault, 10 * AMOUNT);
    }

    // ---------------------------------------------------------------- utils

    /// @dev The BTC -> LBTC leg: anyone submits the notarized payload.
    function _deposit(address to, uint256 amount) internal {
        bytes memory payload = LombardPayload.mint(mintNonce++, address(lbtc), address(lbtc), to, amount);
        lbtc.mint(payload, LombardPayload.proof(NOTARY_KEY, payload));
    }

    function _instructions(string memory func, bytes memory scriptPubkey, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(func, scriptPubkey, amount);
    }

    /// @dev What `executeTransaction` does: approve exactly, call, (reset).
    function _redeem(bytes memory scriptPubkey, uint256 amount) internal returns (bool ok) {
        vm.startPrank(vault);
        lbtc.approve(address(wrapper), amount);
        ok = wrapper.routerWrapper("redeemForBtc", _instructions("redeemForBtc", scriptPubkey, amount));
        vm.stopPrank();
    }

    function _expectRefusal(bytes memory instructions, bytes memory err) internal {
        vm.prank(vault);
        lbtc.approve(address(wrapper), AMOUNT);
        vm.expectRevert(err);
        vm.prank(vault);
        wrapper.routerWrapper("redeemForBtc", instructions);
    }

    // ----------------------------------------------------------- deployment

    function test_constructor_storesLbtc() public view {
        assertEq(wrapper.lbtc(), address(lbtc));
    }

    function test_constructor_rejectsZeroAddress() public {
        vm.expectRevert(LombardWrapper.ZeroAddress.selector);
        new LombardWrapper(address(0));
    }

    // -------------------------------------------------------------- redeem

    function test_redeem_burnsAndEmitsTheExactScriptAndAmount() public {
        uint256 supplyBefore = lbtc.totalSupply();
        uint256 vaultBefore = lbtc.balanceOf(vault);

        vm.prank(vault);
        lbtc.approve(address(wrapper), AMOUNT);

        // Mainnet's order: the mailbox message, the fee to the treasury, the burn.
        vm.expectEmit(true, true, true, true, address(lbtc));
        emit MessageSent(
            LombardPayload.LEDGER_CHAIN_ID,
            address(lbtc),
            LombardPayload.BTC_STAKING_MODULE,
            LombardPayload.redeem(0, address(lbtc), address(lbtc), address(wrapper), P2TR, AMOUNT - FEE)
        );
        vm.expectEmit(true, true, true, true, address(lbtc));
        emit Transfer(address(0), treasury, FEE);
        vm.expectEmit(true, true, true, true, address(lbtc));
        emit Transfer(address(wrapper), address(0), AMOUNT);

        vm.prank(vault);
        bool ok = wrapper.routerWrapper("redeemForBtc", _instructions("redeemForBtc", P2TR, AMOUNT));

        assertTrue(ok, "routerWrapper returned false");
        assertEq(lbtc.balanceOf(vault), vaultBefore - AMOUNT, "vault paid the amount");
        assertEq(lbtc.balanceOf(treasury), FEE, "treasury got the fee");
        assertEq(lbtc.totalSupply(), supplyBefore - (AMOUNT - FEE), "net burn is amount - fee");
    }

    /// @dev The decode a webapp does on the receipt.
    function test_redeem_eventDecodesToScriptAndAmountAfterFee() public {
        vm.recordLogs();
        _redeem(P2TR, AMOUNT);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256("MessageSent(bytes32,address,bytes32,bytes)");
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic) continue;
            found++;
            (uint256 nonce, bytes32 toChain, address token, address sender, bytes memory script, uint256 net) =
                LombardPayload.decodeRedeem(abi.decode(logs[i].data, (bytes)));
            assertEq(nonce, 0);
            assertEq(toChain, LombardPayload.BITCOIN_CHAIN_ID);
            assertEq(token, address(lbtc));
            assertEq(sender, address(wrapper), "Lombard sees the wrapper as the redeemer");
            assertEq(script, P2TR, "scriptPubkey");
            assertEq(net, AMOUNT - FEE, "BTC paid out");
        }
        assertEq(found, 1);
    }

    function test_redeem_leavesNothingInTheWrapper() public {
        _redeem(P2TR, AMOUNT);

        assertEq(lbtc.balanceOf(address(wrapper)), 0, "wrapper holds LBTC");
        assertEq(lbtc.allowance(vault, address(wrapper)), 0, "vault allowance left standing");
        assertEq(lbtc.allowance(address(wrapper), address(lbtc)), 0, "wrapper approved LBTC");
    }

    function test_redeem_acceptsEverySegwitOutput() public {
        assertTrue(_redeem(P2TR, AMOUNT));
        assertTrue(_redeem(P2WPKH, AMOUNT));
        assertTrue(_redeem(P2WSH, AMOUNT));
        assertEq(lbtc.outboundNonce(), 3);
        assertEq(lbtc.balanceOf(address(wrapper)), 0);
    }

    function test_redeem_ignoresTheNameArgument() public {
        vm.startPrank(vault);
        lbtc.approve(address(wrapper), AMOUNT);
        assertTrue(wrapper.routerWrapper("", _instructions("redeemForBtc", P2TR, AMOUNT)));
        vm.stopPrank();
    }

    /// @dev Stray LBTC sent to the wrapper neither blocks a redeem nor moves.
    function test_redeem_strayBalanceDoesNotBlockAndStaysPut() public {
        _deposit(address(wrapper), 777);

        assertTrue(_redeem(P2TR, AMOUNT));
        assertEq(lbtc.balanceOf(address(wrapper)), 777);
    }

    // ----------------------------------------------------- fee and minimum

    function test_redeem_atExactlyTheMinimum() public {
        _redeem(P2TR, FEE + MIN_AFTER_FEE);
        assertEq(lbtc.balanceOf(treasury), FEE);
        assertEq(lbtc.balanceOf(address(wrapper)), 0);
    }

    function test_redeem_belowTheMinimumReverts() public {
        _expectRefusal(
            _instructions("redeemForBtc", P2TR, FEE + MIN_AFTER_FEE - 1),
            abi.encodeWithSelector(MockLBTC.AmountBelowMinLimit.selector, MIN_AFTER_FEE)
        );
    }

    function test_redeem_notAboveTheFeeReverts() public {
        _expectRefusal(
            _instructions("redeemForBtc", P2TR, FEE),
            abi.encodeWithSelector(MockLBTC.AssetRouter_FeeGreaterThanAmount.selector)
        );
    }

    /// @dev The fee check comes first, as on mainnet.
    function test_redeem_feeCheckPrecedesScriptCheck() public {
        _expectRefusal(
            _instructions("redeemForBtc", P2PKH, FEE),
            abi.encodeWithSelector(MockLBTC.AssetRouter_FeeGreaterThanAmount.selector)
        );
    }

    function test_redeem_unsupportedScriptReverts() public {
        _expectRefusal(
            _instructions("redeemForBtc", P2PKH, AMOUNT),
            abi.encodeWithSelector(MockLBTC.ScriptPubkeyUnsupported.selector)
        );
    }

    function test_calcUnstakeRequestAmount() public view {
        (uint256 net, bool aboveDust) = lbtc.calcUnstakeRequestAmount(P2TR, AMOUNT);
        assertEq(net, AMOUNT - FEE);
        assertTrue(aboveDust);
        (net, aboveDust) = lbtc.calcUnstakeRequestAmount(P2TR, FEE + MIN_AFTER_FEE - 1);
        assertEq(net, MIN_AFTER_FEE - 1);
        assertFalse(aboveDust);
        assertEq(lbtc.getRedeemFee(), FEE);
        assertEq(lbtc.getRedeemForBtcMinAmount(), MIN_AFTER_FEE);
        assertEq(lbtc.decimals(), 8);
    }

    // ------------------------------------------------------------ refusals

    function test_refuses_unknownFunc() public {
        _expectRefusal(
            _instructions("redeem", P2TR, AMOUNT),
            abi.encodeWithSelector(LombardWrapper.UnsupportedFunction.selector, "redeem")
        );
        _expectRefusal(
            _instructions("RedeemForBtc", P2TR, AMOUNT),
            abi.encodeWithSelector(LombardWrapper.UnsupportedFunction.selector, "RedeemForBtc")
        );
        _expectRefusal(
            _instructions("", P2TR, AMOUNT), abi.encodeWithSelector(LombardWrapper.UnsupportedFunction.selector, "")
        );
    }

    function test_refuses_zeroAmount() public {
        _expectRefusal(
            _instructions("redeemForBtc", P2TR, 0), abi.encodeWithSelector(LombardWrapper.InvalidAmount.selector)
        );
    }

    function test_refuses_emptyScriptPubkey() public {
        _expectRefusal(
            _instructions("redeemForBtc", "", AMOUNT),
            abi.encodeWithSelector(LombardWrapper.InvalidScriptPubkey.selector)
        );
    }

    function test_refuses_malformedInstructions() public {
        vm.expectRevert();
        vm.prank(vault);
        wrapper.routerWrapper("redeemForBtc", abi.encode(uint256(1)));
    }

    function test_refuses_withoutAllowance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(wrapper), 0, AMOUNT)
        );
        vm.prank(vault);
        wrapper.routerWrapper("redeemForBtc", _instructions("redeemForBtc", P2TR, AMOUNT));
    }

    function test_refuses_anLbtcThatBurnsShort() public {
        ShortBurnLBTC shorty = new ShortBurnLBTC();
        LombardWrapper w = new LombardWrapper(address(shorty));
        shorty.mint(vault, AMOUNT);

        vm.startPrank(vault);
        shorty.approve(address(w), AMOUNT);
        vm.expectRevert(LombardWrapper.LeftoverBalance.selector);
        w.routerWrapper("redeemForBtc", _instructions("redeemForBtc", P2TR, AMOUNT));
        vm.stopPrank();
    }

    // ------------------------------------------------- MockLBTC: the mint leg

    /// @dev A real mainnet mint payload (2.885 BTC to 0x5bde…744b), rebuilt
    ///      byte for byte by the builder the tests and the webapp follow.
    function test_payload_matchesARealMainnetMint() public pure {
        bytes memory real =
            hex"e288fb4a67636e97dfe9e0a5f7c0ab17636a921dc777c6aa9d6665e810ce50d61feb6d12000000000000000000000000000000000000000000000000000000000000153000000000000000000000000089e3e4e7a699d6f131d893aeef7ee143706ac23a0000000000000000000000009ece5fb1ab62d9075c4ec814b321e24d8ea021ac000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000064155b6b130000000000000000000000008236a87084f8b84306f72007f36f2618a56344940000000000000000000000005bde80f61216f2d6977d360694e2d468ea5d744b0000000000000000000000000000000000000000000000000000000011322c3c00000000000000000000000000000000000000000000000000000000";
        bytes memory rebuilt = LombardPayload.mint(
            0x1530,
            0x9eCe5fB1aB62d9075c4ec814b321e24D8EA021ac, // AssetRouter
            0x8236a87084f8B84306f72007F36F2618A5634494, // LBTC
            0x5bdE80F61216F2D6977D360694E2D468Ea5D744B,
            0x11322c3c
        );
        assertEq(rebuilt, real);
    }

    function test_mint_creditsTheRecipient() public {
        address alice = makeAddr("alice");
        bytes memory payload = LombardPayload.mint(42, address(lbtc), address(lbtc), alice, 123_456);

        vm.expectEmit(true, true, true, true, address(lbtc));
        emit Transfer(address(0), alice, 123_456);
        address recipient = lbtc.mint(payload, LombardPayload.proof(NOTARY_KEY, payload));

        assertEq(recipient, alice);
        assertEq(lbtc.balanceOf(alice), 123_456);
        assertTrue(lbtc.usedPayloads(sha256(payload)));
    }

    function test_mint_replayReverts() public {
        bytes memory payload = LombardPayload.mint(42, address(lbtc), address(lbtc), vault, 1);
        bytes memory proof = LombardPayload.proof(NOTARY_KEY, payload);
        lbtc.mint(payload, proof);

        vm.expectRevert(MockLBTC.AssetRouter_MintProcessingError.selector);
        lbtc.mint(payload, proof);
    }

    /// @dev Mainnet skips the proof of a delivered payload; so does the mock.
    function test_mint_replayRevertsWhateverTheProof() public {
        bytes memory payload = LombardPayload.mint(42, address(lbtc), address(lbtc), vault, 1);
        lbtc.mint(payload, LombardPayload.proof(NOTARY_KEY, payload));

        vm.expectRevert(MockLBTC.AssetRouter_MintProcessingError.selector);
        lbtc.mint(payload, abi.encode(new bytes[](0)));
    }

    function test_mint_rejectsAnotherSigner() public {
        bytes memory payload = LombardPayload.mint(42, address(lbtc), address(lbtc), vault, 1);
        bytes memory proof = LombardPayload.proof(uint256(keccak256("impostor")), payload);

        vm.expectRevert(MockLBTC.NotEnoughSignatures.selector);
        lbtc.mint(payload, proof);
    }

    function test_mint_rejectsAProofOverAnotherPayload() public {
        bytes memory payload = LombardPayload.mint(42, address(lbtc), address(lbtc), vault, 1);
        bytes memory other = LombardPayload.mint(42, address(lbtc), address(lbtc), vault, 2);
        // Built before `expectRevert`: sha256 is a precompile call.
        bytes memory proof = LombardPayload.proof(NOTARY_KEY, payload);

        vm.expectRevert(MockLBTC.NotEnoughSignatures.selector);
        lbtc.mint(other, proof);
    }

    function test_mint_rejectsAnEthStyleSignature() public {
        bytes memory payload = LombardPayload.mint(42, address(lbtc), address(lbtc), vault, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(NOTARY_KEY, sha256(payload));
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);

        vm.expectRevert(MockLBTC.NotEnoughSignatures.selector);
        lbtc.mint(payload, abi.encode(sigs));
    }

    function test_mint_rejectsTheWrongSignatureCount() public {
        bytes memory payload = LombardPayload.mint(42, address(lbtc), address(lbtc), vault, 1);

        vm.expectRevert(MockLBTC.LengthMismatch.selector);
        lbtc.mint(payload, abi.encode(new bytes[](2)));
    }

    function test_mint_rejectsPayloadsForAnotherTokenOrRouter() public {
        address other = makeAddr("other");
        bytes[3] memory bad = [
            LombardPayload.mint(42, address(lbtc), other, vault, 1), // toToken
            LombardPayload.mint(42, other, address(lbtc), vault, 1), // GMP recipient
            LombardPayload.mint(42, address(lbtc), address(lbtc), address(0), 1) // recipient
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            bytes memory proof = LombardPayload.proof(NOTARY_KEY, bad[i]);
            vm.expectRevert(MockLBTC.InvalidPayload.selector);
            lbtc.mint(bad[i], proof);
        }
    }
}
