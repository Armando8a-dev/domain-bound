# DomainBound — one key, one door

> A withdrawal signed for one vault can be replayed, byte for byte, on any identical
> vault — unless the signature is cut from that exact contract's address. Two deployed
> vaults, one signature, and a key that either fits one lock or bounces off the other.

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity)
![Foundry](https://img.shields.io/badge/Tested%20with-Foundry-black)
![Tests](https://img.shields.io/badge/tests-9%20passing%20(1000%20fuzz%20runs)-success)
![Next.js](https://img.shields.io/badge/Next.js-15-black?logo=nextdotjs)
![License](https://img.shields.io/badge/license-MIT-blue)

📜 **Vault A:** [0xB9f66B45A91f1B5F5ea3fcCB9e24163c85E590Db](https://sepolia.etherscan.io/address/0xB9f66B45A91f1B5F5ea3fcCB9e24163c85E590Db)
📜 **Vault B:** [0x463cF49BC272D8C640Af21C8953e202264845E07](https://sepolia.etherscan.io/address/0x463cF49BC272D8C640Af21C8953e202264845E07)

---

## Same struct, two different signatures

Both withdrawal paths sign the identical fields — owner, recipient, amount, nonce,
deadline. The difference is entirely in what wraps those fields before they're signed.

**The vulnerable path** — a plain `personal_sign` prefix, nothing else:

```solidity
bytes32 structHash = keccak256(abi.encode(WITHDRAW_TYPEHASH, owner, to, amount, nonce, deadline));
bytes32 digest = MessageHashUtils.toEthSignedMessageHash(structHash);
address signer = ECDSA.recover(digest, v, r, s);
```

No chain id. No contract address. Deploy this exact contract twice and the second
deployment accepts the first one's signatures without complaint — both vaults compute
the same digest from the same fields.

**The safe path** — EIP-712 typed data, via OpenZeppelin's `EIP712`:

```solidity
bytes32 structHash = keccak256(abi.encode(WITHDRAW_TYPEHASH, owner, to, amount, _useNonce(owner), deadline));
bytes32 digest = _hashTypedDataV4(structHash);
address signer = ECDSA.recover(digest, v, r, s);
```

`_hashTypedDataV4` folds this contract's own domain — name, version, chain id, and
`address(this)` — into the digest before it's signed. Vault A and Vault B are different
addresses, so the same owner, signing the same fields, produces a *different* digest
for each one. Submit vault A's signature to vault B and `ECDSA.recover` returns someone
who isn't the owner. The withdrawal reverts.

## The exploit, proven in a test

```solidity
function test_NaiveSignature_ReplaysAcrossVaults() public {
    (uint8 v, bytes32 r, bytes32 s) = _signNaive(attacker, 100 ether, 0, block.timestamp + 1 days);

    vaultA.withdrawBySigNaive(alice, attacker, 100 ether, 0, block.timestamp + 1 days, v, r, s);
    vaultB.withdrawBySigNaive(alice, attacker, 100 ether, 0, block.timestamp + 1 days, v, r, s);

    assertEq(token.balanceOf(attacker), 200 ether); // one signature, two drained vaults
}
```

One signature. No second approval, no second message to sign. Two vaults, both paid
out, because `naiveNonce[owner]` is local storage — a fresh vault always starts at
nonce 0, so the replay's nonce check passes by coincidence every time.

## Try it yourself

The demo puts this at the center: sign once ("cut a key"), then try inserting it into
both vaults.

- **No cut** — the key is blank, cut from a hash with no address baked in. It fits both
  locks. The second vault lights up anyway — the breach.
- **EIP-712 cut** — the key's teeth are cut from Vault A's own address. It fits Vault A
  and visibly bounces off Vault B.

## Tests

`forge test` — 9 tests including a 1000-run fuzz, using real `vm.sign` over both digest
schemes:

| Test | What it proves |
|------|----------------|
| `test_NaiveSignature_ReplaysAcrossVaults` | **the headline** — one signature drains both vaults |
| `test_NaiveSignature_RejectedOnSecondUseAtSameVault` | same-vault replay is still blocked by the local nonce |
| `test_Eip712Signature_WorksOnIntendedVault` | the safe path succeeds where it was signed for |
| `test_Eip712Signature_RejectedOnOtherVault` | the same signature, same nonce value, fails on vault B — only the domain differs |
| `test_Eip712Signature_RejectedOnSecondUse` | nonce consumption blocks replay within one vault |
| `test_TwoVaults_HaveDifferentDomainSeparators` | confirms the actual on-chain cause |
| `test_DeadlineExpired_RevertsBothPaths` / `test_InsufficientBalance_Reverts` | shared guards hold |
| `testFuzz_Eip712_NeverAcceptsAWrongSignature` | 1000 runs of random `(v, r, s)` — never recovers the owner by accident |

## Run it

```bash
git submodule update --init --recursive
forge test -vv

cd frontend && npm ci && npm run dev
```

## Design notes

- **The naive scheme signs via `personal_sign`, not a raw `eth_sign`.** Wallets heavily
  restrict or warn on signing an arbitrary 32-byte hash directly — `eth_sign` is often
  disabled by default. Wrapping with the standard EIP-191 prefix keeps the scheme
  genuinely vulnerable (still no chain id, no contract address) while staying signable
  from any wallet without a scary warning.
- **Both vaults share one `DemoToken` and one struct shape.** Keeping everything else
  identical is what makes the domain separator the entire explanation for the different
  outcome — nothing else about the two vaults differs.
- **No prize or attacker narrative.** `to` defaults to the signer's own address in the
  demo; the point is that the signature works somewhere it was never meant to, which is
  the vulnerability regardless of who benefits.

## What I learned

- A domain separator isn't really about branding a signature with a name — the field
  that actually stops this attack is `verifyingContract`, and OpenZeppelin computes it
  from `address(this)` automatically. Two vaults with the *identical* name and version
  still produce different domain separators, because they're different addresses.
- Nonces alone don't bind a signature to anything beyond the contract that's tracking
  them. Two fresh contracts both start every address at nonce 0, so "the nonce matched"
  proves nothing about which contract the signer meant.
- This closes a loop from Block 19 (GhostSigner): that project's signature had no domain
  separator at all and the vulnerability was a null signer. Here the signer is completely
  real and the signature is well-formed — the missing piece is narrower and easier to
  miss, which is exactly why EIP-712 exists as a standard instead of a convention.

---

**Armando Ochoa** · Smart Contract Developer
Part of a 25+ block blockchain accelerator — this is the gasless transactions / EIP-712
module (Block 24).
