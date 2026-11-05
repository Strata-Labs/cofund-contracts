# Fork testing

The default suite is fork-free. Every test in `test/` runs against the local
mocks in `contracts/Mock*.sol`, so plain `forge test` needs no RPC provider, no
API key and no network. Fork only when you want to check a wrapper against a
real protocol deployment.

## Running against a fork

Pass any RPC endpoint to `--fork-url`:

```bash
forge test --fork-url https://eth-mainnet.g.alchemy.com/v2/<key>
```

`foundry.toml` defines aliases under `[rpc_endpoints]`, so a chain name works in
place of a URL:

```bash
forge test --fork-url ethereum
forge test --fork-url base
forge test --fork-url arbitrum
forge test --fork-url robinhood
forge test --fork-url robinhood_testnet
```

The Alchemy-backed aliases interpolate `ALCHEMY_API_KEY` from the environment:

```bash
export ALCHEMY_API_KEY=...
forge test --fork-url base
```

`robinhood_testnet` points at a public endpoint and needs no key.

## Pinning a block

Without `--fork-block-number` the fork follows the chain tip, so results can
change between runs. Pinning makes a run reproducible and lets Foundry reuse the
state it already downloaded (cached under `~/.foundry/cache/rpc`):

```bash
forge test --fork-url ethereum --fork-block-number 22925142
```

## Narrowing a run

Forked runs are slow, so scope them:

```bash
forge test --fork-url base --match-path test/AaveWrapper.t.sol
forge test --fork-url base --match-test test_Withdraw -vvvv
```

To fork inside a single test rather than for the whole run, `vm.createSelectFork`
takes the same aliases: `vm.createSelectFork("base")`, or
`vm.createSelectFork("base", 37688000)` to pin the block.
