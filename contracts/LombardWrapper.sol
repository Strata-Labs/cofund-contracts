// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The one LBTC call the wrapper makes.
interface ILBTC {
    /// @dev Burns `amount` from `msg.sender` and asks Lombard to pay
    ///      `amount` minus the redeem fee in BTC to `scriptPubkey`.
    function redeemForBtc(bytes calldata scriptPubkey, uint256 amount) external;
}

/// @title  LombardWrapper -- a Cofund vault's exit from LBTC to BTC.
///
/// @notice A v1 call-policy wrapper. The vault calls `routerWrapper` inside
///         `executeTransaction`, after approving it for exactly the signed
///         LBTC allowance. The wrapper pulls `amount` LBTC from the vault and
///         redeems it with Lombard to `scriptPubkey`.
///
///         `instructions` is `abi.encode(string func, bytes scriptPubkey,
///         uint256 amount)`, and `func` must be `"redeemForBtc"`. The `name`
///         argument is ignored, as in every other wrapper.
///
/// @dev    **Why the wrapper holds the LBTC.** Lombard's AssetRouter accepts a
///         redeem only from the holder or the token, and `redeemForBtc` burns
///         from `msg.sender`. So the wrapper takes the LBTC and is the holder
///         for the length of this one call; the redeem burns all of it.
///
///         **Why this is safe.**
///         - The signers approve the exact bytes. The vault's EIP-712
///           `Transaction` carries `instructionsHash = keccak256(instructions)`,
///           so the `scriptPubkey` -- where the BTC goes -- and the `amount`
///           are the ones the policy's signers signed. Nobody can swap the
///           destination after signing.
///         - The signers also sign the `Allowance[]`. The wrapper can pull no
///           more than that, and the vault resets the approval to zero after
///           the call.
///         - The policy binds this wrapper's address, and `lbtc` is fixed at
///           construction. There is no owner, no admin and no setter.
///         - Nothing stays behind. The wrapper approves nobody, and the call
///           reverts unless the redeem burned exactly the LBTC it pulled. LBTC
///           sent to this contract by mistake stays here: nothing can move it.
contract LombardWrapper {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error UnsupportedFunction(string func);
    error InvalidAmount();
    error InvalidScriptPubkey();
    /// @dev The redeem did not burn exactly what the wrapper pulled.
    error LeftoverBalance();

    bytes32 private constant REDEEM_FOR_BTC = keccak256("redeemForBtc");

    address public immutable lbtc;

    constructor(address lbtc_) {
        if (lbtc_ == address(0)) revert ZeroAddress();
        lbtc = lbtc_;
    }

    function routerWrapper(string calldata, bytes calldata instructions) external returns (bool) {
        (string memory func, bytes memory scriptPubkey, uint256 amount) =
            abi.decode(instructions, (string, bytes, uint256));

        if (keccak256(bytes(func)) != REDEEM_FOR_BTC) revert UnsupportedFunction(func);
        if (amount == 0) revert InvalidAmount();
        if (scriptPubkey.length == 0) revert InvalidScriptPubkey();

        IERC20 token = IERC20(lbtc);
        uint256 balanceBefore = token.balanceOf(address(this));

        token.safeTransferFrom(msg.sender, address(this), amount);
        ILBTC(lbtc).redeemForBtc(scriptPubkey, amount);

        if (token.balanceOf(address(this)) != balanceBefore) revert LeftoverBalance();
        return true;
    }
}
