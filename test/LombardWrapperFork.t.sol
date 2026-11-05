// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LombardWrapper} from "../contracts/LombardWrapper.sol";
import {MockLBTC} from "../contracts/MockLBTC.sol";
import {LombardPayload} from "./utils/LombardPayload.sol";

/// @notice The read side of mainnet LBTC the test checks against the mock.
interface ILBTCMainnet {
    function getRedeemFee() external view returns (uint256);
    function getRedeemForBtcMinAmount() external view returns (uint256);
    function getTreasury() external view returns (address);
    function mint(bytes calldata rawPayload, bytes calldata proof) external returns (address);
}

/// @title  LombardWrapperForkTest -- the wrapper against Lombard on mainnet.
///
/// @notice Opt-in, like every fork run in this repo (FORK_GUIDE.md): without an
///         Ethereum fork the suite skips itself, so plain `forge test` stays
///         offline. To run it:
///
///             forge test --fork-url ethereum --match-path test/LombardWrapperFork.t.sol -vv
///
///         It deploys a `LombardWrapper` on the real LBTC, funds a vault-shaped
///         holder from Morpho Blue's LBTC balance, and redeems to a P2TR script.
///         Alongside, it pins the facts `MockLBTC` copies: the fee, the minimum,
///         the error selectors and the `MessageSent` payload.
contract LombardWrapperForkTest is Test {
    address internal constant LBTC = 0x8236a87084f8B84306f72007F36F2618A5634494;
    address internal constant ASSET_ROUTER = 0x9eCe5fB1aB62d9075c4ec814b321e24D8EA021ac;
    address internal constant MAILBOX = 0x964677F337d6528d659b1892D0045B8B27183fc0;
    /// @dev Morpho Blue: a large, long-lived LBTC holder to impersonate.
    address internal constant HOLDER = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    bytes32 internal constant MESSAGE_SENT = keccak256("MessageSent(bytes32,address,bytes32,bytes)");
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    /// @dev 0.01 LBTC.
    uint256 internal constant AMOUNT = 1_000_000;
    bytes internal constant P2TR = hex"5120a60869f0dbcf1dc659c9cecbaf8050135ea9e8cdc487053f1dc6880949dc684c";

    LombardWrapper internal wrapper;
    address internal vault;

    function setUp() public {
        if (block.chainid != 1 || LBTC.code.length == 0) {
            vm.skip(true);
            return;
        }
        wrapper = new LombardWrapper(LBTC);
        vault = makeAddr("vault");

        vm.prank(HOLDER);
        assertTrue(IERC20(LBTC).transfer(vault, 10 * AMOUNT));
    }

    function _redeem(uint256 amount) internal {
        vm.startPrank(vault);
        IERC20(LBTC).approve(address(wrapper), amount);
        wrapper.routerWrapper("redeemForBtc", abi.encode("redeemForBtc", P2TR, amount));
        vm.stopPrank();
    }

    function test_fork_redeemsToP2TRThroughTheWrapper() public {
        IERC20 lbtc = IERC20(LBTC);
        uint256 fee = ILBTCMainnet(LBTC).getRedeemFee();
        address treasury = ILBTCMainnet(LBTC).getTreasury();
        uint256 supplyBefore = lbtc.totalSupply();
        uint256 vaultBefore = lbtc.balanceOf(vault);
        uint256 treasuryBefore = lbtc.balanceOf(treasury);

        vm.prank(vault);
        lbtc.approve(address(wrapper), AMOUNT);

        vm.recordLogs();
        vm.prank(vault);
        uint256 gasBefore = gasleft();
        wrapper.routerWrapper("redeemForBtc", abi.encode("redeemForBtc", P2TR, AMOUNT));
        uint256 gasUsed = gasBefore - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Balances: the vault pays `amount`, the treasury is minted the fee,
        // the wrapper ends empty.
        assertEq(lbtc.balanceOf(vault), vaultBefore - AMOUNT, "vault paid the amount");
        assertEq(lbtc.balanceOf(treasury), treasuryBefore + fee, "treasury got the fee");
        assertEq(lbtc.totalSupply(), supplyBefore - (AMOUNT - fee), "net burn");
        assertEq(lbtc.balanceOf(address(wrapper)), 0, "wrapper holds LBTC");
        assertEq(lbtc.allowance(vault, address(wrapper)), 0, "allowance left standing");

        // Lombard's events: the mailbox message, and the burn from the wrapper.
        uint256 sent;
        uint256 burns;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == MAILBOX && logs[i].topics[0] == MESSAGE_SENT) {
                sent++;
                assertEq(logs[i].topics[1], LombardPayload.LEDGER_CHAIN_ID, "destination chain");
                assertEq(logs[i].topics[2], LombardPayload.b32(ASSET_ROUTER), "msgSender");
                assertEq(logs[i].topics[3], LombardPayload.BTC_STAKING_MODULE, "recipient module");
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                (uint256 nonce, bytes32 toChain, address token, address sender, bytes memory script, uint256 net) =
                    LombardPayload.decodeRedeem(payload);
                assertEq(toChain, LombardPayload.BITCOIN_CHAIN_ID, "bitcoin chain id");
                assertEq(token, LBTC, "from token");
                assertEq(sender, address(wrapper), "redeemer is the wrapper");
                assertEq(script, P2TR, "scriptPubkey");
                assertEq(net, AMOUNT - fee, "BTC to pay out");
                // The mock emits this exact payload, but for its own router.
                assertEq(payload, LombardPayload.redeem(nonce, ASSET_ROUTER, LBTC, address(wrapper), P2TR, net));
                console2.log("MessageSent nonce        ", nonce);
            }
            if (
                logs[i].emitter == LBTC && logs[i].topics[0] == TRANSFER
                    && logs[i].topics[1] == LombardPayload.b32(address(wrapper)) && logs[i].topics[2] == bytes32(0)
            ) {
                burns++;
                assertEq(abi.decode(logs[i].data, (uint256)), AMOUNT, "burned amount");
            }
        }
        assertEq(sent, 1, "one MessageSent");
        assertEq(burns, 1, "one burn");

        console2.log("block                    ", block.number);
        console2.log("redeemed (sat)           ", AMOUNT);
        console2.log("redeem fee (sat)         ", fee);
        console2.log("BTC to P2TR (sat)        ", AMOUNT - fee);
        console2.log("gas, routerWrapper call  ", gasUsed);
    }

    /// @dev Mainnet's fee, minimum and refusals are the ones MockLBTC copies.
    function test_fork_feeAndMinimumMatchTheMock() public {
        uint256 fee = ILBTCMainnet(LBTC).getRedeemFee();
        uint256 min = ILBTCMainnet(LBTC).getRedeemForBtcMinAmount();
        assertEq(fee, 10_000, "redeem fee");
        assertEq(min, 3_300, "minimum after fee");

        _expectRedeemRevert(fee, abi.encodeWithSelector(MockLBTC.AssetRouter_FeeGreaterThanAmount.selector));
        _expectRedeemRevert(fee + min - 1, abi.encodeWithSelector(MockLBTC.AmountBelowMinLimit.selector, min));
        _redeem(fee + min);
    }

    function _expectRedeemRevert(uint256 amount, bytes memory err) internal {
        vm.prank(vault);
        IERC20(LBTC).approve(address(wrapper), amount);
        vm.expectRevert(err);
        vm.prank(vault);
        wrapper.routerWrapper("redeemForBtc", abi.encode("redeemForBtc", P2TR, amount));
    }

    /// @dev A replayed mainnet mint reverts with the error the mock uses.
    function test_fork_replayedMintRevertsLikeTheMock() public {
        bytes memory delivered =
            LombardPayload.mint(0x1530, ASSET_ROUTER, LBTC, 0x5bdE80F61216F2D6977D360694E2D468Ea5D744B, 0x11322c3c);
        vm.expectRevert(MockLBTC.AssetRouter_MintProcessingError.selector);
        ILBTCMainnet(LBTC).mint(delivered, abi.encode(new bytes[](0)));
    }
}
