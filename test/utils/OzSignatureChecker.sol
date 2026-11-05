// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @title  OzSignatureChecker -- OpenZeppelin 5.4's `SignatureChecker.isValidSignatureNow`.
///
/// @notice The address overload and the ERC-1271 check it calls, verbatim from
///         `lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol`.
///         The library itself can't be imported here: it pulls in `Bytes.sol`,
///         whose `mcopy` doesn't compile for this repo's `evm_version = "paris"`.
library OzSignatureChecker {
    function isValidSignatureNow(address signer, bytes32 hash, bytes memory signature) internal view returns (bool) {
        if (signer.code.length == 0) {
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
            return err == ECDSA.RecoverError.NoError && recovered == signer;
        } else {
            return isValidERC1271SignatureNow(signer, hash, signature);
        }
    }

    function isValidERC1271SignatureNow(address signer, bytes32 hash, bytes memory signature)
        internal
        view
        returns (bool)
    {
        (bool success, bytes memory result) =
            signer.staticcall(abi.encodeCall(IERC1271.isValidSignature, (hash, signature)));
        return (success && result.length >= 32
            && abi.decode(result, (bytes32)) == bytes32(IERC1271.isValidSignature.selector));
    }
}
