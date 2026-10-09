"use client";

import { useCallback, useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAccount, useReadContracts, useSignMessage, useSignTypedData, useWriteContract } from "wagmi";
import { sepolia } from "wagmi/chains";
import { keccak256, encodeAbiParameters, parseAbiParameters, type Hex } from "viem";

const VAULT_A = "0xB9f66B45A91f1B5F5ea3fcCB9e24163c85E590Db" as const;
const VAULT_B = "0x463cF49BC272D8C640Af21C8953e202264845E07" as const;
const AMOUNT = 10n * 10n ** 18n;

const TYPEHASH = keccak256(
  new TextEncoder().encode("WithdrawAuthorization(address owner,address to,uint256 amount,uint256 nonce,uint256 deadline)"),
);

const ABI = [
  { type: "function", name: "naiveNonce", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "nonces", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "withdrawBySigNaive", stateMutability: "nonpayable",
    inputs: [{ type: "address" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint8" }, { type: "bytes32" }, { type: "bytes32" }],
    outputs: [] },
  { type: "function", name: "withdrawBySig", stateMutability: "nonpayable",
    inputs: [{ type: "address" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint8" }, { type: "bytes32" }, { type: "bytes32" }],
    outputs: [] },
] as const;

type Mode = "naive" | "eip712";
type DoorState = "idle" | "fit" | "breached" | "held";

function Keyhole() {
  return (
    <svg width="34" height="34" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="9" r="4.2" /><path d="M12 12.5 L7.5 22 L16.5 22 Z" /></svg>
  );
}
function KeyIcon() {
  return (
    <svg width="44" height="18" viewBox="0 0 44 18" fill="none"><circle cx="9" cy="9" r="7" stroke="currentColor" strokeWidth="2.4" /><line x1="16" y1="9" x2="40" y2="9" stroke="currentColor" strokeWidth="2.4" /><line x1="33" y1="9" x2="33" y2="15" stroke="currentColor" strokeWidth="2.4" /><line x1="38" y1="9" x2="38" y2="13" stroke="currentColor" strokeWidth="2.4" /></svg>
  );
}

export default function Page() {
  const { address, isConnected } = useAccount();
  const [mode, setMode] = useState<Mode>("naive");
  const [sig, setSig] = useState<{ v: number; r: Hex; s: Hex; nonce: bigint; deadline: bigint } | null>(null);
  const [doorA, setDoorA] = useState<DoorState>("idle");
  const [doorB, setDoorB] = useState<DoorState>("idle");
  const [busy, setBusy] = useState(false);

  const { data } = useReadContracts({
    contracts: [
      { address: VAULT_A, abi: ABI, functionName: "naiveNonce", args: [address ?? "0x0"] },
      { address: VAULT_A, abi: ABI, functionName: "nonces", args: [address ?? "0x0"] },
    ],
    query: { enabled: Boolean(address) },
  });
  const naiveNonce = data?.[0]?.result as bigint | undefined;
  const eip712Nonce = data?.[1]?.result as bigint | undefined;

  const { signMessageAsync } = useSignMessage();
  const { signTypedDataAsync } = useSignTypedData();
  const { writeContractAsync } = useWriteContract();

  const cutKey = useCallback(async () => {
    if (!address) return;
    setBusy(true); setDoorA("idle"); setDoorB("idle");
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    try {
      if (mode === "naive") {
        const nonce = naiveNonce ?? 0n;
        const structHash = keccak256(
          encodeAbiParameters(parseAbiParameters("bytes32, address, address, uint256, uint256, uint256"), [TYPEHASH, address, address, AMOUNT, nonce, deadline]),
        );
        const flat = await signMessageAsync({ message: { raw: structHash } });
        setSig({ v: parseInt(flat.slice(130, 132), 16), r: flat.slice(0, 66) as Hex, s: `0x${flat.slice(66, 130)}` as Hex, nonce, deadline });
      } else {
        const nonce = eip712Nonce ?? 0n;
        const flat = await signTypedDataAsync({
          domain: { name: "SignedVault", version: "1", chainId: sepolia.id, verifyingContract: VAULT_A },
          types: { WithdrawAuthorization: [
            { name: "owner", type: "address" }, { name: "to", type: "address" },
            { name: "amount", type: "uint256" }, { name: "nonce", type: "uint256" }, { name: "deadline", type: "uint256" },
          ] },
          primaryType: "WithdrawAuthorization",
          message: { owner: address, to: address, amount: AMOUNT, nonce, deadline },
        });
        setSig({ v: parseInt(flat.slice(130, 132), 16), r: flat.slice(0, 66) as Hex, s: `0x${flat.slice(66, 130)}` as Hex, nonce, deadline });
      }
    } catch { /* rejected */ }
    setBusy(false);
  }, [address, mode, naiveNonce, eip712Nonce, signMessageAsync, signTypedDataAsync]);

  const insert = useCallback(
    (target: "A" | "B") => async () => {
      if (!address || !sig) return;
      setBusy(true);
      const vault = target === "A" ? VAULT_A : VAULT_B;
      const setDoor = target === "A" ? setDoorA : setDoorB;
      try {
        await (mode === "naive"
          ? writeContractAsync({ address: vault, abi: ABI, functionName: "withdrawBySigNaive", args: [address, address, AMOUNT, sig.nonce, sig.deadline, sig.v, sig.r, sig.s] })
          : writeContractAsync({ address: vault, abi: ABI, functionName: "withdrawBySig", args: [address, address, AMOUNT, sig.deadline, sig.v, sig.r, sig.s] }));
        setDoor(target === "A" ? "fit" : mode === "naive" ? "breached" : "fit");
      } catch {
        setDoor("held");
      }
      setBusy(false);
    },
    [address, sig, mode, writeContractAsync],
  );

  return (
    <main className="relative min-h-screen">
      <div className="relative z-10 mx-auto flex min-h-screen max-w-2xl flex-col px-6 py-9">
        <header className="flex flex-wrap items-center justify-between gap-5">
          <span className="display text-[17px] font-bold tracking-wide">DomainBound</span>
          <ConnectButton showBalance={false} chainStatus="icon" accountStatus="address" />
        </header>

        <h1 className="display mt-8 text-[30px] font-extrabold leading-[1.15] sm:text-[38px]">
          ONE KEY.<br /><span className="text-[var(--bronze)]">ONE DOOR.</span>
        </h1>

        <div className="mt-7 flex justify-center">
          <div className="modeswitch">
            <button data-on={mode === "naive"} onClick={() => { setMode("naive"); setSig(null); setDoorA("idle"); setDoorB("idle"); }}>No cut</button>
            <button data-on={mode === "eip712"} onClick={() => { setMode("eip712"); setSig(null); setDoorA("idle"); setDoorB("idle"); }}>EIP-712 cut</button>
          </div>
        </div>

        <section className="stage mt-10">
          <div className="lockcol">
            <div className="keyhole" data-state={doorA}><Keyhole /></div>
            <span className="locklabel">Vault A</span>
            <span className="lockcaption">cut for this one</span>
            <button className="act act-gold" onClick={insert("A")} disabled={!sig || busy}>Insert</button>
          </div>

          <div className="keywrap">
            <div className="key" data-armed={Boolean(sig)}><KeyIcon /></div>
            <button className="act act-bronze" onClick={cutKey} disabled={!isConnected || busy}>
              {busy ? "…" : sig ? "Re-cut" : "Cut key"}
            </button>
          </div>

          <div className="lockcol">
            <div className="keyhole" data-state={doorB}><Keyhole /></div>
            <span className="locklabel">Vault B</span>
            <span className="lockcaption">never cut for this one</span>
            <button className="act act-gold" onClick={insert("B")} disabled={!sig || busy}>Insert</button>
          </div>
        </section>

        <div className="mt-8 flex min-h-[28px] justify-center">
          {doorB === "breached" && <span className="badge" data-tone="breach">fit anyway — wrong door</span>}
          {doorB === "held" && <span className="badge" data-tone="safe">bounced off — wrong cut</span>}
          {doorA === "fit" && doorB === "idle" && <span className="badge" data-tone="gold">fits, as expected</span>}
        </div>

        <p className="mx-auto mt-10 max-w-sm text-center text-[12.5px] leading-relaxed text-[var(--dim)]">
          {mode === "naive"
            ? "A blank key, cut from a hash with no address baked in. Every lock reads it the same."
            : "This key's teeth are cut from Vault A's own address. No other lock shares that cut."}
        </p>

        <div className="mt-10 flex flex-wrap justify-center gap-x-5 gap-y-2 pb-6 text-[11px] text-[var(--dim)]">
          <a className="hover:text-[var(--bronze)]" href={`https://sepolia.etherscan.io/address/${VAULT_A}`} target="_blank" rel="noreferrer">vault A ↗</a>
          <a className="hover:text-[var(--bronze)]" href={`https://sepolia.etherscan.io/address/${VAULT_B}`} target="_blank" rel="noreferrer">vault B ↗</a>
          <a className="hover:text-[var(--bronze)]" href="https://github.com/Armando8a-dev/domain-bound" target="_blank" rel="noreferrer">source ↗</a>
        </div>
      </div>
    </main>
  );
}
