// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CofundEIP712} from "./CofundEIP712.sol";

/// @dev Only the State surface this helper calls, exactly as §6 freezes it.
///      The whole invite subsystem is gone from State -- no `Invite`, no
///      `addUserInvite` / `completeUserInvite`, no `invites` -- because a seat
///      is now written in one call and nothing is ever pending on chain.
interface ICofundHelperState {
    struct User {
        address addr;
        string position;
        bool isAdmin;
        bool active;
    }

    function newClient(
        bytes32 clientId,
        string memory adminId,
        address founder,
        string memory clientTier
    ) external returns (bool);

    function addUser(
        bytes32 clientId,
        string memory userId,
        address addr,
        bool isAdmin,
        string memory position
    ) external returns (bool);

    function removeUser(
        bytes32 clientId,
        string memory actorId,
        string memory removedUserId
    ) external returns (bool);

    function rotateUser(
        bytes32 clientId,
        string memory userId,
        address newAddress
    ) external returns (bool);

    function onboardingComplete(
        bytes32 clientId
    ) external view returns (bool);

    function setOnboardingComplete(bytes32 clientId) external;

    function getUser(
        bytes32 clientId,
        string memory userId
    ) external view returns (User memory);

    function getUserIdByAddress(
        address userAddress,
        bytes32 clientId
    ) external view returns (string memory);

    function getActiveAdmins(bytes32 clientId) external view returns (uint256);

    function setClientContractAuthID(
        bytes32 clientId,
        string memory authId
    ) external;

    function helperContracts(
        string memory contractType
    ) external view returns (address);

    function isCofundAdmin(address account) external view returns (bool);
}

/// @title CFHelpersUsersv1 -- membership, authorized by signature alone.
/// @notice The forwarder is gone (§1). Nothing here is authorized by
///         `msg.sender`: every seat is bound by the signatures in calldata,
///         and the recovered EOA is the actor's identity (§0).
/// @dev    Onboarding is platform-relayed (§4.4). The admin signs the seat's
///         parameters once, before the member has a wallet at all, so they
///         never have to come back; the member then authenticates to the
///         platform, generates a key, and the platform relays both halves in
///         one transaction, which is why these calls must arrive through the
///         sponsor guard or a Cofund admin. Nothing is ever pending on chain:
///         there is no invite record, no invite code, and no window in which
///         an outsider has anything to claim.
///
///         Each entrypoint takes `bytes32 clientId` as the storage key and the
///         `string company` the signer actually saw on their device, and
///         refuses the pair unless `sha256(bytes(company)) == clientId` (§4.2).
///         The sha256 precompile makes that binding nearly free, and it is what
///         lets an admin of two companies tell which one they are signing for.
contract CFHelpersUsersv1 is CofundEIP712 {
    using ECDSA for bytes32;

    error UnauthorizedCaller();
    error InvalidParams();
    error InvalidCompany();
    error InviteExpired();
    error InactiveSigner();
    error InvalidSigner();
    error InvalidSignature();
    error ThresholdNotMet();

    /// @dev The furthest ahead an authorization may be set to expire. State
    ///      holds no time logic at all now (§6), so the whole window is the
    ///      helper's business rule (§1). The webapp picks the actual horizon
    ///      inside this ceiling; its UI currently offers 24 hours.
    uint256 public constant MAX_INVITE_LIFETIME = 30 days;

    /// @dev Field order is display order on a Ledger: `company` first so the
    ///      signer knows who they are acting for, `authId` last (§4.2). Frozen.
    ///      Both the admin authorizing the seat and the member accepting it
    ///      sign this one type -- the member sees the company, who added them,
    ///      their own id, role and position (§4.4).
    bytes32 public constant INVITE_TYPEHASH =
        keccak256(
            "InviteUser(string company,string callerId,string userId,bool userIsAdmin,string userPosition,uint256 expiresAt,string authId)"
        );
    bytes32 public constant REMOVE_TYPEHASH =
        keccak256("RemoveUser(string company,string removedUserId,string authId)");
    bytes32 public constant ROTATE_TYPEHASH =
        keccak256(
            "RotateUser(string company,string userId,address newAddress,string authId)"
        );
    /// @dev Two fields and nothing else: the company the admin is acting for
    ///      and the `authId` that makes the approval single-use. There is no
    ///      third thing to approve -- the lock takes no parameters and admits
    ///      no degrees -- so this is what a Ledger renders (§4.2).
    bytes32 public constant COMPLETE_ONBOARDING_TYPEHASH =
        keccak256("CompleteOnboarding(string company,string authId)");

    /// @dev The `InviteUser` payload plus the storage key it is aimed at. One
    ///      value so `addUser` keeps a flat, device-legible argument list
    ///      without spending eight stack slots on it.
    struct AddUserArgs {
        bytes32 clientId;
        string company;
        string callerId;
        string userId;
        bool isAdmin;
        string userPosition;
        uint256 expiresAt;
        string authId;
    }

    ICofundHelperState public immutable stateContract;

    constructor(address _stateContract) {
        stateContract = ICofundHelperState(_stateContract);
    }

    /// @dev §4.2 round 6: the domain binds to State, never to this helper, so
    ///      an unspent authorization survives a `setHelperContract("users", ...)`
    ///      swap and the single-use `authId` store is what stops its replay.
    function _eip712State() internal view override returns (address) {
        return address(stateContract);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                            MEMBERSHIP
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Onboards a client and registers its founding admin in one call.
    /// @dev There is no client yet and so no admin to authorize this -- the
    ///      caller must be the sponsor guard relaying for Cofund, or a Cofund
    ///      admin operating by hand (§4.4).
    ///
    ///      The founder still signs. They sign `InviteUser` over themselves --
    ///      `callerId == userId == adminId`, admin, position "admin" -- and the
    ///      recovered address must be `founder`, so a client cannot be created
    ///      around a key nobody holds. The founder onboards a wallet before
    ///      creating the company, so that key exists by the time we get here.
    function createClient(
        bytes32 clientId,
        string calldata company,
        string calldata adminId,
        address founder,
        string calldata clientTier,
        uint256 expiresAt,
        string calldata authId,
        bytes calldata founderSignature
    ) external returns (bool) {
        _requirePlatform();
        _requireCompany(clientId, company);
        _requireWindow(expiresAt);
        if (bytes(authId).length == 0) revert InvalidParams();
        if (founder == address(0)) revert InvalidParams();

        bytes32 digest = _inviteDigest(
            company,
            adminId,
            adminId,
            true,
            "admin",
            expiresAt,
            authId
        );
        if (_recover(digest, founderSignature) != founder)
            revert InvalidSignature();

        stateContract.setClientContractAuthID(clientId, authId);

        return stateContract.newClient(clientId, adminId, founder, clientTier);
    }

    /// @notice Closes the client's onboarding phase on one admin's signature.
    ///         Irreversible.
    /// @dev Until it lands, `CFHelpersPoliciesv1` lets ONE active admin
    ///      activate a policy on their own signature. That exists because the
    ///      product seats the co-admins before the first policy exists: the
    ///      founder invites the rest of the team, and if the standing rule
    ///      applied from the first block, the moment a second admin was seated
    ///      nobody could stand a policy up until that admin came back to
    ///      co-sign. The cost is that while the phase is open a single admin
    ///      can stand up ANY policy, including one whose other signers they
    ///      control -- so this should be called as soon as onboarding is done.
    ///
    ///      **Any active admin may lock, and the founder is one**, so the
    ///      client is never waiting on Cofund to secure itself. One signature
    ///      is the right bar in both directions: the permission being given up
    ///      is the signer's own, and a lone admin who cannot lock is a lone
    ///      admin stuck in the phase forever. It also only ever tightens the
    ///      rules, so a stolen key gains nothing by spending it.
    ///
    ///      **Not platform-gated**, unlike `createClient` / `addUser`: those
    ///      turn on the platform's authentication of a *person*, which the
    ///      contract cannot see, whereas an admin signing for their own client
    ///      is something the contract can check outright (§4.4's "the key" and
    ///      "authorization" without "the person"). So `msg.sender` authorizes
    ///      nothing here -- as in `removeUser` and `rotateUser`, the signature
    ///      is the whole authorization and anyone may broadcast it. The app
    ///      collects the signature at the end of its onboarding flow and
    ///      relays it like everything else.
    function completeOnboarding(
        bytes32 clientId,
        string calldata company,
        string calldata authId,
        bytes calldata adminSignature
    ) external returns (bool) {
        _requireCompany(clientId, company);
        if (bytes(authId).length == 0) revert InvalidParams();

        // The admin, resolved from their signature -- never from the sender.
        // Bound exactly as `addUser` binds its authorizing admin: a key this
        // client has never seen is `UnauthorizedCaller` rather than a signer
        // error, because it is not a bad signature, it is a stranger.
        address signer = _recover(
            _completeOnboardingDigest(company, authId),
            adminSignature
        );
        string memory signerId = stateContract.getUserIdByAddress(
            signer,
            clientId
        );
        if (bytes(signerId).length == 0) revert UnauthorizedCaller();

        ICofundHelperState.User memory admin = stateContract.getUser(
            clientId,
            signerId
        );
        if (!admin.active) revert InactiveSigner();
        if (!admin.isAdmin) revert InvalidSigner();

        // Single-use, on the same replay store as every other helper action.
        // State refuses an unknown client and a second lock besides.
        stateContract.setClientContractAuthID(clientId, authId);

        stateContract.setOnboardingComplete(clientId);

        return true;
    }

    /// @notice EIP-712 digest an admin signs to lock the onboarding phase.
    function completeOnboardingDigest(
        string calldata company,
        string calldata authId
    ) external view returns (bytes32) {
        return _completeOnboardingDigest(company, authId);
    }

    /// @notice Adds a member, authorized by an admin and accepted by the
    ///         member's own key, in one transaction.
    /// @dev Replaces v0's add / complete / batched trio and the invite code
    ///      entirely (§4.3). Three things bind the seat (§4.4):
    ///
    ///      1. the admin's signature over `InviteUser`, replay-protected by
    ///         `authId` and time-bounded by `expiresAt` -- plus co-signatures
    ///         when the seat is an admin seat;
    ///      2. the platform's authentication of `userId`, which the contract
    ///         cannot see and so turns into a rule: the call must arrive
    ///         through the sponsor guard or a Cofund admin, which also makes
    ///         `guard.pause` the onboarding kill switch;
    ///      3. the member's own signature over the same digest, so a relayer
    ///         bug cannot register an address whose key nobody holds.
    ///
    ///      The admin signs first and need not return; the member signs
    ///      whenever they finish onboarding, inside the window.
    function addUser(
        AddUserArgs calldata args,
        bytes calldata adminSignature,
        bytes[] calldata adminCoSignatures,
        address invitee,
        bytes calldata inviteeSignature
    ) external returns (bool) {
        _requirePlatform();
        _requireCompany(args.clientId, args.company);
        _requireWindow(args.expiresAt);
        if (bytes(args.authId).length == 0) revert InvalidParams();

        bytes32 digest = _inviteDigest(
            args.company,
            args.callerId,
            args.userId,
            args.isAdmin,
            args.userPosition,
            args.expiresAt,
            args.authId
        );

        // The authorizing admin, resolved from their signature -- never from
        // the sender, which is the platform.
        address admin = _recover(digest, adminSignature);
        string memory derived = stateContract.getUserIdByAddress(
            admin,
            args.clientId
        );
        if (bytes(derived).length == 0) revert UnauthorizedCaller();
        if (keccak256(bytes(derived)) != keccak256(bytes(args.callerId)))
            revert UnauthorizedCaller();

        ICofundHelperState.User memory adminUser = stateContract.getUser(
            args.clientId,
            args.callerId
        );
        if (!adminUser.active) revert InactiveSigner();
        if (!adminUser.isAdmin) revert InvalidSigner();

        // Replay protection on the admin's authId (reverts if already used).
        stateContract.setClientContractAuthID(args.clientId, args.authId);

        // Seating another admin takes admin consensus over this same digest --
        // all active admins but one, or a single signature while the onboarding
        // phase is open (`requiredAdminInviteSignatures`).
        if (args.isAdmin) {
            _requireAdminInviteConsensus(
                args.clientId,
                admin,
                digest,
                adminCoSignatures
            );
        }

        // The member's key, proving it is live and is the one being seated.
        if (invitee == address(0)) revert InvalidSignature();
        if (_recover(digest, inviteeSignature) != invitee)
            revert InvalidSignature();

        return
            stateContract.addUser(
                args.clientId,
                args.userId,
                invitee,
                args.isAdmin,
                args.userPosition
            );
    }

    /// @notice EIP-712 digest the authorizing admin -- and the member -- sign.
    function inviteDigest(
        string calldata company,
        string calldata callerId,
        string calldata userId,
        bool userIsAdmin,
        string calldata userPosition,
        uint256 expiresAt,
        string calldata authId
    ) external view returns (bytes32) {
        return
            _inviteDigest(
                company,
                callerId,
                userId,
                userIsAdmin,
                userPosition,
                expiresAt,
                authId
            );
    }

    /// @notice Admin signatures an admin seat must carry for `clientId`.
    /// @dev    **The onboarding phase (§4.3).** While
    ///         `state.onboardingComplete(clientId)` is false the bar is one
    ///         signature -- the inviting admin's own -- whatever the roster
    ///         looks like: during onboarding one admin seats the co-admins
    ///         without the ceremony. This widens nothing. The phase already
    ///         lets a single admin activate ANY policy alone
    ///         (`CFHelpersPoliciesv1.requiredPolicyActivationSignatures`), so
    ///         an admin who can already spend the vault by themselves gains no
    ///         new power by seating a co-admin by themselves; what the
    ///         ceremony would buy here is nothing the open phase has not
    ///         already spent. It buys the product the ordinary case: a founder
    ///         inviting the team one seat at a time, without each new admin
    ///         having to come back and co-sign the next. The phase is closed by
    ///         `completeOnboarding`, and the platform must close it the moment
    ///         its onboarding flow finishes.
    ///
    ///         **After the lock, the ceremony.** All active admins but one,
    ///         with a floor of one. The authorizing admin counts toward it via
    ///         their own signature, so a solo founder and a two-admin client
    ///         each need nothing beyond it, while a third admin makes one
    ///         co-signature mandatory.
    ///
    ///         The phase lowers the COUNT, never the checks: co-signatures
    ///         supplied while it is open are still recovered, still required to
    ///         be distinct, ascending and active admins of this client
    ///         (`_requireAdminInviteConsensus`).
    function requiredAdminInviteSignatures(
        bytes32 clientId
    ) public view returns (uint256) {
        if (!stateContract.onboardingComplete(clientId)) return 1;
        uint256 activeAdmins = stateContract.getActiveAdmins(clientId);
        return activeAdmins > 1 ? activeAdmins - 1 : 1;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                          REMOVE / ROTATE
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Removes a member on the consensus of the client's admins.
    /// @dev One active admin is enough for a plain member; removing an admin
    ///      takes two whenever the client has more than one admin left, so a
    ///      single compromised admin key cannot unseat the others (§4.3).
    ///      Signatures are ascending by recovered address -- the uniqueness
    ///      check used throughout the stack -- and the first signer's userId is
    ///      the `actorId` recorded in State's `UserRemoved` event.
    function removeUser(
        bytes32 clientId,
        string calldata company,
        string calldata removedUserId,
        string calldata authId,
        bytes[] calldata signatures
    ) external returns (bool) {
        _requireCompany(clientId, company);
        if (bytes(authId).length == 0) revert InvalidParams();

        uint256 required = 1;
        if (
            stateContract.getUser(clientId, removedUserId).isAdmin &&
            stateContract.getActiveAdmins(clientId) > 1
        ) {
            required = 2;
        }
        if (signatures.length < required) revert ThresholdNotMet();

        bytes32 digest = _hashTypedData(
            keccak256(
                abi.encode(
                    REMOVE_TYPEHASH,
                    keccak256(bytes(company)),
                    keccak256(bytes(removedUserId)),
                    keccak256(bytes(authId))
                )
            )
        );

        string memory actorId;
        address prev = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = _recover(digest, signatures[i]);
            if (signer <= prev) revert InvalidSignature();
            prev = signer;
            string memory signerId = _requireSignerIsActiveAdmin(
                clientId,
                signer
            );
            if (i == 0) actorId = signerId;
        }

        stateContract.setClientContractAuthID(clientId, authId);

        return stateContract.removeUser(clientId, actorId, removedUserId);
    }

    /// @notice Points a userId at a new key (§4.5).
    /// @dev The new key always signs, whichever path authorizes the rotation:
    ///      that proof of possession is what stops a typo or a wrong-device key
    ///      from bricking an account. On top of it, exactly one path:
    ///
    ///      - self: the CURRENT key signs the same digest. v0 let a self-rotate
    ///        through on nothing but being the caller, so whoever held the
    ///        current key could rotate the victim to an attacker address
    ///        without ever proving it; here the current key must sign the new
    ///        address it is handing over to.
    ///      - recovery (the member lost their key): no current-key signature,
    ///        and instead two distinct active admins when the client has more
    ///        than one, ascending by recovered address.
    ///
    ///      Because policies resolve signers through `usersByAddress`, the
    ///      rotation is live on every policy the moment it lands.
    function rotateUser(
        bytes32 clientId,
        string calldata company,
        string calldata userId,
        address newAddress,
        string calldata authId,
        bytes calldata currentKeySignature,
        bytes calldata newKeySignature,
        bytes[] calldata adminSignatures
    ) external returns (bool) {
        _requireCompany(clientId, company);
        if (bytes(authId).length == 0) revert InvalidParams();
        if (newAddress == address(0)) revert InvalidSignature();

        bytes32 digest = _hashTypedData(
            keccak256(
                abi.encode(
                    ROTATE_TYPEHASH,
                    keccak256(bytes(company)),
                    keccak256(bytes(userId)),
                    newAddress,
                    keccak256(bytes(authId))
                )
            )
        );

        // Proof of possession of the incoming key, on both paths.
        if (_recover(digest, newKeySignature) != newAddress)
            revert InvalidSignature();

        if (currentKeySignature.length != 0) {
            // Self path: the two authorizations are mutually exclusive, so a
            // caller cannot pad a weak one with the other.
            if (adminSignatures.length != 0) revert InvalidParams();

            ICofundHelperState.User memory user = stateContract.getUser(
                clientId,
                userId
            );
            if (!user.active) revert InactiveSigner();
            if (_recover(digest, currentKeySignature) != user.addr)
                revert InvalidSignature();
        } else {
            // Recovery path: admin consensus stands in for the lost key.
            uint256 required = stateContract.getActiveAdmins(clientId) > 1
                ? 2
                : 1;
            if (adminSignatures.length < required) revert ThresholdNotMet();

            address prev = address(0);
            for (uint256 i = 0; i < adminSignatures.length; i++) {
                address signer = _recover(digest, adminSignatures[i]);
                if (signer <= prev) revert InvalidSignature();
                prev = signer;
                _requireSignerIsActiveAdmin(clientId, signer);
            }
        }

        stateContract.setClientContractAuthID(clientId, authId);

        return stateContract.rotateUser(clientId, userId, newAddress);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                              INTERNALS
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Onboarding arrives from the platform, never from the public (§4.4).
    ///      The contract cannot tell who a `userId` belongs to, so it requires
    ///      the party that CAN -- the sponsor guard relaying an authenticated
    ///      session, or a Cofund admin doing it by hand. It also makes
    ///      `guard.pause` an onboarding kill switch.
    function _requirePlatform() private view {
        if (
            msg.sender != stateContract.helperContracts("sponsorGuard") &&
            !stateContract.isCofundAdmin(msg.sender)
        ) revert UnauthorizedCaller();
    }

    /// @dev The signer approved `company`; `clientId` is only the storage key
    ///      the relayer supplies. Refuse the pair unless they are the same
    ///      thing (§4.2).
    function _requireCompany(
        bytes32 clientId,
        string calldata company
    ) private pure {
        if (sha256(bytes(company)) != clientId) revert InvalidCompany();
    }

    /// @dev How long an authorization is good for. Both bounds are inclusive:
    ///      a seat may be taken in the same second it expires, and an admin may
    ///      authorize one exactly `MAX_INVITE_LIFETIME` ahead.
    function _requireWindow(uint256 expiresAt) private view {
        if (block.timestamp > expiresAt) revert InviteExpired();
        if (expiresAt > block.timestamp + MAX_INVITE_LIFETIME)
            revert InvalidParams();
    }

    /// @dev One recovery for the whole contract, so a malformed signature is
    ///      always `InvalidSignature` rather than an OZ error whose shape
    ///      depends on which byte is wrong.
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

    function _inviteDigest(
        string memory company,
        string memory callerId,
        string memory userId,
        bool userIsAdmin,
        string memory userPosition,
        uint256 expiresAt,
        string memory authId
    ) private view returns (bytes32) {
        return
            _hashTypedData(
                keccak256(
                    abi.encode(
                        INVITE_TYPEHASH,
                        keccak256(bytes(company)),
                        keccak256(bytes(callerId)),
                        keccak256(bytes(userId)),
                        userIsAdmin,
                        keccak256(bytes(userPosition)),
                        expiresAt,
                        keccak256(bytes(authId))
                    )
                )
            );
    }

    function _completeOnboardingDigest(
        string calldata company,
        string calldata authId
    ) private view returns (bytes32) {
        return
            _hashTypedData(
                keccak256(
                    abi.encode(
                        COMPLETE_ONBOARDING_TYPEHASH,
                        keccak256(bytes(company)),
                        keccak256(bytes(authId))
                    )
                )
            );
    }

    /// @dev Enforces the admin-seat consensus. Co-signers sign the SAME
    ///      `INVITE_TYPEHASH` digest the authorizing admin signs, so a
    ///      signature commits to the company, the member's id, position, admin
    ///      flag, expiry and authId -- it cannot be harvested for one seat and
    ///      spent on another. Ascending signer order is the uniqueness check;
    ///      `inviter` is seeded as the first signer so they can neither be
    ///      double-counted nor omitted.
    function _requireAdminInviteConsensus(
        bytes32 clientId,
        address inviter,
        bytes32 digest,
        bytes[] calldata coSignatures
    ) private view {
        uint256 required = requiredAdminInviteSignatures(clientId);
        address prev = inviter;
        for (uint256 i = 0; i < coSignatures.length; i++) {
            address signer = _recover(digest, coSignatures[i]);
            if (signer == inviter) revert InvalidSignature();
            if (i > 0 && signer <= prev) revert InvalidSignature();
            prev = signer;
            _requireSignerIsActiveAdmin(clientId, signer);
        }
        if (coSignatures.length + 1 < required) revert ThresholdNotMet();
    }

    /// @dev A signer must be a registered, active admin of this client.
    ///      Returns their userId so callers that need to name the actor do not
    ///      resolve the address twice.
    function _requireSignerIsActiveAdmin(
        bytes32 clientId,
        address account
    ) private view returns (string memory) {
        string memory userId = stateContract.getUserIdByAddress(
            account,
            clientId
        );
        if (bytes(userId).length == 0) revert InvalidSigner();
        ICofundHelperState.User memory user = stateContract.getUser(
            clientId,
            userId
        );
        if (!user.active) revert InactiveSigner();
        if (!user.isAdmin) revert InvalidSigner();
        return userId;
    }
}
