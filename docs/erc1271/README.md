# ERC-1271 logins for Cofund vaults

A Cofund EVM vault on the v1.1 template answers ERC-1271's
`isValidSignature(hash, signature)` for logins: a plain-text message that one
active admin of the cofund signed. Services that log a contract account in by
signature use it, such as Lombard and SIWE dapps.

## The vault

`CFHelpersVaultTemplatev1_1` is the v1 template plus `isValidSignature`. The
check is vault code, so no helper or Gov action can change what a vault
accepts.

Only cofunds created after the factory swap get it. Existing vaults are
immutable clones, and State writes a cofund's vault once.

## What it accepts

`signature = abi.encode(string company, string message, uint256 deadline, bytes signature)`

It returns `0x1626ba7e` when all of these hold, and `0xffffffff` otherwise. It
never reverts.
- `sha256(company)` is the vault's `clientId`.
- `message` is plain text: not empty, not 32 bytes, and no control bytes other
  than tab, line feed and carriage return.
- `hash` is the `personal_sign` hash of `message`.
- `deadline` is between now and 7 days from now.
- `signature` is an EIP-712 signature of
  `SignMessage(string company,string message,uint256 deadline)` under State's
  domain, and State lists its signer as an active admin of the cofund.

**Why one admin is enough.** Plain text can't move tokens.
- Every signature that authorizes a token transfer is typed data: EIP-2612
  permits, Permit2, USDC's `transferWithAuthorization`, and CoW, Seaport and
  UniswapX orders.
- A typed-data digest never equals a `personal_sign` hash.
- The 32-byte and control-byte rules refuse a hash passed off as text.

**What the admin sees.** The signed type carries the message itself, so the
wallet shows the text, not a hash.

**Replay.** `company` binds a signature to one cofund, and State's domain binds
it to one chain and one State. The service's own nonce stops a login being used
twice.

**Revocation.** The vault reads State on every check, so a removed or
deactivated admin's signatures stop validating at once. A session the service
already issued lasts as long as the service decides.

## What it refuses

Permits, Permit2 and signed orders get `0xffffffff`, for two reasons:
- **A signature would skip a policy's limits.** USDC accepts a contract's
  signature for `transferWithAuthorization`.
- **Orders need the vault to act itself.** That means standing approvals and
  cancels sent from the vault. The v1 vault only calls a policy's wrapper.

## Rollout

1. The webapp reads each cofund's vault from `State.clientVaults`. Predicting it
   through the factory would give old cofunds the wrong address after the swap.
2. Deploy the v1.1 template and factory with `script/DeployVaultV1_1.s.sol`.
3. Gov runs `setHelperContract("vaults", factoryV1_1)`.
4. `deployments/<chainId>.json` and the protocol SDK's deployment config gain
   the new `vaults`.

## Signing in the app

- **Privy:** one prompt, for the admin who started the action.
- **Ledger:** the ERC-7730 descriptor gains the `SignMessage` type.

## Lombard

Lombard issues a BTC deposit address to an account after a signed login, and
checks a contract's login with ERC-1271.

1. An admin enables Lombard once per cofund. The server fetches Lombard's
   challenge, the admin signs it, and the server stores the deposit address.
2. A deposit is an ordinary Bitcoin vault payment to that address.
3. Once Lombard notarizes the deposit, Cofund's sponsor calls
   `mint(payload, proof)`. Anyone may call it, and the LBTC goes to the vault
   the payload names.
4. Withdrawing is a vault transaction through `LombardWrapper`, which redeems
   to the cofund's Bitcoin vault.

## Tests

- `test/CFHelpersVaultv1_1.t.sol`: each rule above, an inactive admin, a member,
  another cofund's admin, and malformed bytes and bad signatures answering
  `0xffffffff` without reverting.
- `test/CFHelpersVaultv1_1Fork.t.sol`, on a mainnet fork: Gov registers the
  factory on the live State. A new cofund's vault passes OpenZeppelin's
  `SignatureChecker` with a login, and refuses a USDC
  `transferWithAuthorization` signed as one.
