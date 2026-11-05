// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title  CofundEIP712 -- the one EIP-712 domain the whole v1 stack signs under.
///
/// @notice `("Cofund", "1", block.chainid, address(State))` (§4.2, round 6).
///         Every one of the ten frozen types is signed under this domain,
///         whichever contract verifies it: the users helper, the policies
///         helper, and every client's vault clone.
///
/// @dev    The `verifyingContract` is deliberately **not** `address(this)`.
///         State is the one per-chain address that never moves, so Ledger
///         clear signing needs one descriptor file and one registration per
///         chain, forever -- vault clones need nothing per vault, and a helper
///         swap does not orphan an unspent authorization. Nothing is lost by
///         sharing the address: the typehashes already keep every message
///         apart, and replay isolation comes from the struct, not the domain
///         (`company` -> `clientId`, single-use `authId` keyed per client,
///         per-client `policyId`).
///
///         This is why OpenZeppelin's `EIP712` is not used here. That base
///         caches a separator over `address(this)` at construction and has no
///         seam for a different verifying contract; a vault clone would also
///         inherit the implementation's cached value. The three functions
///         below are the whole of what the stack needs.
abstract contract CofundEIP712 {
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    /// @dev `keccak256("Cofund")` / `keccak256("1")`, folded at compile time.
    bytes32 private constant _NAME_HASH = keccak256("Cofund");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    string private constant _NAME = "Cofund";
    string private constant _VERSION = "1";

    /// @dev The State contract this instance binds its domain to. Implemented
    ///      by each signing contract against whatever holds that address --
    ///      an immutable for the helpers, initializer-set storage for a vault
    ///      clone. Never cached here: a clone's domain must follow the state
    ///      it was initialized with, not the implementation's.
    function _eip712State() internal view virtual returns (address);

    /// @dev Recomputed per call rather than cached. `block.chainid` is read
    ///      live, so a fork keeps working, and the clone case rules out a
    ///      construction-time cache anyway.
    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _DOMAIN_TYPEHASH,
                    _NAME_HASH,
                    _VERSION_HASH,
                    block.chainid,
                    _eip712State()
                )
            );
    }

    /// @notice The `\x19\x01`-prefixed digest a key actually signs.
    function _hashTypedData(
        bytes32 structHash
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
            );
    }

    /// @notice ERC-5267. Fields `0x0f` -- name, version, chainId,
    ///         verifyingContract -- no salt, no extensions.
    function eip712Domain()
        external
        view
        virtual
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (
            hex"0f",
            _NAME,
            _VERSION,
            block.chainid,
            _eip712State(),
            bytes32(0),
            new uint256[](0)
        );
    }
}
