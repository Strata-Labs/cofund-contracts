// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title  MockLBTC -- Lombard's LBTC for the unforked e2e chain.
///
/// @notice One contract plays the token, the AssetRouter, the GMP mailbox and a
///         one-validator notary consortium. It keeps the two calls a Cofund
///         vault meets on mainnet, with mainnet's encodings, fee and errors:
///
///         - `mint(rawPayload, proof)`, callable by anyone. `rawPayload` is a
///           GMP `MessageV1` whose body is Lombard's `mint(bytes32 toToken,
///           bytes32 recipient, uint256 amount)` release, byte for byte as the
///           Lombard API hands it out; `proof` is `abi.encode(bytes[])` with
///           one entry, the notary's 64-byte `r || s` over `sha256(rawPayload)`.
///           A payload mints once; a replay reverts
///           `AssetRouter_MintProcessingError()`, as mainnet does.
///         - `redeemForBtc(scriptPubkey, amount)`, which burns `amount` from
///           the caller, mints the 10,000 sat redeem fee to the treasury and
///           emits the mailbox's `MessageSent` with mainnet's redeem payload.
///           `amount - 10,000` must be at least 3,300 sat.
///
/// @dev    Mainnet routes these through four contracts; here they are one, so
///         `MessageSent` comes from this address rather than from Lombard's
///         mailbox, and its `msgSender` is this address rather than the
///         AssetRouter. Everything else in the event matches mainnet. Test
///         chain only: the notary is a published test key.
contract MockLBTC is ERC20 {
    /* ----------  mainnet constants (Lombard's libraries, verbatim)  ---------- */

    // bytes4(keccak256("MessageV1(bytes32,uint256,bytes32,bytes32,bytes32,bytes)"))
    bytes4 internal constant GMP_V1_SELECTOR = 0xe288fb4a;
    // bytes4(keccak256("mint(bytes32,bytes32,uint256)"))
    bytes4 internal constant MINT_SELECTOR = 0x155b6b13;
    // bytes4(keccak256("redeem(bytes32,bytes32,bytes32,bytes,uint256)"))
    bytes4 internal constant REDEEM_REQUEST_SELECTOR = 0xaa3db85f;

    /// @dev The ledger module that signs deposits and receives redeems.
    bytes32 public constant BTC_STAKING_MODULE = bytes32(uint256(0x0089e3e4e7a699d6f131d893aeef7ee143706ac23a));
    /// @dev Bitcoin mainnet's Lombard chain id, as the AssetRouter reports it.
    bytes32 public constant BITCOIN_CHAIN_ID = 0xff0000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f;
    /// @dev The Lombard ledger's chain id, `MessageSent`'s first topic on mainnet.
    bytes32 public constant LEDGER_CHAIN_ID = 0x0387b25e8e61f2ce4838b04795b231f09ee73ffd391da018bef4bc5c4975897b;
    /// @dev Mainnet's outbound message path (Ethereum -> ledger).
    bytes32 internal constant OUTBOUND_PATH = 0xe088dec32ceec088c8dd4e2647656948b0a023cc623b13ef92f786a0ed7064b3;

    /// @dev Mainnet `tokenConfig(LBTC)`: redeem fee 10,000 sat, minimum 3,300
    ///      sat after the fee, and no to-native commission.
    uint256 public constant REDEEM_FEE = 10_000;
    uint256 public constant REDEEM_FOR_BTC_MIN_AMOUNT = 3_300;

    /* ----------  state  ---------- */

    address public immutable notary;
    address public immutable treasury;

    /// @dev sha256(rawPayload) => minted.
    mapping(bytes32 => bool) public usedPayloads;
    uint256 public outboundNonce;

    /* ----------  mainnet's events and errors  ---------- */

    /// @dev Lombard's `IMailbox.MessageSent`.
    event MessageSent(
        bytes32 indexed destinationLChainId, address indexed msgSender, bytes32 indexed recipient, bytes payload
    );

    error AssetRouter_MintProcessingError();
    error AssetRouter_FeeGreaterThanAmount();
    error AmountBelowMinLimit(uint256 dustLimit);
    error ScriptPubkeyUnsupported();
    error LengthMismatch();
    error NotEnoughSignatures();
    /// @dev Mock only. Mainnet splits this across GMP and AssetRouter errors.
    error InvalidPayload();

    constructor(address notary_, address treasury_) ERC20("Lombard Staked Bitcoin", "LBTC") {
        require(notary_ != address(0) && treasury_ != address(0), "zero address");
        notary = notary_;
        treasury = treasury_;
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /* ----------  mint  ---------- */

    /// @notice Mints the release `rawPayload` carries, once, on a notary proof.
    function mint(bytes calldata rawPayload, bytes calldata proof) external returns (address recipient) {
        if (rawPayload.length < 4 + 32 * 6 || bytes4(rawPayload) != GMP_V1_SELECTOR) revert InvalidPayload();
        (,, bytes32 msgSender, address msgRecipient,, bytes memory body) =
            abi.decode(rawPayload[4:], (bytes32, uint256, bytes32, address, address, bytes));
        if (msgSender != BTC_STAKING_MODULE || msgRecipient != address(this)) revert InvalidPayload();

        uint256 amount;
        (recipient, amount) = _decodeRelease(body);

        // Mainnet skips the proof of a payload it already delivered, so a
        // replay fails on the spent payload whatever proof comes with it.
        bytes32 payloadHash = sha256(rawPayload);
        if (usedPayloads[payloadHash]) revert AssetRouter_MintProcessingError();
        _checkProof(payloadHash, proof);
        usedPayloads[payloadHash] = true;

        _mint(recipient, amount);
    }

    /// @dev `Assets.decodeRelease`, plus `toToken` must be this token.
    function _decodeRelease(bytes memory body) private view returns (address recipient, uint256 amount) {
        if (body.length != 4 + 32 * 3) revert InvalidPayload();
        bytes4 selector;
        bytes32 toToken;
        bytes32 rawRecipient;
        assembly {
            selector := mload(add(body, 0x20))
            toToken := mload(add(body, 0x24))
            rawRecipient := mload(add(body, 0x44))
            amount := mload(add(body, 0x64))
        }
        if (
            selector != MINT_SELECTOR || toToken != bytes32(uint256(uint160(address(this))))
                || uint256(rawRecipient) >> 160 != 0 || rawRecipient == bytes32(0) || amount == 0
        ) revert InvalidPayload();
        recipient = address(uint160(uint256(rawRecipient)));
    }

    /// @dev `Consortium._checkProof` with a one-validator set: one 64-byte
    ///      `r || s`, tried with v = 27 then 28.
    function _checkProof(bytes32 payloadHash, bytes calldata proof) private view {
        bytes[] memory signatures = abi.decode(proof, (bytes[]));
        if (signatures.length != 1) revert LengthMismatch();
        bytes memory sig = signatures[0];
        if (sig.length == 64) {
            bytes32 r;
            bytes32 s;
            assembly {
                r := mload(add(sig, 0x20))
                s := mload(add(sig, 0x40))
            }
            for (uint8 v = 27; v <= 28; v++) {
                (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(payloadHash, v, r, s);
                if (err == ECDSA.RecoverError.NoError && signer == notary) return;
            }
        }
        revert NotEnoughSignatures();
    }

    /* ----------  redeem  ---------- */

    /// @notice Burns `amount` from the caller and requests `amount - fee` sat
    ///         to `scriptPubkey` (P2WPKH, P2WSH or P2TR).
    function redeemForBtc(bytes calldata scriptPubkey, uint256 amount) external {
        uint256 amountAfterFee = _amountAfterFee(scriptPubkey, amount);
        if (amountAfterFee < REDEEM_FOR_BTC_MIN_AMOUNT) revert AmountBelowMinLimit(REDEEM_FOR_BTC_MIN_AMOUNT);

        bytes memory body = abi.encodeWithSelector(
            REDEEM_REQUEST_SELECTOR,
            BITCOIN_CHAIN_ID,
            bytes32(uint256(uint160(address(this)))),
            bytes32(uint256(uint160(msg.sender))),
            scriptPubkey,
            amountAfterFee
        );
        bytes memory rawPayload = abi.encodeWithSelector(
            GMP_V1_SELECTOR,
            OUTBOUND_PATH,
            outboundNonce++,
            bytes32(uint256(uint160(address(this)))),
            BTC_STAKING_MODULE,
            bytes32(0),
            body
        );
        emit MessageSent(LEDGER_CHAIN_ID, address(this), BTC_STAKING_MODULE, rawPayload);

        _mint(treasury, REDEEM_FEE);
        _burn(msg.sender, amount);
    }

    /* ----------  mainnet's read surface for the redeem form  ---------- */

    function calcUnstakeRequestAmount(bytes calldata scriptPubkey, uint256 amount)
        external
        pure
        returns (uint256 amountAfterFee, bool isAboveDust)
    {
        amountAfterFee = _amountAfterFee(scriptPubkey, amount);
        isAboveDust = amountAfterFee >= REDEEM_FOR_BTC_MIN_AMOUNT;
    }

    function getRedeemFee() external pure returns (uint256) {
        return REDEEM_FEE;
    }

    function getRedeemForBtcMinAmount() external pure returns (uint256) {
        return REDEEM_FOR_BTC_MIN_AMOUNT;
    }

    function isRedeemsEnabled() external pure returns (bool) {
        return true;
    }

    function getTreasury() external view returns (address) {
        return treasury;
    }

    /// @dev The AssetRouter's order: fee first, then the script type.
    function _amountAfterFee(bytes calldata scriptPubkey, uint256 amount) private pure returns (uint256) {
        if (amount <= REDEEM_FEE) revert AssetRouter_FeeGreaterThanAmount();
        if (!_isSupportedScript(scriptPubkey)) revert ScriptPubkeyUnsupported();
        return amount - REDEEM_FEE;
    }

    /// @dev `BitcoinUtils.getOutputType`: P2WPKH, P2TR or P2WSH.
    function _isSupportedScript(bytes calldata s) private pure returns (bool) {
        if (s.length == 22) return s[0] == 0x00 && s[1] == 0x14;
        if (s.length == 34) return (s[0] == 0x51 || s[0] == 0x00) && s[1] == 0x20;
        return false;
    }
}
