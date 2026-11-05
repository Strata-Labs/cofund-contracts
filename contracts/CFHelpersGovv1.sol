// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Interface for reading Cofund Admin state
interface ICFHelpersState {
    function isCofundAdmin(address) external view returns (bool);

    function cofundAdminCount() external view returns (uint256);
}

/// @notice Interface for writing Cofund Admin state
interface ICFHelpersStateGov is ICFHelpersState {
    function setCofundAdmin(address admin, bool status) external;

    function incrementCofundAdminCount() external;

    function decrementCofundAdminCount() external;

    function setHelperContract(
        string memory contractType,
        address contractAddress
    ) external;

    function helperContracts(string calldata) external view returns (address);
}

/// @notice Interface for the sponsor guard contract (see CFSponsorGuardv1.sol)
interface ICFSponsorGuard {
    function addSponsor(address) external;

    function removeSponsor(address) external;

    function pause() external;

    function unpause() external;
}

/// @title CFHelpersGovv1
/// @notice Governance helper for Cofund Admin (sponsor) management
/// @dev Supports add, remove, and rotate operations for sponsor keys
/// @dev This contract manages ONLY Cofund Admins (sponsors), NOT vault admins
/// @dev Called directly from a Ledger, never sponsored, so `onlyCofundAdmin`
///      on `msg.sender` is the whole authorization story. v0's ERC-2771 support
///      and its `_enforceEOA` (`code.length != 0`) gate are gone -- the gate is
///      what locked out a 7702-delegated admin key.
contract CFHelpersGovv1 {
    // Errors
    error UnauthorizedCaller();
    error InvalidAddress();
    error InvalidType();
    error AdminExists();
    error NotAdmin();
    error LastAdmin();
    error SelfRemoval();
    error SponsorGuardNotSet();

    // EVENTS
    event CofundAdminAdded(address indexed newAdmin, address indexed addedBy);
    event CofundAdminRemoved(address indexed admin, address indexed removedBy);
    event CofundAdminRotated(
        address indexed oldAdmin,
        address indexed newAdmin
    );
    event HelperContractSet(
        string contractType,
        address indexed contractAddress,
        address indexed setBy
    );
    event SponsorAdded(address indexed sponsor, address indexed by);
    event SponsorRemoved(address indexed sponsor, address indexed by);
    event SponsorGuardPaused(address indexed by);
    event SponsorGuardUnpaused(address indexed by);

    // STATE

    /// @notice State reference (pointer to CFHelpersStatev1)
    ICFHelpersStateGov public immutable stateContract;

    constructor(address _stateContract) {
        stateContract = ICFHelpersStateGov(_stateContract);
    }

    /// @notice Restricts to Cofund admin (sponsor)
    modifier onlyCofundAdmin() {
        if (!stateContract.isCofundAdmin(msg.sender))
            revert UnauthorizedCaller();
        _;
    }

    /// @notice Add a new Cofund admin (sponsor)
    /// @param newAdmin Address to grant Cofund admin privileges
    function addCofundAdmin(address newAdmin) external onlyCofundAdmin {
        // Validation
        if (newAdmin == address(0)) revert InvalidAddress();
        if (stateContract.isCofundAdmin(newAdmin)) revert AdminExists();

        // Update state
        stateContract.setCofundAdmin(newAdmin, true);
        stateContract.incrementCofundAdminCount();

        emit CofundAdminAdded(newAdmin, msg.sender);
    }

    /// @notice Remove an existing Cofund admin (sponsor)
    /// @param admin Address to revoke Cofund admin privileges
    /// @dev Cannot remove self, cannot remove last admin
    function removeCofundAdmin(address admin) external onlyCofundAdmin {
        // Validation
        if (admin == msg.sender) revert SelfRemoval();
        if (!stateContract.isCofundAdmin(admin)) revert NotAdmin();
        if (stateContract.cofundAdminCount() <= 1) revert LastAdmin();

        // Update state
        stateContract.setCofundAdmin(admin, false);
        stateContract.decrementCofundAdminCount();

        emit CofundAdminRemoved(admin, msg.sender);
    }

    /// @notice Rotate own admin key to a new address
    /// @param newAdmin New address to transfer admin privileges to
    /// @dev Caller's admin status is revoked, newAdmin gains admin status
    function rotateCofundAdmin(address newAdmin) external onlyCofundAdmin {
        address oldAdmin = msg.sender;

        // Validation
        if (newAdmin == address(0)) revert InvalidAddress();
        if (stateContract.isCofundAdmin(newAdmin)) revert AdminExists();

        // Update state: revoke old, grant new (count unchanged)
        stateContract.setCofundAdmin(oldAdmin, false);
        stateContract.setCofundAdmin(newAdmin, true);

        emit CofundAdminRotated(oldAdmin, newAdmin);
    }

    /// @notice Check if address is a Cofund admin (sponsor)
    function isAdmin(address addr) external view returns (bool) {
        return stateContract.isCofundAdmin(addr);
    }

    /// @notice Get total number of Cofund admins
    function adminCount() external view returns (uint256) {
        return stateContract.cofundAdminCount();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      HELPER CONTRACT MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Set helper contract address in state
    /// @param contractType The helper type key (e.g., "policies", "users", "vaults")
    /// @param contractAddress The helper contract address
    function setHelperContract(
        string memory contractType,
        address contractAddress
    ) external onlyCofundAdmin {
        // Validation
        if (bytes(contractType).length == 0) revert InvalidType();
        if (contractAddress == address(0)) revert InvalidAddress();

        // Update state
        stateContract.setHelperContract(contractType, contractAddress);

        emit HelperContractSet(contractType, contractAddress, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      SPONSOR GUARD MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════

    function _guard() private view returns (ICFSponsorGuard) {
        address a = stateContract.helperContracts("sponsorGuard");
        if (a == address(0)) revert SponsorGuardNotSet();
        return ICFSponsorGuard(a);
    }

    /// @notice Authorize a new sponsor EOA to relay meta-txs through the guard
    function addSponsor(address sponsor) external onlyCofundAdmin {
        _guard().addSponsor(sponsor);
        emit SponsorAdded(sponsor, msg.sender);
    }

    /// @notice Revoke a sponsor EOA's authorization to relay via the guard
    function removeSponsor(address sponsor) external onlyCofundAdmin {
        _guard().removeSponsor(sponsor);
        emit SponsorRemoved(sponsor, msg.sender);
    }

    /// @notice Emergency pause of all sponsored relaying through the guard
    function pauseSponsorGuard() external onlyCofundAdmin {
        _guard().pause();
        emit SponsorGuardPaused(msg.sender);
    }

    /// @notice Resume sponsored relaying through the guard
    function unpauseSponsorGuard() external onlyCofundAdmin {
        _guard().unpause();
        emit SponsorGuardUnpaused(msg.sender);
    }
}
