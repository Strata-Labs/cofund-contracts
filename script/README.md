# `script/`

| file | what it is |
|---|---|
| `DeployCore.s.sol` | The v1 core on any chain: State, Gov, Policies, Users, the vault factory and the sponsor guard, wired, plus one `addSponsor` and an optional `FEE_RECIPIENT` hand-off. Chain-agnostic; this is the production deploy. |
| `DeployE2E.s.sol` | The webapp's local e2e chain: three independent cores (Ethereum, Robinhood, Base) on one anvil, every mock, the seeding, the sponsor pool. Replaces the seven Hardhat steps. |
| `e2e-deploy.sh` | Drives `DeployE2E` end to end against a node and prints the address JSON. |
| `DeployLombardWrapper.s.sol` | `LombardWrapper` (LBTC -> BTC exit) on one chain. Takes `LBTC`; no owner, nothing else to wire. |
| `DeployVaultV1_1.s.sol` | The v1.1 vault factory and its template (ERC-1271 logins) for one chain's State. Takes `STATE`, then prints the Gov `setHelperContract("vaults", …)` call that makes new cofunds use it. |

---

## `DeployCore` — the production deploy

Three inputs, one of them optional:

| input | required | meaning |
|---|---|---|
| the broadcaster | yes | The Cofund admin. Not an environment variable: it is whoever signs, i.e. `--sender` / `--ledger` / `--private-key`. State's constructor grants it the only privileged bit in the system, and every wiring call in the script is gated on that bit. |
| `SPONSOR` | yes | The webapp's ERC-4337 sponsor account, authorized on the guard so it can pay gas for `relay`. |
| `FEE_RECIPIENT` | no | Where the protocol fee goes. Set it and the broadcaster's last act is `state.setFeeRecipientAddress(FEE_RECIPIENT)`. Leave it unset and nothing extra is sent, so the recipient stays what State's constructor seeded: the admin. |

**On mainnet, set `FEE_RECIPIENT`.** The constructor's seeding is right for a
test chain and wrong for production — the admin is a Ledger that signs Gov
calls, not a treasury. The recipient holds no privilege, so it can be a
multisig, a Safe, or any address that can receive tokens; it is a plain
registry entry the admin can change later through the same call.

### Deploying from a Ledger

```sh
SPONSOR=0x… FEE_RECIPIENT=0x… \
forge script script/DeployCore.s.sol:DeployCore \
  --rpc-url ethereum \
  --ledger --hd-paths "m/44'/60'/376864517'/0/0" \
  --sender 0x536e5C49D3CA62ADf4D2A5Cc2Cd8b9FeE8B0dF6a \
  --broadcast --slow
```

- **Dry run first**: the same command *without* `--broadcast` simulates
  everything and prints the report, touching no chain. Do that, read the
  addresses, then re-run with `--broadcast`.
- **`--sender` must be the address at `--hd-paths`.** The script takes its
  admin from the broadcasting key, so a mismatch reverts on the first wiring
  call rather than deploying something half-owned.
- **`--slow` waits for each receipt before sending the next transaction.**
  That is the right mode for a hardware wallet: the deployment is a chain of
  twelve dependent transactions — six creates, then the bootstrap, the four
  helper registrations and the `addSponsor`, thirteen with `FEE_RECIPIENT` —
  and confirming them one at a time on the device matches how the Ledger
  presents them anyway.
- **Enable blind signing in the Ledger Ethereum app.** Contract creation is
  not a transaction the device can decode, so without it the app refuses to
  sign and the script stops at the first deploy.

The script writes nothing to disk. It prints the addresses as lines and then
as one JSON object — including `feeRecipient`, read back from State rather
than re-derived — for the deployments record.

---

## Running the e2e deploy locally

Two terminals. In the first:

```sh
anvil --accounts 24 --chain-id 31337
```

`--accounts 24` matters: anvil defaults to 10, and the sponsor pool is accounts
10-17 and 20-23. The default mnemonic is Hardhat's, so accounts 0-19 are the
same ones the webapp's `.env.e2e` recorded.

In the second, from the repo root:

```sh
./script/e2e-deploy.sh
```

That is the whole thing. It writes `./out/e2e-addresses.json` (gitignored) and
prints the same JSON to stdout; every progress line goes to stderr, so
`./script/e2e-deploy.sh > addresses.json` gives you a clean file.

First run compiles the repo, which takes a minute or two under `via_ir`; later
runs reuse `out/`. A fresh clone needs `git submodule update --init --recursive`
first, since the script only runs `forge` and `cast` and will not fetch
`lib/forge-std` or `lib/openzeppelin-contracts` for you.

### Knobs

All optional; the defaults are what compose and a laptop both want.

| variable | default | meaning |
|---|---|---|
| `RPC_URL` | `http://127.0.0.1:8545` | node to deploy against |
| `E2E_ADDRESSES_OUT` | `./out/e2e-addresses.json` | where the JSON is written |
| `E2E_MNEMONIC` | anvil/hardhat's default | account source |
| `DEPLOYER_KEY` | account 0, derived | overrides the deployer |
| `SPONSOR` | the deployer | sponsor EOA baked into every guard |
| `E2E_SPONSOR_POOL` | derived from the indices | comma-separated pool addresses |
| `E2E_SPONSOR_POOL_INDICES` | `10 11 12 13 14 15 16 17 20 21 22 23` | mnemonic indices for the pool |

### Determinism

Every address is a pure function of the deployer's nonce, so two runs against
two fresh anvils produce byte-identical JSON. That is what lets the webapp bake
state addresses into its build. It holds only from a **fresh** chain: re-running
against an already-provisioned node deploys a second set of cores at new
addresses (it does skip aliases and sponsors that already exist, so it does not
fail — it just is not idempotent for the cores). The compose service below runs
once against a fresh anvil, which is the case that matters.

---

## What it provisions

Old Hardhat step, and where it went:

| # | old step | now |
|---|---|---|
| 1 | `ignition deploy cofund-vault.eth.ts` | `deployAll()` — `DeployCore.deploy` #1, the "ethereum" stack |
| 2 | `ignition deploy mock-wrapper.ts` | `deployAll()` — `MockToken` / `MockDeFi` / `MockWrapper` |
| 3 | `scripts/seed-localhost-weth.ts` | `deployAll()` deploys `WETH9`; the shell aliases it onto mainnet WETH |
| 4 | `scripts/seed-localhost-usdc.ts` | `deployAll()` deploys `MockUSDC`; shell aliases onto USDC + USDT; `seedAndSponsor()` pre-funds the impersonated holder |
| 5 | `ignition deploy cofund-vault.robinhood.ts` | `deployAll()` — `DeployCore.deploy` #2, the "robinhood" stack |
| 6 | `scripts/seed-localhost-robinhood.ts` | `deployAll()` deploys the swap mocks; shell aliases USDG, the 14 stocks, the wrapper and the quoter; `seedAndSponsor()` mints the reserves |
| 7 | `scripts/authorize-extra-sponsors.ts` | `seedAndSponsor()`, last |
| — | (new) | `deployAll()` — `DeployCore.deploy` #3, the "base" stack, with its own v1.1 factory, after every other CREATE so no earlier address moves |

Three phases, because a forge script cannot `setCode` on a live node
(`vm.etch` is simulation-only and never reaches a `--broadcast` target):

```
forge script --sig deployAll()        three cores, every mock, one broadcast
cast rpc anvil_setCode  x20           alias mocks onto canonical mainnet addresses
forge script --sig seedAndSponsor()   mint reserves, then authorize sponsors LAST
```

**Sponsors go last, and it is load-bearing.** `authorize-extra-sponsors.ts` ran
as a post-deploy step rather than inside the ignition modules because extra
deployer transactions consume nonces before the later modules deploy, shifting
their CREATE addresses off the values baked into the web build. Same reasoning
here: the pool `addSponsor` calls are the last thing that happens, after every
CREATE and every mint.

**Aliasing copies code, never storage** — the same as `hardhat_setCode` before
it. So the aliased WETH has an empty `name()`/`symbol()` and `decimals() == 0`,
exactly as it did under Hardhat; the harness deposits ETH and mints from zero
and never reads them. The swap mocks keep their prices in `constant`s and take
their reserves from phase 3 for the same reason. `anvil_setStorageAt` and
`anvil_setBalance` are not needed: no old step used `setStorageAt`, and anvil
pre-funds all 24 accounts with 10 000 ETH, so the sponsor pool already has gas.

Every stack gets the **full** pool, accounts 10-17 and 20-23. The webapp
splits it (10-13 on ethereum, 14-17 on robinhood, 20-23 on base; 19 deploys
its Aave market); authorizing all twelve on all three is a superset, so every
worker assignment works.

---

## The address JSON

```json
{
  "chainId": 31337,
  "deployer": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "sponsor": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "sponsorPool": ["0xBcd4042D…", "…12 entries, accounts 10-17 and 20-23…"],
  "ethereum": {
    "state": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    "gov": "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
    "policies": "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
    "users": "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
    "vaults": "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9",
    "sponsorGuard": "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707",
    "vaultTemplate": "0x856e4424f806D16E8CBC702B3c0F2ede5468eae5"
  },
  "robinhood": {
    "state": "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0",
    "gov": "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82",
    "policies": "0x9A676e781A523b5d0C0e43731313A708CB607508",
    "users": "0x0B306BF915C4d645ff596e518fAf3F9669b97016",
    "vaults": "0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1",
    "sponsorGuard": "0x9A9f2CCfdE556A7E9Ff0848998Aa4a0CFD8863AE",
    "vaultTemplate": "0x24B3c7704709ed1491473F30393FFc93cFB0FC34"
  },
  "base": {
    "state": "0x95401dc811bb5740090279Ba06cfA8fcF6113778",
    "gov": "0x998abeb3E57409262aE5b751f60747921B33613E",
    "policies": "0x70e0bA845a1A0F2DA3359C97E0285013525FFC49",
    "users": "0x4826533B4897376654Bb4d4AD88B7faFD0C98528",
    "vaults": "0x1291Be112d480055DaFd8a610b7d1e203891C274",
    "sponsorGuard": "0x0E801D84Fa97b50751Dbf25036d067dCf18858bF",
    "vaultTemplate": "0x94B9874aC5605713CcAc00ca8E832B37e15c1399"
  },
  "mocks": {
    "mockToken": "…", "mockDeFi": "…", "mockWrapper": "…",
    "weth9Impl": "…", "mockUsdcImpl": "…",
    "mockStockSwapV4Impl": "…", "mockV4QuoterImpl": "…", "relayWrapper": "…"
  },
  "lombard": {
    "lbtc": "…", "wrapper": "…", "notary": "…", "notaryKey": "0x…"
  },
  "aliased": {
    "weth": "0xC02aaA39…", "usdc": "0xA0b86991…", "usdt": "0xdAC17F95…",
    "usdg": "0x5fc5360D…", "usdtKnownHolder": "0xF977814e…",
    "stockSwapWrapper": "0xf21C3C4C…", "v4Quoter": "0x8Dc178eF…",
    "stocks": { "AAPL": "0xaF3D76f1…", "…14 symbols…": "" }
  }
}
```

- `ethereum` / `robinhood` / `base` use `DeployCore`'s own key names, so `vaults` is the
  factory. `vaultTemplate` is `factory.template()` — not registered anywhere
  (State's `clientVaults` is the only vault registry), but clone prediction
  needs it.
- `mocks.*Impl` are the instances the aliases were copied **from**. Nothing
  should call them; they exist so the copy has a source. `mockToken` is both a
  real deployment (the sponsor-guard spec calls it) and the code source for the
  fourteen stocks — copying code cannot link their storage.
- `aliased.*` are the canonical mainnet addresses the webapp hard-codes. They
  are fixed constants, listed so nothing has to duplicate the table.
- `lombard.lbtc` is `MockLBTC` (not aliased onto mainnet LBTC) and
  `lombard.wrapper` is a real `LombardWrapper` bound to it. `notaryKey` is a
  published test key: sign `sha256(payload)` with it, pass the 64-byte `r || s`
  as `abi.encode(bytes[])`, and anyone can `mint(payload, proof)`.

### Notes for the webapp cutover

- **`NEXT_PUBLIC_ETH_STATE_ADDRESS` is unchanged** —
  `0x5FbDB2315678afecb367f032d93F642f64180aa3`. State is still the first CREATE
  from account 0.
- **`NEXT_PUBLIC_ROBINHOOD_STATE_ADDRESS` moves** to
  `0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0`, because v1 has six core
  contracts instead of seven (the forwarder is gone) and the mocks now deploy in
  one broadcast.
  **Watch out:** the old value, `0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f`, is
  now `mocks.mockToken` — a live ERC20. A stale env var will not fail loudly; it
  will call an unrelated contract. Update it.
- **There is no forwarder.** `sponsor-guard-helpers.ts`'s `DeployedAddresses`
  still has `forwarder` and a `newGov` alias of `governance`; both should go.
- **Read this JSON instead of the ignition manifest.**
  `readIgnitionAddresses()` / `readRobinhoodIgnitionAddresses()` parse
  `ignition/deployments/chain-31337/deployed_addresses.json`, which no longer
  exists. Key mapping: `CofundVault#eth_state` → `ethereum.state`,
  `#eth_governance` → `ethereum.gov`, `#eth_factory` → `ethereum.vaults`,
  `#eth_sponsor_guard` → `ethereum.sponsorGuard`, `MockWrapper#mock_token` →
  `mocks.mockToken`, and so on.
- Everything else the webapp already resolves through
  `state.helperContracts(...)` (`src/lib/evm/config/get-helper-address.ts`), so
  only the state addresses are configuration.
- **`NEXT_PUBLIC_BASE_STATE_ADDRESS`** is
  `0x95401dc811bb5740090279Ba06cfA8fcF6113778`. The Base core is the last
  set of CREATEs, so no other address depends on it.

---

## The compose service

Replace the `hardhat-deploy` service in
`apps/cofund/docker-compose.e2e.yml` with this. The `hardhat` service (anvil)
stays exactly as it is.

```yaml
  hardhat-deploy:
    # Same image as the `hardhat` service above — forge, cast and a POSIX shell.
    # No node, no npm, no pnpm install, no solc download at runtime.
    image: ghcr.io/foundry-rs/foundry:latest
    depends_on:
      hardhat:
        condition: service_healthy
    working_dir: /work
    # Writable: forge writes out/, cache/ and broadcast/.
    volumes:
      - ${COFUND_SOLIDITY_DIR:-../../../cofund-solidity}:/work
      # Host-backed, not named volumes, for the same reason the hardhat build
      # cache was: `down -v` destroys named volumes, and a cold `via_ir` build
      # of the whole contract set is ~2 min. Scoped by session so parallel
      # sessions cannot write each other's artifacts.
      - "${FOUNDRY_BUILD_CACHE_DIR:-${HOME}/.cache/cofund-devcache-foundry/${SESSION_NAME:-main}}/out:/work/out"
      - "${FOUNDRY_BUILD_CACHE_DIR:-${HOME}/.cache/cofund-devcache-foundry/${SESSION_NAME:-main}}/cache:/work/cache"
      # The address JSON, shared with whatever needs to read it.
      - e2e-addresses:/shared
    environment:
      RPC_URL: http://hardhat:8545
      E2E_ADDRESSES_OUT: /shared/e2e-addresses.json
      # Deliberately NOT passing E2E_SPONSOR_POOL. Unset, it derives accounts
      # 10-17 and 20-23 and authorizes all twelve on every stack, which covers
      # E2E_EXTRA_SPONSOR_ADDRESSES (10-13), E2E_EXTRA_SPONSOR_ADDRESSES_RH
      # (14-17) and E2E_EXTRA_SPONSOR_ADDRESSES_BASE (20-23) together. Passing
      # only some of those lists would leave the other workers unauthorized and
      # every relay from them reverting UnauthorizedCaller — if you override
      # it, pass the union.
      #
      # SPONSOR likewise: unset means the deployer, which is the account
      # .env.e2e's ETH_SPONSOR_KEY / ROBINHOOD_SPONSOR_KEY / BASE_SPONSOR_KEY
      # already point at.
    extra_hosts:
      - "host.docker.internal:host-gateway"
    # `sh <script>` rather than relying on the exec bit surviving the mount.
    entrypoint: ["sh"]
    command: ["/work/script/e2e-deploy.sh"]
    restart: "no"
```

and add the shared volume alongside the existing ones:

```yaml
volumes:
  e2e-addresses:
```

Then mount `e2e-addresses:/shared:ro` into whatever reads the addresses (the
playwright service, and `web` if it needs them at runtime) and point the test
helpers at `/shared/e2e-addresses.json`.

The `COFUND_SOLIDITY_DIR` mount must have its submodules initialized —
`lib/forge-std` and `lib/openzeppelin-contracts` — because the container runs
only `forge` and `cast`.

Two knobs if the shared-volume shape does not suit: `E2E_ADDRESSES_OUT` can
point anywhere the container can write (e.g. `/work/out/e2e-addresses.json`,
which lands in the host-backed `out` path above and is gitignored), and the
script also prints the JSON to stdout, so `docker compose run --rm hardhat-deploy`
can be redirected straight into a file.
