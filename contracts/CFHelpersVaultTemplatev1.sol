// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CofundEIP712} from "./CofundEIP712.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/* ----------  External state interface  ----------
 * Subset of the frozen CFHelpersStatev1 surface (design doc §6) that the vault
 * actually calls. Struct layouts must match State v1 field-for-field or the
 * ABI decode of getUser / getPolicy silently mis-reads.
 */
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
    struct Policy {
        bool active;
        string title;
        string policyType;
        bytes32[] signerIds;
        uint256 threshold;
        Transaction transactionDetails;
        Transfer transferDetails;
        bool isTransaction;
    }

    function getUser(
        bytes32 clientId,
        string memory userId
    ) external view returns (User memory);

    function getUserIdByAddress(
        address userAddress,
        bytes32 clientId
    ) external view returns (string memory);

    function getPolicy(
        bytes32 clientId,
        string memory policyId
    ) external view returns (Policy memory);

    /// @dev ok=false,id=0 → address unmapped or user inactive;
    ///      ok=false,id=X → active user X who is not on this policy;
    ///      ok=true, id=X → active user X on this policy.
    function resolvePolicySigner(
        bytes32 clientId,
        string memory policyId,
        address signer
    ) external view returns (bool ok, bytes32 signerId);

    function setClientContractAuthID(
        bytes32 clientId,
        string memory authId
    ) external;

    function clientVaults(
        bytes32 clientId
    ) external view returns (address vaultAddress, string memory vaultTier);

    function subscriptionTierBps(
        string calldata tier
    ) external view returns (uint16);

    function cfFeeRecipientAddress() external view returns (address);

    function isCofundAdmin(address account) external view returns (bool);

    function helperContracts(
        string memory contractType
    ) external view returns (address);
}

interface IWrapper {
    function routerWrapper(
        string calldata name,
        bytes calldata instructions
    ) external returns (bool);
}

/* ----------  Vault template (v1)  ----------
 * No ERC-2771. Authorization is the EIP-712 signature set in calldata;
 * msg.sender is only an anti-griefing broadcaster gate.
 */
contract CFHelpersVaultTemplatev1 is CofundEIP712 {
    using SafeERC20 for IERC20;

    bytes32 public clientId;
    ICofundHelperState public state;
    bool private _initialized;
    address public immutable factory;
    address public immutable expectedState;

    /* ----------  EIP-712 types (design doc §4.2, frozen)  ---------- */

    bytes32 private constant TR_TYPEHASH =
        keccak256(
            "Transfer(string company,string policyId,string messageType,uint256 amount,address token,address recipient,string authId)"
        );

    // Primary type immediately followed by the referenced Allowance type.
    bytes32 private constant TX_TYPEHASH =
        keccak256(
            "Transaction(string company,string policyId,string messageType,address wrapper,string func,Allowance[] allowances,bytes32 instructionsHash,string authId)Allowance(address asset,uint256 amount)"
        );

    bytes32 private constant ALLOWANCE_TYPEHASH =
        keccak256("Allowance(address asset,uint256 amount)");

    error AlreadyInitialized();
    error InactivePolicy();
    error ThresholdNotMet();
    error InvalidType();
    error AmountExceedsPolicy();
    error InvalidPolicyType();
    error InvalidSignature();
    error InvalidSigner();
    error InvalidToken();
    error InvalidAmount();
    error InvalidCompany();
    error RecipientNotAllowed();
    error UnauthorizedCaller(string reason);

    /* ----------  Types  ---------- */
    struct Allowance {
        address asset;
        uint256 amount;
    }

    event TransactionExecuted(
        string indexed policyId,
        string messageType,
        string func,
        address wrapper,
        string authId
    );

    event TransferExecuted(
        string indexed policyId,
        string messageType,
        uint256 amount,
        address token,
        address recipient,
        string authId
    );

    constructor(address _expectedState) {
        factory = msg.sender;
        expectedState = _expectedState;
    }

    /// @dev §4.2 round 6: a clone's domain is `("Cofund", "1", chainId, State)`
    ///      -- the same one the helpers use. Read from `state`, set in
    ///      `initialize`, so it is the clone's own wiring rather than anything
    ///      cached on the implementation. `initialize` pins `_state` to
    ///      `expectedState`, so every clone of this template reports the same
    ///      address and no vault needs its own Ledger descriptor.
    function _eip712State() internal view override returns (address) {
        return address(state);
    }

    function initialize(bytes32 _clientId, address _state) external {
        if (msg.sender != factory)
            revert UnauthorizedCaller("caller is not factory");
        if (_initialized) revert AlreadyInitialized();
        if (_state != expectedState)
            revert UnauthorizedCaller("state is not expected");
        _initialized = true;
        clientId = _clientId;
        state = ICofundHelperState(_state);
    }

    /* ----------  Broadcaster gate (anti-griefing only)  ---------- */

    /// @dev Three broadcasters: the sponsor guard, recognized by its
    ///      registration as `helperContracts["sponsorGuard"]` and never by an
    ///      admin bit (§5 — the guard holds no privilege of its own); a Cofund
    ///      admin, for manual ops; or any active member of this client.
    ///      Authorization is the signature set, not this.
    function _requireBroadcaster() private view {
        if (msg.sender == state.helperContracts("sponsorGuard")) return;
        if (state.isCofundAdmin(msg.sender)) return;

        string memory userId = state.getUserIdByAddress(msg.sender, clientId);
        if (bytes(userId).length == 0)
            revert UnauthorizedCaller("caller not mapped to user");

        ICofundHelperState.User memory callerUser = state.getUser(
            clientId,
            userId
        );
        if (!callerUser.active) revert UnauthorizedCaller("user inactive");
    }

    function _requireCompany(string calldata company) private view {
        if (sha256(bytes(company)) != clientId) revert InvalidCompany();
    }

    /* ----------  EIP-712 hashing  ---------- */

    function _hashAllowances(
        Allowance[] calldata allowances
    ) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](allowances.length);
        for (uint256 i = 0; i < allowances.length; i++) {
            hashes[i] = keccak256(
                abi.encode(
                    ALLOWANCE_TYPEHASH,
                    allowances[i].asset,
                    allowances[i].amount
                )
            );
        }
        // Empty array hashes to keccak256("") — the EIP-712 encoding of an
        // empty dynamic array. NOT bytes32(0) as v0 did.
        return keccak256(abi.encodePacked(hashes));
    }

    /// @dev Reverts unless every signature recovers to a distinct, ascending
    ///      address that State resolves to an active user on this policy.
    ///      Rotation and removal therefore take effect with no policy re-issue.
    function _checkSigners(
        bytes32 digest,
        string calldata policyId,
        bytes[] calldata signatures
    ) private view {
        address prev = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (signer <= prev) revert InvalidSignature();
            prev = signer;

            (bool ok, ) = state.resolvePolicySigner(
                clientId,
                policyId,
                signer
            );
            if (!ok) revert InvalidSigner();
        }
    }

    /// @dev §3.4 — empty list is unrestricted, non-empty list is an allowlist.
    function _requireAllowedRecipient(
        address[] memory recipients,
        address recipient
    ) private pure {
        uint256 len = recipients.length;
        if (len == 0) return;
        for (uint256 i = 0; i < len; i++) {
            if (recipients[i] == recipient) return;
        }
        revert RecipientNotAllowed();
    }

    /* ----------  Entrypoints  ---------- */

    function executeTransfer(
        string calldata company,
        string calldata policyId,
        string calldata messageType,
        uint256 amount,
        address token,
        address recipient,
        string calldata authId,
        bytes[] calldata signatures
    ) external returns (bool) {
        _requireBroadcaster();
        _requireCompany(company);

        ICofundHelperState.Policy memory p = state.getPolicy(
            clientId,
            policyId
        );

        if (!p.active) revert InactivePolicy();
        if (p.isTransaction) revert InvalidType();
        if (amount > p.transferDetails.maxAmount) revert AmountExceedsPolicy();
        if (token != p.transferDetails.token) revert InvalidToken();
        if (keccak256(bytes(p.policyType)) != keccak256(bytes(messageType)))
            revert InvalidPolicyType();
        if (signatures.length < p.threshold) revert ThresholdNotMet();

        _requireAllowedRecipient(p.transferDetails.recipients, recipient);

        state.setClientContractAuthID(clientId, authId);

        _checkSigners(
            _hashTypedData(
                keccak256(
                    abi.encode(
                        TR_TYPEHASH,
                        keccak256(bytes(company)),
                        keccak256(bytes(policyId)),
                        keccak256(bytes(messageType)),
                        amount,
                        token,
                        recipient,
                        keccak256(bytes(authId))
                    )
                )
            ),
            policyId,
            signatures
        );

        // Fee on top of the principal, per the client's subscription tier.
        (, string memory tier) = state.clientVaults(clientId);
        uint16 feeBps = state.subscriptionTierBps(tier);

        if (feeBps != 0) {
            uint256 rawFee = amount * uint256(feeBps);
            uint256 fee = rawFee / 10_000;
            if (fee == 0 && rawFee > 0) {
                fee = 1;
            }
            require(
                IERC20(token).trySafeTransfer(
                    state.cfFeeRecipientAddress(),
                    fee
                ),
                "fee transfer failed"
            );
        }

        // Transfer principal
        require(
            IERC20(token).trySafeTransfer(recipient, amount),
            "ERC20 transfer failed"
        );

        emit TransferExecuted(
            policyId,
            messageType,
            amount,
            token,
            recipient,
            authId
        );
        return true;
    }

    function executeTransaction(
        string calldata company,
        string calldata policyId,
        string calldata messageType,
        address wrapper,
        string calldata func,
        bytes calldata instructions,
        Allowance[] calldata allowances,
        string calldata authId,
        bytes[] calldata signatures
    ) external returns (bool) {
        _requireBroadcaster();
        _requireCompany(company);

        ICofundHelperState.Policy memory p = state.getPolicy(
            clientId,
            policyId
        );

        if (!p.active) revert InactivePolicy();
        if (!p.isTransaction) revert InvalidType();
        if (wrapper != p.transactionDetails.wrapper) revert InvalidType();
        // `messageType` is in the digest the signers approved, so an
        // unchecked one lets an approval for a "Treasury_Management" call be
        // spent against a policy of some other type. `executeTransfer` has
        // always bound the two; this is the same check (§4.3, round 4).
        if (keccak256(bytes(p.policyType)) != keccak256(bytes(messageType)))
            revert InvalidPolicyType();
        if (signatures.length < p.threshold) revert ThresholdNotMet();

        state.setClientContractAuthID(clientId, authId);

        _checkSigners(
            _hashTypedData(
                keccak256(
                    abi.encode(
                        TX_TYPEHASH,
                        keccak256(bytes(company)),
                        keccak256(bytes(policyId)),
                        keccak256(bytes(messageType)),
                        wrapper,
                        keccak256(bytes(func)),
                        _hashAllowances(allowances),
                        keccak256(instructions),
                        keccak256(bytes(authId))
                    )
                )
            ),
            policyId,
            signatures
        );

        // approve exact amounts
        for (uint256 i = 0; i < allowances.length; i++) {
            Allowance calldata a = allowances[i];
            if (a.asset == address(0)) revert InvalidToken();
            if (a.amount == 0) revert InvalidAmount();
            IERC20(a.asset).forceApprove(wrapper, a.amount);
        }

        require(
            IWrapper(wrapper).routerWrapper(func, instructions),
            "wrapper call failed"
        );

        // reset approvals
        for (uint256 i = 0; i < allowances.length; i++) {
            IERC20(allowances[i].asset).forceApprove(wrapper, 0);
        }

        emit TransactionExecuted(policyId, messageType, func, wrapper, authId);
        return true;
    }
}
