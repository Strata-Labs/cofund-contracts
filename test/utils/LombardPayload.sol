// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @title  LombardPayload -- Lombard's GMP encodings, rebuilt for tests.
///
/// @notice What the Lombard API hands a depositor (a mint payload plus the
///         notary proof) and what a redeem puts in the mailbox's `MessageSent`.
///         Re-derived from Lombard's `GMPUtils` and `Assets` libraries rather
///         than read off `MockLBTC`, so a test that agrees with the mock agrees
///         with mainnet; `test_payload_matchesARealMainnetMint` pins it
///         against a real payload.
library LombardPayload {
    Vm private constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // bytes4(keccak256("MessageV1(bytes32,uint256,bytes32,bytes32,bytes32,bytes)"))
    bytes4 internal constant GMP_V1_SELECTOR = 0xe288fb4a;
    // bytes4(keccak256("mint(bytes32,bytes32,uint256)"))
    bytes4 internal constant MINT_SELECTOR = 0x155b6b13;
    // bytes4(keccak256("redeem(bytes32,bytes32,bytes32,bytes,uint256)"))
    bytes4 internal constant REDEEM_REQUEST_SELECTOR = 0xaa3db85f;

    bytes32 internal constant BTC_STAKING_MODULE = bytes32(uint256(0x0089e3e4e7a699d6f131d893aeef7ee143706ac23a));
    bytes32 internal constant BITCOIN_CHAIN_ID = 0xff0000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f;
    bytes32 internal constant LEDGER_CHAIN_ID = 0x0387b25e8e61f2ce4838b04795b231f09ee73ffd391da018bef4bc5c4975897b;
    /// @dev Mainnet's inbound (ledger -> Ethereum) path, as real mint payloads carry it.
    bytes32 internal constant INBOUND_PATH = 0x67636e97dfe9e0a5f7c0ab17636a921dc777c6aa9d6665e810ce50d61feb6d12;
    /// @dev Mainnet's outbound (Ethereum -> ledger) path, as real redeems carry it.
    bytes32 internal constant OUTBOUND_PATH = 0xe088dec32ceec088c8dd4e2647656948b0a023cc623b13ef92f786a0ed7064b3;

    function b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @notice A deposit's mint payload: a GMP `MessageV1` from the staking
    ///         module to `router`, whose body releases `amount` of `token` to
    ///         `recipient`. On the mock, `router` and `token` are both the mock.
    function mint(uint256 nonce, address router, address token, address recipient, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            GMP_V1_SELECTOR,
            INBOUND_PATH,
            nonce,
            BTC_STAKING_MODULE,
            b32(router),
            bytes32(0),
            abi.encodeWithSelector(MINT_SELECTOR, b32(token), b32(recipient), amount)
        );
    }

    /// @notice The notary proof: `abi.encode(bytes[])` of one 64-byte `r || s`
    ///         over `sha256(rawPayload)`.
    function proof(uint256 notaryKey, bytes memory rawPayload) internal pure returns (bytes memory) {
        (, bytes32 r, bytes32 s) = vm.sign(notaryKey, sha256(rawPayload));
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s);
        return abi.encode(sigs);
    }

    /// @notice The payload a redeem emits in `MessageSent`.
    function redeem(
        uint256 nonce,
        address router,
        address token,
        address sender,
        bytes memory scriptPubkey,
        uint256 amountAfterFee
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            GMP_V1_SELECTOR,
            OUTBOUND_PATH,
            nonce,
            b32(router),
            BTC_STAKING_MODULE,
            bytes32(0),
            abi.encodeWithSelector(
                REDEEM_REQUEST_SELECTOR, BITCOIN_CHAIN_ID, b32(token), b32(sender), scriptPubkey, amountAfterFee
            )
        );
    }

    /// @notice The fields a webapp reads back out of a redeem's `MessageSent`
    ///         payload: GMP envelope first, then the redeem body.
    function decodeRedeem(bytes memory rawPayload)
        internal
        pure
        returns (
            uint256 nonce,
            bytes32 toChain,
            address token,
            address sender,
            bytes memory scriptPubkey,
            uint256 amountAfterFee
        )
    {
        bytes memory envelope = new bytes(rawPayload.length - 4);
        for (uint256 i = 0; i < envelope.length; i++) {
            envelope[i] = rawPayload[i + 4];
        }
        bytes memory body;
        (, nonce,,,, body) = abi.decode(envelope, (bytes32, uint256, bytes32, bytes32, bytes32, bytes));

        bytes memory args = new bytes(body.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = body[i + 4];
        }
        bytes32 tokenWord;
        bytes32 senderWord;
        (toChain, tokenWord, senderWord, scriptPubkey, amountAfterFee) =
            abi.decode(args, (bytes32, bytes32, bytes32, bytes, uint256));
        token = address(uint160(uint256(tokenWord)));
        sender = address(uint160(uint256(senderWord)));
    }
}
