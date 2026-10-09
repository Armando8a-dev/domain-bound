// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DemoToken} from "../src/DemoToken.sol";
import {SignedVault} from "../src/SignedVault.sol";

contract SignedVaultTest is Test {
    DemoToken token;
    SignedVault vaultA;
    SignedVault vaultB;

    uint256 aliceKey = 0xA11CE;
    address alice;
    address attacker = makeAddr("attacker");

    bytes32 constant TYPEHASH =
        keccak256("WithdrawAuthorization(address owner,address to,uint256 amount,uint256 nonce,uint256 deadline)");

    function setUp() public {
        token = new DemoToken();
        vaultA = new SignedVault(token);
        vaultB = new SignedVault(token);
        alice = vm.addr(aliceKey);

        token.transfer(alice, 1000 ether);

        vm.startPrank(alice);
        token.approve(address(vaultA), type(uint256).max);
        token.approve(address(vaultB), type(uint256).max);
        vaultA.deposit(100 ether);
        vaultB.deposit(100 ether);
        vm.stopPrank();
    }

    function _signNaive(address to, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, alice, to, amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
        return vm.sign(aliceKey, digest);
    }

    function _signEip712(SignedVault vault, address to, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, alice, to, amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.domainSeparator(), structHash));
        return vm.sign(aliceKey, digest);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  THE HEADLINE: a naive signature for vault A also drains vault B
    // ─────────────────────────────────────────────────────────────────────

    function test_NaiveSignature_ReplaysAcrossVaults() public {
        (uint8 v, bytes32 r, bytes32 s) = _signNaive(attacker, 100 ether, 0, block.timestamp + 1 days);

        // Signed with vault A in mind (that's the only vault alice interacted with
        // when she signed) — nothing in the digest says so.
        vaultA.withdrawBySigNaive(alice, attacker, 100 ether, 0, block.timestamp + 1 days, v, r, s);
        assertEq(vaultA.balanceOf(alice), 0, "vault A drained as intended");

        // The exact same (v, r, s) submitted to a vault alice never signed anything for.
        vaultB.withdrawBySigNaive(alice, attacker, 100 ether, 0, block.timestamp + 1 days, v, r, s);
        assertEq(vaultB.balanceOf(alice), 0, "vault B drained too, same bytes, different vault");

        assertEq(token.balanceOf(attacker), 200 ether, "attacker collected from both vaults with one signature");
    }

    function test_NaiveSignature_RejectedOnSecondUseAtSameVault() public {
        (uint8 v, bytes32 r, bytes32 s) = _signNaive(attacker, 100 ether, 0, block.timestamp + 1 days);

        vaultA.withdrawBySigNaive(alice, attacker, 100 ether, 0, block.timestamp + 1 days, v, r, s);

        vm.expectRevert(SignedVault.InvalidSignature.selector);
        vaultA.withdrawBySigNaive(alice, attacker, 100 ether, 0, block.timestamp + 1 days, v, r, s);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  The EIP-712 path: domain separation stops the exact same attack
    // ─────────────────────────────────────────────────────────────────────

    function test_Eip712Signature_WorksOnIntendedVault() public {
        (uint8 v, bytes32 r, bytes32 s) = _signEip712(vaultA, attacker, 100 ether, 0, block.timestamp + 1 days);

        vaultA.withdrawBySig(alice, attacker, 100 ether, block.timestamp + 1 days, v, r, s);
        assertEq(vaultA.balanceOf(alice), 0);
        assertEq(token.balanceOf(attacker), 100 ether);
    }

    function test_Eip712Signature_RejectedOnOtherVault() public {
        (uint8 v, bytes32 r, bytes32 s) = _signEip712(vaultA, attacker, 100 ether, 0, block.timestamp + 1 days);

        // Same owner, same fields, same nonce value — only the verifying contract differs.
        vm.expectRevert(SignedVault.InvalidSignature.selector);
        vaultB.withdrawBySig(alice, attacker, 100 ether, block.timestamp + 1 days, v, r, s);

        assertEq(vaultB.balanceOf(alice), 100 ether, "vault B balance untouched");
    }

    function test_Eip712Signature_RejectedOnSecondUse() public {
        // Isolate nonce-reuse from the balance check: withdraw half, twice, with the
        // same signature. Balance alone would never block the replay.
        (uint8 v, bytes32 r, bytes32 s) = _signEip712(vaultA, attacker, 10 ether, 0, block.timestamp + 1 days);

        vaultA.withdrawBySig(alice, attacker, 10 ether, block.timestamp + 1 days, v, r, s);
        assertEq(vaultA.balanceOf(alice), 90 ether, "plenty left for a second withdrawal");

        vm.expectRevert(SignedVault.InvalidSignature.selector);
        vaultA.withdrawBySig(alice, attacker, 10 ether, block.timestamp + 1 days, v, r, s);
    }

    function test_TwoVaults_HaveDifferentDomainSeparators() public view {
        assertTrue(vaultA.domainSeparator() != vaultB.domainSeparator());
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Shared guards
    // ─────────────────────────────────────────────────────────────────────

    function test_DeadlineExpired_RevertsBothPaths() public {
        vm.warp(block.timestamp + 2 days);

        (uint8 nv, bytes32 nr, bytes32 ns) = _signNaive(attacker, 10 ether, 0, block.timestamp - 1 days);
        vm.expectRevert(SignedVault.DeadlineExpired.selector);
        vaultA.withdrawBySigNaive(alice, attacker, 10 ether, 0, block.timestamp - 1 days, nv, nr, ns);

        (uint8 ev, bytes32 er, bytes32 es) = _signEip712(vaultA, attacker, 10 ether, 0, block.timestamp - 1 days);
        vm.expectRevert(SignedVault.DeadlineExpired.selector);
        vaultA.withdrawBySig(alice, attacker, 10 ether, block.timestamp - 1 days, ev, er, es);
    }

    function test_InsufficientBalance_Reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signEip712(vaultA, attacker, 1000 ether, 0, block.timestamp + 1 days);
        vm.expectRevert(SignedVault.InsufficientBalance.selector);
        vaultA.withdrawBySig(alice, attacker, 1000 ether, block.timestamp + 1 days, v, r, s);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Fuzz: no forged signer can withdraw EIP-712 funds from either vault
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_Eip712_NeverAcceptsAWrongSignature(uint8 v, bytes32 r, bytes32 s, uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        vm.assume(v == 27 || v == 28);

        address recovered = ecrecover(
            keccak256(abi.encodePacked("\x19\x01", vaultA.domainSeparator(), keccak256(abi.encode(TYPEHASH, alice, attacker, amount, uint256(0), block.timestamp + 1 days)))),
            v,
            r,
            s
        );
        vm.assume(recovered != alice && recovered != address(0));

        // Either this contract's own check or OZ's ECDSA malleability guard must
        // refuse it — both outcomes mean "not alice's signature" was never accepted.
        vm.expectRevert();
        vaultA.withdrawBySig(alice, attacker, amount, block.timestamp + 1 days, v, r, s);
    }
}
