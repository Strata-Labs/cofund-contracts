# v1 mainnet deploy — Ethereum (1), Robinhood (4663) and Base (8453)

Core stack only (`script/DeployCore.s.sol`): State, Gov, Policies, Users,
Factory (+ vault template), SponsorGuard, wired, one sponsor authorized, fee
recipient set. Protocol wrappers are chain-specific and deployed separately.

## Inputs (read from the live v0 stack on 2026-09-21)

| | Ethereum (1) | Robinhood (4663) |
|---|---|---|
| deployer / Cofund admin (Ledger) | `0x536e5C49D3CA62ADf4D2A5Cc2Cd8b9FeE8B0dF6a` at `m/44'/60'/376864517'/0/0` | same |
| `SPONSOR` (v0 guard's only authorized sponsor) | `0x9a87b9c5ee261c3b7f14dcc899a2ad5c8378e2ad` | same |
| `FEE_RECIPIENT` (v0 `State.cfFeeRecipientAddress()`) | `0x65a3E8C52b5C291b606DB9D7F22018Bb59548Fe6` | same |
| RPC alias (`foundry.toml`, needs `ALCHEMY_API_KEY`) | `ethereum` | `robinhood` |
| deployer balance at check time | 0.0162 ETH @ 0.046 gwei | 0.0124 ETH @ 0.053 gwei |

The broadcaster becomes the sole Cofund admin. The constructor sets the fee
recipient to the admin; `FEE_RECIPIENT` makes the script re-point it in the
same run.

## Ledger

Ethereum app open; **blind signing (contract data) enabled** — contract
creation cannot be clear-signed. Expect ~13 confirmations per chain (6 deploys,
5 wiring calls, `addSponsor`, `setFeeRecipientAddress`). `--slow` waits for each
receipt before the next prompt.

## Per chain

```bash
export ALCHEMY_API_KEY=…
export SPONSOR=0x9a87b9c5ee261c3b7f14dcc899a2ad5c8378e2ad
export FEE_RECIPIENT=0x65a3E8C52b5C291b606DB9D7F22018Bb59548Fe6
SENDER=0x536e5C49D3CA62ADf4D2A5Cc2Cd8b9FeE8B0dF6a
HD="m/44'/60'/376864517'/0/0"
```

1. Dry run (simulation only — prints gas and the addresses that WILL be produced):
   ```bash
   forge script script/DeployCore.s.sol:DeployCore --rpc-url ethereum --sender $SENDER
   ```
2. Broadcast:
   ```bash
   forge script script/DeployCore.s.sol:DeployCore --rpc-url ethereum \
     --ledger --hd-paths "$HD" --sender $SENDER --broadcast --slow
   ```
3. Save the printed one-line JSON as `deployments/1.json`, commit.
4. Repeat with `--rpc-url robinhood` → `deployments/4663.json`.

Addresses are CREATE-nonce-derived from the deployer, so the dry run's
addresses hold only if no other transaction from the deployer lands in between.

## Dry run (2026-09-21, deployer nonce as of that moment)

Both simulations: 14,257,254 gas total; ≈0.0014 ETH at ~0.1 gwei. Predicted
addresses — valid only if no other deployer transaction lands first:

| | Ethereum (1) | Robinhood (4663) |
|---|---|---|
| State | `0xD59eFC1803Fb72231Db0B6A872a9c22D8A0102C0` | `0xF3B43952BcC2560789be8076529df8F908cEf535` |
| Gov | `0xB1f02694d0Fb56a8B3978eEdB413aa406E6293Cf` | `0x987a629131715676708cf7063aC76177cFAf8BD7` |
| Policies | `0xd274E8F34E948cD15B212D797F92918AB0b70B65` | `0x12494Ea5919b5D91D48B1C9d2b3C8603adC2C736` |
| Users | `0xDF6e2411c519bFD959472E0b90ab334d742f57aF` | `0x09e1e092596020b6864Ba8Cd1a61A5DeFD1597Fb` |
| Factory | `0x22aA91CE2f8c45179354D219d2Fae4A858aA534f` | `0x8255B8C675A531D76494B2E9B7519826659218cf` |
| SponsorGuard | `0xB419aBdFFFDB6664017D04d91a7B1a4C31F5acea` | `0x0CE3E306111c8C17c68D06b95525750Ab8B6AECE` |

## After

- Post-checks (read-only): `state.isCofundAdmin(SENDER)`, `state.cfFeeRecipientAddress()`,
  `state.helperContracts("sponsorGuard")`, `guard.isAuthorizedSponsor(SPONSOR)`,
  `users.eip712Domain()` reports `("Cofund","1",chainid,state)`.
- Webapp chain config: State address per chain (everything else resolves through
  `helperContracts`); ERC-7730 `COFUND_STATE_ADDRESSES`.
- Verification: see "Source verification" below.

## Source verification

Seven contracts per chain: the six the script creates directly, each with one
`address` constructor argument (State takes the admin; everything else takes
State), plus the `CFHelpersVaultTemplatev1` the factory deploys in its
constructor (argument: State). Addresses come from `deployments/<chainId>.json`
and the template from `broadcast/DeployCore.s.sol/<chainId>/run-latest.json`
(`additionalContracts` of the factory's CREATE). Run from this repo at the
deployed commit (`dd7e505` or a descendant that does not touch `contracts/`)
so the compiler settings in `foundry.toml` match the deployed bytecode.

Ethereum (Etherscan; needs `ETHERSCAN_API_KEY`):

```bash
S=0xD59eFC1803Fb72231Db0B6A872a9c22D8A0102C0
A=0x536e5C49D3CA62ADf4D2A5Cc2Cd8b9FeE8B0dF6a
v() { forge verify-contract --chain 1 --watch --etherscan-api-key "$ETHERSCAN_API_KEY" \
       --constructor-args "$(cast abi-encode 'constructor(address)' "$3")" "$1" "$2"; }
v $S                                          contracts/CFHelpersStatev1.sol:CFHelpersStatev1               $A
v 0xB1f02694d0Fb56a8B3978eEdB413aa406E6293Cf contracts/CFHelpersGovv1.sol:CFHelpersGovv1                   $S
v 0xd274E8F34E948cD15B212D797F92918AB0b70B65 contracts/CFHelpersPoliciesv1.sol:CFHelpersPoliciesv1         $S
v 0xDF6e2411c519bFD959472E0b90ab334d742f57aF contracts/CFHelpersUsersv1.sol:CFHelpersUsersv1               $S
v 0x22aA91CE2f8c45179354D219d2Fae4A858aA534f contracts/CFHelpersVaultFactoryv1.sol:CFHelpersVaultFactoryv1 $S
v 0xa28f993c2503ee4b211cdb02a7e10511fc93cd7a contracts/CFHelpersVaultTemplatev1.sol:CFHelpersVaultTemplatev1 $S
v 0xB419aBdFFFDB6664017D04d91a7B1a4C31F5acea contracts/CFSponsorGuardv1.sol:CFSponsorGuardv1               $S
```

Robinhood (4663): `forge verify-contract` 1.5.x has no Etherscan entry for chain
4663 (an `[etherscan]` table entry does not help), so submit the standard JSON
to Etherscan's multichain API directly. For each contract:

```bash
forge verify-contract --show-standard-json-input --chain 1 --constructor-args "$ARGS" $ADDR contracts/$NAME.sol:$NAME > input.json
curl -X POST "https://api.etherscan.io/v2/api?chainid=4663" --data-urlencode "apikey=$ETHERSCAN_API_KEY" \
  -d module=contract -d action=verifysourcecode -d codeformat=solidity-standard-json-input \
  -d contractaddress=$ADDR --data-urlencode "contractname=contracts/$NAME.sol:$NAME" \
  --data-urlencode "compilerversion=v0.8.28+commit.7893614a" -d "constructorArguements=${ARGS#0x}" \
  --data-urlencode "sourceCode@input.json"
# then poll: …&module=contract&action=checkverifystatus&guid=<result>
```

`compilerversion` MUST be URL-encoded (the `+` otherwise arrives as a space and
Etherscan answers "Invalid Or Not supported solc version"). Robinhood's Blockscout
(`robinhoodchain.blockscout.com`) fronts its API with a Cloudflare challenge, so
`--verifier blockscout` cannot reach it from a script; Sourcify (`--verifier
sourcify`, no key, chain 4663 supported) is the scriptable third route.

### Status (2026-09-21)

| Explorer | Ethereum (7) | Robinhood (7) |
|---|---|---|
| Etherscan (`etherscan.io` / `robin.etherscan.io`) | verified | verified |
| Sourcify | exact_match | exact_match |
| Blockscout | State verified; the other six hit the unauthenticated rate limit | API behind Cloudflare; not done |
- v0 stays live and untouched until clients have moved.

## Base (8453)

Same script and inputs as Ethereum, with one extra step so every Base address
equals its Ethereum counterpart:

1. The admin sends 0 ETH to itself until its Base nonce is 26, the nonce
   Ethereum's State was created at (`cast nonce` to check).
2. `DeployCore` with `--rpc-url base` (13 transactions). State, Gov, Policies,
   Users, the v1 factory and the guard land at the Ethereum addresses.
3. The v1.1 vault factory comes from a fresh deployer's first transaction,
   which puts it at `0x5c73Da882A10B5F23F996e591D451016011b8aB8` on every chain
   (`script/DeployVaultV1_1.s.sol`, `STATE` = Base's State).
4. Gov `setHelperContract("vaults", 0x5c73…8aB8)` from the Ledger admin.

All eight contracts are verified on Basescan (`forge verify-contract --chain
base`) and Sourcify. The record is `deployments/8453.json`.
