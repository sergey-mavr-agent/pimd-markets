// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MarketTypes as T} from "../../../src/v1/libraries/MarketTypes.sol";
import {BoundaryProofVerifier} from "../../../src/v1/BoundaryProofVerifier.sol";
import {IOracleIntake} from "../../../src/v1/interfaces/IOracleIntake.sol";

contract MockToken is ERC20 {
    uint8 private immutable digits;
    bool public rejectTransfers;
    bool public taxTransfers;
    address public callback;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes4 public callbackError;

    constructor(uint8 d) ERC20("Fixture", "FIX") {
        digits = d;
    }

    function decimals() public view override returns (uint8) {
        return digits;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(bool reject_, bool tax_) external {
        rejectTransfers = reject_;
        taxTransfers = tax_;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!rejectTransfers, "transfer rejected");
        if (from != address(0) && callback != address(0)) {
            address c = callback;
            callback = address(0);
            bytes memory reason;
            (callbackSucceeded, reason) = c.call(callbackData);
            if (reason.length >= 4) callbackError = bytes4(reason);
        }
        if (taxTransfers && from != address(0) && to != address(0) && amount > 0) {
            super._update(from, to, amount - 1);
            super._update(from, address(0), 1);
        } else {
            super._update(from, to, amount);
        }
    }
}

/// @dev Stands in for BoundaryOracle in market tests: prices are recorded where tests record them, a
/// proof records `proofValue`, and `priceable` mirrors the oracle's window rule (one hour before the
/// three-day timeout) unless a live proposal is simulated with `setLiveProposal`.
contract MockPrices {
    mapping(uint32 => mapping(uint64 => uint256)) public price;
    mapping(uint32 => uint64) public latestBoundary;
    mapping(uint32 => mapping(uint64 => bool)) public liveProposal;
    uint256 public proofValue = 1e18;
    uint256 public proofCalls;

    function record(uint32 version, uint64 boundary, uint256 value) external {
        price[version][boundary] = value;
        if (boundary >= latestBoundary[version]) latestBoundary[version] = boundary;
    }

    function setLiveProposal(uint32 version, uint64 boundary, bool live) external {
        liveProposal[version][boundary] = live;
    }

    function prove(uint32 version, uint64 boundary, BoundaryProofVerifier.BlockProof[3] calldata) external {
        require(price[version][boundary] == 0, "already recorded");
        ++proofCalls;
        price[version][boundary] = proofValue;
        if (boundary >= latestBoundary[version]) latestBoundary[version] = boundary;
    }

    function priceable(uint32 version, uint64 boundary) external view returns (bool) {
        if (price[version][boundary] != 0 || block.timestamp + 1 hours < uint256(boundary) + 3 days) return true;
        return liveProposal[version][boundary];
    }
}

contract MockVerifier {
    uint256 public value = 1e18;
    bool public fail;

    function configure(uint256 v, bool f) external {
        value = v;
        fail = f;
    }

    function verify(uint64, T.Asset calldata, BoundaryProofVerifier.BlockProof[3] calldata)
        external
        view
        returns (uint256)
    {
        require(!fail, "invalid proof");
        return value;
    }
}

contract MockSwap {
    uint256 public costPerUSDC = 1e12;
    bool public fail;
    bool public shortOutput;

    function configure(bool fail_, bool short_) external {
        fail = fail_;
        shortOutput = short_;
    }

    function setCost(uint256 cost) external {
        costPerUSDC = cost;
    }

    function exactOutput(uint32, uint256 output, uint256 maximum) external returns (uint256 spent) {
        require(!fail, "swap failed");
        spent = output * costPerUSDC;
        require(spent <= maximum, "max input");
        IERC20(T.IMD).transferFrom(msg.sender, address(this), spent);
        IERC20(T.USDC).transfer(msg.sender, shortOutput ? output - 1 : output);
    }
}

contract MockIntake is IOracleIntake {
    uint256 public nonce;
    uint256 public fee = 0.5 ether;
    bool public revertPrice;
    bool public revertRequest;
    uint256 public failAt;
    mapping(bytes32 => bytes) public bodies;
    mapping(bytes32 => address) public consumers;

    function configure(uint256 f, bool priceFail, bool requestFail) external {
        fee = f;
        revertPrice = priceFail;
        revertRequest = requestFail;
    }

    function setFailAt(uint256 at) external {
        failAt = at;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        require(!revertPrice, "price failed");
        return fee;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(!revertRequest && nonce + 1 != failAt && action == bytes32("oracle.request@oracle-1"), "request failed");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        id = keccak256(abi.encode(msg.sender, ++nonce));
        bodies[id] = body;
        consumers[id] = callback.target;
    }
}

/// @dev Test-only ERC-1271 account at the published signer address; no production keys are used.
contract MockSigner {
    address private immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 digest, bytes calldata sig) external view returns (bytes4) {
        return ECDSA.recover(digest, sig) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
