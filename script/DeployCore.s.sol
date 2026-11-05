// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {CFHelpersGovv1} from "../contracts/CFHelpersGovv1.sol";
import {CFHelpersPoliciesv1} from "../contracts/CFHelpersPoliciesv1.sol";
import {CFHelpersUsersv1} from "../contracts/CFHelpersUsersv1.sol";
import {CFHelpersVaultFactoryv1} from "../contracts/CFHelpersVaultFactoryv1.sol";
import {CFSponsorGuardv1} from "../contracts/CFSponsorGuardv1.sol";

/// @title  DeployCore -- the whole v1 core, on any chain, in one transaction batch.
///
/// @notice Deploys and wires the six contracts that make up a v1 deployment
///         (`docs/v1-relaunch-design.md` §7): State, Gov, Policies, Users, the
///         vault factory (which deploys the vault template as its own
///         constructor's first act) and the sponsor guard. Replaces the
///         ignition modules (§9.1).
///
/// @dev    **Two inputs, and only two.**
///
///         - `admin` -- the Cofund admin. State's constructor grants it the
///           only privileged bit in the system and makes it the initial fee
///           recipient; Gov then answers to it and to nobody else. In `run`
///           this is the broadcasting key (a Ledger, in production), because
///           Gov is called directly from the device and is never sponsored
///           (§4.3).
///         - `sponsor` -- the webapp's ERC-4337 sponsor account, authorized on
///           the guard so it can pay gas for `relay` (§0, §5).
///
///         **One optional input, in `run` only.** `FEE_RECIPIENT` moves the
///         protocol fee off the deploying key. State's constructor seeds the
///         recipient to `admin`, which is right for a test chain and wrong for
///         mainnet: the admin is a Ledger that signs Gov calls, not a treasury.
///         Set it and the broadcaster's last act is `setFeeRecipientAddress`;
///         leave it unset and nothing extra is sent, so `deploy` on its own
///         behaves exactly as it always did.
///
///         **Chain-agnostic.** Nothing here reads a chain id, an RPC alias or a
///         deployed address: every v1 contract takes State's address and
///         nothing else, invite expiry is a signed unix timestamp rather than a
///         block count (§1), and the subscription tiers, policy types and fee
///         recipient are seeded by State's constructor. The same script is the
///         whole deployment on Ethereum, Base, Arbitrum or a fresh anvil.
///
///         **Protocol wrappers are NOT deployed here.** `AaveWrapper`,
///         `CompoundWrapper` and `RelayWrapper` bind to per-chain protocol
///         addresses, they are out of relaunch scope (§7), and a client reaches
///         them only through a transaction policy that names one. They get
///         their own per-chain script.
///
///         **What this script deliberately does not do** (§5): it does not make
///         the guard a Cofund admin and it whitelists no selectors. Those
///         concepts are gone. Registration as `helperContracts["sponsorGuard"]`
///         *is* the guard's role -- it is what the vault's broadcaster gate and
///         `Users.createClient` recognize -- and it carries no privilege.
///
///         Usage:
///             SPONSOR=0x... FEE_RECIPIENT=0x... \
///             forge script script/DeployCore.s.sol:DeployCore \
///                 --rpc-url <chain> --ledger --sender <admin> --broadcast
///
///         `deploy` is `public` and broadcast-free so the integration suite can
///         run the real wiring (`test/Relaunch.t.sol` inherits this contract and
///         calls it under `vm.startPrank(admin)`, which is what makes the script
///         itself part of what the acceptance test proves).
contract DeployCore is Script {
    /// @notice Every address a deployment produces, in wiring order.
    /// @dev `factory` is registered under the `"vaults"` helper key; the vault
    ///      template it deploys is reachable as `factory.template()` and is
    ///      never registered anywhere -- State's `clientVaults` is the only
    ///      vault registry (§1).
    struct Core {
        address state;
        address gov;
        address policies;
        address users;
        address factory;
        address guard;
    }

    /// @notice Deploys the core and wires it, as `msg.sender`.
    /// @dev The caller MUST be `admin`: State's constructor grants the Cofund
    ///      admin bit to `admin`, and every wiring call below is gated on that
    ///      bit -- `setGovHelperContract` directly, the rest through Gov's
    ///      `onlyCofundAdmin`. Under `vm.startBroadcast()` in `run` that caller
    ///      is the broadcasting key; in a test it is whoever `vm.startPrank`
    ///      names. Passing an `admin` that is not the caller reverts on the
    ///      first wiring call rather than deploying something half-owned.
    function deploy(address admin, address sponsor) public returns (Core memory core) {
        // ── deploy ────────────────────────────────────────────────────────
        // State first: everything else takes its address and nothing else, so
        // the graph is a star and the order below is the only valid one.
        CFHelpersStatev1 state = new CFHelpersStatev1(admin);
        CFHelpersGovv1 gov = new CFHelpersGovv1(address(state));
        CFHelpersPoliciesv1 policies = new CFHelpersPoliciesv1(address(state));
        CFHelpersUsersv1 users = new CFHelpersUsersv1(address(state));
        // The factory's constructor deploys the vault template it clones.
        CFHelpersVaultFactoryv1 factory = new CFHelpersVaultFactoryv1(address(state));
        CFSponsorGuardv1 guard = new CFSponsorGuardv1(address(state));

        // ── wire, as the Cofund admin ─────────────────────────────────────
        // Bootstrap is once-only and gated on the admin bit; afterwards every
        // registry write goes through Gov.
        state.setGovHelperContract(address(gov));

        gov.setHelperContract("policies", address(policies));
        gov.setHelperContract("users", address(users));
        gov.setHelperContract("vaults", address(factory));
        // The guard's registration IS its role (§5). No admin bit, no
        // selector whitelist -- neither exists any more.
        gov.setHelperContract("sponsorGuard", address(guard));

        // Gov reaches the guard through that same registration, so the
        // sponsor can only be added after it.
        gov.addSponsor(sponsor);

        core = Core({
            state: address(state),
            gov: address(gov),
            policies: address(policies),
            users: address(users),
            factory: address(factory),
            guard: address(guard)
        });
    }

    /// @notice Moves State's protocol fee recipient off the deploying admin.
    ///
    /// @dev    A no-op when `feeRecipient` is the zero address, which is what
    ///         an unset `FEE_RECIPIENT` reads as: nothing is sent and State
    ///         keeps the constructor's seeding (`admin`). Separate from
    ///         `deploy` on purpose -- `deploy`'s two-argument signature is what
    ///         `test/Relaunch.t.sol` builds its fixture on, and the fee
    ///         recipient is a production concern rather than part of the
    ///         wiring the acceptance suite exercises.
    ///
    ///         Like `deploy`, the caller MUST be the Cofund admin:
    ///         `setFeeRecipientAddress` is gated on the admin bit that State's
    ///         constructor granted. It reverts on the zero address itself, so
    ///         the guard above is the only thing that makes "unset" mean
    ///         "leave it alone" rather than "revert".
    function setFeeRecipient(address state, address feeRecipient) public {
        if (feeRecipient == address(0)) return;
        CFHelpersStatev1(state).setFeeRecipientAddress(feeRecipient);
    }

    /// @notice Broadcasting entrypoint. The key that signs is the Cofund admin.
    /// @dev Returns the `Core` it deployed so a caller that is not a terminal
    ///      -- `test/DeployCore.t.sol` -- can assert on it; `forge script`
    ///      ignores the return value and reads `_report`'s output instead.
    function run() external returns (Core memory core) {
        // Read both inputs before opening the broadcast so a missing or
        // malformed SPONSOR -- or a malformed FEE_RECIPIENT -- aborts with
        // nothing deployed. FEE_RECIPIENT is optional; unset reads as zero,
        // which `setFeeRecipient` treats as "leave State's seeding alone".
        address sponsor = vm.envAddress("SPONSOR");
        address feeRecipient = vm.envOr("FEE_RECIPIENT", address(0));

        vm.startBroadcast();
        // Under an open broadcast this is the broadcasting key -- the Ledger or
        // the --sender/--private-key account -- which is exactly the Cofund
        // admin the deployment is for.
        address admin = msg.sender;
        core = deploy(admin, sponsor);
        setFeeRecipient(core.state, feeRecipient);
        vm.stopBroadcast();

        // Read the recipient back rather than re-deriving it, so the report
        // states what the chain holds and not what the script intended.
        _report(admin, sponsor, CFHelpersStatev1(core.state).cfFeeRecipientAddress(), core);
    }

    /// @dev Human-readable lines for the terminal, then one JSON object the
    ///      operator pastes into the deployments record. Nothing is written to
    ///      disk: a script that writes files needs `fs_permissions`, and the
    ///      record is reviewed by a human before it is committed anyway.
    function _report(address admin, address sponsor, address feeRecipient, Core memory core) private view {
        console2.log("");
        console2.log("=== Cofund v1 core deployed ===");
        console2.log("  chainId                ", block.chainid);
        console2.log("  cofundAdmin            ", admin);
        console2.log("  sponsor                ", sponsor);
        console2.log("  feeRecipient           ", feeRecipient);
        console2.log("  CFHelpersStatev1       ", core.state);
        console2.log("  CFHelpersGovv1         ", core.gov);
        console2.log("  CFHelpersPoliciesv1    ", core.policies);
        console2.log("  CFHelpersUsersv1       ", core.users);
        console2.log("  CFHelpersVaultFactoryv1", core.factory);
        console2.log("  CFSponsorGuardv1       ", core.guard);
        console2.log("");
        console2.log("deployments record (one line):");
        console2.log(
            string.concat(
                '{"chainId":',
                vm.toString(block.chainid),
                ',"cofundAdmin":"',
                vm.toString(admin),
                '","sponsor":"',
                vm.toString(sponsor),
                '","feeRecipient":"',
                vm.toString(feeRecipient),
                '","state":"',
                vm.toString(core.state),
                '","gov":"',
                vm.toString(core.gov),
                '","policies":"',
                vm.toString(core.policies),
                '","users":"',
                vm.toString(core.users),
                '","vaults":"',
                vm.toString(core.factory),
                '","sponsorGuard":"',
                vm.toString(core.guard),
                '"}'
            )
        );
    }
}
