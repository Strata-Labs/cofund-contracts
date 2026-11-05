# Cofund contracts

Each client organisation gets a vault. What may leave that vault is decided in
advance by policies: a policy names the members who may authorise a class of
spend, how many of them must agree, and the limits on it — token, maximum
amount, and an allowlist of recipients, or for a transaction policy a specific
wrapper and function. Members approve a spend by signing EIP-712 typed data on
their own device; the vault verifies those signatures against the policy and
executes. A sponsor account operated by the server broadcasts the transaction
and pays the gas, and holds no authority over what it broadcasts.

This is the v1 stack.

## The contracts

**`CFHelpersStatev1`** — the registries and the invariants over them: clients,
users and the address reverse index, policies, vaults, subscription tiers, and
the replay store. It decides who may write, and enforces existence, uniqueness,
referential integrity and last-admin protection. It holds no business rules and
no time logic, and every write into it arrives from gov or from a helper.

**`CFHelpersUsersv1`** — the whole membership surface, in four functions:
`createClient`, `addUser`, `removeUser` and `rotateUser`. It is stateless, and
owns the authorization window, the admin-consensus thresholds and the signature
schemes.

**`CFHelpersPoliciesv1`** — activation and deactivation of transfer and
transaction policies under admin consensus, and validation of what a policy may
contain, including that its type is one State supports.

**`CFHelpersVaultFactoryv1`** and **`CFHelpersVaultTemplatev1`** — the factory
deploys a deterministic clone of the template per client, on State's
instruction; it keeps no registry of its own, because State's `clientVaults` is
the registry. The template is the vault: it holds the funds, checks signatures
against the policy, enforces the recipient allowlist, and calls wrappers for
transaction policies.

**`CFHelpersVaultFactoryv1_1`** and **`CFHelpersVaultTemplatev1_1`** — the
registered `"vaults"` helper on every chain, so every new cofund gets this
vault: v1 plus ERC-1271 `isValidSignature` for logins
([docs/erc1271/README.md](docs/erc1271/README.md)). Existing cofunds keep the
v1 vault they were created with.

**`CFHelpersGovv1`** — the Cofund-admin surface: registering helper contracts,
managing admins and sponsors, pausing the guard. It is called directly from a
Ledger rather than sponsored, so `msg.sender` is the whole authorization story.

**`CFSponsorGuardv1`** — the relay the sponsor broadcasts through. It has no
privilege of its own: being registered as `helperContracts["sponsorGuard"]` in
State *is* its role, and that is what the vault's broadcaster gate and the
onboarding gate on `Users.createClient` and `Users.addUser` recognise. It is
never a Cofund admin, so the gov surface is unreachable from it by construction.
`relay(target, data)` accepts calls from an allowlisted sponsor while unpaused,
and only to the users helper, the policies helper, or a vault State knows.

`AaveWrapper`, `CompoundWrapper` and `RelayWrapper` are unchanged from v0 and
are out of relaunch scope; the `Mock*` contracts exist for the tests.

## Onboarding

An invite is the admin's signed authorization, not a record on chain. The admin
signs a single `InviteUser` message naming the member's identity, their role
and position, and an `expiresAt` no more than 30 days out — and signs it before
the member has a wallet at all. The member later authenticates to the platform,
generates a key during onboarding, and signs that same message; the platform
relays one `Users.addUser` call carrying both signatures, and that call is what
creates the seat.

There is no invite code, and nothing is written on chain until the seat is
filled — no pending invite for an outsider to claim or for anyone to clean up.
A client is created the same way: `createClient` carries the founder's own
signature over their own seat, so a company cannot be created around a key
nobody holds.

`addUser` and `createClient` accept calls only from the sponsor guard or a
Cofund admin. The platform is the party that authenticated the person, so
requiring the call to arrive through the guard makes that trust a rule rather
than an assumption — and makes `guard.pause` the kill switch for onboarding.

## Three properties worth knowing

Policies reference identities, not addresses: a policy stores user ids, and a
signature is resolved through State at execution time, so rotating or removing a
key takes effect immediately on every policy with nothing to re-issue.

Every mutating helper call is authorized by EIP-712 signatures carried in
calldata rather than by `msg.sender`, which is what lets members stay plain EOAs
on a Ledger or an embedded wallet — no account abstraction, no delegation — while
the sponsor is an ordinary Alchemy smart account that only pays gas.

Recipient allowlists are enforced: a transfer policy with a non-empty recipient
list reverts on any recipient outside it, and an empty list means unrestricted,
with the recipient still committed by every signer in the digest.

## EIP-712 types

One domain for every type on a chain:

```
EIP712Domain(name="Cofund", version="1", chainId, verifyingContract=address(CFHelpersStatev1))
```

The `verifyingContract` is the chain's **State**, not the helper that verifies
the message. State is permanent per chain while helpers can be swapped, so a
signature is bound to a deployment rather than to whichever contract happens to
check it, and one Ledger descriptor registration per chain covers all ten types.
Every helper (and every vault clone) answers ERC-5267 `eip712Domain()` with this
domain. A digest built under any other domain — including a per-helper name such
as `"Cofund Users"`, or a helper or vault address as `verifyingContract` — is
rejected. Live State addresses are in `deployments/<chainId>.json`.

Field order is display order on the signing device.

Verified by `CFHelpersUsersv1`:

```
InviteUser(string company,string callerId,string userId,bool userIsAdmin,string userPosition,uint256 expiresAt,string authId)
RemoveUser(string company,string removedUserId,string authId)
RotateUser(string company,string userId,address newAddress,string authId)
CompleteOnboarding(string company,string authId)
```

Verified by `CFHelpersPoliciesv1`:

```
TransferPolicyActivation(string company,string policyId,string title,string policyType,string[] signerIds,uint256 threshold,address token,uint256 maxAmount,address[] recipients,string authId)
TransactionPolicyActivation(string company,string policyId,string title,string policyType,string[] signerIds,uint256 threshold,address wrapper,string func,string authId)
PolicyDeactivation(string company,string policyId,string authId)
```

Verified by `CFHelpersVaultTemplatev1` (each vault clone):

```
Transfer(string company,string policyId,string messageType,uint256 amount,address token,address recipient,string authId)
Transaction(string company,string policyId,string messageType,address wrapper,string func,Allowance[] allowances,bytes32 instructionsHash,string authId)
Allowance(address asset,uint256 amount)
```

`CompleteOnboarding` closes the client's onboarding phase: while
`State.onboardingComplete[clientId]` is false, one active admin's signature seats
an admin and activates a policy; any active admin may sign the close, and it is
permanent per client per chain.

`authId` is single-use per client across every helper and vault: State keeps
one `(clientId, authId)` replay store, so an authorization cannot be replayed
onto a swapped helper.

Every struct carries `string company` so the signer can see which organisation
they are signing for; the entrypoint still takes `bytes32 clientId` as the
storage key and checks `sha256(bytes(company)) == clientId`. Values a signer
approves are present as data rather than behind a hash, so a device in generic
EIP-712 mode shows all of them.

## Build and test

Foundry is the only toolchain. There is no npm.

```bash
git submodule update --init --recursive
forge build
forge test
```

The suite is fork-free and needs no RPC provider or API key. For running against
a real chain, see `FORK_GUIDE.md`.

## Deploy

The core is chain-agnostic. The **broadcasting key becomes the Cofund admin**
(`DeployCore.run` takes `msg.sender` under the open broadcast); the script reads
`SPONSOR` (required, the account the guard will accept relays from) and
`FEE_RECIPIENT` (optional; unset leaves the admin as recipient):

```bash
SPONSOR=<sponsor account> FEE_RECIPIENT=<treasury> \
  forge script script/DeployCore.s.sol:DeployCore --rpc-url <alias> --broadcast \
  --ledger --hd-paths "<path>" --sender <admin address>      # or --private-key ...
```

Dry-run by omitting `--broadcast`. The full mainnet procedure, gas figures and the
predicted addresses are in `docs/mainnet-deploy-v1.md`; live addresses are in
`deployments/<chainId>.json`.
