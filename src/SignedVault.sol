// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title SignedVault
/// @notice Two withdrawal paths over the same struct. One signs a bare struct hash —
///         no chain id, no contract address. The other wraps it in EIP-712, which
///         binds the digest to this exact deployed contract.
/// @dev    Deploy this twice over the same token. A signature authorizing a withdrawal
///         on vault A is, byte for byte, a valid signature to submit to vault B under
///         `withdrawBySigNaive` — nothing in the signed data says "vault A". Under
///         `withdrawBySig`, the same owner's signature for vault A is rejected by
///         vault B, because `_domainSeparatorV4()` bakes `address(this)` into the
///         digest, and the two vaults are different addresses.
contract SignedVault is EIP712, Nonces {
    IERC20 public immutable token;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public naiveNonce;

    /// @dev Same type string either way — the vulnerability isn't the struct, it's
    ///      what wraps the struct before it gets signed.
    bytes32 public constant WITHDRAW_TYPEHASH =
        keccak256("WithdrawAuthorization(address owner,address to,uint256 amount,uint256 nonce,uint256 deadline)");

    error DeadlineExpired();
    error InvalidSignature();
    error InsufficientBalance();
    error ZeroAmount();

    event Deposited(address indexed depositor, uint256 amount);
    event Withdrawn(address indexed owner, address indexed to, uint256 amount, bool domainBound);

    constructor(IERC20 _token) EIP712("SignedVault", "1") {
        token = _token;
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        balanceOf[msg.sender] += amount;
        token.transferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice VULNERABLE. The struct hash is signed via the ordinary `personal_sign`
    ///         wrapper (EIP-191) — no EIP-712 domain separator anywhere in it. The
    ///         exact (v, r, s) that authorizes this on one vault authorizes it on
    ///         every other `SignedVault` running this same code, as long as the local
    ///         nonce happens to match. Two freshly deployed vaults both start at
    ///         nonce 0 for every address, so they always match on the first call.
    function withdrawBySigNaive(
        address owner,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amount == 0) revert ZeroAmount();
        if (nonce != naiveNonce[owner]) revert InvalidSignature();
        if (balanceOf[owner] < amount) revert InsufficientBalance();

        bytes32 structHash = keccak256(abi.encode(WITHDRAW_TYPEHASH, owner, to, amount, nonce, deadline));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(structHash);
        address signer = ECDSA.recover(digest, v, r, s);
        if (signer != owner) revert InvalidSignature();

        naiveNonce[owner] = nonce + 1;
        balanceOf[owner] -= amount;
        token.transfer(to, amount);

        emit Withdrawn(owner, to, amount, false);
    }

    /// @notice SAFE. `_hashTypedDataV4` wraps the struct hash with this contract's own
    ///         domain separator — name, version, chain id, and `address(this)`. The
    ///         same owner signing the same fields for a different vault produces a
    ///         different digest, so `ECDSA.recover` returns a different address here,
    ///         never the real owner.
    function withdrawBySig(address owner, address to, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[owner] < amount) revert InsufficientBalance();

        bytes32 structHash =
            keccak256(abi.encode(WITHDRAW_TYPEHASH, owner, to, amount, _useNonce(owner), deadline));
        bytes32 digest = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(digest, v, r, s);
        if (signer != owner) revert InvalidSignature();

        balanceOf[owner] -= amount;
        token.transfer(to, amount);

        emit Withdrawn(owner, to, amount, true);
    }

    /// @notice This vault's own EIP-712 domain separator — different from every other
    ///         deployed `SignedVault`, even one with identical name and version.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
