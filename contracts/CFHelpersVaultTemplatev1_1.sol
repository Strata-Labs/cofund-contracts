// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {CFHelpersVaultTemplatev1, ICofundHelperState} from "./CFHelpersVaultTemplatev1.sol";

/* ----------  Vault template (v1.1)  ----------
 * v1 plus ERC-1271 for logins: plain text that one active admin of this
 * cofund signed (docs/erc1271/README.md). Nothing else is signed.
 */
contract CFHelpersVaultTemplatev1_1 is CFHelpersVaultTemplatev1 {
    bytes32 private constant LOGIN_TYPEHASH =
        keccak256("SignMessage(string company,string message,uint256 deadline)");

    constructor(address _expectedState) CFHelpersVaultTemplatev1(_expectedState) {}

    /// @notice ERC-1271. `signature` is
    ///         `abi.encode(string company, string message, uint256 deadline, bytes signature)`.
    /// @dev Answers exactly `0x1626ba7e` or `0xffffffff` and never reverts:
    ///      malformed bytes revert inside the self-call and answer no.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        try this.validLogin(hash, signature) returns (bool ok) {
            return ok ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
        } catch {
            return 0xffffffff;
        }
    }

    /// @dev External only so `isValidSignature` can catch a revert.
    function validLogin(bytes32 hash, bytes calldata signature) external view returns (bool) {
        (string memory company, string memory message, uint256 deadline, bytes memory sig) =
            abi.decode(signature, (string, string, uint256, bytes));
        bytes memory text = bytes(message);

        if (sha256(bytes(company)) != clientId) return false;

        // Plain text only: no 32-byte "message" (a hash in disguise), no control bytes.
        if (text.length == 0 || text.length == 32) return false;
        for (uint256 i; i < text.length; ++i) {
            bytes1 c = text[i];
            if ((c < 0x20 && c != 0x0a && c != 0x0d && c != 0x09) || c == 0x7f) return false;
        }

        // The verifier's hash is this text's personal_sign hash.
        if (hash != MessageHashUtils.toEthSignedMessageHash(text)) return false;
        if (deadline < block.timestamp || deadline > block.timestamp + 7 days) return false;

        // One active admin of this cofund signed the text itself.
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(
            _hashTypedData(
                keccak256(abi.encode(LOGIN_TYPEHASH, keccak256(bytes(company)), keccak256(text), deadline))
            ),
            sig
        );
        return err == ECDSA.RecoverError.NoError && _isActiveAdmin(signer);
    }

    /// @dev An unmapped address reads as the empty userId, which is never an admin.
    function _isActiveAdmin(address signer) private view returns (bool) {
        string memory userId = state.getUserIdByAddress(signer, clientId);
        if (bytes(userId).length == 0) return false;
        ICofundHelperState.User memory user = state.getUser(clientId, userId);
        return user.isAdmin && user.active;
    }
}
