// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CofundEIP712} from "./CofundEIP712.sol";

/// @notice The slice of `CFHelpersStatev1` (§6 of `docs/v1-relaunch-design.md`)
///         this helper calls. Declared locally so the package compiles and is
///         reviewable against the frozen surface rather than a concrete State.
/// @dev    `activatePolicy` / `deactivatePolicy` / `setClientContractAuthID`
///         are declared without return values on purpose: State either
///         succeeds or reverts, the boolean v0 returned was never read, and a
///         call site that declares no return tolerates a State that returns
///         one (extra returndata is ignored) as well as one that does not.
interface ICofundHelperState {
    struct User {
        address addr;
        string position;
        bool isAdmin;
        bool active;
    }

    struct Transaction {
        address wrapper;
        string func;
    }

    struct Transfer {
        uint256 maxAmount;
        address token;
        address[] recipients;
    }

    function activatePolicy(
        bytes32 clientId,
        string memory policyId,
        string memory policyType,
        string memory title,
        string[] memory signerIds,
        uint256 threshold,
        Transaction memory transactionDetails,
        Transfer memory transferDetails,
        bool isTransaction
    ) external;

    function deactivatePolicy(
        bytes32 clientId,
        string memory policyId
    ) external;

    function getUser(
        bytes32 clientId,
        string memory userId
    ) external view returns (User memory);

    function getUserIdByAddress(
        address userAddress,
        bytes32 clientId
    ) external view returns (string memory);

    function getActiveAdmins(bytes32 clientId) external view returns (uint256);

    function isSupportedType(
        string memory policyType
    ) external view returns (bool);

    function onboardingComplete(
        bytes32 clientId
    ) external view returns (bool);

    function setClientContractAuthID(
        bytes32 clientId,
        string memory authId
    ) external;
}

/// @title  CFHelpersPoliciesv1
/// @notice Policy activation and deactivation, authorized purely by EIP-712
///         signatures carried in calldata.
/// @dev    Differences from `CFHelpersPoliciesv0` (§1, §4 of the v1 design):
///
///         - **No ERC-2771, no `_enforceEOA`, no caller check at all.** The
///           admin consensus signatures *are* the authorization, so it does
///           not matter who broadcasts the transaction; in production that is
///           the sponsor smart account via `CFSponsorGuardv1.relay`. A caller
///           check would only have re-asserted what the signatures already
///           prove, while breaking the sponsor and any 7702-delegated admin.
///         - **Replay protection moved to State.** `usedAuthId` is gone;
///           `state.setClientContractAuthID(clientId, authId)` is the single
///           replay store (§4.1) and reverts `KeyExists` on reuse. Since
///           round 6 it is keyed by `(clientId, authId)` alone, so an id is
///           single-use per client across this helper, the users helper and
///           the client's vault -- which is what stops a signature spent here
///           from being replayed on a successor helper now that the EIP-712
///           domain names State rather than this contract (§4.2).
///         - **Activation is split in two** so the option group a signer is
///           not using never reaches their device, and every value they
///           approve is data rather than a hash (§4.2 tiers A+B):
///           `signerIds` and `recipients` are signed as arrays.
///         - **The supported-type gate is enforced here**, against State's
///           `isSupportedType` registry, rather than inside `activatePolicy`.
///           State stays a storage layer; the policy rules live in the helper
///           that owns them. The registry itself is still gov-managed in
///           State, so the set of legal types has one writer.
///         - **Policies reference identities.** `string[] signerIds` replaces
///           `address[] policySigners`; State validates them (§3.2) and the
///           vault resolves them at execution time, so rotation and removal
///           propagate without re-issuing a policy.
contract CFHelpersPoliciesv1 is CofundEIP712 {
    error InactiveUser();
    error InvalidAdmin();
    error InvalidThreshold();
    error SignersLength();
    error InvalidType();
    error InvalidPolicyType();
    error UnauthorizedCaller();
    error InvalidTitle();
    error SignerCountMismatch();
    error InvalidSignature();
    error InvalidSigner();
    error InvalidCompany();
    // Raised by State, not here (§3.2): policy signer ids are validated where
    // the user table lives. Kept in this ABI so a caller decoding a reverted
    // activation finds every error that activation can produce in one place.
    error InvalidPolicySigner();
    error DuplicatePolicySigner();

    // §4.2 — frozen type strings. Field order is display order on the device:
    // `company` first so an admin at two companies can tell them apart,
    // `authId` last so a descriptor can hide it.
    bytes32 private constant TRANSFER_POLICY_ACTIVATION_TYPEHASH =
        keccak256(
            "TransferPolicyActivation(string company,string policyId,string title,string policyType,string[] signerIds,uint256 threshold,address token,uint256 maxAmount,address[] recipients,string authId)"
        );

    bytes32 private constant TRANSACTION_POLICY_ACTIVATION_TYPEHASH =
        keccak256(
            "TransactionPolicyActivation(string company,string policyId,string title,string policyType,string[] signerIds,uint256 threshold,address wrapper,string func,string authId)"
        );

    bytes32 private constant POLICY_DEACTIVATION_TYPEHASH =
        keccak256(
            "PolicyDeactivation(string company,string policyId,string authId)"
        );

    struct TransferPolicyArgs {
        bytes32 clientId;
        string company;
        string policyId;
        string title;
        string policyType;
        string[] signerIds;
        uint256 threshold;
        address token;
        uint256 maxAmount;
        address[] recipients;
    }

    struct TransactionPolicyArgs {
        bytes32 clientId;
        string company;
        string policyId;
        string title;
        string policyType;
        string[] signerIds;
        uint256 threshold;
        address wrapper;
        string func;
    }

    ICofundHelperState public immutable stateContract;

    constructor(address _stateContract) {
        stateContract = ICofundHelperState(_stateContract);
    }

    /// @dev §4.2 round 6: one shared domain bound to State, not to this
    ///      helper. The typehashes are what keep a policy message apart from
    ///      a membership or vault message.
    function _eip712State() internal view override returns (address) {
        return address(stateContract);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                              ACTIVATION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Admin signatures an activation of `threshold` must carry.
    /// @dev    **The onboarding phase (§4.3).** While
    ///         `state.onboardingComplete(clientId)` is false the bar is one
    ///         signature, whatever the roster looks like. The product seats the
    ///         co-admins before the first policy exists: the founder invites
    ///         the team, and under the standing rule alone the client would be
    ///         deadlocked from the second admin's seat until that admin came
    ///         back to co-sign the first policy. So the founder is allowed to
    ///         stand the initial policies up by themselves.
    ///
    ///         The risk this trades for is real and unbounded in scope, not in
    ///         time: while the phase is open a single admin can stand up ANY
    ///         policy — including a 2-of-2 whose other signer is a member they
    ///         invited — and spend up to its cap. Nothing on chain closes the
    ///         window; the PLATFORM closes it, with
    ///         `CFHelpersUsersv1.completeOnboarding`, and must do so the moment
    ///         its onboarding flow finishes. A client left in the phase is a
    ///         client whose every admin is effectively unilateral.
    ///
    ///         **After the lock, the v0 rule, unchanged.** A single rogue admin
    ///         must not be able to stand a policy up on their own: with a member
    ///         they invited as the second signer, a 2-of-2 policy they activate
    ///         alone drains the vault. So every activation needs a second
    ///         admin's signature once the client has one. Threshold-1 policies
    ///         keep the stricter all-admins bar — one signer moves funds up to
    ///         `maxAmount` unilaterally. The bar is only meaningful because
    ///         State requires every policy signer id to be a distinct, active
    ///         client user (§3.2): a threshold-2 policy cannot be built from two
    ///         keys one person controls outside the client.
    function requiredPolicyActivationSignatures(
        bytes32 clientId,
        uint256 threshold
    ) public view returns (uint256) {
        if (!stateContract.onboardingComplete(clientId)) return 1;
        uint256 activeAdmins = stateContract.getActiveAdmins(clientId);
        if (activeAdmins <= 1) return 1;
        return threshold == 1 ? activeAdmins : 2;
    }

    /// @notice Activates a transfer policy once enough active admins have
    ///         signed `TransferPolicyActivation` over exactly these values.
    /// @dev    The digest commits to the signer set, the threshold, the token,
    ///         the cap and the recipient allowlist, so an approval cannot be
    ///         harvested from one policy and spent on another, nor replayed
    ///         against a weaker threshold or a wider allowlist. Ascending
    ///         recovered-address order is the uniqueness check.
    function activateTransferPolicy(
        TransferPolicyArgs calldata args,
        string calldata authId,
        bytes[] calldata signatures
    ) external returns (bool) {
        _requireCompany(args.company, args.clientId);
        if (!stateContract.isSupportedType(args.policyType))
            revert InvalidPolicyType();
        _validateActivationInputs(
            args.title,
            args.threshold,
            args.signerIds.length
        );
        if (args.token == address(0)) revert InvalidType();

        stateContract.setClientContractAuthID(args.clientId, authId);

        _requireActivationConsensus(
            args.clientId,
            args.threshold,
            _transferActivationDigest(args, authId),
            signatures
        );

        stateContract.activatePolicy(
            args.clientId,
            args.policyId,
            args.policyType,
            args.title,
            args.signerIds,
            args.threshold,
            ICofundHelperState.Transaction({wrapper: address(0), func: ""}),
            ICofundHelperState.Transfer({
                maxAmount: args.maxAmount,
                token: args.token,
                recipients: args.recipients
            }),
            false
        );
        return true;
    }

    /// @notice Activates a transaction policy once enough active admins have
    ///         signed `TransactionPolicyActivation` over exactly these values.
    function activateTransactionPolicy(
        TransactionPolicyArgs calldata args,
        string calldata authId,
        bytes[] calldata signatures
    ) external returns (bool) {
        _requireCompany(args.company, args.clientId);
        if (!stateContract.isSupportedType(args.policyType))
            revert InvalidPolicyType();
        _validateActivationInputs(
            args.title,
            args.threshold,
            args.signerIds.length
        );
        if (args.wrapper == address(0)) revert InvalidType();

        stateContract.setClientContractAuthID(args.clientId, authId);

        _requireActivationConsensus(
            args.clientId,
            args.threshold,
            _transactionActivationDigest(args, authId),
            signatures
        );

        stateContract.activatePolicy(
            args.clientId,
            args.policyId,
            args.policyType,
            args.title,
            args.signerIds,
            args.threshold,
            ICofundHelperState.Transaction({
                wrapper: args.wrapper,
                func: args.func
            }),
            ICofundHelperState.Transfer({
                maxAmount: 0,
                token: address(0),
                recipients: new address[](0)
            }),
            true
        );
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                             DEACTIVATION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Deactivates a policy on one active admin's signature over
    ///         `PolicyDeactivation`.
    /// @dev    v0 took the deactivation from whoever called it (via the
    ///         forwarder, whoever signed a `ForwardRequest` — a type that named
    ///         no policy). The signature now names the client and the policy,
    ///         so a relayer cannot pair an admin's approval with a different
    ///         policy. One admin still suffices: deactivation only removes
    ///         authority.
    function deactivatePolicy(
        bytes32 clientId,
        string calldata company,
        string calldata policyId,
        string calldata authId,
        bytes calldata adminSignature
    ) external returns (bool) {
        _requireCompany(company, clientId);

        stateContract.setClientContractAuthID(clientId, authId);

        bytes32 digest = _hashTypedData(
            keccak256(
                abi.encode(
                    POLICY_DEACTIVATION_TYPEHASH,
                    keccak256(bytes(company)),
                    keccak256(bytes(policyId)),
                    keccak256(bytes(authId))
                )
            )
        );

        address admin = _recover(digest, adminSignature);
        string memory adminUserId = stateContract.getUserIdByAddress(
            admin,
            clientId
        );
        if (bytes(adminUserId).length == 0) revert UnauthorizedCaller();
        ICofundHelperState.User memory adminUser = stateContract.getUser(
            clientId,
            adminUserId
        );
        if (!adminUser.active) revert InactiveUser();
        if (!adminUser.isAdmin) revert InvalidAdmin();

        stateContract.deactivatePolicy(clientId, policyId);
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                               INTERNALS
    // ═══════════════════════════════════════════════════════════════════

    /// @dev §4 step 1. `company` is what the signer reads on the device;
    ///      `clientId` is the storage key. sha256 is a precompile, so binding
    ///      one to the other costs almost nothing.
    function _requireCompany(
        string calldata company,
        bytes32 clientId
    ) private pure {
        if (sha256(bytes(company)) != clientId) revert InvalidCompany();
    }

    /// @dev Shape checks only. Signer ids and recipients are State's to
    ///      validate (§3.2, §3.4) — it owns the user table and the policy
    ///      record, and re-checking here would be a second, drifting copy.
    function _validateActivationInputs(
        string calldata title,
        uint256 threshold,
        uint256 signerCount
    ) private pure {
        if (bytes(title).length == 0) revert InvalidTitle();
        if (threshold == 0) revert InvalidThreshold();
        if (signerCount == 0) revert SignersLength();
        if (signerCount < threshold) revert SignersLength();
    }

    function _requireActivationConsensus(
        bytes32 clientId,
        uint256 threshold,
        bytes32 digest,
        bytes[] calldata signatures
    ) private view {
        uint256 required = requiredPolicyActivationSignatures(
            clientId,
            threshold
        );
        if (signatures.length < required) revert SignerCountMismatch();

        address prev = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = _recover(digest, signatures[i]);
            // Ascending order is the uniqueness check: `usersByAddress` is
            // injective per client, so distinct addresses are distinct people.
            if (signer <= prev) revert InvalidSignature();
            prev = signer;
            _requireSignerIsActiveAdmin(signer, clientId);
        }
    }

    function _requireSignerIsActiveAdmin(
        address account,
        bytes32 clientId
    ) private view {
        string memory userId = stateContract.getUserIdByAddress(
            account,
            clientId
        );
        if (bytes(userId).length == 0) revert InvalidSigner();
        ICofundHelperState.User memory user = stateContract.getUser(
            clientId,
            userId
        );
        if (!user.active || !user.isAdmin) revert InvalidSigner();
    }

    function _recover(
        bytes32 digest,
        bytes calldata signature
    ) private pure returns (address) {
        (address signer, ECDSA.RecoverError err, ) = ECDSA.tryRecover(
            digest,
            signature
        );
        if (err != ECDSA.RecoverError.NoError || signer == address(0)) {
            revert InvalidSignature();
        }
        return signer;
    }

    /// @dev Every member of the `encodeData` concatenation is 32 bytes wide, so
    ///      encoding the common prefix and the variant tail separately and
    ///      concatenating yields the same bytes as one `abi.encode` of all of
    ///      them. Split because the single expression does not fit the stack
    ///      even via IR.
    function _transferActivationDigest(
        TransferPolicyArgs calldata args,
        string calldata authId
    ) private view returns (bytes32) {
        bytes memory head = _activationHead(
            TRANSFER_POLICY_ACTIVATION_TYPEHASH,
            args.company,
            args.policyId,
            args.title,
            args.policyType
        );
        bytes memory tail = abi.encode(
            _hashStringArray(args.signerIds),
            args.threshold,
            args.token,
            args.maxAmount,
            _hashAddressArray(args.recipients),
            keccak256(bytes(authId))
        );
        return _hashTypedData(keccak256(bytes.concat(head, tail)));
    }

    function _transactionActivationDigest(
        TransactionPolicyArgs calldata args,
        string calldata authId
    ) private view returns (bytes32) {
        bytes memory head = _activationHead(
            TRANSACTION_POLICY_ACTIVATION_TYPEHASH,
            args.company,
            args.policyId,
            args.title,
            args.policyType
        );
        bytes memory tail = abi.encode(
            _hashStringArray(args.signerIds),
            args.threshold,
            args.wrapper,
            keccak256(bytes(args.func)),
            keccak256(bytes(authId))
        );
        return _hashTypedData(keccak256(bytes.concat(head, tail)));
    }

    /// @dev `typehash, company, policyId, title, policyType` — the prefix both
    ///      activation types share, in the frozen field order.
    function _activationHead(
        bytes32 typeHash,
        string calldata company,
        string calldata policyId,
        string calldata title,
        string calldata policyType
    ) private pure returns (bytes memory) {
        return
            abi.encode(
                typeHash,
                keccak256(bytes(company)),
                keccak256(bytes(policyId)),
                keccak256(bytes(title)),
                keccak256(bytes(policyType))
            );
    }

    /// @dev EIP-712 array encoding: the concatenated `encodeData` of the
    ///      elements, keccak256'd. For `string` that is `keccak256(bytes(s))`
    ///      per element.
    function _hashStringArray(
        string[] calldata arr
    ) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            hashes[i] = keccak256(bytes(arr[i]));
        }
        return keccak256(abi.encodePacked(hashes));
    }

    /// @dev `abi.encodePacked` pads each array element to 32 bytes, which is
    ///      exactly the EIP-712 encoding of an `address[]`.
    function _hashAddressArray(
        address[] calldata arr
    ) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(arr));
    }
}
