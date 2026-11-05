// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICFHelpersVaultFactory {
    function createVault(bytes32 clientId) external returns (address);
}

contract CFHelpersStatev1 {
    // Error codes
    error ClientExists();
    error AddressExists();
    error KeyExists();
    error InactiveUser();
    error InvalidUser();
    error InvalidSetting();
    error InvalidPolicy();
    error InvalidHelper();
    error InvalidPolicySigner();
    error DuplicatePolicySigner();
    error InvalidRecipient();
    error InvalidClient();
    error InvalidAddress();
    error InvalidTier();
    error UnauthorizedCaller();
    error UserExists();
    error OnboardingAlreadyComplete();

    // Structs
    struct User {
        address addr;
        string position;
        bool isAdmin;
        bool active;
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

    struct Transaction {
        address wrapper;
        string func;
    }

    struct Transfer {
        uint256 maxAmount;
        address token;
        address[] recipients;
    }

    struct Vault {
        address vaultAddress;
        string vaultTier;
    }

    // Mappings
    mapping(string => address) public helperContracts;
    mapping(address => bool) public isCofundAdmin;
    uint256 public cofundAdminCount;
    mapping(string => bool) public isSupportedType;
    mapping(bytes32 => mapping(string => Policy)) public policies;
    // Membership set behind Policy.signerIds, so a signer lookup is O(1)
    mapping(bytes32 => mapping(string => mapping(bytes32 => bool))) private _isPolicySigner;
    mapping(bytes32 => mapping(string => User)) public users;
    mapping(address => mapping(bytes32 => string)) public usersByAddress;
    mapping(bytes32 => uint256) public activeAdmins;
    /// @notice The one replay store (§4.1). Keyed by `(clientId, authId)`
    ///         alone since round 6 -- not by the consuming contract -- so an
    ///         `authId` is single-use per client across the users helper, the
    ///         policies helper and the client's vault. A signature spent on
    ///         one helper can therefore never be replayed on its successor,
    ///         which is what lets the EIP-712 domain bind to State rather than
    ///         to the contract that happens to verify it (§4.2, §4.4).
    ///         `authId`s are UUIDs; collisions across consumers are not a
    ///         concern.
    mapping(bytes32 => mapping(string => bool)) private clientContractAuthID;
    mapping(bytes32 => Vault) public clientVaults;
    /// @notice Whether the platform has closed this client's onboarding phase.
    /// @dev A one-way flag, false for every new client. The policies helper
    ///      reads it: while it is false a single admin may activate a policy
    ///      (§4.3). State holds no time logic, so nothing here ever flips it
    ///      back or on its own.
    mapping(bytes32 => bool) public onboardingComplete;
    mapping(string => uint16) public subscriptionTierBps;
    mapping(string => bool) public subscriptionTierExists;

    // Variables
    address public cfFeeRecipientAddress;

    // Events
    event UserAdded(bytes32 indexed clientId, string userId, address addr);
    event UserRemoved(bytes32 indexed clientId, string userId, string removedUserId);
    event UserRotated(bytes32 indexed clientId, string userId, address newUserAddress);
    event PolicyActivated(bytes32 indexed clientId, string policyId);
    event PolicyDeactivated(bytes32 indexed clientId, string policyId);
    /// @dev The consuming contract's address is gone from this event with
    ///      round 6's re-keying: the store no longer records who spent an
    ///      `authId`, only that this client's is spent. `msg.sender` is still
    ///      on the transaction for anyone who wants it.
    event SetClientContractAuthID(
        bytes32 clientId,
        string authId,
        bool value
    );
    event NewClientCreated(bytes32 indexed clientId, string adminId, address founder);
    event OnboardingCompleted(bytes32 indexed clientId);

    constructor(address initialAdmin) {
        isCofundAdmin[initialAdmin] = true;
        cofundAdminCount = 1;
        isSupportedType["Contractor_Stipend"] = true;
        isSupportedType["Crypto_Onramp"] = true;
        isSupportedType["Business_Invoice"] = true;
        isSupportedType["Operational_Expense"] = true;
        isSupportedType["Treasury_Management"] = true;
        cfFeeRecipientAddress = initialAdmin;
        // Initialize subscription tiers
        subscriptionTierBps["FREE"] = 75;
        subscriptionTierExists["FREE"] = true;
        subscriptionTierBps["TEAM"] = 50;
        subscriptionTierExists["TEAM"] = true;
        subscriptionTierBps["BUSINESS_NEW"] = 25;
        subscriptionTierExists["BUSINESS_NEW"] = true;
        subscriptionTierBps["BUSINESS"] = 0;
        subscriptionTierExists["BUSINESS"] = true;
    }

    /// @notice Set gov helper contract address (bootstrap, once-only, callable by Cofund admin)
    /// @param govAddress The address of the gov helper contract
    function setGovHelperContract(address govAddress) external {
        // Check that caller is a Cofund Admin
        if (!isCofundAdmin[msg.sender]) revert UnauthorizedCaller();
        // Check that govAddress is not zero
        if (govAddress == address(0)) revert InvalidAddress();
        // Prevent overwriting - bootstrap is once-only (use gov.setHelperContract for updates)
        if (helperContracts["gov"] != address(0)) revert KeyExists();
        // Set gov helper
        helperContracts["gov"] = govAddress;
    }

    function setSupportedType(string memory policyType) external {
        // Check that caller is a Cofund Admin
        if (!isCofundAdmin[msg.sender]) revert UnauthorizedCaller();
        // Update supported type
        isSupportedType[policyType] = true;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      GOV HELPER STORAGE SETTERS
    // ═══════════════════════════════════════════════════════════════════
    // All validation logic lives in CFHelpersGov - these are pure storage setters

    modifier onlyGov() {
        if (msg.sender != helperContracts["gov"]) revert UnauthorizedCaller();
        _;
    }

    /// @notice Set Cofund admin (sponsor) status
    function setCofundAdmin(address admin, bool status) external onlyGov {
        isCofundAdmin[admin] = status;
    }

    /// @notice Increment Cofund admin count (only callable by gov helper)
    function incrementCofundAdminCount() external onlyGov {
        cofundAdminCount++;
    }

    /// @notice Decrement Cofund admin count (only callable by gov helper)
    function decrementCofundAdminCount() external onlyGov {
        cofundAdminCount--;
    }

    /// @notice Get Cofund admin count
    function getCofundAdminCount() external view returns (uint256) {
        return cofundAdminCount;
    }

    /// @notice Set helper contract address (only callable by gov helper)
    /// @param contractType The helper type key (e.g., "policies", "users", "vaults")
    /// @param contractAddress The helper contract address
    function setHelperContract(
        string memory contractType,
        address contractAddress
    ) external onlyGov {
        helperContracts[contractType] = contractAddress;
    }

    /// @notice Spends `authId` for `clientId`. The only replay store in the
    ///         stack (§4.1, §6).
    /// @dev    The caller allowlist is unchanged -- the users helper, the
    ///         policies helper, or this client's own vault -- but since round
    ///         6 the key is `(clientId, authId)` and nothing else. Whichever
    ///         of the three spends it, the other two see it spent: one
    ///         `authId`, one use, per client. That is the guarantee the
    ///         State-bound EIP-712 domain rests on (§4.2).
    function setClientContractAuthID(
        bytes32 clientId,
        string memory authId
    ) external {
        // Checks that caller is the active "users" or "policies" contract or a client vault
        if (
            msg.sender != helperContracts["users"] &&
            msg.sender != helperContracts["policies"] &&
            msg.sender != clientVaults[clientId].vaultAddress
        ) revert UnauthorizedCaller();
        // Replay protection: single-use per client, whichever contract spends it
        if (clientContractAuthID[clientId][authId]) revert KeyExists();
        emit SetClientContractAuthID(clientId, authId, true);
        clientContractAuthID[clientId][authId] = true;
    }

    /// @notice Whether `authId` has been spent for `clientId`.
    /// @dev    No `msg.sender` dependence: every caller reads the same answer
    ///         the three consumers write.
    function getClientContractAuthID(
        bytes32 clientId,
        string memory authId
    ) external view returns (bool) {
        return clientContractAuthID[clientId][authId];
    }

    // User Functions
    function addUser(
        bytes32 clientId,
        string memory userId,
        address addr,
        bool isAdmin,
        string memory position
    ) external returns (bool) {
        // Checks that caller is the active "users" contract
        if (msg.sender != helperContracts["users"]) revert UnauthorizedCaller();
        // Check that the address is not a null address
        if (addr == address(0)) revert InvalidAddress();
        // Check that user does not exist
        if (users[clientId][userId].addr != address(0)) revert UserExists();
        // Check that address is not already assigned to another user
        if (bytes(usersByAddress[addr][clientId]).length != 0) revert AddressExists();

        // Add new user
        users[clientId][userId] = User({
            addr: addr,
            position: position,
            isAdmin: isAdmin,
            active: true
        });

        usersByAddress[addr][clientId] = userId;

        if (isAdmin) {
            activeAdmins[clientId]++;
        }

        emit UserAdded(clientId, userId, addr);
        return true;
    }

    function removeUser(
        bytes32 clientId,
        string memory userId,
        string memory removedUserId
    ) external returns (bool) {
        // Check that caller is the active "users" contract
        if (msg.sender != helperContracts["users"]) revert UnauthorizedCaller();
        // Fetch calling user
        User storage removedUser = users[clientId][removedUserId];
        // Check that removed user is not a null addres
        if (removedUser.addr == address(0)) revert InvalidAddress();
        // Check that removed user is not already inactive
        if (!removedUser.active) revert InactiveUser();
        // Check that removed user is an admin, if so decrement active admins (unless it's the last admin)
        if (removedUser.isAdmin) {
            if (activeAdmins[clientId] <= 1) revert InvalidSetting();
            activeAdmins[clientId]--;
        }
        // Update user to inactive
        users[clientId][removedUserId] = User({
            addr: removedUser.addr,
            isAdmin: removedUser.isAdmin,
            position: removedUser.position,
            active: false
        });
        // Emit event
        emit UserRemoved(clientId, userId, removedUserId);
        return true;
    }

    function rotateUser(
        bytes32 clientId,
        string memory rotatedUserId,
        address newAddress
    ) external returns (bool) {
        // Check that caller is the active "users" contract
        if (msg.sender != helperContracts["users"]) revert UnauthorizedCaller();
        // Fetch user by clientId and userId
        User storage rotatedUser = users[clientId][rotatedUserId];
        // Check that rotated user is not a null address
        if (rotatedUser.addr == address(0)) revert InvalidUser();
        // Check that new address is not a null address
        if (newAddress == address(0)) revert InvalidAddress();
        // Check that rotated user is not already inactive
        if (!rotatedUser.active) revert InactiveUser();
        // Check that new address is not already assigned to another user
        if (bytes(usersByAddress[newAddress][clientId]).length != 0) revert AddressExists();
        // Delete old address from reverse mapping
        delete usersByAddress[rotatedUser.addr][clientId];
        // Add new address to reverse mapping
        usersByAddress[newAddress][clientId] = rotatedUserId;
        // Update user address
        rotatedUser.addr = newAddress;
        // Emit event
        emit UserRotated(clientId, rotatedUserId, newAddress);
        return true;
    }

    // Policy Functions
    // Activate Policy
    function activatePolicy(
        bytes32 clientId,
        string memory policyId,
        string memory policyType,
        string memory title,
        string[] memory signerIds,
        uint256 threshold,
        Transaction memory txDetails,
        Transfer memory trDetails,
        bool isTransaction
    ) external returns (bool) {
        // Check that caller is the active "policies" contract
        if (msg.sender != helperContracts["policies"])
            revert UnauthorizedCaller();
        // Check that policy does not exist
        if (bytes(policies[clientId][policyId].title).length != 0) revert InvalidPolicy();

        // Validate signer ids and record the membership set. A policyId can only be
        // activated once (title check above), so the set is empty on entry and a
        // hash already present is a duplicate id.
        bytes32[] memory signerIdHashes = new bytes32[](signerIds.length);
        for (uint256 i = 0; i < signerIds.length; i++) {
            // Check that the signer is a known, active user of this client
            User storage signer = users[clientId][signerIds[i]];
            if (signer.addr == address(0) || !signer.active) revert InvalidPolicySigner();
            // Check that the id is not repeated
            bytes32 signerIdHash = keccak256(bytes(signerIds[i]));
            if (_isPolicySigner[clientId][policyId][signerIdHash])
                revert DuplicatePolicySigner();
            _isPolicySigner[clientId][policyId][signerIdHash] = true;
            signerIdHashes[i] = signerIdHash;
        }

        // Check that a transfer allowlist cannot be silently disabled by a zero entry
        if (!isTransaction) {
            for (uint256 i = 0; i < trDetails.recipients.length; i++) {
                if (trDetails.recipients[i] == address(0)) revert InvalidRecipient();
            }
        }

        // Update policy
        policies[clientId][policyId] = Policy({
            active: true,
            title: title,
            policyType: policyType,
            signerIds: signerIdHashes,
            threshold: threshold,
            transactionDetails: txDetails,
            transferDetails: trDetails,
            isTransaction: isTransaction
        });

        emit PolicyActivated(clientId, policyId);
        return true;
    }

    // Deactivate Policy
    function deactivatePolicy(
        bytes32 clientId,
        string memory policyId
    ) external returns (bool) {
        if (msg.sender != helperContracts["policies"])
            revert UnauthorizedCaller();

        Policy storage policy = policies[clientId][policyId];
        if (!policy.active) revert InvalidPolicy();

        policy.active = false;

        emit PolicyDeactivated(clientId, policyId);
        return true;
    }

    /// @notice Resolve a recovered address to its identity on a policy
    /// @dev ok=false,id=0  address unmapped or user inactive
    ///      ok=false,id=X  active user X who is not on this policy
    ///      ok=true, id=X  active user X on this policy
    function resolvePolicySigner(
        bytes32 clientId,
        string calldata policyId,
        address signer
    ) external view returns (bool ok, bytes32 signerId) {
        // Reverse index tracks rotation, the active flag tracks removal
        string memory userId = usersByAddress[signer][clientId];
        if (bytes(userId).length == 0) return (false, bytes32(0));
        if (!users[clientId][userId].active) return (false, bytes32(0));
        signerId = keccak256(bytes(userId));
        ok = _isPolicySigner[clientId][policyId][signerId];
    }

    /// @notice Whether a hashed userId is on a policy (no liveness check)
    function isPolicySigner(
        bytes32 clientId,
        string calldata policyId,
        bytes32 signerId
    ) external view returns (bool) {
        return _isPolicySigner[clientId][policyId][signerId];
    }

    // Tier Functions
    function setFeeRecipientAddress(address newRecipient) external {
        // Check that caller is a Cofund Admin
        if (!isCofundAdmin[msg.sender]) revert UnauthorizedCaller();
        // Check that recipient is not a null address
        if (newRecipient == address(0)) revert InvalidAddress();
        // Update fee recipient address
        cfFeeRecipientAddress = newRecipient;
    }
    function setSubscriptionTier(uint16 feeBps, string memory tier) external {
        // Check that caller is a Cofund Admin
        if (!isCofundAdmin[msg.sender]) revert UnauthorizedCaller();
        // Check that tier is not empty
        if (bytes(tier).length == 0) revert InvalidTier();
        // Sanity check that fee BPS is not greater than 1000 (10%)
        if (feeBps > 1_000) revert InvalidSetting();
        // Update subscription tier BPS
        subscriptionTierBps[tier] = feeBps;
        subscriptionTierExists[tier] = true;
    }
    function setClientSubscriptionTier(bytes32 clientId, string memory newTier) external {
        // Check that caller is a Cofund Admin
        if (!isCofundAdmin[msg.sender]) revert UnauthorizedCaller();
        // Check that client vault exists
        if (clientVaults[clientId].vaultAddress == address(0)) revert InvalidClient();
        // Check that new tier exists
        if (!subscriptionTierExists[newTier]) revert InvalidTier();
        // Update client subscription tier
        clientVaults[clientId].vaultTier = newTier;
    }

    // Activate new client
    function newClient(
        bytes32 clientId,
        string memory adminId,
        address founder,
        string memory clientTier
    ) external returns (bool) {
        // Check that caller is the active "users" contract
        if (msg.sender != helperContracts["users"]) revert UnauthorizedCaller();

        // Check that client doesn't exist
        if (clientVaults[clientId].vaultAddress != address(0))
            revert ClientExists();

        // Check that client tier exists
        if (!subscriptionTierExists[clientTier]) revert InvalidTier();

        // Check that the founder is not a null address
        if (founder == address(0)) revert InvalidAddress();

        // Check that the founding admin does not already exist
        if (users[clientId][adminId].addr != address(0)) revert UserExists();
        if (bytes(usersByAddress[founder][clientId]).length != 0) revert AddressExists();

        // Create the founding admin user
        users[clientId][adminId] = User({
            addr: founder,
            position: "admin",
            isAdmin: true,
            active: true
        });

        usersByAddress[founder][clientId] = adminId;
        activeAdmins[clientId] = 1;

        // Create new vault for client
        address vaultFactory = helperContracts["vaults"];
        if (vaultFactory == address(0)) revert InvalidHelper();

        address vault = ICFHelpersVaultFactory(vaultFactory).createVault(
            clientId
        );
        clientVaults[clientId] = Vault({
            vaultAddress: vault,
            vaultTier: clientTier
        });

        emit NewClientCreated(clientId, adminId, founder);
        return true;
    }

    /// @notice Closes a client's onboarding phase, permanently.
    /// @dev Pure registry write: the users helper decides when the platform's
    ///      onboarding flow has finished, State only records that it did and
    ///      refuses to record it twice. There is no time logic here and no way
    ///      back -- `onboardingComplete` is one-way by construction (§6).
    function setOnboardingComplete(bytes32 clientId) external {
        // Check that caller is the active "users" contract
        if (msg.sender != helperContracts["users"]) revert UnauthorizedCaller();
        // Check that the client exists
        if (clientVaults[clientId].vaultAddress == address(0))
            revert InvalidClient();
        // Check that onboarding is not already closed
        if (onboardingComplete[clientId]) revert OnboardingAlreadyComplete();

        onboardingComplete[clientId] = true;

        emit OnboardingCompleted(clientId);
    }

    // View Functions
    function getUser(
        bytes32 clientId,
        string memory userId
    ) external view returns (User memory) {
        return users[clientId][userId];
    }

    function getPolicy(
        bytes32 clientId,
        string memory policyId
    ) external view returns (Policy memory) {
        return policies[clientId][policyId];
    }

    function getActiveAdmins(bytes32 clientId) external view returns (uint256) {
        return activeAdmins[clientId];
    }

    function getUserIdByAddress(
        address userAddress,
        bytes32 clientId
    ) external view returns (string memory) {
        return usersByAddress[userAddress][clientId];
    }
}
