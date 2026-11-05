// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @title  Eip712 -- the signer's half of the v1 stack, in one place.
///
/// @notice Everything a test needs to produce the signatures the v1 contracts
///         accept: the one domain separator (round 6 -- there used to be
///         three), the frozen §4.2 type strings, a `hashStruct` for each of
///         them, the `sha256` company hash, and `vm.sign` wrappers that emit
///         `(r, s, v)` in the layout OpenZeppelin's `ECDSA` expects, sorted
///         ascending by recovered address where the contracts require it.
///
/// @dev    Deliberately an independent re-derivation of the type strings rather
///         than a read of the contracts' own constants: copied verbatim from
///         `docs/v1-relaunch-design.md` §4.2, which is frozen and is what the
///         webapp's builders and the Ledger will render. A typo on either side
///         shows up as a failed recovery, which is the point -- reading the
///         constants off the contract under test would make the test agree with
///         whatever the contract happens to hash.
///
///         `domainSeparator` is built by hand rather than from `eip712Domain()`
///         for the same reason: ERC-5267 shape, `block.chainid`, the State
///         address as the verifying contract, and the name/version this
///         package expects.
library Eip712 {
    /// @dev Cheat code address, as `forge-std`'s `CommonBase` derives it:
    ///      `address(uint160(uint256(keccak256("hevm cheat code"))))`.
    Vm private constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // ═════════════════════════════════════════════════════════════════════
    //  Domains
    // ═════════════════════════════════════════════════════════════════════

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    /// @notice The single v1 domain: `("Cofund", "1", chainId, address(State))`
    ///         (§4.2, round 6).
    ///
    /// @dev    One function, not three. Every type in the stack is signed
    ///         under this domain whoever verifies it -- users helper, policies
    ///         helper, or any client's vault clone -- because the
    ///         `verifyingContract` is State's address rather than the
    ///         verifier's. Hand it `address(state)` and nothing else; passing
    ///         a helper or vault address is the mistake the negative tests in
    ///         each suite pin.
    ///
    ///         Four fields, no salt, no extensions; chain id read at call time.
    function domainSeparator(address state) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    keccak256(bytes("Cofund")),
                    keccak256(bytes("1")),
                    block.chainid,
                    state
                )
            );
    }

    /// @notice The `\x19\x01`-prefixed digest a key actually signs.
    function digest(bytes32 domainSep, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Type hashes -- §4.2, verbatim
    // ═════════════════════════════════════════════════════════════════════

    /// @dev Round 3 dropped `inviteHash`: there is no invite code and no
    ///      pending invite on chain any more (§1, §4.4). What the admin signs
    ///      is the seat itself -- identity, role, position -- bounded by
    ///      `expiresAt` and replay-protected by `authId`, and the member spends
    ///      it in one platform-relayed `addUser` alongside their own signature
    ///      over this very digest.
    bytes32 internal constant INVITE_USER_TYPEHASH =
        keccak256(
            "InviteUser(string company,string callerId,string userId,bool userIsAdmin,string userPosition,uint256 expiresAt,string authId)"
        );

    bytes32 internal constant REMOVE_USER_TYPEHASH =
        keccak256("RemoveUser(string company,string removedUserId,string authId)");

    bytes32 internal constant ROTATE_USER_TYPEHASH =
        keccak256(
            "RotateUser(string company,string userId,address newAddress,string authId)"
        );

    /// @dev Round 4. The client locks its own onboarding phase: one active
    ///      admin signs, and from that transaction on a policy activation
    ///      needs the standing consensus instead of a single signature. The
    ///      shortest message in the set -- there is nothing to approve beyond
    ///      "this company, once" -- and the shape a Ledger renders in two
    ///      fields.
    bytes32 internal constant COMPLETE_ONBOARDING_TYPEHASH =
        keccak256("CompleteOnboarding(string company,string authId)");

    bytes32 internal constant TRANSFER_POLICY_ACTIVATION_TYPEHASH =
        keccak256(
            "TransferPolicyActivation(string company,string policyId,string title,string policyType,string[] signerIds,uint256 threshold,address token,uint256 maxAmount,address[] recipients,string authId)"
        );

    bytes32 internal constant TRANSACTION_POLICY_ACTIVATION_TYPEHASH =
        keccak256(
            "TransactionPolicyActivation(string company,string policyId,string title,string policyType,string[] signerIds,uint256 threshold,address wrapper,string func,string authId)"
        );

    bytes32 internal constant POLICY_DEACTIVATION_TYPEHASH =
        keccak256("PolicyDeactivation(string company,string policyId,string authId)");

    bytes32 internal constant TRANSFER_TYPEHASH =
        keccak256(
            "Transfer(string company,string policyId,string messageType,uint256 amount,address token,address recipient,string authId)"
        );

    /// @dev A referenced struct type is appended to the primary type, sorted by
    ///      name -- here there is only `Allowance`.
    bytes32 internal constant TRANSACTION_TYPEHASH =
        keccak256(
            "Transaction(string company,string policyId,string messageType,address wrapper,string func,Allowance[] allowances,bytes32 instructionsHash,string authId)Allowance(address asset,uint256 amount)"
        );

    bytes32 internal constant ALLOWANCE_TYPEHASH =
        keccak256("Allowance(address asset,uint256 amount)");

    // ═════════════════════════════════════════════════════════════════════
    //  Messages
    // ═════════════════════════════════════════════════════════════════════

    struct InviteUser {
        string company;
        string callerId;
        string userId;
        bool userIsAdmin;
        string userPosition;
        uint256 expiresAt;
        string authId;
    }

    struct RemoveUser {
        string company;
        string removedUserId;
        string authId;
    }

    struct RotateUser {
        string company;
        string userId;
        address newAddress;
        string authId;
    }

    struct CompleteOnboarding {
        string company;
        string authId;
    }

    struct TransferPolicyActivation {
        string company;
        string policyId;
        string title;
        string policyType;
        string[] signerIds;
        uint256 threshold;
        address token;
        uint256 maxAmount;
        address[] recipients;
        string authId;
    }

    struct TransactionPolicyActivation {
        string company;
        string policyId;
        string title;
        string policyType;
        string[] signerIds;
        uint256 threshold;
        address wrapper;
        string func;
        string authId;
    }

    struct PolicyDeactivation {
        string company;
        string policyId;
        string authId;
    }

    struct Transfer {
        string company;
        string policyId;
        string messageType;
        uint256 amount;
        address token;
        address recipient;
        string authId;
    }

    struct Allowance {
        address asset;
        uint256 amount;
    }

    struct Transaction {
        string company;
        string policyId;
        string messageType;
        address wrapper;
        string func;
        Allowance[] allowances;
        bytes32 instructionsHash;
        string authId;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  hashStruct
    // ═════════════════════════════════════════════════════════════════════

    function hashStruct(InviteUser memory m) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    INVITE_USER_TYPEHASH,
                    keccak256(bytes(m.company)),
                    keccak256(bytes(m.callerId)),
                    keccak256(bytes(m.userId)),
                    m.userIsAdmin,
                    keccak256(bytes(m.userPosition)),
                    m.expiresAt,
                    keccak256(bytes(m.authId))
                )
            );
    }

    function hashStruct(RemoveUser memory m) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    REMOVE_USER_TYPEHASH,
                    keccak256(bytes(m.company)),
                    keccak256(bytes(m.removedUserId)),
                    keccak256(bytes(m.authId))
                )
            );
    }

    function hashStruct(RotateUser memory m) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    ROTATE_USER_TYPEHASH,
                    keccak256(bytes(m.company)),
                    keccak256(bytes(m.userId)),
                    m.newAddress,
                    keccak256(bytes(m.authId))
                )
            );
    }

    function hashStruct(CompleteOnboarding memory m) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    COMPLETE_ONBOARDING_TYPEHASH,
                    keccak256(bytes(m.company)),
                    keccak256(bytes(m.authId))
                )
            );
    }

    /// @dev Head and tail are encoded separately and concatenated: every member
    ///      of an `encodeData` concatenation is exactly 32 bytes wide, so the
    ///      bytes are identical to one `abi.encode` of all eleven -- which does
    ///      not fit the stack. `CFHelpersPoliciesv1` splits it the same way.
    function hashStruct(TransferPolicyActivation memory m) internal pure returns (bytes32) {
        bytes memory head = abi.encode(
            TRANSFER_POLICY_ACTIVATION_TYPEHASH,
            keccak256(bytes(m.company)),
            keccak256(bytes(m.policyId)),
            keccak256(bytes(m.title)),
            keccak256(bytes(m.policyType))
        );
        bytes memory tail = abi.encode(
            hashStringArray(m.signerIds),
            m.threshold,
            m.token,
            m.maxAmount,
            hashAddressArray(m.recipients),
            keccak256(bytes(m.authId))
        );
        return keccak256(bytes.concat(head, tail));
    }

    function hashStruct(TransactionPolicyActivation memory m) internal pure returns (bytes32) {
        bytes memory head = abi.encode(
            TRANSACTION_POLICY_ACTIVATION_TYPEHASH,
            keccak256(bytes(m.company)),
            keccak256(bytes(m.policyId)),
            keccak256(bytes(m.title)),
            keccak256(bytes(m.policyType))
        );
        bytes memory tail = abi.encode(
            hashStringArray(m.signerIds),
            m.threshold,
            m.wrapper,
            keccak256(bytes(m.func)),
            keccak256(bytes(m.authId))
        );
        return keccak256(bytes.concat(head, tail));
    }

    function hashStruct(PolicyDeactivation memory m) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    POLICY_DEACTIVATION_TYPEHASH,
                    keccak256(bytes(m.company)),
                    keccak256(bytes(m.policyId)),
                    keccak256(bytes(m.authId))
                )
            );
    }

    function hashStruct(Transfer memory m) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    TRANSFER_TYPEHASH,
                    keccak256(bytes(m.company)),
                    keccak256(bytes(m.policyId)),
                    keccak256(bytes(m.messageType)),
                    m.amount,
                    m.token,
                    m.recipient,
                    keccak256(bytes(m.authId))
                )
            );
    }

    function hashStruct(Allowance memory a) internal pure returns (bytes32) {
        return keccak256(abi.encode(ALLOWANCE_TYPEHASH, a.asset, a.amount));
    }

    function hashStruct(Transaction memory m) internal pure returns (bytes32) {
        bytes memory head = abi.encode(
            TRANSACTION_TYPEHASH,
            keccak256(bytes(m.company)),
            keccak256(bytes(m.policyId)),
            keccak256(bytes(m.messageType)),
            m.wrapper
        );
        bytes memory tail = abi.encode(
            keccak256(bytes(m.func)),
            hashAllowances(m.allowances),
            m.instructionsHash,
            keccak256(bytes(m.authId))
        );
        return keccak256(bytes.concat(head, tail));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Array encodings
    // ═════════════════════════════════════════════════════════════════════

    /// @dev EIP-712 encodes a dynamic array as the keccak of the concatenated
    ///      `encodeData` of its members; for `string` that member is
    ///      `keccak256(bytes(s))`. An empty array therefore hashes to
    ///      `keccak256("")`, not `bytes32(0)`.
    function hashStringArray(string[] memory arr) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            hashes[i] = keccak256(bytes(arr[i]));
        }
        return keccak256(abi.encodePacked(hashes));
    }

    /// @dev `abi.encodePacked` left-pads each address to 32 bytes, which is
    ///      exactly the EIP-712 member encoding of an `address[]`.
    function hashAddressArray(address[] memory arr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(arr));
    }

    function hashAllowances(Allowance[] memory arr) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            hashes[i] = hashStruct(arr[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Client identifier
    // ═════════════════════════════════════════════════════════════════════

    /// @notice The storage key a `string company` must hash to (§4.2). sha256,
    ///         not keccak -- it is a precompile, and it is what every
    ///         `_requireCompany` checks.
    function companyId(string memory company) internal pure returns (bytes32) {
        return sha256(bytes(company));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Signing
    // ═════════════════════════════════════════════════════════════════════

    /// @notice `(r, s, v)` -- the 65-byte layout `ECDSA.recover` expects.
    function sign(uint256 pk, bytes32 dgst) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, dgst);
        return abi.encodePacked(r, s, v);
    }

    /// @notice One signature per key, ordered ascending by recovered address.
    /// @dev Every multi-signature surface in the stack -- admin consensus in
    ///      Users and Policies, `_checkSigners` in the vault -- uses strictly
    ///      ascending recovered-address order as its uniqueness check, so a
    ///      caller that does not sort is rejected however valid the signatures.
    function sign(uint256[] memory pks, bytes32 dgst) internal pure returns (bytes[] memory sigs) {
        uint256[] memory sorted = sortByAddress(pks);
        sigs = new bytes[](sorted.length);
        for (uint256 i = 0; i < sorted.length; i++) {
            sigs[i] = sign(sorted[i], dgst);
        }
    }

    /// @notice One admin's signature over `CompleteOnboarding`, ready to pass
    ///         straight to `CFHelpersUsersv1.completeOnboarding`.
    /// @dev The whole message in one call, because this is the only v1
    ///      entrypoint whose authorization is a single bare `bytes` with no
    ///      companion array -- a call site that built the digest by hand would
    ///      be three lines of ceremony for two fields.
    function signCompleteOnboarding(
        uint256 pk,
        bytes32 usersDomainSep,
        string memory company,
        string memory authId
    ) internal pure returns (bytes memory) {
        return
            sign(
                pk,
                digest(
                    usersDomainSep,
                    hashStruct(CompleteOnboarding({company: company, authId: authId}))
                )
            );
    }

    /// @notice Insertion sort of private keys by the address each derives.
    function sortByAddress(uint256[] memory pks) internal pure returns (uint256[] memory) {
        for (uint256 i = 1; i < pks.length; i++) {
            uint256 key = pks[i];
            address keyAddr = vm.addr(key);
            uint256 j = i;
            while (j > 0 && vm.addr(pks[j - 1]) > keyAddr) {
                pks[j] = pks[j - 1];
                unchecked {
                    --j;
                }
            }
            pks[j] = key;
        }
        return pks;
    }

    // ── small builders, so call sites read as the message they build ──────

    function keys(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function keys(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function keys(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function one(bytes memory a) internal pure returns (bytes[] memory out) {
        out = new bytes[](1);
        out[0] = a;
    }

    function none() internal pure returns (bytes[] memory) {
        return new bytes[](0);
    }

    function ids(string memory a, string memory b, string memory c)
        internal
        pure
        returns (string[] memory out)
    {
        out = new string[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function addrs() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function addrs(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }
}
