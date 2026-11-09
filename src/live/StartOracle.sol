// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./vendor/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "./vendor/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "./vendor/openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "./vendor/openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "./vendor/openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "./vendor/openzeppelin/contracts/utils/math/Math.sol";
import {MarketTypes as T} from "./libraries/MarketTypes.sol";
import {OracleRequest} from "./libraries/OracleRequest.sol";
import {PimdRegistry} from "./PimdRegistry.sol";
import {BoundaryOracle} from "./BoundaryOracle.sol";
import {IOracleIntake} from "./interfaces/IOracleIntake.sol";

/// @notice Start prices for boundaries 27 h or more in the past, asked of the IMD oracle INTAKE with
/// BoundaryOracle's checks and recorded once per (version, boundary). These prices are strikes only:
/// they never settle a market.
/// @dev The requester alone pays BoundaryOracle.oracleCost(version) in IMD, one question per hop, and
/// the gas. A request the intake refuses reverts and records nothing; a request the oracle fails
/// clears its slot, so it may be repeated; a request left unanswered for REQUEST_TTL (the validity the
/// question body asks for) may be replaced by a new one, which voids the old questions. The answer
/// must pass the same attestation checks as a BoundaryOracle dispute resolution, signed by the same
/// signer, for this consumer.
contract StartOracle is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    error InvalidState();
    error InvalidAnswer();
    error InvalidPayment();

    address public constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address public constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    bytes32 public constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    /// @notice An open request this old (the question body's validForSeconds) may be replaced.
    uint256 public constant REQUEST_TTL = 86400;

    PimdRegistry public immutable registry;
    BoundaryOracle public immutable oracle;

    /// @notice USD per unitsPerShare of the version's token at the boundary, 18 decimals; 0 until answered.
    mapping(uint32 => mapping(uint64 => uint256)) public price;

    struct Pending {
        address requester;
        uint64 firstBlock;
        uint64 boundary;
        uint64 requestedAt;
        uint32 version;
        uint8 received;
        bool open;
        bytes32 anchorHash;
        uint256[3] answers;
        bytes32[3] requests;
    }

    struct Request {
        bytes32 key;
        bytes32 questionHash;
        uint8 hop;
        bool pending;
    }

    mapping(bytes32 => Pending) private pendings;
    mapping(bytes32 => Request) public requests;
    mapping(bytes32 => bool) public usedAttestations;

    event StartRequested(
        uint32 indexed version, uint64 indexed boundary, address indexed requester, uint64 firstBlock, uint256 cost
    );
    event OracleRequested(bytes32 indexed requestId, bytes32 indexed key, uint8 hop, bytes32 questionHash);
    event StartRecorded(uint32 indexed version, uint64 indexed boundary, uint256 price);
    event StartFailed(uint32 indexed version, uint64 indexed boundary, uint8 status);
    event StartExpired(uint32 indexed version, uint64 indexed boundary, address indexed requester);

    constructor(PimdRegistry registry_, BoundaryOracle oracle_) EIP712("IdentityMD Oracle", "2") {
        if (address(registry_) == address(0) || address(oracle_) == address(0)) revert InvalidState();
        registry = registry_;
        oracle = oracle_;
    }

    function key(uint32 version, uint64 boundary) public pure returns (bytes32) {
        return keccak256(abi.encode(version, boundary));
    }

    function pending(uint32 version, uint64 boundary) external view returns (Pending memory) {
        return pendings[key(version, boundary)];
    }

    /// @notice Asks the IMD oracle for the version's price at `boundary`, a registry boundary 27 h or
    /// more in the past. `firstBlock` is the first block at or after the boundary; the oracle refuses a
    /// wrong one. The caller pays BoundaryOracle.oracleCost(version) in IMD. An open request is refused
    /// until it is REQUEST_TTL old; then a new request replaces it and its questions are void.
    function request(uint32 version, uint64 boundary, uint64 firstBlock) external nonReentrant {
        T.Asset memory a = registry.asset(version);
        bytes32 k = key(version, boundary);
        Pending storage stale = pendings[k];
        if (
            block.chainid != 1 || !registry.isBoundary(boundary)
                || block.timestamp < uint256(boundary) + oracle.PROOF_WINDOW() || price[version][boundary] != 0
                || (stale.open && block.timestamp < uint256(stale.requestedAt) + REQUEST_TTL) || firstBlock == 0
                || uint256(firstBlock) + 2 >= block.number
        ) revert InvalidState();
        if (stale.open) {
            for (uint256 i; i < 3; ++i) {
                requests[stale.requests[i]].pending = false;
            }
            emit StartExpired(version, boundary, stale.requester);
        }
        (uint256 fee, uint256 total) = oracle.oracleCost(version);
        uint256 beforeBalance = IERC20(T.IMD).balanceOf(address(this));
        IERC20(T.IMD).safeTransferFrom(msg.sender, address(this), total);
        if (IERC20(T.IMD).balanceOf(address(this)) - beforeBalance != total) revert InvalidPayment();
        delete pendings[k];
        Pending storage p = pendings[k];
        p.requester = msg.sender;
        p.firstBlock = firstBlock;
        p.boundary = boundary;
        p.requestedAt = uint64(block.timestamp);
        p.version = version;
        p.open = true;
        IERC20(T.IMD).forceApprove(INTAKE, total);
        for (uint8 i; i < a.hops; ++i) {
            string memory q = OracleRequest.question(a, i, boundary, firstBlock, address(this), version);
            bytes32 rid = IOracleIntake(INTAKE)
                .requestWithFailure(
                    ACTION,
                    OracleRequest.body(q, firstBlock, address(this)),
                    IOracleIntake.Callback(address(this), this.onOracleResult.selector),
                    this.onFailure.selector,
                    T.IMD,
                    fee
                );
            if (rid == bytes32(0) || requests[rid].key != bytes32(0)) revert InvalidState();
            p.requests[i] = rid;
            bytes32 qh = OracleRequest.questionHash(q, firstBlock);
            requests[rid] = Request(k, qh, i, true);
            emit OracleRequested(rid, k, i, qh);
        }
        IERC20(T.IMD).forceApprove(INTAKE, 0);
        emit StartRequested(version, boundary, msg.sender, firstBlock, total);
    }

    function onOracleResult(bytes32 requestId, BoundaryOracle.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        Request storage r = requests[requestId];
        Pending storage p = pendings[r.key];
        if (msg.sender != INTAKE || !r.pending || !p.open) revert InvalidState();
        if (
            a.requestId == bytes32(0) || usedAttestations[a.requestId] || a.chainId != 1 || block.chainid != 1
                || a.questionHash != r.questionHash || a.answerType != 3 || a.answer.length != 32
                || a.fromBlock != p.firstBlock || a.toBlock != p.firstBlock + 2 || a.panelSize < 5 || a.quorum < 4
                || a.quorum > a.agreed || a.agreed > a.panelSize || a.issuedAt > block.timestamp
                || a.issuedAt < p.requestedAt || a.expiresAt < block.timestamp || a.expiresAt < a.issuedAt
                || a.blockHash == bytes32(0) || !SignatureChecker.isValidSignatureNow(SIGNER, digest(a), signature)
        ) revert InvalidAnswer();
        uint256 answer = abi.decode(a.answer, (uint256));
        if (answer == 0) revert InvalidAnswer();
        if (p.received == 0) p.anchorHash = a.blockHash;
        else if (p.anchorHash != a.blockHash) revert InvalidAnswer();
        r.pending = false;
        usedAttestations[a.requestId] = true;
        p.answers[r.hop] = answer;
        ++p.received;
        T.Asset memory asset = registry.asset(p.version);
        if (p.received == asset.hops) {
            uint256 value = uint256(asset.unitsPerShare) * 1e12;
            address cursor = asset.token;
            for (uint256 i; i < asset.hops; ++i) {
                bool forward = cursor == asset.path[i].currency0;
                value = forward
                    ? Math.mulDiv(value, p.answers[i], OracleRequest.HOP_BASE)
                    : Math.mulDiv(value, OracleRequest.HOP_BASE, p.answers[i]);
                cursor = forward ? asset.path[i].currency1 : asset.path[i].currency0;
            }
            if (value == 0 || value > T.MAX_PRICE) revert InvalidAnswer();
            p.open = false;
            price[p.version][p.boundary] = value;
            emit StartRecorded(p.version, p.boundary, value);
        }
    }

    function digest(BoundaryOracle.Attestation calldata a) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                bytes.concat(
                    abi.encode(
                        TYPEHASH,
                        a.requestId,
                        a.chainId,
                        a.questionHash,
                        a.answerType,
                        keccak256(a.answer),
                        a.figure,
                        a.fromBlock
                    ),
                    abi.encode(
                        a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                    )
                )
            )
        );
    }

    /// @notice A refused or failed question records nothing and frees the slot for a new request.
    function onFailure(bytes32 requestId, uint8 status, bytes32, uint16, uint16, bytes calldata) external nonReentrant {
        Request storage r = requests[requestId];
        Pending storage p = pendings[r.key];
        if (msg.sender != INTAKE || !r.pending || !p.open || (status != 1 && status != 2)) revert InvalidState();
        p.open = false;
        for (uint256 i; i < 3; ++i) {
            requests[p.requests[i]].pending = false;
        }
        emit StartFailed(p.version, p.boundary, status);
    }
}
