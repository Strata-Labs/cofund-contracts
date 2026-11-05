// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Foundry port of test/AaveWrapper.ts (WP7).
//
// The TypeScript suite ran in two modes: against the real Aave v3 deployment
// on a mainnet fork, or against local mocks. Only the mock mode is ported --
// no network, no fork -- so the Aave side is MockAavePool + MockAToken behind
// MockPoolAddressesProvider, and WETH9 is the underlying, exactly as the
// non-FORK branch of the TS `before` hook built it.
//
// In production a Cofund vault calls `routerWrapper`; here a plain test
// address ("vault") holds the tokens and calls the wrapper directly, which is
// what the TS suite did with its `owner` signer.

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {AaveWrapper} from "../contracts/AaveWrapper.sol";
import {MockAavePool, MockPoolAddressesProvider} from "../contracts/MockAave.sol";
import {MockToken} from "../contracts/MockToken.sol";
import {WETH9} from "../contracts/WETH9.sol";

contract AaveWrapperTest is Test {
    /// @dev Mirror of the ERC20 event, for `vm.expectEmit` on the aToken.
    event Transfer(address indexed from, address indexed to, uint256 value);

    AaveWrapper internal wrapper;
    MockAavePool internal pool;
    MockPoolAddressesProvider internal provider;
    WETH9 internal weth;
    IERC20 internal aWeth;

    address internal vault;

    function setUp() public {
        weth = new WETH9();

        pool = new MockAavePool();
        aWeth = IERC20(pool.initReserve(address(weth)));

        provider = new MockPoolAddressesProvider(address(pool));
        wrapper = new AaveWrapper(address(provider));

        vault = makeAddr("vault");
        vm.deal(vault, 100 ether);
    }

    // ---------------------------------------------------------------- utils

    /// @dev The `instructions` payload every AaveWrapper call decodes.
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

    /// @dev Fund + approve + supply, the common prelude of the withdraw tests.
    function _supply(address caller, uint256 amount) internal {
        _fundWeth(caller, amount);
        vm.prank(caller);
        weth.approve(address(wrapper), amount);
        vm.prank(caller);
        wrapper.routerWrapper("Entry", _instructions("supplyERC20", amount, address(weth)));
    }

    // ----------------------------------------------------------- deployment

    /// TS: "Should have valid pool address".
    function test_Deployment_ResolvesPoolFromProvider() public view {
        assertTrue(address(wrapper.pool()) != address(0), "pool unset");
        assertEq(address(wrapper.pool()), address(pool));
        assertEq(address(wrapper.provider()), address(provider));
    }

    /// TS: "Should get aToken address for WETH".
    function test_Deployment_ReserveExposesATokenForWeth() public view {
        address aToken = wrapper.pool().getReserveData(address(weth)).aTokenAddress;
        assertTrue(aToken != address(0), "no aToken");
        assertEq(aToken, address(aWeth));
    }

    /// TS: "Should return zero balance initially".
    function test_Deployment_ATokenBalanceStartsAtZero() public view {
        assertEq(aWeth.balanceOf(vault), 0);
        assertEq(aWeth.balanceOf(address(wrapper)), 0);
    }

    // ---------------------------------------------------------- error cases

    /// TS: "Should revert when trying to withdraw without sufficient aTokens".
    function test_RevertWhen_WithdrawingWithoutATokens() public {
        bytes memory instructions = _instructions("withdrawERC20", 1 ether, address(weth));

        vm.expectRevert(
            abi.encodeWithSelector(AaveWrapper.InsufficientBalance.selector, address(weth), 1 ether, 0)
        );
        vm.prank(vault);
        wrapper.routerWrapper("withdraw", instructions);
    }

    /// TS: "Should revert with invalid asset address".
    function test_RevertWhen_AssetIsZeroAddress() public {
        bytes memory instructions = _instructions("supplyERC20", 1 ether, address(0));

        vm.expectRevert(AaveWrapper.InvalidAsset.selector);
        vm.prank(vault);
        wrapper.routerWrapper("supply", instructions);
    }

    /// TS: "Should revert with zero amount".
    function test_RevertWhen_AmountIsZero() public {
        bytes memory instructions = _instructions("supplyERC20", 0, address(weth));

        vm.expectRevert(AaveWrapper.InvalidAmount.selector);
        vm.prank(vault);
        wrapper.routerWrapper("supply", instructions);
    }

    /// @dev The zero-asset guard runs before the zero-amount guard.
    function test_RevertWhen_AssetAndAmountBothInvalid_AssetWins() public {
        bytes memory instructions = _instructions("supplyERC20", 0, address(0));

        vm.expectRevert(AaveWrapper.InvalidAsset.selector);
        vm.prank(vault);
        wrapper.routerWrapper("supply", instructions);
    }

    /// TS: "Should revert with unsupported function".
    function test_RevertWhen_FuncIsUnsupported() public {
        bytes memory instructions = _instructions("unsupportedFunction", 1 ether, address(weth));

        vm.expectRevert(
            abi.encodeWithSelector(AaveWrapper.UnsupportedFunction.selector, "unsupportedFunction")
        );
        vm.prank(vault);
        wrapper.routerWrapper("test", instructions);
    }

    /// @dev `func` is matched exactly -- no case folding, no trimming.
    function test_RevertWhen_FuncCasingDiffers() public {
        bytes memory instructions = _instructions("SupplyERC20", 1 ether, address(weth));

        vm.expectRevert(
            abi.encodeWithSelector(AaveWrapper.UnsupportedFunction.selector, "SupplyERC20")
        );
        vm.prank(vault);
        wrapper.routerWrapper("supply", instructions);
    }

    /// @dev Withdraw path: an asset with no reserve has aToken == 0.
    function test_RevertWhen_WithdrawAssetHasNoReserve() public {
        MockToken stray = new MockToken();
        bytes memory instructions = _instructions("withdrawERC20", 1 ether, address(stray));

        vm.expectRevert(AaveWrapper.InvalidAsset.selector);
        vm.prank(vault);
        wrapper.routerWrapper("withdraw", instructions);
    }

    /// @dev The vault must approve the wrapper first; WETH9 reverts bare.
    function test_RevertWhen_SupplyWithoutApprovingWrapper() public {
        _fundWeth(vault, 1 ether);
        bytes memory instructions = _instructions("supplyERC20", 1 ether, address(weth));

        vm.expectRevert();
        vm.prank(vault);
        wrapper.routerWrapper("Entry", instructions);
    }

    /// @dev The vault must approve the wrapper for aTokens before withdrawing.
    function test_RevertWhen_WithdrawWithoutApprovingATokens() public {
        _supply(vault, 1 ether);

        bytes memory instructions = _instructions("withdrawERC20", 1 ether, address(weth));

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(wrapper), 0, 1 ether
            )
        );
        vm.prank(vault);
        wrapper.routerWrapper("withdraw", instructions);
    }

    /// @dev A failing `pool.withdraw` is caught and re-thrown as WithdrawalFailed.
    function test_RevertWhen_PoolWithdrawReverts() public {
        _supply(vault, 1 ether);
        vm.prank(vault);
        aWeth.approve(address(wrapper), type(uint256).max);

        vm.mockCallRevert(address(pool), MockAavePool.withdraw.selector, "pool down");

        bytes memory instructions = _instructions("withdrawERC20", 1 ether, address(weth));

        vm.expectRevert(
            abi.encodeWithSelector(AaveWrapper.WithdrawalFailed.selector, address(weth), 1 ether)
        );
        vm.prank(vault);
        wrapper.routerWrapper("withdraw", instructions);
    }

    // ----------------------------------------------------------- supply leg

    /// TS: steps 1-4 of "Should supply and withdraw WETH successfully".
    function test_Supply_MovesUnderlyingToPoolAndMintsATokensToCaller() public {
        uint256 amount = 1 ether;
        _fundWeth(vault, amount);
        assertEq(weth.balanceOf(vault), amount);

        vm.prank(vault);
        weth.approve(address(wrapper), amount);

        // aTokens are minted straight to the caller, never to the wrapper.
        vm.expectEmit(true, true, true, true, address(aWeth));
        emit Transfer(address(0), vault, amount);

        vm.prank(vault);
        bool ok = wrapper.routerWrapper("Entry", _instructions("supplyERC20", amount, address(weth)));

        assertTrue(ok, "routerWrapper returned false");
        assertEq(weth.balanceOf(vault), 0, "vault kept WETH");
        assertEq(weth.balanceOf(address(pool)), amount, "pool did not receive WETH");
        assertEq(aWeth.balanceOf(vault), amount, "vault has no aTokens");
    }

    /// TS: "Should demonstrate assetless nature - wrapper holds no aTokens".
    function test_Supply_LeavesWrapperAssetless() public {
        uint256 amount = 0.1 ether;
        _supply(vault, amount);

        assertGt(aWeth.balanceOf(vault), 0, "vault holds no position");
        assertEq(aWeth.balanceOf(address(wrapper)), 0, "wrapper holds aTokens");
        assertEq(weth.balanceOf(address(wrapper)), 0, "wrapper holds WETH");
    }

    /// @dev `safeIncreaseAllowance` is consumed in full by `pool.supply`.
    function test_Supply_ConsumesTheWrapperAllowanceItGrants() public {
        _supply(vault, 1 ether);
        assertEq(weth.allowance(address(wrapper), address(pool)), 0, "stale pool allowance");
        assertEq(weth.allowance(vault, address(wrapper)), 0, "stale wrapper allowance");
    }

    /// @dev Supplies accumulate on the caller's aToken balance.
    function test_Supply_AccumulatesAcrossCalls() public {
        _supply(vault, 0.3 ether);
        assertEq(aWeth.balanceOf(vault), 0.3 ether);

        _supply(vault, 0.7 ether);
        assertEq(aWeth.balanceOf(vault), 1 ether);
        assertEq(weth.balanceOf(address(pool)), 1 ether);
    }

    /// @dev Each caller is credited separately -- `onBehalfOf` is msg.sender.
    function test_Supply_CreditsEachCallerSeparately() public {
        address other = makeAddr("otherVault");

        _supply(vault, 1 ether);
        _supply(other, 2 ether);

        assertEq(aWeth.balanceOf(vault), 1 ether);
        assertEq(aWeth.balanceOf(other), 2 ether);
        assertEq(aWeth.balanceOf(address(wrapper)), 0);
    }

    // --------------------------------------------------------- withdraw leg

    /// TS: steps 5-8 of "Should supply and withdraw WETH successfully".
    function test_Withdraw_BurnsATokensAndReturnsUnderlyingToCaller() public {
        uint256 amount = 1 ether;
        _supply(vault, amount);

        uint256 aTokenBalance = aWeth.balanceOf(vault);
        vm.prank(vault);
        aWeth.approve(address(wrapper), aTokenBalance);

        vm.prank(vault);
        bool ok = wrapper.routerWrapper(
            "Treasury_Management", _instructions("withdrawERC20", aTokenBalance, address(weth))
        );

        assertTrue(ok, "routerWrapper returned false");
        assertEq(aWeth.balanceOf(vault), 0, "aTokens not burned");
        assertLt(aWeth.balanceOf(vault), aTokenBalance);
        assertEq(weth.balanceOf(vault), amount, "WETH not returned");
        assertGt(weth.balanceOf(vault), 0);
        assertEq(weth.balanceOf(address(pool)), 0, "pool kept WETH");
        assertEq(weth.balanceOf(address(wrapper)), 0, "wrapper kept WETH");
        assertEq(aWeth.balanceOf(address(wrapper)), 0, "wrapper kept aTokens");
    }

    /// @dev A partial withdrawal leaves the remainder as aTokens on the caller.
    function test_Withdraw_PartialLeavesRemainderStaked() public {
        _supply(vault, 1 ether);
        vm.prank(vault);
        aWeth.approve(address(wrapper), type(uint256).max);

        vm.prank(vault);
        wrapper.routerWrapper("withdraw", _instructions("withdrawERC20", 0.4 ether, address(weth)));

        assertEq(aWeth.balanceOf(vault), 0.6 ether);
        assertEq(weth.balanceOf(vault), 0.4 ether);
        assertEq(weth.balanceOf(address(pool)), 0.6 ether);
    }

    /// TS: "Should handle withdraw max amount correctly".
    function test_Withdraw_MaxUintDrainsTheWholeATokenBalance() public {
        uint256 amount = 0.5 ether;
        _supply(vault, amount);

        uint256 before = aWeth.balanceOf(vault);
        assertEq(before, amount);

        vm.prank(vault);
        aWeth.approve(address(wrapper), type(uint256).max);

        vm.prank(vault);
        bool ok = wrapper.routerWrapper(
            "MaxWithdraw", _instructions("withdrawERC20", type(uint256).max, address(weth))
        );

        assertTrue(ok, "routerWrapper returned false");
        assertLt(aWeth.balanceOf(vault), 0.001 ether);
        assertEq(aWeth.balanceOf(vault), 0, "mock accrues no interest; must be exact");
        assertEq(weth.balanceOf(vault), amount);
    }

    /// @dev Asking for more than the caller holds reports both figures.
    function test_RevertWhen_WithdrawExceedsATokenBalance() public {
        _supply(vault, 1 ether);
        vm.prank(vault);
        aWeth.approve(address(wrapper), type(uint256).max);

        bytes memory instructions = _instructions("withdrawERC20", 2 ether, address(weth));

        vm.expectRevert(
            abi.encodeWithSelector(
                AaveWrapper.InsufficientBalance.selector, address(weth), 2 ether, 1 ether
            )
        );
        vm.prank(vault);
        wrapper.routerWrapper("withdraw", instructions);
    }

    /// @dev Documents a wart: the aToken allowance the wrapper grants the Pool
    ///      is never spent (the Pool burns directly) and is never cleared.
    function test_Withdraw_LeavesResidualATokenAllowanceToThePool() public {
        _supply(vault, 1 ether);
        vm.prank(vault);
        aWeth.approve(address(wrapper), type(uint256).max);

        vm.prank(vault);
        wrapper.routerWrapper("withdraw", _instructions("withdrawERC20", 1 ether, address(weth)));

        assertEq(aWeth.allowance(address(wrapper), address(pool)), 1 ether);
    }

    // -------------------------------------------------------------- routing

    /// @dev The `name` argument is ignored; only `func` inside `instructions`
    ///      selects the branch. The TS suite passed "Entry", "supply",
    ///      "withdraw", "test", "Treasury_Management" and "MaxWithdraw".
    function test_RouterWrapper_IgnoresTheNameArgument() public {
        string[3] memory names = ["", "Entry", "Treasury_Management"];

        for (uint256 i = 0; i < names.length; i++) {
            _fundWeth(vault, 1 ether);
            vm.prank(vault);
            weth.approve(address(wrapper), 1 ether);

            vm.prank(vault);
            bool ok =
                wrapper.routerWrapper(names[i], _instructions("supplyERC20", 1 ether, address(weth)));
            assertTrue(ok, "dispatch rejected a name");
        }

        assertEq(aWeth.balanceOf(vault), 3 ether);
    }

    /// @dev Malformed `instructions` cannot decode into (string,uint256,address).
    function test_RevertWhen_InstructionsAreMalformed() public {
        vm.expectRevert();
        vm.prank(vault);
        wrapper.routerWrapper("Entry", abi.encode(uint256(1)));
    }
}
