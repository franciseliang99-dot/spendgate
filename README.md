# SpendGate — USDC spend limits for AI agents on Arc

An AI agent can only pay USDC within limits that are written on-chain:
a per-period cap, a per-payment cap, a recipient allowlist, an optional expiry,
and a revoke switch the human can flip at any time.

## How it works

- The human (owner) keeps the money in their own address. They `approve` the
  SpendGate contract once on the USDC ERC-20 interface.
- The owner creates a grant: which agent may pay, period length, per-period cap,
  per-payment cap, expiry, and the allowed recipients.
- The agent calls `pay(grantId, recipient, amount, ...)`. SpendGate checks every
  rule and then moves the funds directly with `transferFrom(owner → recipient)`.
- **The contract never holds funds.** The owner can cut the agent off in two
  independent ways: `revoke(grantId)`, or set the USDC allowance to zero.

## Why Arc

USDC is Arc's native currency and also pays for gas, so an agent needs only one
asset, and the limits are plain dollar amounts a person can read. The contract
uses only the ERC-20 USDC interface (6 decimals) and never accepts native value,
so there is no unit conversion to get wrong.

## Deployment (Arc mainnet, chain 5042)

- Contract: [`0x7D581560256BEFC39d875e9B23005FBE24A8cae6`](https://explorer.arc.io/address/0x7D581560256BEFC39d875e9B23005FBE24A8cae6)
  — source verified on Sourcify (exact match):
  [repo.sourcify.dev](https://repo.sourcify.dev/5042/0x7D581560256BEFC39d875e9B23005FBE24A8cae6)
- Demo grant (id 1): period 1 day, period cap 0.15 USDC, per-payment cap 0.10 USDC,
  one allowlisted recipient. The demo agent key holds only a little USDC for gas.
- Demo transactions:
  - payment of 0.05 within limits, succeeds:
    [`0xa9237b10…18c0`](https://explorer.arc.io/tx/0xa9237b10ffcb805ce5eceffd4a50f5256c1f1b6b223d15a0a707ad38f71718c0)
  - payment of 0.12 over the per-payment cap, rejected with `OverPerPaymentCap`:
    [`0xa09b413a…b108`](https://explorer.arc.io/tx/0xa09b413a4355678d0705b862090953b119f6bc7376b72cadfcc3f405aa9db108)
  - owner revokes the grant:
    [`0xbabdf2c5…64ed`](https://explorer.arc.io/tx/0xbabdf2c5d6449e52b48a46849809d1239f44e860ab9d772bb3caf5b3edb164ed)
  - payment of 0.05 after revoke, rejected with `Revoked`:
    [`0xe8aa822c…c1f4`](https://explorer.arc.io/tx/0xe8aa822cd9981a51be2a6b97e1f7a3ba94d7fdc202f369125b5f7377e8e7c1f4)

## Threat model

SpendGate assumes the agent's key may be stolen. Whoever holds that key can
spend no more than the grant allows: only to allowlisted recipients, at most the
per-payment cap per call, and at most the period cap per period, until the grant
expires or is revoked. The owner key is trusted. The contract has no admin, no
upgrade path, and no function that can move funds other than `pay`.

## Known properties (by design, not bugs)

- **Fixed windows.** An agent can spend the full cap in the last second of one
  period and again in the first second of the next, so up to 2x the cap in a
  short burst. Use a shorter period and a smaller cap if that matters.
- **The approval is the outer limit.** SpendGate's caps are the inner limit. If
  the owner approves an unlimited amount, a bug in this contract could reach the
  owner's whole balance. Approve only about one or two periods' worth.
- **Revocation can be front-run.** Arc has a mempool. If the agent key is
  already stolen, an attacker who sees `revoke` (or a cap / allowlist change)
  pending can pay first with a higher fee. Worst case: the rest of the current
  period's cap, plus one more period if this happens at a period boundary. To
  stop spending immediately, revoke **and** set the USDC approval to zero.
- **Shared approval.** All grants from one owner draw on one USDC approval, so
  one agent can use it up and make the others' payments fail. Use a separate
  owner address per agent if you need isolation.
- **Force-sent native USDC is stuck.** The contract never accepts value, but
  native USDC force-sent to it stays there; there is deliberately no withdraw
  function.
- **Very large period.** The period index stays 0, so the period cap becomes a
  lifetime cap. This is a valid configuration.

## Tests

Foundry unit, fuzz, and invariant tests (`forge test`). Invariants include:
spending in any period never exceeds the period cap, no single payment exceeds
the per-payment cap, payments only reach allowlisted recipients, and a revoked
grant never pays again. The invariant handler checks spending against its own
record of each cap, not against values read back from the contract.

The invariants were checked against deliberately broken copies of the contract.
Each break below turned its invariant red on five fuzz seeds, while the unchanged
contract stayed green:

- no period-cap check, `setCaps` resetting the spend, a window that never rolls
  over, a window that rolls over on every payment: `invariant_I3` fails
- no agent check: `invariant_I2` fails
- no allowlist check: `invariant_I1` fails

`forge lint` flags four narrowing casts in `src/SpendGate.sol`. All are safe:
`uint64(block.timestamp)` and `uint64(idx)` (the index is at most the timestamp),
`uint128(newSpent)` (checked against the `uint128` period cap just before), and
`uint128(m)` (at most `remaining`, a `uint128`). No lint-disable comments were
added, so the source stays byte-identical to the verified deployment.

## Build

```
forge install foundry-rs/forge-std --no-git
forge build
forge test
```

Solidity 0.8.30. No upgrade proxy, no admin key.

## License

MIT
