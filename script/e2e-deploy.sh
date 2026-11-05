#!/bin/sh
#
# e2e-deploy.sh -- provision a fresh anvil with the whole Cofund v1 e2e chain.
#
# Replaces the seven `npx hardhat ...` steps the webapp's `hardhat-deploy`
# compose service used to run (see script/DeployE2E.s.sol for the step-by-step
# mapping). Runs on nothing but `forge`, `cast` and a POSIX shell, so
# `ghcr.io/foundry-rs/foundry:latest` can execute it as-is -- there is no node,
# no npm and no `jq` in that image, which is why the address JSON is assembled
# here with awk rather than by a tool.
#
# Three phases, because a forge script cannot mutate a live node's code:
#
#   1. `forge script --sig deployAll()`   -- all three cores, every mock, one broadcast
#   2. `cast rpc anvil_setCode` x20       -- alias mocks onto canonical mainnet addresses
#   3. `forge script --sig seedAndSponsor()` -- mint reserves, then authorize sponsors LAST
#
# Environment (all optional):
#   RPC_URL               node to deploy against        (default http://127.0.0.1:8545)
#   E2E_ADDRESSES_OUT     where to write the JSON       (default ./out/e2e-addresses.json)
#   E2E_MNEMONIC          account source                (default: anvil/hardhat's)
#   DEPLOYER_KEY          override the derived account-0 key
#   SPONSOR               sponsor EOA baked into every guard (default: the deployer)
#   E2E_SPONSOR_POOL      comma-separated pool addresses (default: derived from the indices)
#   E2E_SPONSOR_POOL_INDICES  mnemonic indices for the pool (default "10 11 12 13 14 15 16 17 20 21 22 23")
#
set -eu

# busybox ash, dash and bash all have it; guard so a shell without it still runs.
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
OUT="${E2E_ADDRESSES_OUT:-./out/e2e-addresses.json}"
# Anvil's default mnemonic is Hardhat's, which is what makes accounts 0-19
# identical to the ones the webapp's `.env.e2e` recorded.
MNEMONIC="${E2E_MNEMONIC:-test test test test test test test test test test test junk}"
POOL_INDICES="${E2E_SPONSOR_POOL_INDICES:-10 11 12 13 14 15 16 17 20 21 22 23}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
cd "$ROOT"

WORK=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$WORK'" EXIT
TOKENS="$WORK/tokens"
: > "$TOKENS"

say() { printf '%s\n' "$*" >&2; }
die() { printf 'e2e-deploy: %s\n' "$*" >&2; exit 1; }

# ── accounts ────────────────────────────────────────────────────────────────
# Account 0 deploys everything, so every CREATE address is a pure function of
# its nonce on a fresh chain. `.env.e2e`'s ETH_SPONSOR_KEY is this same account.
DEPLOYER_KEY="${DEPLOYER_KEY:-$(cast wallet private-key "$MNEMONIC" 0)}"
DEPLOYER=$(cast wallet address "$DEPLOYER_KEY")

if [ -n "${E2E_SPONSOR_POOL:-}" ]; then
    POOL="$E2E_SPONSOR_POOL"
else
    # Accounts 10-17 and 20-23: the webapp's parallel-worker sponsor pool (19
    # deploys its Aave market). Each worker broadcasts from its own sponsor so
    # the app's per-sponsor nonce lock stops serializing the suite; an
    # unauthorized key is inert, because guard.relay gates on
    # isAuthorizedSponsor[msg.sender].
    POOL=""
    for i in $POOL_INDICES; do
        a=$(cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$i")
        POOL="${POOL:+$POOL,}$a"
    done
fi

say "e2e-deploy: rpc      $RPC_URL"
say "e2e-deploy: deployer $DEPLOYER"
say "e2e-deploy: pool     $POOL"

# ── wait for the node ───────────────────────────────────────────────────────
# Compose's healthcheck already gates this container, but a bare `anvil` on a
# laptop may still be opening its socket.
n=0
until cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; do
    n=$((n + 1))
    [ "$n" -lt 60 ] || die "no node at $RPC_URL after 60s"
    sleep 1
done

CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")

# Log first, then print it: `forge | tee` would report tee's status, and dash
# (the foundry image's /bin/sh) has no pipefail, so a failed forge passed.
forge_run() {
    sig="$1"
    shift
    status=0
    forge script script/DeployE2E.s.sol:DeployE2E \
        --sig "$sig" \
        --rpc-url "$RPC_URL" \
        --private-key "$DEPLOYER_KEY" \
        --broadcast \
        "$@" > "$WORK/forge.log" 2>&1 || status=$?
    cat "$WORK/forge.log"
    return "$status"
}

# ── phase 1: deploy the three cores and every mock ──────────────────────────
say ""
say "e2e-deploy: [1/3] deploying the ethereum, robinhood and base cores and the mocks"
# An empty-but-set SPONSOR would reach `vm.envOr` as an unparseable address, so
# unset it and let the script fall back to the deployer -- which is what the old
# ignition modules did (`m.getParameter("sponsor", deployer)`).
if [ -z "${SPONSOR:-}" ]; then unset SPONSOR 2>/dev/null || true; else export SPONSOR; fi
# `--slow`: one transaction per block. The three cores and the mocks are more
# gas than one 30M block holds, and anvil's automine leaves a transaction that
# does not fit the block it is batched into pending until the NEXT transaction
# arrives -- which forge, waiting on that receipt, never sends. Nonces, and so
# addresses, are the same either way.
forge_run 'deployAll()' --slow || die "deployAll() failed"

# The script emits `E2E_ADDR <key> <addr>`, `E2E_ALIAS <implKey> <target>`,
# `E2E_STOCK <symbol> <addr>` and `E2E_KEY <key> <hex>`. grep -o strips forge's
# log framing and, because the patterns are anchored to fixed shapes,
# guarantees the fields are clean.
grep -oE 'E2E_(ADDR|ALIAS|STOCK|KEY) [A-Za-z0-9_]+ 0x[0-9a-fA-F]+' "$WORK/forge.log" > "$TOKENS" || true
[ -s "$TOKENS" ] || die "deployAll() printed no addresses -- see the forge output above"

addr() {
    v=$(awk -v k="$1" '$1=="E2E_ADDR" && $2==k {print $3}' "$TOKENS" | tail -1)
    [ -n "$v" ] || die "missing address for '$1'"
    printf '%s' "$v"
}

# A test-only private key the script publishes (MockLBTC's notary).
key() {
    v=$(awk -v k="$1" '$1=="E2E_KEY" && $2==k {print $3}' "$TOKENS" | tail -1)
    [ -n "$v" ] || die "missing key for '$1'"
    printf '%s' "$v"
}

# ── phase 2: alias the mocks onto the canonical mainnet addresses ───────────
# The e2e chain is UNFORKED, so mainnet WETH/USDC/USDT, Robinhood's USDG, the
# fourteen tokenized stocks, the stock-swap wrapper and the V4 quoter do not
# exist -- but the webapp hard-codes all of them with no devnet override. The
# old seed scripts deployed a throwaway instance and copied its runtime code
# across with `hardhat_setCode`; `anvil_setCode` is the same capability under
# the name this node answers to.
#
# Code only, never storage -- which is exactly what the harness wants (WETH
# starts with zero supply and mints from deposits) and why the swap mocks hold
# their prices in constants and take their reserves from phase 3.
say ""
say "e2e-deploy: [2/3] aliasing mock code onto the canonical mainnet addresses"
awk '$1=="E2E_ALIAS" {print $2, $3}' "$TOKENS" > "$WORK/aliases"
aliased=0
skipped=0
while read -r impl target; do
    [ -n "$impl" ] || continue
    if [ "$(cast code "$target" --rpc-url "$RPC_URL")" != "0x" ]; then
        # Matches the old scripts' "already present -- skipping", which is what
        # made a re-run against a half-provisioned chain a no-op.
        skipped=$((skipped + 1))
        continue
    fi
    cache="$WORK/code.$impl"
    [ -f "$cache" ] || cast code "$(addr "$impl")" --rpc-url "$RPC_URL" > "$cache"
    cast rpc anvil_setCode "$target" "$(cat "$cache")" --rpc-url "$RPC_URL" >/dev/null \
        || die "anvil_setCode failed for $target"
    [ "$(cast code "$target" --rpc-url "$RPC_URL")" != "0x" ] \
        || die "anvil_setCode did not take at $target"
    aliased=$((aliased + 1))
done < "$WORK/aliases"
say "e2e-deploy:       $aliased aliased, $skipped already present"

# ── phase 3: mint the reserves, then authorize the sponsor pool ─────────────
# Sponsors are the last thing that happens, deliberately: `addSponsor` calls
# consume deployer nonces, and the old flow kept them behind every CREATE so
# they could not shift the addresses the web build bakes in. Nothing is created
# after this point.
say ""
say "e2e-deploy: [3/3] minting reserves, then authorizing the sponsor pool on all three stacks"
# Exported, not prefixed: a `VAR=x func` prefix sets the variable in the calling
# shell without necessarily exporting it, so the forge subprocess would not see it.
E2E_ETH_STATE="$(addr ethState)"
E2E_RH_STATE="$(addr rhState)"
E2E_BASE_STATE="$(addr baseState)"
export E2E_ETH_STATE E2E_RH_STATE E2E_BASE_STATE
E2E_SPONSOR_POOL="$POOL"
export E2E_SPONSOR_POOL
forge_run 'seedAndSponsor()' || die "seedAndSponsor() failed"

# ── the address JSON ────────────────────────────────────────────────────────
stocks_json() {
    awk '$1=="E2E_STOCK" {
        printf "%s\n      \"%s\": \"%s\"", (NR_OUT++ ? "," : ""), $2, $3
    }' "$TOKENS"
}

pool_json() {
    printf '%s' "$POOL" | awk -F, '{
        for (i = 1; i <= NF; i++) printf "%s\n    \"%s\"", (i > 1 ? "," : ""), $i
    }'
}

JSON=$(cat <<EOF
{
  "chainId": $CHAIN_ID,
  "deployer": "$(addr deployer)",
  "sponsor": "$(addr sponsor)",
  "sponsorPool": [$(pool_json)
  ],
  "ethereum": {
    "state": "$(addr ethState)",
    "gov": "$(addr ethGov)",
    "policies": "$(addr ethPolicies)",
    "users": "$(addr ethUsers)",
    "vaults": "$(addr ethVaultsV1_1)",
    "sponsorGuard": "$(addr ethGuard)",
    "vaultTemplate": "$(addr ethVaultTemplateV1_1)"
  },
  "robinhood": {
    "state": "$(addr rhState)",
    "gov": "$(addr rhGov)",
    "policies": "$(addr rhPolicies)",
    "users": "$(addr rhUsers)",
    "vaults": "$(addr rhVaultsV1_1)",
    "sponsorGuard": "$(addr rhGuard)",
    "vaultTemplate": "$(addr rhVaultTemplateV1_1)"
  },
  "base": {
    "state": "$(addr baseState)",
    "gov": "$(addr baseGov)",
    "policies": "$(addr basePolicies)",
    "users": "$(addr baseUsers)",
    "vaults": "$(addr baseVaultsV1_1)",
    "sponsorGuard": "$(addr baseGuard)",
    "vaultTemplate": "$(addr baseVaultTemplateV1_1)"
  },
  "mocks": {
    "mockToken": "$(addr mockToken)",
    "mockDeFi": "$(addr mockDeFi)",
    "mockWrapper": "$(addr mockWrapper)",
    "weth9Impl": "$(addr weth9Impl)",
    "mockUsdcImpl": "$(addr mockUsdcImpl)",
    "mockStockSwapV4Impl": "$(addr mockStockSwapV4Impl)",
    "mockV4QuoterImpl": "$(addr mockV4QuoterImpl)",
    "relayWrapper": "$(addr relayWrapper)"
  },
  "lombard": {
    "lbtc": "$(addr lombardLbtc)",
    "wrapper": "$(addr lombardWrapper)",
    "notary": "$(addr lombardNotary)",
    "notaryKey": "$(key lombardNotaryKey)"
  },
  "aliased": {
    "weth": "$(addr weth)",
    "usdc": "$(addr usdc)",
    "usdt": "$(addr usdt)",
    "usdg": "$(addr usdg)",
    "usdtKnownHolder": "$(addr usdtKnownHolder)",
    "stockSwapWrapper": "$(addr stockSwapWrapper)",
    "v4Quoter": "$(addr v4Quoter)",
    "stocks": {$(stocks_json)
    }
  }
}
EOF
)

mkdir -p "$(dirname "$OUT")"
printf '%s\n' "$JSON" > "$OUT"
say ""
say "e2e-deploy: wrote $OUT"
say ""

# stdout carries the JSON and nothing else, so a caller can pipe this straight
# into a file or a parser; every progress line above went to stderr.
printf '%s\n' "$JSON"
