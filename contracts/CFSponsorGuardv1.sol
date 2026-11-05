// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICFHelpersStateSponsor {
    function helperContracts(string calldata) external view returns (address);

    function clientVaults(bytes32 clientId)
        external
        view
        returns (address vaultAddress, string memory vaultTier);
}

interface ICFVaultSponsor {
    function clientId() external view returns (bytes32);
}

/// @title CFSponsorGuardv1
/// @notice A relay with no privilege of its own. Registration as
///         `state.helperContracts["sponsorGuard"]` **is** the guard's role:
///         the vault's broadcaster gate and `Users.createClient` recognize
///         that address. It is never made a Cofund admin, so Gov's admin
///         surface is unreachable from it by construction, whatever ends up
///         registered where.
/// @dev `relay` is the only entrypoint. It routes to the users helper, the
///      policies helper or a known client vault, any selector, and nothing
///      else -- never to State, whose every write goes through gov or a
///      helper. The helpers and vaults authorize each mutating call from the
///      EIP-712 signatures in its own calldata, so the guard has no selector
///      whitelists and adds no authorization of its own. The blast radius of
///      a leaked sponsor key is sponsor gas plus whatever those signatures
///      already authorize -- nothing without them.
/// @dev Sponsor management is gated by the gov helper (read dynamically from
///      state.helperContracts("gov")), mirroring the existing gov <-> state
///      pattern used elsewhere in the system.
contract CFSponsorGuardv1 {
    error UnauthorizedCaller();
    error AlreadySponsor();
    error NotASponsor();
    error GuardPaused();
    error InvalidAddress();
    error InvalidCall();
    error CallNotAllowed();

    event SponsorAdded(address indexed sponsor, address indexed by);
    event SponsorRemoved(address indexed sponsor, address indexed by);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event DirectCallRelayed(address indexed sponsor, address indexed target, bytes4 indexed selector);

    ICFHelpersStateSponsor public immutable state;

    mapping(address => bool) public isAuthorizedSponsor;
    uint256 public authorizedSponsorCount;
    bool public paused;

    constructor(address _state) {
        if (_state == address(0)) revert InvalidAddress();
        state = ICFHelpersStateSponsor(_state);
    }

    modifier onlyGov() {
        if (msg.sender != state.helperContracts("gov")) revert UnauthorizedCaller();
        _;
    }

    function addSponsor(address sponsor) external onlyGov {
        if (sponsor == address(0)) revert InvalidAddress();
        if (isAuthorizedSponsor[sponsor]) revert AlreadySponsor();
        isAuthorizedSponsor[sponsor] = true;
        authorizedSponsorCount++;
        emit SponsorAdded(sponsor, msg.sender);
    }

    function removeSponsor(address sponsor) external onlyGov {
        if (!isAuthorizedSponsor[sponsor]) revert NotASponsor();
        isAuthorizedSponsor[sponsor] = false;
        authorizedSponsorCount--;
        emit SponsorRemoved(sponsor, msg.sender);
    }

    function pause() external onlyGov {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyGov {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Broadcast a sponsored call to `target` as the guard. Only an
    ///         authorized sponsor may call it, and only the users helper, the
    ///         policies helper and known client vaults are reachable -- any
    ///         selector on those, none anywhere else. This is how every signed
    ///         helper call and every `vault.executeTransfer` /
    ///         `vault.executeTransaction` reaches the chain.
    function relay(address target, bytes calldata data)
        external
        payable
        returns (bytes memory)
    {
        if (paused) revert GuardPaused();
        if (!isAuthorizedSponsor[msg.sender]) revert UnauthorizedCaller();
        if (data.length < 4) revert InvalidCall();

        if (!_isHelper(target) && !_isKnownVault(target)) revert CallNotAllowed();

        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        emit DirectCallRelayed(msg.sender, target, bytes4(data[:4]));
        return ret;
    }

    /// @dev True when `target` is the users or policies helper. `address(0)`
    ///      never matches, so an unregistered helper does not quietly turn a
    ///      zero target into an allowed one.
    function _isHelper(address target) internal view returns (bool) {
        if (target == address(0)) return false;
        return
            target == state.helperContracts("users") ||
            target == state.helperContracts("policies");
    }


    /// @dev A vault is known when the address it claims to serve, read back
    ///      through State's registry, is this very address. A plain staticcall
    ///      rather than try/catch: a target whose read-only fallback returns
    ///      data that is not 32 bytes would otherwise make the decode revert
    ///      opaquely instead of being refused with CallNotAllowed.
    function _isKnownVault(address target) internal view returns (bool) {
        if (target == address(0) || target.code.length == 0) return false;
        (bool ok, bytes memory ret) = target.staticcall(
            abi.encodeCall(ICFVaultSponsor.clientId, ())
        );
        if (!ok || ret.length != 32) return false;
        (address registered, ) = state.clientVaults(abi.decode(ret, (bytes32)));
        return registered == target;
    }
}
