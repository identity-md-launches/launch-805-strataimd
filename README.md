# StrataIMD

StrataIMD (`STRATA`) is an immutable ERC-20 with no transfer fee. Its constructor
mints the entire supply once to `msg.sender`, the immediate deployer.

| Deployment parameter | Value |
| --- | --- |
| Contract | `src/StrataIMD.sol:StrataIMD` |
| Name / symbol | `StrataIMD` / `STRATA` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in minor units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None (`[]`; ABI encoding `0x`) |
| Native value required | `0` |
| Compiler | Solidity `0.8.26` |
| EVM target | Cancun |
| Optimizer | Enabled, 200 runs |
| Metadata bytecode hash | None |

## Behavior and assumptions

- Transfers deliver exactly the requested amount. There are no taxes, burns,
  rebases, transfer limits, exemptions, or fees payable to the deployer.
- The standard `transfer`, `approve`, and `transferFrom` functions return `true`
  on success and revert with ERC-20 custom errors on failure. Insufficient funds,
  insufficient allowance, and zero-address recipients are rejected without
  retaining partial state changes. Approving the zero address also reverts.
- Zero-value transfers between nonzero addresses are supported and emit a
  `Transfer` event. Self-transfers preserve balances. Delegated self-transfers
  still spend allowance.
- `approve` replaces an allowance and can revoke it by setting it to zero.
  Finite allowances decrease when spent; `type(uint256).max` means unlimited
  approval and does not decrease. `approve` emits `Approval`; this OpenZeppelin
  implementation does not emit another `Approval` when `transferFrom` spends it.
- There is no owner, administrator, pause, blacklist, seizure, external mint or
  burn function, initializer, proxy, upgrade path, or recipient callback.
  The constructor's mint is the only reachable supply-changing operation.
- The token has no payable entry point or asset recovery function. Sending
  tokens to the token contract itself does not make them recoverable.

## Build and validation

With Foundry and Solidity 0.8.26 installed:

```sh
forge build
forge test
forge fmt --check
```

The compiler is pinned by version in `foundry.toml`. All Solidity dependencies
are vendored as ordinary files, with licenses and archive hashes recorded in
`lib/PROVENANCE.md`. No package installation, submodule, RPC, wallet, environment
configuration, FFI, or filesystem cheatcode permission is required to run the
tests. The compiler itself is supplied by the build environment.

Unit tests cover metadata, constructor events, CREATE2 factory deployment,
exact transfer amounts, full/zero/self transfers, approval replacement and
revocation, finite/unlimited allowance spending, atomic failure paths, and
rejection of minting and privileged holder-control selectors. The deployed
runtime is checked for forbidden delegatecall, callcode, and selfdestruct
opcodes, skipping PUSH data.

Four fuzz tests run 512 cases each. Stateful invariants run 128 sequences of
64 operations across four funded holders, checking exact balance movements,
allowance spending, and conservation of the fixed supply.

The launch accounting fixture checks factory/distributor/holder/pool-address
token movements. It does not run Uniswap swaps. The supplied protected harness
depends on network launch infrastructure (`LaunchLiquidity`,
`PoolInitializationGuard`, `HookFlags`, Uniswap v4, and resolved launch
parameters) that was not provided as project source; that complete integration
check belongs to the launch verifier. Local tests do not substitute for it.

## Deployment and operations

Use the creation bytecode produced by the pinned build:

```sh
forge inspect src/StrataIMD.sol:StrataIMD bytecode
```

There are no constructor arguments to append and no initialization calls. A
direct deployment credits the deploying account. Deployment through a factory
credits the factory, not the originating wallet. A wrapper that creates the
token likewise receives the supply, so the launch operator must use the intended
deployment route and verify the recipient before distribution. CREATE2 works
without token-specific addresses or salts in the constructor.

The target chain must support the configured EVM version. No chain, factory,
pool, paired currency, initial price, pool allocation, or requester address was
specified in this assignment. The launch operator supplies and validates those
parameters separately. The token performs no automatic allocation: for an
IdentityMD launch, the factory handles the swarm allocation, pool seeding, and
remainder transfers. The illustrative pool share in tests is not a deployment
parameter. No application contracts are required for this token.

The operator is responsible for confirming the exact `10^27` supply and initial
factory balance, comparing deployed bytecode to this build, verifying source on
the target explorer, and completing the protected launch integration checks.
There are no token administration keys or maintenance calls. Holders control
transfers and allowances; integrations should request only the allowance they
need and account for the normal ERC-20 allowance replacement race when changing
an existing approval (revoke it first and confirm before granting a new one).

The implementation uses the vendored OpenZeppelin ERC-20 without modifying its
transfer or allowance logic. Review against the supplied security reference
found no external calls, price inputs, signatures, or upgrade authority in this
token. Foundry unit, fuzz, invariant, and bytecode checks are the local validation
scope; Slither and Mythril were not run. Tests are not an independent security
audit. An independent adversarial review remains a release responsibility.
No transactions have been broadcast.
