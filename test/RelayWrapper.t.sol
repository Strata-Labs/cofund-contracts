// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Foundry port of the wrapper-level behaviour in test/RelayWrapper.poc.ts (WP7).
//
// The TypeScript POC drove RelayWrapper through the v0 vault + forwarder
// stack (State/Gov/Forwarder/Policies/Users/VaultFactory, a two-admin
// EIP-712 `executeTransaction`) and, in FORK mode, through live calldata
// from https://api.relay.link/quote. None of that plumbing is ported: it is
// v0 infrastructure being deleted, and it exercises the vault, not the
// wrapper. What is ported is the wrapper's own contract: what
// `RelayWrapper.routerWrapper` does with a MockRelayRouter -- decode,
// validate, pull, approve, dispatch verbatim calldata, sweep, reset, emit.
//
// In production a Cofund vault calls `routerWrapper` after granting an
// allowance through its `allowances` array; here a plain test address
// ("vault") holds the tokens, approves the wrapper directly and calls it.

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {RelayWrapper} from "../contracts/RelayWrapper.sol";
import {MockRelayRouter} from "../contracts/MockRelayRouter.sol";
import {MockRelayTarget} from "../contracts/MockRelayTarget.sol";
import {MockToken} from "../contracts/MockToken.sol";

contract RelayWrapperTest is Test {
    /// @dev Mirrors of the events under test, for `vm.expectEmit`.
    event RelayDispatched(
        address indexed vault,
        address indexed target,
        address indexed inputToken,
        uint256 amount,
        bytes32 dataHash
    );
    event DepositPulled(
        address indexed from, address indexed token, uint256 amount, uint256 value
    );

    RelayWrapper internal wrapper;
    MockRelayRouter internal router;
    MockToken internal usdc;

    address internal vault;

    /// @dev 100 USDC at 6 decimals, the POC's USDC_AMOUNT.
    uint256 internal constant AMOUNT = 100_000_000;

    function setUp() public {
        wrapper = new RelayWrapper();
        router = new MockRelayRouter();
        usdc = new MockToken();

        vault = makeAddr("vault");
        vm.deal(vault, 100 ether);

        usdc.mint(vault, AMOUNT * 3);
        vm.prank(vault);
        usdc.approve(address(wrapper), type(uint256).max);
    }

    // ---------------------------------------------------------------- utils

    /// @dev The `instructions` payload every RelayWrapper call decodes.
    function _instructions(
        string memory func,
        address inputToken,
        uint256 amount,
        address target,
        bytes memory data
    ) internal pure returns (bytes memory) {
        return abi.encode(func, inputToken, amount, target, data);
    }

    /// @dev The single "deposit" step the POC's `localQuote` synthesised.
    function _depositCalldata(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(MockRelayRouter.deposit, (address(usdc), amount));
    }

    function _entry(uint256 amount, address target, bytes memory data)
        internal
        view
        returns (bytes memory)
    {
        return _instructions("entry", address(usdc), amount, target, data);
    }

    // ---------------------------------------------------------- error cases

    /// @dev `func` must be exactly "entry"; the check precedes every other guard.
    function test_RevertWhen_FuncIsNotEntry() public {
        bytes memory instructions = _instructions(
            "deposit", address(usdc), AMOUNT, address(router), _depositCalldata(AMOUNT)
        );

        vm.expectRevert(abi.encodeWithSelector(RelayWrapper.UnsupportedFunc.selector, "deposit"));
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    function test_RevertWhen_FuncCasingDiffers() public {
        bytes memory instructions =
            _instructions("Entry", address(usdc), AMOUNT, address(router), _depositCalldata(AMOUNT));

        vm.expectRevert(abi.encodeWithSelector(RelayWrapper.UnsupportedFunc.selector, "Entry"));
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev With every field invalid, the func guard is the one that fires.
    function test_RevertWhen_EverythingIsInvalid_FuncGuardWins() public {
        bytes memory instructions = _instructions("", address(0), 0, address(0), "");

        vm.expectRevert(abi.encodeWithSelector(RelayWrapper.UnsupportedFunc.selector, ""));
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    function test_RevertWhen_InputTokenIsZero() public {
        bytes memory instructions =
            _instructions("entry", address(0), AMOUNT, address(router), _depositCalldata(AMOUNT));

        vm.expectRevert(RelayWrapper.InvalidToken.selector);
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    function test_RevertWhen_AmountIsZero() public {
        bytes memory instructions = _entry(0, address(router), _depositCalldata(AMOUNT));

        vm.expectRevert(RelayWrapper.InvalidAmount.selector);
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    function test_RevertWhen_TargetIsZero() public {
        bytes memory instructions = _entry(AMOUNT, address(0), _depositCalldata(AMOUNT));

        vm.expectRevert(RelayWrapper.InvalidTarget.selector);
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev Token guard precedes the amount guard, which precedes the target guard.
    function test_RevertWhen_TokenAndAmountBothInvalid_TokenWins() public {
        bytes memory instructions = _instructions("entry", address(0), 0, address(0), "");

        vm.expectRevert(RelayWrapper.InvalidToken.selector);
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    function test_RevertWhen_AmountAndTargetBothInvalid_AmountWins() public {
        bytes memory instructions = _entry(0, address(0), "");

        vm.expectRevert(RelayWrapper.InvalidAmount.selector);
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev The caller must have approved the wrapper (the vault's `allowances`).
    function test_RevertWhen_CallerHasNotApprovedTheWrapper() public {
        address stranger = makeAddr("stranger");
        usdc.mint(stranger, AMOUNT);

        bytes memory instructions = _entry(AMOUNT, address(router), _depositCalldata(AMOUNT));

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(wrapper), 0, AMOUNT
            )
        );
        vm.prank(stranger);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev Approval without balance still fails at the pull.
    function test_RevertWhen_CallerHasInsufficientBalance() public {
        address pauper = makeAddr("pauper");
        vm.prank(pauper);
        usdc.approve(address(wrapper), type(uint256).max);

        bytes memory instructions = _entry(AMOUNT, address(router), _depositCalldata(AMOUNT));

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, pauper, 0, AMOUNT
            )
        );
        vm.prank(pauper);
        wrapper.routerWrapper("entry", instructions);
    }

    // --------------------------------------------------- dispatch failures

    /// @dev A target that reverts with no data yields RelayCallFailed("").
    function test_RevertWhen_TargetRevertsWithoutReason() public {
        // MockRelayRouter has no fallback, so an unknown selector reverts bare.
        bytes memory instructions =
            _entry(AMOUNT, address(router), abi.encodeWithSignature("notAFunction()"));

        vm.expectRevert(abi.encodeWithSelector(RelayWrapper.RelayCallFailed.selector, bytes("")));
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev The target's own revert data is carried inside RelayCallFailed.
    function test_RevertWhen_TargetReverts_ReasonIsCarried() public {
        MockRelayTarget target = new MockRelayTarget();
        bytes memory boom = abi.encodeCall(MockRelayTarget.boom, (7));

        bytes memory expectedReason = abi.encodeWithSelector(MockRelayTarget.Boom.selector, uint256(7));
        bytes memory instructions = _entry(AMOUNT, address(target), boom);

        vm.expectRevert(
            abi.encodeWithSelector(RelayWrapper.RelayCallFailed.selector, expectedReason)
        );
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev The approval is scoped to `amount`: calldata asking for more fails.
    function test_RevertWhen_TargetPullsMoreThanTheApprovedAmount() public {
        bytes memory instructions =
            _entry(AMOUNT, address(router), _depositCalldata(AMOUNT * 2));

        bytes memory expectedReason = abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientAllowance.selector, address(router), AMOUNT, AMOUNT * 2
        );

        vm.expectRevert(
            abi.encodeWithSelector(RelayWrapper.RelayCallFailed.selector, expectedReason)
        );
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev Native value to a non-payable target fails the dispatch.
    function test_RevertWhen_TargetCannotAcceptValue() public {
        MockRelayTarget target = new MockRelayTarget();
        bytes memory instructions =
            _entry(AMOUNT, address(target), abi.encodeCall(MockRelayTarget.record, (1)));

        vm.expectRevert(abi.encodeWithSelector(RelayWrapper.RelayCallFailed.selector, bytes("")));
        vm.prank(vault);
        wrapper.routerWrapper{value: 1 ether}("entry", instructions);
    }

    // ------------------------------------------------------- happy dispatch

    /// POC: "dispatches a Relay swap+bridge intent" -- the wrapper half of it.
    function test_Dispatch_PullsTokensAndTheRouterTakesThem() public {
        uint256 before = usdc.balanceOf(vault);
        bytes memory instructions = _entry(AMOUNT, address(router), _depositCalldata(AMOUNT));

        vm.prank(vault);
        bool ok = wrapper.routerWrapper("entry", instructions);

        assertTrue(ok, "routerWrapper returned false");
        assertLt(usdc.balanceOf(vault), before, "vault kept its tokens");
        assertEq(before - usdc.balanceOf(vault), AMOUNT, "wrong amount ceded");
        assertEq(usdc.balanceOf(address(router)), AMOUNT, "router did not pull");
        // Assetless wrapper.
        assertEq(usdc.balanceOf(address(wrapper)), 0, "wrapper holds residual");
    }

    /// @dev The approval granted to the target is reset to zero afterwards.
    function test_Dispatch_ResetsTheTargetApprovalToZero() public {
        bytes memory instructions = _entry(AMOUNT, address(router), _depositCalldata(AMOUNT));

        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);

        assertEq(usdc.allowance(address(wrapper), address(router)), 0, "stale target approval");
    }

    /// POC: the `RelayDispatched` assertion.
    function test_Dispatch_EmitsRelayDispatched() public {
        bytes memory data = _depositCalldata(AMOUNT);
        bytes memory instructions = _entry(AMOUNT, address(router), data);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit RelayDispatched(vault, address(router), address(usdc), AMOUNT, keccak256(data));

        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev The router sees the wrapper as the depositor, not the vault.
    function test_Dispatch_RouterSeesTheWrapperAsDepositor() public {
        bytes memory instructions = _entry(AMOUNT, address(router), _depositCalldata(AMOUNT));

        vm.expectEmit(true, true, true, true, address(router));
        emit DepositPulled(address(wrapper), address(usdc), AMOUNT, 0);

        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev The calldata from the quote is forwarded byte for byte.
    function test_Dispatch_ForwardsCalldataVerbatim() public {
        MockRelayTarget target = new MockRelayTarget();
        bytes memory data = abi.encodeCall(MockRelayTarget.record, (42));

        vm.prank(vault);
        wrapper.routerWrapper("entry", _entry(AMOUNT, address(target), data));

        assertEq(target.lastData(), data, "calldata mutated");
        assertEq(target.lastCaller(), address(wrapper), "wrong caller");
        assertEq(target.callCount(), 1);
    }

    /// @dev Selectors the wrapper knows nothing about are dispatched all the same.
    function test_Dispatch_ForwardsUnknownSelectors() public {
        MockRelayTarget target = new MockRelayTarget();
        bytes memory data = abi.encodeWithSignature("someRelayRoute(uint256,bytes32)", 1, bytes32(0));

        vm.prank(vault);
        wrapper.routerWrapper("entry", _entry(AMOUNT, address(target), data));

        assertEq(target.lastData(), data, "calldata mutated");
    }

    /// @dev `msg.value` is forwarded to the target (the native-fee routes).
    function test_Dispatch_ForwardsMsgValueToTheTarget() public {
        bytes memory instructions = _entry(AMOUNT, address(router), _depositCalldata(AMOUNT));

        vm.expectEmit(true, true, true, true, address(router));
        emit DepositPulled(address(wrapper), address(usdc), AMOUNT, 0.25 ether);

        vm.prank(vault);
        wrapper.routerWrapper{value: 0.25 ether}("entry", instructions);

        assertEq(address(router).balance, 0.25 ether, "value not forwarded");
        assertEq(address(wrapper).balance, 0, "wrapper kept value");
    }

    /// @dev Only `msg.value` is forwarded -- a pre-funded wrapper balance is not.
    ///      The POC pre-funded the wrapper because the v0 vault did not forward
    ///      value; that ETH simply stayed put.
    function test_Dispatch_DoesNotSpendThePreFundedWrapperBalance() public {
        vm.deal(address(wrapper), 1 ether);
        bytes memory instructions = _entry(AMOUNT, address(router), _depositCalldata(AMOUNT));

        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);

        assertEq(address(wrapper).balance, 1 ether, "pre-funded ETH moved");
        assertEq(address(router).balance, 0, "router received value");
    }

    // ------------------------------------------------------------- sweeping

    /// @dev A target that pulls less than `amount` gets the rest swept back.
    function test_Dispatch_SweepsLeftoverDustBackToTheCaller() public {
        uint256 pulled = AMOUNT / 2;
        uint256 before = usdc.balanceOf(vault);

        vm.prank(vault);
        wrapper.routerWrapper("entry", _entry(AMOUNT, address(router), _depositCalldata(pulled)));

        assertEq(before - usdc.balanceOf(vault), pulled, "dust not returned");
        assertEq(usdc.balanceOf(address(router)), pulled);
        assertEq(usdc.balanceOf(address(wrapper)), 0, "wrapper holds residual");
        assertEq(usdc.allowance(address(wrapper), address(router)), 0);
    }

    /// @dev A target that pulls nothing leaves the caller whole.
    function test_Dispatch_ReturnsEverythingWhenTheTargetPullsNothing() public {
        MockRelayTarget target = new MockRelayTarget();
        uint256 before = usdc.balanceOf(vault);

        vm.prank(vault);
        wrapper.routerWrapper(
            "entry", _entry(AMOUNT, address(target), abi.encodeCall(MockRelayTarget.record, (1)))
        );

        assertEq(usdc.balanceOf(vault), before, "tokens lost");
        assertEq(usdc.balanceOf(address(wrapper)), 0);
    }

    /// @dev A target with no code accepts the call; the tokens round-trip.
    function test_Dispatch_TargetWithoutCodeSucceeds() public {
        address eoa = makeAddr("eoaTarget");
        uint256 before = usdc.balanceOf(vault);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit RelayDispatched(vault, eoa, address(usdc), AMOUNT, keccak256(""));

        vm.prank(vault);
        bool ok = wrapper.routerWrapper("entry", _entry(AMOUNT, eoa, ""));

        assertTrue(ok);
        assertEq(usdc.balanceOf(vault), before, "tokens lost to an EOA target");
        assertEq(usdc.balanceOf(address(wrapper)), 0);
    }

    /// @dev The sweep takes the wrapper's whole balance, including tokens that
    ///      were stranded there before this call. Worth knowing: whoever
    ///      dispatches next collects any dust an earlier caller left behind.
    function test_Dispatch_SweepAlsoTakesPreexistingWrapperBalance() public {
        usdc.mint(address(wrapper), 7);
        uint256 before = usdc.balanceOf(vault);

        vm.prank(vault);
        wrapper.routerWrapper("entry", _entry(AMOUNT, address(router), _depositCalldata(AMOUNT)));

        assertEq(before - usdc.balanceOf(vault), AMOUNT - 7, "stray dust not swept to caller");
        assertEq(usdc.balanceOf(address(wrapper)), 0);
    }

    // -------------------------------------------------------------- routing

    /// @dev The `name` argument is ignored; only `func` inside `instructions`
    ///      selects the branch. The POC always passed "entry".
    function test_RouterWrapper_IgnoresTheNameArgument() public {
        string[3] memory names = ["", "entry", "Treasury_Management"];

        for (uint256 i = 0; i < names.length; i++) {
            vm.prank(vault);
            bool ok = wrapper.routerWrapper(
                names[i], _entry(AMOUNT, address(router), _depositCalldata(AMOUNT))
            );
            assertTrue(ok, "dispatch rejected a name");
        }

        assertEq(usdc.balanceOf(address(router)), AMOUNT * 3);
        assertEq(usdc.balanceOf(vault), 0);
    }

    /// @dev Malformed `instructions` cannot decode into
    ///      (string,address,uint256,address,bytes).
    function test_RevertWhen_InstructionsAreMalformed() public {
        vm.expectRevert();
        vm.prank(vault);
        wrapper.routerWrapper("entry", abi.encode(uint256(1)));
    }

    /// @dev The wrapper accepts bare ETH (Relay native-fee refunds).
    function test_Receive_AcceptsEth() public {
        assertEq(address(wrapper).balance, 0);

        vm.prank(vault);
        (bool ok,) = address(wrapper).call{value: 1 ether}("");

        assertTrue(ok, "wrapper rejected ETH");
        assertEq(address(wrapper).balance, 1 ether);
    }
}
