// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Foundry port of test/CompoundWrapper.ts (WP7).
//
// Only the mock mode of the TypeScript suite is ported -- no network, no
// fork -- so each Comet market is a MockComet over a local base token
// (WETH9 for the WETH market, MockToken for USDC and USDT), exactly as the
// non-FORK branch of the TS `before` hook built it.
//
// In production a Cofund vault calls `routerWrapper`; here a plain test
// address ("vault") holds the tokens and calls the wrapper directly, which is
// what the TS suite did with its `owner` signer.

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {CompoundWrapper} from "../contracts/CompoundWrapper.sol";
import {MockComet} from "../contracts/MockComet.sol";
import {MockToken} from "../contracts/MockToken.sol";
import {WETH9} from "../contracts/WETH9.sol";

contract CompoundWrapperTest is Test {
    /// @dev Mirrors of CompoundWrapper's events, for `vm.expectEmit`.
    event Supplied(address indexed user, address indexed asset, uint256 amount);
    event Withdrawn(address indexed user, address indexed asset, uint256 amount);

    CompoundWrapper internal wrapper;

    WETH9 internal weth;
    MockToken internal usdc;
    MockToken internal usdt;

    MockComet internal usdcComet;
    MockComet internal wethComet;
    MockComet internal usdtComet;

    address internal vault;
    address internal user;

    function setUp() public {
        weth = new WETH9();
        usdc = new MockToken();
        usdt = new MockToken();

        usdcComet = new MockComet(address(usdc));
        wethComet = new MockComet(address(weth));
        usdtComet = new MockComet(address(usdt));

        // Ethereum configuration: all three markets.
        wrapper = new CompoundWrapper(address(usdcComet), address(wethComet), address(usdtComet));

        vault = makeAddr("vault");
        user = makeAddr("user");
        vm.deal(vault, 100 ether);
        vm.deal(user, 100 ether);
    }

    // ---------------------------------------------------------------- utils

    /// @dev The `instructions` payload every CompoundWrapper call decodes.
    function _instructions(
        string memory func,
        uint256 amount,
        address asset
    ) internal pure returns (bytes memory) {
        return abi.encode(func, amount, asset);
    }

    /// @dev WETH9 has no mint; wrap ETH the way the TS suite did.
    function _fundWeth(address to, uint256 amount) internal {
        vm.deal(to, to.balance + amount);
        vm.prank(to);
        weth.deposit{value: amount}();
    }

    /// @dev Fund + approve + supply WETH, the common prelude of the withdraw tests.
    function _supplyWeth(address caller, uint256 amount) internal {
        _fundWeth(caller, amount);
        vm.prank(caller);
        weth.approve(address(wrapper), amount);
        vm.prank(caller);
        wrapper.routerWrapper("entry", _instructions("supplyERC20", amount, address(weth)));
    }

    /// @dev A Base-like deployment: USDC + WETH markets, no USDT market.
    function _deployWithoutUsdt() internal returns (CompoundWrapper) {
        return new CompoundWrapper(address(usdcComet), address(wethComet), address(0));
    }

    // ----------------------------------------------------------- deployment

    /// TS: "Should have valid USDC comet address".
    function test_Deployment_UsdcCometWired() public view {
        assertEq(address(wrapper.usdcComet()), address(usdcComet));
    }

    /// TS: "Should have valid WETH comet address".
    function test_Deployment_WethCometWired() public view {
        assertEq(address(wrapper.wethComet()), address(wethComet));
    }

    /// TS: "Should have valid USDT comet address (Ethereum)".
    function test_Deployment_UsdtCometWired() public view {
        assertEq(address(wrapper.usdtComet()), address(usdtComet));
    }

    /// TS: "Should have valid base token (WETH)".
    function test_Deployment_WethCometBaseTokenIsWeth() public view {
        assertEq(wrapper.wethComet().baseToken(), address(weth));
        assertEq(wrapper.usdcComet().baseToken(), address(usdc));
        assertEq(wrapper.usdtComet().baseToken(), address(usdt));
    }

    /// TS: "Should deploy with optional USDT disabled (Base-like deployment)".
    function test_Deployment_UsdtMarketIsOptional() public {
        CompoundWrapper baseWrapper = _deployWithoutUsdt();

        assertEq(address(baseWrapper.usdtComet()), address(0));
        assertEq(address(baseWrapper.usdcComet()), address(usdcComet));
        assertEq(address(baseWrapper.wethComet()), address(wethComet));
    }

    /// @dev The two required markets are checked in the constructor.
    function test_Deployment_RevertWhen_UsdcCometIsZero() public {
        vm.expectRevert(bytes("Invalid USDC Comet address"));
        new CompoundWrapper(address(0), address(wethComet), address(usdtComet));
    }

    function test_Deployment_RevertWhen_WethCometIsZero() public {
        vm.expectRevert(bytes("Invalid WETH Comet address"));
        new CompoundWrapper(address(usdcComet), address(0), address(usdtComet));
    }

    /// TS: "Should revert when supplying unsupported USDT on Base-like deployment".
    function test_RevertWhen_SupplyingUsdtWithoutAUsdtMarket() public {
        CompoundWrapper baseWrapper = _deployWithoutUsdt();

        usdc.mint(vault, 1_000_000);
        bytes memory instructions = _instructions("supplyERC20", 1_000_000, address(usdt));

        vm.expectRevert(CompoundWrapper.InvalidAsset.selector);
        vm.prank(vault);
        baseWrapper.routerWrapper("entry", instructions);
    }

    // ---------------------------------------------------------- error cases

    /// TS: "Should revert with invalid asset address".
    function test_RevertWhen_AssetIsZeroAddress() public {
        bytes memory instructions = _instructions("supplyERC20", 1 ether, address(0));

        vm.expectRevert(CompoundWrapper.InvalidAsset.selector);
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// TS: "Should revert with zero amount".
    function test_RevertWhen_AmountIsZero() public {
        bytes memory instructions = _instructions("supplyERC20", 0, address(weth));

        vm.expectRevert(CompoundWrapper.InvalidAmount.selector);
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev The zero-asset guard runs before the zero-amount guard.
    function test_RevertWhen_AssetAndAmountBothInvalid_AssetWins() public {
        bytes memory instructions = _instructions("supplyERC20", 0, address(0));

        vm.expectRevert(CompoundWrapper.InvalidAsset.selector);
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// TS: "Should revert with unsupported function".
    function test_RevertWhen_FuncIsUnsupported() public {
        bytes memory instructions = _instructions("unsupportedFunction", 1 ether, address(weth));

        vm.expectRevert(
            abi.encodeWithSelector(CompoundWrapper.UnsupportedFunc.selector, "unsupportedFunction")
        );
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev `func` is matched exactly -- no case folding, no trimming.
    function test_RevertWhen_FuncCasingDiffers() public {
        bytes memory instructions = _instructions("WithdrawERC20", 1 ether, address(weth));

        vm.expectRevert(
            abi.encodeWithSelector(CompoundWrapper.UnsupportedFunc.selector, "WithdrawERC20")
        );
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev A token that is no market's base token is rejected by `getComet`.
    function test_RevertWhen_AssetIsNotAMarketBaseToken() public {
        MockToken stray = new MockToken();
        stray.mint(vault, 1 ether);

        bytes memory instructions = _instructions("supplyERC20", 1 ether, address(stray));

        vm.expectRevert(CompoundWrapper.InvalidAsset.selector);
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev The same rejection applies on the withdraw branch.
    function test_RevertWhen_WithdrawAssetIsNotAMarketBaseToken() public {
        MockToken stray = new MockToken();
        bytes memory instructions = _instructions("withdrawERC20", 1 ether, address(stray));

        vm.expectRevert(CompoundWrapper.InvalidAsset.selector);
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// TS: "Should revert when vault hasn't approved wrapper".
    ///     WETH9 reverts bare on an allowance shortfall.
    function test_RevertWhen_SupplyWithoutApprovingWrapper() public {
        _fundWeth(user, 1 ether);
        bytes memory instructions = _instructions("supplyERC20", 1 ether, address(weth));

        vm.expectRevert();
        vm.prank(user);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev Same shortfall on an OZ ERC20 market surfaces the typed error.
    function test_RevertWhen_SupplyWithoutApprovingWrapper_TypedError() public {
        usdc.mint(user, 1_000_000);
        bytes memory instructions = _instructions("supplyERC20", 1_000_000, address(usdc));

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(wrapper), 0, 1_000_000
            )
        );
        vm.prank(user);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev Comet's binary permission must be granted before a withdrawal.
    function test_RevertWhen_WithdrawWithoutCometPermission() public {
        _supplyWeth(vault, 1 ether);

        bytes memory instructions = _instructions("withdrawERC20", 0.5 ether, address(weth));

        vm.expectRevert(bytes("MockComet: not permitted"));
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    /// @dev Comet itself rejects an over-withdrawal; the wrapper does not pre-check.
    function test_RevertWhen_WithdrawExceedsPosition() public {
        _supplyWeth(vault, 1 ether);
        vm.prank(vault);
        wethComet.approve(address(wrapper), type(uint256).max);

        bytes memory instructions = _instructions("withdrawERC20", 2 ether, address(weth));

        vm.expectRevert(bytes("MockComet: insufficient balance"));
        vm.prank(vault);
        wrapper.routerWrapper("entry", instructions);
    }

    // ----------------------------------------------------------- supply leg

    /// TS: "Should supply WETH successfully".
    function test_Supply_CreditsCallerPositionAndLeavesWrapperAssetless() public {
        uint256 amount = 1 ether;
        _fundWeth(vault, amount);
        assertEq(weth.balanceOf(vault), amount);
        assertEq(wethComet.balanceOf(vault), 0, "position should start empty");

        vm.prank(vault);
        weth.approve(address(wrapper), amount);

        vm.prank(vault);
        bool ok = wrapper.routerWrapper("entry", _instructions("supplyERC20", amount, address(weth)));

        assertTrue(ok, "routerWrapper returned false");
        // The mock credits 1:1 (the real Comet loses a wei to principal rounding).
        assertEq(wethComet.balanceOf(vault), amount, "vault position wrong");
        assertEq(weth.balanceOf(vault), 0, "vault kept WETH");
        assertEq(weth.balanceOf(address(wethComet)), amount, "comet did not receive WETH");

        // Assetless wrapper: neither the token nor the position stays behind.
        assertEq(weth.balanceOf(address(wrapper)), 0, "wrapper kept WETH");
        assertEq(wethComet.balanceOf(address(wrapper)), 0, "wrapper kept a position");
    }

    /// TS: "Should emit Supplied event".
    function test_Supply_EmitsSupplied() public {
        uint256 amount = 0.5 ether;
        _fundWeth(vault, amount);
        vm.prank(vault);
        weth.approve(address(wrapper), amount);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit Supplied(vault, address(weth), amount);

        vm.prank(vault);
        wrapper.routerWrapper("entry", _instructions("supplyERC20", amount, address(weth)));
    }

    /// TS: "Should handle multiple supplies correctly".
    function test_Supply_MultipleSuppliesAccumulate() public {
        assertEq(wethComet.balanceOf(vault), 0);

        _supplyWeth(vault, 0.3 ether);
        assertGe(wethComet.balanceOf(vault), 0.3 ether);

        _supplyWeth(vault, 0.7 ether);
        assertGe(wethComet.balanceOf(vault), 1 ether);
        assertEq(weth.balanceOf(address(wethComet)), 1 ether);
    }

    /// @dev `safeIncreaseAllowance` is consumed in full by `comet.supplyFrom`.
    function test_Supply_ConsumesTheWrapperAllowanceItGrants() public {
        _supplyWeth(vault, 1 ether);
        assertEq(weth.allowance(address(wrapper), address(wethComet)), 0, "stale comet allowance");
        assertEq(weth.allowance(vault, address(wrapper)), 0, "stale wrapper allowance");
    }

    /// @dev `getComet` routes USDC to the USDC market, not the WETH market.
    function test_Supply_RoutesUsdcToTheUsdcMarket() public {
        usdc.mint(vault, 1_000_000);
        vm.prank(vault);
        usdc.approve(address(wrapper), 1_000_000);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit Supplied(vault, address(usdc), 1_000_000);

        vm.prank(vault);
        wrapper.routerWrapper("entry", _instructions("supplyERC20", 1_000_000, address(usdc)));

        assertEq(usdcComet.balanceOf(vault), 1_000_000);
        assertEq(wethComet.balanceOf(vault), 0, "credited the wrong market");
        assertEq(usdc.balanceOf(address(usdcComet)), 1_000_000);
    }

    /// @dev The optional USDT market is reachable when it is configured.
    function test_Supply_RoutesUsdtToTheUsdtMarketWhenConfigured() public {
        usdt.mint(vault, 1_000_000);
        vm.prank(vault);
        usdt.approve(address(wrapper), 1_000_000);

        vm.prank(vault);
        wrapper.routerWrapper("entry", _instructions("supplyERC20", 1_000_000, address(usdt)));

        assertEq(usdtComet.balanceOf(vault), 1_000_000);
        assertEq(usdcComet.balanceOf(vault), 0, "credited the wrong market");
    }

    /// @dev Each caller is credited separately -- `dst` is msg.sender.
    function test_Supply_CreditsEachCallerSeparately() public {
        _supplyWeth(vault, 1 ether);
        _supplyWeth(user, 2 ether);

        assertEq(wethComet.balanceOf(vault), 1 ether);
        assertEq(wethComet.balanceOf(user), 2 ether);
        assertEq(wethComet.balanceOf(address(wrapper)), 0);
    }

    // --------------------------------------------------------- withdraw leg

    /// TS: "Should withdraw WETH with accrued interest".
    function test_Withdraw_WithAccruedInterest() public {
        uint256 supplyAmount = 2 ether;
        _supplyWeth(vault, supplyAmount);

        uint256 initialPosition = wethComet.balanceOf(vault);
        assertEq(initialPosition, supplyAmount);

        // Advance blocks so MockComet accrues interest, as the TS suite did
        // with 100 `evm_mine` calls.
        vm.roll(block.number + 100);

        uint256 positionWithInterest = wethComet.balanceOf(vault);
        assertGt(positionWithInterest, initialPosition, "no interest accrued");

        uint256 wethBefore = weth.balanceOf(vault);

        // Comet's approve is a binary permission grant.
        vm.prank(vault);
        wethComet.approve(address(wrapper), type(uint256).max);

        uint256 withdrawAmount = 1.5 ether;
        vm.prank(vault);
        bool ok = wrapper.routerWrapper(
            "entry", _instructions("withdrawERC20", withdrawAmount, address(weth))
        );

        assertTrue(ok, "routerWrapper returned false");

        uint256 finalPosition = wethComet.balanceOf(vault);
        assertApproxEqAbs(positionWithInterest - finalPosition, withdrawAmount, 0.001 ether);
        assertApproxEqAbs(weth.balanceOf(vault) - wethBefore, withdrawAmount, 0.001 ether);
        assertGt(finalPosition, 0, "position fully drained");

        // The interest survives the partial withdrawal.
        assertGt(finalPosition, supplyAmount - withdrawAmount);
        assertEq(wethComet.balanceOf(address(wrapper)), 0, "wrapper kept a position");
        assertEq(weth.balanceOf(address(wrapper)), 0, "wrapper kept WETH");
    }

    /// TS: "Should emit Withdrawn event".
    function test_Withdraw_EmitsWithdrawn() public {
        _supplyWeth(vault, 1 ether);
        vm.prank(vault);
        wethComet.approve(address(wrapper), type(uint256).max);

        uint256 withdrawAmount = 0.5 ether;

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit Withdrawn(vault, address(weth), withdrawAmount);

        vm.prank(vault);
        wrapper.routerWrapper("entry", _instructions("withdrawERC20", withdrawAmount, address(weth)));
    }

    /// @dev The underlying goes to the caller (`to == msg.sender`), never the wrapper.
    function test_Withdraw_SendsUnderlyingToTheCaller() public {
        _supplyWeth(vault, 1 ether);
        vm.prank(vault);
        wethComet.approve(address(wrapper), type(uint256).max);

        vm.prank(vault);
        wrapper.routerWrapper("entry", _instructions("withdrawERC20", 1 ether, address(weth)));

        assertEq(weth.balanceOf(vault), 1 ether);
        assertEq(wethComet.balanceOf(vault), 0);
        assertEq(weth.balanceOf(address(wethComet)), 0);
        assertEq(weth.balanceOf(address(wrapper)), 0);
    }

    /// @dev Withdrawing routes through `getComet` too.
    function test_Withdraw_RoutesUsdcToTheUsdcMarket() public {
        usdc.mint(vault, 1_000_000);
        vm.prank(vault);
        usdc.approve(address(wrapper), 1_000_000);
        vm.prank(vault);
        wrapper.routerWrapper("entry", _instructions("supplyERC20", 1_000_000, address(usdc)));

        vm.prank(vault);
        usdcComet.approve(address(wrapper), type(uint256).max);

        vm.prank(vault);
        wrapper.routerWrapper("entry", _instructions("withdrawERC20", 400_000, address(usdc)));

        assertEq(usdc.balanceOf(vault), 400_000);
        assertEq(usdcComet.balanceOf(vault), 600_000);
    }

    // -------------------------------------------------------------- routing

    /// @dev The `name` argument is ignored; only `func` inside `instructions`
    ///      selects the branch. The TS suite always passed "entry".
    function test_RouterWrapper_IgnoresTheNameArgument() public {
        string[3] memory names = ["", "entry", "Treasury_Management"];

        for (uint256 i = 0; i < names.length; i++) {
            _fundWeth(vault, 1 ether);
            vm.prank(vault);
            weth.approve(address(wrapper), 1 ether);

            vm.prank(vault);
            bool ok =
                wrapper.routerWrapper(names[i], _instructions("supplyERC20", 1 ether, address(weth)));
            assertTrue(ok, "dispatch rejected a name");
        }

        assertEq(wethComet.balanceOf(vault), 3 ether);
    }

    /// @dev Malformed `instructions` cannot decode into (string,uint256,address).
    function test_RevertWhen_InstructionsAreMalformed() public {
        vm.expectRevert();
        vm.prank(vault);
        wrapper.routerWrapper("entry", abi.encode(uint256(1)));
    }
}
