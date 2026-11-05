// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";

import {DeployCore} from "./DeployCore.s.sol";

import {CFHelpersStatev1} from "../contracts/CFHelpersStatev1.sol";
import {CFHelpersGovv1} from "../contracts/CFHelpersGovv1.sol";
import {CFHelpersVaultFactoryv1} from "../contracts/CFHelpersVaultFactoryv1.sol";
import {CFSponsorGuardv1} from "../contracts/CFSponsorGuardv1.sol";

import {MockToken} from "../contracts/MockToken.sol";
import {MockDeFi} from "../contracts/MockDeFi.sol";
import {MockWrapper} from "../contracts/MockWrapper.sol";
import {MockUSDC} from "../contracts/MockUSDC.sol";
import {WETH9} from "../contracts/WETH9.sol";
import {MockStockSwapV4, MockV4Quoter} from "../contracts/MockStockSwapV4.sol";
import {RelayWrapper} from "../contracts/RelayWrapper.sol";
import {MockLBTC} from "../contracts/MockLBTC.sol";
import {LombardWrapper} from "../contracts/LombardWrapper.sol";
import {CFHelpersVaultFactoryv1_1} from "../contracts/CFHelpersVaultFactoryv1_1.sol";

/// @title  DeployE2E -- the whole webapp e2e chain, on a fresh anvil, in two passes.
///
/// @notice Replaces the seven Hardhat steps the webapp's `hardhat-deploy`
///         compose service used to run. Mapping, old step -> new home:
///
///         | # | old step                                   | here |
///         |---|--------------------------------------------|------|
///         | 1 | `ignition deploy cofund-vault.eth.ts`      | `deployAll()` -- `DeployCore.deploy` #1 ("ethereum") |
///         | 2 | `ignition deploy mock-wrapper.ts`          | `deployAll()` -- MockToken / MockDeFi / MockWrapper |
///         | 3 | `scripts/seed-localhost-weth.ts`           | `deployAll()` deploys WETH9; `e2e-deploy.sh` aliases it |
///         | 4 | `scripts/seed-localhost-usdc.ts`          | `deployAll()` deploys MockUSDC; shell aliases; `seedAndSponsor()` mints |
///         | 5 | `ignition deploy cofund-vault.robinhood.ts`| `deployAll()` -- `DeployCore.deploy` #2 ("robinhood") |
///         | 6 | `scripts/seed-localhost-robinhood.ts`     | `deployAll()` deploys the swap mocks; shell aliases; `seedAndSponsor()` mints |
///         | 7 | `scripts/authorize-extra-sponsors.ts`     | `seedAndSponsor()`, LAST -- see the ordering note below |
///
/// @dev    **Two passes, because a forge script cannot `setCode` on a live
///         node.** Steps 3, 4 and 6 aliased mainnet token addresses onto mock
///         runtime code with `hardhat_setCode`. `vm.etch` is simulation-only
///         and never reaches a `--broadcast` target, so the aliasing lives in
///         `script/e2e-deploy.sh` as `cast rpc anvil_setCode`. Everything that
///         must happen *after* the aliases exist -- minting reserves into the
///         aliased addresses -- is therefore a second broadcast:
///
///             deployAll()  ->  shell: anvil_setCode x20  ->  seedAndSponsor()
///
///         **Three stacks, one chain, one deployer.** The old modules deployed
///         two fully independent cores on the single localhost node, mirroring
///         production's one-state-per-chain topology; the webapp's Robinhood
///         specs drive the second one, and a third, Base, closes the run.
///         All three are deployed here from the same key in one broadcast, so
///         every address is a pure function of the deployer's nonce on a fresh
///         anvil -- deterministic across runs, which is what the webapp's
///         baked-in `NEXT_PUBLIC_*_STATE_ADDRESS` values require.
///
///         **Sponsors go LAST, and that is load-bearing.** `authorize-extra-sponsors.ts`
///         ran as a post-deploy step rather than inside the ignition modules
///         because extra deployer transactions consume nonces before the later
///         modules deploy, shifting their CREATE addresses. The same reasoning
///         applies here, so the pool `addSponsor` calls are the last thing
///         `seedAndSponsor()` does, after every CREATE and every mint.
///
///         **`--sig` is mandatory.** This contract inherits `DeployCore`, whose
///         `run()` is not `virtual` and therefore cannot be overridden. Running
///         this file without `--sig` would execute `DeployCore.run()` and
///         deploy a single bare core. `script/e2e-deploy.sh` always passes
///         `--sig`; drive it through the shell script rather than by hand.
contract DeployE2E is DeployCore {
    /* ─────────────────────── aliased mainnet addresses ─────────────────────── */
    // Canonical addresses the webapp hard-codes with no devnet override. The
    // e2e chain is UNFORKED, so none of them exist until the shell aliases mock
    // runtime code onto them.

    /// @dev `seed-localhost-weth.ts`.
    address internal constant CANONICAL_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @dev `seed-localhost-usdc.ts`. Also the "operate with stables" token the
    ///      Robinhood founders track deposits on, which is this same node.
    address internal constant CANONICAL_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant CANONICAL_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    /// @dev Binance hot wallet -- the holder the webapp e2e impersonates for USDT.
    address internal constant USDT_KNOWN_HOLDER = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    /// @dev `seed-localhost-robinhood.ts`, mirroring `stock-pools.ts`.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant STOCK_SWAP_WRAPPER = 0xf21C3C4Cb339bA038c0B374b55F47Fa22ce4d419;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;

    /// @dev Raw USDT pre-minted to the impersonated holder (1e12, 6 decimals).
    uint256 internal constant USDT_HOLDER_BALANCE = 1_000_000_000_000;
    /// @dev MockLBTC's notary: a published test key, so the webapp e2e can sign
    ///      mint proofs. `e2e-deploy.sh` writes it to the JSON as
    ///      `lombard.notaryKey`. Test chain only.
    uint256 internal constant LOMBARD_NOTARY_KEY = uint256(keccak256("cofund.e2e.lombard.notary"));
    /// @dev Where MockLBTC mints the redeem fee; nobody holds its key.
    address internal constant LOMBARD_TREASURY = address(uint160(uint256(keccak256("cofund.e2e.lombard.treasury"))));

    /// @dev Per-stock reserve the swap wrapper pays buys out of.
    uint256 internal constant SHARE_RESERVE = 1_000_000 * 10 ** 18;
    /// @dev USDG reserve the swap wrapper pays sells out of.
    uint256 internal constant USDG_RESERVE = 1_000_000_000 * 10 ** 6;

    /// @notice The fourteen tokenized stocks, in `stock-pools.ts` order.
    /// @dev Symbols are carried alongside so the address JSON the shell prints
    ///      is readable; the webapp keys its pools by symbol.
    function _stockSymbols() internal pure returns (string[14] memory s) {
        s = [
            string("AAPL"),
            "NVDA",
            "MSFT",
            "TSLA",
            "SPY",
            "AMZN",
            "GOOGL",
            "META",
            "AMD",
            "PLTR",
            "ORCL",
            "MU",
            "SNDK",
            "SPCX"
        ];
    }

    function _stockAddresses() internal pure returns (address[14] memory a) {
        a = [
            0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, // AAPL
            0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, // NVDA
            0xe93237C50D904957Cf27E7B1133b510C669c2e74, // MSFT
            0x322F0929c4625eD5bAd873c95208D54E1c003b2d, // TSLA
            0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, // SPY
            0x12f190a9F9d7D37a250758b26824B97CE941bF54, // AMZN
            0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, // GOOGL
            0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, // META
            0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, // AMD
            0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, // PLTR
            0xb0992820E760d836549ba69BC7598b4af75dEE03, // ORCL
            0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, // MU
            0xB90A19fF0Af67f7779afF50A882A9CfF42446400, // SNDK
            0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa // SPCX
        ];
    }

    /* ───────────────────────────── pass 1 ───────────────────────────── */

    /// @notice Deploys the three cores and every mock, in one broadcast.
    /// @dev Emits `E2E_ADDR <key> <address>` lines; `e2e-deploy.sh` parses them
    ///      into the address JSON and into the `cast rpc anvil_setCode` calls.
    ///      Nothing is written to disk -- that would need `fs_permissions`, and
    ///      `DeployCore` already established stdout as the reporting channel.
    function deployAll() external {
        // Read before the broadcast opens so a malformed SPONSOR aborts with
        // nothing deployed. Unset means "the deployer", which is what the old
        // ignition modules did (`m.getParameter("sponsor", deployer)`) and what
        // `.env.e2e`'s `ETH_SPONSOR_KEY` (anvil account 0) expects.
        address sponsorOverride = vm.envOr("SPONSOR", address(0));

        vm.startBroadcast();
        address admin = msg.sender;
        address sponsor = sponsorOverride == address(0) ? admin : sponsorOverride;

        // Steps 1 and 5. Two independent cores, same deployer, same admin.
        Core memory eth = deploy(admin, sponsor);
        Core memory rh = deploy(admin, sponsor);

        // Step 2 -- the real mock-wrapper trio. These keep their CREATE
        // addresses and their own storage; the webapp's sponsor-guard spec
        // calls `mockWrapper.routerWrapper` through `executeTransaction`.
        MockToken mockToken = new MockToken();
        MockDeFi mockDeFi = new MockDeFi(address(mockToken));
        MockWrapper mockWrapper = new MockWrapper(address(mockDeFi));

        // Steps 3, 4 and 6 -- code sources only. The old scripts deployed a
        // throwaway instance purely to read runtime code off it before
        // `setCode`; these are those instances. `mockToken` above doubles as
        // the source for the fourteen stock aliases: MockToken takes no
        // constructor arguments and has no immutables, so a second instance
        // would have byte-identical runtime code.
        WETH9 weth9Impl = new WETH9();
        MockUSDC mockUsdcImpl = new MockUSDC();
        MockStockSwapV4 stockSwapImpl = new MockStockSwapV4();
        MockV4Quoter quoterImpl = new MockV4Quoter();

        // The real RelayWrapper, which the liquidity-monitor refill policies
        // bind to. It takes nothing: the router it dispatches to arrives per
        // call from the live Relay quote, and has no code on this unforked
        // chain, so a dispatch sweeps the input straight back to the vault.
        // Deployed last, so no address `.env.e2e` bakes in moves.
        RelayWrapper relayWrapper = new RelayWrapper();

        // Lombard: MockLBTC stands in for LBTC, its router, mailbox and notary;
        // LombardWrapper is the real exit wrapper, bound to it. After the
        // RelayWrapper, for the same reason: no earlier address moves.
        MockLBTC mockLbtc = new MockLBTC(vm.addr(LOMBARD_NOTARY_KEY), LOMBARD_TREASURY);
        LombardWrapper lombardWrapper = new LombardWrapper(address(mockLbtc));

        // v1.1 vaults: one factory per State, registered as "vaults", so every
        // e2e cofund gets a vault that answers ERC-1271 logins. Last, so no
        // earlier address moves.
        CFHelpersVaultFactoryv1_1 ethVaults = new CFHelpersVaultFactoryv1_1(eth.state);
        CFHelpersVaultFactoryv1_1 rhVaults = new CFHelpersVaultFactoryv1_1(rh.state);
        CFHelpersGovv1(eth.gov).setHelperContract("vaults", address(ethVaults));
        CFHelpersGovv1(rh.gov).setHelperContract("vaults", address(rhVaults));

        // Base: a third core, built as Robinhood's is -- its own core and its
        // own v1.1 factory, registered as "vaults". Last of all, so no address
        // `.env.e2e` or a spec bakes in moves.
        Core memory base = deploy(admin, sponsor);
        CFHelpersVaultFactoryv1_1 baseVaults = new CFHelpersVaultFactoryv1_1(base.state);
        CFHelpersGovv1(base.gov).setHelperContract("vaults", address(baseVaults));

        vm.stopBroadcast();

        _report(admin, sponsor, eth, rh, base);
        _emit("mockToken", address(mockToken));
        _emit("mockDeFi", address(mockDeFi));
        _emit("mockWrapper", address(mockWrapper));
        _emit("weth9Impl", address(weth9Impl));
        _emit("mockUsdcImpl", address(mockUsdcImpl));
        _emit("mockStockSwapV4Impl", address(stockSwapImpl));
        _emit("mockV4QuoterImpl", address(quoterImpl));
        _emit("relayWrapper", address(relayWrapper));
        _emit("lombardLbtc", address(mockLbtc));
        _emit("lombardWrapper", address(lombardWrapper));
        _emit("lombardNotary", vm.addr(LOMBARD_NOTARY_KEY));
        console2.log(string.concat("E2E_KEY lombardNotaryKey ", vm.toString(bytes32(LOMBARD_NOTARY_KEY))));
        _emit("ethVaultsV1_1", address(ethVaults));
        _emit("ethVaultTemplateV1_1", ethVaults.template());
        _emit("rhVaultsV1_1", address(rhVaults));
        _emit("rhVaultTemplateV1_1", rhVaults.template());
        _emit("baseVaultsV1_1", address(baseVaults));
        _emit("baseVaultTemplateV1_1", baseVaults.template());
        _reportAliases();
    }

    /// @dev The alias plan the shell executes, so the canonical address list
    ///      lives in exactly one place. `E2E_ALIAS <implKey> <target>` means
    ///      "copy the runtime code at `<implKey>`'s address onto `<target>`";
    ///      `e2e-deploy.sh` resolves `<implKey>` against the `E2E_ADDR` lines
    ///      above, so a key must always be emitted before it is aliased.
    ///
    ///      `mockToken` is the source for the stocks and also a real
    ///      deployment in its own right (step 2) -- aliasing copies code, never
    ///      storage, so the two roles cannot interfere.
    function _reportAliases() private pure {
        _emit("weth", CANONICAL_WETH);
        _emit("usdc", CANONICAL_USDC);
        _emit("usdt", CANONICAL_USDT);
        _emit("usdg", USDG);
        _emit("stockSwapWrapper", STOCK_SWAP_WRAPPER);
        _emit("v4Quoter", V4_QUOTER);
        _emit("usdtKnownHolder", USDT_KNOWN_HOLDER);

        _alias("weth9Impl", CANONICAL_WETH);
        _alias("mockUsdcImpl", CANONICAL_USDC);
        _alias("mockUsdcImpl", CANONICAL_USDT);
        _alias("mockUsdcImpl", USDG);
        _alias("mockStockSwapV4Impl", STOCK_SWAP_WRAPPER);
        _alias("mockV4QuoterImpl", V4_QUOTER);

        string[14] memory symbols = _stockSymbols();
        address[14] memory stocks = _stockAddresses();
        for (uint256 i = 0; i < stocks.length; i++) {
            console2.log(string.concat("E2E_STOCK ", symbols[i], " ", vm.toString(stocks[i])));
            _alias("mockToken", stocks[i]);
        }
    }

    /* ───────────────────────────── pass 2 ───────────────────────────── */

    /// @notice Mints the reserves the aliased tokens need, then authorizes the
    ///         sponsor pool on all three stacks.
    /// @dev Runs only after the shell has aliased mock code onto the canonical
    ///      addresses -- every mint below targets an aliased address and would
    ///      revert against empty code.
    ///
    ///      Reads `E2E_ETH_STATE` / `E2E_RH_STATE` / `E2E_BASE_STATE` and resolves gov and the
    ///      guard through `state.helperContracts(...)`, exactly as
    ///      `authorize-extra-sponsors.ts` did and as the webapp does: only the
    ///      state addresses are ever configured anywhere.
    function seedAndSponsor() external {
        address ethState = vm.envAddress("E2E_ETH_STATE");
        address rhState = vm.envAddress("E2E_RH_STATE");
        address baseState = vm.envAddress("E2E_BASE_STATE");
        address[] memory pool = vm.envOr("E2E_SPONSOR_POOL", ",", new address[](0));

        (address ethGov, address ethGuard) = _resolve(ethState, "ethereum");
        (address rhGov, address rhGuard) = _resolve(rhState, "robinhood");
        (address baseGov, address baseGuard) = _resolve(baseState, "base");

        vm.startBroadcast();

        // ── step 4's tail: pre-fund the holder the webapp impersonates ─────
        MockUSDC(CANONICAL_USDT).mint(USDT_KNOWN_HOLDER, USDT_HOLDER_BALANCE);

        // ── step 6's tail: reserves the swap wrapper pays out of ───────────
        address[14] memory stocks = _stockAddresses();
        for (uint256 i = 0; i < stocks.length; i++) {
            MockToken(stocks[i]).mint(STOCK_SWAP_WRAPPER, SHARE_RESERVE);
        }
        MockUSDC(USDG).mint(STOCK_SWAP_WRAPPER, USDG_RESERVE);

        // ── step 7, and it must stay last: every CREATE is behind us ───────
        _authorize(ethGov, ethGuard, pool);
        _authorize(rhGov, rhGuard, pool);
        _authorize(baseGov, baseGuard, pool);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== e2e seeding complete ===");
        console2.log("  USDT holder pre-funded  ", USDT_KNOWN_HOLDER);
        console2.log("  stock reserves minted   ", stocks.length);
        console2.log("  sponsors authorized     ", pool.length);
    }

    /// @dev `addSponsor` reverts `AlreadySponsor`, so skip the ones already on
    ///      the guard. Keeps the whole script re-runnable against a chain that
    ///      is already half-provisioned, which is how the old script behaved.
    function _authorize(address gov, address guard, address[] memory pool) private {
        for (uint256 i = 0; i < pool.length; i++) {
            if (CFSponsorGuardv1(guard).isAuthorizedSponsor(pool[i])) continue;
            CFHelpersGovv1(gov).addSponsor(pool[i]);
        }
    }

    /// @dev Mirrors `authorize-extra-sponsors.ts`: a state address with no gov
    ///      or no guard means the wrong address or an incomplete deploy, and
    ///      failing here beats a confusing revert three calls later.
    function _resolve(address state, string memory label) private view returns (address gov, address guard) {
        gov = CFHelpersStatev1(state).helperContracts("gov");
        guard = CFHelpersStatev1(state).helperContracts("sponsorGuard");
        if (gov == address(0) || guard == address(0)) {
            revert(string.concat("state for ", label, " has no gov/guard -- wrong address, or the deploy did not complete"));
        }
    }

    /* ───────────────────────────── reporting ───────────────────────────── */

    /// @dev One `E2E_ADDR <key> <address>` line per contract. Deliberately not
    ///      JSON: the shell assembles that, so nothing here depends on `jq`
    ///      being present in the foundry image (it is not).
    function _emit(string memory key, address value) private pure {
        console2.log(string.concat("E2E_ADDR ", key, " ", vm.toString(value)));
    }

    /// @dev One `E2E_ALIAS <implKey> <target>` line per `anvil_setCode` the
    ///      shell must perform, in the order the old seed scripts performed them.
    function _alias(string memory implKey, address target) private pure {
        console2.log(string.concat("E2E_ALIAS ", implKey, " ", vm.toString(target)));
    }

    function _emitCore(string memory prefix, Core memory core) private pure {
        _emit(string.concat(prefix, "State"), core.state);
        _emit(string.concat(prefix, "Gov"), core.gov);
        _emit(string.concat(prefix, "Policies"), core.policies);
        _emit(string.concat(prefix, "Users"), core.users);
        _emit(string.concat(prefix, "Factory"), core.factory);
        _emit(string.concat(prefix, "Guard"), core.guard);
    }

    function _report(address admin, address sponsor, Core memory eth, Core memory rh, Core memory base) private view {
        console2.log("");
        console2.log("=== Cofund v1 e2e chain deployed ===");
        console2.log("  chainId  ", block.chainid);
        console2.log("  deployer ", admin);
        console2.log("  sponsor  ", sponsor);
        console2.log("");

        _emit("deployer", admin);
        _emit("sponsor", sponsor);
        _emitCore("eth", eth);
        _emitCore("rh", rh);
        _emitCore("base", base);
        // The vault template is not registered anywhere -- State's
        // `clientVaults` is the only vault registry -- but the webapp's clone
        // prediction needs it, so report it.
        _emit("ethVaultTemplate", CFHelpersVaultFactoryv1(eth.factory).template());
        _emit("rhVaultTemplate", CFHelpersVaultFactoryv1(rh.factory).template());
    }
}
